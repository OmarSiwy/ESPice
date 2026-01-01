//! Device contract: the comptime interface every device (hand-written or
//! VAF/VF-generated) must satisfy. `validate(D)` checks the full surface the
//! solver (analysis/compiled.zig) actually calls, so a mismatch fails at the
//! device definition with a readable error instead of deep in a solver loop.
//!
//! Physics is VALUE-FORM: written once, generic over an opaque scalar S.
//! The analysis crate instantiates it with a derivative-carrying scalar, so
//! one pass yields residual + all analytic partials — no finite differences.
//!
//!   pub fn eval(comptime S: type, x: [n_u]S, m: *const Model, i: *const Instance, t: f64) [n_u]S;
//!   pub fn q   (comptime S: type, x, m, i, t) [n_u]S;   // optional: charges
//!
//! The scalar interface S provides (see `Value` below for the plain-f64
//! reference implementation — the analysis side must mirror this list):
//!
//!   con addC scale            — constants in / scaling
//!   add sub neg mul div       — arithmetic
//!   exp log sqrt pow          — pow(a, c): constant exponent
//!   sin cos tanh sinh cosh atan
//!   abs minC maxC min max     — piecewise; derivative flat past clamp
//!   val                       — read the value (branching, debugging)
//!
//! RULES for physics code:
//!   - Everything not depending on x (param prep, temperature, geometry)
//!     stays plain f64. Only x-dependent chains use S ops.
//!   - Never branch on an S with `if` directly; use .val() for topology-level
//!     decisions and minC/maxC/min/max for clamps (they keep the derivative
//!     consistent with the picked branch).

const std = @import("std");

// ponytail: @exp/@log unavailable on nvptx64 (LLVM #141364, no fix in sight).
// @sqrt/@sin/@cos are fine (Legal in LLVM NVPTX). Hand-roll only exp/log.
const builtin = @import("builtin");
const is_gpu = builtin.cpu.arch == .nvptx64 or builtin.cpu.arch == .amdgcn;

