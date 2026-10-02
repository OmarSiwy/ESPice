//! (G + jωC) x = b solves in the stacked-real form [G, -ωC; ωC, G], dense
//! for small circuits and sparse above. The sparse 2n pattern is derived once
//! from the circuit CSC, so each frequency's fill is a streamed copy of the G
//! and C planes. Batches of frequencies run as SIMD lanes through LaneLu.

const std = @import("std");
const dense_lu = @import("dense_lu.zig");
const direct = @import("direct.zig");
const lane_lu = @import("lane_lu.zig");
const num = @import("core").numerics;

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
    /// Frequencies per LaneLu pass; `solveBatch` groups its ω from the
    /// first in runs of W.
    pub const W = std.simd.suggestVectorLength(f64) orelse 1;

    n: u32,
    nn: u32,
    strategy: Strategy,
    /// `factorEach`'s ω indices held as the identity: a singular block, or
    /// a lane no pivot tape it tried could replay.
    held_id: std.ArrayList(u32) = .empty,

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
        /// `factorEach`'s factors, one 2n x 2n LU and pivot row per ω.
        held: []f64 = &.{},
        held_piv: []u32 = &.{},
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
        /// Lane scratch: the RHS and solution planes. Allocated by the
        /// first `solveBatch` or `factorEach`; the matrix values never exist
        /// as a lane plane (`Stacked` computes each column as it is read).
        lane_work: []@Vector(W, f64) = &.{},
        /// The current `Dyn`'s entries grouped by source column: column j's
        /// are `dyn_ent[dyn_ptr[j]..dyn_ptr[j + 1]]`, in entry order, ground
        /// entries left out. Rebuilt by every `solveBatch` with a `Dyn`.
        dyn_ptr: []u32 = &.{},
        dyn_ent: []u32 = &.{},
        lanes: ?lane_lu.LaneLu(W) = null,
        /// `factorEach`'s factors: W ω per group, all replaying `slv.lu`'s
        /// pivot tape.
        held: []lane_lu.LaneLu(W) = &.{},
    };

    /// A solver over the CSC pattern `col_ptr`/`row_idx` (n columns,
    /// borrowed for the solver's lifetime) with G and C given per slot, for
    /// callers whose planes are not a circuit evaluation. Nothing is
    /// evaluated.
    pub fn fromPlanes(allocator: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, g: []const f64, c: []const f64) !Self {
        const Planes = struct {
            n: usize,
            nnz: usize,
            col_ptr: []const u32,
            row_idx: []const u32,
            g_vals: []const f64,
            c_vals: []const f64,
            fn linearizeAc(_: @This(), _: []const f64) !void {}
            fn denseG(p: @This(), out: []f64) void {
                p.dense(p.g_vals, out);
            }
            fn denseC(p: @This(), out: []f64) void {
                p.dense(p.c_vals, out);
            }
            fn dense(p: @This(), vals: []const f64, out: []f64) void {
                @memset(out[0 .. p.n * p.n], 0);
                for (0..p.n) |j| for (p.col_ptr[j]..p.col_ptr[j + 1]) |s| {
                    out[@as(usize, p.row_idx[s]) * p.n + j] += vals[s];
                };
            }
        };
        return fromCircuit(allocator, Planes{ .n = n, .nnz = col_ptr[n], .col_ptr = col_ptr, .row_idx = row_idx, .g_vals = g, .c_vals = c }, &.{});
    }

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
        // Each ω's values are new; the bypass copy would be nnz2 f64s
        // (3.7 MB on sweep_opamp_wl_5000) that never match.
        slv.dropBypass();

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
        self.held_id.deinit(allocator);
        switch (self.strategy) {
            .dense => |*d| {
                allocator.free(d.held);
                allocator.free(d.held_piv);
                allocator.free(d.g_dense);
                allocator.free(d.c_mat);
                allocator.free(d.a_lu);
                allocator.free(d.piv);
            },
            .sp => |*s| {
                freeHeld(allocator, s);
                if (s.lanes) |*l| l.deinit(allocator);
                allocator.free(s.lane_work);
                allocator.free(s.dyn_ptr);
                allocator.free(s.dyn_ent);
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

    /// Adjoint solve with the current factorization: the transpose of the
    /// stacked-real system, which as a complex system is A^H x = rhs
    /// (A = G + jωC, so A^H = G^T − jωC^T). A caller that needs A^T's
    /// solution conjugates this one; |x| is the same either way.
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
    /// factorization serves every rhs. `adjoint` selects A^H (see
    /// `solveRhsT`), not A^T: conjugate the solution for A^T's. The dense
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
        if (sp.lane_work.len == 0)
            sp.lane_work = try gpa.alloc(@Vector(W, f64), 2 * nn);
        const b_plane = sp.lane_work[0..nn];
        const x_plane = sp.lane_work[nn..];
        try indexDyn(gpa, sp, dyn);

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

            const src = Stacked(W).of(sp, omega_vec, dyn, base, cnt);
            const bad = sp.lanes.?.refactor(src, sp.slv.params.refactor_growth_limit);

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

    /// Replaces the solver's G and C with `g` and `c`, indexed by CSC slot
    /// of the source pattern (a circuit's `g_vals`/`c_vals` layout). The
    /// dense strategy places them through the pattern `fromCircuit`
    /// borrowed.
    pub fn setPlanes(self: *Self, g: []const f64, c: []const f64) void {
        switch (self.strategy) {
            .dense => |*d| {
                const n: usize = self.n;
                @memset(d.g_dense, 0);
                @memset(d.c_mat, 0);
                for (0..n) |j| for (d.src_col_ptr[j]..d.src_col_ptr[j + 1]) |p| {
                    const at = @as(usize, d.src_row_idx[p]) * n + j;
                    d.g_dense[at] += g[p];
                    d.c_mat[at] += c[p];
                };
            },
            .sp => |*s| {
                @memcpy(s.g_vals, g[0..s.g_vals.len]);
                @memcpy(s.c_vals, c[0..s.c_vals.len]);
            },
        }
    }

    /// Factors G + jω_k C for every ω_k in `omegas` and keeps all of them,
    /// so `solveEach` can solve a different right-hand side per ω as often
    /// as it likes: the block-diagonal preconditioner shape. The sparse
    /// strategy holds ceil(len/W) LaneLu groups replaying one pivot tape,
    /// taken at the middle ω. A lane the tape cannot replay has the tape
    /// repivoted at its ω, at most twice; a lane that still fails, or a
    /// singular dense block, is held as the identity and listed in
    /// `held_id`. Any other factor or solve on `self` invalidates the held
    /// factors.
    pub fn factorEach(self: *Self, allocator: Allocator, omegas: []const f64) !void {
        std.debug.assert(omegas.len > 0);
        self.held_id.clearRetainingCapacity();
        switch (self.strategy) {
            .dense => |*d| {
                const nn: usize = self.nn;
                if (d.held.len != omegas.len * nn * nn) {
                    allocator.free(d.held);
                    allocator.free(d.held_piv);
                    d.held = &.{};
                    d.held_piv = &.{};
                    d.held = try allocator.alloc(f64, omegas.len * nn * nn);
                    d.held_piv = try allocator.alloc(u32, omegas.len * nn);
                }
                for (omegas, 0..) |omega, k| {
                    const a = d.held[k * nn * nn ..][0 .. nn * nn];
                    dense_lu.buildComplexAdmittance(self.n, self.nn, d.g_dense, d.c_mat, omega, a);
                    dense_lu.factorize(nn, a, d.held_piv[k * nn ..][0..nn]) catch
                        try self.held_id.append(allocator, @intCast(k));
                }
            },
            .sp => |*sp| try self.factorEachSparse(allocator, sp, omegas),
        }
    }

    fn factorEachSparse(self: *Self, allocator: Allocator, sp: *Sparse, omegas: []const f64) !void {
        const gpa = sp.slv.gpa;
        const LL = lane_lu.LaneLu(W);
        const nn: usize = self.nn;
        if (sp.lane_work.len == 0)
            sp.lane_work = try gpa.alloc(@Vector(W, f64), 2 * nn);
        const groups = (omegas.len + W - 1) / W;
        var tape = omegas.len / 2;
        var tries: u8 = 0;
        while (true) : (tries += 1) {
            // A full factor at omegas[tape] lays down a fresh pivot tape.
            sp.slv.factored = false;
            try setOmegaSparse(self.n, sp, omegas[tape], .{}, 0);
            const lu = if (sp.slv.lu) |*l| l else return error.UnsupportedEngine;
            freeHeld(gpa, sp);
            sp.held = try gpa.alloc(LL, groups);
            for (sp.held, 0..) |*h, g| h.* = LL.init(gpa, lu) catch |err| {
                for (sp.held[0..g]) |*done| done.deinit(gpa);
                gpa.free(sp.held);
                sp.held = &.{};
                return err;
            };
            self.held_id.clearRetainingCapacity();
            for (sp.held, 0..) |*h, g| {
                const base = g * W;
                const cnt = @min(W, omegas.len - base);
                var ow: [W]f64 = undefined;
                for (0..W) |l| ow[l] = omegas[base + @min(l, cnt - 1)];
                const bad = h.refactor(Stacked(W).of(sp, ow, .{}, base, cnt), sp.slv.params.refactor_growth_limit);
                for (0..cnt) |l| if ((bad >> @intCast(l)) & 1 != 0)
                    try self.held_id.append(allocator, @intCast(base + l));
            }
            if (self.held_id.items.len == 0 or tries == 2) return;
            tape = self.held_id.items[0];
        }
    }

    /// Solves right-hand side k (the stacked 2n vector at `rhs[k*2n..]`)
    /// against `factorEach`'s factor k into the same rows of `x_out`, for
    /// every held ω; `adjoint` solves the stacked-real transpose, which is
    /// A^H. The identity lanes copy their right-hand side.
    pub fn solveEach(self: *Self, rhs: []const f64, x_out: []f64, adjoint: bool) void {
        const nn: usize = self.nn;
        switch (self.strategy) {
            .dense => |*d| for (0..d.held_piv.len / nn) |k| {
                const lu = d.held[k * nn * nn ..][0 .. nn * nn];
                const piv = d.held_piv[k * nn ..][0..nn];
                const b = rhs[k * nn ..][0..nn];
                const x = x_out[k * nn ..][0..nn];
                if (adjoint) dense_lu.solveFactoredT(nn, lu, piv, b, x) else dense_lu.solveFactored(nn, lu, piv, b, x);
            },
            .sp => |*sp| {
                const b_plane = sp.lane_work[0..nn];
                const x_plane = sp.lane_work[nn..];
                const m = rhs.len / nn;
                for (sp.held, 0..) |*h, g| {
                    const base = g * W;
                    const cnt = @min(W, m - base);
                    for (b_plane, 0..) |*lane, i| {
                        var row: [W]f64 = undefined;
                        for (0..W) |l| row[l] = rhs[(base + @min(l, cnt - 1)) * nn + i];
                        lane.* = row;
                    }
                    if (adjoint) h.solveT(b_plane, x_plane) else h.solve(b_plane, x_plane);
                    for (x_plane, 0..) |lane, i| {
                        const row: [W]f64 = lane;
                        for (0..cnt) |l| x_out[(base + l) * nn + i] = row[l];
                    }
                }
            },
        }
        for (self.held_id.items) |k| @memcpy(x_out[k * nn ..][0..nn], rhs[k * nn ..][0..nn]);
    }

    fn freeHeld(gpa: Allocator, sp: *Sparse) void {
        for (sp.held) |*h| h.deinit(gpa);
        gpa.free(sp.held);
        sp.held = &.{};
    }

    pub const test_access = if (@import("builtin").is_test) .{
        .W = W,
        .solveBatchSerial = solveBatchSerial,
        .setOmegaSparse = setOmegaSparse,
        .indexDyn = indexDyn,
        .Sparse = Sparse,
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

    /// Groups `dyn`'s entries by source column into `dyn_ptr`/`dyn_ent`
    /// with a counting sort, so each column keeps entry order. An empty
    /// `dyn` leaves them alone: `Stacked.of` ignores them then.
    fn indexDyn(gpa: Allocator, s: *Sparse, dyn: Dyn) !void {
        if (dyn.slots.len == 0) return;
        const n = s.src_col_ptr.len - 1;
        const nnz = s.src_col_ptr[n];
        if (s.dyn_ptr.len != n + 1) {
            gpa.free(s.dyn_ptr);
            s.dyn_ptr = &.{};
            s.dyn_ptr = try gpa.alloc(u32, n + 1);
        }
        const ptr = s.dyn_ptr;
        @memset(ptr, 0);
        for (dyn.slots) |slot| if (slot < nnz) {
            ptr[slotCol(s.src_col_ptr, slot) + 1] += 1;
        };
        for (1..n + 1) |j| ptr[j] += ptr[j - 1];
        if (s.dyn_ent.len != ptr[n]) {
            gpa.free(s.dyn_ent);
            s.dyn_ent = &.{};
            s.dyn_ent = try gpa.alloc(u32, ptr[n]);
        }
        // Backwards from each column's end leaves ptr[j + 1] at column j's
        // start; one shift down restores the starts.
        var e = dyn.slots.len;
        while (e > 0) {
            e -= 1;
            const slot = dyn.slots[e];
            if (slot >= nnz) continue;
            const j = slotCol(s.src_col_ptr, slot);
            ptr[j + 1] -= 1;
            s.dyn_ent[ptr[j + 1]] = @intCast(e);
        }
        std.mem.copyForwards(u32, ptr[0..n], ptr[1..]);
        ptr[n] = @intCast(s.dyn_ent.len);
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
            num.scale(s.vals[p..][0..lenu], omega, s.c_vals[cs..][0..lenu]);
            p += lenu;
        }
        for (0..nu) |j| {
            const cs = s.src_col_ptr[j];
            const len = s.src_col_ptr[j + 1] - cs;
            const lenu: usize = len;
            num.scale(s.vals[p..][0..lenu], neg_omega, s.c_vals[cs..][0..lenu]);
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

/// The stacked-real A(ω) = [G, -ωC; ωC, G] (plus `Dyn`) for L frequencies,
/// as a `LaneLu(L).refactor` source: each column is computed from the G and
/// C snapshots as the refactor reads it, so no lane value plane exists. Same
/// products and adds, in the same order per entry, as `setOmegaSparse`, so
/// lane l is bitwise that scalar fill at ω index `base + min(l, cnt - 1)`.
/// `Stacked(1)` is the scalar oracle of the fill.
pub fn Stacked(comptime L: usize) type {
    return struct {
        const V = @Vector(L, f64);
        src_col_ptr: []const u32,
        col_ptr: []const u32,
        g: []const f64,
        c: []const f64,
        omega: V,
        dyn: Dyn,
        dyn_ptr: []const u32,
        dyn_ent: []const u32,
        base: usize,
        cnt: usize,

        /// The fill of `sp` at `omega`; `dyn` must be the one `indexDyn`
        /// grouped into `sp`, with lane l at ω index `base + min(l, cnt - 1)`.
        pub fn of(sp: anytype, omega: V, dyn: Dyn, base: usize, cnt: usize) @This() {
            return .{
                .src_col_ptr = sp.src_col_ptr,
                .col_ptr = sp.col_ptr,
                .g = sp.g_vals,
                .c = sp.c_vals,
                .omega = omega,
                .dyn = dyn,
                .dyn_ptr = sp.dyn_ptr,
                .dyn_ent = if (dyn.slots.len == 0) &.{} else sp.dyn_ent,
                .base = base,
                .cnt = cnt,
            };
        }

        /// Stacked column `col`: for col = j < n, G then ωC of source column
        /// j; for col = n + j, -ωC then G. Entry p lands at `w[prow[p]]`.
        pub inline fn load(s: @This(), col: usize, w: []V, prow: []const u32) void {
            const n = s.src_col_ptr.len - 1;
            const top = col < n;
            const j = if (top) col else col - n;
            const cs = s.src_col_ptr[j];
            const len: usize = s.src_col_ptr[j + 1] - cs;
            const rows = prow[s.col_ptr[col]..][0 .. 2 * len];
            const g = s.g[cs..][0..len];
            const c = s.c[cs..][0..len];
            if (top) {
                for (rows[0..len], g) |r, v| w[r] = @splat(v);
                for (rows[len..], c) |r, v| w[r] = s.omega * @as(V, @splat(v));
            } else {
                const neg = -s.omega;
                for (rows[0..len], c) |r, v| w[r] = neg * @as(V, @splat(v));
                for (rows[len..], g) |r, v| w[r] = @splat(v);
            }
            if (s.dyn_ent.len == 0) return;
            for (s.dyn_ent[s.dyn_ptr[j]..s.dyn_ptr[j + 1]]) |e| {
                var re: [L]f64 = undefined;
                var im: [L]f64 = undefined;
                for (0..L) |l| {
                    const t = s.dyn.at(e, s.base + @min(l, s.cnt - 1));
                    re[l] = t.re;
                    im[l] = t.im;
                }
                const at = s.dyn.slots[e] - cs;
                const rv: V = re;
                const iv: V = im;
                if (top) {
                    w[rows[at]] += rv;
                    w[rows[len + at]] += iv;
                } else {
                    w[rows[at]] -= iv;
                    w[rows[len + at]] += rv;
                }
            }
        }
    };
}

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
            @memcpy(sr_row_idx[p..][0 .. e - s], row_idx[s..e]);
            p += e - s;
            for (row_idx[s..e]) |r| {
                sr_row_idx[p] = r + n;
                p += 1;
            }
            sr_col_ptr[half * nu + j + 1] = p;
        }
    }
}
