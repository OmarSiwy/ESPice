//! Device evaluation shared by the host, the GPU kernels and runtime-loaded
//! devices: forward-mode AD scalars, the per-type SoA batch behind the
//! `Batch`/`Hooks` ABI, and the one `evalRange` body both backends run.
//! Also the build root of every per-model object, GPU image and HDL `.so`.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract");
const gompute = @import("gompute");
const ir = @import("device_abi");
// NVPTX/AMDGCN have no libm, so `@exp`/`@log`/`@sin` and std's pow/sinh/cosh
// do not compile there; gompute.math forwards to libm on the host instead.
// `expm1` and `atan` also come from it: std's versions use
// `doNotOptimizeAway`, which AMDGCN cannot lower.
const dmath = gompute.math;

/// Whether `@mulAdd` is a native instruction. Without the feature it lowers to
/// a libm `fma()` call per lane, far slower than the two-rounding form.
/// It is `@mulAdd` rather than `@setFloatMode(.optimized)` on purpose: that
/// mode also grants `nnan`/`ninf`, and `Dual.div` must be allowed to divide by
/// zero (Verilog-A permits `V/r` with r = 0) so SparseLu's isFinite check can
/// catch the result.
// ponytail: an arch switch covers every shipped target; add a `-Dfma` option
// only when a target needs to override it.
const fma_ok = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .fma),
    .aarch64, .aarch64_be => true,
    .nvptx64, .amdgcn => true,
    else => false,
};

/// Forward-mode dual number implementing the contract's device scalar `S`:
/// one eval pass yields the residual and every partial. Lane u holds ∂/∂x[u].
///
/// `F` is the float width of the derivative half only. The value half and
/// every `S` boundary (`con`/`scale`/`addC`/`val`/`ddxAt`) stay f64, so the
/// residual is identical at either width. `F = f32` trades Newton iterations
/// for GPU throughput; see `jacFloat` and `gpuJacFloat` for who takes it.
pub fn Dual(comptime N: usize, comptime F: type) type {
    return DualFor(N, F, false);
}