pub const fmath = struct {
    pub inline fn exp(x: f64) f64 {
        if (comptime !is_gpu) return @exp(x);
        // Saturate like libm: also keeps k in i64 range when a device's
        // comptime validation instantiates eval with sentinel extremes.
        if (x < -745.2) return 0.0;
        if (x > 709.8) return std.math.inf(f64);
        // Range reduction: e^x = 2^(x/ln2) = 2^k * 2^f, f in [0,1)
        const log2e = 1.4426950408889634;
        const t = x * log2e;
        const k = @floor(t);
        const f = t - k;
        // Minimax degree-6 polynomial for 2^f on [0,1), ~1 ulp
        var p: f64 = 1.5417544459590958e-5;
        p = p * f + 1.5252732999903985e-4;
        p = p * f + 1.3333558178101622e-3;
        p = p * f + 9.6181291052364266e-3;
        p = p * f + 5.5504108663561613e-2;
        p = p * f + 2.4022650695909071e-1;
        p = p * f + 6.9314718055994531e-1;
        p = p * f + 1.0;
        // Scale by 2^k via bit manipulation
        const ki: i64 = @intFromFloat(k);
        const bits: u64 = @bitCast(p);
        return @bitCast(bits +% (@as(u64, @bitCast(ki)) << 52));
    }

    pub inline fn sin(x: f64) f64 {
        return if (comptime !is_gpu) @sin(x) else sinCos(x)[0];
    }

    pub inline fn cos(x: f64) f64 {
        return if (comptime !is_gpu) @cos(x) else sinCos(x)[1];
    }

    /// f64 sin/cos for nvptx (no fsin/fcos lowering, no libcalls). musl-style:
    /// 3-part Cody-Waite reduction by π/2 + minimax kernels on [-π/4, π/4].
    /// ponytail: ~1 ulp for |x| < ~2^26·π/2 — SPICE source phases ωt+φ stay
    /// far below that; add Payne-Hanek if a fixture ever proves otherwise.
    pub fn sinCos(x: f64) [2]f64 {
        const two_over_pi = 0.63661977236758134308;
        const kd = @floor(x * two_over_pi + 0.5);
        const p1 = 1.57079632673412561417e+00;
        const p2 = 6.07710050650619224932e-11;
        const p3 = 2.02226624879595063154e-21;
        var r = x - kd * p1;
        r -= kd * p2;
        r -= kd * p3;
        const q: u2 = @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(kd)))));
        const r2 = r * r;
        const s = r + r * r2 * (-1.66666666666666324348e-01 + r2 * (8.33333333332248946124e-03 +
            r2 * (-1.98412698298579493134e-04 + r2 * (2.75573137070700676789e-06 +
                r2 * (-2.50507602534068634195e-08 + r2 * 1.58969099521155010221e-10)))));
        const c = 1.0 + r2 * (-0.5 + r2 * (4.16666666666666019037e-02 + r2 * (-1.38888888888741095749e-03 +
            r2 * (2.48015872894767294178e-05 + r2 * (-2.75573143513906633035e-07 +
                r2 * 2.08757232129817482790e-09)))));
        return switch (q) {
            0 => .{ s, c },
            1 => .{ c, -s },
            2 => .{ -s, -c },
            3 => .{ -c, s },
        };
    }

    /// S contract: a > 0, constant exponent (see module doc).
    pub inline fn pow(a: f64, c: f64) f64 {
        if (comptime !is_gpu) return std.math.pow(f64, a, c);
        if (!(a > 0)) return 0;
        return exp(c * log(a));
    }

    pub inline fn tanh(x: f64) f64 {
        if (comptime !is_gpu) return std.math.tanh(x);
        if (x > 20.0) return 1.0;
        if (x < -20.0) return -1.0;
        const e2 = exp(2.0 * x);
        return (e2 - 1.0) / (e2 + 1.0);
    }

    pub inline fn sinh(x: f64) f64 {
        if (comptime !is_gpu) return std.math.sinh(x);
        const e = exp(x);
        return 0.5 * (e - 1.0 / e);
    }

    pub inline fn cosh(x: f64) f64 {
        if (comptime !is_gpu) return std.math.cosh(x);
        const e = exp(x);
        return 0.5 * (e + 1.0 / e);
    }

    pub inline fn log(x: f64) f64 {
        if (comptime !is_gpu) return @log(x);
        // Decompose: x = 2^e * m, m in [1,2); log(x) = e*ln2 + log(m)
        const ln2 = 0.6931471805599453;
        const bits: u64 = @bitCast(x);
        const e_biased: i64 = @intCast((bits >> 52) & 0x7FF);
        const e: f64 = @floatFromInt(e_biased - 1023);
        // Normalize mantissa to [1,2)
        const m_bits = (bits & 0x000FFFFFFFFFFFFF) | 0x3FF0000000000000;
        const m: f64 = @bitCast(m_bits);
        // 2*atanh((m-1)/(m+1)) series, ~2 ulp on [1,2)
        const s = (m - 1.0) / (m + 1.0);
        const s2 = s * s;
        var q: f64 = 1.0 / 9.0;
        q = q * s2 + 1.0 / 7.0;
        q = q * s2 + 1.0 / 5.0;
        q = q * s2 + 1.0 / 3.0;
        q = q * s2 + 1.0;
        return e * ln2 + 2.0 * s * q;
    }
};

pub const UpdateResult = union(enum) {
    ok,
    request_reject_at: f64,
};

pub const UnknownKind = enum {
    voltage,
    current,
    flow,
};

pub fn Entry(comptime n: usize) type {
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
    };
}

pub const HistoryReq = struct {
    max_delay: f64,
    interp_order: u8 = 1,
};

pub fn NoiseGen(comptime D: type) type {
    const n = nU(D);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        kind: enum { thermal, shot, flicker },
    };
}

pub fn nU(comptime D: type) comptime_int {
    return @typeInfo(D.U).@"enum".fields.len;
}

pub fn uKinds(comptime D: type) [nU(D)]UnknownKind {
    if (@hasDecl(D, "u_kinds")) return D.u_kinds;
    return [_]UnknownKind{.voltage} ** nU(D);
}

// ============================================================================
// Value: plain-f64 scalar satisfying the S interface. Reference
// implementation of the op list; used by device unit tests (and any consumer
// that wants residuals without derivatives).
// ============================================================================

