//! engine.zig — the whole device engine in one file: the derivative scalar,
//! type-erased batching (SoA), a SINK-PARAMETERIZED eval so one physics body
//! serves both CPU and GPU, persistent-worker CPU threading, the runtime `.so`
//! device ABI, and runtime VA/Verilog compile+cache+load.
//!
//! Consolidates the former batch.zig + par.zig + dyn.zig + load.zig.
//!
//! CPU vs GPU: gompute's `map` is elementwise-scalar-only and its `RawKernel`
//! is device-only, so device assembly (sparse gather → eval residual+Jacobian →
//! scatter) cannot be a single "compile the CPU code for GPU" map. Instead the
//! physics is written ONCE in `evalRange`, generic over a `sink`:
//! ONE `Sink(D, device, skip_const)` serves both: `device=false` scatters `+=`
//! into whichever planes the caller hands it (its own, or a ParEval lane's
//! private slab); `device=true` is a gompute `RawKernel` that atomic-scatters
//! into device buffers. gompute owns the GPU build/launch (was the hand-rolled
//! ptxas/nvlink megakernel).

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract");
const gompute = @import("gompute"); // GPU: RawKernel build/launch (shared core)
// NVPTX/AMDGCN emit no libcalls, so `@exp`/`@log`/`@sin`/`@cos` and
// std.math's sinh/cosh/pow are hard codegen errors in device compilation.
// gompute.math is the drop-in that also forwards to libm on the host.
const dmath = gompute.math;
// engine.zig is the SHARED device core: the app compiles it at comptime for
// builtins, and the FastVAF `.so` compiles this SAME source at runtime for
// dynamics — identical format by construction. Deps: std + contract + gompute
// (both app and .so provide gompute); NO fastvaf (that would be circular — the
// fastvaf-dependent loader lives in loader.zig, app-only).

// ===========================================================================
// Derivative scalar (moved out of contract.zig — the engine is the only thing
// that instantiates device physics with a concrete S).
// ===========================================================================

/// FMA contraction for the Dual derivative propagation, WITHOUT fast-math.
///
/// `@mulAdd` is the contraction `@setFloatMode(.optimized)` would license and
/// nothing else: no `nnan`, no `ninf`. That matters because `Dual.div` divides
/// by an unguarded `b.v`, and Verilog-A deliberately PERMITS that to be zero
/// (VerA proof.zig:33 — "`/` by zero is not an error […] rejecting it would
/// refuse `I <+ V/r`, the plain resistor"). A `ninf` assertion there would be
/// silent Release-only UB in the one place SparseLu's isFinite check exists to
/// catch (solvers/sparse_lu.zig:263,444).
///
/// A float mode on the CALLER cannot do this job: LLVM fast-math flags are
/// per-instruction, emitted from the callee's lexical scope, and inlining
/// copies them intact — measured, `evalRange`'s `@setFloatMode(.optimized)`
/// yields 0 `vfmadd` for a `mul` inlined out of this type.
///
/// GATED because on a target without the feature `@mulAdd` lowers to a libm
/// `fma()` CALL PER LANE — measured 14 calls for one `Dual(14).mul` on
/// `-mcpu=baseline`, i.e. catastrophically slower than the two-rounding form
/// it replaces.
/// ponytail: arch switch, not a build option; every target this ships to is
/// listed. Add a `-Dfma` knob only if a real target needs to override it.
const fma_ok = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .fma),
    .aarch64, .aarch64_be => true,
    .nvptx64, .amdgcn => true,
    else => false,
};

/// Forward-mode dual satisfying the device scalar interface S: one eval pass
/// yields residual + all analytic partials. Lane u carries ∂/∂x[u].
///
/// MIXED PRECISION. `F` is the width of the DERIVATIVE half only; the value
/// half is always f64 and every boundary of the contract's S protocol
/// (`con`/`scale`/`addC`/`val`/`ddxAt`) is f64, so a device never sees `F`.
/// `F = f32` is the inexact-Newton construction: Newton converges to the
/// accuracy of the RESIDUAL, and an approximate Jacobian costs iteration count
/// rather than the answer. It exists because sm_89 runs f32 at 69x its f64 rate
/// (docs/gpu-device-eval.md §1), which is the only route by which a compact
/// model beats this CPU. `jacFloat` decides per device — the permission is the
/// device's `jac_f32`, because only the physics knows whether its unknowns fit
/// in f32's ~7 digits.
pub fn Dual(comptime N: usize, comptime F: type) type {
    return DualFor(N, F, false);
}

