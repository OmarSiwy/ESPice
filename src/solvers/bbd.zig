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
//! then A_i^-1 E_i in place after factor), F_i (m_i×s row-major), U_i
//! (m_i×m_i Schur scratch). m_i is the block's LOCAL border footprint —
//! the set of border nodes it actually couples to — mapped by loc_i.
//!
//! Border set = {ground row 0} ∪ [coupling_start, n): row/col 0 is OUTSIDE
//! computeBbd's blocks and carries only the gmin'd diagonal, so it is
//! treated as a border node. Border membership is therefore an index list
//! (border_node), not a contiguous range.
//!
//! factor(vals): scatter flat CSC vals via a precomputed tape (src→dst
//! index pairs built once at init, the batch.zig `slots` idiom); per block
//! dense-LU A_i, solve W_i in place, U_i = F_i·W_i; serial fixed-order
//! Schur reduce into s_dense; dense-LU s_dense. No refactor/pivot replay:
//! dense re-factor per Newton iteration is trivially cheap at these sizes.
//! Everything is fixed-order serial → byte-identical re-factors.
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
const root = @import("root.zig");
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
        blk_u_off: []usize, // U_i offset: m×m Schur scratch
        blk_piv_off: []usize, // offset into piv slab, s entries
        blk_loc_off: []usize, // offset into loc slab, m entries

        n: u32,
        b: u32, // border size (>= 1: ground)
        nb: u32, // number of blocks
        arena: []T, // [A_i|W_i|F_i|U_i]* ++ s_dense
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
            simdFillU32(node_block, NONE);
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
            simdFillU32(border_pos, NONE);
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
            const blk_u_off = try gpa.alloc(usize, nb);
            errdefer gpa.free(blk_u_off);
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
                blk_u_off[bi] = arena_len + sz * sz + 2 * sz * m;
                blk_piv_off[bi] = piv_len;
                blk_loc_off[bi] = loc_len;
                arena_len += sz * sz + 2 * sz * m + m * m;
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
            for (0..nb) |bi| simdCopyU32(loc[blk_loc_off[bi]..][0..blk_m[bi]], sets[bi].items);

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
                .blk_u_off = blk_u_off,
                .blk_piv_off = blk_piv_off,
                .blk_loc_off = blk_loc_off,
                .n = n,
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
            gpa.free(self.blk_u_off);
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
            // Scatter: zero arena, then accumulate through tape.
            simdZero(self.arena);
            for (vals, self.dst) |v, d| self.arena[d] += v;

            const nblocks = self.nb;
            // Per-block: factorize A_i, solve W columns, compute U = F·W.
            for (0..nblocks) |bi| {
                const s: usize = self.blk_s[bi];
                const m: usize = self.blk_m[bi];
                const a = self.arena[self.blk_a_off[bi]..][0 .. s * s];
                const pv = self.piv[self.blk_piv_off[bi]..][0..s];
                Dense.factorize(s, a, pv) catch return error.SingularMatrix;

                // W_j = A^-1 E_j in place (column-major: each col contiguous)
                const w = self.arena[self.blk_w_off[bi]..][0 .. s * m];
                for (0..m) |j| {
                    const col = w[j * s ..][0..s];
                    Dense.solveFactored(s, a, pv, col, col);
                }

                // U = F·W: dot of F row r (contiguous s) with W col c (contiguous s)
                const f = self.arena[self.blk_f_off[bi]..][0 .. m * s];
                const u = self.arena[self.blk_u_off[bi]..][0 .. m * m];
                for (0..m) |r| {
                    for (0..m) |c| {
                        u[r * m + c] = dotSimd(f[r * s ..][0..s], w[c * s ..][0..s]);
                    }
                }
            }

            // Serial fixed-order Schur reduce: S -= Σ U_i
            const bsz: usize = self.b;
            const sd = self.arena[self.s_off..][0 .. bsz * bsz];
            for (0..nblocks) |bi| {
                const m: usize = self.blk_m[bi];
                const lo = self.loc[self.blk_loc_off[bi]..][0..m];
                const u = self.arena[self.blk_u_off[bi]..][0 .. m * m];
                for (lo, 0..) |gr, r| {
                    for (lo, 0..) |gc, c| {
                        sd[@as(usize, gr) * bsz + gc] -= u[r * m + c];
                    }
                }
            }
            Dense.factorize(bsz, sd, self.s_piv) catch return error.SingularMatrix;
        }

        /// x := A^-1 x. Block back-solves touch disjoint x slices; the
        /// border gather/scatter is serial fixed-order.
        pub fn solveInPlace(self: *Self, x: []T) void {
            const bsz: usize = self.b;
            const sd = self.arena[self.s_off..][0 .. bsz * bsz];
            const nblocks = self.nb;

            // 1. y_i = A_i^-1 b_i
            for (0..nblocks) |bi| {
                const s: usize = self.blk_s[bi];
                const xi = x[self.blk_start[bi]..][0..s];
                const a = self.arena[self.blk_a_off[bi]..][0 .. s * s];
                Dense.solveFactored(s, a, self.piv[self.blk_piv_off[bi]..][0..s], xi, xi);
            }

            // 2. bg = b_g - Σ F_i y_i
            for (0..bsz) |j| self.bg[j] = x[self.border_node[j]];
            for (0..nblocks) |bi| {
                const s: usize = self.blk_s[bi];
                const m: usize = self.blk_m[bi];
                const f = self.arena[self.blk_f_off[bi]..][0 .. m * s];
                const lo = self.loc[self.blk_loc_off[bi]..][0..m];
                const xi = x[self.blk_start[bi]..][0..s];
                for (lo, 0..) |g, j| {
                    self.bg[g] -= dotSimd(f[j * s ..][0..s], xi);
                }
            }

            // 3. xg = S^-1 bg, scatter
            Dense.solveFactored(bsz, sd, self.s_piv, self.bg, self.bg);
            for (0..bsz) |j| x[self.border_node[j]] = self.bg[j];

            // 4. x_i = y_i - W_i xg_loc
            for (0..nblocks) |bi| {
                const s: usize = self.blk_s[bi];
                const m: usize = self.blk_m[bi];
                const w = self.arena[self.blk_w_off[bi]..][0 .. m * s];
                const lo = self.loc[self.blk_loc_off[bi]..][0..m];
                const xi = x[self.blk_start[bi]..][0..s];
                for (lo, 0..) |g, j| {
                    const xgj = self.bg[g];
                    if (xgj == 0) continue;
                    axpySimdNeg(xi, w[j * s ..][0..s], xgj);
                }
            }
        }

        /// x := A^-T x, via the stored factors. The transposed system's
        /// Schur complement is S^T, so the border solve is S^-T through
        /// dense_lu.solveFactoredT; W^T = E^T A^-T plays F's role and vice
        /// versa. Border reduction happens BEFORE block solves (uses raw
        /// b_i, not A^-T b_i — W already contains A^-1 E).
        pub fn solveTInPlace(self: *Self, x: []T) void {
            const bsz: usize = self.b;
            const sd = self.arena[self.s_off..][0 .. bsz * bsz];
            const nblocks = self.nb;

            // 1. bg = b_g - Σ W_i^T b_i  (= b_g - Σ E_i^T A_i^-T b_i)
            for (0..bsz) |j| self.bg[j] = x[self.border_node[j]];
            for (0..nblocks) |bi| {
                const s: usize = self.blk_s[bi];
                const m: usize = self.blk_m[bi];
                const w = self.arena[self.blk_w_off[bi]..][0 .. m * s];
                const lo = self.loc[self.blk_loc_off[bi]..][0..m];
                const xi = x[self.blk_start[bi]..][0..s];
                for (lo, 0..) |g, c| {
                    self.bg[g] -= dotSimd(w[c * s ..][0..s], xi);
                }
            }

            // 2. xg = S^-T bg, scatter
            Dense.solveFactoredT(bsz, sd, self.s_piv, self.bg, self.bg);
            for (0..bsz) |j| x[self.border_node[j]] = self.bg[j];

            // 3. x_i = A_i^-T (b_i - F_i^T xg_loc)
            for (0..nblocks) |bi| {
                const s: usize = self.blk_s[bi];
                const m: usize = self.blk_m[bi];
                const f = self.arena[self.blk_f_off[bi]..][0 .. m * s];
                const lo = self.loc[self.blk_loc_off[bi]..][0..m];
                const xi = x[self.blk_start[bi]..][0..s];
                for (lo, 0..) |g, j| {
                    const xgj = self.bg[g];
                    if (xgj == 0) continue;
                    axpySimdNeg(xi, f[j * s ..][0..s], xgj);
                }
                const a = self.arena[self.blk_a_off[bi]..][0 .. s * s];
                Dense.solveFactoredT(s, a, self.piv[self.blk_piv_off[bi]..][0..s], xi, xi);
            }
        }

        // ---- SIMD kernels ----

        const W32 = std.simd.suggestVectorLength(u32) orelse 1;
        const V32 = @Vector(W32, u32);

        /// SIMD zero-fill a contiguous T buffer.
        inline fn simdZero(buf: []T) void {
            const zero: Vec = @splat(0);
            var i: usize = 0;
            while (i + VecLen <= buf.len) : (i += VecLen) {
                buf[i..][0..VecLen].* = zero;
            }
            for (buf[i..]) |*v| v.* = 0;
        }

        /// SIMD fill u32 buffer with a constant value.
        fn simdFillU32(buf: []u32, val: u32) void {
            const fill: V32 = @splat(val);
            var i: usize = 0;
            while (i + W32 <= buf.len) : (i += W32) {
                buf[i..][0..W32].* = fill;
            }
            for (buf[i..]) |*v| v.* = val;
        }

        /// SIMD copy u32 buffer.
        fn simdCopyU32(dst: []u32, src: []const u32) void {
            var i: usize = 0;
            while (i + W32 <= dst.len) : (i += W32) {
                dst[i..][0..W32].* = src[i..][0..W32].*;
            }
            for (dst[i..], src[i..]) |*d, s| d.* = s;
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
    for (s.items) |e| {
        if (e == v) return;
    }
    try s.append(gpa, v);
}