pub const Value = struct {
    v: f64,

    const Self = @This();

    pub fn con(c: f64) Self {
        return .{ .v = c };
    }
    pub fn add(a: Self, b: Self) Self {
        return .{ .v = a.v + b.v };
    }
    pub fn sub(a: Self, b: Self) Self {
        return .{ .v = a.v - b.v };
    }
    pub fn neg(a: Self) Self {
        return .{ .v = -a.v };
    }
    pub fn mul(a: Self, b: Self) Self {
        return .{ .v = a.v * b.v };
    }
    pub fn div(a: Self, b: Self) Self {
        return .{ .v = a.v / b.v };
    }
    pub fn scale(a: Self, c: f64) Self {
        return .{ .v = a.v * c };
    }
    pub fn addC(a: Self, c: f64) Self {
        return .{ .v = a.v + c };
    }
    pub fn exp(a: Self) Self {
        return .{ .v = fmath.exp(a.v) };
    }
    pub fn log(a: Self) Self {
        return .{ .v = fmath.log(a.v) };
    }
    pub fn sqrt(a: Self) Self {
        return .{ .v = @sqrt(a.v) };
    }
    pub fn sin(a: Self) Self {
        return .{ .v = fmath.sin(a.v) };
    }
    pub fn cos(a: Self) Self {
        return .{ .v = fmath.cos(a.v) };
    }
    pub fn tanh(a: Self) Self {
        return .{ .v = fmath.tanh(a.v) };
    }
    pub fn abs(a: Self) Self {
        return .{ .v = @abs(a.v) };
    }
    pub fn minC(a: Self, c: f64) Self {
        return .{ .v = @min(a.v, c) };
    }
    pub fn maxC(a: Self, c: f64) Self {
        return .{ .v = @max(a.v, c) };
    }
    pub fn pow(a: Self, c: f64) Self {
        return .{ .v = fmath.pow(a.v, c) };
    }
    pub fn atan(a: Self) Self {
        return .{ .v = std.math.atan(a.v) };
    }
    pub fn sinh(a: Self) Self {
        return .{ .v = fmath.sinh(a.v) };
    }
    pub fn cosh(a: Self) Self {
        return .{ .v = fmath.cosh(a.v) };
    }
    pub fn max(a: Self, b: Self) Self {
        return .{ .v = @max(a.v, b.v) };
    }
    pub fn min(a: Self, b: Self) Self {
        return .{ .v = @min(a.v, b.v) };
    }
    pub fn val(a: Self) f64 {
        return a.v;
    }
};

// ============================================================================
// Dual: forward-mode derivative-carrying scalar satisfying the S interface.
// Used by GENERATED (VAF/VF) devices to export analytic residual+Jacobian
// across the .so ABI (zpicey_eval_ad). Hand-written devices never name it —
// the analysis crate instantiates their physics with its own scalar.
// ============================================================================