fn DualFor(comptime N: usize, comptime F: type, comptime collapsed: bool) type {
    return struct {
        v: f64,
        /// A vector's natural ABI alignment is its SIZE — 64 bytes at N=8,
        /// F=f64 — which pads this struct to 128 bytes to carry 72 of payload
        /// and makes every array of duals 44% padding. `evalQ`'s
        /// `struct{res:[8]S, q:[8]S}` return is 2048 bytes for 1152 of payload,
        /// of which only 384 can be nonzero. Nothing reads `d` through a raw
        /// pointer — every consumer widens through `grad()`/`ddxAt()` into a
        /// plain f64 — so the alignment buys nothing and costs at most a
        /// `movaps`->`movups` swap, which is free on any AVX2 part.
        /// Measured on generated mos1 evalQ: sizeOf 128 -> 72, return struct
        /// 2048 -> 1152 B, 1727 -> 1631 static instructions (-95 of them moves,
        /// +2 FP), 920 -> 900 callgrind Ir per instance-eval.
        d: V align(@alignOf(F)),

        // Builders apply D.collapse before freezing the shared scatter tapes.
        pub const collapse_applied = collapsed;
        const V = @Vector(N, F);
        const Self = @This();

        inline fn splat(c: f64) V {
            return @splat(@floatCast(c));
        }
        /// a*b + c on the derivative vector, fused where the hardware has it.
        inline fn mulAddV(a: V, b: V, c: V) V {
            return if (fma_ok) @mulAdd(V, a, b, c) else a * b + c;
        }
        pub fn seed(value: f64, comptime u: usize) Self {
            var d: V = @splat(0);
            d[u] = 1;
            return .{ .v = value, .d = d };
        }
        pub fn con(c: f64) Self {
            return .{ .v = c, .d = splat(0) };
        }
        /// One of the three places the Jacobian widens back to f64 — the
        /// solver's `g_vals` is `[]f64` and feeds a sparse LU. The other two are
        /// `evalRange`'s scatter and its limiting correction.
        pub fn ddxAt(a: Self, col: usize) f64 {
            const lanes: [N]F = a.d;
            return lanes[col];
        }
        /// The whole derivative, widened. Callers that need f64 partials (the
        /// scatter, the limiting correction, noise) go through this rather than
        /// reading `.d`, so `F` stays private to the arithmetic.
        pub inline fn grad(a: Self) @Vector(N, f64) {
            return if (F == f64) a.d else @floatCast(a.d);
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
            return .{ .v = a.v * b.v, .d = mulAddV(b.d, splat(a.v), a.d * splat(b.v)) };
        }
        pub fn div(a: Self, b: Self) Self {
            const inv_b = 1.0 / b.v;
            const quot = a.v * inv_b;
            return .{ .v = quot, .d = mulAddV(b.d, splat(-quot), a.d) * splat(inv_b) };
        }
        pub fn scale(a: Self, c: f64) Self {
            return .{ .v = a.v * c, .d = a.d * splat(c) };
        }
        pub fn addC(a: Self, c: f64) Self {
            return .{ .v = a.v + c, .d = a.d };
        }
        pub fn exp(a: Self) Self {
            const e = dmath.exp(a.v);
            return .{ .v = e, .d = a.d * splat(e) };
        }
        pub fn log(a: Self) Self {
            return .{ .v = dmath.log(a.v), .d = a.d * splat(1.0 / a.v) };
        }
        /// Pure Zig libm forms preserve tiny arguments and the full f64 range.
        /// VerA's precompute scalar uses these same value operations.
        pub fn expm1(a: Self) Self {
            return .{ .v = std.math.expm1(a.v), .d = a.d * splat(dmath.exp(a.v)) };
        }
        pub fn log1p(a: Self) Self {
            return .{ .v = std.math.log1p(a.v), .d = a.d * splat(1.0 / (1.0 + a.v)) };
        }
        pub fn sqrt(a: Self) Self {
            const s = @sqrt(a.v);
            return .{ .v = s, .d = a.d * splat(if (s > 0.0) 0.5 / s else 0.0) };
        }
        pub fn sin(a: Self) Self {
            return .{ .v = dmath.sin(a.v), .d = a.d * splat(dmath.cos(a.v)) };
        }
        pub fn cos(a: Self) Self {
            return .{ .v = dmath.cos(a.v), .d = a.d * splat(-dmath.sin(a.v)) };
        }
        pub fn tanh(a: Self) Self {
            const th = dmath.tanh(a.v);
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
        /// c·x^(c−1) = c·p/x — one `pow`, and algebraically exact for x != 0
        /// including §4.3.1's negative-base integral-c clause.
        ///
        /// x == 0 keeps the second `pow`, and is NOT a rounding nicety: at
        /// c == 1 the true slope is 1, but c·p/x is 0/0 = NaN, the isFinite
        /// gate below would drop it, and the Jacobian row goes flat. `mjs`
        /// defaults to 0 in bjt.va, so `1 - mjs` is exactly that exponent and
        /// the substrate base `1 - v/ps` reaches exactly 0 at v == ps. The
        /// branch is never taken at a normal bias, so the hot path is still
        /// one `pow`. Same rule VerA's `zPow` applies — codegen now routes a
        /// solve-constant exponent here instead, so the two must agree.
        pub fn pow(a: Self, c: f64) Self {
            const p = dmath.pow(a.v, c);
            const slope = if (a.v != 0.0) c * p / a.v else c * dmath.pow(a.v, c - 1.0);
            return .{ .v = p, .d = a.d * splat(if (std.math.isFinite(slope)) slope else 0.0) };
        }
        pub fn atan(a: Self) Self {
            return .{ .v = std.math.atan(a.v), .d = a.d * splat(1.0 / (1.0 + a.v * a.v)) };
        }
        pub fn sinh(a: Self) Self {
            return .{ .v = dmath.sinh(a.v), .d = a.d * splat(dmath.cosh(a.v)) };
        }
        pub fn cosh(a: Self) Self {
            return .{ .v = dmath.cosh(a.v), .d = a.d * splat(dmath.sinh(a.v)) };
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

        // Relational + select, required by VerA's contract decl set
        // (../VerA/tools/contract.zig: "max","lt","le","eq","sel","val",
        // "ddxAt"). A comparison is an indicator: value 0 or 1, derivative
        // zero almost everywhere, so `con` is the right constructor — the
        // branch carries no sensitivity of its own. Semantics match VerA's
        // reference lowering (../VerA/src/backend/tb.zig).
        pub fn lt(a: Self, b: Self) Self {
            return con(@floatFromInt(@intFromBool(a.v < b.v)));
        }
        pub fn le(a: Self, b: Self) Self {
            return con(@floatFromInt(@intFromBool(a.v <= b.v)));
        }
        pub fn eq(a: Self, b: Self) Self {
            return con(@floatFromInt(@intFromBool(a.v == b.v)));
        }
        /// `c` is such an indicator (or any 0/1-valued expression): picks `a`
        /// when nonzero. Derivatives ride with the taken branch, which is
        /// what keeps a lowered ternary differentiable.
        pub fn sel(c: Self, a: Self, b: Self) Self {
            return if (c.v != 0.0) a else b;
        }
    };
}

/// `Dual` with the derivative half deleted: the same S protocol, so the same
/// `D.eval`/`D.q` body compiles against it, and every method here is the `.v`
/// line of the matching `Dual` method VERBATIM — `div`'s reciprocal-multiply,
/// `abs`'s sign test (not `@abs`, which differs at -0), `min`/`max`'s tie rule.
/// That is the whole contract of this type: value-for-value identical to a Dual
/// pass, so a caller that only reads `.v` may substitute it freely.
///
/// For `evalQRange`, the transient's post-accept charge re-read: it throws both
/// Jacobians away, and computing the 8-lane gradient of a mos1 core to discard
/// it is the bulk of what that pass costs.
///
/// VerA emits an equivalent `R` inside every stateful device (codegen.zig
/// `rscalar_txt`) for `updateState`/`limit`/`collapse`, but the contract keeps
/// it private, so a host that wants one declares its own.
fn RealFor(comptime collapsed: bool) type {
    return struct {
        v: f64,

        const Self = @This();
        pub const collapse_applied = collapsed;

        pub fn seed(value: f64, comptime _: usize) Self {
            return .{ .v = value };
        }
        pub fn con(c: f64) Self {
            return .{ .v = c };
        }
        pub fn val(a: Self) f64 {
            return a.v;
        }
        /// A value-only pass has no derivative; the contract still requires the
        /// accessor. Same answer VerA's `R` gives.
        pub fn ddxAt(_: Self, _: usize) f64 {
            return 0.0;
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
        /// `Dual.div` computes `a.v * (1/b.v)`, not `a.v / b.v`, because it
        /// needs the reciprocal for the derivative anyway. The two differ in
        /// the last bit; this pass has to match the Dual one, so it keeps the
        /// reciprocal.
        pub fn div(a: Self, b: Self) Self {
            return .{ .v = a.v * (1.0 / b.v) };
        }
        pub fn scale(a: Self, c: f64) Self {
            return .{ .v = a.v * c };
        }
        pub fn addC(a: Self, c: f64) Self {
            return .{ .v = a.v + c };
        }
        pub fn exp(a: Self) Self {
            return .{ .v = dmath.exp(a.v) };
        }
        pub fn log(a: Self) Self {
            return .{ .v = dmath.log(a.v) };
        }
        pub fn expm1(a: Self) Self {
            return .{ .v = std.math.expm1(a.v) };
        }
        pub fn log1p(a: Self) Self {
            return .{ .v = std.math.log1p(a.v) };
        }
        pub fn sqrt(a: Self) Self {
            return .{ .v = @sqrt(a.v) };
        }
        pub fn sin(a: Self) Self {
            return .{ .v = dmath.sin(a.v) };
        }
        pub fn cos(a: Self) Self {
            return .{ .v = dmath.cos(a.v) };
        }
        pub fn tanh(a: Self) Self {
            return .{ .v = dmath.tanh(a.v) };
        }
        pub fn sinh(a: Self) Self {
            return .{ .v = dmath.sinh(a.v) };
        }
        pub fn cosh(a: Self) Self {
            return .{ .v = dmath.cosh(a.v) };
        }
        pub fn atan(a: Self) Self {
            return .{ .v = std.math.atan(a.v) };
        }
        /// NOT `@abs`: `Dual.abs` is a sign test, which returns -0 unchanged.
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
            return .{ .v = dmath.pow(a.v, c) };
        }
        pub fn max(a: Self, b: Self) Self {
            return if (a.v >= b.v) a else b;
        }
        pub fn min(a: Self, b: Self) Self {
            return if (a.v <= b.v) a else b;
        }
        pub fn lt(a: Self, b: Self) Self {
            return con(@floatFromInt(@intFromBool(a.v < b.v)));
        }
        pub fn le(a: Self, b: Self) Self {
            return con(@floatFromInt(@intFromBool(a.v <= b.v)));
        }
        pub fn eq(a: Self, b: Self) Self {
            return con(@floatFromInt(@intFromBool(a.v == b.v)));
        }
        pub fn sel(c: Self, a: Self, b: Self) Self {
            return if (c.v != 0.0) a else b;
        }
    };
}

// ===========================================================================
// Constants + contract re-exports
// ===========================================================================

/// Width of the derivative half of `Dual` for device D. `pub const jac_f32` is
/// VerA's `--jac-f32` permission (contract.zig, "THE WIDTHS INSIDE S ARE THE
/// HOST'S"); a device that does not declare it gets f64, which is what a host
/// must assume.
pub fn jacFloat(comptime D: type) type {
    return if (@hasDecl(D, "jac_f32") and D.jac_f32) f32 else f64;
}

pub const GROUND: u32 = 0;

pub const StateCtlOp = contract.StateCtlOp;
pub const SimState = contract.SimState;
pub const LimitResult = contract.LimitResult;
pub const Constant = contract.Constant;

// ===========================================================================
// Circuit-facing types
// ===========================================================================

pub const ParamRef = struct {
    /// Tagged because BOTH widths are live: VerA emits `f64` parameters, while
    /// hand-written devices (tests/testdev.zig, and any device written straight
    /// against the contract) still use `f32`. A single-width `*f32` here is what
    /// silently emptied `collectParams` for every generated device and took
    /// `.dc` sweep, Monte Carlo, sensitivity and dcmatch down with it — those
    /// four read the circuit's parameters through this and got nothing back.
    ///
    /// The accessors below are the whole interface; nothing outside should
    /// switch on the tag. Values move as `f64` because that is what the callers
    /// compute in — an `f32` field round-trips through `@floatCast`, which is
    /// exactly the precision the device declared.
    ptr: Ptr,
    device_type: []const u8,
    param_name: []const u8,
    index: u32,
    is_instance: bool,
    primary: bool,
    pelgrom_ap: f64 = 0,
    area_wl: f64 = 0,

    pub const Ptr = union(enum) {
        f32: *f32,
        f64: *f64,
    };

    pub fn get(self: ParamRef) f64 {
        return switch (self.ptr) {
            .f32 => |p| p.*,
            .f64 => |p| p.*,
        };
    }

    /// Low-level write; call Circuit.recompute before solving to validate topology and caches.
    pub fn set(self: ParamRef, v: f64) void {
        switch (self.ptr) {
            .f32 => |p| p.* = @floatCast(v),
            .f64 => |p| p.* = v,
        }
    }
};

pub const NoiseSource = struct {
    node_p: u32,
    node_n: u32,
    kind: NoiseGenKind = .thermal,
    conductance: f64,
    current: f64 = 0,
    kf: f64 = 0,
    af: f64 = 1,
};

pub const NoiseGenKind = enum { thermal, shot, flicker };
pub const NoiseGen = struct { row: usize, col: usize, kind: NoiseGenKind };

/// Target value planes for one eval pass. Circuit.eval points this at its own
/// slices; parallel eval points lanes 1.. at private slabs and reduces after.
pub const Planes = struct {
    g_vals: []f64,
    c_vals: []f64,
    rhs: []f64,
    q_vec: []f64,
};

/// Per-type device batch vtable. One entry per device TYPE, created by
/// ProtoStore(D).finalize(). eval/eval_newton stamp [first..last) into `pl` —
/// the caller picks the target planes, so the same entry point serves the
/// serial path and a ParEval lane's private slab.
pub const Batch = struct {
    // -- hot --
    ctx: *anyopaque,
    eval: *const fn (*anyopaque, *const Planes, first: u32, last: u32, []const f64, f64) void,
    eval_newton: *const fn (*anyopaque, *const Planes, first: u32, last: u32, []const f64, f64) void,
    count: u32,
    n_u: u32,
    has_charge: bool,
    has_const_jacobian: bool,
    /// False when eval uses shared per-batch scratch — such a batch runs whole
    /// on one lane.
    thread_safe: bool,

    // -- cold --
    type_name: []const u8,
    hooks: *const Hooks,
};

/// Cold per-device-type vtable. Null entry ⇒ device type lacks the hook.
pub const Hooks = struct {
    scatter_bounds: *const fn (*anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32,
    apply_limits: ?*const fn (*anyopaque, []f64, []const f64) bool = null,
    clear_limits: ?*const fn (*anyopaque) void = null,
    seed: ?*const fn (*anyopaque, []f64) void = null,
    mark_current_rows: ?*const fn (*anyopaque, []bool) void = null,
    update_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    /// `updateState` for a device that declares NO `stateCtl` — one whose
    /// accepted-step state cannot be rolled back. Called once per ACCEPTED
    /// step instead of once per Newton iteration.
    ///
    /// §4.5.2 calls this "accepted-step bookkeeping" and it has to be taken
    /// literally. VerA lowers `absdelay` to a `zHistPush` into a fixed
    /// 32-entry ring INSIDE `updateState`. Driven per Newton iteration —
    /// rejected attempts included — a transmission line took ~10 pushes per
    /// timestep, so the ring spanned a fraction of one timestep instead of
    /// 32 of them; every delay lookup fell off the end, `zHistAt` returned
    /// the NEWEST sample, and the line behaved as if it had no delay.
    ///
    /// That fed back into the solver: the bogus residual stopped Newton
    /// converging, dt halved, and more attempts meant more pushes.
    /// devices/lossy_tline ran 51,847 step attempts — 25,624 rejected, mean
    /// 9.9 iterations against a cap of 10 — to emit 600 requested points.
    ///
    /// Only HISTORY devices defer. Everything else keeps the per-iteration
    /// call: either `stateCtl` makes its updates undoable, or its
    /// `request_reject_at` is a breakpoint that must be seen per attempt for
    /// a source edge to land sharply.
    commit_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    state_ctl: ?*const fn (*anyopaque, StateCtlOp) bool = null,
    set_temp: ?*const fn (*anyopaque, f32) void = null,
    /// Host-owned Instance fields (`$abstime`, timestep, `analysis()`,
    /// `initial_step`/`final_step`). A generated device READS these and never
    /// writes them, so nothing else in the engine can supply them — without
    /// this hook `$abstime` is pinned at its default 0 and every SPICE
    /// waveform degenerates to its t=0 value.
    ///
    /// Contract with the analyses: call it once per SOLVE ATTEMPT (before
    /// eval/updateState run for that attempt), never per Newton iteration —
    /// it walks every instance, so it is O(count) per timepoint by design.
    set_sim_state: ?*const fn (*anyopaque, SimState) void = null,
    record_history: ?*const fn (*anyopaque, []const f64, f64) void = null,
    inject_history: ?*const fn (*anyopaque, f64, []f64) void = null,
    min_delay: ?*const fn (*anyopaque) f64 = null,
    /// §9.17.2 `$bound_step`: the tightest NEXT-step bound any instance of
    /// this device type asked for, or `inf`. Written by the device's
    /// `updateState`, so it is only meaningful after one has run — the
    /// transient reads it per accepted step, which is what §9.17.2 says.
    ///
    /// Distinct from `min_delay`, which is a static property of the MODEL
    /// (`D.delays`). A generated device has no `delays` decl at all, so
    /// `min_delay` is null for every VerA model and the transmission lines
    /// were running completely unbounded: tline's `$bound_step(0.25*td)` was
    /// computed, stored, and read by nothing.
    bound_step: ?*const fn (*anyopaque) f64 = null,
    next_breakpoint: ?*const fn (*anyopaque, f64) ?f64 = null,
    /// Per-device-STATE charge tape: `q_tape()[id * n_u + ru]` is the charge
    /// THIS instance put on row `rhs_idx[id * n_u + ru]` at the last eval —
    /// the same index space `gath`/`rhs_idx`/`slots` already use, so it adds
    /// no new handle type. Null when the device declares no `q`.
    ///
    /// Exists because ngspice runs CKTterr once per device charge STATE and
    /// mins over states, then over devices (ckttrunc.c -> DEVtrunc ->
    /// cktterr.c), where this engine ran it once per matrix ROW off the summed
    /// q plane. Summing co-moving charges first adds their divided differences
    /// and loses the binding state (docs/analysis/transient-integration.md).
    /// Host-only and additive: the four `[]f64` planes, the u32 tapes, the CSC
    /// pattern, the Model/Instance PODs and `DeviceKernel.run`'s parameter
    /// list are all unchanged.
    q_tape: ?*const fn (*anyopaque) []const f64 = null,
    /// Charges only, whole batch: restamp `q_vec` + `q_tape` at `x` and leave
    /// g/c/rhs alone. Null when the device declares no `q`. See `evalQRange` —
    /// this is the transient's post-accept re-read, not a second eval path.
    eval_q: ?*const fn (*anyopaque, *const Planes, []const f64, f64) void = null,
    collect_params: *const fn (*anyopaque, std.mem.Allocator, *std.ArrayList(ParamRef)) anyerror!void,
    collect_noise: ?*const fn (*anyopaque, []const f64, std.mem.Allocator, *std.ArrayList(NoiseSource)) anyerror!void = null,
    recompute: ?*const fn (*anyopaque) error{TopologyChanged}!void = null,
    /// This batch's device-resident working set, or null when the device type
    /// is not `gpuEligible` — the launcher reads a null here as "this batch
    /// stays on the CPU" and declines the whole circuit rather than splitting a
    /// solve across both, which would cost a plane round-trip per iteration to
    /// merge.
    gpu_payload: ?*const fn (*anyopaque) GpuPayload = null,
    apply_attempt: ?*const fn (*anyopaque, f64) void = null,
    restore_models: ?*const fn (*anyopaque) void = null,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
};

pub const Proto = struct {
    ctx: *anyopaque,
    type_name: []const u8,
    pattern: *const fn (*anyopaque, std.mem.Allocator, *PatternBuilder) anyerror!void,
    finalize: *const fn (*anyopaque, std.mem.Allocator, PatternView) anyerror!Batch,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    apply_perm: *const fn (*anyopaque, []const u32) void,
};

pub const PatternView = struct {
    col_ptr: []const u32,
    row_idx: []const u32,
    n: u32,
    trash_slot: u32,

    pub fn findSlot(self: PatternView, row: u32, col: u32) ?u32 {
        var lo = self.col_ptr[col];
        var hi = self.col_ptr[col + 1];
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.row_idx[mid] < row) lo = mid + 1 else hi = mid;
        }
        if (lo < self.col_ptr[col + 1] and self.row_idx[lo] == row) return lo;
        return null;
    }
};

pub const PatternBuilder = struct {
    keys: std.ArrayList(u64) = .empty,

    pub fn add(self: *PatternBuilder, gpa: std.mem.Allocator, row: u32, col: u32) !void {
        try self.keys.append(gpa, (@as(u64, col) << 32) | row); // col-major sort order
    }

    pub fn reserve(self: *PatternBuilder, gpa: std.mem.Allocator, extra: usize) !void {
        try self.keys.ensureUnusedCapacity(gpa, extra);
    }

    pub fn deinit(self: *PatternBuilder, gpa: std.mem.Allocator) void {
        self.keys.deinit(gpa);
    }

    /// LSD radix sort (16-bit digits): O(n) on the bounded (col,row) keys.
    fn radixSort(gpa: std.mem.Allocator, sort_keys: []u64) !void {
        if (sort_keys.len < 64) {
            std.mem.sortUnstable(u64, sort_keys, {}, std.sort.asc(u64));
            return;
        }
        var max_key: u64 = 0;
        for (sort_keys) |k| max_key = @max(max_key, k);

        const tmp = try gpa.alloc(u64, sort_keys.len);
        defer gpa.free(tmp);
        const counts = try gpa.alloc(u32, 1 << 16);
        defer gpa.free(counts);

        var src: []u64 = sort_keys;
        var dst: []u64 = tmp;
        var shift: u6 = 0;
        while (true) {
            @memset(counts, 0);
            for (src) |k| counts[@as(u16, @truncate(k >> shift))] += 1;
            var sum: u32 = 0;
            for (counts) |*c| {
                const c0 = c.*;
                c.* = sum;
                sum += c0;
            }
            for (src) |k| {
                const d: u16 = @truncate(k >> shift);
                dst[counts[d]] = k;
                counts[d] += 1;
            }
            const t = src;
            src = dst;
            dst = t;
            if (shift >= 48 or (max_key >> shift) >> 16 == 0) break;
            shift += 16;
        }
        if (src.ptr != sort_keys.ptr) @memcpy(sort_keys, src);
    }

    pub fn toCsc(self: *PatternBuilder, gpa: std.mem.Allocator, n: u32, col_ptr_out: *[]u32, row_idx_out: *[]u32) !u32 {
        const all = self.keys.items;
        try radixSort(gpa, all);
        var m: usize = 0;
        for (all) |k| {
            if (m == 0 or all[m - 1] != k) {
                all[m] = k;
                m += 1;
            }
        }
        const nnz: u32 = @intCast(m);

        const col_ptr = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(col_ptr);
        const row_idx = try gpa.alloc(u32, nnz);
        @memset(col_ptr, 0);
        for (all[0..m], 0..) |k, p| {
            row_idx[p] = @truncate(k);
            col_ptr[(k >> 32) + 1] += 1;
        }
        for (0..n) |j| col_ptr[j + 1] += col_ptr[j];
        col_ptr_out.* = col_ptr;
        row_idx_out.* = row_idx;
        return nnz;
    }
};

/// Scatter window over precomputed tapes: min/max slot and rhs row touched,
/// trash slot / trash row (ground writes) excluded.
pub fn tapeBounds(slots: []const u32, rhs_idx: []const u32, trash_slot: u32, trash_row: u32) [4]u32 {
    var slot_lo: u32 = std.math.maxInt(u32);
    var slot_hi: u32 = 0;
    var row_lo: u32 = std.math.maxInt(u32);
    var row_hi: u32 = 0;
    for (slots) |s| {
        if (s == trash_slot) continue;
        slot_lo = @min(slot_lo, s);
        slot_hi = @max(slot_hi, s + 1);
    }
    for (rhs_idx) |r| {
        if (r == trash_row) continue;
        row_lo = @min(row_lo, r);
        row_hi = @max(row_hi, r + 1);
    }
    if (slot_lo > slot_hi) slot_lo = slot_hi;
    if (row_lo > row_hi) row_lo = row_hi;
    return .{ slot_lo, slot_hi, row_lo, row_hi };
}

/// Precompute the gather/scatter tapes for one batch from its flat node
/// list ([id * n_u + u] layout). Ground rows/cols land in the trash slot, and
/// so do the STRUCTURALLY zero (row, col) pairs `pat` clears — `addPattern`
/// did not reserve a matrix entry for them and `evalRange` never reads them
/// back, so the trash slot is the one answer that keeps the tape's frozen
/// `[id][ru][cu]` shape while the matrix carries only the entries a device
/// can actually fill.
pub fn buildTapes(nodes: []const u32, n_u: usize, pat: []const u64, pv: PatternView, gath: []u32, rhs_idx: []u32, slots: []u32) void {
    const count = nodes.len / n_u;
    for (0..count) |id| {
        const nd = nodes[id * n_u ..][0..n_u];
        for (nd, 0..) |node, u| {
            gath[id * n_u + u] = node;
            rhs_idx[id * n_u + u] = if (node == GROUND) pv.n else node;
        }
        for (nd, 0..) |r, ru| for (nd, 0..) |c, cu| {
            const live = (pat[ru] >> @intCast(cu)) & 1 != 0;
            slots[(id * n_u + ru) * n_u + cu] =
                if (r == GROUND or c == GROUND or !live) pv.trash_slot else pv.findSlot(r, c).?;
        };
    }
}

/// D's structural Jacobian, resistive OR reactive: bit `cu` of row `ru` is set
/// when this device can put anything at all in local matrix entry (ru, cu).
///
/// VerA emits `jac_pattern`/`q_pattern` (see its `emitPattern`); a device that
/// declares neither gets all ones, which is the dense behaviour every host had
/// before the declaration existed — runtime `.so` devices built by an older
/// generator included.
fn jacPattern(comptime D: type) [contract.nU(D)]u64 {
    var out = rowPattern(D, "jac_pattern");
    // A device with no reactive residual has no charge columns to reserve;
    // asking `rowPattern` for the missing half would answer "dense" and undo
    // the whole reservation.
    if (@hasDecl(D, "q")) {
        const q = rowPattern(D, "q_pattern");
        for (&out, q) |*o, qm| o.* |= qm;
    }
    return out;
}

/// One half of it. An undeclared half is all ones — the dense behaviour every
/// host had before the declaration existed, which is also what a runtime `.so`
/// device from an older generator gets.
fn rowPattern(comptime D: type, comptime name: []const u8) [contract.nU(D)]u64 {
    if (!@hasDecl(D, name)) return @splat(std.math.maxInt(u64));
    return @field(D, name);
}

// ===========================================================================
// Sink-parameterized eval — the ONE physics body. `sink` (comptime-known)
// owns all memory access, so the same loop serves both instantiations of the
// ONE `Sink` type (CPU `+=`, GPU atomic-scatter). Always AD (Dual): residual +
// Jacobian in one pass.
// ===========================================================================

fn evalRange(comptime D: type, sink: anytype, first: u32, end: u32, t: f64, limiting: bool) void {
    @setEvalBranchQuota(1_000_000);
    const SinkT = @typeInfo(@TypeOf(sink)).pointer.child;
    @setFloatMode(.optimized);
    const n_u = comptime contract.nU(D);
    const has_limit = comptime @hasDecl(D, "limit");
    const S = DualFor(n_u, jacFloat(D), @hasDecl(D, "collapse"));
    const use_lim = if (comptime has_limit) limiting else false;
    const jac_pat = comptime rowPattern(D, "jac_pattern");
    const q_pat = comptime rowPattern(D, "q_pattern");
    // BRANCHLESS GROUND on the host. A ground row/column already resolves to
    // `trash_row`/`trash_slot` in the tape, so `+= v` there is architecturally
    // a no-op — the predicate only saves one add on a line that is L1-resident
    // by construction (every instance in the batch shares it), and costs a test
    // per stamp plus the `active` array itself in the frame.
    //
    // NOT on the GPU, and that is measured: there the skipped add is a
    // CONTENDED ATOMIC on one address across the whole grid, worth 2x on
    // 40,000 instances (docs/device-evaluation-audit-2026-09.md, "Ground
    // scatter"). Same body, opposite right answer, so it is a comptime split
    // on the sink's own `device` flag.
    const mask_ground = comptime SinkT.on_device;

    var id: u32 = first;
    while (id < end) : (id += 1) {
        // Gather the local eval point; corr = local(x) − lx (zero unless limiting).
        var lx: [n_u]f64 = undefined;
        var active: [n_u]bool = undefined;
        var corr: @Vector(n_u, f64) = @splat(0);
        inline for (0..n_u) |u| {
            const gi = sink.gath(id, u);
            active[u] = gi != GROUND;
            const xg = sink.x(gi);
            lx[u] = xg;
            if (use_lim) {
                const l = sink.lim(id, u);
                lx[u] = l;
                corr[u] = xg - l;
            }
        }
        // Limiting being ARMED is not the same as any unknown having moved:
        // `lim_x` equals `x` on every instance the limiter left alone, which
        // near convergence is nearly all of them. One vector compare replaces
        // `2 * n_u` masked dot products of a zero vector.
        const corr_live = use_lim and @reduce(.Or, corr != @as(@Vector(n_u, f64), @splat(0)));

        var xv: [n_u]S = undefined;
        inline for (0..n_u) |u| xv[u] = S.seed(lx[u], u);

        // `eval` and `q` each open their own call to the device's shared model
        // core, so asking for both ran the whole model TWICE — measured at 2x
        // the core entries per instance eval (158,556 for 79,278 on a 6-MOS
        // transient), against device eval that is 92% of the run. `evalQ` is
        // the same physics off ONE core call; VerA's generated testbench gates
        // it against `eval`/`q` bit-for-bit, value and derivative.
        const has_q = comptime @hasDecl(D, "q");
        const fuse = comptime has_q and @hasDecl(D, "evalQ");

        var out: [n_u]S = undefined;
        var qo: if (has_q) [n_u]S else void = undefined;
        if (comptime fuse) {
            const both = @call(.always_inline, D.evalQ, .{ S, xv, sink.model(id), sink.inst(id), t });
            out = both.res;
            qo = both.q;
        } else {
            out = D.eval(S, xv, sink.model(id), sink.inst(id), t);
            if (comptime has_q) qo = D.q(S, xv, sink.model(id), sink.inst(id), t);
        }

        // Ground matrix/residual stamps are discarded. Keep their AD lanes
        // for limiting; charge rows still feed per-state tapes and conservation.
        //
        // `jac_pat`/`q_pat` are the DEVICE's structural Jacobian: a clear bit
        // is an entry the physics can never fill, so the stamp goes away at
        // comptime instead of adding 0.0 to a matrix slot once per instance per
        // Newton iteration. mos1 keeps 21 of 64 resistive and 16 of 64 reactive
        // columns; the cleared ones also never reached `addPattern`, so there
        // is no matrix entry behind them to add to.
        //
        // TWO passes over the rows, and `rhs_idx[id * n_u + ru]` is read in
        // each of them. That is not an oversight: fusing them into one pass is
        // bit-identical (the four planes are disjoint arrays and the write
        // order within each stays `ru`/`cu` ascending) and it does save the
        // reload plus the `slots + (id*n_u+ru)*n_u` base the two halves share
        // — 387 -> 360 Ir per instance on the standalone stamp rig at mos1
        // geometry. It was built and measured on the real kernel and it does
        // not pay: fusing keeps `out` live across the charge stamps as well,
        // and inside a 1460-Ir body with 8 duals of each residual already in
        // the frame the extra pressure costs more than the addressing saves.
        // mos6_inverter 248.51M -> 246.67M Ir, but parallel_inverters_100
        // 704.92M -> 706.92M with the whole delta inside the mos1 kernel
        // (+2.39M). Device-dependent codegen, not a lever. Reverted.
        inline for (0..n_u) |ru| if (!mask_ground or active[ru]) {
            const row = sink.rhsRow(id, ru);
            var val = out[ru].v;
            if (comptime has_limit) {
                // Widened FIRST: this term lands on the residual, which stays
                // f64 whatever the Jacobian is carried in. An empty row has an
                // identically zero gradient, so the correction is zero too.
                if (corr_live and comptime jac_pat[ru] != 0) val += @reduce(.Add, out[ru].grad() * corr);
            }
            sink.scatterRes(row, val);
            if (comptime !SinkT.skip_g and jac_pat[ru] != 0) {
                const g = out[ru].grad();
                inline for (0..n_u) |cu| if (comptime (jac_pat[ru] >> cu) & 1 != 0) if (!mask_ground or active[cu]) {
                    sink.scatterJac(id, ru, cu, g[cu]);
                };
            }
        };

        if (comptime has_q) {
            inline for (0..n_u) |ru| {
                const row = sink.rhsRow(id, ru);
                var qv = qo[ru].v;
                if (comptime has_limit) {
                    if (corr_live and comptime q_pat[ru] != 0) qv += @reduce(.Add, qo[ru].grad() * corr);
                }
                // EVERY charge row is written, cleared pattern included: the
                // q plane is a conservation sum and `q_tape` is what CKTterr
                // runs over. Only the JACOBIAN columns are structural.
                //
                // A CLEAR PATTERN ROW IS NOT A LICENCE TO SKIP THE STAMP, here
                // or on the resistive half, and the resistive version of that
                // mistake is one you would never see in a diff. VerA builds
                // these masks by ORing `unknownDeps(value)` into the row at
                // every `res[...]` it emits (codegen.zig `patRow`), so a term
                // whose value depends on no unknown leaves the row's mask CLEAR
                // while writing the row. `isource` is exactly that —
                // `jac_pattern = {0, 0}` with `eval` stamping the DC current
                // into both rows — so gating `scatterRes` on `jac_pat[ru] != 0`
                // deletes every independent current source in the netlist.
                //
                // No device in today's set does it on the REACTIVE half (all 39
                // generated devices checked: every row `q` writes has a nonzero
                // `q_pattern` row), but nothing in the generator prevents it,
                // and the failure mode is worse: a `ddt()` of something that
                // varies with `t` and not with `x` would leave `q_tape` holding
                // a frozen 0 for a state that is actually moving, and
                // `stepBound` would drop a real LTE bound and run the step
                // long. Skipping the 4-of-8 dead mos1 charge rows is worth 14
                // Ir per instance on the stamp rig; the predicate that would
                // earn it safely is "row `ru` is ever written at all", which
                // the generator knows and does not emit. That is a VerA
                // declaration (`q_rows`/`jac_rows`), not a host inference.
                sink.scatterQ(id, ru, row, qv);
                if (comptime !SinkT.skip_c and q_pat[ru] != 0) {
                    if (!mask_ground or active[ru]) {
                        const gq = qo[ru].grad();
                        inline for (0..n_u) |cu| if (comptime (q_pat[ru] >> cu) & 1 != 0) if (!mask_ground or active[cu]) {
                            sink.scatterQJac(id, ru, cu, gq[cu]);
                        };
                    }
                }
            }
        }
    }
}

/// `evalRange`'s REACTIVE half, alone — same seed, same `D.q`, same `scatterQ`,
/// and an `S` whose value arithmetic is `Dual`'s verbatim, so `q_vec` and
/// `q_tape` come out bit-for-bit what a full eval would leave there. Host only.
///
/// `S` is a PARAMETER because the caller passes `RealFor`, and this pass reads
/// only `.v`. Measured: LLVM dead-codes `Dual`'s gradient here for a small core
/// (mos1/parallel_inverters_100 is a wash, +0.01%) and does NOT for a larger one
/// (mos6_inverter 204.14M -> 199.43M Ir, -2.3%), so the value-only `S` is what
/// makes "computes no derivatives" a property of the type instead of a property
/// of the optimizer — which is the half of it that scales to bsim4/hicum.
///
/// The transient re-reads the charges once per ACCEPTED step, because `newton()`
/// returns on the iterate it converged without reassembling: the planes hold
/// q(x_k) while the accepted point is x_k+1 (tran.zig, post-accept block). It
/// used a whole `Circuit.eval` for that — 595 extra full device passes on
/// scaling/parallel_inverters_100, 16% of the program — and threw g/c/rhs away,
/// since the next step's first assemble restamps all three.
///
/// Everything `evalRange` does that this drops is dead at that call site:
/// `D.eval`'s residual and both Jacobians (restamped) and the limiting
/// correction (`converger` clears limits before it returns, so `corr` is
/// identically zero). What survives is the charge, which is exactly what the
/// caller reads.
fn evalQRange(comptime D: type, comptime S: type, sink: anytype, first: u32, end: u32, t: f64) void {
    @setEvalBranchQuota(1_000_000);
    @setFloatMode(.optimized);
    const n_u = comptime contract.nU(D);
    var id: u32 = first;
    while (id < end) : (id += 1) {
        var xv: [n_u]S = undefined;
        inline for (0..n_u) |u| xv[u] = S.seed(sink.x(sink.gath(id, u)), u);
        const qo = D.q(S, xv, sink.model(id), sink.inst(id), t);
        // EVERY charge row, cleared pattern included — see `evalRange`'s note.
        inline for (0..n_u) |ru| sink.scatterQ(id, ru, sink.rhsRow(id, ru), qo[ru].v);
    }
}

/// SPICE-style limiting pass: cur = local(x); old = lim (once engaged) else
/// local(x_old); lim = D.limit(cur, old). Returns 1.0 if any instance reported
/// `converged = false` — the DEVICE decides whether its clamp was significant
/// enough to force another Newton iteration (pnjlim says yes, a cosmetic
/// fetlim/limvds clamp says no). This replaces the old `limit_flag_unknowns`
/// table, which could only answer that positionally and so could not tell a
/// large clamp from a small one on the same unknown.
fn limitRange(comptime D: type, sink: anytype, first: u32, end: u32, lim_active: bool) f64 {
    const n_u = comptime contract.nU(D);
    var flag: f64 = 0;
    var id: u32 = first;
    while (id < end) : (id += 1) {
        var cur: [n_u]f64 = undefined;
        var old: [n_u]f64 = undefined;
        inline for (0..n_u) |u| {
            const gi = sink.gath(id, u);
            cur[u] = sink.x(gi);
            old[u] = if (lim_active) sink.lim(id, u) else sink.xOld(gi);
        }
        // NOT `@call(.always_inline, ...)`, and that is measured, not an
        // oversight. `limit`'s contract signature is `[n_u]f64` BY VALUE twice
        // in and a `LimitResult(n_u)` out, so a real call boundary here would
        // cost 2*n_u stores plus n_u+1 loads of pure ABI per instance per
        // Newton iterate — but there is no call boundary: one call site and a
        // small leaf body mean LLVM already inlines it. Forcing the same
        // decision explicitly only takes it away from the inliner's own
        // ordering, and it is a LOSS: same tree, two builds, raw byte-identical,
        // scaling/parallel_inverters_100 504.35M -> 505.78M Ir (+0.28%),
        // devices/mos6_inverter 175.54M -> 175.89M (+0.20%).
        //
        // An env-gated A/B of the two call forms INSIDE one binary says the
        // opposite (-3.9%/-3.0%) and is wrong: keeping a non-inlined arm alive
        // forces `D.limit` to be emitted out of line, so that experiment prices
        // the cost of DEFEATING the inliner, not the benefit of helping it.
        // Inlining questions need two builds.
        const lm = D.limit(sink.model(id), sink.inst(id), cur, old);
        if (!lm.converged) flag = 1;
        inline for (0..n_u) |u| sink.setLim(id, u, lm.x[u]);
    }
    return flag;
}

// ===========================================================================
// ProtoStore(D) + DeviceBatch(D): comptime device accumulation and the frozen
// SoA batch with the AD eval hot loop and cold Hooks vtable.
// ===========================================================================

pub fn ProtoStore(comptime D: type) type {
    // ponytail: the contract owns unknown counting; retain usize for tape offsets.
    const n_u: usize = comptime contract.nU(D);
    return struct {
        models: std.ArrayList(D.Model) = .empty,
        instances: std.ArrayList(D.Instance) = .empty,
        nodes: std.ArrayList([n_u]u32) = .empty,

        const Self = @This();

        pub fn addPattern(ctx: *anyopaque, gpa: std.mem.Allocator, pb: *PatternBuilder) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // The device's structural Jacobian, not n_u^2: an entry no device
            // can fill is still a matrix nonzero once it is reserved, and it
            // costs fill-in and float work in every factorization for the rest
            // of the run. ngspice reserves exactly its 22 MOS1 stamps; this is
            // how espice reserves 25 instead of 64.
            const pat = comptime jacPattern(D);
            const nnz = comptime blk: {
                var k: usize = 0;
                for (pat) |m| k += @popCount(m & (std.math.maxInt(u64) >> (63 - (n_u - 1))));
                break :blk k;
            };
            try pb.reserve(gpa, self.nodes.items.len * nnz);
            // Runtime loops: this runs ONCE per batch at setup, and unrolling
            // n_u^2 for 38 devices is a comptime-quota problem, not a speedup.
            for (self.nodes.items) |nd| {
                for (0..n_u) |ru| for (0..n_u) |cu| {
                    if ((pat[ru] >> @intCast(cu)) & 1 == 0) continue;
                    if (nd[ru] != GROUND and nd[cu] != GROUND)
                        try pb.add(gpa, nd[ru], nd[cu]);
                };
            }
        }

        pub fn finalize(ctx: *anyopaque, gpa: std.mem.Allocator, pv: PatternView) anyerror!Batch {
            const has_q = @hasDecl(D, "q");
            const const_g = @hasDecl(D, "constant") and D.constant.g;
            const const_c = @hasDecl(D, "constant") and D.constant.c;
            const has_attempt_decl = @hasDecl(D, "attempt");
            const self: *Self = @ptrCast(@alignCast(ctx));
            const count = self.models.items.len;
            const store = try gpa.create(DeviceBatch(D));

            store.count = count;
            store.models = &.{};
            store.instances = &.{};
            store.gath = &.{};
            store.rhs_idx = &.{};
            store.slots = &.{};
            if (comptime has_q) store.q_tape = &.{};
            if (comptime has_attempt_decl) store.saved_models = &.{};
            if (comptime @hasDecl(D, "limit")) store.lim_x = &.{};
            if (comptime @hasDecl(D, "State")) store.states = &.{};
            errdefer DeviceBatch(D).hooks.deinit(store, gpa);

            store.models = try self.models.toOwnedSlice(gpa);
            if (comptime has_attempt_decl) {
                store.saved_models = try gpa.alloc(D.Model, count);
                store.attempt_saved = false;
            }
            if (comptime @hasDecl(D, "limit")) {
                store.lim_x = try gpa.alloc(f64, count * n_u);
                store.lim_active = false;
            }
            store.instances = try self.instances.toOwnedSlice(gpa);

            store.gath = try gpa.alloc(u32, count * n_u);
            store.rhs_idx = try gpa.alloc(u32, count * n_u);
            store.slots = try gpa.alloc(u32, count * n_u * n_u);
            const flat_nodes = @as([*]const u32, @ptrCast(self.nodes.items.ptr))[0 .. count * n_u];
            buildTapes(flat_nodes, n_u, &jacPattern(D), pv, store.gath, store.rhs_idx, store.slots);
            // Fourth member of the tape family: same (id, ru) index space, one
            // f64 per charge contribution. See Hooks.q_tape.
            if (comptime has_q) {
                store.q_tape = try gpa.alloc(f64, count * n_u);
                @memset(store.q_tape, 0);
            }
            self.nodes.deinit(gpa);
            self.nodes = .empty;

            if (comptime @hasDecl(D, "State")) {
                store.states = try gpa.alloc(D.State, count);
                for (0..count) |i| store.states[i] = D.initState(&store.models[i], &store.instances[i]);
            }
            if (comptime @hasDecl(D, "precompute")) {
                for (0..count) |i| D.precompute(&store.instances[i], &store.models[i]);
            }

            return .{
                .ctx = store,
                .eval = DeviceBatch(D).eval,
                .eval_newton = DeviceBatch(D).evalNewton,
                .count = @intCast(count),
                .n_u = n_u,
                .has_charge = @hasDecl(D, "q"),
                .has_const_jacobian = const_g and (!has_q or const_c),
                .thread_safe = true,
                .type_name = @typeName(D),
                .hooks = &DeviceBatch(D).hooks,
            };
        }

        pub fn applyPerm(ctx: *anyopaque, perm: []const u32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.nodes.items) |*nd| {
                inline for (0..n_u) |u| {
                    if (nd[u] < perm.len) nd[u] = perm[nd[u]];
                }
            }
        }

        pub fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.models.deinit(gpa);
            self.instances.deinit(gpa);
            self.nodes.deinit(gpa);
            gpa.destroy(self);
        }
    };
}