fn DualFor(comptime N: usize, comptime F: type, comptime collapsed: bool) type {
    return struct {
        v: f64,
        /// Derivative lanes. Aligned to the element, not the vector: natural
        /// vector alignment pads `Dual(8, f64)` from 72 to 128 bytes, and
        /// nothing reads `d` through a pointer that needs it.
        d: V align(@alignOf(F)),

        /// Read by the generated device: the builder already applied
        /// `D.collapse` to the scatter tapes.
        pub const collapse_applied = collapsed;
        const V = @Vector(N, F);
        const Self = @This();

        inline fn splat(c: f64) V {
            return @splat(@floatCast(c));
        }
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
        /// Partial with respect to lane `col`, widened to f64.
        pub fn ddxAt(a: Self, col: usize) f64 {
            const lanes: [N]F = a.d;
            return lanes[col];
        }
        /// The whole derivative widened to f64, so `F` never leaks past the
        /// arithmetic.
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
        /// Same value operation as VerA's precompute scalar, so the two agree.
        pub fn expm1(a: Self) Self {
            return .{ .v = dmath.expm1(a.v), .d = a.d * splat(dmath.exp(a.v)) };
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
        /// `x^c`, slope `c·x^c/x`: one `pow`, exact for x != 0 (LRM §4.3.1
        /// negative bases included). At x == 0 the slope takes a second `pow`
        /// because `c·p/x` is 0/0 there and c == 1 must still give slope 1
        /// (gummel_poon's `1 - mjs` exponent at its default mjs = 0). A
        /// non-finite slope becomes 0. Must match VerA's `zPow`.
        pub fn pow(a: Self, c: f64) Self {
            const p = dmath.pow(a.v, c);
            const slope = if (a.v != 0.0) c * p / a.v else c * dmath.pow(a.v, c - 1.0);
            return .{ .v = p, .d = a.d * splat(if (std.math.isFinite(slope)) slope else 0.0) };
        }
        pub fn atan(a: Self) Self {
            return .{ .v = dmath.atan(a.v), .d = a.d * splat(1.0 / (1.0 + a.v * a.v)) };
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

        // Comparisons return a 0/1 indicator with zero derivative; the
        // derivative follows whichever operand `sel` picks. Semantics match
        // VerA's reference lowering (backend/tb.zig).
        pub fn lt(a: Self, b: Self) Self {
            return con(@floatFromInt(@intFromBool(a.v < b.v)));
        }
        pub fn le(a: Self, b: Self) Self {
            return con(@floatFromInt(@intFromBool(a.v <= b.v)));
        }
        pub fn eq(a: Self, b: Self) Self {
            return con(@floatFromInt(@intFromBool(a.v == b.v)));
        }
        /// Returns `a` when the indicator `c` is nonzero, else `b`, derivative
        /// included.
        pub fn sel(c: Self, a: Self, b: Self) Self {
            return if (c.v != 0.0) a else b;
        }
    };
}

/// Value-only device scalar for `evalQRange`. Every method is the `.v` line of
/// the matching `Dual` method verbatim (reciprocal-multiply `div`, sign-test
/// `abs`, the same min/max tie rule), so any pass that reads only `.v` gets
/// bit-identical values without paying for the gradient. VerA's own `R`
/// scalar is private to each generated device, hence this copy.
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
        /// Always 0; the contract requires the accessor.
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
        // Reciprocal-multiply, not `/`: matches `Dual.div` to the last bit.
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
            return .{ .v = dmath.expm1(a.v) };
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
            return .{ .v = dmath.atan(a.v) };
        }
        // Sign test, not `@abs`: matches `Dual.abs`, which keeps -0.
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

/// Derivative width of `Dual` for device D on the host. f32 only when the
/// device declares `jac_f32_host`: the f32 Jacobian helps some CPU decks and
/// costs others extra gmin-ladder steps (docs/perf/jac-width-2026-09-10.md).
pub fn jacFloat(comptime D: type) type {
    return if (@hasDecl(D, "jac_f32_host") and D.jac_f32_host) f32 else f64;
}

/// Derivative width of `Dual` for device D in its GPU kernel: f32 whenever the
/// device permits it with `jac_f32`, since GPUs run f32 many times faster.
pub fn gpuJacFloat(comptime D: type) type {
    return if (@hasDecl(D, "jac_f32") and D.jac_f32) f32 else f64;
}

pub const NoiseSource = ir.NoiseSource;
pub const NoiseGen = ir.NoiseGen;
pub const PsdTerm = ir.PsdTerm;
pub const Planes = ir.Planes;
pub const Batch = ir.Batch;
pub const Proto = ir.Proto;
const GROUND = ir.GROUND;
const StateCtlOp = ir.StateCtlOp;
const SimState = ir.SimState;
const ParamRef = ir.ParamRef;
const Hooks = ir.Hooks;
const PatternView = ir.PatternView;
const PatternBuilder = ir.PatternBuilder;
const GpuPayload = ir.GpuPayload;
const DeviceVtable = ir.DeviceVtable;

/// Returns `{slot_lo, slot_hi, row_lo, row_hi}`: the half-open slot and row
/// ranges the tapes touch, ignoring the trash slot and row. Empty ranges come
/// back as `lo == hi`.
fn tapeBounds(slots: []const u32, rhs_idx: []const u32, trash_slot: u32, trash_row: u32) [4]u32 {
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

/// Fills the gather, residual-row and Jacobian-slot tapes from the flat node
/// list (`[id * n_u + u]`). Ground rows go to row `pv.n`; ground entries and
/// the structural zeros `pat` clears go to `pv.trash_slot`, which keeps the
/// frozen `[id][ru][cu]` tape shape without reserving matrix entries.
/// Asserts every other (row, col) is in the pattern.
fn buildTapes(nodes: []const u32, n_u: usize, pat: []const u64, pv: PatternView, gath: []u32, rhs_idx: []u32, slots: []u32) void {
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

/// D's structural Jacobian, resistive and reactive combined: bit `cu` of row
/// `ru` is set when the device can write local entry (ru, cu).
fn jacPattern(comptime D: type) [contract.nU(D)]u64 {
    var out = rowPattern(D, "jac_pattern");
    // Without `q` there is no reactive half; `rowPattern` would call it dense.
    if (@hasDecl(D, "q")) {
        const q = rowPattern(D, "q_pattern");
        for (&out, q) |*o, qm| o.* |= qm;
    }
    return out;
}

/// The pattern decl `name` (`jac_pattern` or `q_pattern`), or all ones (dense)
/// when D does not declare it.
fn rowPattern(comptime D: type, comptime name: []const u8) [contract.nU(D)]u64 {
    if (!@hasDecl(D, name)) return @splat(std.math.maxInt(u64));
    return @field(D, name);
}

/// Which residual rows D's `eval` (`jac_rows`) or `q` (`q_rows`) ever writes;
/// all rows when undeclared. The others are zero at every bias, so their
/// stamps are dropped at comptime.
///
/// Never derive this from `rowPattern(...)[ru] != 0`. A row can be written
/// with a value that depends on no unknown: `isource` has `jac_pattern =
/// {0, 0}` and still stamps its current into both rows.
fn writtenRows(comptime D: type, comptime name: []const u8) [contract.nU(D)]bool {
    if (!@hasDecl(D, name)) return @splat(true);
    const mask: u64 = @field(D, name);
    var out: [contract.nU(D)]bool = @splat(true);
    for (&out, 0..) |*o, ru| o.* = (mask >> @intCast(ru)) & 1 != 0;
    return out;
}

/// The charge sites of D that join the transient LTE (`contract.qLte`), in
/// site order. `q_tape` holds one entry per instance and listed site,
/// indexed `id * lteSites(D).len + j`, the way ngspice's `*trunc.c` routines
/// hand CKTterr one charge state each.
fn lteSites(comptime D: type) []const usize {
    comptime {
        const on = contract.qLte(D);
        var out: [on.len]usize = undefined;
        var n: usize = 0;
        for (on, 0..) |o, k| if (o) {
            out[n] = k;
            n += 1;
        };
        const sites = out[0..n].*;
        return &sites;
    }
}

/// The derivative basis `evalRange` seeds: `w` lanes, and the lane each
/// unknown seeds into.
///
/// Wide: one lane per unknown. Narrow, for an instance whose collapse is
/// maximal (`collapse_full`): every merged set is one circuit node, its
/// columns share a matrix slot, and one shared lane computes the summed entry
/// the solver sees. mos1 goes from 8 lanes to 4, one ymm instead of two.
const Basis = struct {
    w: usize,
    /// `lane[u]` is the lane unknown `u` seeds.
    lane: []const u8,
};

fn basisOf(comptime D: type, comptime narrow: bool) Basis {
    const n_u = contract.nU(D);
    var lane: [n_u]u8 = undefined;
    var w: usize = 0;
    if (!narrow) {
        for (&lane, 0..) |*l, u| l.* = @intCast(u);
        w = n_u;
    } else {
        // The contract guarantees `collapse_full` is resolved and aliases
        // downward, so each root precedes its aliases.
        var of_root: [n_u]u8 = @splat(0);
        for (0..n_u) |u| {
            if (D.collapse_full[u]) |r| {
                lane[u] = of_root[r];
            } else {
                of_root[u] = @intCast(w);
                lane[u] = @intCast(w);
                w += 1;
            }
        }
    }
    const l = lane;
    return .{ .w = w, .lane = &l };
}

/// One pattern half with a single representative column kept per lane, so a
/// shared lane is stamped once. Computed per half because `g_vals` and
/// `c_vals` are separate planes.
///
/// The representative is the lowest alias, not the root: that is the column
/// the wide kernel stamps, so a slot shared with an unrelated column (a gate
/// tied to its drain) sums in the same order and the output stays
/// byte-identical. `alias[cu]` is `collapse_full[cu] != null`; all-false makes
/// this the identity.
fn repMask(comptime n_u: usize, comptime lane: [n_u]u8, comptime alias: [n_u]bool, comptime pat: [n_u]u64) [n_u]u64 {
    var out: [n_u]u64 = @splat(0);
    for (&out, pat) |*m, row| {
        var rep: [n_u]?usize = @splat(null);
        for (0..n_u) |cu| {
            if ((row >> @intCast(cu)) & 1 == 0) continue;
            const cur = rep[lane[cu]];
            // First column of the lane wins, then any alias beats a root.
            if (cur == null or (!alias[cur.?] and alias[cu])) rep[lane[cu]] = cu;
        }
        for (rep) |c| if (c) |cu| {
            m.* |= @as(u64, 1) << @intCast(cu);
        };
    }
    return out;
}

/// Whether D gets a second `evalRange` instantiation on the narrow basis for
/// its fully collapsed instances. It pays only when it saves a register on
/// AVX2 (docs/perf/remaining-2026-09-10.md): the wide dual spans two ymm
/// (4 < n_u <= 8) and the narrow one fits in one (w <= 4). That admits
/// mos1/2/3/6/9, bsim1, bsim3, hfet2, jfet and mes.
///
/// Limiting adds a correctness gate: the correction is stored per lane, so no
/// two unknowns `limit` writes may share one.
// ponytail: n_u <= 8 keeps bsim4 and hisim wide because nothing prices them
// yet; lift the bound when one of them sits on a benchmark deck.
fn canNarrow(comptime D: type) bool {
    if (!@hasDecl(D, "collapse_full")) return false;
    const n_u = contract.nU(D);
    if (n_u > 8 or n_u <= 4) return false;
    const b = comptime basisOf(D, true);
    if (b.w > 4 or b.w >= n_u) return false;
    if (@hasDecl(D, "limit")) {
        var seen: [n_u]bool = @splat(false);
        const writes = contract.limitWrites(D);
        for (0..n_u) |u| if ((writes >> @intCast(u)) & 1 != 0) {
            if (seen[b.lane[u]]) return false;
            seen[b.lane[u]] = true;
        };
    }
    return true;
}

/// Evaluates instances `[first, end)` of D and stamps residual, charge and
/// both Jacobians through `sink`. The one physics body: the host sink adds
/// into the planes, the GPU sink writes per-contribution staging cells.
///
/// `narrow` selects the reduced derivative basis (see `Basis`) and is sound
/// only on maximally collapsed instances, which `ProtoStore.finalize` sorts to
/// `[0, narrow_count)`. `F` is the derivative width: `jacFloat(D)` on the
/// host, `gpuJacFloat(D)` in `DeviceKernel`.
fn evalRange(comptime D: type, comptime narrow: bool, comptime F: type, sink: anytype, first: u32, end: u32, t: f64, limiting: bool) void {
    @setEvalBranchQuota(1_000_000);
    const SinkT = @typeInfo(@TypeOf(sink)).pointer.child;
    @setFloatMode(.optimized);
    const n_u = comptime contract.nU(D);
    const has_limit = comptime @hasDecl(D, "limit");
    const jac_pat = comptime rowPattern(D, "jac_pattern");
    const q_pat = comptime rowPattern(D, "q_pattern");
    const jac_row = comptime writtenRows(D, "jac_rows");
    const q_row = comptime writtenRows(D, "q_rows");

    const B = comptime basisOf(D, narrow);
    const W = B.w;
    const lane = comptime B.lane[0..n_u].*;
    const alias = comptime blk: {
        var a: [n_u]bool = @splat(false);
        if (narrow) for (&a, D.collapse_full) |*o, c| {
            o.* = c != null;
        };
        break :blk a;
    };
    const jac_rep = comptime repMask(n_u, lane, alias, jac_pat);
    const q_rep = comptime repMask(n_u, lane, alias, q_pat);
    const S = DualFor(if (!SinkT.on_device and padsLanes(D, narrow)) std.mem.alignForward(usize, W, 4) else W, F, @hasDecl(D, "collapse"));
    const use_lim = if (comptime has_limit) limiting else false;
    const lim_writes = comptime if (has_limit) contract.limitWrites(D) else 0;
    const has_q = comptime @hasDecl(D, "q");
    // `evalQ` computes both halves from one call into the model core; calling
    // `eval` and `q` separately runs the core twice.
    const fuse = comptime has_q and @hasDecl(D, "evalQ");
    // Ground predicates only on the GPU. On the host a ground stamp lands in
    // the shared trash slot/row, so the add is cheaper than the test. On the
    // GPU that add is a contended write on one address, measured 2x on 40,000
    // instances (docs/device-evaluation-audit-2026-09.md).
    const mask_ground = comptime SinkT.on_device;

    var id: u32 = first;
    while (id < end) : (id += 1) {
        var lx: [n_u]f64 = undefined;
        var active: [n_u]bool = undefined;
        // x minus its limited image, per lane. `canNarrow` guarantees no two
        // corrected unknowns share a lane.
        var corr: @Vector(W, f64) = @splat(0);
        inline for (0..n_u) |u| {
            const gi = sink.gath(id, u);
            active[u] = gi != GROUND;
            const xg = sink.x(gi);
            lx[u] = xg;
            // Only unknowns `limit` writes have a limited image; the other
            // lanes of `corr` stay zero.
            if (use_lim and comptime (lim_writes >> u) & 1 != 0) {
                const l = sink.lim(id, u);
                lx[u] = l;
                corr[lane[u]] = xg - l;
            }
        }
        // Near convergence the limiter leaves almost every instance alone, so
        // one test skips the correction dot products.
        const corr_live = use_lim and anyNonzero(W, corr);

        // Values stay per unknown even when lanes merge: a limited `di` and
        // its node `d` hold different numbers.
        var xv: [n_u]S = undefined;
        inline for (0..n_u) |u| xv[u] = S.seed(lx[u], lane[u]);

        var out: [n_u]S = undefined;
        // `q` returns one charge per ddt site. The planes take the rows
        // (`qRows`); the host `q_tape` takes the LTE sites.
        var qs: if (has_q) [contract.nQ(D)]S else void = undefined;
        var qo: if (has_q) [n_u]S else void = undefined;
        if (comptime fuse) {
            const both = @call(.always_inline, D.evalQ, .{ S, xv, sink.model(id), sink.inst(id), t });
            out = both.res;
            qs = both.q;
        } else {
            out = D.eval(S, xv, sink.model(id), sink.inst(id), t);
            if (comptime has_q) qs = D.q(S, xv, sink.model(id), sink.inst(id), t);
        }
        if (comptime has_q) qo = contract.qRows(D, S, qs);

        // Rows the device never writes (`jac_row`) and entries it can never
        // fill (`jac_pat`) are dropped at comptime; the planes start at +0.0,
        // so a skipped `+= 0.0` cannot even change a sign bit. Resistive and
        // reactive halves stay in separate passes: fusing them measured
        // slower on the mos1 kernel from register pressure.
        inline for (0..n_u) |ru| if (comptime jac_row[ru]) if (!mask_ground or active[ru]) {
            const row = sink.rhsRow(id, ru);
            var val = out[ru].v;
            if (comptime has_limit) {
                // The correction lands on the f64 residual. An empty pattern
                // row has zero gradient, so it has no correction either.
                if (corr_live and comptime jac_pat[ru] != 0) val += @reduce(.Add, head(W, out[ru].grad()) * corr);
            }
            sink.scatterRes(row, val);
            if (comptime !SinkT.skip_g and jac_pat[ru] != 0) {
                const g = out[ru].grad();
                inline for (0..n_u) |cu| if (comptime (jac_rep[ru] >> cu) & 1 != 0) if (!mask_ground or active[cu]) {
                    sink.scatterJac(id, ru, cu, g[lane[cu]]);
                };
            }
        };

        if (comptime has_q) {
            // Gated on `q_row`, never on `q_pat`: a `ddt()` of something that
            // varies in t but not in x has a clear pattern row and a live
            // charge.
            inline for (0..n_u) |ru| if (comptime q_row[ru]) {
                const row = sink.rhsRow(id, ru);
                var qv = qo[ru].v;
                if (comptime has_limit) {
                    if (corr_live and comptime q_pat[ru] != 0) qv += @reduce(.Add, head(W, qo[ru].grad()) * corr);
                }
                sink.scatterQ(row, qv);
                if (comptime !SinkT.skip_c and q_pat[ru] != 0) {
                    if (!mask_ground or active[ru]) {
                        const gq = qo[ru].grad();
                        inline for (0..n_u) |cu| if (comptime (q_rep[ru] >> cu) & 1 != 0) if (!mask_ground or active[cu]) {
                            sink.scatterQJac(id, ru, cu, gq[lane[cu]]);
                        };
                    }
                }
            };
            if (comptime !SinkT.on_device) inline for (comptime lteSites(D), 0..) |k, j| {
                var qv = qs[k].v;
                if (comptime has_limit) {
                    if (corr_live) qv += @reduce(.Add, head(W, qs[k].grad()) * corr);
                }
                sink.tapeQ(id, j, qv);
            };
        }
    }
}

/// Host models whose derivative lanes pad to a multiple of 4, mapped to
/// whether the narrow (collapsed) basis pads too. Opt-in, because no rule on
/// W or n_u predicts the sign. Callgrind Ir, padded/unpadded, 100-instance
/// DC sweeps with/without series resistances: gummel_poon 0.65/0.60,
/// vbic13_4t 0.65, vdmos 0.73/0.68, bsim2 0.82, mes 0.78 (narrow basis
/// unpadded: 1.00), jfet 0.76/1.02 (both on the wide basis). Losers left out:
/// bsim4va and bsimsoi_va 1.05, b3soidd 1.09, hfet1 and jfet2 1.06,
/// hisim2_va 1.03; every other model measured 1.00.
/// Pad lanes carry zero partials (or NaN from a 0/0) that no stamp reads,
/// so the output is byte-identical either way.
const pad_lanes = std.StaticStringMap(bool).initComptime(.{
    .{ "gummel_poon", true },
    .{ "vbic13_4t", true },
    .{ "vdmos", true },
    .{ "jfet", false },
    .{ "mes", false },
    .{ "bsim2", true },
});

fn padsLanes(comptime D: type, comptime narrow: bool) bool {
    const both = pad_lanes.get(comptime baseName(D)) orelse return false;
    return both or !narrow;
}

/// The first `w` lanes of `v`: the unpadded basis, so the correction dot
/// product sums exactly the lanes it sums without padding.
inline fn head(comptime w: usize, v: anytype) @Vector(w, f64) {
    return @shuffle(f64, v, undefined, std.simd.iota(i32, w));
}

/// `@reduce(.Or, v != 0)` computed on the bits: true when any lane is nonzero
/// or NaN, false for ±0. Lowers to vpaddq + vptest instead of a mask shuffle.
/// Differential test against the float compare: tests/eval.zig.
inline fn anyNonzero(comptime w: usize, v: @Vector(w, f64)) bool {
    return @reduce(.Or, @as(@Vector(w, u64), @bitCast(v)) << @splat(1)) != 0;
}

/// Restamps `q_vec` and `q_tape` for instances `[first, end)` and leaves the
/// other planes alone. Host only. With `S = RealFor(...)` the charges are
/// bit-identical to a full `evalRange` pass, at no gradient cost.
///
/// The transient calls this once per accepted step: Newton returns without
/// reassembling at the accepted iterate, so the planes still hold the
/// previous iterate's charge. The limiting correction is skipped because
/// limits are cleared before Newton returns.
fn evalQRange(comptime D: type, comptime S: type, sink: anytype, first: u32, end: u32, t: f64) void {
    @setEvalBranchQuota(1_000_000);
    @setFloatMode(.optimized);
    const n_u = comptime contract.nU(D);
    const q_row = comptime writtenRows(D, "q_rows");
    var id: u32 = first;
    while (id < end) : (id += 1) {
        var xv: [n_u]S = undefined;
        inline for (0..n_u) |u| xv[u] = S.seed(sink.x(sink.gath(id, u)), u);
        const qs = D.q(S, xv, sink.model(id), sink.inst(id), t);
        const qo = contract.qRows(D, S, qs);
        // Same `q_row` gate as `evalRange`, or the two passes would differ.
        inline for (0..n_u) |ru| if (comptime q_row[ru]) sink.scatterQ(sink.rhsRow(id, ru), qo[ru].v);
        inline for (comptime lteSites(D), 0..) |k, j| sink.tapeQ(id, j, qs[k].v);
    }
}

/// SPICE-style limiting over instances `[first, end)`: `lim = D.limit(cur,
/// old)`, where `cur` is the local x and `old` is the previous limited value
/// (once limiting is active) or the local `x_old`. Returns 1.0 when any
/// instance reports `converged = false`, which forces another Newton
/// iteration; the device decides whether its clamp was large enough.
///
/// Unknowns `limit` reads but never writes take `old` from `x_old`. That
/// equals the previous limited copy whenever `postStep` runs once per `x_old`
/// update, which holds on every CPU path (only GPU backtracking calls it
/// twice).
fn limitRange(comptime D: type, sink: anytype, first: u32, end: u32, lim_active: bool) f64 {
    const n_u = comptime contract.nU(D);
    // The device's read and write sets; a MOS ladder reads 4 of its 8
    // unknowns and writes 2. All ones when the device does not declare them.
    const reads = comptime contract.limitReads(D);
    const writes = comptime contract.limitWrites(D);
    // f64 rather than bool: measured +0.1% instructions with a bool here.
    var flag: f64 = 0;
    var id: u32 = first;
    while (id < end) : (id += 1) {
        // Lanes outside `reads` stay undefined: `limit` never reads them, and
        // their outputs fall outside `writes`, so nothing stores them.
        var cur: [n_u]f64 = undefined;
        var old: [n_u]f64 = undefined;
        inline for (0..n_u) |u| if (comptime (reads >> u) & 1 != 0) {
            const gi = sink.gath(id, u);
            cur[u] = sink.x(gi);
            old[u] = if (lim_active and comptime (writes >> u) & 1 != 0)
                sink.lim(id, u)
            else
                sink.xOld(gi);
        };
        // A plain call on purpose. LLVM inlines it anyway; forcing
        // `.always_inline` measured 0.2-0.3% slower.
        const lm = D.limit(sink.model(id), sink.inst(id), cur, old);
        if (!lm.converged) flag = 1;
        inline for (0..n_u) |u| if (comptime (writes >> u) & 1 != 0) {
            sink.setLim(id, u, lm.x[u]);
        };
    }
    return flag;
}

/// Allocator for `ProtoStore` staging rows. Not the caller's allocator, which
/// is usually an arena: an arena keeps every abandoned `MultiArrayList`
/// capacity alive, measured at 73 MB on a 25,000-MOSFET deck. `finalize`
/// copies the rows once, at exact size, into the caller's allocator.
const staging_gpa = std.heap.smp_allocator;

/// Construction-time rows for one device type: each instance's Model,
/// Instance and nodes, staged until `finalize` freezes them into a
/// `DeviceBatch(D)`. Reached through the type-erased `Proto`.
pub fn ProtoStore(comptime D: type) type {
    const n_u: usize = comptime contract.nU(D);
    return struct {
        /// One row per instance, owned by `staging_gpa`.
        rows: std.MultiArrayList(Row) = .empty,

        const Self = @This();
        const Row = struct { model: D.Model, instance: D.Instance, nodes: [n_u]u32 };

        pub fn append(self: *Self, model: D.Model, instance: D.Instance, nodes: [n_u]u32) !void {
            try self.rows.append(staging_gpa, .{ .model = model, .instance = instance, .nodes = nodes });
        }

        /// `Proto.pattern`: adds every (row, col) the device's structural
        /// Jacobian can fill, ground excluded. Reserving only the structural
        /// entries (25 of 64 for mos1) keeps fill-in out of every
        /// factorization.
        pub fn addPattern(ctx: *anyopaque, gpa: std.mem.Allocator, pb: *PatternBuilder) ir.DeviceResult(void) {
            return ir.DeviceResult(void).fromLocal(addPatternLocal(ctx, gpa, pb));
        }

        fn addPatternLocal(ctx: *anyopaque, gpa: std.mem.Allocator, pb: *PatternBuilder) error{OutOfMemory}!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const pat = comptime jacPattern(D);
            const nnz = comptime blk: {
                var k: usize = 0;
                for (pat) |m| k += @popCount(m & (std.math.maxInt(u64) >> (63 - (n_u - 1))));
                break :blk k;
            };
            try pb.reserve(gpa, self.rows.len * nnz);
            // Runtime loops: this runs once per batch, and unrolling n_u^2
            // for every device only costs comptime quota.
            for (self.rows.items(.nodes)) |nd| {
                for (0..n_u) |ru| for (0..n_u) |cu| {
                    if ((pat[ru] >> @intCast(cu)) & 1 == 0) continue;
                    if (nd[ru] != GROUND and nd[cu] != GROUND)
                        try pb.add(gpa, nd[ru], nd[cu]);
                };
            }
        }

        /// `Proto.finalize`: copies the staged rows into a new batch owned by
        /// `gpa`, builds its tapes against `pv`, and frees the staging rows.
        /// Fails with `TooManyInstances` past `maxInt(u32)` rows.
        pub fn finalize(ctx: *anyopaque, gpa: std.mem.Allocator, pv: PatternView) ir.DeviceResult(Batch) {
            return ir.DeviceResult(Batch).fromLocal(finalizeLocal(ctx, gpa, pv));
        }

        fn finalizeLocal(ctx: *anyopaque, gpa: std.mem.Allocator, pv: PatternView) error{ OutOfMemory, TooManyInstances }!Batch {
            const has_q = @hasDecl(D, "q");
            const has_attempt_decl = @hasDecl(D, "attempt");
            const self: *Self = @ptrCast(@alignCast(ctx));
            const count = std.math.cast(u32, self.rows.len) orelse return error.TooManyInstances;
            const store = try gpa.create(DeviceBatch(D));

            store.count = count;
            store.owns_tapes = true;
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
            // The staged rows can only be reordered before the copies below.
            if (comptime canNarrow(D)) store.narrow_count = try self.partitionCollapsed();

            store.models = try gpa.dupe(D.Model, self.rows.items(.model));
            if (comptime has_attempt_decl) {
                store.saved_models = try gpa.alloc(D.Model, count);
                store.attempt_saved = false;
            }
            if (comptime @hasDecl(D, "limit")) {
                // Full n_u stride and zeroed, although only `limitWrites`
                // slots are used: the GPU uploads the whole plane, and the
                // stride is part of the frozen tape layout.
                store.lim_x = try gpa.alloc(f64, count * n_u);
                @memset(store.lim_x, 0);
                store.lim_active = false;
            }
            store.instances = try gpa.dupe(D.Instance, self.rows.items(.instance));

            store.gath = try gpa.alloc(u32, count * n_u);
            store.rhs_idx = try gpa.alloc(u32, count * n_u);
            store.slots = try gpa.alloc(u32, count * n_u * n_u);
            const flat_nodes = @as([*]const u32, @ptrCast(self.rows.items(.nodes).ptr))[0 .. count * n_u];
            buildTapes(flat_nodes, n_u, &jacPattern(D), pv, store.gath, store.rhs_idx, store.slots);
            if (comptime has_q) {
                store.q_tape = try gpa.alloc(f64, count * comptime lteSites(D).len);
                @memset(store.q_tape, 0);
            }
            self.rows.deinit(staging_gpa);
            self.rows = .empty;

            // `setup` before `initState`: both read the card, and only the
            // former fills `Instance.su`.
            if (comptime @hasDecl(D, "setup")) {
                for (0..count) |i| D.setup(Dual(1, f64), &store.models[i], &store.instances[i]);
            }
            if (comptime @hasDecl(D, "State")) {
                store.states = try gpa.alloc(D.State, count);
                for (0..count) |i| store.states[i] = D.initState(&store.models[i], &store.instances[i]);
            }
            if (comptime @hasDecl(D, "precompute")) {
                for (0..count) |i| D.precompute(&store.instances[i], &store.models[i]);
            }

            return DeviceBatch(D).binding(store);
        }

        /// Stable-partitions the rows so maximally collapsed instances come
        /// first, and returns their count; the narrow basis is a comptime
        /// width and needs a uniform range. A uniform batch is left in place,
        /// so instance order (and slot summation order) only changes in a
        /// genuinely mixed batch.
        fn partitionCollapsed(self: *Self) !u32 {
            const flags = try staging_gpa.alloc(bool, self.rows.len);
            defer staging_gpa.free(flags);
            var n: usize = 0;
            for (self.rows.items(.model), self.rows.items(.instance), flags) |*m, *i, *f| {
                f.* = std.meta.eql(D.collapse(m, i), D.collapse_full);
                if (f.*) n += 1;
            }
            if (n != 0 and n != self.rows.len) {
                var src = try self.rows.clone(staging_gpa);
                defer src.deinit(staging_gpa);
                var lo: usize = 0;
                var hi: usize = n;
                for (flags, 0..) |f, k| {
                    const dst = if (f) &lo else &hi;
                    self.rows.set(dst.*, src.get(k));
                    dst.* += 1;
                }
            }
            return @intCast(n);
        }

        /// `Proto.apply_perm`: renumbers staged nodes through `perm`; nodes
        /// past its end are left alone.
        pub fn applyPerm(ctx: *anyopaque, perm: []const u32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.rows.items(.nodes)) |*nd| {
                inline for (0..n_u) |u| {
                    if (nd[u] < perm.len) nd[u] = perm[nd[u]];
                }
            }
        }

        /// `Proto.destroy`: frees the staging rows and the store itself.
        pub fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.rows.deinit(staging_gpa);
            gpa.destroy(self);
        }
    };
}