pub fn Dual(comptime N: usize) type {
    return struct {
        v: f64,
        d: V,

        const V = @Vector(N, f64);
        const Self = @This();

        inline fn splat(c: f64) V {
            return @splat(c);
        }
        /// Seed unknown `u` (derivative 1 w.r.t. itself). `u` is comptime —
        /// a runtime-indexed vector write does not compile; every caller seeds
        /// inside an `inline for`, so the index is comptime anyway.
        pub fn seed(value: f64, comptime u: usize) Self {
            var d: V = @splat(0);
            d[u] = 1;
            return .{ .v = value, .d = d };
        }
        pub fn con(c: f64) Self {
            return .{ .v = c, .d = splat(0) };
        }
        pub fn add(a: Self, b: Self) Self {
            return .{ .v = a.v + b.v, .d = a.d + b.d };
        }
        pub fn sub(a: Self, b: Self) Self {
            return .{ .v = a.v - b.v, .d = a.d - b.d };
        }
        pub fn neg(a: Self) Self {
            return .{ .v = -a.v, .d = -a.d };
        }
        pub fn mul(a: Self, b: Self) Self {
            return .{ .v = a.v * b.v, .d = a.d * splat(b.v) + b.d * splat(a.v) };
        }
        pub fn div(a: Self, b: Self) Self {
            const inv_b = 1.0 / b.v;
            const quot = a.v * inv_b;
            return .{ .v = quot, .d = (a.d - b.d * splat(quot)) * splat(inv_b) };
        }
        pub fn scale(a: Self, c: f64) Self {
            return .{ .v = a.v * c, .d = a.d * splat(c) };
        }
        pub fn addC(a: Self, c: f64) Self {
            return .{ .v = a.v + c, .d = a.d };
        }
        pub fn exp(a: Self) Self {
            const e = fmath.exp(a.v); // nvptx-safe (raw @exp has no libcall there)
            return .{ .v = e, .d = a.d * splat(e) };
        }
        pub fn log(a: Self) Self {
            return .{ .v = fmath.log(a.v), .d = a.d * splat(1.0 / a.v) };
        }
        pub fn sqrt(a: Self) Self {
            const s = @sqrt(a.v);
            // s==0: slope is +inf; 0*inf from a clamped-constant input would
            // poison the whole Jacobian with NaN. Flat derivative instead.
            return .{ .v = s, .d = a.d * splat(if (s > 0.0) 0.5 / s else 0.0) };
        }
        pub fn sin(a: Self) Self {
            const sc = if (comptime !is_gpu) [2]f64{ @sin(a.v), @cos(a.v) } else fmath.sinCos(a.v);
            return .{ .v = sc[0], .d = a.d * splat(sc[1]) };
        }
        pub fn cos(a: Self) Self {
            const sc = if (comptime !is_gpu) [2]f64{ @sin(a.v), @cos(a.v) } else fmath.sinCos(a.v);
            return .{ .v = sc[1], .d = a.d * splat(-sc[0]) };
        }
        pub fn tanh(a: Self) Self {
            const th = fmath.tanh(a.v);
            return .{ .v = th, .d = a.d * splat(1.0 - th * th) };
        }
        pub fn abs(a: Self) Self {
            return if (a.v < 0) a.neg() else a;
        }
        pub fn minC(a: Self, c: f64) Self {
            return if (a.v > c) con(c) else a;
        }
        pub fn maxC(a: Self, c: f64) Self {
            return if (a.v < c) con(c) else a;
        }
        pub fn pow(a: Self, c: f64) Self {
            const p = fmath.pow(a.v, c);
            // a.v==0: c*p/0 is inf/NaN; keep the Jacobian finite (see sqrt).
            const slope = c * p / a.v;
            return .{ .v = p, .d = a.d * splat(if (std.math.isFinite(slope)) slope else 0.0) };
        }
        pub fn atan(a: Self) Self {
            return .{ .v = std.math.atan(a.v), .d = a.d * splat(1.0 / (1.0 + a.v * a.v)) };
        }
        pub fn sinh(a: Self) Self {
            return .{ .v = fmath.sinh(a.v), .d = a.d * splat(fmath.cosh(a.v)) };
        }
        pub fn cosh(a: Self) Self {
            return .{ .v = fmath.cosh(a.v), .d = a.d * splat(fmath.sinh(a.v)) };
        }
        pub fn max(a: Self, b: Self) Self {
            return if (a.v >= b.v) a else b;
        }
        pub fn min(a: Self, b: Self) Self {
            return if (a.v <= b.v) a else b;
        }
        pub fn val(a: Self) f64 {
            return a.v;
        }
    };
}

/// Evaluate D's residual at plain-f64 terminal values. Test helper.
pub fn evalValues(comptime D: type, x: [nU(D)]f64, m: *const D.Model, inst: *const D.Instance, t: f64) [nU(D)]f64 {
    var xs: [nU(D)]Value = undefined;
    inline for (0..nU(D)) |u| xs[u] = Value.con(x[u]);
    const out = D.eval(Value, xs, m, inst, t);
    var res: [nU(D)]f64 = undefined;
    inline for (0..nU(D)) |u| res[u] = out[u].val();
    return res;
}

/// Same for the charge function.
pub fn qValues(comptime D: type, x: [nU(D)]f64, m: *const D.Model, inst: *const D.Instance, t: f64) [nU(D)]f64 {
    var xs: [nU(D)]Value = undefined;
    inline for (0..nU(D)) |u| xs[u] = Value.con(x[u]);
    const out = D.q(Value, xs, m, inst, t);
    var res: [nU(D)]f64 = undefined;
    inline for (0..nU(D)) |u| res[u] = out[u].val();
    return res;
}

// ============================================================================
// Validation
// ============================================================================

