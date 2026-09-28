//! Fixed-pattern sparse direct solver: the facade every Newton caller uses.
//! Picks an engine from the pattern (tridiagonal, bordered block diagonal or
//! general sparse LU), skips refactoring when the values did not change, and
//! demotes to the general LU when a structured engine meets a singular pivot.

const std = @import("std");
const sparse_lu = @import("sparse_lu.zig");
const tridiag_mod = @import("tridiag.zig");
const order_mod = @import("order.zig");
const bbd_mod = @import("bbd.zig");
const lu_kernels = @import("lu_kernels.zig");
const root = @import("core").numerics;

const Allocator = std.mem.Allocator;

/// Pivoting knobs. The defaults are the production settings.
pub const Params = struct {
    /// Threshold partial pivoting keeps the diagonal while
    /// |diag| >= pivot_tol * column max (KLU's default 0.001).
    pivot_tol: f64 = 1e-3,
    /// A refactor whose reused pivot falls below this fraction of its column
    /// max fails, forcing a full re-pivoting factor. 0 disables the monitor.
    refactor_growth_limit: f64 = 1e-12,
    /// A re-pivot whose L plus U outgrows this multiple of the fresh
    /// factor's restarts on the previous pivots (`SparseLu.fill_cap`).
    repivot_fill_cap: f64 = 3,
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
    /// At most one engine is live. `lu` is built lazily when a structured
    /// engine is demoted, so BBD and tridiagonal systems never pay for it.
    lu: ?SparseLu,
    tri: ?TriDiag,
    bbd_eng: ?BbdEng = null,
    gpa: Allocator,
    /// True once a factorization matches `vcopy`.
    factored: bool = false,
    params: Params = .{},
    /// Owned column ordering handed to `lu`; empty until `lu` exists.
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
    /// A device factored `vcopy` and `lu` still holds older values. The
    /// next host use refactors from `vcopy` first (bitwise the device's).
    host_stale: bool = false,

    /// Chooses the engine from the pattern alone: tridiagonal, then BBD
    /// when `bbd` describes a profitable split, else sparse LU.
    pub fn init(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?root.BbdInfo) !Self {
        var self: Self = .{ .n = n, .col_ptr = col_ptr, .row_idx = row_idx, .lu = null, .tri = null, .gpa = gpa };
        errdefer self.deinit();
        if (tridiag_mod.isTridiag(n, col_ptr, row_idx)) {
            self.tri = try TriDiag.init(gpa, n, col_ptr, row_idx);
        } else if (try initBbd(gpa, n, col_ptr, row_idx, bbd)) |eng| {
            self.bbd_eng = eng;
        } else {
            self.q = try computeOrdering(gpa, n, col_ptr, row_idx);
            self.lu = try SparseLu.init(gpa, n, col_ptr, row_idx, self.q);
        }
        self.vcopy = try gpa.alloc(f64, col_ptr[n]);
        return self;
    }

    fn initBbd(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?root.BbdInfo) !?BbdEng {
        const info = bbd orelse {
            if (comptime @import("builtin").link_libc) if (std.c.getenv("ZP_LU_STATS") != null) std.debug.print("lu-census: no BbdInfo\n", .{});
            return null;
        };
        // ESPICE_NO_BBD forces the flat LU for A/B comparisons.
        if (comptime @import("builtin").link_libc) {
            if (std.c.getenv("ESPICE_NO_BBD") != null) return null;
        }
        const stats = comptime @import("builtin").link_libc;
        const eng = BbdEng.init(gpa, n, col_ptr, row_idx, info, .{}) catch |err| switch (err) {
            error.NotApplicable => {
                if (stats) if (std.c.getenv("ZP_LU_STATS") != null) std.debug.print("lu-census: BbdInfo emitted; Bbd.init declined (NotApplicable)\n", .{});
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (stats) if (std.c.getenv("ZP_LU_STATS") != null) std.debug.print("lu-census: BbdInfo emitted; Bbd.init accepted\n", .{});
        return eng;
    }

    pub fn deinit(self: *Self) void {
        if (self.par) |*p| p.deinit(self.gpa);
        if (self.lu) |*lu| lu.deinit(self.gpa);
        if (self.tri) |*tri| tri.deinit(self.gpa);
        if (self.bbd_eng) |*eng| eng.deinit();
        self.gpa.free(self.q);
        self.gpa.free(self.vcopy);
        self.* = undefined;
    }

    /// Factors `vals` (length nnz, pattern order). Returns at once when
    /// the values equal the last factored ones, which is common on linear
    /// circuits between timestep changes. Otherwise refactors on the
    /// existing pivot sequence and falls back to a full factor if the
    /// replay fails. The solver keeps its own copy of `vals`. `execution`
    /// schedules the BBD block factors; `.{}` runs them serially.
    pub fn factor(self: *Self, vals: []const f64, execution: root.Execution) !void {
        const nnz = self.vcopy.len;
        if (self.factored and !self.host_stale and simdEql(self.vcopy, vals[0..nnz])) return;
        try self.factorInner(vals, execution);
        self.host_stale = false;
        @memcpy(self.vcopy, vals[0..nnz]);
        self.gen +%= 1;
    }

    /// True when `vals` equal the last factored values (the bypass test).
    pub fn unchanged(self: *const Self, vals: []const f64) bool {
        return self.factored and simdEql(self.vcopy, vals[0..self.vcopy.len]);
    }

    /// Brings `lu` up to `vcopy` after a device factor. The device ran
    /// this refactor's exact operations and passed its tests, so it cannot
    /// fail here.
    fn syncHost(self: *Self) void {
        if (!self.host_stale) return;
        self.lu.?.refactor(self.col_ptr, self.vcopy, self.params.refactor_growth_limit) catch
            @panic("device LU passed a refactor the host fails");
        self.host_stale = false;
    }

    fn factorInner(self: *Self, vals: []const f64, execution: root.Execution) !void {
        if (self.tri) |*tri| {
            if (tri.factor(vals)) |_| {
                self.factored = true;
                return;
            } else |_| {
                // Thomas has no pivoting, so an MNA branch row's zero
                // diagonal lands here. Demote to the pivoting LU for good.
                // ponytail: vsource-bearing ladders lose the tridiagonal
                // speed; a 2x2-block-pivot Thomas would recover it.
                tri.deinit(self.gpa);
                self.tri = null;
                self.factored = false;
            }
        }
        if (self.bbd_eng) |*eng| {
            if (eng.factorWithExecution(vals, execution)) |_| {
                self.factored = true;
                return;
            } else |_| {
                // A singular block: demote to the flat LU for good.
                eng.deinit();
                self.bbd_eng = null;
                self.factored = false;
            }
        }
        if (self.lu == null) {
            if (self.q.len == 0) self.q = try computeOrdering(self.gpa, self.n, self.col_ptr, self.row_idx);
            self.lu = try SparseLu.init(self.gpa, self.n, self.col_ptr, self.row_idx, self.q);
        }
        const lu = &self.lu.?;
        lu.fill_cap = self.params.repivot_fill_cap;
        const ptol = self.params.pivot_tol;
        if (self.factored) {
            if (self.refactorLu(vals, execution)) |_| return else |_| {}
            self.factored = false;
        }
        try lu.factor(self.gpa, self.col_ptr, self.row_idx, vals, ptol);
        self.factored = true;
    }

    /// `lu.refactor`, on `execution.lu_threads` workers when the flop-count
    /// model below prices that faster. Bitwise the same either way.
    fn refactorLu(self: *Self, vals: []const f64, execution: root.Execution) error{SingularMatrix}!void {
        const lu = &self.lu.?;
        const growth = self.params.refactor_growth_limit;
        const threads = execution.lu_threads;
        const io = execution.io orelse return lu.refactor(self.col_ptr, vals, growth);
        if (threads < 2) return lu.refactor(self.col_ptr, vals, growth);
        if (self.par_epoch != lu.pattern_epoch) {
            self.par_epoch = lu.pattern_epoch;
            if (self.par) |*p| p.deinit(self.gpa);
            self.par = null;
            // Out of memory for the tables: stay serial this epoch.
            if (parWorthIt(lu)) self.par = lu_kernels.HostRefactor.init(self.gpa, lu, self.col_ptr, growth) catch null;
        }
        const p = if (self.par) |*p| p else return lu.refactor(self.col_ptr, vals, growth);
        return p.run(lu, vals, io, threads);
    }

    /// Solves in place with whichever engine is live.
    fn solveInPlace(self: *Self, x: []f64) void {
        self.syncHost();
        if (self.tri) |*tri| return tri.solve(x[0..self.n]);
        if (self.bbd_eng) |*eng| return eng.solveInPlace(x[0..self.n]);
        self.lu.?.solve(x[0..self.n], x[0..self.n]);
    }

    /// x = -A^-1 rhs, the Newton step. `rhs` and `x` may alias.
    pub fn solveNeg(self: *Self, rhs: []const f64, x: []f64) void {
        negateSimd(rhs[0..self.n], x[0..self.n]);
        self.solveInPlace(x);
    }

    /// x = A^-1 rhs. `rhs` and `x` may alias.
    pub fn solve(self: *Self, rhs: []const f64, x: []f64) void {
        if (rhs.ptr != x.ptr) @memcpy(x[0..self.n], rhs[0..self.n]);
        self.solveInPlace(x);
    }

    /// x = A^-T rhs, for adjoint analyses. `rhs` and `x` may alias.
    pub fn solveT(self: *Self, rhs: []const f64, x: []f64) void {
        if (rhs.ptr != x.ptr) @memcpy(x[0..self.n], rhs[0..self.n]);
        self.syncHost();
        if (self.tri) |*tri| return tri.solveT(x[0..self.n]);
        if (self.bbd_eng) |*eng| return eng.solveTInPlace(x[0..self.n]);
        self.lu.?.solveT(x[0..self.n], x[0..self.n]);
    }
};

/// The multicore refactor's admission: enough flops per refactor to pay
/// for the handoffs, and enough per column that the columns are not a
/// dependent chain. `ESPICE_LU_PAR=0/1` forces it off or on.
fn parWorthIt(lu: *const sparse_lu.SparseLu) bool {
    var flops: u64 = 0;
    for (lu.ui.items) |i| flops += lu.lp[i + 1] - lu.lp[i];
    // Tape-sized factors refactor in microseconds.
    var ok = lu.tv.items.len == 0 and flops >= par_min_flops and flops >= par_min_per_col * @as(u64, lu.n) and flops <= par_max_flops;
    if (comptime @import("builtin").link_libc) {
        if (std.c.getenv("ESPICE_LU_PAR")) |v| ok = v[0] == '1';
        if (std.c.getenv("ESPICE_LU_PAR_STATS") != null)
            std.debug.print("lu-par: n={d} F={d} F/n={d} admit={}\n", .{ lu.n, flops, flops / @max(lu.n, 1), ok });
    }
    return ok;
}

/// Measured on the post-layout and stress decks, 2 to 8 threads
/// (docs/solvers/gpu-lu.md, "Multicore host refactor"): F/n = 445 and up
/// wins at every thread count from F = 0.78M (sram_bsim4_1k); F/n = 152
/// breaks even at 4 and 8 threads and loses at 2; F/n <= 95 loses up to 12x
/// (the columns form a chain, and every handoff is a wait). ponytail: one
/// F/n bar for every thread count; fit per count if a deck lands between.
const par_min_flops = 500_000;
const par_min_per_col = 300;
/// 4 bytes of tables per flop.
const par_max_flops = 400_000_000;

/// BTF + AMD column ordering; caller owns the result.
fn computeOrdering(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32) ![]u32 {
    const q = try gpa.alloc(u32, n);
    errdefer gpa.free(q);
    const ws_buf = try gpa.alloc(u32, order_mod.wsSize(n, col_ptr[n]));
    defer gpa.free(ws_buf);
    var ws = order_mod.Ws.init(ws_buf);
    try order_mod.order(n, col_ptr, row_idx, q, &ws);
    return q;
}

/// Bitwise-meaningful float equality (-0 == +0, NaN != NaN), W lanes at a time.
fn simdEql(a: []const f64, b: []const f64) bool {
    const W = std.simd.suggestVectorLength(f64) orelse 1;
    const V = @Vector(W, f64);
    var i: usize = 0;
    while (i + W <= a.len) : (i += W) {
        const av: V = a[i..][0..W].*;
        const bv: V = b[i..][0..W].*;
        if (@reduce(.Or, av != bv)) return false;
    }
    for (a[i..], b[i..]) |ai, bi| {
        if (ai != bi) return false;
    }
    return true;
}

fn negateSimd(src: []const f64, dst: []f64) void {
    const W = std.simd.suggestVectorLength(f64) orelse 1;
    const V = @Vector(W, f64);
    var i: usize = 0;
    while (i + W <= src.len) : (i += W) {
        const v: V = src[i..][0..W].*;
        dst[i..][0..W].* = -v;
    }
    for (src[i..], dst[i..]) |s, *d| d.* = -s;
}