/// Whether D's `updateState` pushes history it cannot take back (LRM §4.5
/// `absdelay`). Native devices declare `unrevertible_state`; VerA devices are
/// recognized by the `__absdelay__` infix its naming scheme puts on the
/// Instance fields.
// ponytail: field-name matching until VerA can emit `unrevertible_state`
// (its contract has no slot for host-only decls yet).
fn hasAbsdelayState(comptime D: type) bool {
    if (@hasDecl(D, "unrevertible_state")) return D.unrevertible_state;
    return hasInstanceField(D, "__absdelay__", false);
}

/// Whether D holds a §5.10 variable across evaluations with no VerA `__acc`
/// accepted copy, so `stateCtl(.revert)` cannot take its write back.
fn hasUnrevertibleHeld(comptime D: type) bool {
    return hasInstanceField(D, "__held__", true);
}

/// Whether some Instance field of D contains `infix`; with `uncopied`, only
/// fields without an `__acc` accepted copy count.
fn hasInstanceField(comptime D: type, comptime infix: []const u8, comptime uncopied: bool) bool {
    if (!@hasDecl(D, "Instance")) return false;
    // hisim Instances have hundreds of long field names.
    @setEvalBranchQuota(2_000_000);
    inline for (@typeInfo(D.Instance).@"struct".fields) |f| {
        if (std.mem.indexOf(u8, f.name, infix) != null and
            !(uncopied and (std.mem.endsWith(u8, f.name, "__acc") or @hasField(D.Instance, f.name ++ "__acc"))))
            return true;
    }
    return false;
}