/// Does this device carry §4.5 `absdelay` state — a ring buffer its
/// `updateState` pushes into and CANNOT take back?
///
/// Detected from the Instance field name because VerA's naming is a stable,
/// injective encoding (naming.zig: role-tagged `<module>__analog_op__absdelay__*`,
/// deliberately insert-tolerant so `zig -fincremental` can track it), so this
/// is reading a documented ABI rather than guessing.
///
/// ponytail: the honest home for this is a VerA decl — something like
/// `pub const unrevertible_state = true` beside `lane_clean`/`jac_f32` — so
/// the host asks a question instead of pattern-matching an answer. Upgrade
/// there; this predicate is the shim until then.
fn hasAbsdelayState(comptime D: type) bool {
    // Native engine devices say it outright (the upgrade path the comment
    // above names); VerA-generated ones are detected from the Instance field
    // naming ABI below, because the contract's allowed_pub_decls has no slot
    // for a host-only marker.
    if (@hasDecl(D, "unrevertible_state")) return D.unrevertible_state;
    if (!@hasDecl(D, "Instance")) return false;
    // hisim-class Instances carry hundreds of long field names; the substring
    // scan is comptime O(fields × name len) and blows the default 1000 quota.
    @setEvalBranchQuota(2_000_000);
    for (@typeInfo(D.Instance).@"struct".fields) |f| {
        if (std.mem.indexOf(u8, f.name, "__absdelay__") != null) return true;
    }
    return false;
}