/// Find position of `v` in a small sorted slice. Precondition: `v` is
/// present (ensured by pass 1 collecting every E/F border position).
fn localIdx(sorted: []const u32, v: u32) u32 {
    // ponytail: linear scan; m is tiny (handful of border nodes per block).
    // Upgrade path: binary search if max_border grows past ~64.
    for (sorted, 0..) |e, i| {
        if (e == v) return @intCast(i);
    }
    unreachable;
}

// ============================================================================
// Tests — synthetic BBD systems validated against the flat sparse LU through
// the public direct.Solver facade (bbd=null → flat path).
// ============================================================================

const testing = std.testing;
const direct = @import("direct.zig");

/// Synthetic BBD system: ground node 0, `nb` blocks of size `s`, `ncpl`
/// coupling nodes at the end. Deterministic values from a seeded PRNG;
/// diagonally dominant so both paths factor without drama.
const Synth = struct {
    n: u32,
    dense: []f64,
    col_ptr: []u32,
    row_idx: []u32,
    vals: []f64,
    info: root.BbdInfo,

    fn build(gpa: Allocator, nb: u32, s: u32, ncpl: u32, seed: u64, opts: struct {
        decoupled_block: ?u32 = null, // this block gets no E/F entries (m=0)
        singular_block: ?u32 = null, // this block's A_i is rank-deficient
        cross_entry: bool = false, // add a block-1 <-> block-0 entry
    }) !Synth {
        const n = 1 + nb * s + ncpl;
        const dense = try gpa.alloc(f64, @as(usize, n) * n);
        @memset(dense, 0);
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();

        dense[0] = 1.0; // ground diagonal (gmin'd)
        const cs = 1 + nb * s; // coupling_start
        const blocks = try gpa.alloc(root.BbdBlock, nb);
        for (0..nb) |bi| {
            const st = 1 + @as(u32, @intCast(bi)) * s;
            blocks[bi] = .{ .start = st, .size = s, .type_id = 0, .instance_id = @intCast(bi + 1) };
            // block interior: dense-ish, diagonally dominant
            for (0..s) |i| {
                for (0..s) |j| {
                    const v = rnd.float(f64) - 0.5;
                    dense[(st + i) * n + (st + j)] = if (i == j) v + @as(f64, @floatFromInt(s)) + 2 else v;
                }
            }
            if (opts.singular_block) |sb| {
                if (sb == bi and s >= 2) {
                    // rows 0 and 1 identical -> A_i singular (full matrix
                    // stays regular through the border coupling)
                    for (0..s) |j| dense[(st + 1) * n + (st + j)] = dense[(st + 0) * n + (st + j)];
                }
            }
            if (opts.decoupled_block != null and opts.decoupled_block.? == bi) continue;
            if (ncpl > 0) {
                // asymmetric E/F so solveT is a real test
                for (0..s) |k| {
                    const cp = cs + @as(u32, @intCast(k % ncpl));
                    dense[(st + k) * n + cp] = 0.25 * (rnd.float(f64) - 0.5); // E
                    dense[cp * n + (st + k)] = 0.25 * (rnd.float(f64) - 0.5); // F
                }
            }
        }
        // border-border: dominant diagonal + a few off-diagonals
        for (0..ncpl) |i| {
            dense[(cs + i) * n + (cs + i)] = 4 + rnd.float(f64);
            if (i + 1 < ncpl) dense[(cs + i) * n + (cs + i + 1)] = 0.3 * (rnd.float(f64) - 0.5);
        }
        if (opts.cross_entry and nb >= 2) {
            dense[blocks[1].start * n + blocks[0].start] = 0.1;
        }

        var self = Synth{
            .n = n,
            .dense = dense,
            .col_ptr = undefined,
            .row_idx = undefined,
            .vals = undefined,
            .info = .{ .blocks = blocks, .coupling_start = cs, .coupling_size = ncpl },
        };
        // dense -> CSC
        var nnz: usize = 0;
        for (dense) |v| nnz += @intFromBool(v != 0);
        self.col_ptr = try gpa.alloc(u32, n + 1);
        self.row_idx = try gpa.alloc(u32, nnz);
        self.vals = try gpa.alloc(f64, nnz);
        var p: u32 = 0;
        self.col_ptr[0] = 0;
        for (0..n) |j| {
            for (0..n) |i| {
                const v = dense[i * n + j];
                if (v != 0) {
                    self.row_idx[p] = @intCast(i);
                    self.vals[p] = v;
                    p += 1;
                }
            }
            self.col_ptr[j + 1] = p;
        }
        return self;
    }

    fn free(self: *Synth, gpa: Allocator) void {
        gpa.free(self.dense);
        gpa.free(self.col_ptr);
        gpa.free(self.row_idx);
        gpa.free(self.vals);
        gpa.free(self.info.blocks);
    }

    fn rhs(self: *const Synth, gpa: Allocator) ![]f64 {
        const r = try gpa.alloc(f64, self.n);
        for (r, 0..) |*ri, i| ri.* = @as(f64, @floatFromInt(i % 7)) - 3.0;
        return r;
    }
};