/// The frozen per-type batch: SoA columns for every instance of D plus the
/// shared tapes, reached through `Batch` and the comptime `hooks` table. A
/// hook is null when D lacks the decl it needs.
pub fn DeviceBatch(comptime D: type) type {
    const n_u: usize = comptime contract.nU(D);
    const has_state = @hasDecl(D, "State");
    const has_q = @hasDecl(D, "q");
    const has_attempt = @hasDecl(D, "attempt");
    const has_limit = @hasDecl(D, "limit");
    // A device that reads no host-owned field gets a null `set_sim_state`, so
    // the per-timepoint sweep skips it.
    const has_sim_state = @hasField(D.Instance, "abstime") or
        @hasField(D.Instance, "dt") or
        @hasField(D.Instance, "analysis_kind") or
        @hasField(D.Instance, "is_initial_step") or
        @hasField(D.Instance, "is_final_step");
    const narrowable = canNarrow(D);

    return struct {
        count: u32,
        /// Prepared templates own the tapes; instances made from them borrow.
        owns_tapes: bool = true,
        /// Instances `[0, narrow_count)` collapse maximally and run on the
        /// narrow basis; `ProtoStore.finalize` sorted them to the front.
        narrow_count: if (narrowable) u32 else void,
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
        /// Charge per instance and LTE site, indexed `id * lteSites(D).len +
        /// j`. Written by `Sink.tapeQ` on the host only; see `Hooks.q_tape`.
        q_tape: if (has_q) []f64 else void,

        const Self = @This();

        pub const hooks: Hooks = .{
            .instantiate = instantiate,
            .snapshot = snapshot,
            .set_limit_active = if (has_limit) setLimitActive else null,
            .scatter_bounds = scatterBounds,
            .q_tape = if (has_q) qTape else null,
            .eval_q = if (has_q) evalQOnly else null,
            .apply_limits = if (has_limit) applyLimits else null,
            .clear_limits = if (has_limit) clearLimits else null,
            .begin_solve = if (@hasDecl(D, "beginSolve")) beginSolve else null,
            .advance_iteration = if (@hasDecl(D, "advanceIteration")) advanceIteration else null,
            .check_convergence = if (@hasDecl(D, "checkConvergence")) checkConvergence else null,
            .seed = if (@hasDecl(D, "seed")) seedFn else null,
            .mark_current_rows = if (@hasDecl(D, "u_kinds")) markCurrentRows else null,
            // Unrevertible state runs once per accepted point; everything
            // else per converged solve. See `Hooks.commit_state`.
            .update_state = if (@hasDecl(D, "updateState") and !hasAbsdelayState(D) and !hasUnrevertibleHeld(D)) updateState else null,
            .commit_state = if (@hasDecl(D, "updateState") and hasAbsdelayState(D)) updateState else null,
            .commit_held = if (@hasDecl(D, "updateState") and !hasAbsdelayState(D) and hasUnrevertibleHeld(D)) updateState else null,
            .state_ctl = if (@hasDecl(D, "stateCtl")) stateCtl else null,
            // Only `updateState` writes `bound_step`.
            .bound_step = if (@hasDecl(D, "updateState") and @hasField(D.Instance, "bound_step")) boundStep else null,
            .set_temp = if (@hasField(D.Instance, "temperature")) setTemp else null,
            .set_sim_state = if (has_sim_state) setSimState else null,
            .min_delay = if (@hasDecl(D, "delays")) minDelay else null,
            .next_breakpoint = if (@hasDecl(D, "nextBreakpoint")) nextBreakpointFn else null,
            .collect_params = collectParams,
            // A generator is only priced by the device's own `noisePsd`.
            .collect_noise = if (@hasDecl(D, "noise_gens")) blk: {
                if (!@hasDecl(D, "noisePsd")) @compileError(@typeName(D) ++
                    " declares noise_gens without noisePsd; see docs/devices/noise-contract.md §3");
                break :blk collectNoise;
            } else null,
            .recompute = if (@hasDecl(D, "collapse") or @hasDecl(D, "precompute") or @hasDecl(D, "setup")) recomputePrecomputed else null,
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

        fn evalQOnly(ctx: *anyopaque, pl: *const Planes, first: u32, last: u32, x: []const f64, t: f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var sink = Sink(D, false, false).host(self, pl, x, undefined);
            // Without `always_inline` LLVM moves mos6's charge core out of
            // line, measured +0.9% on devices/mos6_inverter.
            @call(.always_inline, evalQRange, .{ D, RealFor(@hasDecl(D, "collapse")), &sink, first, last, t });
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
            const F = jacFloat(D);
            if (comptime narrowable) {
                // A ParEval slice may straddle the partition boundary.
                const split = std.math.clamp(self.narrow_count, first, last);
                if (split > first) evalRange(D, true, F, &sink, first, split, t, limiting);
                if (last > split) evalRange(D, false, F, &sink, split, last, t, limiting);
            } else {
                evalRange(D, false, F, &sink, first, last, t, limiting);
            }
        }

        fn localX(self: *Self, x: []const f64, id: usize) [n_u]f64 {
            var out: [n_u]f64 = undefined;
            inline for (0..n_u) |u| out[u] = x[self.gath[id * n_u + u]];
            return out;
        }

        fn beginSolve(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.instances) |*inst| D.beginSolve(inst);
        }

        fn advanceIteration(ctx: *anyopaque, previous_x: []const f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id|
                D.advanceIteration(&self.models[id], &self.instances[id], self.localX(previous_x, id));
        }

        fn checkConvergence(ctx: *anyopaque, x: []const f64) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                if (!D.checkConvergence(&self.models[id], &self.instances[id], self.localX(x, id))) return false;
            }
            return true;
        }

        fn seedFn(ctx: *anyopaque, x: []f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime has_limit) {
                // Only the slots `limitRange` maintains are ever read back.
                const writes = comptime contract.limitWrites(D);
                for (0..self.count) |id| {
                    const sv = D.seed(&self.models[id], &self.instances[id]);
                    inline for (0..n_u) |u| if (comptime (writes >> u) & 1 != 0) {
                        self.lim_x[id * n_u + u] = sv[u] orelse x[self.gath[id * n_u + u]];
                    };
                }
                self.lim_active = true;
            }
        }

        /// Marks the rows of non-voltage unknowns (branch currents) unless the
        /// same node is also one of the instance's voltage unknowns.
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
            // `limitRange` never touches the planes, but `host` reads their
            // pointers, and `undefined` would trap in Debug.
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

        /// Runs `D.updateState` on every instance at `x` and returns the
        /// earliest time any of them asks the step to be rejected at, if any.
        /// Called once per converged solve (or per accepted step for
        /// `commit_state`/`commit_held`), not per Newton iteration.
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

        /// Sets every instance's temperature from Celsius (`.temp`) to the
        /// Kelvin `$temperature` reads (LRM §9.10), then reruns `setup` and `precompute`.
        fn setTemp(ctx: *anyopaque, temp_c: f32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.instances) |*inst| inst.temperature = @as(f64, temp_c) + 273.15;
            self.reprep();
        }

        /// Writes the host-owned Instance fields a device declares. No
        /// `setup`/`precompute` rerun: they depend only on parameters, never on these.
        fn setSimState(ctx: *anyopaque, st: SimState) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.instances) |*inst| {
                if (comptime @hasField(D.Instance, "abstime")) inst.abstime = st.t;
                if (comptime @hasField(D.Instance, "dt")) inst.dt = st.dt;
                // The device declares its own AnalysisKind enum; convert by ordinal.
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

        /// This batch's GPU working set. The slices stay owned by the batch.
        fn gpuPayload(ctx: *anyopaque) GpuPayload {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{
                .kernel = comptime kernelName(D),
                .count = self.count,
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

        /// Reruns `setup` and `precompute` and returns false when `collapse` now asks for
        /// a node aliasing the frozen tapes do not have.
        fn recomputePrecomputed(ctx: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.reprep();
            if (comptime @hasDecl(D, "collapse")) {
                for (self.models, self.instances, 0..) |*model, *inst, id| {
                    const col = D.collapse(model, inst);
                    const nd = self.gath[id * n_u ..][0..n_u];
                    inline for (D.num_ports..n_u) |u| {
                        if (col[u]) |target| {
                            if (nd[u] != nd[target]) return false;
                        } else if (std.mem.indexOfScalar(u32, nd[0..u], nd[u]) != null) {
                            // The builder gave every unaliased internal its own node.
                            return false;
                        }
                    }
                }
            }
            return true;
        }

        fn reprep(self: *Self) void {
            if (comptime @hasDecl(D, "setup")) {
                for (self.instances, self.models) |*inst, *mdl| D.setup(Dual(1, f64), mdl, inst);
            }
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

        fn collectParams(ctx: *anyopaque, gpa: std.mem.Allocator, list: *std.ArrayList(ParamRef)) ir.DeviceResult(void) {
            return ir.DeviceResult(void).fromLocal(collectParamsLocal(ctx, gpa, list));
        }

        fn collectParamsLocal(ctx: *anyopaque, gpa: std.mem.Allocator, list: *std.ArrayList(ParamRef)) error{OutOfMemory}!void {
            // `paramField` runs per field; txl's history has ~10k fields.
            @setEvalBranchQuota(100_000 + 100 * (@typeInfo(D.Instance).@"struct".fields.len + @typeInfo(D.Model).@"struct".fields.len));
            const self: *Self = @ptrCast(@alignCast(ctx));
            try appendParams(D.Instance, self.instances, true, gpa, list);
            try appendParams(D.Model, self.models, false, gpa, list);
        }

        fn appendParams(comptime T: type, items: anytype, comptime is_instance: bool, gpa: std.mem.Allocator, list: *std.ArrayList(ParamRef)) error{OutOfMemory}!void {
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

        /// Whether `field` of T is a sweepable parameter: a float with a
        /// finite default that is not a VerA-internal or runtime-state field.
        fn paramField(comptime T: type, comptime field: std.builtin.Type.StructField) bool {
            if (field.type != f32 and field.type != f64) return false;
            // A trailing `__` is VerA's own namespace (no escaped Verilog-A
            // name ends in `_`), e.g. `nom_temp__` from `.options tnom`,
            // which `.mc`/`.sens` must not perturb. So is `<flow>__retained`,
            // the retention flag `derive` writes (contract `JacWhen`).
            if (comptime std.mem.endsWith(u8, field.name, "__") or
                std.mem.endsWith(u8, field.name, "__retained")) return false;
            if (@hasDecl(D, "AnalysisKind") and T == D.Instance) {
                // A VerA Instance holds runtime state; only these two are
                // parameters.
                const knobs = std.StaticStringMap(void).initComptime(.{
                    .{ "temperature", {} }, .{ "mfactor", {} },
                });
                if (!knobs.has(field.name)) return false;
            }
            const dflt = @field(T{}, field.name);
            return dflt > -1e30 and dflt < 1e30;
        }

        /// Appends one `NoiseSource` per declared generator per instance, with
        /// the PSD `D.noisePsd` gives at `x`. Pure in `x`, so `.pnoise` can
        /// call it once per PSS sample.
        fn collectNoise(ctx: *anyopaque, x: []const f64, gpa: std.mem.Allocator, list: *std.ArrayList(NoiseSource)) ir.DeviceResult(void) {
            return ir.DeviceResult(void).fromLocal(collectNoiseLocal(ctx, x, gpa, list));
        }

        fn collectNoiseLocal(ctx: *anyopaque, x: []const f64, gpa: std.mem.Allocator, list: *std.ArrayList(NoiseSource)) error{OutOfMemory}!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                const terms = D.noisePsd(self.localX(x, id), &self.models[id], &self.instances[id]);
                inline for (D.noise_gens, 0..) |gen, k| {
                    // Term k belongs to generator k (noise-contract.md §3).
                    // `@abs` matches ngspice nevalsrc.c:106. Correlation is
                    // not transported, so generators are independent here.
                    // Zero-power generators stay: their ordinal identifies
                    // them across PSS samples.
                    const t = terms[k];
                    try list.append(gpa, .{
                        .node_p = self.gath[id * n_u + gen.row],
                        .node_n = self.gath[id * n_u + gen.col],
                        .white = @abs(t.white),
                        .flicker = @abs(t.flicker),
                        .ef = t.ef,
                    });
                }
            }
        }

        fn binding(self: *Self) Batch {
            const const_g = @hasDecl(D, "constant") and D.constant.g;
            const const_c = @hasDecl(D, "constant") and D.constant.c;
            return .{
                .ctx = self,
                .eval = eval,
                .eval_newton = evalNewton,
                .count = self.count,
                .n_u = n_u,
                .has_charge = has_q,
                .has_const_jacobian = const_g and (!has_q or const_c),
                .type_name = comptime baseName(D),
                .hooks = &hooks,
            };
        }

        fn instantiate(ctx: *const anyopaque, gpa: std.mem.Allocator) ir.DeviceResult(Batch) {
            return ir.DeviceResult(Batch).fromLocal(duplicate(ctx, gpa, false));
        }

        fn snapshot(ctx: *const anyopaque, gpa: std.mem.Allocator) ir.DeviceResult(Batch) {
            return ir.DeviceResult(Batch).fromLocal(duplicate(ctx, gpa, true));
        }

        fn setLimitActive(ctx: *anyopaque, active: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.lim_active = active;
        }

        /// A new batch sharing the template's tapes with private copies of
        /// all mutable state. `accepted` copies the template's history
        /// (`snapshot`); otherwise history starts fresh (`instantiate`).
        fn duplicate(ctx: *const anyopaque, gpa: std.mem.Allocator, comptime accepted: bool) !Batch {
            const template: *const Self = @ptrCast(@alignCast(ctx));
            const self = try gpa.create(Self);
            self.* = template.*;
            self.owns_tapes = false;
            self.models = &.{};
            self.instances = &.{};
            if (comptime has_state) self.states = &.{};
            if (comptime has_q) self.q_tape = &.{};
            if (comptime has_attempt) {
                self.saved_models = &.{};
                self.attempt_saved = if (accepted) template.attempt_saved else false;
            }
            if (comptime has_limit) {
                self.lim_x = &.{};
                self.lim_active = if (accepted) template.lim_active else false;
            }
            errdefer destroy(self, gpa);

            // Model/Instance are POD, so a byte copy is a deep copy.
            self.models = try gpa.dupe(D.Model, template.models);
            self.instances = try gpa.dupe(D.Instance, template.instances);
            if (comptime has_attempt) {
                self.saved_models = try gpa.alloc(D.Model, self.count);
                if (accepted and template.attempt_saved) @memcpy(self.saved_models, template.saved_models);
            }
            if (comptime has_limit) {
                self.lim_x = try gpa.alloc(f64, self.count * n_u);
                if (accepted) @memcpy(self.lim_x, template.lim_x) else @memset(self.lim_x, 0);
            }
            if (comptime has_q) {
                self.q_tape = try gpa.alloc(f64, self.count * comptime lteSites(D).len);
                if (accepted) @memcpy(self.q_tape, template.q_tape) else @memset(self.q_tape, 0);
            }
            if (comptime has_state) {
                self.states = try gpa.alloc(D.State, self.count);
                if (accepted) {
                    @memcpy(self.states, template.states);
                } else {
                    for (self.states, self.models, self.instances) |*state, *model, *instance|
                        state.* = D.initState(model, instance);
                }
            }
            return self.binding();
        }

        fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            gpa.free(self.models);
            if (comptime has_attempt) gpa.free(self.saved_models);
            if (comptime has_limit) gpa.free(self.lim_x);
            gpa.free(self.instances);
            if (comptime has_state) gpa.free(self.states);
            if (self.owns_tapes) {
                gpa.free(self.gath);
                gpa.free(self.rhs_idx);
                gpa.free(self.slots);
            }
            if (comptime has_q) gpa.free(self.q_tape);
            gpa.destroy(self);
        }
    };
}