pub fn validate(comptime D: type) void {
    @setEvalBranchQuota(1_000_000);
    const name = @typeName(D);

    // Required decls first, so a missing one reads as a contract violation
    // rather than a raw "no member named ..." error.
    for (.{ "U", "num_ports", "Model", "Instance", "eval" }) |decl| {
        if (!@hasDecl(D, decl))
            @compileError(name ++ ": contract requires `pub " ++ decl ++ "`");
    }

    if (@typeInfo(D.U) != .@"enum" or !isDenseEnum(D.U))
        @compileError(name ++ ".U must be a dense enum(u8) with values 0..n-1");
    const n = nU(D);

    const np: usize = D.num_ports;
    if (np == 0 or np > n)
        @compileError(name ++ ".num_ports must be in 1..|U|");

    validateDefaultedStruct(D, "Model");
    validateDefaultedStruct(D, "Instance");

    // Physics: generic over S, so only shape-checkable. eval/q take
    // (comptime S, [n]S, *const Model, *const Instance, f64).
    validatePhysicsFn(D, "eval");
    if (@hasDecl(D, "q")) validatePhysicsFn(D, "q");

    // Voltage limiting (pnjlim/fetlim) and cold-start seeding (SPICE
    // MODEINITJCT). seed returns absolute local voltages written into a
    // zeroed x before Newton iteration 1; null leaves an unknown untouched
    // (externally driven terminals). Any device with junction limiting
    // should also declare seed — limiting from x_old = 0 is what pins
    // cold-start Newton in the wrong basin.
    // NOTE: limit corrections are only APPLIED to internal unknowns
    // (u >= num_ports) — the batch masks external writes, since a limiter
    // writing a driven/shared node fights sources and other devices.
    // seed writes are unmasked: they happen once, pre-solve, and the first
    // linear solve re-imposes every source constraint.
    if (@hasDecl(D, "limit"))
        expectFn(D, "limit", fn (*const D.Model, *const D.Instance, [n]f64, [n]f64) [n]f64);
    if (@hasDecl(D, "seed"))
        expectFn(D, "seed", fn (*const D.Model, *const D.Instance) [n]?f64);
    // Node collapse (ngspice setup): for each internal unknown, return the
    // port index it collapses onto when its separating parasitic R is 0, or
    // null to keep a private node. Consulted once at build time.
    if (@hasDecl(D, "collapse"))
        expectFn(D, "collapse", fn (*const D.Model, *const D.Instance) [n]?u8);

    // State machine: eval reads Instance, so updateState gets a MUTABLE
    // Instance — switch position etc. must live in Instance fields.
    if (@hasDecl(D, "initState") or @hasDecl(D, "updateState")) {
        if (!@hasDecl(D, "State"))
            @compileError(name ++ ": initState/updateState require pub const State");
        // initState also mutable: generated digital devices push initial
        // logic outputs into Instance drive targets at init.
        expectFn(D, "initState", fn (*const D.Model, *D.Instance) D.State);
        expectFn(D, "updateState", fn (*const D.Model, *D.Instance, [n]f64, *D.State) UpdateResult);
    }

    // History (delay-line devices): histInject is generic over the lookup
    // (it cannot name the analysis crate's HistLookup), so shape-check only.
    if (@hasDecl(D, "histInject")) {
        if (!@hasDecl(D, "n_hist_signals"))
            @compileError(name ++ ": histInject requires pub const n_hist_signals");
        const nh: u32 = D.n_hist_signals;
        expectFn(D, "gatherHistSignals", fn ([n]f64) [nh]f64);
        validateDelaysFn(D);
        const info = @typeInfo(@TypeOf(D.histInject));
        if (info != .@"fn" or info.@"fn".params.len != 3)
            @compileError(name ++ ".histInject: expected fn (*const Model, lookup: anytype, t: f64) [n_u]f64");
    }

    // Convergence aids.
    if (@hasDecl(D, "attempt")) {
        const T = @TypeOf(D.attempt);
        if (T != fn (D.Model, f64) D.Model and T != fn (D.Model, D.Instance, f64) D.Model)
            @compileError(name ++ ".attempt: expected fn (Model, f64) Model or fn (Model, Instance, f64) Model");
    }
    if (@hasDecl(D, "limit"))
        expectFn(D, "limit", fn (*const D.Model, *const D.Instance, [n]f64, [n]f64) [n]f64);

    // Optional metadata.
    if (@hasDecl(D, "u_kinds") and @TypeOf(D.u_kinds) != [n]UnknownKind)
        @compileError(name ++ ".u_kinds must be [|U|]UnknownKind");
    if (@hasDecl(D, "g_pattern_override")) validateEntryArray(D, "g_pattern_override", n);
    if (@hasDecl(D, "c_pattern_override")) validateEntryArray(D, "c_pattern_override", n);
    if (@hasDecl(D, "noise_gens")) {
        const info = @typeInfo(@TypeOf(D.noise_gens));
        if (info != .array or info.array.child != NoiseGen(D))
            @compileError(name ++ ".noise_gens must be [k]NoiseGen(Self)");
    }
    validateMcParam(D);

    // PrepCache: if declared, device must also export computePrep and evalFromPrep.
    // qFromPrep is required when the device also declares q.
    if (@hasDecl(D, "PrepCache")) {
        if (!@hasDecl(D, "computePrep"))
            @compileError(name ++ ": PrepCache requires pub fn computePrep");
        expectFn(D, "computePrep", fn (*const D.Model, *const D.Instance) D.PrepCache);
        if (!@hasDecl(D, "evalFromPrep"))
            @compileError(name ++ ": PrepCache requires pub fn evalFromPrep");
        validatePrepPhysicsFn(D, "evalFromPrep");
        if (@hasDecl(D, "q") and !@hasDecl(D, "qFromPrep"))
            @compileError(name ++ ": PrepCache + q requires pub fn qFromPrep");
        if (@hasDecl(D, "qFromPrep")) validatePrepPhysicsFn(D, "qFromPrep");
    }

    // precompute: instance-mutating parameter prep before solve.
    if (@hasDecl(D, "precompute"))
        expectFn(D, "precompute", fn (*D.Instance, *const D.Model) void);

    // Constant-Jacobian flags: must be bool when present.
    if (@hasDecl(D, "constant_g") and @TypeOf(D.constant_g) != bool)
        @compileError(name ++ ".constant_g must be bool");
    if (@hasDecl(D, "constant_c") and @TypeOf(D.constant_c) != bool)
        @compileError(name ++ ".constant_c must be bool");

    // Breakpoint scheduling for piecewise sources.
    if (@hasDecl(D, "nextBreakpoint"))
        expectFn(D, "nextBreakpoint", fn (*const D.Model, f64) ?f64);

    // Smoke test: instantiate eval(Value) at comptime to catch type errors
    // in the physics body, not just shape mismatches.
    _ = validateEvalInstantiation(D);

    // Pub-decl allowlist: only contract-recognized names may be pub.
    // zpicey_* are the dynamic plugin ABI (validated by dyn.zig loader).
    rejectStrayPubDecls(D);
}