const relaxed = Limits{ .min_blocks = 2 };

fn expectMatchesFlat(gpa: Allocator, sy: *const Synth, eng: *Bbd(f64)) !void {
    var flat = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, null);
    defer flat.deinit();
    try flat.factor(sy.vals);
    try eng.factor(sy.vals);

    const b_rhs = try sy.rhs(gpa);
    defer gpa.free(b_rhs);
    const x_ref = try gpa.alloc(f64, sy.n);
    defer gpa.free(x_ref);
    const x = try gpa.alloc(f64, sy.n);
    defer gpa.free(x);

    flat.solve(b_rhs, x_ref);
    @memcpy(x, b_rhs);
    eng.solveInPlace(x);
    for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);

    flat.solveT(b_rhs, x_ref);
    @memcpy(x, b_rhs);
    eng.solveTInPlace(x);
    for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);
}

test "bbd: 3-block + border matches flat LU (solve + solveT)" {
    const gpa = testing.allocator;
    var sy = try Synth.build(gpa, 3, 4, 3, 42, .{});
    defer sy.free(gpa);
    var eng = try Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
    defer eng.deinit();
    try expectMatchesFlat(gpa, &sy, &eng);
}

test "bbd: block with empty border footprint (m_i = 0)" {
    const gpa = testing.allocator;
    var sy = try Synth.build(gpa, 3, 4, 3, 7, .{ .decoupled_block = 1 });
    defer sy.free(gpa);
    var eng = try Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
    defer eng.deinit();
    try testing.expectEqual(@as(u32, 0), eng.blk_m[1]);
    try expectMatchesFlat(gpa, &sy, &eng);
}