pub fn DeviceBatch(comptime D: type) type {
    const n_u: usize = comptime contract.nU(D);
    const S = DualFor(n_u, jacFloat(D), @hasDecl(D, "collapse"));
    const has_state = @hasDecl(D, "State");
    const has_q = @hasDecl(D, "q");
    const has_attempt = @hasDecl(D, "attempt");
    const has_limit = @hasDecl(D, "limit");
    // A device that reads none of the host-owned fields gets a null hook, so
    // the analyses' per-timepoint sweep skips it entirely.
    const has_sim_state = @hasField(D.Instance, "abstime") or
        @hasField(D.Instance, "dt") or
        @hasField(D.Instance, "analysis_kind") or
        @hasField(D.Instance, "is_initial_step") or
        @hasField(D.Instance, "is_final_step");

    return struct {
        count: usize,
        models: []D.Model,
        saved_models: if (has_attempt) []D.Model else void,
        attempt_saved: if (has_attempt) bool else void,
        lim_x: if (has_limit) []f64 else void,
        lim_active: if (has_limit) bool else void,
        instances: []D.Instance,
        states: if (has_state) []D.State else void,
        gath: []u32,
        rhs_idx: []u32,
        slots: []u32,
        /// Per-device-state charge, indexed `id * n_u + ru` — the fourth
        /// member of the tape family above, written by `Sink.scatterQ` on the
        /// host path only. The transient keeps its LTE history over this
        /// instead of the summed q plane. See `Hooks.q_tape`.
        q_tape: if (has_q) []f64 else void,

        const Self = @This();

        pub const hooks: Hooks = .{
            .scatter_bounds = scatterBounds,
            .q_tape = if (has_q) qTape else null,
            .eval_q = if (has_q) evalQOnly else null,
            .apply_limits = if (has_limit) applyLimits else null,
            .clear_limits = if (has_limit) clearLimits else null,
            .seed = if (@hasDecl(D, "seed")) seedFn else null,
            .mark_current_rows = if (@hasDecl(D, "u_kinds")) markCurrentRows else null,
            // Split on `absdelay` state — the one thing a speculative update
            // cannot take back. Everything else keeps the per-iteration call:
            // `stateCtl` reverts it, or its `request_reject_at` is a
            // breakpoint that must be seen per attempt for a source edge to
            // land sharply. See `Hooks.commit_state`.
            .update_state = if (@hasDecl(D, "updateState") and !hasAbsdelayState(D)) updateState else null,
            .commit_state = if (@hasDecl(D, "updateState") and hasAbsdelayState(D)) updateState else null,
            .state_ctl = if (@hasDecl(D, "stateCtl")) stateCtl else null,
            // Only devices with an accepted-step FSM can write it.
            .bound_step = if (@hasDecl(D, "updateState") and @hasField(D.Instance, "bound_step")) boundStep else null,
            .set_temp = if (@hasField(D.Instance, "temperature")) setTemp else null,
            .set_sim_state = if (has_sim_state) setSimState else null,
            // Gated on the decl, not on the dead histInject channel: VerA now
            // emits `delays` for absdelay devices (model-frame, like
            // nextBreakpoint), which is what makes the transient's wavefront
            // echo machinery and its dt_max <= td clamp actually live.
            .min_delay = if (@hasDecl(D, "delays")) minDelay else null,
            .next_breakpoint = if (@hasDecl(D, "nextBreakpoint")) nextBreakpointFn else null,
            .collect_params = collectParams,
            .collect_noise = if (@hasDecl(D, "noise_gens")) collectNoise else null,
            .recompute = if (@hasDecl(D, "collapse") or @hasDecl(D, "precompute")) recomputePrecomputed else null,
            .gpu_payload = if (gpuEligible(D)) gpuPayload else null,
            .apply_attempt = if (has_attempt) applyAttempt else null,
            .restore_models = if (has_attempt) restoreAttempt else null,
            .deinit = destroy,
        };

        fn eval(ctx: *anyopaque, pl: *const Planes, first: u32, last: u32, x: []const f64, t: f64) void {
            evalInner(ctx, pl, first, last, x, t, false);
        }

        fn evalNewton(ctx: *anyopaque, pl: *const Planes, first: u32, last: u32, x: []const f64, t: f64) void {
            evalInner(ctx, pl, first, last, x, t, true);
        }

        fn evalQOnly(ctx: *anyopaque, pl: *const Planes, x: []const f64, t: f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var sink = Sink(D, false, false).host(self, pl, x, undefined);
            evalQRange(D, RealFor(@hasDecl(D, "collapse")), &sink, 0, @intCast(self.count), t);
        }

        fn scatterBounds(ctx: *anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return tapeBounds(self.slots[first * n_u * n_u .. last * n_u * n_u], self.rhs_idx[first * n_u .. last * n_u], trash_slot, trash_row);
        }

        fn qTape(ctx: *anyopaque) []const f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.q_tape;
        }

        fn evalInner(ctx: *anyopaque, pl: *const Planes, first: u32, last: u32, x: []const f64, t: f64, comptime skip_const: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const limiting = if (comptime has_limit) self.lim_active else false;
            var sink = Sink(D, false, skip_const).host(self, pl, x, undefined);
            evalRange(D, &sink, first, last, t, limiting);
        }

        fn localX(self: *Self, x: []const f64, id: usize) [n_u]f64 {
            var out: [n_u]f64 = undefined;
            inline for (0..n_u) |u| out[u] = x[self.gath[id * n_u + u]];
            return out;
        }

        fn seedFn(ctx: *anyopaque, x: []f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime has_limit) {
                for (0..self.count) |id| {
                    const sv = D.seed(&self.models[id], &self.instances[id]);
                    const xn = self.localX(x, id);
                    inline for (0..n_u) |u|
                        self.lim_x[id * n_u + u] = sv[u] orelse xn[u];
                }
                self.lim_active = true;
            }
        }

        fn markCurrentRows(ctx: *anyopaque, mask: []bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                inline for (0..n_u) |u| {
                    if (comptime D.u_kinds[u] != .voltage) {
                        const node = self.gath[id * n_u + u];
                        const voltage_alias = blk: {
                            inline for (0..n_u) |v| {
                                if (comptime D.u_kinds[v] == .voltage)
                                    if (self.gath[id * n_u + v] == node) break :blk true;
                            }
                            break :blk false;
                        };
                        if (node != GROUND and !voltage_alias) mask[node] = true;
                    }
                }
            }
        }

        fn applyLimits(ctx: *anyopaque, x: []f64, x_old: []const f64) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // limitRange never scatters to the planes; an empty Planes keeps the
            // sink's plane .ptr reads valid (undefined would trap in Debug).
            const no_planes: Planes = .{ .g_vals = &.{}, .c_vals = &.{}, .rhs = &.{}, .q_vec = &.{} };
            var sink = Sink(D, false, false).host(self, &no_planes, x, x_old.ptr);
            const any = limitRange(D, &sink, 0, @intCast(self.count), self.lim_active);
            self.lim_active = true;
            return any != 0;
        }

        fn clearLimits(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.lim_active = false;
        }

        /// Re-enters the device's model core at `R` (value-only) to restage the
        /// `ddt`/`idt` arguments at the accepted x. `converger.checkConverged`
        /// runs it once per CONVERGED solve, not per Newton iterate, so the
        /// denominator here is `attempts`, not `nr_iters`.
        ///
        /// WHY MOS6 COSTS 2.6x MOS1 PER INSTANCE. Not slot count and not the
        /// model card. Ablated (double this loop, idempotent, raw unchanged):
        /// mos1 ~200 Ir/instance/call on scaling/parallel_inverters_100 (22.3M
        /// over 613 attempts x 200) AND on devices/mos6_inverter re-carded to
        /// LEVEL 1 (5.56M over 323 x 80 = 215 Ir) — same circuit, same
        /// CJ/CJSW/CGSO/CGDO/TOX — against 556 Ir for LEVEL 6 on that same
        /// deck. Slots are 13 vs 9 (1.44x) and the cards are identical, so
        /// neither explains it.
        ///
        /// What does: the staged set is the Meyer capacitances, and mos6's
        /// Meyer partition needs the Sakurai-Newton saturation voltage. Its
        /// core carries `KV*(Vgs-Vth)^NV` and `KC*(Vgs-Vth)^NC` with NV/NC
        /// non-integer, so the DCE'd closure of the staged values contains TWO
        /// `std.math.pow` calls; mos1's `Vdsat = Vgs - Vth` is a subtract and
        /// its closure contains none. Standalone rig at this deck's parameters,
        /// 100k calls each: exactly 2 pow per mos6 call and 0 per mos1, 593 of
        /// mos6's 819 Ir. Generic `pow` is `exp(y*ln x)` + frexp/ldexp, ~300 Ir.
        /// The junction charges are NOT it — these decks give no AD/AS/PD/PS,
        /// so `czbd`/`czbs` are zero and those arms are already branch-dead.
        ///
        /// Nothing here can fix that: the two `pow`s are inside VerA's emitted
        /// core. The host-side lever would be to stage the `ddt` arguments from
        /// the eval pass that already computed them at the same x, which needs
        /// the generator to expose them.
        fn updateState(ctx: *anyopaque, x: []const f64) ?f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var min_reject: ?f64 = null;
            for (0..self.count) |id| {
                const lx = self.localX(x, id);
                switch (D.updateState(&self.models[id], &self.instances[id], lx, &self.states[id])) {
                    .ok => {},
                    .request_reject_at => |tr| {
                        min_reject = if (min_reject) |cur| @min(cur, tr) else tr;
                    },
                }
            }
            return min_reject;
        }

        /// Tightest `$bound_step` across this batch's instances. Read after an
        /// accepted step, so `updateState` has already refreshed every one.
        fn boundStep(ctx: *anyopaque) f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var b = std.math.inf(f64);
            for (self.instances[0..self.count]) |*inst| b = @min(b, inst.bound_step);
            return b;
        }

        fn stateCtl(ctx: *anyopaque, op: StateCtlOp) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var dirty = false;
            for (0..self.count) |id| {
                if (D.stateCtl(&self.models[id], &self.instances[id], &self.states[id], @enumFromInt(@intFromEnum(op)))) dirty = true;
            }
            return dirty;
        }

        /// §9.10 `$temperature` is KELVIN; the host speaks Celsius (the SPICE
        /// `.temp` card), hence the conversion. The field was probed as "temp"
        /// until now — a name no generated device has — so this hook was
        /// silently null and `.temp`/`temp_sweep` moved only the explicit
        /// TempCoeff parameters, never the device's own junction physics.
        fn setTemp(ctx: *anyopaque, temp_c: f32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.instances) |*inst| inst.temperature = @as(f64, temp_c) + 273.15;
            self.reprep();
        }

        /// Write the host-owned Instance block. Field-by-field `@hasField` so a
        /// device that reads only `$abstime` pays for exactly that store.
        /// No `reprep()`: FastVAF hoists nothing time-dependent into
        /// `precompute` — it is derived from Model/Instance parameters, which
        /// this does not touch — so there is no derived state to invalidate.
        fn setSimState(ctx: *anyopaque, st: SimState) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.instances) |*inst| {
                if (comptime @hasField(D.Instance, "abstime")) inst.abstime = st.t;
                if (comptime @hasField(D.Instance, "dt")) inst.dt = st.dt;
                // Devices declare their own AnalysisKind; ordinal-convert like
                // stateCtl does for StateCtlOp.
                if (comptime @hasField(D.Instance, "analysis_kind"))
                    inst.analysis_kind = @enumFromInt(@intFromEnum(st.kind));
                if (comptime @hasField(D.Instance, "is_initial_step")) inst.is_initial_step = st.initial_step;
                if (comptime @hasField(D.Instance, "is_final_step")) inst.is_final_step = st.final_step;
            }
        }

        fn applyAttempt(ctx: *anyopaque, lambda: f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (!self.attempt_saved) {
                @memcpy(self.saved_models, self.models);
                self.attempt_saved = true;
            }
            for (self.models, self.saved_models) |*m, s| m.* = D.attempt(s, lambda);
            self.reprep();
        }

        fn restoreAttempt(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (!self.attempt_saved) return;
            self.attempt_saved = false;
            @memcpy(self.models, self.saved_models);
            self.reprep();
        }

        /// Hand the launcher this batch's working set. Slices, not copies —
        /// the batch keeps owning them; the launcher only reads them to stage
        /// device memory (and re-reads `models`/`instances` on `repack`).
        fn gpuPayload(ctx: *anyopaque) GpuPayload {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{
                .kernel = comptime kernelName(D),
                .count = @intCast(self.count),
                .n_u = n_u,
                .models = std.mem.sliceAsBytes(self.models),
                .instances = std.mem.sliceAsBytes(self.instances),
                .gath = self.gath,
                .rhs_idx = self.rhs_idx,
                .slots = self.slots,
                .lim_kernel = comptime if (hasStateKernel(D)) stateKernelName(D) else "",
                .ctl_kernel = comptime if (hasCtlKernel(D)) ctlKernelName(D) else "",
                .reduce_kernel = comptime reduceKernelName(D),
                .lim_x = if (comptime has_limit) self.lim_x else &.{},
                .states = if (comptime has_state) std.mem.sliceAsBytes(self.states) else &.{},
                .lim_active = if (comptime has_limit) self.lim_active else false,
            };
        }

        fn recomputePrecomputed(ctx: *anyopaque) error{TopologyChanged}!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.reprep();
            if (comptime @hasDecl(D, "collapse")) {
                for (self.models, self.instances, 0..) |*model, *inst, id| {
                    const col = D.collapse(model, inst);
                    const nd = self.gath[id * n_u ..][0..n_u];
                    inline for (D.num_ports..n_u) |u| {
                        if (col[u]) |target| {
                            if (nd[u] != nd[target]) return error.TopologyChanged;
                        } else if (std.mem.indexOfScalar(u32, nd[0..u], nd[u]) != null) {
                            // Builder allocated a distinct node for every unaliased internal.
                            return error.TopologyChanged;
                        }
                    }
                }
            }
        }

        fn reprep(self: *Self) void {
            if (comptime @hasDecl(D, "precompute")) {
                for (self.instances, self.models) |*inst, *mdl| D.precompute(inst, mdl);
            }
        }

        fn minDelay(ctx: *anyopaque) f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var min_td = std.math.inf(f64);
            for (self.models) |*m| {
                for (D.delays(m)) |d| min_td = @min(min_td, d);
            }
            return min_td;
        }

        fn nextBreakpointFn(ctx: *anyopaque, t: f64) ?f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var best: f64 = std.math.inf(f64);
            for (self.models) |*m| {
                if (D.nextBreakpoint(m, t)) |bp| best = @min(best, bp);
            }
            return if (best == std.math.inf(f64)) null else best;
        }

        fn collectParams(ctx: *anyopaque, gpa: std.mem.Allocator, list: *std.ArrayList(ParamRef)) anyerror!void {
            @setEvalBranchQuota(100_000);
            const self: *Self = @ptrCast(@alignCast(ctx));
            try appendParams(D.Instance, self.instances, true, gpa, list);
            try appendParams(D.Model, self.models, false, gpa, list);
        }

        fn appendParams(comptime T: type, items: anytype, comptime is_instance: bool, gpa: std.mem.Allocator, list: *std.ArrayList(ParamRef)) anyerror!void {
            const type_name = comptime blk: {
                const full = @typeName(D);
                const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse break :blk full;
                break :blk full[dot + 1 ..];
            };
            comptime var field_idx: usize = 0;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime paramField(T, field)) {
                    const primary = comptime if (@hasDecl(D, "mc_param"))
                        std.mem.eql(u8, field.name, D.mc_param)
                    else if (@hasDecl(D, "AnalysisKind"))
                        !is_instance and field_idx == 0
                    else
                        is_instance and field_idx == 0;
                    for (items, 0..) |*it, idx| {
                        try list.append(gpa, .{
                            .ptr = if (field.type == f32)
                                .{ .f32 = &@field(it, field.name) }
                            else
                                .{ .f64 = &@field(it, field.name) },
                            .device_type = type_name,
                            .param_name = field.name,
                            .index = @intCast(idx),
                            .is_instance = is_instance,
                            .primary = primary,
                        });
                    }
                    field_idx += 1;
                }
            }
        }

        fn paramField(comptime T: type, comptime field: std.builtin.Type.StructField) bool {
            if (field.type != f32 and field.type != f64) return false;
            if (@hasDecl(D, "AnalysisKind") and T == D.Instance) {
                // VerA's emitModel owns VA parameters; Instance owns runtime
                // state. Never perturb timers, timestep fields or prep caches.
                const knobs = std.StaticStringMap(void).initComptime(.{
                    .{ "temperature", {} }, .{ "mfactor", {} },
                });
                if (!knobs.has(field.name)) return false;
            }
            const dflt = @field(T{}, field.name);
            return dflt > -1e30 and dflt < 1e30;
        }

        fn collectNoise(ctx: *anyopaque, x: []const f64, gpa: std.mem.Allocator, list: *std.ArrayList(NoiseSource)) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                var xd: [n_u]S = undefined;
                inline for (0..n_u) |u| xd[u] = S.seed(x[self.gath[id * n_u + u]], u);
                const out = D.eval(S, xd, &self.models[id], &self.instances[id], 0);
                inline for (D.noise_gens) |gen| {
                    switch (gen.kind) {
                        .thermal => {
                            const g = @abs(out[gen.row].ddxAt(gen.col));
                            if (g > 0) try list.append(gpa, .{
                                .node_p = self.gath[id * n_u + gen.row],
                                .node_n = self.gath[id * n_u + gen.col],
                                .conductance = g,
                            });
                        },
                        .shot, .flicker => {},
                    }
                }
            }
        }

        fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            gpa.free(self.models);
            if (comptime has_attempt) gpa.free(self.saved_models);
            if (comptime has_limit) gpa.free(self.lim_x);
            gpa.free(self.instances);
            if (comptime has_state) gpa.free(self.states);
            gpa.free(self.gath);
            gpa.free(self.rhs_idx);
            gpa.free(self.slots);
            if (comptime has_q) gpa.free(self.q_tape);
            gpa.destroy(self);
        }
    };
}

