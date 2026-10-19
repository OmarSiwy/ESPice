//! Fixed-pattern sparse direct solver: the facade every Newton caller uses.
//! Picks an engine from the pattern (tridiagonal, bordered block diagonal or
//! general sparse LU), skips refactoring when the values did not change, and
//! demotes to the general LU when a structured engine meets a singular pivot
//! (or, for BBD, a Schur reduction too unstable to refine). A pivot replay
//! that kept a sub-threshold pivot is probed and re-factored when its solves
//! miss the threshold-pivoting bar.
//!
//! In: a frozen CSC pattern, then values per factor and right-hand sides per
//! solve. Out: solutions of A x = b and A^T x = b. Cites KLU's threshold
//! pivoting (`pivot_tol`), LAPACK dgerfs and LAWN 41 (BBD refinement and the
//! residual bars), dev/solvers/gilbert-peierls-lu.md ("Two replay
//! thresholds"), dev/solvers/gpu-lu.md ("Multicore host refactor"); #44,
//! #45, #136.

const std = @import("std");
const assert = std.debug.assert;
const sparse_lu = @import("sparse_lu.zig");
const tridiag_mod = @import("tridiag.zig");
const order_mod = @import("order.zig");
const bbd_mod = @import("bbd.zig");
const lu_kernels = @import("lu_kernels.zig");
const num = @import("core").numerics;
const z = @import("stdpp");

const Allocator = std.mem.Allocator;

/// `-Dlu-instrument`: the `ZP_LU_STATS` census is compiled in.
pub const instrument = sparse_lu.instrument;

/// Threshold partial pivoting keeps the diagonal while
/// |diag| >= pivot_tol * column max (KLU's default 0.001).
pub const pivot_tol: f64 = 1e-3;
/// A re-pivot whose L plus U outgrows this multiple of the fresh factor's
/// restarts on the previous pivots (`SparseLu.fill_cap`).
const repivot_fill_cap: f64 = 3;
/// A BBD factor whose `Bbd.growth` exceeds this is probed: a refined solve
/// each way (A and A^T) whose scaled residual misses `probe_ratio_max`
/// demotes it to the general LU, else every solve on it is refined (#136).
/// Below it the certificate's ratio stayed under 0.04 (`residual_tests.zig`).
const bbd_refine_growth: f64 = 1e3;

/// Pivoting knobs. The defaults are the production settings.
pub const Params = struct {
    /// A refactor whose reused pivot falls below this fraction of its column
    /// max fails, forcing a full re-pivoting factor. 0 disables the monitor.
    /// Permissive for Newton, whose residual gate absorbs an inexact step
    /// and whose diverging iterates (values to 1e60) would otherwise
    /// re-pivot and fill every iteration; `FreqSolver`, whose solves are
    /// final, raises it to `pivot_tol` (#44). A replay that took a pivot
    /// below `pivot_tol` is probed and re-factored when its solves miss the
    /// threshold-pivoting bar (`replayHolds`). dev/solvers/gilbert-peierls-lu.md,
    /// "Two replay thresholds".
    refactor_growth_limit: f64 = 1e-12,
};

/// Refinement steps after a BBD solve at most (LAPACK dgerfs' ITMAX).
const refine_max = 5;
/// The probe's bar on ||b - A x|| / (||A|| ||x|| n eps): LAWN 41's 30
/// over 30, since one right-hand side only samples the error. On the
/// certificate's BBD family a probe at 27.7 let a solve through at 67;
/// refined solves that keep BBD probe at 0.2 or less (#136).
const probe_ratio_max = 1;

/// Developer switches. The facade reads them from the environment once
/// (`espice.zig`); the solver reads no environment.
pub const Knobs = struct {
    /// `ZP_LU_STATS`: print the BBD census and every full factor's fill.
    /// Read only under `-Dlu-instrument` (`instrument`).
    stats: bool = false,
    /// `ESPICE_NO_BBD`: force the flat LU, for A/B comparisons.
    no_bbd: bool = false,
    /// `ESPICE_LU_PAR=0/1`: force the multicore refactor off or on.
    par: ?bool = null,
    /// `ESPICE_LU_PAR_STATS`: print the multicore refactor's admission.
    par_stats: bool = false,
};

