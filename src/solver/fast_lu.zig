//! `fast_mode` (docs/solvers/gpu-lu.md, "fast_mode"): the refactor runs in
//! f32 on the f64 factor's pivot tape, after an exact power-of-two
//! equilibration, and the solve reaches f64 backward error by mixed-precision
//! iterative refinement (residuals in f64, corrections through the f32
//! factors), switching to GMRES-IR when plain refinement contracts slowly.
//! Not bitwise the f64 path. A solve that misses the stop test returns false
//! and the caller runs the exact f64 factor and solve for that iteration.

const std = @import("std");
const SparseLu = @import("sparse_lu.zig").SparseLu;
const lu_kernels = @import("lu_kernels.zig");
const Gmres = @import("gmres.zig").Gmres;

/// Growth limit of the f32 refactor's pivot monitor: f32 keeps about 7
/// digits, so a pivot 1e-6 below its column cannot help refinement.
pub const growth_f32 = 1e-6;
/// Stop test: normwise backward error ||r|| <= stop_c * u64 * (||A|| ||x||
/// + ||b||), with u64 = 2^-53.
pub const stop_c = 16;
/// Plain refinement steps before giving up on it.
const max_ir = 8;
/// A step that shrinks the backward error by less than this factor sends
/// the solve to GMRES-IR.
const slow_rate = 0.5;
/// GMRES-IR: outer steps, and the Krylov depth of each (one cycle).
const max_gmres_ir = 3;
const gmres_m = 30;

/// Counters of a query's fast solves, for `ESPICE_LU_FAST_STATS`.
pub const Stats = struct {
    refactors: u64 = 0,
    /// f32 refactors whose pivot test failed (the f64 path ran instead).
    refactor_fails: u64 = 0,
    solves: u64 = 0,
    /// Refinement corrections, plain and GMRES-IR outer steps.
    iterations: u64 = 0,
    gmres: u64 = 0,
    /// Solves that missed the stop test (the f64 path ran instead).
    fallbacks: u64 = 0,

    pub fn add(self: *Stats, o: Stats) void {
        inline for (@typeInfo(Stats).@"struct".fields) |f| @field(self, f.name) += @field(o, f.name);
    }
};