// ===========================================================================
// GPU path — the SAME evalRange body, driven by a gompute RawKernel with an
// atomic-scatter sink. One kernel per device type; builtins register at comptime
// (kernels.zig), a dynamic `.so` registers its one device from this same
// template. Buffers are flat SoA uploaded before launch (host mirrors of the
// batch tapes/planes). First cut targets simple devices (no state / history /
// limiting); richer devices stay CPU until their GPU state is added.
// ===========================================================================

/// Devices eligible for a GPU kernel. History still needs device-side state
/// not yet wired; those run CPU-only.
///
/// `limit` devices (the diode/FET/BJT class — the models that actually carry
/// eval work) run with a device-resident `lim_x` plane maintained by
/// `StateKernel`, which fuses the `applyLimits` clamp pass and the
/// `updateState` latch refresh into one per-instance launch.
///
/// `State` is admitted ONLY alongside `limit`. For that class, State is the
/// path-latch pattern: `updateState` stages `inst.wb__/wq__`, `stateCtl`
/// commits them into the `pb__/pq__` latches eval reads (CtlKernel runs that
/// on the device), and `updateState` returns `.ok` unconditionally. A
/// State-WITHOUT-limit device is a waveform source or FSM (vsource,
/// isource, vswitch, mes) whose eval reads host-owned per-attempt state the
/// device copy would never see.
///
/// `core_reads_simstate` is the VerA-emitted decl for a core that reads a
/// host-published sim-state Instance field (analysis()/$abstime/ddt-family
/// dt). The host republishes those on the HOST blob only, so such a core
/// (jfet2's analysis() gate today) evals stale device-resident — excluded.
/// ponytail: for the rest it is decl-correlation, not proof — StateKernel
/// still flags a non-.ok updateState result so a future model that breaks
/// the assumption degrades loudly into the CPU fallback.
pub fn gpuEligible(comptime D: type) bool {
    return !@hasDecl(D, "histInject") and
        !@hasDecl(D, "core_reads_simstate") and
        (@hasDecl(D, "limit") or !@hasDecl(D, "State"));
}

/// Does device D pair its eval kernel with a `StateKernel`?
pub fn hasStateKernel(comptime D: type) bool {
    return gpuEligible(D) and (@hasDecl(D, "limit") or @hasDecl(D, "State"));
}

/// Does device D also need a `CtlKernel`? Accepted-step latches (stateCtl's
/// commit/revert) mutate the device-resident Instance/State blobs, so the
/// host walk cannot stand in for it once the batch is resident.
pub fn hasCtlKernel(comptime D: type) bool {
    return hasStateKernel(D) and @hasDecl(D, "stateCtl");
}

/// The kernel symbol for device D — `arp_eval_<model>`.
///
/// Derived from the TYPE, and called by both sides: `kernels.zig` to export the
/// symbol into the GPU image, and `gpuPayload` below to name the symbol the
/// launcher looks up. One function so the two cannot drift into a green build
/// that fails with `error.KernelNotFound` on a machine with a GPU.
pub fn kernelName(comptime D: type) [:0]const u8 {
    const full = @typeName(D);
    const base = if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| full[dot + 1 ..] else full;
    return "arp_eval_" ++ base;
}

/// The limit/state kernel symbol for device D — `arp_lim_<model>`. Same
/// derive-from-the-type rule (and reason) as `kernelName`.
pub fn stateKernelName(comptime D: type) [:0]const u8 {
    const full = @typeName(D);
    const base = if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| full[dot + 1 ..] else full;
    return "arp_lim_" ++ base;
}

/// The accepted-step latch kernel symbol — `arp_ctl_<model>`.
pub fn ctlKernelName(comptime D: type) [:0]const u8 {
    const full = @typeName(D);
    const base = if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| full[dot + 1 ..] else full;
    return "arp_ctl_" ++ base;
}

/// The segmented-reduction symbol — `arp_reduce_<model>`.
///
/// The BODY is device-independent (see `ReduceKernel`), but the symbol is keyed
/// on D anyway: `kernels.zig` compiles one root per device and gompute requires
/// kernel names to be unique across roots, so a single shared `arp_reduce` would
/// collide once per catalog entry. The launcher uses whichever resident batch's
/// copy it finds first — they are the same code.
pub fn reduceKernelName(comptime D: type) [:0]const u8 {
    const full = @typeName(D);
    const base = if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| full[dot + 1 ..] else full;
    return "arp_reduce_" ++ base;
}

/// One batch's device-resident working set, type-erased.
///
/// Everything here is written by the builder and then FROZEN for the life of
/// the solve, which is what lets the launcher upload it once and leave it on
/// the GPU: the tapes are pattern, and `models`/`instances` only change when a
/// sweep mutates a parameter (see the `repack` hook). Per Newton iteration the
/// launcher moves `x` in and the value planes out, and nothing else.
pub const GpuPayload = struct {
    /// `arp_eval_<model>`, from `kernelName`.
    kernel: []const u8,
    /// Instances in this batch — one GPU thread each.
    count: u32,
    /// Unknowns per instance. Fixes the tape strides below.
    n_u: u32,
    /// `[]D.Model` / `[]D.Instance` as bytes. POD by contract (§5 rule 3), so a
    /// byte copy is the whole upload.
    models: []const u8,
    instances: []const u8,
    /// count * n_u — global row each local unknown gathers x from.
    gath: []const u32,
    /// count * n_u — residual row each local unknown scatters to.
    rhs_idx: []const u32,
    /// count * n_u * n_u — CSC slot each Jacobian entry scatters to.
    slots: []const u32,
    /// `arp_lim_<model>` when the device pairs a `StateKernel` with its eval
    /// kernel (`hasStateKernel`), else "".
    lim_kernel: []const u8,
    /// `arp_ctl_<model>` when the device latches accepted-step state
    /// (`hasCtlKernel`), else "".
    ctl_kernel: []const u8,
    /// `arp_reduce_<model>` — the segmented sum that turns this pass's staging
    /// cells back into plane values. Device-independent body; see
    /// `reduceKernelName` for why it carries a per-device symbol anyway.
    reduce_kernel: []const u8,
    /// Host lim plane (count * n_u), for the seed-era upload; empty when the
    /// device has no `limit`. Once the device StateKernel runs, the resident
    /// copy is authoritative and this is stale by design.
    lim_x: []const f64,
    /// `[]D.State` as bytes (POD), uploaded once; empty when no `State`.
    states: []const u8,
    /// Host-side lim_active at call time — only consulted until the device
    /// takes the lim plane over (seed → first eval).
    lim_active: bool,
};