test "bbd: b = 1 (ground-only border, fully decoupled blocks)" {
    const gpa = testing.allocator;
    var sy = try Synth.build(gpa, 4, 3, 0, 11, .{});
    defer sy.free(gpa);
    var eng = try Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
    defer eng.deinit();
    try testing.expectEqual(@as(u32, 1), eng.b);
    try expectMatchesFlat(gpa, &sy, &eng);
}

test "bbd: singular block reports SingularMatrix from factor" {
    const gpa = testing.allocator;
    var sy = try Synth.build(gpa, 3, 4, 3, 13, .{ .singular_block = 1 });
    defer sy.free(gpa);
    var eng = try Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
    defer eng.deinit();
    try testing.expectError(error.SingularMatrix, eng.factor(sy.vals));
}

test "bbd: cross-block entry -> NotApplicable" {
    const gpa = testing.allocator;
    var sy = try Synth.build(gpa, 3, 4, 3, 17, .{ .cross_entry = true });
    defer sy.free(gpa);
    try testing.expectError(
        error.NotApplicable,
        Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed),
    );
}

test "bbd: production limits reject small block counts" {
    const gpa = testing.allocator;
    var sy = try Synth.build(gpa, 3, 4, 3, 19, .{});
    defer sy.free(gpa);
    try testing.expectError(
        error.NotApplicable,
        Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, .{}),
    );
}

