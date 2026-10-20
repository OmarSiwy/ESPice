//! (G + jωC) x = b solves in the stacked-real form [G, -ωC; ωC, G], dense
//! for small circuits and sparse above. The sparse 2n pattern is derived once
//! from the circuit CSC, so each frequency's fill is a streamed copy of the G
//! and C planes. Batches of frequencies run as SIMD lanes through LaneLu.
//!
//! In: a circuit's G and C planes (or a dense G and C) and right-hand sides
//! per ω. Out: stacked-real solutions, real parts then imaginary. Cites
//! dev/solvers/overview.md and dev/solvers/gilbert-peierls-lu.md ("Two
//! replay thresholds", #44); #43 (held singular ω in `factorEach`), #83
//! (allocation failure is not a numerical one).

const std = @import("std");
const assert = std.debug.assert;
const dense_lu = @import("dense_lu.zig");
const direct = @import("direct.zig");
const lane_lu = @import("lane_lu.zig");
const SparseLu = @import("sparse_lu.zig").SparseLu;
const num = @import("core").numerics;

const Allocator = std.mem.Allocator;

// Dense only wins for tiny systems. medium/ladder_filter (n = 41) spent 90%
// of its run in dense 82^3/3 factors per omega; the sparse refactor is O(nnz).
const dense_threshold: u32 = 16;

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
        assert(e < self.slots.len);
        assert(k < self.re.len / self.slots.len);
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

    /// Every allocation the solver owns or makes later (`factorEach`,
    /// `deinit`) uses this, the allocator it was built with (#13).
    gpa: Allocator,
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

    /// n <= dense_threshold: owned n x n row-major G and C, assembled per
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
    /// evaluated. Caller frees with `deinit` and the same allocator. Asserts
    /// that `col_ptr` has n + 1 entries and `g` and `c` one value per slot.
    pub fn fromPlanes(allocator: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, g: []const f64, c: []const f64) !Self {
        assert(col_ptr.len == @as(usize, n) + 1);
        assert(g.len >= col_ptr[n]);
        assert(c.len >= col_ptr[n]);
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
    /// the circuit's CSC pattern for the solver's lifetime, and so does the
    /// dense one, to place `Dyn` entries and `setPlanes`. Caller frees with
    /// `deinit` and the same allocator.
    pub fn fromCircuit(allocator: Allocator, ckt: anytype, x_op: []const f64) !Self {
        try ckt.linearizeAc(x_op);
        const n: u32 = @intCast(ckt.n);

        if (n <= dense_threshold) {
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
        assert(col_ptr[nn] == total_nnz);

        // The analysis Circuit carries the facade's switches; a bare planes
        // view takes the defaults.
        const T = @TypeOf(ckt);
        const C = if (@typeInfo(T) == .pointer) @typeInfo(T).pointer.child else T;
        const knobs: direct.Knobs = if (comptime @hasField(C, "knobs")) ckt.knobs.lu else .{};
        var slv = try direct.Solver.init(allocator, nn, col_ptr, row_idx, null, knobs);
        errdefer slv.deinit();
        // A frequency solve is used as is, with no Newton step to correct
        // it, so a replayed pivot (the lanes', or the scalar refactor's
        // from the last ω) must pass the full factor's own threshold; at
        // the Newton default of 1e-12 a tape laid at ω = 0 replayed at
        // 1e6 left scaled residuals of 8e3 (#44).
        slv.params.refactor_growth_limit = direct.pivot_tol;
        // Each ω's values are new; the bypass copy would be nnz2 f64s
        // (3.7 MB on sweep_opamp_wl_5000) that never match.
        slv.dropBypass();

        return .{
            .gpa = allocator,
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
    /// `allocator`; takes ownership of both, also on error. Asserts that `g`
    /// and `c` are n x n.
    pub fn initDense(allocator: Allocator, n: u32, g: []f64, c: []f64) !Self {
        assert(g.len == @as(usize, n) * n);
        assert(c.len == g.len);
        errdefer allocator.free(g);
        errdefer allocator.free(c);
        const nn: u32 = 2 * n;
        const nnu: usize = nn;
        const a_lu = try allocator.alloc(f64, nnu * nnu);
        errdefer allocator.free(a_lu);
        const piv = try allocator.alloc(u32, nnu);

        return .{
            .gpa = allocator,
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

    /// Frees everything the solver owns.
    pub fn deinit(self: *Self) void {
        const allocator = self.gpa;
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

    /// Factors A(ω) = G + jωC and solves one stacked right-hand side; `rhs`
    /// and `x_out` are 2n long and may alias. Fails with `error.Singular`
    /// (dense) or `error.SingularMatrix` (sparse) on a singular A(ω), or
    /// `OutOfMemory`, leaving `x_out` untouched and no usable factor. Asserts
    /// that both slices hold 2n entries.
    pub fn solve(self: *Self, omega: f64, rhs: []const f64, x_out: []f64) !void {
        assert(rhs.len >= self.nn);
        assert(x_out.len >= self.nn);
        try self.setOmega(omega);
        self.solveRhs(rhs, x_out);
    }

    // Assembles and factors G + jωC. Right-hand sides at this ω then
    // need only `solveRhs`/`solveRhsT`. Fails with `error.Singular`
    // (dense) or `error.SingularMatrix` (sparse) on a singular A(ω), after
    // which `solveRhs` must not run until a `setOmega` succeeds.
    fn setOmega(self: *Self, omega: f64) !void {
        try self.setOmegaDyn(omega, .{}, 0);
    }

    /// `setOmega` plus `dyn`'s terms at ω index `k`.
    fn setOmegaDyn(self: *Self, omega: f64, dyn: Dyn, k: usize) !void {
        if (dyn.slots.len != 0) assert(k < dyn.re.len / dyn.slots.len);
        switch (self.strategy) {
            .dense => |*d| try setOmegaDense(self.n, self.nn, d, omega, dyn, k),
            .sp => |*s| try setOmegaSparse(self.n, s, omega, dyn, k),
        }
    }

    // Solves with the current factorization, which `setOmega` must have
    // left; both slices are 2n long and may alias.
    fn solveRhs(self: *Self, rhs: []const f64, x_out: []f64) void {
        switch (self.strategy) {
            .dense => |*d| dense_lu.solveFactored(self.nn, d.a_lu, d.piv, rhs, x_out),
            .sp => |*s| s.slv.solve(rhs, x_out),
        }
    }

    // Adjoint solve with the current factorization: the transpose of the
    // stacked-real system, which as a complex system is A^H x = rhs
    // (A = G + jωC, so A^H = G^T − jωC^T). A caller that needs A^T's
    // solution conjugates this one; |x| is the same either way.
    fn solveRhsT(self: *Self, rhs: []const f64, x_out: []f64) void {
        switch (self.strategy) {
            .dense => |*d| dense_lu.solveFactoredT(self.nn, d.a_lu, d.piv, rhs, x_out),
            .sp => |*s| s.slv.solveT(rhs, x_out),
        }
    }

    /// Adds `v` to entry (i, i) of the solver's copy of G; the circuit is
    /// untouched. Call it before the first solve: a factorization already
    /// held does not see it. Asserts that `i < n`.
    pub fn addDiagG(self: *Self, i: u32, v: f64) void {
        assert(i < self.n);
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
    /// factorization serves every rhs. `adjoint` solves the transpose of the
    /// stacked-real system, A^H = G^T − jωC^T, not A^T: conjugate the
    /// solution for A^T's (|x| is the same either way). The dense
    /// strategy, a non-LU engine and any lane whose refactor fails take the
    /// per-ω scalar path. The scalar factorization afterwards holds some ω
    /// of the batch. Allocates the lane planes on first use. Fails with
    /// `error.Singular` or `error.SingularMatrix` when an ω the scalar path
    /// takes is singular, with some ω's rows of `x_out` already written.
    /// Asserts that `rhs` is a positive multiple of 2n long, that `x_out`
    /// holds `omegas.len` times that, and that `dyn` has one term per entry
    /// per ω.
    pub fn solveBatch(self: *Self, omegas: []const f64, dyn: Dyn, rhs: []const f64, x_out: []f64, adjoint: bool) !void {
        const nn: usize = self.nn;
        const m = rhs.len;
        assert(m > 0);
        assert(m % nn == 0);
        assert(x_out.len == omegas.len * m);
        if (omegas.len == 0) return;
        assert(dyn.re.len == dyn.slots.len * omegas.len);
        assert(dyn.im.len == dyn.re.len);
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
            // A singular centre point falls back to the serial path; an
            // allocation failure is the caller's, not a numerical one (#83).
            const lu = (try self.chunkTape(sp, omegas, dyn, base, cnt, rhs, x_out, adjoint)) orelse continue;

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
            try self.chunkPeel(omegas, dyn, base, cnt, bad, rhs, x_out, adjoint);
        }
    }

    /// `solveBatch`'s chunk head: the pivot tape lanes `[base, base + cnt)`
    /// replay, laid by a scalar factor at the chunk's centre ω when none is
    /// current. Null when the chunk took the serial path instead (a
    /// singular centre or a non-LU engine), its rows of `x_out` written. An
    /// allocation failure is the caller's, not a numerical one (#83). The
    /// GPU lane backend runs it per point per round.
    fn chunkTape(self: *Self, sp: *Sparse, omegas: []const f64, dyn: Dyn, base: usize, cnt: usize, rhs: []const f64, x_out: []f64, adjoint: bool) !?*SparseLu {
        const centre = base + cnt / 2;
        if (!sp.slv.factored) setOmegaSparse(self.n, sp, omegas[centre], dyn, centre) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => { // else: a numerical factor failure takes the serial path
                try self.solveBatchSerial(omegas, dyn, base, cnt, rhs, x_out, adjoint);
                return null;
            },
        };
        // LaneLu replays SparseLu only, not the tridiagonal engine.
        return sp.slv.sparse() orelse {
            try self.solveBatchSerial(omegas, dyn, base, cnt, rhs, x_out, adjoint);
            return null;
        };
    }

    /// `solveBatch`'s chunk tail: each lane `bad` marks solves on the serial
    /// path, in lane order, after every lane solve: a failed lane's full
    /// factor may repivot the tape the next chunk replays.
    fn chunkPeel(self: *Self, omegas: []const f64, dyn: Dyn, base: usize, cnt: usize, bad: u64, rhs: []const f64, x_out: []f64, adjoint: bool) !void {
        for (0..cnt) |l| if ((bad & (@as(u64, 1) << @intCast(l))) != 0)
            try self.solveBatchSerial(omegas, dyn, base + l, 1, rhs, x_out, adjoint);
    }

    /// Replaces the solver's G and C with `g` and `c`, indexed by CSC slot
    /// of the source pattern (a circuit's `g_vals`/`c_vals` layout). The
    /// dense strategy places them through the pattern `fromCircuit`
    /// borrowed. Asserts that the solver has that pattern (not
    /// `initDense`'s) and that `g` and `c` cover it.
    pub fn setPlanes(self: *Self, g: []const f64, c: []const f64) void {
        assert(g.len == c.len);
        switch (self.strategy) {
            .dense => |*d| {
                const n: usize = self.n;
                assert(d.src_col_ptr.len == n + 1);
                assert(g.len >= d.src_col_ptr[n]);
                @memset(d.g_dense, 0);
                @memset(d.c_mat, 0);
                for (0..n) |j| for (d.src_col_ptr[j]..d.src_col_ptr[j + 1]) |p| {
                    const at = @as(usize, d.src_row_idx[p]) * n + j;
                    d.g_dense[at] += g[p];
                    d.c_mat[at] += c[p];
                };
            },
            .sp => |*s| {
                assert(g.len >= s.g_vals.len);
                @memcpy(s.g_vals, g[0..s.g_vals.len]);
                @memcpy(s.c_vals, c[0..s.c_vals.len]);
            },
        }
    }

    /// Factors G + jω_k C for every ω_k in `omegas` and keeps all of them,
    /// so `solveEach` can solve a different right-hand side per ω as often
    /// as it likes: the block-diagonal preconditioner shape. The sparse
    /// strategy holds ceil(len/W) LaneLu groups replaying one pivot tape,
    /// taken at the middle ω. When lanes fail to replay it, up to two more
    /// tapes are laid at the first failed ω not yet tried, and the tape
    /// that held the fewest lanes is kept. A lane that still fails (every
    /// lane when A at each tape ω is singular), or a singular dense block,
    /// is held as the identity and listed in `held_id`, ascending. Any
    /// other factor or solve on `self` invalidates the held
    /// factors. Asserts that `omegas` is not empty; the sparse strategy
    /// fails with `error.UnsupportedEngine` when the 2n system did not get
    /// the sparse LU, the only engine LaneLu replays.
    pub fn factorEach(self: *Self, omegas: []const f64) !void {
        const allocator = self.gpa;
        assert(omegas.len > 0);
        self.held_id.clearRetainingCapacity();
        // Every ω at most is held, so no append below allocates.
        try self.held_id.ensureTotalCapacity(allocator, omegas.len);
        switch (self.strategy) {
            .dense => |*d| {
                const nn: usize = self.nn;
                if (d.held.len != omegas.len * nn * nn) {
                    // Both before either is replaced: a held block without its
                    // pivot rows passed this length check on the next call.
                    const held = try allocator.alloc(f64, omegas.len * nn * nn);
                    errdefer allocator.free(held);
                    const held_piv = try allocator.alloc(u32, omegas.len * nn);
                    allocator.free(d.held);
                    allocator.free(d.held_piv);
                    d.held = held;
                    d.held_piv = held_piv;
                }
                assert(d.held_piv.len * nn == d.held.len);
                for (omegas, 0..) |omega, k| {
                    const a = d.held[k * nn * nn ..][0 .. nn * nn];
                    const piv = d.held_piv[k * nn ..][0..nn];
                    dense_lu.buildComplexAdmittance(self.n, self.nn, d.g_dense, d.c_mat, omega, a);
                    dense_lu.pinVoid(nn, a);
                    dense_lu.factorize(nn, a, piv) catch {
                        // A failed factor leaves `piv` partial; the identity
                        // is a factor `solveEach` can read.
                        @memset(a, 0);
                        for (piv, 0..) |*p, i| {
                            p.* = @intCast(i);
                            a[i * nn + i] = 1;
                        }
                        self.held_id.appendAssumeCapacity(@intCast(k));
                    };
                }
            },
            .sp => |*sp| try self.factorEachSparse(sp, omegas),
        }
        assert(self.held_id.items.len <= omegas.len);
    }

    fn factorEachSparse(self: *Self, sp: *Sparse, omegas: []const f64) !void {
        const gpa = self.gpa;
        // The sparse solver was built from the same gpa.
        assert(sp.slv.gpa.ptr == gpa.ptr);
        const nn: usize = self.nn;
        if (sp.lane_work.len == 0)
            sp.lane_work = try gpa.alloc(@Vector(W, f64), 2 * nn);
        var tried: [3]usize = undefined;
        var tries: usize = 0;
        var best: usize = undefined;
        var best_held: usize = std.math.maxInt(usize);
        var tape = omegas.len / 2;
        while (tries < tried.len) {
            tried[tries] = tape;
            tries += 1;
            const held = try self.replayTape(sp, omegas, tape);
            if (held < best_held) {
                best = tape;
                best_held = held;
            }
            if (held == 0) return;
            tape = for (self.held_id.items) |k| {
                if (std.mem.indexOfScalar(usize, tried[0..tries], k) == null) break k;
            } else break;
        }
        // A full factor can depend on the previous pivots (the re-pivot fill
        // cap), so the replayed best may hold a different count.
        if (best != tried[tries - 1]) _ = try self.replayTape(sp, omegas, best);
    }

    /// Lays a fresh pivot tape by a full factor at `omegas[tape]` and
    /// replays it into every LaneLu group. `held_id` receives the ω it
    /// cannot replay, every ω when A(omegas[tape]) is singular (no group is
    /// built then). Returns how many ω that holds. Asserts that `held_id`
    /// has room for every ω (`factorEach` reserves it).
    fn replayTape(self: *Self, sp: *Sparse, omegas: []const f64, tape: usize) !usize {
        const gpa = self.gpa;
        const LL = lane_lu.LaneLu(W);
        freeHeld(gpa, sp);
        self.held_id.clearRetainingCapacity();
        assert(self.held_id.capacity >= omegas.len);
        sp.slv.factored = false;
        setOmegaSparse(self.n, sp, omegas[tape], .{}, 0) catch |err| {
            if (err != error.SingularMatrix) return err;
            for (0..omegas.len) |k| self.held_id.appendAssumeCapacity(@intCast(k));
            return omegas.len;
        };
        const lu = sp.slv.sparse() orelse return error.UnsupportedEngine;
        const groups = (omegas.len + W - 1) / W;
        sp.held = try gpa.alloc(LL, groups);
        for (sp.held, 0..) |*h, g| h.* = LL.init(gpa, lu) catch |err| {
            for (sp.held[0..g]) |*done| done.deinit(gpa);
            gpa.free(sp.held);
            sp.held = &.{};
            return err;
        };
        for (sp.held, 0..) |*h, g| {
            const base = g * W;
            const cnt = @min(W, omegas.len - base);
            var ow: [W]f64 = undefined;
            for (0..W) |l| ow[l] = omegas[base + @min(l, cnt - 1)];
            const bad = h.refactor(Stacked(W).of(sp, ow, .{}, base, cnt), sp.slv.params.refactor_growth_limit);
            for (0..cnt) |l| if ((bad >> @intCast(l)) & 1 != 0)
                self.held_id.appendAssumeCapacity(@intCast(base + l));
        }
        return self.held_id.items.len;
    }

    /// Solves right-hand side k (the stacked 2n vector at `rhs[k*2n..]`)
    /// against `factorEach`'s factor k into the same rows of `x_out`, for
    /// every held ω; `adjoint` solves the stacked-real transpose, which is
    /// A^H. The identity lanes copy their right-hand side, so `rhs` and
    /// `x_out` must not overlap. Asserts that `rhs` holds exactly one
    /// vector per ω `factorEach` was given and `x_out` as many, and that
    /// the two do not overlap.
    pub fn solveEach(self: *Self, rhs: []const f64, x_out: []f64, adjoint: bool) void {
        const nn: usize = self.nn;
        if (nn == 0) return;
        assert(rhs.len % nn == 0);
        assert(x_out.len >= rhs.len);
        const r0 = @intFromPtr(rhs.ptr);
        const x0 = @intFromPtr(x_out.ptr);
        assert(r0 + rhs.len * @sizeOf(f64) <= x0 or x0 + rhs.len * @sizeOf(f64) <= r0);
        switch (self.strategy) {
            .dense => |d| assert(d.held_piv.len == rhs.len),
            // No groups when no tape could be laid; every ω is held then (#43).
            .sp => |sp| assert(sp.held.len == (rhs.len / nn + W - 1) / W or self.held_id.items.len == rhs.len / nn),
        }
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

    /// Private kernels and types for tests.zig; void outside test builds.
    pub const test_access = if (@import("builtin").is_test) .{
        .W = W,
        .setOmega = setOmega,
        .solveRhs = solveRhs,
        .solveRhsT = solveRhsT,
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
        assert(first + count <= omegas.len);
        assert(m % nn == 0);
        for (first..first + count) |k| {
            try self.setOmegaDyn(omegas[k], dyn, k);
            var r: usize = 0;
            while (r < m) : (r += nn) {
                const b = rhs[r..][0..nn];
                const x = x_out[k * m + r ..][0..nn];
                if (adjoint) self.solveRhsT(b, x) else self.solveRhs(b, x);
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
        assert(ptr[0] == 0);
    }

    fn setOmegaDense(n: u32, nn: u32, d: *Dense, omega: f64, dyn: Dyn, k: usize) !void {
        dense_lu.buildComplexAdmittance(n, nn, d.g_dense, d.c_mat, omega, d.a_lu);
        for (dyn.slots, 0..) |slot, e| {
            if (slot >= d.src_row_idx.len) continue;
            const t = dyn.at(e, k);
            addDense(n, nn, d.a_lu, d.src_row_idx[slot], slotCol(d.src_col_ptr, slot), t.re, t.im);
        }
        dense_lu.pinVoid(nn, d.a_lu);
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
        assert(p == s.vals.len);

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
        /// Asserts that 1 <= cnt <= L.
        pub fn of(sp: anytype, omega: V, dyn: Dyn, base: usize, cnt: usize) @This() {
            assert(cnt >= 1);
            assert(cnt <= L);
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

/// `Stacked` over lanes from several points on one stacked pattern: lane l
/// fills from `g[l]`/`c[l]`, one point's source-slot G and C snapshot, at
/// `omega[l]`. Same products, in the same order per entry, as `Stacked`,
/// so lane l is bitwise `Stacked(1)` of its own point. No `Dyn`: a deck
/// with `acDyn` terms solves per point. The host oracle of the GPU lane
/// backend's (point, ω) fill (phase 4); every point must share the pattern
/// `src_col_ptr`/`col_ptr`.
pub fn StackedPoints(comptime L: usize) type {
    return struct {
        const V = @Vector(L, f64);
        src_col_ptr: []const u32,
        col_ptr: []const u32,
        g: [L][]const f64,
        c: [L][]const f64,
        omega: V,

        /// Stacked column `col` per lane, as `Stacked.load`.
        pub inline fn load(s: @This(), col: usize, w: []V, prow: []const u32) void {
            const n = s.src_col_ptr.len - 1;
            const top = col < n;
            const j = if (top) col else col - n;
            const cs = s.src_col_ptr[j];
            const len: usize = s.src_col_ptr[j + 1] - cs;
            const rows = prow[s.col_ptr[col]..][0 .. 2 * len];
            for (0..len) |i| {
                var ga: [L]f64 = undefined;
                var ca: [L]f64 = undefined;
                for (0..L) |l| {
                    ga[l] = s.g[l][cs + i];
                    ca[l] = s.c[l][cs + i];
                }
                const gv: V = ga;
                const cv: V = ca;
                if (top) {
                    w[rows[i]] = gv;
                    w[rows[len + i]] = s.omega * cv;
                } else {
                    w[rows[i]] = -s.omega * cv;
                    w[rows[len + i]] = gv;
                }
            }
        }
    };
}

/// The column of CSC slot `slot` in the pattern `col_ptr` describes, by
/// binary search (O(log n)); empty columns are skipped. A slot at or past
/// nnz returns n, one past the last column, so callers filter ground slots
/// first. Asserts that `col_ptr` opens at 0.
pub fn slotCol(col_ptr: []const u32, slot: u32) usize {
    assert(col_ptr[0] == 0);
    const j = std.sort.upperBound(u32, col_ptr, slot, struct {
        fn order(key: u32, item: u32) std.math.Order {
            return std.math.order(key, item);
        }
    }.order) - 1;
    assert(j < col_ptr.len);
    return j;
}

/// Source slot `slot`'s four stacked-real positions: column j's G and ωC
/// entries, then column n + j's -ωC and G entries.
fn stackedPos(src_col_ptr: []const u32, slot: u32) [4]usize {
    assert(slot < src_col_ptr[src_col_ptr.len - 1]);
    const j = slotCol(src_col_ptr, slot);
    const cs: usize = src_col_ptr[j];
    const len: usize = src_col_ptr[j + 1] - cs;
    const top = 2 * cs + (slot - cs);
    const right = 2 * @as(usize, src_col_ptr[src_col_ptr.len - 1]) + top;
    return .{ top, top + len, right, right + len };
}

/// Adds re + j·im at entry (row, col) of the row-major 2n x 2n stacked-real
/// `a`, [Re -Im; Im Re], the layout `buildComplexAdmittance` writes.
/// Asserts that nn = 2n and that (row, col) lies in the n x n block.
pub fn addDense(n: usize, nn: usize, a: []f64, row: usize, col: usize, re: f64, im: f64) void {
    assert(nn == 2 * n);
    assert(row < n);
    assert(col < n);
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
    assert(sr_col_ptr.len == 2 * nu + 1);
    assert(sr_row_idx.len == 4 * @as(usize, col_ptr[n]));
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
    assert(p == sr_row_idx.len);
}

const testing = std.testing;

/// G = 2 on the diagonal and -1 between ring neighbours (0 and n - 1
/// included), C = `c_diag` on the diagonal: a pattern no structured engine
/// takes, so the stacked 2n system gets the sparse LU.
const Ring = struct {
    const n_max = 24;
    col_ptr: [n_max + 1]u32 = undefined,
    row_idx: [3 * n_max]u32 = undefined,
    g: [3 * n_max]f64 = undefined,
    c: [3 * n_max]f64 = undefined,

    fn init(n: u32, c_diag: f64) Ring {
        assert(n >= 3);
        assert(n <= n_max);
        var r: Ring = .{};
        var p: u32 = 0;
        for (0..n) |j| {
            r.col_ptr[j] = p;
            var rows = [3]u32{ @intCast((j + n - 1) % n), @intCast(j), @intCast((j + 1) % n) };
            std.mem.sort(u32, &rows, {}, std.sort.asc(u32));
            for (rows) |i| {
                r.row_idx[p] = i;
                r.g[p] = if (i == j) 2 else -1;
                r.c[p] = if (i == j) c_diag else 0;
                p += 1;
            }
        }
        r.col_ptr[n] = p;
        return r;
    }
};

fn everyEntryPoint(gpa: Allocator, n: u32) !void {
    const ring: Ring = .init(n, 1e-3);
    const nnz = ring.col_ptr[n];
    var fs = try FreqSolver.fromPlanes(gpa, n, ring.col_ptr[0 .. n + 1], ring.row_idx[0..nnz], ring.g[0..nnz], ring.c[0..nnz]);
    defer fs.deinit();
    const nn: usize = 2 * @as(usize, n);
    var rhs: [2 * Ring.n_max]f64 = @splat(0);
    rhs[0] = 1;
    var x: [2 * Ring.n_max * 5]f64 = undefined;
    try fs.solve(1e3, rhs[0..nn], x[0..nn]);
    const omegas = [_]f64{ 1, 1e2, 1e4, 1e6, 1e8 };
    const dyn: Dyn = .{ .slots = &.{ 0, 1, 1_000_000 }, .re = &(@as([15]f64, @splat(0.5))), .im = &(@as([15]f64, @splat(0.25))) };
    try fs.solveBatch(&omegas, dyn, rhs[0..nn], x[0 .. omegas.len * nn], false);
    try fs.solveBatch(&omegas, .{}, rhs[0..nn], x[0 .. omegas.len * nn], true);
    try fs.factorEach(&omegas);
    var each: [2 * Ring.n_max * 5]f64 = @splat(1);
    fs.solveEach(each[0 .. omegas.len * nn], x[0 .. omegas.len * nn], false);
}

test "FreqSolver: every entry point frees all it holds on every allocation failure (#83)" {
    // n = 4 takes the dense strategy, n = 20 the sparse lanes. Any error but
    // OutOfMemory would be an allocation failure reported as a numerical one.
    inline for (.{ 4, 20 }) |n|
        try testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, everyEntryPoint, .{@as(u32, n)});
}

test "FreqSolver: a dense factorEach that fails to grow keeps its held factors consistent" {
    // Grows from one held ω to three; the pivot rows' allocation fails. The
    // next factorEach of the same count must still allocate both.
    const ring: Ring = .init(4, 1e-3);
    const nnz = ring.col_ptr[4];
    for (0..2) |fail_at| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var fs = try FreqSolver.fromPlanes(failing.allocator(), 4, ring.col_ptr[0..5], ring.row_idx[0..nnz], ring.g[0..nnz], ring.c[0..nnz]);
        defer fs.deinit();
        try testing.expect(fs.strategy == .dense);
        try fs.factorEach(&.{1});
        failing.fail_index = failing.alloc_index + fail_at;
        const omegas = [_]f64{ 1, 10, 100 };
        try testing.expectError(error.OutOfMemory, fs.factorEach(&omegas));
        failing.fail_index = std.math.maxInt(usize);
        try fs.factorEach(&omegas);
        var rhs: [3 * 8]f64 = @splat(0);
        for (0..3) |k| rhs[k * 8] = 1;
        var x: [3 * 8]f64 = undefined;
        fs.solveEach(&rhs, &x, false);
        // Each held factor solves its own ω: compare with a fresh solve.
        for (omegas, 0..) |w, k| {
            var want: [8]f64 = undefined;
            try fs.solve(w, rhs[k * 8 ..][0..8], &want);
            for (want, x[k * 8 ..][0..8]) |a, b| try testing.expectApproxEqAbs(a, b, 1e-12);
        }
    }
}

test "slotCol and stackedPos place every slot of a pattern with empty columns" {
    // Columns 1 and 3 are empty: col_ptr = 0 2 2 5 5 6.
    const col_ptr = [_]u32{ 0, 2, 2, 5, 5, 6 };
    const want_col = [_]usize{ 0, 0, 2, 2, 2, 4 };
    for (want_col, 0..) |j, slot| try testing.expectEqual(j, slotCol(&col_ptr, @intCast(slot)));
    // A slot at nnz (a ground entry) maps one past the last column.
    try testing.expectEqual(@as(usize, 5), slotCol(&col_ptr, 6));
    // Stacked column j holds column j's G rows then its ωC rows; column
    // n + j starts at 2 nnz with -ωC then G.
    for (0..6) |slot| {
        const j = want_col[slot];
        const cs = col_ptr[j];
        const len = col_ptr[j + 1] - cs;
        const q = stackedPos(&col_ptr, @intCast(slot));
        try testing.expectEqual(2 * cs + (slot - cs), q[0]);
        try testing.expectEqual(q[0] + len, q[1]);
        try testing.expectEqual(12 + q[0], q[2]);
        try testing.expectEqual(q[2] + len, q[3]);
    }
}

test "addDense writes the stacked-real [Re -Im; Im Re] image of one complex entry" {
    var a: [16]f64 = @splat(0);
    addDense(2, 4, &a, 1, 0, 3, 5);
    // Row-major 4 x 4: (1,0) += 3, (3,0) += 5, (1,2) -= 5, (3,2) += 3.
    const want = [16]f64{ 0, 0, 0, 0, 3, 0, -5, 0, 0, 0, 0, 0, 5, 0, 3, 0 };
    try testing.expectEqualSlices(f64, &want, &a);
}

test "StackedPoints: lane (point, ω) is bitwise Stacked(1) of its own point on the shared tape" {
    const gpa = testing.allocator;
    const n: u32 = 20; // above dense_threshold: the sparse strategy
    const a: Ring = .init(n, 1e-3);
    var b: Ring = .init(n, 3e-3);
    for (b.g[0..a.col_ptr[n]]) |*v| v.* *= 1.05;
    const nnz = a.col_ptr[n];
    var fa = try FreqSolver.fromPlanes(gpa, n, a.col_ptr[0 .. n + 1], a.row_idx[0..nnz], a.g[0..nnz], a.c[0..nnz]);
    defer fa.deinit();
    var fb = try FreqSolver.fromPlanes(gpa, n, b.col_ptr[0 .. n + 1], b.row_idx[0..nnz], b.g[0..nnz], b.c[0..nnz]);
    defer fb.deinit();
    // Lay point a's tape at 1e4 rad/s; point b replays it.
    try FreqSolver.test_access.setOmega(&fa, 1e4);
    const spa = &fa.strategy.sp;
    const spb = &fb.strategy.sp;
    const lu = spa.slv.sparse().?;
    const L = 4;
    var lanes = try lane_lu.LaneLu(L).init(gpa, lu);
    defer lanes.deinit(gpa);
    const omegas = [L]f64{ 1e2, 1e2, 1e6, 1e6 };
    const src: StackedPoints(L) = .{
        .src_col_ptr = spa.src_col_ptr,
        .col_ptr = spa.col_ptr,
        .g = .{ spa.g_vals, spb.g_vals, spa.g_vals, spb.g_vals },
        .c = .{ spa.c_vals, spb.c_vals, spa.c_vals, spb.c_vals },
        .omega = omegas,
    };
    const bad = lanes.refactor(src, spa.slv.params.refactor_growth_limit);
    const nn: usize = 2 * n;
    const bv = try gpa.alloc(@Vector(L, f64), 2 * nn);
    defer gpa.free(bv);
    for (bv[0..nn], 0..) |*v, i| v.* = @splat(@as(f64, @floatFromInt(i % 3)) - 1);
    lanes.solve(bv[0..nn], bv[nn..]);
    var one = try lane_lu.LaneLu(1).init(gpa, lu);
    defer one.deinit(gpa);
    const b1 = try gpa.alloc(@Vector(1, f64), 2 * nn);
    defer gpa.free(b1);
    for (0..L) |l| {
        const sp = if (l % 2 == 0) spa else spb;
        const want_bad = one.refactor(Stacked(1).of(sp, @as(@Vector(1, f64), @splat(omegas[l])), .{}, 0, 1), spa.slv.params.refactor_growth_limit);
        try testing.expectEqual(want_bad != 0, (bad >> @intCast(l)) & 1 != 0);
        if (want_bad != 0) continue;
        for (b1[0..nn], 0..) |*v, i| v.* = @splat(@as(f64, @floatFromInt(i % 3)) - 1);
        one.solve(b1[0..nn], b1[nn..]);
        for (bv[nn..], b1[nn..]) |got, want| {
            const g: [L]f64 = got;
            const w: [1]f64 = want;
            try testing.expectEqual(@as(u64, @bitCast(w[0])), @as(u64, @bitCast(g[l])));
        }
    }
}