/// The ONE sink `evalRange`/`limitRange` consume. `device` picks the two axes
/// that differ between CPU and GPU and NOTHING else — the gather/index/eval body
/// is identical:
///   - memory access: host reads plain slices (GlobalPtr(T) == [*]T), device
///     casts the `.global` kernel params to generic addrspace (one cvta.global
///     on NVPTX) so the contract's generic-addrspace `eval` can read them.
///   - scatter: host `p[i] +=`; device `@atomicRmw(.Add)` (many threads stamp
///     one matrix slot; the atomic lowers to a global-space reduction).
/// The ABI-table fields are GlobalPtr both ways — one type, one body, two
/// backends. Host-only state hangs off `b: *DeviceBatch(D)` and is `void`
/// under `device`, so a device compilation never sees it.
pub fn Sink(comptime D: type, comptime device: bool, comptime skip_const: bool) type {
    const n_u: usize = comptime contract.nU(D);
    const const_g = @hasDecl(D, "constant") and D.constant.g;
    const const_c = @hasDecl(D, "constant") and D.constant.c;
    const BatchT = DeviceBatch(D);
    return struct {
        xs: gompute.GlobalPtr(f64),
        gath_: gompute.GlobalPtr(u32),
        rhs_idx_: gompute.GlobalPtr(u32),
        slots_: gompute.GlobalPtr(u32),
        models_: gompute.GlobalPtr(D.Model),
        instances_: gompute.GlobalPtr(D.Instance),
        g_vals: gompute.GlobalPtr(f64),
        c_vals: gompute.GlobalPtr(f64),
        rhs: gompute.GlobalPtr(f64),
        q_vec: gompute.GlobalPtr(f64),

        /// The lim plane (count * n_u) and x_old — device-resident buffers on
        /// the GPU, the batch's own `lim_x` / the caller's x_old on the host.
        /// One pointer type both ways so `evalRange`/`limitRange` compile for
        /// either sink; `undefined` when the device has no `limit` (never
        /// dereferenced — every access is behind `has_limit`).
        lim_: gompute.GlobalPtr(f64),
        xo: gompute.GlobalPtr(f64), // x_old (limit pass only)

        /// The owning batch, for the host-side tables that have no device
        /// mirror — today just `q_tape`, which `scatterQ` writes per
        /// (id, ru) and the transient's LTE reads. `void` under `device`, so
        /// a GPU compilation never names a host slice.
        b: if (device) void else *BatchT,

        pub const skip_g = skip_const and const_g;
        pub const skip_c = skip_const and const_c;
        /// Is this the atomic-scatter (GPU) sink? `evalRange` reads it to keep
        /// the ground predicates there and drop them on the host.
        pub const on_device = device;

        const Sk = @This();

        pub inline fn x(s: *const Sk, gi: u32) f64 {
            return s.xs[gi];
        }
        pub inline fn xOld(s: *const Sk, gi: u32) f64 {
            return s.xo[gi];
        }
        pub inline fn gath(s: *const Sk, id: u32, u: usize) u32 {
            return s.gath_[@as(usize, id) * n_u + u];
        }
        pub inline fn rhsRow(s: *const Sk, id: u32, ru: usize) u32 {
            return s.rhs_idx_[@as(usize, id) * n_u + ru];
        }
        pub inline fn lim(s: *const Sk, id: u32, u: usize) f64 {
            return s.lim_[@as(usize, id) * n_u + u];
        }
        pub inline fn setLim(s: *const Sk, id: u32, u: usize, v: f64) void {
            s.lim_[@as(usize, id) * n_u + u] = v;
        }
        // The contract's eval takes generic-addrspace pointers; on device the
        // `.global` param is cast here rather than copying the whole
        // Model/Instance per thread (a compact model's Model is hundreds of
        // params wide and would blow the register budget). On host the cast is
        // a no-op.
        pub inline fn model(s: *const Sk, id: u32) *const D.Model {
            return @addrSpaceCast(&s.models_[id]);
        }
        pub inline fn inst(s: *const Sk, id: u32) *const D.Instance {
            return @addrSpaceCast(&s.instances_[id]);
        }
        inline fn slot(s: *const Sk, id: u32, ru: usize, cu: usize) u32 {
            return s.slots_[(@as(usize, id) * n_u + ru) * n_u + cu];
        }
        /// PLAIN, NON-ATOMIC, on the device too — and that is a contract with
        /// the launcher, not a shortcut. On the device the tape does not index
        /// the plane, it indexes a per-contribution STAGING cell that exactly
        /// one thread ever touches; `gpu_context` builds that permutation and
        /// then sums each plane cell's run of staging cells in tape order.
        ///
        /// An `@atomicRmw(.Add)` here would hand the summation order back to the
        /// hardware, which does not promise to repeat it. That was the defect:
        /// on `parallel_inverters_2000` the Vdd row takes 8000 contributions of
        /// ±1.8 that cancel to 3.6e-9, so two replays of the SAME pass differed
        /// by 2.1e-10 — reordering, not a race (a lost update would move the sum
        /// by 1.8) — but the LU maps that row 1:1 onto the Vdd BRANCH CURRENT
        /// and Newton's delta gate there is 1.25e-12. Every iterate rejected.
        /// `GpuContext.reduce` carries the measurement.
        ///
        /// Still `+=` and not `=`: the staging is zeroed per pass, so this is
        /// `0 + v`, which is what keeps signed zero and NaN quieting identical
        /// to the host stamp (tests/devices.zig pins that).
        inline fn add(p: gompute.GlobalPtr(f64), i: u32, v: f64) void {
            p[i] += v;
        }
        pub inline fn scatterRes(s: *const Sk, row: u32, val: f64) void {
            add(s.rhs, row, val);
        }
        pub inline fn scatterJac(s: *const Sk, id: u32, ru: usize, cu: usize, val: f64) void {
            add(s.g_vals, s.slot(id, ru, cu), val);
        }
        /// Scatter one charge contribution. Two destinations, one value: the
        /// summed q plane (what the companion residual integrates) and — on the
        /// host only — the per-device-state tape (what CKTterr must run over).
        /// `id`/`ru` mirror `scatterQJac`'s signature; on a device build the
        /// tape write is comptime-dead and the extra params vanish, so
        /// `DeviceKernel.run`'s ABI is untouched.
        pub inline fn scatterQ(s: *const Sk, id: u32, ru: usize, row: u32, qv: f64) void {
            add(s.q_vec, row, qv);
            if (comptime !device and @hasDecl(D, "q"))
                s.b.q_tape[@as(usize, id) * n_u + ru] = qv;
        }
        pub inline fn scatterQJac(s: *const Sk, id: u32, ru: usize, cu: usize, val: f64) void {
            add(s.c_vals, s.slot(id, ru, cu), val);
        }

        // Host constructor: flatten the batch's slices to the GlobalPtr fields
        // (GlobalPtr(T) == [*]T here) so the shared body indexes them the same
        // way the device does. `has_limit` guards `xo`/lim state, unused off the
        // limit pass.
        pub fn host(b: *BatchT, pl: *const Planes, xs: []const f64, xo: [*]const f64) Sk {
            return .{
                .xs = @constCast(xs.ptr), // read-only here; GlobalPtr carries no const
                .gath_ = b.gath.ptr,
                .rhs_idx_ = b.rhs_idx.ptr,
                .slots_ = b.slots.ptr,
                .models_ = b.models.ptr,
                .instances_ = b.instances.ptr,
                .g_vals = pl.g_vals.ptr,
                .c_vals = pl.c_vals.ptr,
                .rhs = pl.rhs.ptr,
                .q_vec = pl.q_vec.ptr,
                .lim_ = if (comptime @hasDecl(D, "limit")) b.lim_x.ptr else undefined,
                .xo = @constCast(xo),
                .b = b,
            };
        }
    };
}

/// One-thread-per-instance GPU kernel for device D — the gompute RawKernel entry.
/// Body is the SHARED `evalRange`; only the sink differs from the CPU path.
/// `exportRaw`'d by kernels.zig (builtins) or the `.so` shim (dynamics), so it
/// is analyzed only in device compilation (globalIdX is device-only).
pub fn DeviceKernel(comptime D: type, comptime block_size: u32) type {
    return struct {
        pub fn run(
            count: u64,
            t: f64,
            xs: gompute.GlobalPtr(f64),
            gath: gompute.GlobalPtr(u32),
            rhs_idx: gompute.GlobalPtr(u32),
            slots: gompute.GlobalPtr(u32),
            models: gompute.GlobalPtr(D.Model),
            instances: gompute.GlobalPtr(D.Instance),
            g_vals: gompute.GlobalPtr(f64),
            c_vals: gompute.GlobalPtr(f64),
            rhs: gompute.GlobalPtr(f64),
            q_vec: gompute.GlobalPtr(f64),
            lim: gompute.GlobalPtr(f64),
            limiting: u64,
        ) callconv(gompute.kernel_callconv) void {
            const tid = gompute.globalIdX(block_size);
            if (tid >= count) return;
            var sink = Sink(D, true, false){
                .xs = xs,
                .gath_ = gath,
                .rhs_idx_ = rhs_idx,
                .slots_ = slots,
                .models_ = models,
                .instances_ = instances,
                .g_vals = g_vals,
                .c_vals = c_vals,
                .rhs = rhs,
                .q_vec = q_vec,
                .lim_ = lim,
                .xo = undefined, // limit pass only; never read in evalRange
                .b = {},
            };
            const id: u32 = @intCast(tid);
            evalRange(D, &sink, id, id + 1, t, limiting != 0);
        }
    };
}

/// Per-instance limit + state-latch kernel — the device half of
/// `Circuit.applyLimits`/`Circuit.updateStates` for a resident batch, fused
/// into one launch (the converger always calls the two back-to-back at the
/// same x, `finalizeStep`).
///
/// Bit 0 of `flags[0]`: some instance's clamp said "not converged" (pnjlim) —
/// the host's `limited` answer. Bit 1: some `updateState` returned a
/// non-`.ok` result the GPU path cannot honour (a `request_reject_at` time);
/// the launcher treats that as a fault and falls back to the CPU, so the
/// class assumption in `gpuEligible` degrades loudly, not silently.
pub fn StateKernel(comptime D: type, comptime block_size: u32) type {
    const n_u: usize = comptime contract.nU(D);
    const has_limit = @hasDecl(D, "limit");
    const has_state = @hasDecl(D, "State");
    const StateT = if (has_state) D.State else u8;
    return struct {
        pub fn run(
            count: u64,
            xs: gompute.GlobalPtr(f64),
            x_old: gompute.GlobalPtr(f64),
            gath: gompute.GlobalPtr(u32),
            models: gompute.GlobalPtr(D.Model),
            instances: gompute.GlobalPtr(D.Instance),
            lim: gompute.GlobalPtr(f64),
            states: gompute.GlobalPtr(StateT),
            lim_active: u64,
            flags: gompute.GlobalPtr(u32),
        ) callconv(gompute.kernel_callconv) void {
            const tid = gompute.globalIdX(block_size);
            if (tid >= count) return;
            const id: usize = @intCast(tid);
            const model: *const D.Model = @addrSpaceCast(&models[id]);
            var flag: u32 = 0;
            // Raw local x: `limit` clamps it, `updateState` latches at it.
            var cur: [n_u]f64 = undefined;
            inline for (0..n_u) |u| cur[u] = xs[gath[id * n_u + u]];
            if (comptime has_limit) {
                const inst_c: *const D.Instance = @addrSpaceCast(&instances[id]);
                var old: [n_u]f64 = undefined;
                inline for (0..n_u) |u|
                    old[u] = if (lim_active != 0) lim[id * n_u + u] else x_old[gath[id * n_u + u]];
                const lm = D.limit(model, inst_c, cur, old);
                if (!lm.converged) flag |= 1;
                inline for (0..n_u) |u| lim[id * n_u + u] = lm.x[u];
            }
            if (comptime has_state) {
                const inst_m: *D.Instance = @addrSpaceCast(&instances[id]);
                const st: *StateT = @addrSpaceCast(&states[id]);
                switch (D.updateState(model, inst_m, cur, st)) {
                    .ok => {},
                    else => flag |= 2,
                }
            }
            if (flag != 0) _ = @atomicRmw(u32, &flags[0], .Or, flag, .monotonic);
        }
    };
}

/// Segmented sum: one plane cell per thread, `plane[i] = sum(stage[seg[i]..seg[i+1]])`.
///
/// This is the second half of the deterministic scatter. `Sink.add` on the
/// device writes each contribution to its OWN staging cell, and gpu_context
/// ordered those cells so that a plane cell's contributors sit contiguously and
/// in tape order — so this loop reduces them in the SAME order the serial CPU
/// stamp accumulates them, every launch, forever. (Exactly, for a segment the
/// launcher did not have to cut; see `Order.chunk`.) Left-to-right and strict
/// on purpose: no `@setFloatMode(.optimized)` here, because `reassoc` is
/// exactly the freedom being taken away.
///
/// The plane is WRITTEN, not accumulated, so the launcher no longer clears it.
///
/// ONE accumulator, not several. Interleaved chains would be deterministic too,
/// but not in the order that matters: the tape emits a device's rows in `ru`
/// order, so an `l`-lane interleave hands lane `l` every instance's row `l` —
/// on `parallel_inverters_2000` that is one lane taking every +1.8 and another
/// taking every -1.8, and the partial sums grow to `chunk/n_u * 1.8` instead of
/// staying at 1.8. Measured on that row's 8000 contributions: tape order errs
/// 1.6e-17 against the exactly-rounded sum, an order that separates the
/// cancelling pair by W errs 4.0e-12 (W=32) to 1.6e-11 (W=1024). The whole
/// point of this kernel is not to do that.
///
/// The launcher keeps the chain short instead (two levels, this kernel twice),
/// so no thread walks more than `Order.chunk` before the f64 latency is hidden
/// by other threads. Measured on this card, lanes 4 -> 1 is free:
/// parallel_inverters_2000 --gpu 0.78/0.80/0.92 s -> 0.78/0.79/0.80 s,
/// parallel_inverters_500 0.55/0.57/0.58 s -> 0.55/0.56/0.57 s.
pub fn ReduceKernel(comptime _: type, comptime block_size: u32) type {
    return struct {
        pub fn run(
            n_cells: u64,
            seg: gompute.GlobalPtr(u32),
            stage: gompute.GlobalPtr(f64),
            plane: gompute.GlobalPtr(f64),
        ) callconv(gompute.kernel_callconv) void {
            const tid = gompute.globalIdX(block_size);
            if (tid >= n_cells) return;
            const i: u32 = @intCast(tid);
            var sum: f64 = 0;
            var k = seg[i];
            const end = seg[i + 1];
            while (k < end) : (k += 1) sum += stage[k];
            plane[i] = sum;
        }
    };
}

/// Accepted-step latch kernel — the device half of `Circuit.stateCtl` for a
/// resident batch. For the admitted class this is the path-integration
/// protocol: `commit` folds the staged `wb__/wq__` into the `pb__/pq__`
/// latches eval reads, `revert` is a no-op, `query` answers false. All three
/// ops route here anyway (no class assumption): the kernel ORs the real
/// stateCtl verdict into `flags[0]`, so a future device with a live query
/// answers honestly instead of by decree.
pub fn CtlKernel(comptime D: type, comptime block_size: u32) type {
    const StateT = if (@hasDecl(D, "State")) D.State else u8;
    return struct {
        pub fn run(
            count: u64,
            models: gompute.GlobalPtr(D.Model),
            instances: gompute.GlobalPtr(D.Instance),
            states: gompute.GlobalPtr(StateT),
            op: u64,
            flags: gompute.GlobalPtr(u32),
        ) callconv(gompute.kernel_callconv) void {
            const tid = gompute.globalIdX(block_size);
            if (tid >= count) return;
            const id: usize = @intCast(tid);
            const model: *const D.Model = @addrSpaceCast(&models[id]);
            const inst: *D.Instance = @addrSpaceCast(&instances[id]);
            const st: *StateT = @addrSpaceCast(&states[id]);
            const sop: StateCtlOp = @enumFromInt(@as(u8, @truncate(op)));
            if (D.stateCtl(model, inst, st, sop))
                _ = @atomicRmw(u32, &flags[0], .Or, 1, .monotonic);
        }
    };
}

// ===========================================================================
// ParEval — persistent-worker CPU threading. Lane 0 stamps into the caller's
// planes; lanes 1.. stamp private slabs, SIMD-reduced in fixed order (bit-
// identical run-to-run at a given n_lanes). Zero-alloc, no-mutex hot path.
//
// NOT bit-identical to the serial path, and that is a bounded reassociation,
// not the GPU's unbounded one. `reduce` walks lanes 1..n in a fixed order, so
// a cell's sum is `((S0 + S1) + S2) + ...` over CONSECUTIVE segments of the
// serial sequence — `init` cuts the lane ranges at INSTANCE boundaries and
// hands them out in ascending order, so no instance's contributions ever
// straddle a lane. That is the property that matters: the cancelling pair that
// makes a high-fan-in cell ill-conditioned (see `GpuContext.reduce`) stays
// inside one lane, every lane partial is as well-conditioned as tape order,
// and the fold adds n_lanes already-cancelled values. Measured serial vs
// n_lanes in {2,4,8,16}, same point count everywhere: parallel_inverters_500
// and _2000 max 1.1e-16..1.9e-16, resistor_grid_100x100 4.4e-16, rc_ladder_10k
// bit-identical. One ulp, against a benchmark tolerance of 1e-2.
//
// ponytail: bit-identity would need a per-contribution staging tape on the host
// and a segmented reduction over it — ~8x the plane footprint at mos1 geometry
// and the same memory traffic twice, to move 1 ulp. Build it only if a deck
// ever shows a threading-dependent trajectory (a point-count change is the
// tell); the GPU's `Order` is the design to copy.
// ===========================================================================

pub const EvalTask = struct {
    batch: u32,
    first: u32,
    last: u32,
};

const Window = struct {
    slot_lo: u32,
    slot_hi: u32, // exclusive
    row_lo: u32,
    row_hi: u32, // exclusive
};

