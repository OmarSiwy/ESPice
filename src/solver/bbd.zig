//! Bordered-block-diagonal LU for subcircuit-expanded netlists, whose
//! builder permutation puts each instance's internal nodes in one block and
//! the coupling nodes last:
//!
//!   [ A_1        E_1 ] [x_1]   [b_1]
//!   [     ...    ... ] [...] = [...]
//!   [        A_k E_k ] [x_k]   [b_k]
//!   [ F_1 ... F_k S  ] [x_g]   [b_g]
//!
//! Blocks are small, so each is factored dense (partial pivoting) and the
//! Schur complement S - sum F_i A_i^-1 E_i is reduced in fixed block order,
//! which keeps two factors of the same values byte-identical. Every factor
//! is a full dense factor; there is no pivot replay. Row/col 0 (ground)
//! sits outside every block and joins the border.

const std = @import("std");
const root = @import("core").numerics;
const dense_lu = @import("dense_lu.zig");

const Allocator = std.mem.Allocator;
const NONE: u32 = std.math.maxInt(u32);

/// `NotApplicable`: the split is unprofitable under `Limits`, or some CSC
/// entry couples two blocks (the builder never emits one).
pub const InitError = error{ NotApplicable, OutOfMemory };

/// Activation thresholds. The defaults are the production gates; tests relax
/// them to exercise small systems.
pub const Limits = struct {
    min_blocks: usize = 8,
    max_block: u32 = 64,
    max_border: u32 = 512,
};