fn validateEvalInstantiation(comptime D: type) [nU(D)]f64 {
    @setEvalBranchQuota(1_000_000);
    const n = nU(D);
    const m: D.Model = .{};
    const inst: D.Instance = .{};
    var xs: [n]Value = undefined;
    inline for (0..n) |u| xs[u] = Value.con(0);
    const out = D.eval(Value, xs, &m, &inst, 0);
    var res: [n]f64 = undefined;
    inline for (0..n) |u| res[u] = out[u].val();
    return res;
}

const allowed_pub_decls = std.StaticStringMap(void).initComptime(.{
    .{ "U", {} },
    .{ "num_ports", {} },
    .{ "Model", {} },
    .{ "Instance", {} },
    .{ "eval", {} },
    .{ "q", {} },
    .{ "limit", {} },
    .{ "seed", {} },
    .{ "collapse", {} },
    .{ "initState", {} },
    .{ "updateState", {} },
    .{ "State", {} },
    .{ "histInject", {} },
    .{ "n_hist_signals", {} },
    .{ "gatherHistSignals", {} },
    .{ "delays", {} },
    .{ "attempt", {} },
    .{ "u_kinds", {} },
    .{ "g_pattern_override", {} },
    .{ "c_pattern_override", {} },
    .{ "noise_gens", {} },
    .{ "mc_param", {} },
    .{ "PrepCache", {} },
    .{ "computePrep", {} },
    .{ "evalFromPrep", {} },
    .{ "qFromPrep", {} },
    .{ "precompute", {} },
    .{ "constant_g", {} },
    .{ "constant_c", {} },
    .{ "nextBreakpoint", {} },
});

fn rejectStrayPubDecls(comptime D: type) void {
    const decls = @typeInfo(D).@"struct".decls;
    for (decls) |d| {
        if (allowed_pub_decls.has(d.name)) continue;
        // zpicey_* are dynamic plugin ABI exports (validated by dyn.zig loader).
        if (d.name.len >= 7 and std.mem.eql(u8, d.name[0..7], "zpicey_")) continue;
        @compileError(@typeName(D) ++ ": stray pub decl `" ++ d.name ++
            "` — only contract-recognized names may be pub");
    }
}

