//! (G + jωC) x = b solves in the stacked-real form [G, -ωC; ωC, G], dense
//! for small circuits and sparse above. The sparse 2n pattern is derived once
//! from the circuit CSC, so each frequency's fill is a streamed copy of the G
//! and C planes. Batches of frequencies run as SIMD lanes through LaneLu.

const std = @import("std");
const dense_lu = @import("dense_lu.zig");
const direct = @import("direct.zig");
const lane_lu = @import("lane_lu.zig");

const Allocator = std.mem.Allocator;

// Dense only wins for tiny systems. medium/ladder_filter (n = 41) spent 90%
// of its run in dense 82^3/3 factors per omega; the sparse refactor is O(nnz).
const DENSE_THRESHOLD: u32 = 16;

/// The part of A(ω) beyond G + jωC over the ω of one `solveBatch` call:
/// entry e adds re + j·im at source CSC slot `slots[e]`, its term at
/// `omegas[k]` being `re[e * omegas.len + k]` and `im[...]`. A slot at or past
/// the pattern's nnz (a ground entry) adds nothing. The default is empty.
pub const Dyn = struct {
    slots: []const u32 = &.{},
    re: []const f64 = &.{},
    im: []const f64 = &.{},

    /// Entry e's term at ω index k.
    fn at(self: Dyn, e: usize, k: usize) struct { re: f64, im: f64 } {
        const i = e * (self.re.len / self.slots.len) + k;
        return .{ .re = self.re[i], .im = self.im[i] };
    }
};

