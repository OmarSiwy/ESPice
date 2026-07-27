//! Device contract: the comptime interface every device (VA-generated or
//! hand-written) must satisfy. `validate(D)` structurally checks the surface
//! the engine calls — decls present, enum dense, param types, function arity —
//! so a mismatch fails at the device definition with a readable error.
//!
//! This file only CHECKS the contract; it provides no scalar implementation.
//! Physics is written generic over an opaque scalar S:
//!
//!   pub fn eval(comptime S: type, x: [n_u]S, m: *const Model, i: *const Instance, t: f64) [n_u]S;
//!   pub fn q   (comptime S: type, x, m, i, t) [n_u]S;   // optional: charges
//!
//! The engine instantiates S — a plain-f64 value form for residuals, a
//! derivative-carrying dual for the Jacobian. The S primitive set devices may
//! use: con addC scale · add sub neg mul div · exp log sqrt pow(a,c) · sin cos
//! tanh sinh cosh atan · abs minC maxC min max · val.
//!
//! RULES for physics code:
//!   - Everything not depending on x (param prep, temperature, geometry)
//!     stays plain f64. Only x-dependent chains use S ops.
//!   - Never branch on an S with `if` directly; use .val() for topology-level
//!     decisions and minC/maxC/min/max for clamps.

const std = @import("std");

pub const UpdateResult = union(enum) {
    ok,
    request_reject_at: f64,
};

/// Accepted-state bookkeeping for FSM devices (switches). The transient
/// loop uses this to reject/retry a timestep whose converged solution flipped
/// a device state, so the discontinuity lands sharp at the crossing:
///   query  — does the working state differ from the last accepted state?
///   commit — step accepted: accepted := working
///   revert — step rejected: working := accepted
pub const StateCtlOp = enum(u8) { query, commit, revert };

/// §4.6.1 `analysis()`. Host mirror of the `AnalysisKind` every generated
/// device declares for itself — the engine converts by ordinal
/// (`@enumFromInt(@intFromEnum(..))`), same trick as StateCtlOp, so the tag
/// ORDER here is load-bearing and must match FastVAF's emission.
pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };

/// Host-owned per-pass simulation state (see `Hooks.set_sim_state`).
/// Everything here is a property of the ANALYSIS, not of the device, so the
/// host is the only writer:
///   t     — §9.10 `$abstime`, the time the solve is targeting
///   dt    — §9.10 timestep feeding `ddt`/`idt`; 0 in a static analysis, which
///           is what the generated zDdt/zIdt helpers test for
///   kind  — §4.6.1 `analysis()`
///   initial_step / final_step — §5.10.2 global events
pub const SimState = struct {
    t: f64 = 0,
    dt: f64 = 0,
    kind: AnalysisKind = .dc,
    initial_step: bool = false,
    final_step: bool = false,
};

pub const UnknownKind = enum {
    voltage,
    current,
    flow,
};

pub fn NoiseGen(comptime D: type) type {
    const n = nU(D);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        kind: enum { thermal, shot, flicker },
    };
}

/// One generator's PSD at a given state vector, returned by the optional
/// device `noisePsd` hook (position k = noise_gens[k]):
///   S(f) = white + flicker / f^ef   [A²/Hz]
/// white: thermal 4kT·g, shot 2q|I| — the DEVICE computes it from its own
/// currents/conductances. corr_with pairs correlated generators (BSIM4
/// tnoiMod, PSP igid); real coefficient until a reference demands complex.
pub const PsdTerm = struct {
    white: f64,
    flicker: f64 = 0,
    ef: f64 = 1,
    corr_with: ?u8 = null,
    corr: f64 = 0,
};

/// Operating-point output variable metadata. Mirrors `noise_gens`: an optional
/// comptime table a device may declare, describing internal quantities (gm,
/// gds, vth, currents, ...) it exposes for post-solve inspection. Position k
/// in `op_vars` corresponds to element k of the `opValues(...)` result. A
/// Verilog-A `(* desc=... *) real x;` module variable becomes one entry.
pub const OpVar = struct {
    name: []const u8,
    units: []const u8 = "",
    desc: []const u8 = "",
};

pub fn nU(comptime D: type) comptime_int {
    return @typeInfo(D.U).@"enum".fields.len;
}