/// Whether D gets GPU kernels. Excluded, and kept on the host:
/// - `mutable_eval` devices, whose first-call snapshots need exclusive
///   evaluation;
/// - Newton-history devices (`beginSolve`/`advanceIteration`/
///   `checkConvergence`);
/// - `core_reads_simstate` cores, since sim state is published to the host
///   copy only;
/// - unrevertible held variables (`hasUnrevertibleHeld`), which
///   `StateKernel` would latch at every converged solve instead of once per
///   accepted point;
/// - `State` without `limit` (sources and FSMs whose eval reads host-owned
///   per-attempt state).
/// `State` with `limit` is the path-latch pattern that `StateKernel` and
/// `CtlKernel` run on the device.
// ponytail: the State-with-limit rule is decl correlation, not proof;
// `StateKernel` flags any non-`.ok` `updateState` so a device that breaks it
// falls back to the CPU instead of running wrong.
fn gpuEligible(comptime D: type) bool {
    if (@hasDecl(D, "mutable_eval") and D.mutable_eval) return false;
    if (@hasDecl(D, "beginSolve") or @hasDecl(D, "advanceIteration") or @hasDecl(D, "checkConvergence")) return false;
    if (hasUnrevertibleHeld(D)) return false;
    return !@hasDecl(D, "core_reads_simstate") and
        (@hasDecl(D, "limit") or !@hasDecl(D, "State"));
}