pub const default_min_instances: u32 = 1024;

const Mode = enum(u8) { full, newton };

pub const ParEval = struct {
    gpa: std.mem.Allocator,
    n_lanes: u32,

    g_slab: []f64,
    c_slab: []f64,
    rhs_slab: []f64,
    q_slab: []f64,

    tasks: []EvalTask,
    task_off: []u32,
    windows: []Window,

    nnz1: usize,
    n1: usize,
    has_charge: bool,

    threads: []std.Thread,
    started: bool,
    quit: std.atomic.Value(bool),
    epoch: std.atomic.Value(u32),
    done: std.atomic.Value(u32),
    job_batches: []const Batch,
    job_own_planes: Planes,
    job_has_charge: bool,
    job_x: []const f64,
    job_t: f64,
    job_mode: Mode,

    pub fn init(
        gpa: std.mem.Allocator,
        _: std.Io,
        batches: []const Batch,
        nnz: u32,
        n: u32,
        has_charge: bool,
        trash_slot: u32,
        n_lanes_req: u32,
    ) !ParEval {
        const n_lanes = @max(n_lanes_req, 1);
        const nnz1: usize = nnz + 1;
        const n1: usize = n + 1;
        const extra: usize = n_lanes - 1;

        var w_total: u64 = 0;
        for (batches) |b| w_total += @as(u64, b.count) * b.n_u * b.n_u;
        const target: u64 = (w_total + n_lanes - 1) / n_lanes;

        var lane_tasks = try gpa.alloc(std.ArrayList(EvalTask), n_lanes);
        defer {
            for (lane_tasks) |*lt| lt.deinit(gpa);
            gpa.free(lane_tasks);
        }
        for (lane_tasks) |*lt| lt.* = .empty;
        var loads = try gpa.alloc(u64, n_lanes);
        defer gpa.free(loads);
        @memset(loads, 0);

        for (batches, 0..) |b, bi| {
            if (b.thread_safe or b.count == 0) continue;
            try lane_tasks[0].append(gpa, .{ .batch = @intCast(bi), .first = 0, .last = b.count });
            loads[0] += @as(u64, b.count) * b.n_u * b.n_u;
        }
        var cur: u32 = 0;
        for (batches, 0..) |b, bi| {
            if (!b.thread_safe or b.count == 0) continue;
            const w: u64 = @as(u64, b.n_u) * b.n_u;
            var pos: u32 = 0;
            while (pos < b.count) {
                while (cur + 1 < n_lanes and loads[cur] >= target) cur += 1;
                const cap = if (loads[cur] >= target) b.count - pos else blk: {
                    const room = target - loads[cur];
                    break :blk @as(u32, @intCast(@min(@as(u64, b.count - pos), (room + w - 1) / w)));
                };
                const take = @max(cap, 1);
                try lane_tasks[cur].append(gpa, .{ .batch = @intCast(bi), .first = pos, .last = pos + take });
                loads[cur] += @as(u64, take) * w;
                pos += take;
            }
        }

        var tasks: std.ArrayList(EvalTask) = .empty;
        errdefer tasks.deinit(gpa);
        const task_off = try gpa.alloc(u32, n_lanes + 1);
        errdefer gpa.free(task_off);
        var off: u32 = 0;
        for (lane_tasks, 0..) |lt, l| {
            task_off[l] = off;
            try tasks.appendSlice(gpa, lt.items);
            off += @intCast(lt.items.len);
        }
        task_off[n_lanes] = off;

        const windows = try gpa.alloc(Window, extra);
        errdefer gpa.free(windows);
        for (windows, 1..) |*win, l| {
            win.* = .{ .slot_lo = @intCast(nnz1 - 1), .slot_hi = 0, .row_lo = @intCast(n1 - 1), .row_hi = 0 };
            for (tasks.items[task_off[l]..task_off[l + 1]]) |task| {
                const b = &batches[task.batch];
                const bounds = b.hooks.scatter_bounds(b.ctx, task.first, task.last, trash_slot, n);
                win.slot_lo = @min(win.slot_lo, bounds[0]);
                win.slot_hi = @max(win.slot_hi, bounds[1]);
                win.row_lo = @min(win.row_lo, bounds[2]);
                win.row_hi = @max(win.row_hi, bounds[3]);
            }
            if (win.slot_lo > win.slot_hi) win.slot_lo = win.slot_hi;
            if (win.row_lo > win.row_hi) win.row_lo = win.row_hi;
        }

        const g_slab = try gpa.alloc(f64, extra * nnz1);
        errdefer gpa.free(g_slab);
        const rhs_slab = try gpa.alloc(f64, extra * n1);
        errdefer gpa.free(rhs_slab);
        const c_slab = try gpa.alloc(f64, if (has_charge) extra * nnz1 else 0);
        errdefer gpa.free(c_slab);
        const q_slab = try gpa.alloc(f64, if (has_charge) extra * n1 else 0);
        errdefer gpa.free(q_slab);
        @memset(g_slab, 0);
        @memset(rhs_slab, 0);
        @memset(c_slab, 0);
        @memset(q_slab, 0);

        const threads = try gpa.alloc(std.Thread, extra);
        errdefer gpa.free(threads);

        return .{
            .gpa = gpa,
            .n_lanes = n_lanes,
            .g_slab = g_slab,
            .c_slab = c_slab,
            .rhs_slab = rhs_slab,
            .q_slab = q_slab,
            .tasks = try tasks.toOwnedSlice(gpa),
            .task_off = task_off,
            .windows = windows,
            .nnz1 = nnz1,
            .n1 = n1,
            .has_charge = has_charge,
            .threads = threads,
            .started = false,
            .quit = .init(false),
            .epoch = .init(0),
            .done = .init(0),
            .job_batches = batches,
            .job_own_planes = undefined,
            .job_has_charge = has_charge,
            .job_x = &.{},
            .job_t = 0,
            .job_mode = .full,
        };
    }

    pub fn deinit(self: *ParEval) void {
        if (self.started) {
            self.quit.store(true, .release);
            _ = self.epoch.fetchAdd(1, .release);
            for (self.threads) |th| th.join();
        }
        const gpa = self.gpa;
        gpa.free(self.threads);
        gpa.free(self.g_slab);
        gpa.free(self.c_slab);
        gpa.free(self.rhs_slab);
        gpa.free(self.q_slab);
        gpa.free(self.tasks);
        gpa.free(self.task_off);
        gpa.free(self.windows);
        self.* = undefined;
    }

    pub fn eval(self: *ParEval, batches: []const Batch, own_planes: Planes, has_charge: bool, x: []const f64, t: f64) void {
        @memset(own_planes.g_vals, 0);
        if (has_charge) {
            @memset(own_planes.c_vals, 0);
            @memset(own_planes.q_vec, 0);
        }
        @memset(own_planes.rhs, 0);
        self.forkJoin(batches, own_planes, has_charge, x, t, .full);
    }

    pub fn evalNewton(
        self: *ParEval,
        batches: []const Batch,
        own_planes: Planes,
        has_charge: bool,
        has_baseline: bool,
        g_base: []const f64,
        c_base: []const f64,
        x: []const f64,
        t: f64,
    ) void {
        if (has_baseline) {
            @memcpy(own_planes.g_vals, g_base);
            if (has_charge) {
                @memcpy(own_planes.c_vals, c_base);
                @memset(own_planes.q_vec, 0);
            }
            @memset(own_planes.rhs, 0);
            self.forkJoin(batches, own_planes, has_charge, x, t, .newton);
        } else {
            // ponytail: full eval already owns plane clearing and worker dispatch.
            self.eval(batches, own_planes, has_charge, x, t);
        }
    }

    fn forkJoin(self: *ParEval, batches: []const Batch, own_planes: Planes, has_charge: bool, x: []const f64, t: f64, mode: Mode) void {
        if (self.n_lanes == 1) {
            runLane(self, batches, own_planes, has_charge, 0, x, t, mode);
            return;
        }
        if (!self.started) self.startWorkers();
        self.job_batches = batches;
        self.job_own_planes = own_planes;
        self.job_has_charge = has_charge;
        self.job_x = x;
        self.job_t = t;
        self.job_mode = mode;
        self.done.store(0, .monotonic);
        _ = self.epoch.fetchAdd(1, .release);
        runLane(self, batches, own_planes, has_charge, 0, x, t, mode);
        var spins: u32 = 0;
        while (self.done.load(.acquire) < self.n_lanes - 1) {
            // Same `pause` the loader's SpinLock uses. A busy waiter should not
            // hold issue slots its SMT sibling needs to FINISH the job we are
            // waiting on. Acquire/release and the 4096-spin yield are unchanged.
            std.atomic.spinLoopHint();
            spins +%= 1;
            if (spins > 4096) std.Thread.yield() catch {};
        }
        self.reduce(own_planes, has_charge);
    }

    fn startWorkers(self: *ParEval) void {
        const epoch0 = self.epoch.load(.acquire);
        for (self.threads, 1..) |*th, lane| {
            th.* = std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, workerMain, .{ self, @as(u32, @intCast(lane)), epoch0 }) catch
                @panic("ParEval: worker spawn failed");
        }
        self.started = true;
    }

    fn workerMain(self: *ParEval, lane: u32, epoch0: u32) void {
        var last: u32 = epoch0;
        while (true) {
            var spins: u32 = 0;
            var e = self.epoch.load(.acquire);
            while (e == last) {
                std.atomic.spinLoopHint();
                spins +%= 1;
                if (spins > 4096) std.Thread.yield() catch {};
                e = self.epoch.load(.acquire);
            }
            last = e;
            if (self.quit.load(.acquire)) return;
            runLane(self, self.job_batches, self.job_own_planes, self.job_has_charge, lane, self.job_x, self.job_t, self.job_mode);
            _ = self.done.fetchAdd(1, .release);
        }
    }

    fn lanePlanes(self: *ParEval, own_planes: Planes, lane: u32) Planes {
        if (lane == 0) return own_planes;
        const e: usize = lane - 1;
        const g = self.g_slab[e * self.nnz1 ..][0..self.nnz1];
        const r = self.rhs_slab[e * self.n1 ..][0..self.n1];
        return .{
            .g_vals = g,
            .rhs = r,
            .c_vals = if (self.has_charge) self.c_slab[e * self.nnz1 ..][0..self.nnz1] else g,
            .q_vec = if (self.has_charge) self.q_slab[e * self.n1 ..][0..self.n1] else r,
        };
    }

    fn runLane(self: *ParEval, batches: []const Batch, own_planes: Planes, has_charge: bool, lane: u32, x: []const f64, t: f64, mode: Mode) void {
        const pl = self.lanePlanes(own_planes, lane);
        if (lane != 0) {
            const win = self.windows[lane - 1];
            @memset(pl.g_vals[win.slot_lo..win.slot_hi], 0);
            @memset(pl.rhs[win.row_lo..win.row_hi], 0);
            pl.g_vals[self.nnz1 - 1] = 0;
            pl.rhs[self.n1 - 1] = 0;
            if (has_charge) {
                @memset(pl.c_vals[win.slot_lo..win.slot_hi], 0);
                @memset(pl.q_vec[win.row_lo..win.row_hi], 0);
                pl.c_vals[self.nnz1 - 1] = 0;
                pl.q_vec[self.n1 - 1] = 0;
            }
        }
        for (self.tasks[self.task_off[lane]..self.task_off[lane + 1]]) |task| {
            const b = &batches[task.batch];
            switch (mode) {
                .full => b.eval(b.ctx, &pl, task.first, task.last, x, t),
                .newton => b.eval_newton(b.ctx, &pl, task.first, task.last, x, t),
            }
        }
    }

    fn reduce(self: *ParEval, own_planes: Planes, has_charge: bool) void {
        var l: u32 = 1;
        while (l < self.n_lanes) : (l += 1) {
            const e: usize = l - 1;
            const win = self.windows[e];
            addSimd(
                own_planes.g_vals[win.slot_lo..win.slot_hi],
                self.g_slab[e * self.nnz1 + win.slot_lo .. e * self.nnz1 + win.slot_hi],
            );
            addSimd(
                own_planes.rhs[win.row_lo..win.row_hi],
                self.rhs_slab[e * self.n1 + win.row_lo .. e * self.n1 + win.row_hi],
            );
            if (has_charge) {
                addSimd(
                    own_planes.c_vals[win.slot_lo..win.slot_hi],
                    self.c_slab[e * self.nnz1 + win.slot_lo .. e * self.nnz1 + win.slot_hi],
                );
                addSimd(
                    own_planes.q_vec[win.row_lo..win.row_hi],
                    self.q_slab[e * self.n1 + win.row_lo .. e * self.n1 + win.row_hi],
                );
            }
        }
    }
};

const vec_width = std.simd.suggestVectorLength(f64) orelse 4;

fn addSimd(dst: []f64, src: []const f64) void {
    const W = vec_width;
    const Vv = @Vector(W, f64);
    var i: usize = 0;
    while (i + W <= dst.len) : (i += W) {
        const d: Vv = dst[i..][0..W].*;
        const s: Vv = src[i..][0..W].*;
        dst[i..][0..W].* = d + s;
    }
    while (i < dst.len) : (i += 1) dst[i] += src[i];
}

// ===========================================================================
// Runtime device ABI (dlopen'd .so). Crosses the boundary PER BATCH: the .so
// compiles this same ProtoStore(D)/DeviceBatch(D) and hands back the same
// type-erased Proto the builtin path uses. layoutHash() guards ABI drift.
// ===========================================================================

// Version 6 makes Hooks.recompute return error{TopologyChanged}!void. Reject old
// host callbacks before invocation; GPU PODs and layoutHash remain unchanged.
//
// Version 7: the slot tape's cleared entries are the DEVICE's structural
// Jacobian zeros, not just ground — `addPattern` no longer reserves a matrix
// entry for them and `evalRange` no longer writes one. Structs are unchanged,
// so the guard is `layoutHash` mixing this number rather than a layout delta.
pub const abi_version: u32 = 7;

pub const DeviceVtable = struct {
    name: []const u8,
    n_u: u32,
    num_ports: u32,
    model_size: usize,
    instance_size: usize,
    init_model: *const fn ([*]u8) void,
    init_instance: *const fn ([*]u8) void,
    set_model_param: *const fn ([*]u8, []const u8, f64) bool,
    set_instance_param: *const fn ([*]u8, []const u8, f64) bool,
    /// LRM 6.3.4 / 3.4.5: a parameter whose value is an expression over OTHER
    /// parameters, plus every localparam. The Model is a flat struct, so a host
    /// write to a base parameter cannot reach what was declared over it — the
    /// device closes that gap here, and the contract requires the host to call it
    /// once after the last `set_model_param` and before anything READS the model.
    /// Null when the module has no such parameter, which is the common case.
    derive: ?*const fn (model: [*]u8) void,
    collapse: ?*const fn (model: [*]const u8, instance: [*]const u8, out: [*]i32) void,
    proto_create: *const fn (std.mem.Allocator) anyerror!Proto,
    proto_add: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, model: [*]const u8, instance: [*]const u8, nodes: [*]const u32) anyerror!void,

    // GPU eval kernel this device emitted from `engine.DeviceKernel` at
    // `.so`-build-time (empty ⇒ CPU-only). The `.so` compiles the SAME template
    // the builtins use, so the format matches; the app links it into its gompute
    // context by `gpu_kernel_name`. Populated by the compileGenerated shim
    // (dynamic devices); empty for the in-process vtable (builtins bake their
    // kernels via kernels.zig instead).
    gpu_kernel_name: []const u8 = "",
    gpu_ptx: []const u8 = "", // NVIDIA cubin/PTX image
    gpu_amdgcn: []const u8 = "", // AMD code object
};