/// Frequency-domain solver. Solution and right-hand side
/// vectors are length 2n: real parts, then imaginary parts.
pub const FreqSolver = struct {
    const Self = @This();
    const W = std.simd.suggestVectorLength(f64) orelse 1;

    n: u32,
    nn: u32,
    strategy: Strategy,

    const Strategy = union(enum) {
        dense: Dense,
        sp: Sparse,
    };

    /// n <= DENSE_THRESHOLD: owned n x n row-major G and C, assembled per
    /// frequency into the reused 2n x 2n LU slab. The borrowed source
    /// pattern places `Dyn` entries; empty from `initDense`.
    const Dense = struct {
        src_col_ptr: []const u32 = &.{},
        src_row_idx: []const u32 = &.{},
        g_dense: []f64,
        c_mat: []f64,
        a_lu: []f64,
        piv: []u32,
    };

    /// Owns the 2n stacked-real CSC, its solver and a snapshot of the
    /// circuit's G and C planes; borrows only the frozen source pattern.
    const Sparse = struct {
        g_vals: []f64,
        c_vals: []f64,
        src_col_ptr: []const u32,
        col_ptr: []u32,
        row_idx: []u32,
        vals: []f64,
        slv: direct.Solver,
        /// Lane scratch: one vector per structural entry, then the RHS
        /// and solution planes. Allocated by the first `solveBatch`.
        lane_work: []@Vector(W, f64) = &.{},
        lanes: ?lane_lu.LaneLu(W) = null,
    };

    /// Linearizes `ckt` at `x_op` (one eval; its G and C planes are the
    /// linearization) and builds the solver from copies of them, so the
    /// circuit may be re-evaluated afterwards. The sparse path borrows
    /// the circuit's CSC pattern for the solver's lifetime.
    pub fn fromCircuit(allocator: Allocator, ckt: anytype, x_op: []const f64) !Self {
        try ckt.linearizeAc(x_op);
        const n: u32 = @intCast(ckt.n);

        if (n <= DENSE_THRESHOLD) {
            const nu: usize = n;
            const g = try allocator.alloc(f64, nu * nu);
            ckt.denseG(g);
            const c = allocator.alloc(f64, nu * nu) catch |err| {
                allocator.free(g);
                return err;
            };
            ckt.denseC(c);
            var fs = try initDense(allocator, n, g, c);
            fs.strategy.dense.src_col_ptr = ckt.col_ptr;
            fs.strategy.dense.src_row_idx = ckt.row_idx;
            return fs;
        }

        return initSparse(allocator, n, ckt);
    }

    fn initSparse(allocator: Allocator, n: u32, ckt: anytype) !Self {
        const nn: u32 = 2 * n;
        const src_nnz: usize = ckt.nnz;
        const total_nnz: usize = 4 * src_nnz;

        const col_ptr = try allocator.alloc(u32, @as(usize, nn) + 1);
        errdefer allocator.free(col_ptr);
        const row_idx = try allocator.alloc(u32, total_nnz);
        errdefer allocator.free(row_idx);
        const vals = try allocator.alloc(f64, total_nnz);
        errdefer allocator.free(vals);
        const g_vals = try allocator.dupe(f64, ckt.g_vals[0..src_nnz]);
        errdefer allocator.free(g_vals);
        const c_vals = try allocator.dupe(f64, ckt.c_vals[0..src_nnz]);
        errdefer allocator.free(c_vals);

        buildStackedRealPattern(n, ckt.col_ptr, ckt.row_idx, col_ptr, row_idx);

        var slv = try direct.Solver.init(allocator, nn, col_ptr, row_idx, null);
        errdefer slv.deinit();

        return .{
            .n = n,
            .nn = nn,
            .strategy = .{ .sp = .{
                .g_vals = g_vals,
                .c_vals = c_vals,
                .src_col_ptr = ckt.col_ptr,
                .col_ptr = col_ptr,
                .row_idx = row_idx,
                .vals = vals,
                .slv = slv,
            } },
        };
    }

    /// Dense solver over row-major n x n `g` and `c`, allocated with
    /// `allocator`; takes ownership of both, also on error.
    pub fn initDense(allocator: Allocator, n: u32, g: []f64, c: []f64) !Self {
        errdefer allocator.free(g);
        errdefer allocator.free(c);
        const nn: u32 = 2 * n;
        const nnu: usize = nn;
        const a_lu = try allocator.alloc(f64, nnu * nnu);
        errdefer allocator.free(a_lu);
        const piv = try allocator.alloc(u32, nnu);

        return .{
            .n = n,
            .nn = nn,
            .strategy = .{ .dense = .{
                .g_dense = g,
                .c_mat = c,
                .a_lu = a_lu,
                .piv = piv,
            } },
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        switch (self.strategy) {
            .dense => |*d| {
                allocator.free(d.g_dense);
                allocator.free(d.c_mat);
                allocator.free(d.a_lu);
                allocator.free(d.piv);
            },
            .sp => |*s| {
                if (s.lanes) |*l| l.deinit(allocator);
                allocator.free(s.lane_work);
                s.slv.deinit();
                allocator.free(s.col_ptr);
                allocator.free(s.row_idx);
                allocator.free(s.vals);
                allocator.free(s.g_vals);
                allocator.free(s.c_vals);
            },
        }
    }

    /// `setOmega` then `solveRhs`.
    pub fn solve(self: *Self, omega: f64, rhs: []const f64, x_out: []f64) !void {
        try self.setOmega(omega);
        try self.solveRhs(rhs, x_out);
    }

    /// Assembles and factors G + jωC. Right-hand sides at this ω then
    /// need only `solveRhs`/`solveRhsT`.
    pub fn setOmega(self: *Self, omega: f64) !void {
        try self.setOmegaDyn(omega, .{}, 0);
    }

    /// `setOmega` plus `dyn`'s terms at ω index `k`.
    fn setOmegaDyn(self: *Self, omega: f64, dyn: Dyn, k: usize) !void {
        switch (self.strategy) {
            .dense => |*d| try setOmegaDense(self.n, self.nn, d, omega, dyn, k),
            .sp => |*s| try setOmegaSparse(self.n, s, omega, dyn, k),
        }
    }

    /// Solves with the current factorization. `rhs` and `x_out` may alias.
    pub fn solveRhs(self: *Self, rhs: []const f64, x_out: []f64) !void {
        switch (self.strategy) {
            .dense => |*d| dense_lu.solveFactored(self.nn, d.a_lu, d.piv, rhs, x_out),
            .sp => |*s| s.slv.solve(rhs, x_out),
        }
    }

    /// Adjoint solve A^T x = rhs with the current factorization.
    pub fn solveRhsT(self: *Self, rhs: []const f64, x_out: []f64) !void {
        switch (self.strategy) {
            .dense => |*d| dense_lu.solveFactoredT(self.nn, d.a_lu, d.piv, rhs, x_out),
            .sp => |*s| s.slv.solveT(rhs, x_out),
        }
    }

    /// Adds `v` to entry (i, i) of the solver's copy of G; the circuit is
    /// untouched. Call it before the first solve: a factorization already
    /// held does not see it.
    pub fn addDiagG(self: *Self, i: u32, v: f64) void {
        switch (self.strategy) {
            .dense => |*d| d.g_dense[@as(usize, i) * self.n + i] += v,
            .sp => |*s| {
                // Stacked column i opens with source column i's rows.
                const cs = s.src_col_ptr[i];
                const rows = s.row_idx[s.col_ptr[i]..][0 .. s.src_col_ptr[i + 1] - cs];
                // Circuit.freeze guarantees every diagonal is in the pattern.
                s.g_vals[cs + std.mem.indexOfScalar(u32, rows, i).?] += v;
            },
        }
    }

    /// Solves every ω in `omegas` against each right-hand side in `rhs`
    /// (nr stacked 2n vectors), with `dyn`'s terms added to each A(ω), W
    /// frequencies per LaneLu pass;
    /// `x_out[(k*nr + r)*2n..][0..2n]` receives ω_k for rhs r, so one
    /// factorization serves every rhs. `adjoint` selects A^T. The dense
    /// strategy, a non-LU engine and any lane whose refactor fails take the
    /// per-ω scalar path. The scalar factorization afterwards holds some ω
    /// of the batch.
    pub fn solveBatch(self: *Self, omegas: []const f64, dyn: Dyn, rhs: []const f64, x_out: []f64, adjoint: bool) !void {
        const nn: usize = self.nn;
        const m = rhs.len;
        std.debug.assert(m > 0 and m % nn == 0);
        std.debug.assert(x_out.len == omegas.len * m);
        if (omegas.len == 0) return;
        std.debug.assert(dyn.re.len == dyn.slots.len * omegas.len and dyn.im.len == dyn.re.len);
        const sp: *Sparse = switch (self.strategy) {
            .sp => |*s| s,
            .dense => return self.solveBatchSerial(omegas, dyn, 0, omegas.len, rhs, x_out, adjoint),
        };

        const gpa = sp.slv.gpa;
        const LL = lane_lu.LaneLu(W);
        const nnz2 = sp.vals.len; // structural entries in the 2n CSC
        if (sp.lane_work.len == 0)
            sp.lane_work = try gpa.alloc(@Vector(W, f64), nnz2 + 2 * nn);
        const vplane = sp.lane_work[0..nnz2];
        const b_plane = sp.lane_work[nnz2..][0..nn];
        const x_plane = sp.lane_work[nnz2 + nn ..];

        var base: usize = 0;
        while (base < omegas.len) : (base += W) {
            const cnt = @min(W, omegas.len - base);
            // Pad a ragged tail by repeating its last ω.
            var ow: [W]f64 = undefined;
            for (0..W) |l| ow[l] = omegas[base + @min(l, cnt - 1)];
            const omega_vec: @Vector(W, f64) = ow;

            // The lanes replay the current pivot sequence; only the first
            // chunk, or one after a failed factor, pays a scalar factor.
            // A lane whose pivots decay fails the scalar growth monitor,
            // and its serial full factor repivots for the next chunk.
            if (!sp.slv.factored) setOmegaSparse(self.n, sp, ow[cnt / 2], dyn, base + cnt / 2) catch {
                try self.solveBatchSerial(omegas, dyn, base, cnt, rhs, x_out, adjoint);
                continue;
            };
            // LaneLu replays SparseLu only, not the tridiagonal engine.
            const lu = if (sp.slv.lu) |*l| l else {
                try self.solveBatchSerial(omegas, dyn, base, cnt, rhs, x_out, adjoint);
                continue;
            };

            // A full factor can change the L/U lengths; rebuild then.
            if (sp.lanes) |*l| {
                if (l.lx.len != lu.lx.items.len or l.ux.len != lu.ux.items.len) {
                    l.deinit(gpa);
                    sp.lanes = null;
                }
            }
            if (sp.lanes == null) sp.lanes = try LL.init(gpa, lu);
            sp.lanes.?.base = lu;

            fillLanePlane(self.n, sp, omega_vec, vplane);
            addDynLanes(sp.src_col_ptr, dyn, base, cnt, vplane);
            const growth = sp.slv.params.refactor_growth_limit;
            const bad = sp.lanes.?.refactor(sp.col_ptr, vplane, growth);

            var r: usize = 0;
            while (r < m) : (r += nn) {
                for (rhs[r..][0..nn], b_plane) |value, *lane| lane.* = @splat(value);
                if (adjoint) sp.lanes.?.solveT(b_plane, x_plane) else sp.lanes.?.solve(b_plane, x_plane);
                for (0..cnt) |l| {
                    if ((bad & (@as(u64, 1) << @intCast(l))) != 0) continue;
                    const dst = x_out[(base + l) * m + r ..][0..nn];
                    for (0..nn) |i| {
                        const row: [W]f64 = x_plane[i];
                        dst[i] = row[l];
                    }
                }
            }
            // After every lane solve: a failed lane's full factor may
            // repivot the tape the lanes replay.
            for (0..cnt) |l| if ((bad & (@as(u64, 1) << @intCast(l))) != 0)
                try self.solveBatchSerial(omegas, dyn, base + l, 1, rhs, x_out, adjoint);
        }
    }

    pub const test_access = if (@import("builtin").is_test) .{
        .W = W,
        .solveBatchSerial = solveBatchSerial,
        .setOmegaSparse = setOmegaSparse,
        .fillLanePlane = fillLanePlane,
        .addDynLanes = addDynLanes,
    } else {};

    /// The lane path's oracle: `setOmega` with `dyn` and a solve per ω, over
    /// `omegas[first..][0..count]`, into the `x_out` rows `solveBatch` uses.
    fn solveBatchSerial(self: *Self, omegas: []const f64, dyn: Dyn, first: usize, count: usize, rhs: []const f64, x_out: []f64, adjoint: bool) !void {
        const nn: usize = self.nn;
        const m = rhs.len;
        for (first..first + count) |k| {
            try self.setOmegaDyn(omegas[k], dyn, k);
            var r: usize = 0;
            while (r < m) : (r += nn) {
                const b = rhs[r..][0..nn];
                const x = x_out[k * m + r ..][0..nn];
                if (adjoint) try self.solveRhsT(b, x) else try self.solveRhs(b, x);
            }
        }
    }

    /// `setOmegaSparse`'s fill for W frequencies at once, in the same
    /// entry order and with the same products, so each lane is bitwise
    /// the scalar fill.
    fn fillLanePlane(n: u32, s: *Sparse, omega: @Vector(W, f64), out: []@Vector(W, f64)) void {
        const nu: usize = n;
        const neg_omega = -omega;
        var p: usize = 0;
        for (0..nu) |j| {
            const cs = s.src_col_ptr[j];
            const len: usize = s.src_col_ptr[j + 1] - cs;
            for (0..len) |q| out[p + q] = @splat(s.g_vals[cs + q]);
            p += len;
            for (0..len) |q| out[p + q] = omega * @as(@Vector(W, f64), @splat(s.c_vals[cs + q]));
            p += len;
        }
        for (0..nu) |j| {
            const cs = s.src_col_ptr[j];
            const len: usize = s.src_col_ptr[j + 1] - cs;
            for (0..len) |q| out[p + q] = neg_omega * @as(@Vector(W, f64), @splat(s.c_vals[cs + q]));
            p += len;
            for (0..len) |q| out[p + q] = @splat(s.g_vals[cs + q]);
            p += len;
        }
    }

    /// `setOmegaSparse`'s `dyn` adds for ω indices `base + l`, l < W, a
    /// ragged tail (l >= cnt) repeating its last ω as `solveBatch` pads it.
    /// Same entry order and operations, so each lane is bitwise the scalar
    /// fill.
    fn addDynLanes(src_col_ptr: []const u32, dyn: Dyn, base: usize, cnt: usize, out: []@Vector(W, f64)) void {
        const nnz = src_col_ptr[src_col_ptr.len - 1];
        for (dyn.slots, 0..) |slot, e| {
            if (slot >= nnz) continue;
            var re: [W]f64 = undefined;
            var im: [W]f64 = undefined;
            for (0..W) |l| {
                const t = dyn.at(e, base + @min(l, cnt - 1));
                re[l] = t.re;
                im[l] = t.im;
            }
            const q = stackedPos(src_col_ptr, slot);
            const rv: @Vector(W, f64) = re;
            const iv: @Vector(W, f64) = im;
            out[q[0]] += rv;
            out[q[1]] += iv;
            out[q[2]] -= iv;
            out[q[3]] += rv;
        }
    }

    fn setOmegaDense(n: u32, nn: u32, d: *Dense, omega: f64, dyn: Dyn, k: usize) !void {
        dense_lu.buildComplexAdmittance(n, nn, d.g_dense, d.c_mat, omega, d.a_lu);
        for (dyn.slots, 0..) |slot, e| {
            if (slot >= d.src_row_idx.len) continue;
            const t = dyn.at(e, k);
            addDense(n, nn, d.a_lu, d.src_row_idx[slot], slotCol(d.src_col_ptr, slot), t.re, t.im);
        }
        try dense_lu.factorize(nn, d.a_lu, d.piv);
    }

    /// Fills the 2n stacked-real values, column j < n as [G | ωC] and
    /// column n + j as [-ωC | G], adds `dyn` at ω index `k`, then factors.
    fn setOmegaSparse(n: u32, s: *Sparse, omega: f64, dyn: Dyn, k: usize) !void {
        const nu: usize = n;
        const neg_omega = -omega;
        var p: usize = 0;

        for (0..nu) |j| {
            const cs = s.src_col_ptr[j];
            const len = s.src_col_ptr[j + 1] - cs;
            const lenu: usize = len;
            @memcpy(s.vals[p..][0..lenu], s.g_vals[cs..][0..lenu]);
            p += lenu;
            scaleCopy(s.vals[p..][0..lenu], s.c_vals[cs..][0..lenu], omega);
            p += lenu;
        }
        for (0..nu) |j| {
            const cs = s.src_col_ptr[j];
            const len = s.src_col_ptr[j + 1] - cs;
            const lenu: usize = len;
            scaleCopy(s.vals[p..][0..lenu], s.c_vals[cs..][0..lenu], neg_omega);
            p += lenu;
            @memcpy(s.vals[p..][0..lenu], s.g_vals[cs..][0..lenu]);
            p += lenu;
        }
        for (dyn.slots, 0..) |slot, e| {
            if (slot >= s.g_vals.len) continue;
            const q = stackedPos(s.src_col_ptr, slot);
            const t = dyn.at(e, k);
            s.vals[q[0]] += t.re;
            s.vals[q[1]] += t.im;
            s.vals[q[2]] -= t.im;
            s.vals[q[3]] += t.re;
        }

        try s.slv.factor(s.vals, .{});
    }
};

/// The column of CSC slot `slot` in the pattern `col_ptr` describes.
pub fn slotCol(col_ptr: []const u32, slot: u32) usize {
    return std.sort.upperBound(u32, col_ptr, slot, struct {
        fn order(key: u32, item: u32) std.math.Order {
            return std.math.order(key, item);
        }
    }.order) - 1;
}

/// Source slot `slot`'s four stacked-real positions: column j's G and ωC
/// entries, then column n + j's -ωC and G entries.
fn stackedPos(src_col_ptr: []const u32, slot: u32) [4]usize {
    const j = slotCol(src_col_ptr, slot);
    const cs: usize = src_col_ptr[j];
    const len: usize = src_col_ptr[j + 1] - cs;
    const top = 2 * cs + (slot - cs);
    const right = 2 * @as(usize, src_col_ptr[src_col_ptr.len - 1]) + top;
    return .{ top, top + len, right, right + len };
}

/// Adds re + j·im at entry (row, col) of the row-major 2n x 2n stacked-real
/// `a`, [Re -Im; Im Re], the layout `buildComplexAdmittance` writes.
pub fn addDense(n: usize, nn: usize, a: []f64, row: usize, col: usize, re: f64, im: f64) void {
    a[row * nn + col] += re;
    a[(n + row) * nn + col] += im;
    a[row * nn + n + col] -= im;
    a[(n + row) * nn + n + col] += re;
}

/// Writes the 2n x 2n stacked-real CSC pattern: each column j and n + j gets
/// column j's rows r followed by r + n. `sr_col_ptr` has 2n + 1 entries,
/// `sr_row_idx` 4 * nnz.
inline fn buildStackedRealPattern(
    n: u32,
    col_ptr: []const u32,
    row_idx: []const u32,
    sr_col_ptr: []u32,
    sr_row_idx: []u32,
) void {
    const nu: usize = n;
    var p: u32 = 0;
    sr_col_ptr[0] = 0;

    for (0..2) |half| {
        for (0..nu) |j| {
            const s = col_ptr[j];
            const e = col_ptr[j + 1];
            for (row_idx[s..e]) |r| {
                sr_row_idx[p] = r;
                p += 1;
            }
            for (row_idx[s..e]) |r| {
                sr_row_idx[p] = r + n;
                p += 1;
            }
            sr_col_ptr[half * nu + j + 1] = p;
        }
    }
}

/// dst[i] = s * src[i].
fn scaleCopy(dst: []f64, src: []const f64, s: f64) void {
    const W = std.simd.suggestVectorLength(f64) orelse 1;
    const VT = @Vector(W, f64);
    const sv: VT = @splat(s);

    var i: usize = 0;
    while (i + W <= src.len) : (i += W) {
        const v: VT = src[i..][0..W].*;
        const p: *[W]f64 = dst[i..][0..W];
        p.* = sv * v;
    }
    while (i < src.len) : (i += 1) {
        dst[i] = s * src[i];
    }
}