pub fn uKinds(comptime D: type) [nU(D)]UnknownKind {
    if (@hasDecl(D, "u_kinds")) return D.u_kinds;
    return [_]UnknownKind{.voltage} ** nU(D);
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
        if (@hasDecl(D, "stateCtl"))
            expectFn(D, "stateCtl", fn (*const D.Model, *D.Instance, *D.State, StateCtlOp) bool);
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

    // Convergence aids. Only the 2-arg attempt form exists — batch.zig:616
    // calls it unconditionally; a 3-arg variant would never be invoked.
    if (@hasDecl(D, "attempt"))
        expectFn(D, "attempt", fn (D.Model, f64) D.Model);

    // Optional metadata.
    if (@hasDecl(D, "u_kinds") and @TypeOf(D.u_kinds) != [n]UnknownKind)
        @compileError(name ++ ".u_kinds must be [|U|]UnknownKind");
    if (@hasDecl(D, "noise_gens")) {
        const info = @typeInfo(@TypeOf(D.noise_gens));
        if (info != .array or info.array.child != NoiseGen(D))
            @compileError(name ++ ".noise_gens must be [k]NoiseGen(Self)");
    }
    // In-device noise PSDs: pure fn of ANY state vector (AC noise calls it
    // once at x_op, pnoise per PSS sample, tran-noise per step). Requires
    // noise_gens: return position k describes generator k. Devices without
    // it keep the thermal-off-the-Jacobian collectNoise fallback.
    if (@hasDecl(D, "noisePsd")) {
        if (!@hasDecl(D, "noise_gens"))
            @compileError(name ++ ".noisePsd requires pub const noise_gens");
        expectFn(D, "noisePsd", fn ([n]f64, *const D.Model, *const D.Instance) [D.noise_gens.len]PsdTerm);
    }
    if (@hasDecl(D, "limit_flag_unknowns")) {
        const info = @typeInfo(@TypeOf(D.limit_flag_unknowns));
        if (info != .array or info.array.child != D.U)
            @compileError(name ++ ".limit_flag_unknowns must be [k]U");
    }
    // Operating-point output variables: optional metadata + a matching
    // opValues hook (same comptime-S shape as eval). Position k in op_vars
    // describes element k of opValues's result.
    if (@hasDecl(D, "op_vars")) {
        const info = @typeInfo(@TypeOf(D.op_vars));
        if (info != .array or info.array.child != OpVar)
            @compileError(name ++ ".op_vars must be [k]OpVar");
        if (!@hasDecl(D, "opValues"))
            @compileError(name ++ ": op_vars requires pub fn opValues");
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

    // Pub-decl allowlist: only contract-recognized names may be pub.
    // zpicey_* are the dynamic plugin ABI (validated by dyn.zig loader).
    rejectStrayPubDecls(D);
}

const allowed_pub_decls = std.StaticStringMap(void).initComptime(.{
    .{ "U", {} },
    .{ "num_ports", {} },
    .{ "Model", {} },
    .{ "Instance", {} },
    .{ "eval", {} },
    .{ "q", {} },
    .{ "limit", {} },
    .{ "limit_flag_unknowns", {} },
    .{ "seed", {} },
    .{ "collapse", {} },
    .{ "initState", {} },
    .{ "updateState", {} },
    .{ "stateCtl", {} },
    .{ "State", {} },
    // Runtime analysis kind exported by generated devices for the analysis()
    // builtin; the host engine sets Instance.analysis_kind per pass.
    .{ "AnalysisKind", {} },
    // LRM 9.4 display tasks. Present ONLY in a device built with
    // `--display=emit` (FastVAF's testbench artifact); the engine never calls
    // it, and a device compiled for the solver does not have it at all.
    .{ "display", {} },
    .{ "histInject", {} },
    .{ "n_hist_signals", {} },
    .{ "gatherHistSignals", {} },
    .{ "delays", {} },
    .{ "attempt", {} },
    .{ "u_kinds", {} },
    .{ "noise_gens", {} },
    .{ "noisePsd", {} },
    .{ "op_vars", {} },
    .{ "opValues", {} },
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
        // <module>__analog_op__{laplace,zi}_*__sec — the cascade coefficients of
        // an LRM 4.5.11/4.5.12 filter. Public on purpose: they ARE the transfer
        // function, and a host running .ac/.noise builds H(jw) from them because
        // the real-valued residual cannot carry it. The name embeds the module,
        // so it cannot be in the list above.
        if (d.name.len >= 5 and std.mem.eql(u8, d.name[d.name.len - 5 ..], "__sec")) continue;
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
                ": field type must be numeric/bool/enum, []const u8, or a fixed-size array of these");
    }
}

fn isValueType(comptime T: type) bool {
    // Generated string parameters point at immutable literals in the device
    // image. The loader keeps that .so open for the lifetime of every opaque
    // Model blob, so copying the slice through init_model/ProtoStore is safe;
    // numeric setParam/collectParams intentionally ignore it.
    if (T == []const u8) return true;
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        // Integer-backed enums are fixed-size POD (e.g. Instance.analysis_kind).
        .@"enum" => |e| isValueType(e.tag_type),
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