test "bbd: determinism -- two factors of the same values are byte-identical" {
    const gpa = testing.allocator;
    var sy = try Synth.build(gpa, 3, 4, 3, 23, .{});
    defer sy.free(gpa);
    var eng = try Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
    defer eng.deinit();

    try eng.factor(sy.vals);
    const snap_arena = try gpa.dupe(f64, eng.arena);
    defer gpa.free(snap_arena);
    const snap_piv = try gpa.dupe(u32, eng.piv);
    defer gpa.free(snap_piv);
    const snap_spiv = try gpa.dupe(u32, eng.s_piv);
    defer gpa.free(snap_spiv);

    try eng.factor(sy.vals);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(snap_arena), std.mem.sliceAsBytes(eng.arena));
    try testing.expectEqualSlices(u32, snap_piv, eng.piv);
    try testing.expectEqualSlices(u32, snap_spiv, eng.s_piv);
}

test "bbd: facade activates BBD at >= 8 blocks and matches flat" {
    const gpa = testing.allocator;
    var sy = try Synth.build(gpa, 8, 5, 4, 29, .{});
    defer sy.free(gpa);

    var s_bbd = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info);
    defer s_bbd.deinit();
    try testing.expect(s_bbd.bbd_eng != null);
    var s_flat = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, null);
    defer s_flat.deinit();

    try s_bbd.factor(sy.vals);
    try s_flat.factor(sy.vals);

    const b_rhs = try sy.rhs(gpa);
    defer gpa.free(b_rhs);
    const x = try gpa.alloc(f64, sy.n);
    defer gpa.free(x);
    const x_ref = try gpa.alloc(f64, sy.n);
    defer gpa.free(x_ref);

    s_flat.solve(b_rhs, x_ref);
    s_bbd.solve(b_rhs, x);
    for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);

    s_flat.solveNeg(b_rhs, x_ref);
    s_bbd.solveNeg(b_rhs, x);
    for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);

    s_flat.solveT(b_rhs, x_ref);
    s_bbd.solveT(b_rhs, x);
    for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);
}

test "bbd: facade falls back to flat permanently on a singular block" {
    const gpa = testing.allocator;
    var sy = try Synth.build(gpa, 8, 5, 4, 31, .{ .singular_block = 2 });
    defer sy.free(gpa);

    var s = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info);
    defer s.deinit();
    try testing.expect(s.bbd_eng != null);

    // block 2 singular but the full matrix is regular through the border:
    // factor must succeed via the flat fallback
    try s.factor(sy.vals);
    try testing.expect(s.bbd_eng == null);
    try testing.expect(s.lu != null);

    var flat = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, null);
    defer flat.deinit();
    try flat.factor(sy.vals);

    const b_rhs = try sy.rhs(gpa);
    defer gpa.free(b_rhs);
    const x = try gpa.alloc(f64, sy.n);
    defer gpa.free(x);
    const x_ref = try gpa.alloc(f64, sy.n);
    defer gpa.free(x_ref);
    flat.solve(b_rhs, x_ref);
    s.solve(b_rhs, x);
    for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);

    // second factor stays flat (refactor path) and still works
    try s.factor(sy.vals);
    try testing.expect(s.bbd_eng == null);
    s.solve(b_rhs, x);
    for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);
}