/// The f64 side of a fast solve: A's values and norm, the scaling, the
/// refinement loop. The f32 factors live with whoever factors (host threads
/// or the device) and come in as the `corr` argument of `solve`.
pub const Refiner = struct {
    n: u32,
    col_ptr: []const u32,
    row_idx: []const u32,
    /// A's values the f32 factors were built from, CSC order.
    fa: []f64,
    anorm: f64 = 0,
    /// Row scale (by original row) and column scale: powers of two, so
    /// R A C is exact in f64.
    rs: []f64,
    cs: []f64,
    r: []f64,
    d: []f64,
    /// GMRES-IR's right-hand side, and the preconditioner's output.
    b: []f64,
    p: []f64,
    r32: []f32,
    dx32: []f32,
    gm: ?Gmres = null,
    stats: Stats = .{},

    /// Borrows the pattern. Caller owns the result; free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32) !Refiner {
        const nnz = col_ptr[n];
        var self: Refiner = .{ .n = n, .col_ptr = col_ptr, .row_idx = row_idx, .fa = &.{}, .rs = &.{}, .cs = &.{}, .r = &.{}, .d = &.{}, .b = &.{}, .p = &.{}, .r32 = &.{}, .dx32 = &.{} };
        errdefer self.deinit(gpa);
        self.fa = try gpa.alloc(f64, nnz);
        inline for (.{ "rs", "cs", "r", "d", "b", "p" }) |f| @field(self, f) = try gpa.alloc(f64, n);
        self.r32 = try gpa.alloc(f32, n);
        self.dx32 = try gpa.alloc(f32, n);
        return self;
    }

    pub fn deinit(self: *Refiner, gpa: std.mem.Allocator) void {
        if (self.gm) |*g| g.deinit(gpa);
        gpa.free(self.fa);
        inline for (.{ "rs", "cs", "r", "d", "b", "p" }) |f| gpa.free(@field(self, f));
        gpa.free(self.r32);
        gpa.free(self.dx32);
        self.* = undefined;
    }

    /// Takes `vals` as the matrix to solve with: records them and ||A||,
    /// picks the scaling and writes R A C in f32 to `a32`. False when a
    /// value is not finite.
    pub fn load(self: *Refiner, vals: []const f64, a32: []f32) bool {
        const n = self.n;
        const cp = self.col_ptr;
        const ri = self.row_idx;
        @memcpy(self.fa, vals[0..self.fa.len]);
        @memset(self.rs, 0);
        @memset(self.r, 0); // row sums of |A|
        for (0..n) |j| for (cp[j]..cp[j + 1]) |p| {
            const v = @abs(vals[p]);
            if (!std.math.isFinite(v)) return false;
            self.rs[ri[p]] = @max(self.rs[ri[p]], v);
            self.r[ri[p]] += v;
        };
        var anorm: f64 = 0;
        for (self.r) |v| anorm = @max(anorm, v);
        self.anorm = anorm;
        for (self.rs) |*s| s.* = pow2Inv(s.*);
        for (0..n) |j| {
            var m: f64 = 0;
            for (cp[j]..cp[j + 1]) |p| m = @max(m, @abs(vals[p]) * self.rs[ri[p]]);
            self.cs[j] = pow2Inv(m);
            for (cp[j]..cp[j + 1]) |p| a32[p] = @floatCast(vals[p] * self.rs[ri[p]] * self.cs[j]);
        }
        return true;
    }

    /// 2^-e for the e with 2^e <= m < 2^(e+1); 1 for a zero m.
    fn pow2Inv(m: f64) f64 {
        if (m == 0) return 1;
        return std.math.ldexp(@as(f64, 1), -std.math.ilogb(m));
    }

    /// x = A^-1 b to the stop test, `corr.apply(r32, dx32)` giving
    /// dx32 = -(R A C)^-1 r32 in f32. False when the test was not met; `x`
    /// is then garbage.
    pub fn solve(self: *Refiner, gpa: std.mem.Allocator, corr: anytype, b: []const f64, x: []f64) bool {
        const n = self.n;
        self.stats.solves += 1;
        const bnorm = infNorm(b[0..n]);
        const tol = stop_c * std.math.floatEps(f64) / 2;
        @memset(x[0..n], 0);
        @memcpy(self.r, b[0..n]);
        var eta_prev = std.math.inf(f64);
        var it: u32 = 0;
        while (it < max_ir) : (it += 1) {
            if (infNorm(self.r) == 0) return true;
            self.correct(corr, self.r, self.d);
            for (x[0..n], self.d) |*xi, di| xi.* += di;
            const eta = self.residual(b, x, bnorm);
            self.stats.iterations += 1;
            if (!std.math.isFinite(eta)) return self.fail();
            if (eta <= tol) return true;
            if (eta > slow_rate * eta_prev) break;
            eta_prev = eta;
        }
        // GMRES-IR (Carson and Higham 2017): each step solves A d = r by
        // GMRES right-preconditioned with the f32 factors, in f64.
        if (self.gm == null) self.gm = Gmres.init(gpa, n, gmres_m) catch return self.fail();
        self.stats.gmres += 1;
        const Op = struct {
            ref: *Refiner,
            corr: @TypeOf(corr),
            pub fn matvec(op: *const @This(), v: []const f64, w: []f64) void {
                op.ref.matvec(v, w);
            }
            pub fn precond(op: *const @This(), v: []f64) void {
                op.ref.correct(op.corr, v, op.ref.p);
                @memcpy(v, op.ref.p);
            }
        };
        const op: Op = .{ .ref = self, .corr = corr };
        for (0..max_gmres_ir) |_| {
            @memcpy(self.b, self.r);
            @memset(self.d, 0);
            _ = self.gm.?.solve(&op, self.b, self.d, 1e-12, 0);
            for (x[0..n], self.d) |*xi, di| xi.* += di;
            const eta = self.residual(b, x, bnorm);
            self.stats.iterations += 1;
            if (!std.math.isFinite(eta)) break;
            if (eta <= tol) return true;
        }
        return self.fail();
    }

    fn fail(self: *Refiner) bool {
        self.stats.fallbacks += 1;
        return false;
    }

    /// d = A^-1 r through the f32 factors: R r scaled by a power of two
    /// into f32 range, solved, scaled back through C.
    fn correct(self: *Refiner, corr: anytype, r: []const f64, d: []f64) void {
        var m: f64 = 0;
        for (r, self.rs) |ri, s| m = @max(m, @abs(ri * s));
        if (m == 0 or !std.math.isFinite(m) or std.math.isNan(infNorm(r))) {
            @memset(d, if (m == 0) 0 else std.math.nan(f64));
            return;
        }
        const inv = pow2Inv(m);
        const sig = 1 / inv;
        for (self.r32, r, self.rs) |*o, ri, s| o.* = @floatCast(ri * s * inv);
        corr.apply(self.r32, self.dx32);
        for (d, self.dx32, self.cs) |*o, v, c| o.* = -@as(f64, v) * c * sig;
    }

    /// w = A v over `fa`.
    fn matvec(self: *const Refiner, v: []const f64, w: []f64) void {
        @memset(w[0..self.n], 0);
        for (0..self.n) |j| {
            const vj = v[j];
            for (self.col_ptr[j]..self.col_ptr[j + 1]) |p| w[self.row_idx[p]] += self.fa[p] * vj;
        }
    }

    /// r = b - A x; returns the normwise backward error.
    fn residual(self: *Refiner, b: []const f64, x: []const f64, bnorm: f64) f64 {
        self.matvec(x, self.r);
        for (self.r, b[0..self.n]) |*ri, bi| ri.* = bi - ri.*;
        const den = self.anorm * infNorm(x[0..self.n]) + bnorm;
        return if (den == 0) 0 else infNorm(self.r) / den;
    }

    fn infNorm(v: []const f64) f64 {
        var m: f64 = 0;
        for (v) |e| m = @max(m, @abs(e));
        // @max drops NaN; a NaN anywhere must fail the tests.
        for (v) |e| if (std.math.isNan(e)) return std.math.nan(f64);
        return m;
    }
};