/// Layout guard over every type that crosses the boundary + the compiler
/// version. Both sides compile this same source; equal hashes ⇒ compatible.
pub fn layoutHash() u64 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var h: u64 = 0xcbf29ce484222325;
        for (builtin.zig_version_string) |c| h = mix(h, c);
        h = mix(h, @intFromEnum(builtin.zig_backend));
        h = mix(h, @intFromEnum(builtin.mode));
        for ([_]type{
            DeviceVtable, Proto,          Batch,
            Hooks,        Planes,         PatternView,
            PatternBuilder, ParamRef,     NoiseSource,
            std.mem.Allocator,
        }) |T| h = hashType(h, T);
        // Not a type: the SEMANTICS of the slot tape. A `.so` built before
        // `jac_pattern` reserves every (ru, cu) in the matrix and fills every
        // one; this host reserves only the device's structural pattern. Same
        // struct layouts, incompatible tapes — so the hash has to move.
        h = mix(h, abi_version);
        break :blk h;
    };
}

fn mix(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x100000001b3;
}

fn hashType(h0: u64, comptime T: type) u64 {
    var h = mix(mix(h0, @sizeOf(T)), @alignOf(T));
    switch (@typeInfo(T)) {
        .@"struct" => |si| inline for (si.fields) |f| {
            if (!f.is_comptime and @sizeOf(f.type) > 0) h = mix(h, @offsetOf(T, f.name));
        },
        else => {},
    }
    return h;
}

// ===========================================================================
// The host half of the contract (CONSUMING §4.2)
// ===========================================================================

/// This simulator's VPI application, and it deliberately has no `systf`.
///
/// §2.8.3 lets a `.va` call a `$name` no compiler defines, to be supplied
/// through §12.32 `vpi_register_analog_systf`. ESPice registers none, so the
/// right answer is to say so ONCE, in a type, and let `validateHost` turn a
/// model that needs one into a build error naming the function — instead of a
/// null `Instance.systf` reached at the first Newton step, or worse a value
/// invented out of thin air inside the residual.
///
/// A named empty struct rather than `DeviceBatch(D)`: `validateHost` only ever
/// looks for a `systf` decl, and routing the check through the batch type would
/// instantiate every model's SoA store at comptime just to ask that question.
///
/// ponytail: no VPI application until a model wants one. The day `checkHost`
/// errors, declare `pub fn systf(*const Model) ?*const contract.SystfHost` here
/// and fill EVERY partial (§12.22.1) — a slot left alone is a derivative
/// claimed and not computed.
pub const VpiHost = struct {};

/// Assert this host can supply everything `D` calls. A no-op for a device that
/// names no `$systf`, so every device site carries it unconditionally.
///
/// `contract.validate(D)` cannot ask this: it runs where the DEVICE is defined,
/// and a `.va` compiled to a `.so` does not know which simulator loads it. The
/// requirement only exists where the two meet — here.
pub fn checkHost(comptime D: type) void {
    contract.validateHost(VpiHost, D);
}

/// Export a contract-shaped device under the runtime ABI. The generated shim
/// is one line: `comptime { engine.exportDevice(@import("device"), "name"); }`.
pub fn exportDevice(comptime D: type, comptime device_name: []const u8) void {
    // The dynamic half. Builtins are checked over the catalog in root.zig;
    // this covers the `.so`, which root.zig never sees.
    comptime checkHost(D);
    const impl = Impl(D, device_name);
    @export(&impl.abiVersion, .{ .name = "arp_abi_version" });
    @export(&impl.layoutHashC, .{ .name = "arp_layout_hash" });
    @export(&impl.getVtable, .{ .name = "arp_device" });
}

/// In-process vtable (tests, embedding without dlopen).
pub fn deviceVtable(comptime D: type, comptime device_name: []const u8) *const DeviceVtable {
    return &Impl(D, device_name).vtable;
}

fn Impl(comptime D: type, comptime device_name: []const u8) type {
    return struct {
        const Store = ProtoStore(D);
        const n_u: usize = contract.nU(D);

        fn abiVersion() callconv(.c) u32 {
            return abi_version;
        }
        fn layoutHashC() callconv(.c) u64 {
            return layoutHash();
        }
        fn getVtable() callconv(.c) *const DeviceVtable {
            return &vtable;
        }

        const vtable: DeviceVtable = .{
            .name = device_name,
            .n_u = n_u,
            .num_ports = D.num_ports,
            .model_size = @sizeOf(D.Model),
            .instance_size = @sizeOf(D.Instance),
            .init_model = initBlob(D.Model),
            .init_instance = initBlob(D.Instance),
            .set_model_param = setParam(D.Model),
            .set_instance_param = setParam(D.Instance),
            .derive = if (@hasDecl(D, "derive")) deriveFn else null,
            .collapse = if (@hasDecl(D, "collapse")) collapseFn else null,
            .proto_create = protoCreate,
            .proto_add = protoAdd,
        };

        fn initBlob(comptime T: type) *const fn ([*]u8) void {
            return struct {
                fn f(dest: [*]u8) void {
                    const p: *T = @ptrCast(@alignCast(dest));
                    p.* = .{};
                }
            }.f;
        }

        fn setParam(comptime T: type) *const fn ([*]u8, []const u8, f64) bool {
            return struct {
                fn f(dest: [*]u8, param: []const u8, value: f64) bool {
                    @setEvalBranchQuota(10_000);
                    const p: *T = @ptrCast(@alignCast(dest));
                    inline for (@typeInfo(T).@"struct".fields) |field| {
                        switch (@typeInfo(field.type)) {
                            .float => if (matches(param, field.name)) {
                                @field(p, field.name) = @floatCast(value);
                                markGiven(p, field.name);
                                return true;
                            },
                            .int => if (matches(param, field.name)) {
                                @field(p, field.name) = @intFromFloat(value);
                                markGiven(p, field.name);
                                return true;
                            },
                            .bool => if (matches(param, field.name)) {
                                @field(p, field.name) = value != 0;
                                return true;
                            },
                            else => {},
                        }
                    }
                    return false;
                }

                /// A VA parameter whose name collides with a Zig primitive
                /// (`u0`, `type`, ...) is emitted by VerA's naming.zig with a
                /// trailing `Z` escape marker; the card key keeps the VA
                /// spelling, so match it against the unescaped name too.
                fn matches(param: []const u8, comptime field: []const u8) bool {
                    if (std.ascii.eqlIgnoreCase(param, field)) return true;
                    if (comptime field.len > 1 and field[field.len - 1] == 'Z')
                        return std.ascii.eqlIgnoreCase(param, field[0 .. field.len - 1]);
                    return false;
                }

                /// §9.19 `$param_given` companion (`<name>__given: bool`),
                /// emitted by VerA only for queried parameters. Raise it with
                /// the value or derived-default logic runs as if the card
                /// said nothing.
                fn markGiven(p: *T, comptime field: []const u8) void {
                    if (comptime @hasField(T, field ++ "__given"))
                        @field(p, field ++ "__given") = true;
                }
            }.f;
        }

        fn deriveFn(model: [*]u8) void {
            const m: *D.Model = @ptrCast(@alignCast(model));
            D.derive(m);
        }

        fn collapseFn(model: [*]const u8, instance: [*]const u8, out: [*]i32) void {
            const m: *const D.Model = @ptrCast(@alignCast(model));
            const i: *const D.Instance = @ptrCast(@alignCast(instance));
            const col = D.collapse(m, i);
            inline for (D.num_ports..n_u) |u|
                out[u] = if (col[u]) |p| @intCast(p) else -1;
        }

        fn protoCreate(gpa: std.mem.Allocator) anyerror!Proto {
            const store = try gpa.create(Store);
            store.* = .{};
            return .{
                .ctx = store,
                .type_name = device_name,
                .pattern = Store.addPattern,
                .finalize = Store.finalize,
                .destroy = Store.destroy,
                .apply_perm = Store.applyPerm,
            };
        }

        fn protoAdd(ctx: *anyopaque, gpa: std.mem.Allocator, model: [*]const u8, instance: [*]const u8, nodes: [*]const u32) anyerror!void {
            const store: *Store = @ptrCast(@alignCast(ctx));
            const m: *const D.Model = @ptrCast(@alignCast(model));
            const i: *const D.Instance = @ptrCast(@alignCast(instance));
            try store.models.append(gpa, m.*);
            try store.instances.append(gpa, i.*);
            try store.nodes.append(gpa, nodes[0..n_u].*);
        }
    };
}

/// Open a process-lifetime library; its mapping owns the returned vtable.
pub fn loadDevice(path: []const u8) !*const DeviceVtable {
    var lib = try std.DynLib.open(path);
    errdefer lib.close();

    const u32_fn = *const fn () callconv(.c) u32;
    const u64_fn = *const fn () callconv(.c) u64;
    const ver = lib.lookup(u32_fn, "arp_abi_version") orelse return error.NotArpDevice;
    if (ver() != abi_version) return error.WrongAbiVersion;
    const lh = lib.lookup(u64_fn, "arp_layout_hash") orelse return error.NotArpDevice;
    if (lh() != layoutHash()) return error.LayoutMismatch;

    const get_vt = lib.lookup(*const fn () callconv(.c) *const DeviceVtable, "arp_device") orelse
        return error.NotArpDevice;
    return get_vt();
}

test "Dual: expm1 and log1p retain finite range and IEEE endpoints" {
    const S = Dual(1, f64);
    for ([_]f64{ -740, -1, -1e-17, -0.0, 0, 1e-17, 0.5, 704, 709 }) |x| {
        const y = S.seed(x, 0).expm1();
        try std.testing.expect(std.math.isFinite(y.v));
        try std.testing.expectApproxEqRel(std.math.expm1(x), y.v, 3e-15);
        try std.testing.expectEqual(@exp(x), y.ddxAt(0));
    }
    for ([_]f64{ -1, -0.9999999999999999, -1e-17, -0.0, 0, 1e-17, 0.5, 1e308, std.math.inf(f64) }) |x| {
        const y = S.seed(x, 0).log1p();
        try std.testing.expectApproxEqRel(std.math.log1p(x), y.v, 3e-15);
        try std.testing.expectEqual(1.0 / (1.0 + x), y.ddxAt(0));
    }
    try std.testing.expectEqual(std.math.inf(f64), S.seed(710, 0).expm1().v);
    try std.testing.expectEqual(std.math.inf(f64), S.seed(std.math.inf(f64), 0).expm1().v);
    try std.testing.expectEqual(@as(f64, -1), S.seed(-std.math.inf(f64), 0).expm1().v);
    try std.testing.expect(std.math.isNan(S.seed(-2, 0).log1p().v));
    try std.testing.expect(std.math.isNan(S.seed(std.math.nan(f64), 0).expm1().v));
    try std.testing.expect(std.math.isNan(S.seed(std.math.nan(f64), 0).log1p().v));
    try std.testing.expect(std.math.signbit(S.seed(-0.0, 0).expm1().v));
    try std.testing.expect(std.math.signbit(S.seed(-0.0, 0).log1p().v));
}

test "Dual: an f32 Jacobian leaves the residual bit-identical" {
    // The one invariant the whole mixed-precision construction rests on
    // (docs/gpu-device-eval.md §9): `F` is the width of the DERIVATIVE, and the
    // residual is f64 on both instantiations. Not a tolerance — every operation
    // on `.v` is the same f64 arithmetic, so the values must be EQUAL. If this
    // ever needs a tolerance, the split has leaked into the residual.
    const core = struct {
        // The diode's own core, which is what the prototype ships:
        // is·(exp(v/vt) − 1) + gmin·v.
        fn f(comptime S: type, bias: f64) S {
            const x = [2]S{ S.seed(bias, 0), S.seed(0, 1) };
            const v = x[0].sub(x[1]);
            return S.con(1e-14).mul(v.div(S.con(0.025851999786450736)).exp().addC(-1.0))
                .add(v.scale(1e-12));
        }
    }.f;
    for (0..17) |i| {
        const bias = @as(f64, @floatFromInt(i)) * 0.05;
        const a = core(Dual(2, f64), bias);
        const b = core(Dual(2, f32), bias);
        try std.testing.expectEqual(a.val(), b.val());
        // …and the Jacobian degrades to f32 precision, and only to that.
        for (0..2) |c| try std.testing.expectApproxEqRel(a.ddxAt(c), b.ddxAt(c), 1e-6);
    }
}

test "RealFor: every primitive is Dual's value half, bit for bit" {
    // The invariant `evalQRange` rests on. Not a tolerance: the post-accept
    // charge re-read must reproduce the Dual pass EXACTLY, because `q_hist`/
    // `i_prev`/`q_tape` feed the next step's residual and `stepBound`'s LTE, so
    // one ulp here walks the timestep sequence off. If a `Dual` value expression
    // is ever changed (`div`'s reciprocal-multiply and `abs`'s sign test are the
    // two that do not read as the obvious thing), this fails instead of silently
    // perturbing every transient.
    const core = struct {
        fn f(comptime S: type, a: f64, b: f64) S {
            const x = S.seed(a, 0);
            const y = S.seed(b, 1);
            // One chain per primitive, so a desync anywhere lands in the result.
            var r = x.add(y).sub(y).neg().mul(x).div(y.addC(3.0)).scale(-0.5);
            r = r.abs().minC(4.0).maxC(-4.0);
            r = r.add(x.exp().log().expm1().log1p());
            r = r.add(y.addC(9.0).sqrt().pow(1.5));
            r = r.add(x.sin().cos().tanh().sinh().cosh().atan());
            r = r.add(S.sel(x.lt(y), x.max(y), x.min(y)));
            return r.add(S.sel(x.le(y).add(x.eq(y)), x, y));
        }
    }.f;
    for (0..13) |i| {
        for (0..13) |j| {
            // Spans both signs and crosses zero exactly, which is where `abs`,
            // `min`/`max` ties and `sel`'s 0/1 mask differ if they differ.
            const a = @as(f64, @floatFromInt(i)) * 0.25 - 1.5;
            const b = @as(f64, @floatFromInt(j)) * 0.25 - 1.5;
            try std.testing.expectEqual(
                core(DualFor(2, f64, false), a, b).val(),
                core(RealFor(false), a, b).val(),
            );
        }
    }
}

test "dyn vtable: blob init, param set by name, proto add" {
    const R = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct { r: f32 = 1000 };
        pub const Instance = struct { temp: f32 = 300.15 };
        pub fn eval(comptime Sc: type, x: [2]Sc, m: *const Model, _: *const Instance, _: f64) [2]Sc {
            const i = x[0].sub(x[1]).scale(1.0 / @as(f64, m.r));
            return .{ i, i.neg() };
        }
    };
    const testing = std.testing;
    const vt = deviceVtable(R, "tres");
    try testing.expectEqual(@as(u32, 2), vt.n_u);
    try testing.expectEqual(@sizeOf(R.Model), vt.model_size);

    var mblob: [@sizeOf(R.Model)]u8 align(16) = undefined;
    vt.init_model(&mblob);
    try testing.expect(vt.set_model_param(&mblob, "r", 42));
    try testing.expect(!vt.set_model_param(&mblob, "bogus", 1));
    const m: *R.Model = @ptrCast(@alignCast(&mblob));
    try testing.expectEqual(@as(f32, 42), m.r);

    var iblob: [@sizeOf(R.Instance)]u8 align(16) = undefined;
    vt.init_instance(&iblob);

    const proto = try vt.proto_create(testing.allocator);
    const nodes = [2]u32{ 1, 2 };
    try vt.proto_add(proto.ctx, testing.allocator, &mblob, &iblob, &nodes);
    const store: *ProtoStore(R) = @ptrCast(@alignCast(proto.ctx));
    try testing.expectEqual(@as(usize, 1), store.models.items.len);
    try testing.expectEqual(@as(f32, 42), store.models.items[0].r);
    proto.destroy(proto.ctx, testing.allocator);
}