/// eval/q: fn (comptime S: type, [n]S, *const Model, *const Instance, f64) [n]S.
/// Generic over S, so the concrete signature is checked by instantiation:
/// here only arity + comptime-type first param.
fn validatePhysicsFn(comptime D: type, comptime fn_name: []const u8) void {
    const info = @typeInfo(@TypeOf(@field(D, fn_name)));
    if (info != .@"fn" or info.@"fn".params.len != 5 or info.@"fn".params[0].type != type)
        @compileError(@typeName(D) ++ "." ++ fn_name ++
            ": expected fn (comptime S: type, [n_u]S, *const Model, *const Instance, f64) [n_u]S");
}

/// evalFromPrep/qFromPrep: fn (comptime S, [n]S, *const PrepCache, *const Model, *const Instance, f64) [n]S.
fn validatePrepPhysicsFn(comptime D: type, comptime fn_name: []const u8) void {
    const info = @typeInfo(@TypeOf(@field(D, fn_name)));
    if (info != .@"fn" or info.@"fn".params.len != 6 or info.@"fn".params[0].type != type)
        @compileError(@typeName(D) ++ "." ++ fn_name ++
            ": expected fn (comptime S: type, [n_u]S, *const PrepCache, *const Model, *const Instance, f64) [n_u]S");
}

fn expectFn(comptime D: type, comptime fn_name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(D, fn_name))
        @compileError(@typeName(D) ++ ": missing " ++ fn_name);
    if (@TypeOf(@field(D, fn_name)) != Expected)
        @compileError(@typeName(D) ++ "." ++ fn_name ++ ": expected " ++ @typeName(Expected));
}

fn validateDefaultedStruct(comptime D: type, comptime decl: []const u8) void {
    const T = @field(D, decl);
    if (@typeInfo(T) != .@"struct")
        @compileError(@typeName(D) ++ "." ++ decl ++ " must be a struct");
    for (@typeInfo(T).@"struct".fields) |f| {
        if (f.default_value_ptr == null)
            @compileError(@typeName(D) ++ "." ++ decl ++ "." ++ f.name ++ " must have a default value");
        if (!isValueType(f.type))
            @compileError(@typeName(D) ++ "." ++ decl ++ "." ++ f.name ++
                ": field type must be f32, f64, i32, bool, or a fixed-size array of these (no pointers/slices)");
    }
}

fn isValueType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        .array => |a| isValueType(a.child),
        else => false,
    };
}

fn validateDelaysFn(comptime D: type) void {
    const err = @typeName(D) ++ ".delays: expected fn (*const Model) [k]f64, k >= 1";
    if (!@hasDecl(D, "delays")) @compileError(err);
    const info = @typeInfo(@TypeOf(D.delays));
    if (info != .@"fn" or info.@"fn".params.len != 1 or
        info.@"fn".params[0].type != *const D.Model)
        @compileError(err);
    const ret = @typeInfo(info.@"fn".return_type.?);
    if (ret != .array or ret.array.child != f64 or ret.array.len == 0)
        @compileError(err);
}

fn validateEntryArray(comptime D: type, comptime decl: []const u8, comptime n: comptime_int) void {
    const info = @typeInfo(@TypeOf(@field(D, decl)));
    if (info != .array or info.array.child != Entry(n))
        @compileError(@typeName(D) ++ "." ++ decl ++ " must be [k]Entry(n_u)");
}

fn isDenseEnum(comptime E: type) bool {
    const info = @typeInfo(E).@"enum";
    if (info.tag_type != u8) return false;
    for (info.fields, 0..) |f, idx| {
        if (f.value != idx) return false;
    }
    return true;
}

/// Optional per-device declaration: `pub const mc_param = "resist";`
/// Names the principal value parameter (Instance or Model f32 field) that
/// Monte Carlo varies. Validated here so a typo fails at compile time.
pub fn validateMcParam(comptime D: type) void {
    if (!@hasDecl(D, "mc_param")) return;
    const name: []const u8 = D.mc_param;
    var found = false;
    for (@typeInfo(D.Instance).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name) and f.type == f32) found = true;
    }
    for (@typeInfo(D.Model).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name) and f.type == f32) found = true;
    }
    if (!found) @compileError(@typeName(D) ++ ".mc_param '" ++ D.mc_param ++ "' is not an f32 field of Model or Instance");
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const MockR = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    pub const Model = struct {
        g: f64 = 1e-3,
    };

    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        const ir = x[0].sub(x[1]).scale(model.g);
        return .{ ir, ir.neg() };
    }
};