/// Whether D's GPU eval kernel is paired with a `StateKernel`.
fn hasStateKernel(comptime D: type) bool {
    return gpuEligible(D) and (@hasDecl(D, "limit") or @hasDecl(D, "State"));
}

/// Whether D also needs a `CtlKernel`: `stateCtl` mutates the resident
/// Instance/State blobs, which the host cannot reach.
fn hasCtlKernel(comptime D: type) bool {
    return hasStateKernel(D) and @hasDecl(D, "stateCtl");
}

/// D's type name without its namespace (`vsource.Vsource` gives `Vsource`).
/// Used as the batch `type_name` and the kernel symbol suffix.
fn baseName(comptime D: type) []const u8 {
    const full = @typeName(D);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

// Kernel symbols, derived from the type so the build root that exports them
// and `gpuPayload` that names them for the launcher cannot drift apart.

fn kernelName(comptime D: type) [:0]const u8 {
    return "arp_eval_" ++ comptime baseName(D);
}

fn stateKernelName(comptime D: type) [:0]const u8 {
    return "arp_lim_" ++ comptime baseName(D);
}

fn ctlKernelName(comptime D: type) [:0]const u8 {
    return "arp_ctl_" ++ comptime baseName(D);
}

/// The reduce body is device-independent, but gompute needs kernel names
/// unique across the per-device build roots, so each device exports a copy.
fn reduceKernelName(comptime D: type) [:0]const u8 {
    return "arp_reduce_" ++ comptime baseName(D);
}

/// Memory access for `evalRange`/`limitRange`. `device` changes only how
/// pointers are reached: the host indexes plain slices (`GlobalPtr(T)` is
/// `[*]T`), the GPU casts `.global` kernel arguments to the generic address
/// space the contract's `eval` takes. Host-only state is `void` under
/// `device`. `skip_const` drops stamps of a constant Jacobian half.
fn Sink(comptime D: type, comptime device: bool, comptime skip_const: bool) type {
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
        /// The lim plane (count * n_u). Undefined, and never read, when D has
        /// no `limit`.
        lim_: gompute.GlobalPtr(f64),
        /// `x_old`; read only by `limitRange`.
        xo: gompute.GlobalPtr(f64),
        /// The batch's `q_tape`, host only. Held as a bare pointer: through
        /// the batch, every plane store might alias the slice header, and
        /// LLVM reloaded it before each charge store.
        q_tape: if (device or !@hasDecl(D, "q")) void else [*]f64,

        pub const skip_g = skip_const and const_g;
        pub const skip_c = skip_const and const_c;
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
        // An address-space cast, not a copy: a compact model's Model has
        // hundreds of fields and would not fit in GPU registers. A no-op on
        // the host.
        pub inline fn model(s: *const Sk, id: u32) *const D.Model {
            return @addrSpaceCast(&s.models_[id]);
        }
        pub inline fn inst(s: *const Sk, id: u32) if (@hasDecl(D, "mutable_eval") and D.mutable_eval) *D.Instance else *const D.Instance {
            return @addrSpaceCast(&s.instances_[id]);
        }
        inline fn slot(s: *const Sk, id: u32, ru: usize, cu: usize) u32 {
            return s.slots_[(@as(usize, id) * n_u + ru) * n_u + cu];
        }
        // Plain `+=` on the GPU too. There the tape indexes a staging cell
        // only this thread writes, and `ReduceKernel` sums each plane cell's
        // cells in tape order; an atomic add would make the order, and so
        // the rounding, vary between runs. The staging is zeroed per pass,
        // so `0 + v` keeps signed zeros and NaNs as the host stamp does.
        inline fn add(p: gompute.GlobalPtr(f64), i: u32, v: f64) void {
            p[i] += v;
        }
        pub inline fn scatterRes(s: *const Sk, row: u32, val: f64) void {
            add(s.rhs, row, val);
        }
        pub inline fn scatterJac(s: *const Sk, id: u32, ru: usize, cu: usize, val: f64) void {
            add(s.g_vals, s.slot(id, ru, cu), val);
        }
        pub inline fn scatterQ(s: *const Sk, row: u32, qv: f64) void {
            add(s.q_vec, row, qv);
        }
        /// Records LTE site `j` of instance `id` in the host `q_tape`.
        pub inline fn tapeQ(s: *const Sk, id: u32, j: usize, qv: f64) void {
            s.q_tape[@as(usize, id) * (comptime lteSites(D).len) + j] = qv;
        }
        pub inline fn scatterQJac(s: *const Sk, id: u32, ru: usize, cu: usize, val: f64) void {
            add(s.c_vals, s.slot(id, ru, cu), val);
        }

        /// Host sink over batch `b`, writing into `pl`. `xo` may be undefined
        /// outside `limitRange`.
        pub fn host(b: *BatchT, pl: *const Planes, xs: []const f64, xo: [*]const f64) Sk {
            return .{
                .xs = @constCast(xs.ptr), // GlobalPtr has no const form; never written
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
                .q_tape = if (comptime @hasDecl(D, "q")) b.q_tape.ptr else {},
            };
        }
    };
}

