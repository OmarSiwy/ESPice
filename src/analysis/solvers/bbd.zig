//! Bordered-block-diagonal dense LU.
//!
//! The Builder's BBD permutation (subckt-expanded netlists) groups each
//! subcircuit instance's internal nodes into a contiguous block, with all
//! coupling/top-level nodes trailing. This solver exploits that:
//!
//!   [ A_1        E_1 ] [x_1]   [b_1]
//!   [     ...    ... ] [...] = [...]
//!   [        A_k E_k ] [x_k]   [b_k]
//!   [ F_1 ... F_k S  ] [x_g]   [b_g]
//!
//! Each block is extracted into DENSE per-block records in one contiguous
//! arena (blocks are small — dense LU with partial pivoting beats sparse GP
//! at that size, and the fixed layout is a future GPU batched-LU substrate).
//! Per block i: A_i (s×s row-major), W_i (s×m_i COLUMN-major; holds E_i,
//! then A_i^-1 E_i in place after factor), F_i (m_i×s row-major).
//! m_i is the block's LOCAL border footprint —
//! the set of border nodes it actually couples to — mapped by loc_i.
//!
//! Border set = {ground row 0} ∪ [coupling_start, n): row/col 0 is OUTSIDE
//! computeBbd's blocks and carries only the gmin'd diagonal, so it is
//! treated as a border node. Border membership is therefore an index list
//! (border_node), not a contiguous range.
//!
//! factor(vals): scatter flat CSC vals via a precomputed tape (src→dst
//! index pairs built once at init, the batch.zig `slots` idiom); per block
//! dense-LU A_i, solve W_i in place, reduce F_i·W_i directly into s_dense
//! in fixed block order; dense-LU s_dense. No refactor/pivot replay:
//! dense re-factor per Newton iteration is trivially cheap at these sizes.
//! Independent block factors may run through std.Io; reductions stay fixed-order.
//!
//! init returns error.NotApplicable unless the structure is profitable AND
//! provably clean (every CSC nnz classifiable as block-interior / E / F /
//! border-border; a cross-block entry — impossible by computeBbd
//! construction, checked defensively — disqualifies).
//!
//! DOD layout: block metadata stored as SoA (parallel slabs of start, s, m,
//! offsets). Per-block pivot and loc arrays packed into contiguous slabs
//! indexed by cumulative offsets. Single arena[] for all dense data.

const std = @import("std");
const root = @import("numerics");
const dense_lu = @import("dense_lu.zig");

const Allocator = std.mem.Allocator;
const NONE: u32 = std.math.maxInt(u32);

pub const InitError = error{ NotApplicable, OutOfMemory };

/// Activation thresholds. Defaults are the production gates used by
/// direct.SolverT; tests relax them to exercise small synthetic systems.
pub const Limits = struct {
    min_blocks: usize = 8,
    max_block: u32 = 64,
    max_border: u32 = 512,
};