/// BBD engine. All dense data lives in one arena:
/// per block i, A_i (s x s row-major), W_i (s x m column-major; E_i, then
/// A_i^-1 E_i after factor) and F_i (m x s row-major), then S (b x b). m is
/// the block's border footprint, the border nodes it touches, mapped by `loc`.
pub const Bbd = struct {
    const Self = @This();
    const VecLen = std.simd.suggestVectorLength(f64) orelse 1;
    const Vec = @Vector(VecLen, f64);

    // Per-block metadata, nb entries each.
    blk_start: []u32, // first global row/col
    blk_s: []u32, // block size s
    blk_m: []u32, // border footprint m
    blk_a_off: []u32, // arena offsets of A_i, W_i, F_i
    blk_w_off: []u32,
    blk_f_off: []u32,
    blk_piv_off: []u32, // offset into `piv`, s entries
    blk_loc_off: []u32, // offset into `loc`, m entries

    b: u32, // border size, >= 1 (ground)
    nb: u32,
    arena: []f64,
    s_off: u32, // arena offset of S
    piv: []u32,
    s_piv: []u32,
    loc: []u32, // footprint slot -> border position
    border_node: []u32, // border position -> global node
    dst: []u32, // CSC entry p -> arena index it accumulates into
    bg: []f64, // border scratch, b entries
    gpa: Allocator,

    /// Classifies the pattern against `info` and lays out the arena.
    /// Borrows nothing; `col_ptr`/`row_idx` may be freed afterwards.
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

        // Node -> block id, and node -> border position.
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

        // Pass 1: per-block border footprints.
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

        const blk_start = try gpa.alloc(u32, nb);
        errdefer gpa.free(blk_start);
        const blk_s = try gpa.alloc(u32, nb);
        errdefer gpa.free(blk_s);
        const blk_m = try gpa.alloc(u32, nb);
        errdefer gpa.free(blk_m);
        const blk_a_off = try gpa.alloc(u32, nb);
        errdefer gpa.free(blk_a_off);
        const blk_w_off = try gpa.alloc(u32, nb);
        errdefer gpa.free(blk_w_off);
        const blk_f_off = try gpa.alloc(u32, nb);
        errdefer gpa.free(blk_f_off);
        const blk_piv_off = try gpa.alloc(u32, nb);
        errdefer gpa.free(blk_piv_off);
        const blk_loc_off = try gpa.alloc(u32, nb);
        errdefer gpa.free(blk_loc_off);

        // `dst` and the offsets are u32; a larger arena falls back to the
        // flat LU. Every offset is below the running `arena_len`.
        const arena_max = std.math.maxInt(u32);
        var arena_len: usize = 0;
        // Blocks are disjoint row ranges and each footprint slot comes
        // from a CSC entry, so both sums stay below n and nnz.
        var piv_len: u32 = 0;
        var loc_len: u32 = 0;
        for (info.blocks, sets, 0..) |ib, s, bi| {
            const sz: usize = ib.size;
            const m: usize = s.items.len;
            const a_off = arena_len;
            arena_len += sz * sz + 2 * sz * m;
            if (arena_len > arena_max) return error.NotApplicable;
            blk_start[bi] = ib.start;
            blk_s[bi] = ib.size;
            blk_m[bi] = @intCast(m);
            blk_a_off[bi] = @intCast(a_off);
            blk_w_off[bi] = @intCast(a_off + sz * sz);
            blk_f_off[bi] = @intCast(a_off + sz * sz + sz * m);
            blk_piv_off[bi] = piv_len;
            blk_loc_off[bi] = loc_len;
            piv_len += ib.size;
            loc_len += @intCast(m);
        }
        const s_off: u32 = @intCast(arena_len);
        arena_len += @as(usize, b) * b;
        if (arena_len > arena_max) return error.NotApplicable;

        const arena = try gpa.alloc(f64, arena_len);
        errdefer gpa.free(arena);
        const piv = try gpa.alloc(u32, piv_len);
        errdefer gpa.free(piv);
        const s_piv = try gpa.alloc(u32, b);
        errdefer gpa.free(s_piv);
        const loc = try gpa.alloc(u32, loc_len);
        errdefer gpa.free(loc);
        const border_node = try gpa.alloc(u32, b);
        errdefer gpa.free(border_node);
        const bg = try gpa.alloc(f64, b);
        errdefer gpa.free(bg);
        const dst_tape = try gpa.alloc(u32, col_ptr[n]);
        errdefer gpa.free(dst_tape);

        border_node[0] = 0;
        for (0..info.coupling_size) |j| border_node[j + 1] = info.coupling_start + @as(u32, @intCast(j));
        for (0..nb) |bi| @memcpy(loc[blk_loc_off[bi]..][0..blk_m[bi]], sets[bi].items);

        // Pass 2: the scatter tape.
        for (0..n) |c| {
            for (col_ptr[c]..col_ptr[c + 1]) |p| {
                const r = row_idx[p];
                const rb = node_block[r];
                const cb = node_block[c];
                var d: usize = undefined;
                if (rb != NONE and cb != NONE) {
                    const bi = rb; // A_i
                    const st = blk_start[bi];
                    const sz = blk_s[bi];
                    d = blk_a_off[bi] + @as(usize, r - st) * sz + (c - st);
                } else if (rb != NONE) {
                    const bi = rb; // E_i, stored column-major in W_i
                    const st = blk_start[bi];
                    const lc = localIdx(loc[blk_loc_off[bi]..][0..blk_m[bi]], border_pos[c]);
                    d = blk_w_off[bi] + @as(usize, lc) * blk_s[bi] + (r - st);
                } else if (cb != NONE) {
                    const bi = cb; // F_i
                    const st = blk_start[bi];
                    const lr = localIdx(loc[blk_loc_off[bi]..][0..blk_m[bi]], border_pos[r]);
                    d = blk_f_off[bi] + @as(usize, lr) * blk_s[bi] + (c - st);
                } else {
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

    /// Full numeric factor of `vals` (CSC order). Block factors may run
    /// on `execution.io`; the Schur reduction is always serial in block
    /// order, so the result does not depend on the schedule. Fails when a
    /// block or S is singular; the arena is then unusable until the next
    /// successful factor.
    pub fn factorWithExecution(self: *Self, vals: []const f64, execution: root.Execution) error{SingularMatrix}!void {
        simdZero(self.arena);
        for (vals, self.dst) |v, d| self.arena[d] += v;

        const tasks = self.taskCount(execution);
        if (tasks > 1) try self.factorBlocksScheduled(execution.io.?, tasks);
        const nblocks = self.nb;
        const bsz: usize = self.b;
        const sd = self.arena[self.s_off..][0 .. bsz * bsz];
        for (0..nblocks) |bi| {
            // Serially, factor each block right before its reduction so W is hot.
            if (tasks == 1) try self.factorBlock(bi);
            const s: usize = self.blk_s[bi];
            const m: usize = self.blk_m[bi];
            const w = self.arena[self.blk_w_off[bi]..][0 .. s * m];

            const f = self.arena[self.blk_f_off[bi]..][0 .. m * s];
            const lo = self.loc[self.blk_loc_off[bi]..][0..m];
            for (lo, 0..) |gr, r| {
                for (lo, 0..) |gc, c| {
                    sd[@as(usize, gr) * bsz + gc] -= dotSimd(f[r * s ..][0..s], w[c * s ..][0..s]);
                }
            }
        }
        dense_lu.factorize(bsz, sd, self.s_piv) catch return error.SingularMatrix;
    }

    inline fn factorBlock(self: *const Self, bi: usize) error{SingularMatrix}!void {
        const s: usize = self.blk_s[bi];
        const m: usize = self.blk_m[bi];
        const a = self.arena[self.blk_a_off[bi]..][0 .. s * s];
        const pv = self.piv[self.blk_piv_off[bi]..][0..s];
        dense_lu.factorize(s, a, pv) catch return error.SingularMatrix;
        const w = self.arena[self.blk_w_off[bi]..][0 .. s * m];
        for (0..m) |j| {
            const col = w[j * s ..][0..s];
            dense_lu.solveFactored(s, a, pv, col, col);
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
        // ponytail: at most 16 equal block ranges; weight them by block
        // cost if mixed sizes ever show measurable worker imbalance.
        var futures: [16]std.Io.Future(error{SingularMatrix}!void) = undefined;
        for (0..tasks) |i| {
            futures[i] = io.async(factorBlocks, .{ self, self.nb * i / tasks, self.nb * (i + 1) / tasks });
        }
        // Join every task before reporting a failure: the caller frees
        // these slabs when it demotes to the flat LU.
        var result: error{SingularMatrix}!void = {};
        for (futures[0..tasks]) |*future| future.await(io) catch |err| {
            result = err;
        };
        return result;
    }

    /// x = A^-1 x after a successful factor.
    pub fn solveInPlace(self: *Self, x: []f64) void {
        self.solve(false, x);
    }

    /// x = A^-T x after a successful factor. The transposed Schur
    /// complement is S^T, and W^T = E^T A^-T takes F's role, so the
    /// border reduction reads the raw b_i before any block solve.
    pub fn solveTInPlace(self: *Self, x: []f64) void {
        self.solve(true, x);
    }

    inline fn solve(self: *Self, comptime transpose: bool, x: []f64) void {
        const bsz: usize = self.b;
        const sd = self.arena[self.s_off..][0 .. bsz * bsz];
        const nblocks = self.nb;

        // Forward solve uses y_i = A_i^-1 b_i; transpose uses raw b_i.
        if (!transpose) {
            for (0..nblocks) |bi| {
                const s: usize = self.blk_s[bi];
                const xi = x[self.blk_start[bi]..][0..s];
                const a = self.arena[self.blk_a_off[bi]..][0 .. s * s];
                dense_lu.solveFactored(s, a, self.piv[self.blk_piv_off[bi]..][0..s], xi, xi);
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
            dense_lu.solveFactoredT(bsz, sd, self.s_piv, self.bg, self.bg)
        else
            dense_lu.solveFactored(bsz, sd, self.s_piv, self.bg, self.bg);
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
                root.axpy(xi, -xgj, coupling[j * s ..][0..s]);
            }
            if (transpose) {
                const a = self.arena[self.blk_a_off[bi]..][0 .. s * s];
                dense_lu.solveFactoredT(s, a, self.piv[self.blk_piv_off[bi]..][0..s], xi, xi);
            }
        }
    }

    // Vector stores beat the memset call on this per-factor arena.
    inline fn simdZero(buf: []f64) void {
        const zero: Vec = @splat(0);
        var i: usize = 0;
        while (i + VecLen <= buf.len) : (i += VecLen) {
            buf[i..][0..VecLen].* = zero;
        }
        for (buf[i..]) |*v| v.* = 0;
    }

    fn dotSimd(a: []const f64, c: []const f64) f64 {
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
};

/// Appends `v` unless present.
fn addToSet(gpa: Allocator, s: *std.ArrayList(u32), v: u32) error{OutOfMemory}!void {
    // ponytail: linear scan over a few border nodes; a bitset if they grow.
    if (std.mem.findScalar(u32, s.items, v) != null) return;
    try s.append(gpa, v);
}

/// Position of `v` in a block footprint; pass 1 guarantees it is present.
fn localIdx(sorted: []const u32, v: u32) u32 {
    // ponytail: linear scan over a few border nodes; binary search if
    // footprints grow past ~64.
    return @intCast(std.mem.findScalar(u32, sorted, v) orelse unreachable);
}