/// The host instance: f32 factors on host threads (the kernel bodies),
/// with a `Refiner`.
pub const FastLu = struct {
    hf: lu_kernels.HostFactor(f32),
    ref: Refiner,
    a32: []f32,
    y32: []f32,
    bneg: []f64,
    /// The f32 factors match `ref.fa`.
    valid: bool = false,
    /// Workers for the refactor, fixed per epoch by the caller.
    threads: u32 = 1,

    /// Builds the f32 tables for `lu`'s current factor. Borrows the
    /// pattern. Caller owns the result; free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, lu: *const SparseLu, col_ptr: []const u32, row_idx: []const u32) !FastLu {
        var hf = try lu_kernels.HostFactor(f32).init(gpa, lu, col_ptr, growth_f32);
        errdefer hf.deinit(gpa);
        var ref = try Refiner.init(gpa, lu.n, col_ptr, row_idx);
        errdefer ref.deinit(gpa);
        const a32 = try gpa.alloc(f32, col_ptr[lu.n]);
        errdefer gpa.free(a32);
        const y32 = try gpa.alloc(f32, lu.n);
        errdefer gpa.free(y32);
        const bneg = try gpa.alloc(f64, lu.n);
        errdefer gpa.free(bneg);
        return .{ .hf = hf, .ref = ref, .a32 = a32, .y32 = y32, .bneg = bneg };
    }

    pub fn deinit(self: *FastLu, gpa: std.mem.Allocator) void {
        self.hf.deinit(gpa);
        self.ref.deinit(gpa);
        gpa.free(self.a32);
        gpa.free(self.y32);
        gpa.free(self.bneg);
        self.* = undefined;
    }

    /// Factors `vals` in f32 on `lu`'s pivot tape. False (factors invalid)
    /// when a void slot is nonzero, a value is not finite or a pivot test
    /// fails.
    pub fn refactor(self: *FastLu, lu: *const SparseLu, vals: []const f64, io: ?std.Io) bool {
        self.valid = false;
        self.ref.stats.refactors += 1;
        for (lu.void_slots.items) |p| {
            if (vals[p] != 0) return self.refactorFailed();
        }
        if (!self.ref.load(vals, self.a32)) return self.refactorFailed();
        if (!self.hf.refactor(self.a32, io, self.threads)) return self.refactorFailed();
        self.valid = true;
        return true;
    }

    fn refactorFailed(self: *FastLu) bool {
        self.ref.stats.refactor_fails += 1;
        return false;
    }

    /// x = -A^-1 rhs to f64 backward error; false when refinement missed.
    pub fn solveNeg(self: *FastLu, gpa: std.mem.Allocator, rhs: []const f64, x: []f64) bool {
        for (self.bneg, rhs[0..self.ref.n]) |*o, v| o.* = -v;
        return self.ref.solve(gpa, self, self.bneg, x);
    }

    /// The correction `Refiner.solve` asks for.
    pub fn apply(self: *FastLu, r32: []const f32, dx32: []f32) void {
        self.hf.solveNegSerial(r32, self.y32, dx32);
    }
};