pub fn Bbd(comptime T: type) type {
    return struct {
        const Self = @This();
        const Dense = dense_lu.DenseLu(T);
        const VecLen = std.simd.suggestVectorLength(T) orelse 1;
        const Vec = @Vector(VecLen, T);

        // -- SoA block metadata (parallel arrays, nb entries each) --
        blk_start: []u32, // global index of first block row/col
        blk_s: []u32, // block size
        blk_m: []u32, // local border footprint (|loc_i|)
        blk_a_off: []usize, // A_i offset in arena: s×s row-major
        blk_w_off: []usize, // W_i offset: s×m col-major (E, then A^-1 E)
        blk_f_off: []usize, // F_i offset: m×s row-major
        blk_piv_off: []usize, // offset into piv slab, s entries
        blk_loc_off: []usize, // offset into loc slab, m entries

        b: u32, // border size (>= 1: ground)
        nb: u32, // number of blocks
        arena: []T, // [A_i|W_i|F_i]* ++ s_dense
        s_off: usize, // s_dense (b×b row-major) offset in arena
        piv: []u32, // per-block pivot rows (contiguous slab)
        s_piv: []u32, // border pivot rows (b)
        loc: []u32, // local border col -> border position, per block
        border_node: []u32, // border position -> global node index (b)
        dst: []u32, // scatter tape: nnz p -> arena index
        bg: []T, // border gather scratch (b)
        gpa: Allocator,

        pub fn init(
            gpa: Allocator,
            n: u32,
            col_ptr: []const u32,
            row_idx: []const u32,
            info: root.BbdInfo,
            limits: Limits,
        ) InitError!Self {
            const nb: u32 = @intCast(info.blocks.len);
            if (nb < limits.min_blocks) return error.NotApplicable;
            const b: u32 = info.coupling_size + 1;
            if (b > @min(limits.max_border, n / 2)) return error.NotApplicable;
            if (info.coupling_start + info.coupling_size != n) return error.NotApplicable;

            // ---- node classification: block id / border position ----
            const node_block = try gpa.alloc(u32, n);
            defer gpa.free(node_block);
            @memset(node_block, NONE);
            for (info.blocks, 0..) |blk, bi| {
                if (blk.size == 0 or blk.size > limits.max_block) return error.NotApplicable;
                if (blk.start == 0 or blk.start + blk.size > info.coupling_start) return error.NotApplicable;
                for (blk.start..blk.start + blk.size) |i| {
                    if (node_block[i] != NONE) return error.NotApplicable; // overlap
                    node_block[i] = @intCast(bi);
                }
            }
            const border_pos = try gpa.alloc(u32, n);
            defer gpa.free(border_pos);
            @memset(border_pos, NONE);
            border_pos[0] = 0;
            for (0..info.coupling_size) |j| border_pos[info.coupling_start + j] = @intCast(j + 1);
            for (0..n) |i| {
                if (node_block[i] == NONE and border_pos[i] == NONE) return error.NotApplicable; // gap
            }

            // ---- pass 1: structural scan + per-block border footprints ----
            const sets = try gpa.alloc(std.ArrayList(u32), nb);
            defer {
                for (sets) |*s| s.deinit(gpa);
                gpa.free(sets);
            }
            for (sets) |*s| s.* = .empty;
            for (0..n) |c| {
                for (col_ptr[c]..col_ptr[c + 1]) |p| {
                    const r = row_idx[p];
                    const rb = node_block[r];
                    const cb = node_block[c];
                    if (rb != NONE and cb != NONE) {
                        if (rb != cb) return error.NotApplicable; // cross-block entry
                    } else if (rb != NONE) {
                        try addToSet(gpa, &sets[rb], border_pos[c]); // E entry
                    } else if (cb != NONE) {
                        try addToSet(gpa, &sets[cb], border_pos[r]); // F entry
                    } // else border-border: goes to s_dense
                }
            }
            for (sets) |*s| std.mem.sort(u32, s.items, {}, std.sort.asc(u32));

            // ---- layout: SoA block metadata ----
            const blk_start = try gpa.alloc(u32, nb);
            errdefer gpa.free(blk_start);
            const blk_s = try gpa.alloc(u32, nb);
            errdefer gpa.free(blk_s);
            const blk_m = try gpa.alloc(u32, nb);
            errdefer gpa.free(blk_m);
            const blk_a_off = try gpa.alloc(usize, nb);
            errdefer gpa.free(blk_a_off);
            const blk_w_off = try gpa.alloc(usize, nb);
            errdefer gpa.free(blk_w_off);
            const blk_f_off = try gpa.alloc(usize, nb);
            errdefer gpa.free(blk_f_off);
            const blk_piv_off = try gpa.alloc(usize, nb);
            errdefer gpa.free(blk_piv_off);
            const blk_loc_off = try gpa.alloc(usize, nb);
            errdefer gpa.free(blk_loc_off);

            var arena_len: usize = 0;
            var piv_len: usize = 0;
            var loc_len: usize = 0;
            for (info.blocks, sets, 0..) |ib, s, bi| {
                const sz: usize = ib.size;
                const m: usize = s.items.len;
                blk_start[bi] = ib.start;
                blk_s[bi] = ib.size;
                blk_m[bi] = @intCast(m);
                blk_a_off[bi] = arena_len;
                blk_w_off[bi] = arena_len + sz * sz;
                blk_f_off[bi] = arena_len + sz * sz + sz * m;
                blk_piv_off[bi] = piv_len;
                blk_loc_off[bi] = loc_len;
                arena_len += sz * sz + 2 * sz * m;
                piv_len += sz;
                loc_len += m;
            }
            const s_off = arena_len;
            arena_len += @as(usize, b) * b;
            // dst is u32-indexed; degenerate giant systems fall back to flat.
            if (arena_len > std.math.maxInt(u32)) return error.NotApplicable;

            const arena = try gpa.alloc(T, arena_len);
            errdefer gpa.free(arena);
            const piv = try gpa.alloc(u32, piv_len);
            errdefer gpa.free(piv);
            const s_piv = try gpa.alloc(u32, b);
            errdefer gpa.free(s_piv);
            const loc = try gpa.alloc(u32, loc_len);
            errdefer gpa.free(loc);
            const border_node = try gpa.alloc(u32, b);
            errdefer gpa.free(border_node);
            const bg = try gpa.alloc(T, b);
            errdefer gpa.free(bg);
            const dst_tape = try gpa.alloc(u32, col_ptr[n]);
            errdefer gpa.free(dst_tape);

            border_node[0] = 0;
            for (0..info.coupling_size) |j| border_node[j + 1] = info.coupling_start + @as(u32, @intCast(j));
            for (0..nb) |bi| @memcpy(loc[blk_loc_off[bi]..][0..blk_m[bi]], sets[bi].items);

            // ---- pass 2: scatter tape ----
            for (0..n) |c| {
                for (col_ptr[c]..col_ptr[c + 1]) |p| {
                    const r = row_idx[p];
                    const rb = node_block[r];
                    const cb = node_block[c];
                    var d: usize = undefined;
                    if (rb != NONE and cb != NONE) {
                        // block interior: A_i[r-start, c-start]
                        const bi = rb;
                        const st = blk_start[bi];
                        const sz = blk_s[bi];
                        d = blk_a_off[bi] + @as(usize, r - st) * sz + (c - st);
                    } else if (rb != NONE) {
                        // block row, border col: E -> W (col-major)
                        const bi = rb;
                        const st = blk_start[bi];
                        const lc = localIdx(loc[blk_loc_off[bi]..][0..blk_m[bi]], border_pos[c]);
                        d = blk_w_off[bi] + @as(usize, lc) * blk_s[bi] + (r - st);
                    } else if (cb != NONE) {
                        // border row, block col: F
                        const bi = cb;
                        const st = blk_start[bi];
                        const lr = localIdx(loc[blk_loc_off[bi]..][0..blk_m[bi]], border_pos[r]);
                        d = blk_f_off[bi] + @as(usize, lr) * blk_s[bi] + (c - st);
                    } else {
                        // border-border: S
                        d = s_off + @as(usize, border_pos[r]) * b + border_pos[c];
                    }
                    dst_tape[p] = @intCast(d);
                }
            }

            return .{
                .blk_start = blk_start,
                .blk_s = blk_s,
                .blk_m = blk_m,
                .blk_a_off = blk_a_off,
                .blk_w_off = blk_w_off,
                .blk_f_off = blk_f_off,
                .blk_piv_off = blk_piv_off,
                .blk_loc_off = blk_loc_off,
                .b = b,
                .nb = nb,
                .arena = arena,
                .s_off = s_off,
                .piv = piv,
                .s_piv = s_piv,
                .loc = loc,
                .border_node = border_node,
                .dst = dst_tape,
                .bg = bg,
                .gpa = gpa,
            };
        }

        pub fn deinit(self: *Self) void {
            const gpa = self.gpa;
            gpa.free(self.blk_start);
            gpa.free(self.blk_s);
            gpa.free(self.blk_m);
            gpa.free(self.blk_a_off);
            gpa.free(self.blk_w_off);
            gpa.free(self.blk_f_off);
            gpa.free(self.blk_piv_off);
            gpa.free(self.blk_loc_off);
            gpa.free(self.arena);
            gpa.free(self.piv);
            gpa.free(self.s_piv);
            gpa.free(self.loc);
            gpa.free(self.border_node);
            gpa.free(self.dst);
            gpa.free(self.bg);
            self.* = undefined;
        }

        /// Full numeric factor. gmin arrives already added to `vals` by
        /// newton.zig and flows through the tape. Serial fixed order —
        /// two factors of the same values are byte-identical.
        pub fn factor(self: *Self, vals: []const T) error{SingularMatrix}!void {
            return self.factorWithExecution(vals, .{});
        }

        pub fn factorWithExecution(self: *Self, vals: []const T, execution: root.Execution) error{SingularMatrix}!void {
            // Scatter: zero arena, then accumulate through tape.
            simdZero(self.arena);
            for (vals, self.dst) |v, d| self.arena[d] += v;

            const tasks = self.taskCount(execution);
            if (tasks > 1) try self.factorBlocksScheduled(execution.io.?, tasks);
            const nblocks = self.nb;
            const bsz: usize = self.b;
            const sd = self.arena[self.s_off..][0 .. bsz * bsz];
            // Reduce S -= F·W in block order after all independent work joins.
            for (0..nblocks) |bi| {
                // Keep freshly factored W hot for its reduction on the serial path.
                if (tasks == 1) try self.factorBlock(bi);
                const s: usize = self.blk_s[bi];
                const m: usize = self.blk_m[bi];
                const w = self.arena[self.blk_w_off[bi]..][0 .. s * m];

                // Fixed-order Schur reduction; each dot product is consumed once.
                const f = self.arena[self.blk_f_off[bi]..][0 .. m * s];
                const lo = self.loc[self.blk_loc_off[bi]..][0..m];
                for (lo, 0..) |gr, r| {
                    for (lo, 0..) |gc, c| {
                        sd[@as(usize, gr) * bsz + gc] -= dotSimd(f[r * s ..][0..s], w[c * s ..][0..s]);
                    }
                }
            }
            Dense.factorize(bsz, sd, self.s_piv) catch return error.SingularMatrix;
        }

        inline fn factorBlock(self: *const Self, bi: usize) error{SingularMatrix}!void {
            const s: usize = self.blk_s[bi];
            const m: usize = self.blk_m[bi];
            const a = self.arena[self.blk_a_off[bi]..][0 .. s * s];
            const pv = self.piv[self.blk_piv_off[bi]..][0..s];
            Dense.factorize(s, a, pv) catch return error.SingularMatrix;
            const w = self.arena[self.blk_w_off[bi]..][0 .. s * m];
            for (0..m) |j| {
                const col = w[j * s ..][0..s];
                Dense.solveFactored(s, a, pv, col, col);
            }
        }

        fn factorBlocks(self: *const Self, start: usize, end: usize) error{SingularMatrix}!void {
            for (start..end) |bi| try self.factorBlock(bi);
        }

        fn taskCount(self: *const Self, execution: root.Execution) usize {
            if (execution.io == null or execution.threads < 2) return 1;
            var work: u64 = 0;
            for (self.blk_s, self.blk_m) |s, m| work += @as(u64, s) * s * (s + 3 * @as(u64, m));
            return @intCast(@max(1, @min(execution.threads, 16, self.nb, work / 131_072)));
        }

        fn factorBlocksScheduled(self: *const Self, io: std.Io, tasks: usize) error{SingularMatrix}!void {
            // ponytail: at most 16 equal block ranges; use weighted ranges if
            // mixed block sizes make measured worker imbalance significant.
            var futures: [16]std.Io.Future(error{SingularMatrix}!void) = undefined;
            for (0..tasks) |i| {
                futures[i] = io.async(factorBlocks, .{ self, self.nb * i / tasks, self.nb * (i + 1) / tasks });
            }
            // All tasks must finish before a failure permits the caller to
            // release these slabs and switch to the scalar pivoting ladder.
            var result: error{SingularMatrix}!void = {};
            for (futures[0..tasks]) |*future| future.await(io) catch |err| {
                result = err;
            };
            return result;
        }

        /// x := A^-1 x. Block back-solves touch disjoint x slices; the
        /// border gather/scatter is serial fixed-order.
        pub fn solveInPlace(self: *Self, x: []T) void {
            self.solve(false, x);
        }

        /// x := A^-T x, via the stored factors. The transposed system's
        /// Schur complement is S^T, so the border solve is S^-T through
        /// dense_lu.solveFactoredT; W^T = E^T A^-T plays F's role and vice
        /// versa. Border reduction happens BEFORE block solves (uses raw
        /// b_i, not A^-T b_i — W already contains A^-1 E).
        pub fn solveTInPlace(self: *Self, x: []T) void {
            self.solve(true, x);
        }

        inline fn solve(self: *Self, comptime transpose: bool, x: []T) void {
            const bsz: usize = self.b;
            const sd = self.arena[self.s_off..][0 .. bsz * bsz];
            const nblocks = self.nb;

            // Forward solve uses y_i = A_i^-1 b_i; transpose uses raw b_i.
            if (!transpose) {
                for (0..nblocks) |bi| {
                    const s: usize = self.blk_s[bi];
                    const xi = x[self.blk_start[bi]..][0..s];
                    const a = self.arena[self.blk_a_off[bi]..][0 .. s * s];
                    Dense.solveFactored(s, a, self.piv[self.blk_piv_off[bi]..][0..s], xi, xi);
                }
            }

            // bg = b_g - Σ F_i y_i, or b_g - Σ W_i^T b_i for transpose.
            const reduce_off = if (transpose) self.blk_w_off else self.blk_f_off;
            for (0..bsz) |j| self.bg[j] = x[self.border_node[j]];
            for (0..nblocks) |bi| {
                const s: usize = self.blk_s[bi];
                const m: usize = self.blk_m[bi];
                const coupling = self.arena[reduce_off[bi]..][0 .. m * s];
                const lo = self.loc[self.blk_loc_off[bi]..][0..m];
                const xi = x[self.blk_start[bi]..][0..s];
                for (lo, 0..) |g, j| {
                    self.bg[g] -= dotSimd(coupling[j * s ..][0..s], xi);
                }
            }

            if (transpose)
                Dense.solveFactoredT(bsz, sd, self.s_piv, self.bg, self.bg)
            else
                Dense.solveFactored(bsz, sd, self.s_piv, self.bg, self.bg);
            for (0..bsz) |j| x[self.border_node[j]] = self.bg[j];

            // x_i = y_i - W_i xg_loc, or A_i^-T (b_i - F_i^T xg_loc).
            const subtract_off = if (transpose) self.blk_f_off else self.blk_w_off;
            for (0..nblocks) |bi| {
                const s: usize = self.blk_s[bi];
                const m: usize = self.blk_m[bi];
                const coupling = self.arena[subtract_off[bi]..][0 .. m * s];
                const lo = self.loc[self.blk_loc_off[bi]..][0..m];
                const xi = x[self.blk_start[bi]..][0..s];
                for (lo, 0..) |g, j| {
                    const xgj = self.bg[g];
                    if (xgj == 0) continue;
                    axpySimdNeg(xi, coupling[j * s ..][0..s], xgj);
                }
                if (transpose) {
                    const a = self.arena[self.blk_a_off[bi]..][0 .. s * s];
                    Dense.solveFactoredT(s, a, self.piv[self.blk_piv_off[bi]..][0..s], xi, xi);
                }
            }
        }

        // ---- SIMD kernels ----

        // Hot arena: vector stores beat builtin memset here; see the skills audit.
        inline fn simdZero(buf: []T) void {
            const zero: Vec = @splat(0);
            var i: usize = 0;
            while (i + VecLen <= buf.len) : (i += VecLen) {
                buf[i..][0..VecLen].* = zero;
            }
            for (buf[i..]) |*v| v.* = 0;
        }

        /// SIMD dot product of two contiguous slices of equal length.
        fn dotSimd(a: []const T, c: []const T) T {
            std.debug.assert(a.len == c.len);
            var acc: Vec = @splat(0);
            var i: usize = 0;
            while (i + VecLen <= a.len) : (i += VecLen) {
                const av: Vec = a[i..][0..VecLen].*;
                const cv: Vec = c[i..][0..VecLen].*;
                acc += av * cv;
            }
            var sum = @reduce(.Add, acc);
            while (i < a.len) : (i += 1) sum += a[i] * c[i];
            return sum;
        }

        /// SIMD x[i] -= w[i] * scalar (axpy with negation).
        fn axpySimdNeg(x: []T, w: []const T, scalar: T) void {
            std.debug.assert(x.len == w.len);
            const sv: Vec = @splat(scalar);
            var i: usize = 0;
            while (i + VecLen <= x.len) : (i += VecLen) {
                const xv: Vec = x[i..][0..VecLen].*;
                const wv: Vec = w[i..][0..VecLen].*;
                x[i..][0..VecLen].* = xv - wv * sv;
            }
            while (i < x.len) : (i += 1) x[i] -= w[i] * scalar;
        }
    };
}

/// Insert `v` into `s` if not already present (set semantics). Block
/// border footprints are tiny (handful of entries), so linear scan is fine.
fn addToSet(gpa: Allocator, s: *std.ArrayList(u32), v: u32) error{OutOfMemory}!void {
    // ponytail: stdlib lookup suffices for tiny footprints; use a bitset if they grow.
    if (std.mem.findScalar(u32, s.items, v) != null) return;
    try s.append(gpa, v);
}

/// Find position of `v` in a small sorted slice. Precondition: `v` is
/// present (ensured by pass 1 collecting every E/F border position).
fn localIdx(sorted: []const u32, v: u32) u32 {
    // ponytail: linear scan; m is tiny (handful of border nodes per block).
    // Upgrade path: binary search if max_border grows past ~64.
    return @intCast(std.mem.findScalar(u32, sorted, v) orelse unreachable);
}