/// GPU eval kernel for D, one thread per instance, running the same
/// `evalRange` as the host through a device `Sink`.
fn DeviceKernel(comptime D: type, comptime block_size: u32) type {
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
                .xo = undefined, // read only by limitRange
                .q_tape = {},
            };
            const id: u32 = @intCast(tid);
            // Always the wide basis here: the kernel arguments carry no
            // `narrow_count`, and they are part of the frozen GPU boundary.
            // ponytail: pass `narrow_count` once narrowing is measured on a GPU.
            evalRange(D, false, gpuJacFloat(D), &sink, id, id + 1, t, limiting != 0);
        }
    };
}

/// GPU limit and state-latch kernel, one thread per instance: the device side
/// of `applyLimits` followed by `updateState`, fused because the converger
/// always runs the two back to back at the same x.
///
/// Sets bit 0 of `flags[0]` when a clamp reports not converged, and bit 1
/// when an `updateState` returns anything but `.ok`, which the launcher
/// treats as a fault and answers by falling back to the CPU.
fn StateKernel(comptime D: type, comptime block_size: u32) type {
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
            var cur: [n_u]f64 = undefined;
            inline for (0..n_u) |u| cur[u] = xs[gath[id * n_u + u]];
            if (comptime has_limit) {
                // Must use the same write set as `limitRange`: host and
                // device share one `lim_x` plane.
                const writes = comptime contract.limitWrites(D);
                const inst_c: *const D.Instance = @addrSpaceCast(&instances[id]);
                var old: [n_u]f64 = undefined;
                inline for (0..n_u) |u| if (comptime (writes >> u) & 1 != 0) {
                    old[u] = if (lim_active != 0) lim[id * n_u + u] else x_old[gath[id * n_u + u]];
                } else {
                    old[u] = x_old[gath[id * n_u + u]];
                };
                const lm = D.limit(model, inst_c, cur, old);
                if (!lm.converged) flag |= 1;
                inline for (0..n_u) |u| if (comptime (writes >> u) & 1 != 0) {
                    lim[id * n_u + u] = lm.x[u];
                };
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

/// Segmented sum, one plane cell per thread: `plane[i] = sum(stage[seg[i] ..
/// seg[i + 1]])`. The launcher lays each cell's staging contributions out
/// contiguously in tape order, so this sums them in the order the host stamp
/// does, on every launch. The plane is overwritten, not accumulated.
///
/// Strict left-to-right with one accumulator on purpose: no `.optimized`
/// float mode, and no interleaved partial sums. The tape emits rows in `ru`
/// order, so interleaving would group all the +1.8 contributions of a supply
/// row in one lane and all the -1.8 in another, measured at 4e-12 error
/// against 1.6e-17 in order. The launcher bounds the chain length instead.
fn ReduceKernel(comptime _: type, comptime block_size: u32) type {
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

/// GPU accepted-step kernel, one thread per instance: runs `D.stateCtl` with
/// `op` on the resident Instance/State blobs and ORs its result into bit 0
/// of `flags[0]`.
fn CtlKernel(comptime D: type, comptime block_size: u32) type {
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

/// What this simulator offers devices, checked by `contract.validateHost`.
/// It supports Newton iteration hooks and mutable evaluation, and registers
/// no VPI `$systf` functions (LRM §12.32), so a model that calls one fails
/// to build instead of reading a null `Instance.systf` at run time.
// ponytail: add `pub fn systf(*const Model) ?*const contract.SystfHost` when a
// model needs one, and fill every partial (LRM §12.22.1).
const VpiHost = struct {
    pub const iteration_hooks = true;
    /// The batch runs `setup` once before `initState` (after `.options tnom`
    /// is on the card), and `reprep` reruns it after every parameter or
    /// temperature write.
    pub const calls_setup = true;
    pub const mutable_eval = true;
};

/// Compile error unless this host provides everything D requires. The check
/// lives here rather than in `contract.validate` because a device compiled to
/// a `.so` cannot know which simulator will load it.
pub fn checkHost(comptime D: type) void {
    contract.validateHost(VpiHost, D);
}

/// Exports D under the runtime device ABI (`arp_abi_version`,
/// `arp_layout_hash`, `arp_device`). The generated `.so` shim calls this:
/// `comptime { @import("dyn").exportDevice(@import("device"), "name"); }`.
pub fn exportDevice(comptime D: type, comptime device_name: []const u8) void {
    comptime checkHost(D);
    const impl = Impl(D, device_name);
    @export(&impl.abiVersion, .{ .name = "arp_abi_version" });
    @export(&impl.layoutHashC, .{ .name = "arp_layout_hash" });
    @export(&impl.getVtable, .{ .name = "arp_device" });
}

/// D's vtable without going through a shared library.
pub fn deviceVtable(comptime D: type, comptime device_name: []const u8) *const DeviceVtable {
    return &Impl(D, device_name).vtable;
}

fn Impl(comptime D: type, comptime device_name: []const u8) type {
    return struct {
        const Store = ProtoStore(D);
        const n_u: usize = contract.nU(D);

        fn abiVersion() callconv(.c) u32 {
            return ir.abi_version;
        }
        fn layoutHashC() callconv(.c) u64 {
            return ir.layoutHash();
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
            .bind_model = bindFn(D.Model),
            .bind_instance = bindFn(D.Instance),
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

        fn bindFn(comptime T: type) *const fn ([*]u8, []const ir.Param) ir.BindStatus {
            return struct {
                fn f(dest: [*]u8, params: []const ir.Param) ir.BindStatus {
                    return ir.bind.apply(@as(*T, @ptrCast(@alignCast(dest))), params);
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

        fn protoCreate(gpa: std.mem.Allocator) ir.DeviceResult(Proto) {
            const store = gpa.create(Store) catch return .out_of_memory;
            store.* = .{};
            return .{ .ok = .{
                .ctx = store,
                .type_name = device_name,
                .pattern = Store.addPattern,
                .finalize = Store.finalize,
                .destroy = Store.destroy,
                .apply_perm = Store.applyPerm,
            } };
        }

        // The rows live on `staging_gpa`, not the ABI's allocator.
        fn protoAdd(ctx: *anyopaque, _: std.mem.Allocator, model: [*]const u8, instance: [*]const u8, nodes: [*]const u32) ir.DeviceResult(void) {
            const store: *Store = @ptrCast(@alignCast(ctx));
            const m: *const D.Model = @ptrCast(@alignCast(model));
            const i: *const D.Instance = @ptrCast(@alignCast(instance));
            return ir.DeviceResult(void).fromLocal(store.append(m.*, i.*, nodes[0..n_u].*));
        }
    };
}

fn placeholder(_: u64) callconv(gompute.kernel_callconv) void {}

// As the build root, export every model in `models`: its GPU kernels (or a
// no-op placeholder when it is not GPU-eligible) in a device compilation, and
// its `arp_device_<name>` vtable getter on the host.
comptime {
    if (@import("root") == @This() and !builtin.is_test) {
        for (@typeInfo(@import("models")).@"struct".decls) |decl| {
            const D = @field(@import("models"), decl.name);
            if (gompute.is_device) {
                const block_size = ir.gpu_block_size;
                if (gpuEligible(D)) {
                    gompute.exportRaw(kernelName(D), &DeviceKernel(D, block_size).run);
                    if (hasStateKernel(D)) gompute.exportRaw(stateKernelName(D), &StateKernel(D, block_size).run);
                    if (hasCtlKernel(D)) gompute.exportRaw(ctlKernelName(D), &CtlKernel(D, block_size).run);
                    gompute.exportRaw(reduceKernelName(D), &ReduceKernel(D, block_size).run);
                } else gompute.exportRaw("arp_nop_" ++ decl.name, &placeholder);
            } else {
                checkHost(D);
                if (@hasDecl(D, "eval")) {
                    const Export = struct {
                        fn get() callconv(.c) *const DeviceVtable {
                            return deviceVtable(D, @typeName(D));
                        }
                    };
                    @export(&Export.get, .{ .name = "arp_device_" ++ decl.name });
                }
            }
        }
        gompute.exportKernels(.{});
    }
}

/// Private decls exposed to the test suites.
pub const test_access = if (@import("builtin").is_test) .{
    .DualFor = DualFor,
    .RealFor = RealFor,
    .anyNonzero = anyNonzero,
} else {};