/// One linear engine, picked from the pattern by `Solver.init`.
pub const Engine = union(enum) {
    lu: sparse_lu.SparseLu,
    tri: tridiag_mod.TriDiag,
    bbd: bbd_mod.Bbd,
};

/// Sparse direct solver on one frozen CSC pattern.
pub const Solver = struct {
    const Self = @This();
    const SparseLu = sparse_lu.SparseLu;
    const TriDiag = tridiag_mod.TriDiag;
    const BbdEng = bbd_mod.Bbd;

    n: u32,
    /// Borrowed CSC pattern; must outlive the solver.
    col_ptr: []const u32,
    row_idx: []const u32,
    /// The live engine. The general LU is built only when a structured
    /// engine is demoted, so BBD and tridiagonal systems never pay for it.
    engine: Engine,
    gpa: Allocator,
    /// True once a factorization matches `vcopy`.
    factored: bool = false,
    params: Params = .{},
    knobs: Knobs,
    /// Owned column ordering handed to the LU; empty until the LU exists.
    q: []u32 = &.{},
    /// Values of the last factorization, for the unchanged-matrix bypass.
    vcopy: []f64 = &.{},
    /// Bumped whenever `vcopy` changes, by `factor` or by a device factor,
    /// so a device copy of the factors knows whether it is current.
    gen: u32 = 0,
    /// The multicore refactor of the current pivot epoch, when the cost
    /// model admitted it (`refactorLu`).
    par: ?lu_kernels.HostRefactor = null,
    /// Pivot epoch the cost model last judged.
    par_epoch: u32 = 0,
    /// A device factored `vcopy` and the LU still holds older values. The
    /// next host use refactors from `vcopy` first (bitwise the device's).
    host_stale: bool = false,
    /// BBD refinement scratch: the right-hand side, the residual,
    /// |A||x| + |b| and the probe's solution, n entries each. Empty on the
    /// other engines.
    refine_buf: []f64 = &.{},
    /// `replayHolds` scratch, 3n: the probe solution, its residual and the
    /// row sums of |A|. Empty until a replay first needs the probe.
    probe: []f64 = &.{},

    /// Chooses the engine from the pattern alone: tridiagonal, then BBD
    /// when `bbd` describes a profitable split, else sparse LU (whose AMD
    /// ordering fails with `OutOfWorkspace` on pathological fill). Borrows
    /// `col_ptr` and `row_idx`, which must outlive the solver; free with
    /// `deinit`. Asserts that `col_ptr` has n + 1 entries and `row_idx`
    /// covers them.
    pub fn init(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?num.BbdInfo, knobs: Knobs) !Self {
        assert(col_ptr.len == @as(usize, n) + 1);
        assert(row_idx.len >= col_ptr[n]);
        var self: Self = .{ .n = n, .col_ptr = col_ptr, .row_idx = row_idx, .engine = undefined, .gpa = gpa, .knobs = knobs };
        if (tridiag_mod.isTridiag(n, col_ptr, row_idx)) {
            self.engine = .{ .tri = try TriDiag.init(gpa, n, col_ptr, row_idx) };
        } else if (try initBbd(gpa, n, col_ptr, row_idx, bbd, knobs)) |eng| {
            self.engine = .{ .bbd = eng };
        } else {
            errdefer gpa.free(self.q);
            self.engine = .{ .lu = try self.initLu() };
        }
        errdefer self.deinit();
        self.vcopy = try gpa.alloc(f64, col_ptr[n]);
        if (self.engine == .bbd) self.refine_buf = try gpa.alloc(f64, 4 * @as(usize, n));
        assert(!self.factored);
        return self;
    }

    /// The general LU, or null while a structured engine is live.
    pub fn sparse(self: *Self) ?*SparseLu {
        return switch (self.engine) {
            .lu => |*lu| lu,
            .tri, .bbd => null,
        };
    }

    /// Orders the pattern (once) and builds the general LU on it.
    fn initLu(self: *Self) !SparseLu {
        if (self.q.len == 0) self.q = try computeOrdering(self.gpa, self.n, self.col_ptr, self.row_idx);
        assert(self.q.len == self.n);
        var lu = try SparseLu.init(self.gpa, self.n, self.col_ptr, self.q);
        lu.stats = self.knobs.stats;
        return lu;
    }

    /// Swaps a singular structured engine for the general LU, for good. The
    /// LU is built first, so out of memory leaves the old engine live.
    fn demote(self: *Self) !void {
        const lu = try self.initLu();
        switch (self.engine) {
            .lu => unreachable,
            .tri => |*tri| tri.deinit(self.gpa),
            .bbd => |*eng| eng.deinit(),
        }
        self.engine = .{ .lu = lu };
        self.factored = false;
        assert(self.sparse() != null);
    }

    fn initBbd(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?num.BbdInfo, knobs: Knobs) !?BbdEng {
        const info = bbd orelse {
            if (instrument and knobs.stats) std.debug.print("lu-census: no BbdInfo\n", .{});
            return null;
        };
        if (knobs.no_bbd) return null;
        const eng = BbdEng.init(gpa, n, col_ptr, row_idx, info, .{}) catch |err| switch (err) {
            error.NotApplicable => {
                if (instrument and knobs.stats) std.debug.print("lu-census: BbdInfo emitted; Bbd.init declined (NotApplicable)\n", .{});
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (instrument and knobs.stats) std.debug.print("lu-census: BbdInfo emitted; Bbd.init accepted\n", .{});
        return eng;
    }

    /// Frees every engine and copy; the borrowed pattern stays the caller's.
    pub fn deinit(self: *Self) void {
        if (self.par) |*p| p.deinit(self.gpa);
        switch (self.engine) {
            .lu => |*lu| lu.deinit(self.gpa),
            .tri => |*tri| tri.deinit(self.gpa),
            .bbd => |*eng| eng.deinit(),
        }
        self.gpa.free(self.q);
        self.gpa.free(self.vcopy);
        self.gpa.free(self.refine_buf);
        self.gpa.free(self.probe);
        self.* = undefined;
    }

    /// Factors `vals` (length nnz, pattern order). Returns at once when
    /// the values equal the last factored ones, which is common on linear
    /// circuits between timestep changes. Otherwise refactors on the
    /// existing pivot sequence and falls back to a full factor if the
    /// replay fails or its probe misses (`replayHolds`). The solver keeps
    /// its own copy of `vals` unless `dropBypass` ran. `execution`
    /// schedules the BBD block factors and the multicore refactor; `.{}`
    /// runs serially. A structured engine that meets a singular pivot is
    /// freed for good and the call retries on the general LU, as is a BBD
    /// factor that fails its refinement probe (`bbd_refine_growth`).
    /// `SingularMatrix` leaves no usable factorization, and neither does
    /// `OutOfMemory`: solve only after a successful `factor`. Asserts that
    /// `vals` holds at least the pattern's nnz entries.
    pub fn factor(self: *Self, vals: []const f64, execution: num.Execution) !void {
        assert(vals.len >= self.col_ptr[self.n]);
        const nnz = self.vcopy.len;
        if (nnz != 0 and self.factored and !self.host_stale and simdEql(self.vcopy, vals[0..nnz])) return;
        try self.factorInner(vals, execution);
        assert(self.factored);
        self.host_stale = false;
        num.copySimd(self.vcopy, vals[0..nnz]);
        self.gen +%= 1;
    }

    /// True when `vals` equal the last factored values (the bypass test).
    pub fn unchanged(self: *const Self, vals: []const f64) bool {
        return self.vcopy.len != 0 and self.factored and simdEql(self.vcopy, vals[0..self.vcopy.len]);
    }

    /// Frees the copy behind the unchanged-matrix bypass, for a caller whose
    /// values never repeat (a frequency sweep): every `factor` then factors.
    /// Not for a solver a device LU (`gpu_lu.zig`) shares, which syncs
    /// through the copy, nor for a BBD engine, whose solves refine against
    /// the copy and go unrefined without it.
    pub fn dropBypass(self: *Self) void {
        self.gpa.free(self.vcopy);
        self.vcopy = &.{};
    }

    /// Brings the LU up to `vcopy` after a device factor. The device ran
    /// this refactor's exact operations and passed its tests, so it cannot
    /// fail here.
    fn syncHost(self: *Self) void {
        if (!self.host_stale) return;
        assert(self.factored);
        self.sparse().?.refactor(self.col_ptr, self.vcopy, self.params.refactor_growth_limit) catch
            @panic("device LU passed a refactor the host fails");
        self.host_stale = false;
    }

    fn factorInner(self: *Self, vals: []const f64, execution: num.Execution) !void {
        // A refactor that fails after overwriting the LU (the probe's OOM)
        // must not leave the old `vcopy` bypassing onto it.
        errdefer self.factored = false;
        switch (self.engine) {
            .lu => {},
            // Thomas has no pivoting, so an MNA branch row's zero diagonal
            // fails here. ponytail: vsource-bearing ladders lose the
            // tridiagonal speed; a 2x2-block-pivot Thomas would recover it.
            .tri => |*tri| if (tri.factor(vals, pivot_tol)) |_| {
                self.factored = true;
                return;
            } else |_| try self.demote(),
            // A singular block, or a Schur reduction too unstable to refine.
            // BBD wants one value per pattern entry: drop the trash slot past it.
            .bbd => |*eng| if (eng.factorWithExecution(vals[0..self.col_ptr[self.n]], execution)) |_| {
                if (!(eng.growth > bbd_refine_growth) or self.probeBbd(eng, vals[0..self.col_ptr[self.n]])) {
                    self.factored = true;
                    return;
                }
                try self.demote();
            } else |_| try self.demote(),
        }
        const lu = &self.engine.lu;
        lu.fill_cap = repivot_fill_cap;
        lu.keep_min = self.params.refactor_growth_limit;
        const ptol = pivot_tol;
        if (self.factored) {
            if (self.refactorLu(vals, execution)) |_| {
                if (try self.replayHolds(vals)) return;
            } else |_| {}
            self.factored = false;
        }
        try lu.factor(self.gpa, self.col_ptr, self.row_idx, vals, ptol);
        self.factored = true;
    }

    /// Whether the replay that just refactored `vals` solves as threshold
    /// pivoting promises. The growth monitor admits a pivot down to
    /// `refactor_growth_limit` (1e-12) of its column, for Newton's sake, and
    /// on an ill-conditioned matrix such a replay reached a LAWN 41 ratio
    /// of 1.5e6 where a fresh factor gives 0.019 (#45, #136). A replay
    /// whose multipliers all stay within 1/pivot_tol is one the full factor
    /// could have laid down and passes at once. Otherwise a probe
    /// right-hand side is solved both ways and each scaled residual must
    /// stay within `replay_ratio_max / pivot_tol`, the residual
    /// certificate's bar for threshold pivoting; a miss sends the caller to
    /// a full factor. The check sits here, not in `solve`, so one probe
    /// covers every later `solve`, `solveNeg` and `solveT`, and only a
    /// fallible call re-factors. O(|L|) per replay for the scan; the probe
    /// (two solves, two passes over A) runs only after a marginal replay.
    /// `FreqSolver` replays at pivot_tol, so it never probes. ponytail: a
    /// device factor (`syncHost`, the device LU's own solve) is not
    /// probed; check on the host after the sync if that path needs it.
    fn replayHolds(self: *Self, vals: []const f64) !bool {
        const lu = &self.engine.lu;
        const ptol = pivot_tol;
        if (!(ptol > 0)) return true;
        if (maxMultiplier(lu) <= 1 / ptol) return true;
        const n: usize = self.n;
        if (self.probe.len == 0) self.probe = try self.gpa.alloc(f64, 3 * n);
        assert(self.probe.len == 3 * n);
        const x = self.probe[0..n];
        const r = self.probe[n..][0..n];
        const rows = self.probe[2 * n ..][0..n];
        // ||A||_inf from the row sums, ||A||_1 = ||A^T||_inf from the columns.
        @memset(rows, 0);
        var norm_1: f64 = 0;
        for (0..n) |j| {
            var col: f64 = 0;
            for (self.col_ptr[j]..self.col_ptr[j + 1]) |p| {
                const a = @abs(vals[p]);
                rows[self.row_idx[p]] += a;
                col += a;
            }
            norm_1 = @max(norm_1, col);
        }
        const norm_inf = maxAbs(rows);
        const nf: f64 = @floatFromInt(n);
        inline for (.{ false, true }) |transpose| {
            probeRhs(r);
            if (transpose) lu.solveT(r, x) else lu.solve(r, x);
            probeRhs(r);
            // r = b - A x, or b - A^T x.
            for (0..n) |j| for (self.col_ptr[j]..self.col_ptr[j + 1]) |p| {
                const i = self.row_idx[p];
                if (transpose) r[j] -= vals[p] * x[i] else r[i] -= vals[p] * x[j];
            };
            const a_norm = if (transpose) norm_1 else norm_inf;
            const ratio = maxAbs(r) / (a_norm * maxAbs(x) * nf * std.math.floatEps(f64));
            // Negated, so a NaN ratio fails too.
            if (!(ratio <= replay_ratio_max / ptol)) return false;
        }
        return true;
    }

    /// `lu.refactor`, on `execution.lu_threads` workers when the flop-count
    /// model below prices that faster. Bitwise the same either way.
    fn refactorLu(self: *Self, vals: []const f64, execution: num.Execution) error{SingularMatrix}!void {
        assert(self.factored);
        const lu = &self.engine.lu;
        const growth = self.params.refactor_growth_limit;
        const threads = execution.lu_threads;
        const io = execution.io orelse return lu.refactor(self.col_ptr, vals, growth);
        if (threads < 2) return lu.refactor(self.col_ptr, vals, growth);
        if (self.par_epoch != lu.pattern_epoch) {
            self.par_epoch = lu.pattern_epoch;
            if (self.par) |*p| p.deinit(self.gpa);
            self.par = null;
            // Out of memory for the tables: stay serial this epoch.
            if (parWorthIt(lu, self.knobs)) self.par = lu_kernels.HostRefactor.init(self.gpa, lu, self.col_ptr, growth) catch null;
        }
        const p = if (self.par) |*p| p else return lu.refactor(self.col_ptr, vals, growth);
        return p.run(lu, vals, io, threads);
    }

    /// Solves in place with whichever engine is live.
    fn solveInPlace(self: *Self, x: []f64) void {
        assert(self.factored);
        assert(x.len >= self.n);
        self.syncHost();
        switch (self.engine) {
            .lu => |*lu| lu.solve(x[0..self.n], x[0..self.n]),
            .tri => |*tri| tri.solve(x[0..self.n]),
            .bbd => |*eng| self.solveBbd(eng, false, x[0..self.n]),
        }
    }

    /// The BBD solve, refined against `vcopy` when the factor's Schur
    /// growth says it may not be backward stable (#136).
    fn solveBbd(self: *Self, eng: *BbdEng, comptime transpose: bool, x: []f64) void {
        if (!(eng.growth > bbd_refine_growth) or self.vcopy.len == 0) {
            if (transpose) eng.solveTInPlace(x) else eng.solveInPlace(x);
            return;
        }
        const b = self.refine_buf[0..self.n];
        num.copySimd(b, x);
        if (transpose) eng.solveTInPlace(x) else eng.solveInPlace(x);
        self.refine(eng, transpose, self.vcopy, b, x);
    }

    /// Solves a fixed pseudo-random right-hand side on the fresh factor of
    /// `vals`, both ways, refines each, and reports whether both scaled
    /// residuals meet `probe_ratio_max`. Refinement in working precision
    /// cannot recover a Schur reduction whose error outgrows the solution,
    /// which this catches before any caller solves.
    fn probeBbd(self: *Self, eng: *BbdEng, vals: []const f64) bool {
        return self.probeOne(eng, false, vals) and self.probeOne(eng, true, vals);
    }

    fn probeOne(self: *Self, eng: *BbdEng, comptime transpose: bool, vals: []const f64) bool {
        const n = self.n;
        const b = self.refine_buf[0..n];
        const r = self.refine_buf[n..][0..n];
        const s = self.refine_buf[2 * n ..][0..n];
        const x = self.refine_buf[3 * n ..][0..n];
        for (b, 0..) |*bi, i| {
            const h = (@as(u64, i) +% 1) *% 0x9E3779B97F4A7C15;
            bi.* = @as(f64, @floatFromInt(h >> 11)) / 0x1p53 * 2 - 1;
        }
        num.copySimd(x, b);
        if (transpose) eng.solveTInPlace(x) else eng.solveInPlace(x);
        self.refine(eng, transpose, vals, b, x);
        // r = b - op(A) x and s = the row sums of |op(A)|.
        num.copySimd(r, b);
        @memset(s, 0);
        for (0..n) |j| for (self.col_ptr[j]..self.col_ptr[j + 1]) |p| {
            const i = self.row_idx[p];
            const row = if (transpose) j else i;
            r[row] -= vals[p] * x[if (transpose) i else j];
            s[row] += @abs(vals[p]);
        };
        const nf: f64 = @floatFromInt(n);
        const ratio = num.normInf(r) / (num.normInf(s) * num.normInf(x) * nf * std.math.floatEps(f64));
        return ratio <= probe_ratio_max;
    }

    /// Fixed-precision iterative refinement of `x` against `vals`, as
    /// LAPACK's dgerfs: stop once the componentwise backward error
    /// max |r_i| / (|A||x| + |b|)_i reaches eps or stops halving.
    fn refine(self: *Self, eng: *BbdEng, comptime transpose: bool, vals: []const f64, b: []const f64, x: []f64) void {
        const n = self.n;
        const r = self.refine_buf[n..][0..n];
        const s = self.refine_buf[2 * n ..][0..n];
        assert(self.refine_buf.len == 4 * @as(usize, n));
        var last: f64 = 3;
        for (0..refine_max) |_| {
            num.copySimd(r, b);
            // ponytail: plain loops on a path only a high-growth BBD factor
            // takes; the sparse walk could not vectorize anyway.
            for (s, b) |*si, bi| si.* = @abs(bi);
            for (0..n) |j| for (self.col_ptr[j]..self.col_ptr[j + 1]) |p| {
                const i = self.row_idx[p];
                const ax = vals[p] * x[if (transpose) i else j];
                const row = if (transpose) j else i;
                r[row] -= ax;
                s[row] += @abs(ax);
            };
            var berr: f64 = 0;
            for (r, s) |ri, si| if (si > 0) {
                berr = @max(berr, @abs(ri) / si);
            };
            if (!(berr > std.math.floatEps(f64) and 2 * berr <= last)) break;
            last = berr;
            if (transpose) eng.solveTInPlace(r) else eng.solveInPlace(r);
            num.axpy(x, 1, r);
        }
    }

    /// x = -A^-1 rhs, the Newton step. `rhs` and `x` may alias. Asserts that
    /// the last `factor` succeeded and that both slices hold n entries.
    pub fn solveNeg(self: *Self, rhs: []const f64, x: []f64) void {
        assert(rhs.len >= self.n);
        assert(x.len >= self.n);
        num.scale(x[0..self.n], -1, rhs[0..self.n]);
        self.solveInPlace(x);
    }

    /// x = A^-1 rhs. `rhs` and `x` may alias. Asserts as `solveNeg` does.
    pub fn solve(self: *Self, rhs: []const f64, x: []f64) void {
        assert(rhs.len >= self.n);
        assert(x.len >= self.n);
        if (rhs.ptr != x.ptr) @memcpy(x[0..self.n], rhs[0..self.n]);
        self.solveInPlace(x);
    }

    /// x = A^-T rhs, for adjoint analyses. `rhs` and `x` may alias. Asserts
    /// as `solveNeg` does.
    pub fn solveT(self: *Self, rhs: []const f64, x: []f64) void {
        assert(self.factored);
        assert(rhs.len >= self.n);
        assert(x.len >= self.n);
        if (rhs.ptr != x.ptr) @memcpy(x[0..self.n], rhs[0..self.n]);
        self.syncHost();
        switch (self.engine) {
            .lu => |*lu| lu.solveT(x[0..self.n], x[0..self.n]),
            .tri => |*tri| tri.solveT(x[0..self.n]),
            .bbd => |*eng| self.solveBbd(eng, true, x[0..self.n]),
        }
    }
};

/// The multicore refactor's admission: enough flops per refactor to pay
/// for the handoffs, and enough per column that the columns are not a
/// dependent chain. `Knobs.par` forces it off or on.
fn parWorthIt(lu: *const sparse_lu.SparseLu, knobs: Knobs) bool {
    assert(lu.factored);
    var flops: u64 = 0;
    for (lu.ui.items) |i| flops += lu.lp[i + 1] - lu.lp[i];
    // Tape-sized factors refactor in microseconds.
    var ok = lu.tv.items.len == 0 and flops >= par_min_flops and flops >= par_min_per_col * @as(u64, lu.n) and flops <= par_max_flops;
    if (knobs.par) |forced| ok = forced;
    if (knobs.par_stats)
        std.debug.print("lu-par: n={d} F={d} F/n={d} admit={}\n", .{ lu.n, flops, flops / @max(lu.n, 1), ok });
    return ok;
}

/// LAPACK's LAWN 41 bar for a backward-stable solve. `replayHolds` divides
/// it by `pivot_tol`, as the residual certificate does for threshold
/// pivoting (residual_tests.zig `ratio_max_pivoting`): multipliers up to
/// 1/pivot_tol are the full factor's own.
const replay_ratio_max = 30.0;

/// The largest |L| entry over the steps the refactor's growth monitor
/// covers. A replay writes L as v / d, so its smallest accepted pivot
/// ratio is 1 / max(1, this), whichever kernel ran it (tape, columns,
/// threads). Scale-accepted steps are left out: their pivots sit decades
/// below the raw column by design. Runs on every replay, so it is the
/// vector `normInf`, which skips NaN; a NaN multiplier reaches the solve,
/// whose NaN the Newton gates refuse.
fn maxMultiplier(lu: *const sparse_lu.SparseLu) f64 {
    const lx = lu.lx.items;
    if (std.mem.indexOfScalar(bool, lu.scaled_pivot, true) == null) return num.normInf(lx);
    var m: f64 = 0;
    for (0..lu.n) |k| {
        if (lu.scaled_pivot[k]) continue;
        m = @max(m, num.normInf(lx[lu.lp[k]..lu.lp[k + 1]]));
    }
    return m;
}

/// max |s[i]|, 0 for an empty slice; NaN when any entry is NaN, unlike
/// `numerics.normInf`, which skips NaN. The probe's norms, cold.
fn maxAbs(s: []const f64) f64 {
    var m: f64 = 0;
    for (s) |v| {
        if (std.math.isNan(v)) return v;
        m = @max(m, @abs(v));
    }
    return m;
}

/// Higham's alternating probe, b[i] = (-1)^i (1 + i / (n - 1)): no
/// structure a circuit matrix shares, the right-hand side LAPACK's
/// condition estimators use (dlacn2's last vector).
fn probeRhs(b: []f64) void {
    const den: f64 = @floatFromInt(@max(b.len, 2) - 1);
    for (b, 0..) |*v, i| {
        const mag = 1 + @as(f64, @floatFromInt(i)) / den;
        v.* = if (i % 2 == 0) mag else -mag;
    }
}

/// Measured on the post-layout and stress decks, 2 to 8 threads
/// (dev/solvers/gpu-lu.md, "Multicore host refactor"): F/n = 445 and up
/// wins at every thread count from F = 0.78M (sram_bsim4_1k); F/n = 152
/// breaks even at 4 and 8 threads and loses at 2; F/n <= 95 loses up to 12x
/// (the columns form a chain, and every handoff is a wait). ponytail: one
/// F/n bar for every thread count; fit per count if a deck lands between.
const par_min_flops = 500_000;
const par_min_per_col = 300;
/// 4 bytes of tables per flop.
const par_max_flops = 400_000_000;
comptime {
    assert(par_min_flops <= par_max_flops);
    // The multicore tables hold u32 offsets.
    assert(par_max_flops <= std.math.maxInt(u32));
}

/// BTF + AMD column ordering; caller owns the result.
fn computeOrdering(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32) ![]u32 {
    const q = try gpa.alloc(u32, n);
    errdefer gpa.free(q);
    const ws_buf = try gpa.alloc(u32, order_mod.wsSize(n, col_ptr[n]));
    defer gpa.free(ws_buf);
    var ws = order_mod.Ws.init(ws_buf);
    try order_mod.order(n, col_ptr, row_idx, q, &ws);
    assert(ws.used == 0); // order restores the slab
    return q;
}

/// IEEE equality per element (-0 == +0, NaN != NaN) and equal lengths.
/// stdpp's mismatch search: four vector blocks per branch.
fn simdEql(a: []const f64, b: []const f64) bool {
    return z.fromSlice(f64, a).eq(z.fromSlice(f64, b));
}

const testing = std.testing;

test simdEql {
    const builtin = @import("builtin");
    // Other self-hosted backends run stdpp's scalar fallback.
    if (builtin.zig_backend == .stage2_llvm or builtin.zig_backend == .stage2_x86_64)
        comptime std.debug.assert(@TypeOf(z.fromSlice(f64, &.{})).lane_count != null);
    const Ref = struct {
        fn scalar(a: []const f64, b: []const f64) bool {
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (x != y) return false;
            return true;
        }
        fn pull(a: []const f64, b: []const f64) bool {
            var src = z.fromSlice(f64, a);
            return src.byRef().eq(z.fromSlice(f64, b));
        }
        fn check(a: []const f64, b: []const f64) !void {
            const want = scalar(a, b);
            try testing.expectEqual(want, simdEql(a, b));
            try testing.expectEqual(want, pull(a, b));
        }
    };
    var buf_a: [208]f64 = undefined;
    var buf_b: [208]f64 = undefined;
    var prng = std.Random.DefaultPrng.init(0xe91);
    const r = prng.random();
    for (&buf_a, &buf_b) |*a, *b| {
        a.* = r.float(f64) - 0.5;
        b.* = a.*;
    }
    // Past 3x the widest f64 lane count, at several misalignments, with
    // one planted change at a spread of positions: a different value, a
    // NaN on both sides (unequal), zeros of opposite sign (equal).
    for (0..201) |n| for (0..3) |off| {
        const a = buf_a[off..][0..n];
        const b = buf_b[off..][0..n];
        try Ref.check(a, b);
        if (n > 0) try Ref.check(a, b[0 .. n - 1]);
        const step = @max(1, n / 16);
        for (0..n) |i| {
            if (i % step != 0 and i != n - 1) continue;
            const ka = a[i];
            const kb = b[i];
            defer {
                a[i] = ka;
                b[i] = kb;
            }
            b[i] = kb + 1;
            try Ref.check(a, b);
            a[i] = std.math.nan(f64);
            b[i] = a[i];
            try Ref.check(a, b);
            a[i] = 0;
            b[i] = -0.0;
            try Ref.check(a, b);
        }
    };
}

test "Solver: a tridiagonal pattern with a zero diagonal demotes to the pivoting LU" {
    // A = [0 1 0; 1 2 4; 0 1 3]: row 0 is an MNA branch row with no
    // diagonal value, so Thomas fails at its first pivot.
    const gpa = testing.allocator;
    const col_ptr = [_]u32{ 0, 2, 5, 7 };
    const row_idx = [_]u32{ 0, 1, 0, 1, 2, 1, 2 };
    var vals = [_]f64{ 0, 1, 1, 2, 1, 4, 3 };
    var s = try Solver.init(gpa, 3, &col_ptr, &row_idx, null, .{});
    defer s.deinit();
    try testing.expect(s.engine == .tri);
    try s.factor(&vals, .{});
    try testing.expect(s.engine == .lu);

    // A [1 2 3] = [2 17 11], A^T [1 2 3] = [2 8 17].
    var x: [3]f64 = undefined;
    s.solve(&.{ 2, 17, 11 }, &x);
    for (x, [_]f64{ 1, 2, 3 }) |xi, want| try testing.expectApproxEqAbs(want, xi, 1e-12);
    s.solveT(&.{ 2, 8, 17 }, &x);
    for (x, [_]f64{ 1, 2, 3 }) |xi, want| try testing.expectApproxEqAbs(want, xi, 1e-12);

    // The same values again are the bypass: no new generation. A NaN never
    // matches, so it always refactors.
    const gen = s.gen;
    try s.factor(&vals, .{});
    try testing.expectEqual(gen, s.gen);
    try testing.expect(s.unchanged(&vals));
    vals[3] = std.math.nan(f64);
    try testing.expect(!s.unchanged(&vals));
}