const MockSw = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    // Switch position lives in Instance so eval can read it.
    pub const State = struct { flips: u32 = 0 };

    pub const Model = struct {
        gon: f64 = 1.0,
        goff: f64 = 1e-12,
    };

    pub const Instance = struct {
        closed: bool = false,
    };

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, inst: *const Instance, _: f64) [n_u]S {
        const g = if (inst.closed) model.gon else model.goff;
        const ir = x[0].sub(x[1]).scale(g);
        return .{ ir, ir.neg() };
    }

    pub fn initState(_: *const Model, _: *Instance) State {
        return .{};
    }

    pub fn updateState(_: *const Model, inst: *Instance, x: [n_u]f64, s: *State) UpdateResult {
        const want = (x[0] - x[1]) > 0.5;
        if (want != inst.closed) {
            inst.closed = want;
            s.flips += 1;
        }
        return .ok;
    }

    pub fn attempt(model: Model, lambda: f64) Model {
        var m = model;
        m.gon *= lambda;
        return m;
    }

    pub fn limit(_: *const Model, _: *const Instance, x_new: [n_u]f64, _: [n_u]f64) [n_u]f64 {
        return x_new;
    }
};

const MockTline = struct {
    pub const U = enum(u8) { p1, p2 };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    pub const Model = struct {
        z0: f32 = 50,
        td: f32 = 1e-9,
    };

    pub const Instance = struct {};

    pub const mc_param = "z0";
    pub const u_kinds = [n_u]UnknownKind{ .voltage, .voltage };
    pub const g_pattern_override = [_]Entry(n_u){.{ .row = 0, .col = 0 }};
    pub const c_pattern_override = [0]Entry(n_u){};
    pub const noise_gens = [_]NoiseGen(@This()){.{ .row = 0, .col = 1, .kind = .thermal }};

    pub const n_hist_signals: u32 = 2;

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        const y0 = 1.0 / @as(f64, model.z0);
        return .{ x[0].scale(y0), x[1].scale(y0) };
    }

    pub fn delays(model: *const Model) [1]f64 {
        return .{@as(f64, model.td)};
    }

    pub fn gatherHistSignals(x: [n_u]f64) [n_hist_signals]f64 {
        return .{ x[0], x[1] };
    }

    pub fn histInject(model: *const Model, lookup: anytype, t: f64) [n_u]f64 {
        const td = @as(f64, model.td);
        const y0 = 1.0 / @as(f64, model.z0);
        return .{ lookup.at(t - td, 1) * y0, lookup.at(t - td, 0) * y0 };
    }
};

test "validate: minimal resistor" {
    comptime validate(MockR);
}

test "validate: switch (state in Instance + attempt + limit)" {
    comptime validate(MockSw);
}

test "validate: tline (histInject + metadata)" {
    comptime validate(MockTline);
}

test "evalValues: MockR residual" {
    const m: MockR.Model = .{ .g = 2e-3 };
    const out = evalValues(MockR, .{ 1.0, 0.0 }, &m, &.{}, 0);
    try testing.expectApproxEqAbs(@as(f64, 2e-3), out[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -2e-3), out[1], 1e-15);
}

test "updateState mutates Instance" {
    var inst: MockSw.Instance = .{};
    var s: MockSw.State = .{};
    const m: MockSw.Model = .{};
    _ = MockSw.updateState(&m, &inst, .{ 1.0, 0.0 }, &s);
    try testing.expect(inst.closed);
    try testing.expectEqual(@as(u32, 1), s.flips);
}

test "uKinds default: all voltage" {
    const k = comptime uKinds(MockR);
    try testing.expectEqual(UnknownKind.voltage, k[0]);
    try testing.expectEqual(UnknownKind.voltage, k[1]);
}

test "uKinds override" {
    const k = comptime uKinds(MockTline);
    try testing.expectEqual(UnknownKind.voltage, k[1]);
}

test "nU" {
    try testing.expectEqual(@as(comptime_int, 2), comptime nU(MockR));
}
