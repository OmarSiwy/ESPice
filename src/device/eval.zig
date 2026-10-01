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

/// A `Dual` family over lanes `0..n` with unknown u on lane u, every value
/// carrying all n lanes. For tests and one-off evaluations; `evalRange`
/// builds its families from a device's `Basis`.
pub fn Dual(comptime N: usize, comptime F: type) type {
    const lane = comptime blk: {
        var l: [N]u8 = undefined;
        for (&l, 0..) |*e, u| e.* = u;
        break :blk l;
    };
    return DualFor(F, &lane, .{ .dense = true }, false);
}

/// How a `DualFor` family lays out a value's derivative lanes.
const Layout = struct {
    /// Every `Of(m)` is one type carrying every lane of the basis. Otherwise
    /// `Of(m)` carries only the lanes of `m`'s unknowns, and a binary
    /// operation joins its operands' lanes.
    dense: bool,
    /// Rounds each value's lane count up to a power of two: LLVM splits a
    /// 12- or 26-wide vector into shuffles and spills (gummel_poon's eval
    /// body doubled). The pad lanes hold zeros (or a NaN from a 0/0) that
    /// nothing reads.
    pad: bool = false,
};

/// Number of lanes `lane` maps unknowns onto.
fn laneCount(comptime lane: []const u8) usize {
    var n: usize = 0;
    for (lane) |l| if (l != contract.no_lane) {
        n = @max(n, @as(usize, l) + 1);
    };
    return n;
}

/// Forward-mode AD family: the contract's scalar family `S`
/// (`contract.family_fns`, numerics per `contract.expectFamily`). One eval
/// pass yields the residual and every partial.
///
/// `lane[u]` is the derivative lane unknown `u` seeds, or
/// `contract.no_lane`; several unknowns may share one (the narrow basis).
/// `F` is the float width of the derivative half only. The value half and
/// every boundary (`con`/`scale`/`addC`/`val`/`ddxAt`) stay f64, so the
/// residual is identical at either width. `F = f32` trades Newton iterations
/// for GPU throughput; see `jacFloat` and `gpuJacFloat` for who takes it.
fn DualFor(comptime F: type, comptime lane: []const u8, comptime layout: Layout, comptime collapsed: bool) type {
    const n_lanes = laneCount(lane);
    if (n_lanes > 64) @compileError("Dual: more than 64 derivative lanes");
    const all: u64 = if (n_lanes == 64) ~@as(u64, 0) else (@as(u64, 1) << n_lanes) - 1;
    return struct {
        /// Read by the generated device: the builder already applied
        /// `D.collapse` to the scatter tapes.
        pub const collapse_applied = collapsed;
        pub const V = f64;

        /// The lanes the unknowns in `m` occupy, one bit per lane.
        fn lanesOf(comptime m: u64) u64 {
            if (layout.dense) return all;
            var s: u64 = 0;
            for (lane, 0..) |l, u| {
                if (u < 64 and (m >> u) & 1 != 0 and l != contract.no_lane) s |= @as(u64, 1) << l;
            }
            return s;
        }

        fn width(comptime ls: u64) usize {
            const n = @popCount(ls);
            return if (layout.pad and n != 0) std.math.ceilPowerOfTwoAssert(usize, n) else n;
        }

        fn unknownBit(comptime u: usize) u64 {
            return if (u < 64) @as(u64, 1) << u else ~@as(u64, 0);
        }

        pub fn Of(comptime m: u64) type {
            return Val(lanesOf(m));
        }
        pub fn con(c: f64) Of(0) {
            return .{ .v = c, .d = @splat(0) };
        }
        pub fn probe(comptime u: usize, v: f64) Of(unknownBit(u)) {
            const T = Of(unknownBit(u));
            var d: T.Lanes = @splat(0);
            if (comptime lane[u] != contract.no_lane) d[comptime T.pos(lane[u])] = 1;
            return .{ .v = v, .d = d };
        }
        /// `a` where the indicator `c` is nonzero, else `b`, lanes included.
        pub fn sel(c: anytype, a: anytype, b: anytype) Val(@TypeOf(a).lanes | @TypeOf(b).lanes) {
            const r = @TypeOf(a).lanes | @TypeOf(b).lanes;
            return if (c.v != 0.0) a.toLanes(r) else b.toLanes(r);
        }

        /// A value carrying the lanes in `ls`, in ascending lane order.
        fn Val(comptime ls: u64) type {
            return struct {
                v: f64,
                /// Aligned to the element, not the vector: natural vector
                /// alignment pads 8 f64 lanes from 72 to 128 bytes, and
                /// nothing reads `d` through a pointer that needs it.
                d: Lanes align(@alignOf(F)),

                pub const lanes = ls;
                const Lanes = @Vector(width(ls), F);
                const T = @This();

                /// Where lane `l` sits in `d`.
                fn pos(comptime l: usize) usize {
                    return @popCount(ls & ((@as(u64, 1) << l) - 1));
                }
                inline fn k(c: f64) Lanes {
                    return @splat(@floatCast(c));
                }
                inline fn map(a: T, v: f64, c: f64) T {
                    return .{ .v = v, .d = a.d * k(c) };
                }
                /// These lanes laid out as `to_ls`'s. New and pad lanes are +0.
                inline fn spread(a: T, comptime to_ls: u64) @Vector(width(to_ls), F) {
                    if (ls & ~to_ls != 0) @compileError("Dual: lanes do not widen");
                    if (ls == to_ls) return a.d;
                    if (ls == 0) return @splat(0);
                    const idx = comptime blk: {
                        var idx: [width(to_ls)]i32 = @splat(-1);
                        var j: usize = 0;
                        for (0..64) |l| if ((to_ls >> l) & 1 != 0) {
                            if ((ls >> l) & 1 != 0) idx[j] = pos(l);
                            j += 1;
                        };
                        break :blk idx;
                    };
                    return @shuffle(F, a.d, @as(@Vector(1, F), @splat(0)), idx);
                }
                fn toLanes(a: T, comptime to_ls: u64) Val(to_ls) {
                    return .{ .v = a.v, .d = a.spread(to_ls) };
                }

                pub fn to(a: T, comptime m: u64) Of(m) {
                    return a.toLanes(Of(m).lanes);
                }
                pub fn val(a: T) f64 {
                    return a.v;
                }
                /// The partial with respect to unknown `u`, widened to f64.
                pub fn ddxAt(a: T, comptime u: usize) f64 {
                    const l = lane[u];
                    if (comptime l == contract.no_lane or (ls >> l) & 1 == 0) return 0.0;
                    return a.d[comptime pos(l)];
                }
                /// Every lane widened to f64, pad lanes included, so `F`
                /// never leaks past the arithmetic.
                pub inline fn grad(a: T) @Vector(width(ls), f64) {
                    return if (F == f64) a.d else @floatCast(a.d);
                }

                pub fn add(a: T, b: anytype) Val(ls | @TypeOf(b).lanes) {
                    const r = ls | @TypeOf(b).lanes;
                    return .{ .v = a.v + b.v, .d = a.spread(r) + b.spread(r) };
                }
                pub fn sub(a: T, b: anytype) Val(ls | @TypeOf(b).lanes) {
                    const r = ls | @TypeOf(b).lanes;
                    return .{ .v = a.v - b.v, .d = a.spread(r) - b.spread(r) };
                }
                pub fn neg(a: T) T {
                    return .{ .v = -a.v, .d = -a.d };
                }
                pub fn mul(a: T, b: anytype) Val(ls | @TypeOf(b).lanes) {
                    const B = @TypeOf(b);
                    const J = Val(ls | B.lanes);
                    if (B.lanes == 0) return .{ .v = a.v * b.v, .d = a.spread(J.lanes) * J.k(b.v) };
                    if (ls == 0) return .{ .v = a.v * b.v, .d = b.spread(J.lanes) * J.k(a.v) };
                    return .{ .v = a.v * b.v, .d = mulAddV(J.Lanes, b.spread(J.lanes), J.k(a.v), a.spread(J.lanes) * J.k(b.v)) };
                }
                /// The value is the IEEE quotient (contract §3); the lanes
                /// keep the reciprocal.
                pub fn div(a: T, b: anytype) Val(ls | @TypeOf(b).lanes) {
                    const B = @TypeOf(b);
                    const J = Val(ls | B.lanes);
                    const inv = 1.0 / b.v;
                    const q = a.v / b.v;
                    if (B.lanes == 0) return .{ .v = q, .d = a.spread(J.lanes) * J.k(inv) };
                    return .{ .v = q, .d = mulAddV(J.Lanes, b.spread(J.lanes), J.k(-q), a.spread(J.lanes)) * J.k(inv) };
                }
                pub fn scale(a: T, c: f64) T {
                    return map(a, a.v * c, c);
                }
                pub fn addC(a: T, c: f64) T {
                    return .{ .v = a.v + c, .d = a.d };
                }
                pub fn exp(a: T) T {
                    const e = dmath.exp(a.v);
                    return map(a, e, e);
                }
                pub fn log(a: T) T {
                    return map(a, dmath.log(a.v), 1.0 / a.v);
                }
                /// Same value operation as VerA's precompute scalar, so the
                /// two agree.
                pub fn expm1(a: T) T {
                    return map(a, dmath.expm1(a.v), dmath.exp(a.v));
                }
                pub fn log1p(a: T) T {
                    return map(a, std.math.log1p(a.v), 1.0 / (1.0 + a.v));
                }
                pub fn sqrt(a: T) T {
                    const s = @sqrt(a.v);
                    return map(a, s, if (s > 0.0) 0.5 / s else 0.0);
                }
                pub fn sin(a: T) T {
                    return map(a, dmath.sin(a.v), dmath.cos(a.v));
                }
                pub fn cos(a: T) T {
                    return map(a, dmath.cos(a.v), -dmath.sin(a.v));
                }
                pub fn tanh(a: T) T {
                    const th = dmath.tanh(a.v);
                    return map(a, th, 1.0 - th * th);
                }
                /// `x^c`, slope `c·x^c/x`: one `pow`, exact for x != 0 (LRM
                /// §4.3.1 negative bases included). At x == 0 the slope takes
                /// a second `pow` because `c·p/x` is 0/0 there and c == 1
                /// must still give slope 1. A non-finite slope becomes 0.
                pub fn pow(a: T, c: f64) T {
                    const p = dmath.pow(a.v, c);
                    const slope = if (a.v != 0.0) c * p / a.v else c * dmath.pow(a.v, c - 1.0);
                    return map(a, p, if (std.math.isFinite(slope)) slope else 0.0);
                }
                pub fn atan(a: T) T {
                    return map(a, dmath.atan(a.v), 1.0 / (1.0 + a.v * a.v));
                }
                pub fn sinh(a: T) T {
                    return map(a, dmath.sinh(a.v), dmath.cosh(a.v));
                }
                pub fn cosh(a: T) T {
                    return map(a, dmath.cosh(a.v), dmath.sinh(a.v));
                }
                // Comparisons return a 0/1 indicator without lanes; `sel`
                // carries the lanes of the operand it picks.
                pub fn lt(a: T, b: anytype) Of(0) {
                    return con(@floatFromInt(@intFromBool(a.v < b.v)));
                }
                pub fn le(a: T, b: anytype) Of(0) {
                    return con(@floatFromInt(@intFromBool(a.v <= b.v)));
                }
                pub fn eq(a: T, b: anytype) Of(0) {
                    return con(@floatFromInt(@intFromBool(a.v == b.v)));
                }
            };
        }
    };
}

inline fn mulAddV(comptime Vec: type, a: Vec, b: Vec, c: Vec) Vec {
    return if (fma_ok) @mulAdd(Vec, a, b, c) else a * b + c;
}

/// Value-only family for the paths that read no partial: `evalQRange`, the
/// charge-tape kernel and every value entry point (`setup`, `limit`,
/// `updateState`, ...). Every method is the `.v` line of the matching
/// `DualFor` method verbatim, so it computes the bits `eval` computes
/// without paying for the gradient.
fn RealFor(comptime collapsed: bool) type {
    return struct {
        v: f64,

        const Self = @This();
        pub const collapse_applied = collapsed;
        pub const V = f64;
        pub const lanes: u64 = 0;

        pub fn Of(comptime _: u64) type {
            return Self;
        }
        pub fn con(c: f64) Self {
            return .{ .v = c };
        }
        pub fn probe(comptime _: usize, v: f64) Self {
            return .{ .v = v };
        }
        pub fn sel(c: Self, a: Self, b: Self) Self {
            return if (c.v != 0.0) a else b;
        }
        pub fn to(a: Self, comptime _: u64) Self {
            return a;
        }
        pub fn val(a: Self) f64 {
            return a.v;
        }
        /// Always 0; the contract requires the accessor.
        pub fn ddxAt(_: Self, comptime _: usize) f64 {
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
        pub fn pow(a: Self, c: f64) Self {
            return .{ .v = dmath.pow(a.v, c) };
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
    };
}

/// The value-only family every non-eval entry point runs on.
const Real = RealFor(false);

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
/// Only the unknowns in `contract.derivReads` get a lane: the device reads
/// the others as constants and `jac_const` holds their exact partials. Wide:
/// one lane per read unknown. Narrow, for an instance whose collapse is
/// maximal (`collapse_full`): every merged set is one circuit node, its
/// columns share a matrix slot, and one shared lane computes the summed entry
/// the solver sees. mos1 goes from 6 lanes to 4, one ymm instead of two.
const Basis = struct {
    w: usize,
    /// `lane[u]` is the lane unknown `u` seeds, or `contract.no_lane`.
    lane: []const u8,
};

fn basisOf(comptime D: type, comptime narrow: bool) Basis {
    const n_u = contract.nU(D);
    const reads = contract.derivReads(D);
    var lane: [n_u]u8 = @splat(contract.no_lane);
    var of_root: [n_u]u8 = @splat(contract.no_lane);
    var w: usize = 0;
    for (0..n_u) |u| {
        if (u < 64 and (reads >> u) & 1 == 0) continue;
        // The contract guarantees `collapse_full` is resolved.
        const root = if (narrow) D.collapse_full[u] orelse u else u;
        if (of_root[root] == contract.no_lane) {
            of_root[root] = @intCast(w);
            w += 1;
        }
        lane[u] = of_root[root];
    }
    const l = lane;
    return .{ .w = w, .lane = &l };
}

/// One pattern half with a single representative column kept per lane, so a
/// shared lane is stamped once; columns without a lane are dropped (their
/// partials come from `jac_const`). Computed per half because `g_vals` and
/// `c_vals` are separate planes.
///
/// The representative is the lowest alias, not the root: that is the column
/// the wide kernel stamps, so a slot shared with an unrelated column (a gate
/// tied to its drain) sums in the same order and the output stays
/// byte-identical. `alias[cu]` is `collapse_full[cu] != null`; all-false makes
/// this the identity on the laned columns.
fn repMask(comptime n_u: usize, comptime lane: [n_u]u8, comptime alias: [n_u]bool, comptime pat: [n_u]u64) [n_u]u64 {
    var out: [n_u]u64 = @splat(0);
    for (&out, pat) |*m, row| {
        var rep: [n_u]?usize = @splat(null);
        for (0..n_u) |cu| {
            if ((row >> @intCast(cu)) & 1 == 0 or lane[cu] == contract.no_lane) continue;
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

/// The `jac_const` entry for local (row `ru`, column `cu`), if any.
fn constEntry(comptime D: type, comptime ru: usize, comptime cu: usize) ?contract.JacConst(D.U) {
    for (contract.jacConst(D)) |e| {
        if (@intFromEnum(e.row) == ru and @intFromEnum(e.col) == cu) return e;
    }
    return null;
}

/// Whether D gets a second `evalRange` instantiation on the narrow basis for
/// its fully collapsed instances. It pays only when it saves a register on
/// AVX2 (docs/perf/remaining-2026-09-10.md): the wide dual spans two ymm
/// (4 < w <= 8) and the narrow one fits in one (w <= 4). That admits
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
    if (b.w > 4 or b.w >= comptime basisOf(D, false).w) return false;
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
/// host, `gpuJacFloat(D)` in `DeviceKernel`. `layout` is `hostLayout` on the
/// host and dense in `DeviceKernel`.
fn evalRange(comptime D: type, comptime narrow: bool, comptime F: type, comptime layout: Layout, sink: anytype, first: u32, end: u32, sim: SimState, limiting: bool) void {
    @setEvalBranchQuota(1_000_000);
    const SinkT = @typeInfo(@TypeOf(sink)).pointer.child;
    @setFloatMode(.optimized);
    const n_u = comptime contract.nU(D);
    const has_limit = comptime @hasDecl(D, "limit");
    const reads = comptime contract.derivReads(D);
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
    const S = DualFor(F, &lane, layout, @hasDecl(D, "collapse"));
    // Every lane of the basis: the layout the limiting correction sums in.
    const full = comptime S.Of(reads).lanes;
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
        const model = sink.model(id);

        // `q` returns one charge per ddt site. The planes take the rows
        // (`qRows`); the host `q_tape` takes the LTE sites.
        var out: contract.Rows(D, S) = undefined;
        var qs: if (has_q) contract.Sites(D, S) else void = undefined;
        if (comptime fuse) {
            const both = @call(.always_inline, D.evalQ, .{ S, &lx, model, sink.inst(id), sim });
            out = both.res;
            qs = both.q;
        } else {
            out = D.eval(S, &lx, model, sink.inst(id), sim);
            if (comptime has_q) qs = D.q(S, &lx, model, sink.inst(id), sim);
        }
        const qo = if (comptime has_q) contract.qRows(D, S, qs) else {};

        // Rows the device never writes (`jac_row`) and entries it can never
        // fill (`jac_pat`) are dropped at comptime; the planes start at +0.0,
        // so a skipped `+= 0.0` cannot even change a sign bit. Resistive and
        // reactive halves stay in separate passes: fusing them measured
        // slower on the mos1 kernel from register pressure. A column without
        // a lane stamps its `jac_const` partial in the same (row, column)
        // order, so a shared slot sums as the tape orders it.
        inline for (0..n_u) |ru| if (comptime jac_row[ru]) if (!mask_ground or active[ru]) {
            const row = sink.rhsRow(id, ru);
            var val = out[ru].v;
            if (comptime has_limit and @TypeOf(out[ru]).lanes != 0) {
                // The correction lands on the f64 residual. A row without
                // lanes has zero gradient, so it has no correction either.
                if (corr_live) val += @reduce(.Add, head(W, out[ru].toLanes(full).grad()) * corr);
            }
            sink.scatterRes(row, val);
            if (comptime !SinkT.skip_g and jac_pat[ru] != 0) {
                inline for (0..n_u) |cu| if (!mask_ground or active[cu]) {
                    if (comptime (jac_rep[ru] >> cu) & 1 != 0) {
                        sink.scatterJac(id, ru, cu, out[ru].ddxAt(cu));
                    } else if (comptime constEntry(D, ru, cu)) |e| {
                        if (comptime e.g != 0) if (contract.jacConstApplies(D, e, model, S.collapse_applied)) sink.scatterJac(id, ru, cu, e.g);
                    }
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
                if (comptime has_limit and @TypeOf(qo[ru]).lanes != 0) {
                    if (corr_live) qv += @reduce(.Add, head(W, qo[ru].toLanes(full).grad()) * corr);
                }
                sink.scatterQ(row, qv);
                if (comptime !SinkT.skip_c and q_pat[ru] != 0) {
                    if (!mask_ground or active[ru]) {
                        inline for (0..n_u) |cu| if (!mask_ground or active[cu]) {
                            if (comptime (q_rep[ru] >> cu) & 1 != 0) {
                                sink.scatterQJac(id, ru, cu, qo[ru].ddxAt(cu));
                            } else if (comptime constEntry(D, ru, cu)) |e| {
                                if (comptime e.c != 0) if (contract.jacConstApplies(D, e, model, S.collapse_applied)) sink.scatterQJac(id, ru, cu, e.c);
                            }
                        };
                    }
                }
            };
            if (comptime !SinkT.on_device) inline for (comptime lteSites(D), 0..) |k, j| {
                var qv = qs[k].v;
                if (comptime has_limit and @TypeOf(qs[k]).lanes != 0) {
                    if (corr_live) qv += @reduce(.Add, head(W, qs[k].toLanes(full).grad()) * corr);
                }
                sink.tapeQ(id, j, qv);
            };
        }
    }
}

/// The host's lane layout: sparse and padded to a power of two on the wide
/// basis, dense on the narrow one (at most 4 lanes, one ymm). Callgrind Ir
/// per instance, dense exact / sparse pow2, 100-instance DC sweeps:
/// hisimhv_va 23.7M/6.8M, hisim2_va 37.1M/13.7M, bsimsoi_va 7.36M/3.95M,
/// vbic13_4t 7.74M/3.83M, b3soidd 4.95M/3.02M, bsim4va 4.14M/2.32M,
/// hicumL2_va 4.53M/3.82M, gummel_poon 3.46M/1.96M, mesa 2.03M/1.58M, mos1
/// with RD/RS 1.33M/1.14M, bsim2 1.35M/0.99M, jfet 0.48M/0.37M, mes
/// 0.46M/0.34M; no wide model lost. On the narrow basis sparse lost up to
/// 2.8% (bsim1, mos2/3/9).
fn hostLayout(comptime narrow: bool) Layout {
    return if (narrow) .{ .dense = true } else .{ .dense = false, .pad = true };
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
fn evalQRange(comptime D: type, comptime S: type, sink: anytype, first: u32, end: u32, sim: SimState) void {
    @setEvalBranchQuota(1_000_000);
    @setFloatMode(.optimized);
    const n_u = comptime contract.nU(D);
    const q_row = comptime writtenRows(D, "q_rows");
    var id: u32 = first;
    while (id < end) : (id += 1) {
        var lx: [n_u]f64 = undefined;
        inline for (0..n_u) |u| lx[u] = sink.x(sink.gath(id, u));
        const qs = D.q(S, &lx, sink.model(id), sink.inst(id), sim);
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
fn limitRange(comptime D: type, sink: anytype, first: u32, end: u32, lim_active: bool, sim: SimState) f64 {
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
        const lm = D.limit(Real, sink.model(id), sink.inst(id), cur, old, sim);
        if (!lm.converged) flag = 1;
        inline for (0..n_u) |u| if (comptime (writes >> u) & 1 != 0) {
            sink.setLim(id, u, lm.x[u]);
        };
    }
    return flag;
}

/// Allocator for `ProtoStore` staging columns. Not the caller's allocator,
/// which is usually an arena: an arena keeps every abandoned list capacity
/// alive, measured at 73 MB on a 25,000-MOSFET deck. Separate per-column
/// lists grow by remap, never by copy, and `finalize` moves one column at a
/// time into the caller's allocator, freeing each staging column at once.
const staging_gpa = std.heap.smp_allocator;

/// Moves `items[k]` to `items[dst[k]]` for every k by following each cycle
/// of the permutation, one element in hand at a time. `seen` is scratch of
/// the same length; its contents on entry do not matter.
pub fn permuteInPlace(comptime T: type, items: []T, dst: []const u32, seen: []bool) void {
    @memset(seen, false);
    for (0..items.len) |start| {
        if (seen[start]) continue;
        var held = items[start];
        var j = start;
        while (true) {
            seen[j] = true;
            const d = dst[j];
            std.mem.swap(T, &held, &items[d]);
            j = d;
            if (j == start) break;
        }
    }
}

/// Construction-time rows for one device type: each instance's Model,
/// Instance and nodes, staged until `finalize` freezes them into a
/// `DeviceBatch(D)`. Reached through the type-erased `Proto`.
pub fn ProtoStore(comptime D: type) type {
    const n_u: usize = comptime contract.nU(D);
    return struct {
        /// One entry per instance in each column, owned by `staging_gpa`.
        models: std.ArrayList(D.Model) = .empty,
        instances: std.ArrayList(D.Instance) = .empty,
        nodes: std.ArrayList([n_u]u32) = .empty,

        const Self = @This();

        pub fn append(self: *Self, model: D.Model, instance: D.Instance, nodes: [n_u]u32) !void {
            try self.models.append(staging_gpa, model);
            errdefer _ = self.models.pop();
            try self.instances.append(staging_gpa, instance);
            errdefer _ = self.instances.pop();
            try self.nodes.append(staging_gpa, nodes);
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
            try pb.reserve(gpa, self.nodes.items.len * nnz);
            // Runtime loops: this runs once per batch, and unrolling n_u^2
            // for every device only costs comptime quota.
            for (self.nodes.items) |nd| {
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
            const count = std.math.cast(u32, self.nodes.items.len) orelse return error.TooManyInstances;
            const store = try gpa.create(DeviceBatch(D));

            store.count = count;
            store.sim = .{};
            store.owns_tapes = true;
            store.models = &.{};
            store.instances = &.{};
            store.gath = &.{};
            store.rhs_idx = &.{};
            store.slots = &.{};
            if (comptime has_q) store.q_tape = &.{};
            if (comptime has_attempt_decl) store.saved_models = &.{};
            if (comptime hasSpiceBreaks(D)) store.src_brk = &.{};
            if (comptime @hasDecl(D, "limit")) store.lim_x = &.{};
            if (comptime @hasDecl(D, "State")) store.states = &.{};
            errdefer DeviceBatch(D).hooks.deinit(store, gpa);
            // The staged rows can only be reordered before the copies below.
            if (comptime canNarrow(D)) store.narrow_count = try self.partitionCollapsed();

            // Each column moves to `gpa` at exact size and its staging copy
            // dies right after, so at most one column exists twice.
            store.models = try gpa.dupe(D.Model, self.models.items);
            self.models.deinit(staging_gpa);
            self.models = .empty;
            if (comptime has_attempt_decl) {
                store.saved_models = try gpa.alloc(D.Model, count);
                store.attempt_saved = false;
            }
            if (comptime @hasDecl(D, "nextBreakpoint") and skipsTimerState(D)) store.bp = .{ .lo = std.math.inf(f64), .hi = std.math.inf(f64) };
            if (comptime hasSpiceBreaks(D)) {
                store.src_brk = try gpa.alloc(SrcBrk, count);
                @memset(store.src_brk, .{});
            }
            if (comptime @hasDecl(D, "limit")) {
                // Full n_u stride and zeroed, although only `limitWrites`
                // slots are used: the GPU uploads the whole plane, and the
                // stride is part of the frozen tape layout.
                store.lim_x = try gpa.alloc(f64, count * n_u);
                @memset(store.lim_x, 0);
                store.lim_active = false;
            }
            store.instances = try gpa.dupe(D.Instance, self.instances.items);
            self.instances.deinit(staging_gpa);
            self.instances = .empty;

            store.gath = try gpa.alloc(u32, count * n_u);
            store.rhs_idx = try gpa.alloc(u32, count * n_u);
            store.slots = try gpa.alloc(u32, count * n_u * n_u);
            const flat_nodes = @as([*]const u32, @ptrCast(self.nodes.items.ptr))[0 .. count * n_u];
            buildTapes(flat_nodes, n_u, &jacPattern(D), pv, store.gath, store.rhs_idx, store.slots);
            if (comptime has_q) {
                store.q_tape = try gpa.alloc(f64, count * comptime lteSites(D).len);
                @memset(store.q_tape, 0);
            }
            self.nodes.deinit(staging_gpa);
            self.nodes = .empty;

            // `setup` before `initState`: both read the card, and only the
            // former fills `Instance.su`.
            if (comptime @hasDecl(D, "setup")) {
                for (0..count) |i| D.setup(Real, &store.models[i], &store.instances[i]);
            }
            if (comptime @hasDecl(D, "State")) {
                store.states = try gpa.alloc(D.State, count);
                for (0..count) |i| store.states[i] = D.initState(&store.models[i], &store.instances[i]);
                store.commitBirth();
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
            const len = self.nodes.items.len;
            const flags = try staging_gpa.alloc(bool, len);
            defer staging_gpa.free(flags);
            var n: usize = 0;
            for (self.models.items, self.instances.items, flags) |*m, *i, *f| {
                f.* = std.meta.eql(D.collapse(Real, m, i), D.collapse_full);
                if (f.*) n += 1;
            }
            if (n == 0 or n == len) return @intCast(n);
            // Row k moves to dst[k]; each column is permuted in place, so no
            // row is ever held twice.
            const dst = try staging_gpa.alloc(u32, len);
            defer staging_gpa.free(dst);
            var lo: u32 = 0;
            var hi: u32 = @intCast(n);
            for (flags, dst) |f, *d| {
                const next = if (f) &lo else &hi;
                d.* = next.*;
                next.* += 1;
            }
            permuteInPlace(D.Model, self.models.items, dst, flags);
            permuteInPlace(D.Instance, self.instances.items, dst, flags);
            permuteInPlace([n_u]u32, self.nodes.items, dst, flags);
            return @intCast(n);
        }

        /// `Proto.apply_perm`: renumbers staged nodes through `perm`; nodes
        /// past its end are left alone.
        pub fn applyPerm(ctx: *anyopaque, perm: []const u32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.nodes.items) |*nd| {
                inline for (0..n_u) |u| {
                    if (nd[u] < perm.len) nd[u] = perm[nd[u]];
                }
            }
        }

        /// `Proto.destroy`: frees the staging rows and the store itself.
        pub fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.models.deinit(staging_gpa);
            self.instances.deinit(staging_gpa);
            self.nodes.deinit(staging_gpa);
            gpa.destroy(self);
        }
    };
}

/// Models whose `updateState` only advances §5.10.3 timer bookkeeping
/// (`__analog_op__timer__*`). This host never reads it: breakpoints come from
/// the model-level `nextBreakpoint`, and the pass writes `bound_step = inf`
/// and `discontinuity_order = -1`, the Instance defaults. So the batch skips
/// `updateState`, the `bound_step` walk and `stateCtl`, whose twins then
/// never differ from the Instance. Opt-in by name because a
/// `$bound_step` or `$discontinuity` call leaves no trace in the Instance:
/// vsource.va and isource.va call neither (only `$abstime` and `@(timer)`);
/// re-check before adding one. `skipsTimerState` rejects any other state.
/// Measured on tran/rc_sinusoidal_startup: ~660 Ir per step.
const timer_only_state = std.StaticStringMap(void).initComptime(.{
    .{"vsource"},
    .{"isource"},
});

fn skipsTimerState(comptime D: type) bool {
    if (timer_only_state.get(comptime baseName(D)) == null) return false;
    // Two substring scans per field name; VerA emits one field per timer.
    @setEvalBranchQuota(200_000 + 2_000 * @typeInfo(D.Instance).@"struct".fields.len);
    for (@typeInfo(D.State).@"struct".fields) |f| {
        if (!@hasField(D.Instance, f.name))
            @compileError(@typeName(D) ++ " carries State beyond stateCtl twins (" ++ f.name ++ "); drop it from timer_only_state");
    }
    for (@typeInfo(D.Instance).@"struct".fields) |f| {
        if (std.mem.indexOf(u8, f.name, "__") != null and std.mem.indexOf(u8, f.name, "__analog_op__timer") == null)
            @compileError(@typeName(D) ++ " holds non-timer state (" ++ f.name ++ "); drop it from timer_only_state");
    }
    return true;
}

/// A source model whose PULSE and PWL corners follow ngspice's request-time
/// rounding (`spicePulseBreak`, `spicePwlBreak`) instead of VerA's timer
/// arithmetic.
fn hasSpiceBreaks(comptime D: type) bool {
    return @hasDecl(D, "nextBreakpoint") and skipsTimerState(D) and @hasField(D.Model, "pulse_td");
}

const SrcBrk = struct { req: f64 = std.math.inf(f64), at: f64 = std.math.inf(f64) };

/// Models whose ngspice load extrapolates the first Newton iterate of a
/// transient step over CKTdeltaOld[2], the step two back, where the host
/// and the other models use the previous step (hfetload.c:129). Every
/// branch voltage hfet1 reads lies between its internal nodes gp/sp/dp, so
/// re-predicting only those reproduces ngspice's and leaves the ports'
/// prediction to the other devices on them. mesaload.c:150 and
/// hfet2load.c:98 predict the same way; mesa stays off because it moved
/// tran/device_mesa_oscillator away from ngspice (52.5x -> 57.7x), and
/// hfet2 reads its gate port directly.
const delta_old2_predict = std.StaticStringMap(void).initComptime(.{.{"hfet1"}});

fn predictsOverDeltaOld2(comptime D: type) bool {
    return delta_old2_predict.get(comptime baseName(D)) != null;
}

/// Models whose ngspice load flags non-convergence itself when a branch
/// current misses its linear prediction from the previous iterate
/// (hfetload.c:389), checked host-side by `Circuit.loadCheck`. The MOS,
/// BJT and diode tests are dead in ngspice (NIiter overwrites CKTnoncon).
/// hfet2load.c:270 and mesaload.c:388 have the same test, but it moved
/// tran/device_mesa_oscillator away from ngspice (52.5x -> 65x: mesa.va's
/// series resistors are flow unknowns ngspice does not have, and their
/// delta test already adds an iteration) and op/device_hfet2 only by
/// roundoff, so both stay off.
const load_check = std.StaticStringMap(void).initComptime(.{.{"hfet1"}});

/// ngspice's PULSE breakpoint (vsrcacct.c:48-121, isrcacct.c the same): the
/// corner after `tq`, requested at the accepted time `t_acc <= tq` and
/// rounded as ngspice rounds it, `t_acc + (corner - phase(t_acc))`. VerA's
/// `td + tr + pw + tf` can land one ulp away, which moves a breakpoint across
/// an integer picosecond and changes every TXL/CPL delayed read after it
/// (txlload.c truncates time to ps). Null when the result is not after `tq`,
/// i.e. `t_acc` is not a time ngspice would have asked at, and for any
/// waveform but PULSE. Nonzero PHASE is left to the timers too: ngspice gives
/// it a different meaning outside xs mode. The widths are vsource.va's
/// P_TR/P_TF/P_PW/P_PER.
fn spicePulseBreak(m: anytype, t_acc: f64, tq: f64) ?f64 {
    if (m.waveform != 1 or m.pulse_phase != 0) return null;
    const tr = @max(m.pulse_tr, 1.0e-12);
    const tf = @max(m.pulse_tf, 1.0e-12);
    const pw = @max(m.pulse_pw, 0.0) + @max(-m.pulse_pw, 0.0) * 1.0e30;
    const per = @max(m.pulse_per, tr + pw + tf + 1.0e-12);
    var time = t_acc - m.pulse_td;
    if (time >= per) time -= per * @floor(time / per);
    // ngspice's `atime = time + CKTminBreak`; the host asks at t + minBreak.
    const atime = time + (tq - t_acc);
    const corner: f64 = if (atime < 0.0) 0.0 else if (atime < tr) tr else if (atime < tr + pw) tr + pw else if (atime < tr + pw + tf) tr + pw + tf else per;
    const bp = t_acc + (corner - time);
    return if (bp > tq) bp else null;
}

/// ngspice's PWL breakpoint for a V source (vsrcacct.c:167-216): the first
/// table time `t_k` after the request, rounded from the accepted time
/// `t_acc <= tq` as `t_acc + (t_k - local)`, where `local` is `t_acc - td`
/// folded into `[r, t_last]` by `r=`. VerA's timers give `t_k + td`, one ulp
/// away at times, and add the PULSE timers' corners at TD and TD + TR, which
/// ngspice does not have. Past the last point of a non-repeating table there
/// is no breakpoint (inf). Null when the rounded time is not after `tq`
/// (an anchor ngspice would not ask at), and for any other waveform. The
/// repeat gate is vsource.va's own, so breakpoints follow the waveform it
/// computes.
fn spicePwlBreak(m: anytype, t_acc: f64, tq: f64) ?f64 {
    const T = @TypeOf(m.*);
    if (m.waveform != 4 or m.pwl_len <= 0) return null;
    // Slot `k` of the flattened `pwl_times[]`, named as in
    // frontend/builder.zig pwlSlot.
    @setEvalBranchQuota(200_000);
    const cap = comptime blk: {
        var c: usize = 0;
        while (@hasField(T, std.fmt.comptimePrint("pwl_timesZ5b{d}Z5d", .{c}))) c += 1;
        break :blk c;
    };
    var ts: [cap]f64 = undefined;
    inline for (0..cap) |k| ts[k] = @field(m.*, std.fmt.comptimePrint("pwl_timesZ5b{d}Z5d", .{k}));
    const n: usize = @min(@as(usize, @intCast(m.pwl_len)), cap);
    const t_last = ts[n - 1];
    const r = m.pwl_repeat;
    const repeats = r >= 0.0 and n > 1 and t_last > r;
    const period = t_last - r;
    var time = t_acc - m.pwl_td;
    if (time > t_last) {
        if (!repeats) return std.math.inf(f64);
        time -= r;
        time -= period * @floor(time / period);
        time += r;
    }
    // ngspice's `atime = time + CKTminBreak`; the host asks at t + minBreak.
    const atime = time + (tq - t_acc);
    const corner = for (ts[0..n]) |c| {
        if (c > atime) break c;
    } else if (!repeats) return std.math.inf(f64) else for (ts[0..n]) |c| {
        // At the end of a repeating table ngspice sets nothing and asks again
        // one step later, after the fold; this names the same corner now.
        if (c + period > atime) break c + period;
    } else return null;
    const bp = t_acc + (corner - time);
    return if (bp > tq) bp else null;
}

test "spicePwlBreak rounds from the request time as ngspice does" {
    const M = struct {
        waveform: i64 = 4,
        pwl_len: i64 = 3,
        pwl_repeat: f64 = -1,
        pwl_td: f64 = 0,
        pwl_timesZ5b0Z5d: f64 = 0,
        pwl_timesZ5b1Z5d: f64 = 1.0e-9,
        pwl_timesZ5b2Z5d: f64 = 3.1e-9,
        pwl_timesZ5b3Z5d: f64 = 0,
    };
    const mb = 1e-20;
    var m: M = .{};
    try std.testing.expectEqual(@as(?f64, 1.0e-9), spicePwlBreak(&m, 0, mb));
    // `t_acc + (t_k - t_acc)`, not the table time itself.
    const t_acc = 0.7e-9;
    try std.testing.expectEqual(@as(?f64, t_acc + (3.1e-9 - t_acc)), spicePwlBreak(&m, t_acc, 1.0e-9 + mb));
    try std.testing.expectEqual(@as(?f64, std.math.inf(f64)), spicePwlBreak(&m, 3.1e-9, 3.1e-9 + mb));
    // TD delays every corner; the accepted time rounds it.
    m.pwl_td = 0.3e-9;
    try std.testing.expectEqual(@as(?f64, 0.3e-9), spicePwlBreak(&m, 0, mb));
    try std.testing.expectEqual(@as(?f64, 0.3e-9 + 1.0e-9), spicePwlBreak(&m, 0.3e-9, 0.3e-9 + mb));
    // `r=1n`: past the end the table replays [1n, 3.1n], period 2.1n.
    m = .{ .pwl_repeat = 1.0e-9 };
    const bp = spicePwlBreak(&m, 3.1e-9, 3.1e-9 + mb).?;
    try std.testing.expectApproxEqRel(@as(f64, 5.2e-9), bp, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 7.3e-9), spicePwlBreak(&m, bp, bp + mb).?, 1e-12);
    // `r=0` repeats the whole table (period 3.1n); a negative `r` is no repeat.
    m = .{ .pwl_repeat = 0 };
    try std.testing.expectApproxEqRel(@as(f64, 4.1e-9), spicePwlBreak(&m, 3.1e-9, 3.1e-9 + mb).?, 1e-12);
    // Not PWL: the caller falls back.
    m.waveform = 1;
    try std.testing.expectEqual(@as(?f64, null), spicePwlBreak(&m, 0, mb));
}

test "spicePulseBreak rounds from the request time as ngspice does" {
    // tran/bench_tline_txl1_1_line's VS: PULSE(0 5 15.9n 0.2n 0.2n 15.8n 32n).
    const m = .{ .waveform = @as(i64, 1), .pulse_phase = 0.0, .pulse_td = 15.9e-9, .pulse_tr = 0.2e-9, .pulse_tf = 0.2e-9, .pulse_pw = 15.8e-9, .pulse_per = 32e-9 };
    const mb = 1e-20;
    try std.testing.expectEqual(@as(?f64, 15.9e-9), spicePulseBreak(m, 0, mb));
    try std.testing.expectEqual(@as(?f64, 1.61e-8), spicePulseBreak(m, 15.9e-9, 15.9e-9 + mb));
    // The fall's end: ngspice lands one ulp below td+tr+pw+tf = 3.21e-8,
    // at 32099.999... ps, which txlload.c truncates to 32099.
    try std.testing.expectEqual(@as(?f64, 3.2099999999999996e-08), spicePulseBreak(m, 3.19e-8, 3.19e-8 + mb));
    try std.testing.expectEqual(@as(?f64, 4.79e-8), spicePulseBreak(m, 3.2099999999999996e-08, 3.2099999999999996e-08 + mb));
    // An anchor ngspice would not ask at yields nothing (caller falls back).
    try std.testing.expectEqual(@as(?f64, null), spicePulseBreak(m, 0, 60e-9));
}

/// Whether D's `updateState` pushes delay-line history, which only accepted
/// transient points may feed: LRM §4.5 `absdelay`, and the native lines that
/// declare `unrevertible_state` (they have no `stateCtl`). A VerA ring would
/// revert, but a push at the operating point seeds it with a static solve
/// (multi_analysis/bench_hb_tline_guard: 6.7e-8 to 0.66 of its tolerance).
/// VerA devices are recognized by the `__analog_op__absdelay__` infix its
/// naming scheme puts on an absdelay operator's Instance fields. A bare
/// `__absdelay__` also matches a field that merely carries the name (a
/// Verilog device's), and a device routed to `commit_state` never runs
/// `updateState` at the operating point, so its fixed point never forms.
// ponytail: field-name matching until VerA's contract marks delay history.
fn hasAbsdelayState(comptime D: type) bool {
    if (@hasDecl(D, "unrevertible_state")) return D.unrevertible_state;
    return hasInstanceField(D, "__analog_op__absdelay__");
}

/// D's §4.5.4 `idt` operator unknowns, as local indices. VerA spells the
/// k-th one `idt$k`, escaped to `idtZ24k` in `D.U`.
// ponytail: name matching, as above, until VerA's contract marks operator
// unknowns.
fn idtUnknowns(comptime D: type) []const u32 {
    comptime {
        var out: []const u32 = &.{};
        if (@hasDecl(D, "U")) for (@typeInfo(D.U).@"enum".fields) |f| {
            if (std.mem.startsWith(u8, f.name, "idtZ24")) out = out ++ [_]u32{f.value};
        };
        const final = out[0..out.len].*;
        return &final;
    }
}

/// Whether the host reads D's live per-instance timer schedule
/// (`pendingBreakpoint`, which holds §5.10.3.3 start times computed during
/// the solve). Not for timer-only models, whose `updateState` never runs so
/// `__next` is stale, nor for GPU-resident types, whose host Instance is.
fn walksPending(comptime D: type) bool {
    return @hasDecl(D, "pendingBreakpoint") and !skipsTimerState(D) and !hasCtlKernel(D);
}

/// Whether D's history is §5.10 held variables and no analog operator (no
/// cross/above FSM, delay line or timer).
fn holdsOnlyHeld(comptime D: type) bool {
    return hasInstanceField(D, "__held__") and !hasInstanceField(D, "__analog_op__");
}

/// Whether some Instance field of D contains `infix`.
fn hasInstanceField(comptime D: type, comptime infix: []const u8) bool {
    if (!@hasDecl(D, "Instance")) return false;
    // hisim Instances have hundreds of long field names.
    @setEvalBranchQuota(2_000_000);
    inline for (@typeInfo(D.Instance).@"struct".fields) |f| {
        if (std.mem.indexOf(u8, f.name, infix) != null) return true;
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
    const narrowable = canNarrow(D);
    // Only timer-only models: their breakpoints are pure in (model, t).
    // Native lines rewrite `Model.brk` as they step, so theirs are not.
    const has_bp = @hasDecl(D, "nextBreakpoint") and skipsTimerState(D);
    const has_src_brk = hasSpiceBreaks(D);
    // isrcacct.c requests the raw PWL table times, so only the V source
    // rounds its PWL corners.
    const is_vsource = comptime std.mem.eql(u8, baseName(D), "vsource");
    const has_ac_dyn = @hasDecl(D, "ac_dyn_slots");

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
        /// `nextBreakpointFn` returned `hi` (inf for none) at `lo`. That
        /// answer holds for every `t` in `[lo, hi)`: no fire lies strictly
        /// between. `lo = inf` is empty. Every model write goes through
        /// `reprep` or `applyAttempt`, which empty it.
        bp: if (has_bp) struct { lo: f64, hi: f64 } else void,
        /// Per model, ngspice's VSRCbreak_time: the PULSE or PWL breakpoint `at`
        /// requested at query time `req`, kept until a query reaches it
        /// (or goes back before `req`, a new run). `req = inf` is empty.
        src_brk: if (has_src_brk) []SrcBrk else void,
        lim_x: if (has_limit) []f64 else void,
        lim_active: if (has_limit) bool else void,
        /// The analysis state every device call receives; `eval` takes `t`
        /// from its own argument.
        sim: SimState = .{},
        instances: []D.Instance,
        states: if (has_state) []D.State else void,
        gath: []u32,
        rhs_idx: []u32,
        slots: []u32,
        /// Charge per instance and LTE site, indexed `id * lteSites(D).len +
        /// j`. Written by `Sink.tapeQ` on the host only; see `Hooks.q_tape`.
        q_tape: if (has_q) []f64 else void,

        const Self = @This();

        const noise_names = if (@hasDecl(D, "noise_gens")) blk: {
            var names: [D.noise_gens.len][]const u8 = undefined;
            for (D.noise_gens, &names) |gen, *name| name.* = if (@hasField(@TypeOf(gen), "name")) gen.name else "";
            const frozen = names;
            break :blk frozen;
        } else {};

        pub const hooks: Hooks = .{
            .instantiate = instantiate,
            .snapshot = snapshot,
            .copy_state = copyState,
            .set_limit_active = if (has_limit) setLimitActive else null,
            .scatter_bounds = scatterBounds,
            .q_tape = if (has_q) qTape else null,
            .eval_q = if (has_q) evalQOnly else null,
            .apply_limits = if (has_limit) applyLimits else null,
            .clear_limits = if (has_limit) clearLimits else null,
            .advance_iteration = if (@hasDecl(D, "advanceIteration")) advanceIteration else null,
            .check_convergence = if (@hasDecl(D, "checkConvergence")) checkConvergence else null,
            .predict_first_iterate = if (predictsOverDeltaOld2(D)) predictFirstIterate else null,
            .mark_load_check_rows = if (load_check.get(baseName(D)) != null) markInternalRows else null,
            .seed = if (@hasDecl(D, "seed")) seedFn else null,
            .seed_ic = if (idtUnknowns(D).len != 0) seedIc else null,
            .mark_current_rows = if (@hasDecl(D, "u_kinds")) markCurrentRows else null,
            // Delay history runs once per accepted point; everything else
            // per converged solve. See `Hooks.commit_state`.
            .update_state = if (@hasDecl(D, "updateState") and !hasAbsdelayState(D) and !skipsTimerState(D)) updateState else null,
            .commit_state = if (@hasDecl(D, "updateState") and hasAbsdelayState(D)) updateState else null,
            .state_ctl = if (@hasDecl(D, "stateCtl") and !skipsTimerState(D)) stateCtl else null,
            // Only `updateState` writes `bound_step`.
            .bound_step = if (@hasDecl(D, "updateState") and @hasField(D.Instance, "bound_step") and !skipsTimerState(D)) boundStep else null,
            .set_temp = if (@hasField(D.Instance, "temperature")) setTemp else null,
            .set_sim_state = setSimState,
            .min_delay = if (@hasDecl(D, "delays")) minDelay else null,
            .next_breakpoint = if (@hasDecl(D, "nextBreakpoint") or walksPending(D)) nextBreakpointFn else null,
            .collect_params = collectParams,
            // A generator is only priced by the device's own `noisePsd`.
            .collect_noise = if (@hasDecl(D, "noise_gens")) blk: {
                if (!@hasDecl(D, "noisePsd")) @compileError(@typeName(D) ++
                    " declares noise_gens without noisePsd; see docs/devices/noise-contract.md §3");
                break :blk collectNoise;
            } else null,
            .noise_names = if (@hasDecl(D, "noise_gens")) &noise_names else &.{},
            .collect_ac_dyn = if (has_ac_dyn) collectAcDyn else null,
            .ac_dyn = if (has_ac_dyn) acDyn else null,
            .recompute = if (@hasDecl(D, "collapse") or @hasDecl(D, "precompute") or @hasDecl(D, "setup") or has_bp) recomputePrecomputed else null,
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
            @call(.always_inline, evalQRange, .{ D, RealFor(@hasDecl(D, "collapse")), &sink, first, last, self.simAt(t) });
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
            const sim = self.simAt(t);
            if (comptime narrowable) {
                // A ParEval slice may straddle the partition boundary.
                const split = std.math.clamp(self.narrow_count, first, last);
                if (split > first) evalRange(D, true, F, hostLayout(true), &sink, first, split, sim, limiting);
                if (last > split) evalRange(D, false, F, hostLayout(false), &sink, split, last, sim, limiting);
            } else {
                evalRange(D, false, F, hostLayout(false), &sink, first, last, sim, limiting);
            }
        }

        /// The stored analysis state at eval time `t`.
        fn simAt(self: *const Self, t: f64) SimState {
            var sim = self.sim;
            sim.t = t;
            return sim;
        }

        fn localX(self: *Self, x: []const f64, id: usize) [n_u]f64 {
            var out: [n_u]f64 = undefined;
            inline for (0..n_u) |u| out[u] = x[self.gath[id * n_u + u]];
            return out;
        }

        fn advanceIteration(ctx: *anyopaque, previous_x: []const f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id|
                D.advanceIteration(Real, &self.models[id], &self.instances[id], self.localX(previous_x, id), self.sim);
        }

        fn checkConvergence(ctx: *anyopaque, x: []const f64) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                if (!D.checkConvergence(Real, &self.models[id], &self.instances[id], self.localX(x, id), self.sim)) return false;
            }
            return true;
        }

        fn markInternalRows(ctx: *anyopaque, mask: []bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                inline for (D.num_ports..n_u) |u| if (comptime D.u_kinds[u] == .voltage) {
                    const row = self.gath[id * n_u + u];
                    if (row != GROUND) mask[row] = true;
                };
            }
        }

        fn predictFirstIterate(ctx: *anyopaque, trial: []f64, cur: []const f64, prev: []const f64, xfact: f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                inline for (D.num_ports..n_u) |u| if (comptime D.u_kinds[u] == .voltage) {
                    const row = self.gath[id * n_u + u];
                    if (row != GROUND) trial[row] = cur[row] + xfact * (cur[row] - prev[row]);
                };
            }
        }

        fn seedFn(ctx: *anyopaque, x: []f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime has_limit) {
                // Only the slots `limitRange` maintains are ever read back.
                const writes = comptime contract.limitWrites(D);
                for (0..self.count) |id| {
                    const sv = D.seed(Real, &self.models[id], &self.instances[id], self.sim);
                    inline for (0..n_u) |u| if (comptime (writes >> u) & 1 != 0) {
                        self.lim_x[id * n_u + u] = sv[u] orelse x[self.gath[id * n_u + u]];
                    };
                }
                self.lim_active = true;
            }
        }

        fn seedIc(ctx: *anyopaque, x: []f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const R = RealFor(@hasDecl(D, "collapse"));
            for (0..self.count) |id| inline for (comptime idtUnknowns(D)) |u| {
                const gi = self.gath[id * n_u + u];
                if (gi != GROUND) {
                    // The static row is s - ic when the idt has an ic (slope
                    // 1) and does not read s otherwise (slope 0). One exact
                    // Newton step on the row lands s on ic.
                    var lx = self.localX(x, id);
                    const r0 = D.eval(R, &lx, &self.models[id], &self.instances[id], self.sim)[u].v;
                    lx[u] += 1.0;
                    const slope = D.eval(R, &lx, &self.models[id], &self.instances[id], self.sim)[u].v - r0;
                    if (slope != 0) x[gi] -= r0 / slope;
                }
            };
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
            const any = limitRange(D, &sink, 0, @intCast(self.count), self.lim_active, self.sim);
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
        /// `commit_state`), not per Newton iteration.
        fn updateState(ctx: *anyopaque, x: []const f64) ?f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var min_reject: ?f64 = null;
            for (0..self.count) |id| {
                const lx = self.localX(x, id);
                switch (D.updateState(Real, &self.models[id], &self.instances[id], lx, &self.states[id], self.sim)) {
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

        /// Commits the initial state, so a `stateCtl(.revert)` before the
        /// first accepted point restores it rather than the `State` defaults.
        fn commitBirth(self: *Self) void {
            if (comptime @hasDecl(D, "stateCtl")) _ = stateCtl(self, .commit);
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

        fn setSimState(ctx: *anyopaque, st: SimState) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.sim = st;
        }

        fn applyAttempt(ctx: *anyopaque, lambda: f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (!self.attempt_saved) {
                @memcpy(self.saved_models, self.models);
                self.attempt_saved = true;
            }
            for (self.models, self.saved_models) |*m, s| m.* = D.attempt(s, lambda);
            if (comptime has_bp) self.bp.lo = std.math.inf(f64);
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
                    const col = D.collapse(Real, model, inst);
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
            if (comptime has_bp) self.bp.lo = std.math.inf(f64);
            if (comptime has_src_brk) @memset(self.src_brk, .{});
            if (comptime @hasDecl(D, "setup")) {
                for (self.instances, self.models) |*inst, *mdl| D.setup(Real, mdl, inst);
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

        /// The earliest model or instance breakpoint strictly after `t`. The
        /// transient asks once per step; for a timer-only model (`has_bp`)
        /// the answer only moves when `t` reaches it, so the walk (68 timers
        /// per vsource model, ~425 Ir) runs once per breakpoint instead. A
        /// PULSE or V-source PWL corner rounds from the accepted time `sim.t`
        /// (the transient asks right after accepting it), as ngspice's
        /// VSRCaccept does.
        fn nextBreakpointFn(ctx: *anyopaque, t: f64) ?f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime has_bp) {
                if (self.bp.lo <= t and t < self.bp.hi) return if (self.bp.hi == std.math.inf(f64)) null else self.bp.hi;
            }
            const t_acc = if (self.sim.kind == .tran and self.sim.t <= t) self.sim.t else t;
            var best: f64 = std.math.inf(f64);
            if (comptime @hasDecl(D, "nextBreakpoint")) for (self.models, 0..) |*m, i| {
                if (comptime has_src_brk) {
                    const b = &self.src_brk[i];
                    if (t < b.req or t >= b.at)
                        b.* = .{ .req = t, .at = spicePulseBreak(m, t_acc, t) orelse
                            (if (comptime is_vsource) spicePwlBreak(m, t_acc, t) else null) orelse
                            D.nextBreakpoint(m, t) orelse std.math.inf(f64) };
                    best = @min(best, b.at);
                    continue;
                }
                if (D.nextBreakpoint(m, t)) |bp| best = @min(best, bp);
            };
            // §5.10.3.3 re-armed fire times exist only in the committed
            // Instance, so every commit can move them: no cache.
            if (comptime walksPending(D)) for (self.instances) |*inst| {
                if (D.pendingBreakpoint(inst, t)) |bp| best = @min(best, bp);
            };
            if (comptime has_bp) self.bp = .{ .lo = t, .hi = best };
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
                    else if (isVera(D))
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
            if (isVera(D) and T == D.Instance) {
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
                const terms = D.noisePsd(Real, self.localX(x, id), &self.models[id], &self.instances[id], self.sim);
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

        fn collectAcDyn(ctx: *anyopaque, gpa: std.mem.Allocator, list: *std.ArrayList(u32)) ir.DeviceResult(void) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            list.ensureUnusedCapacity(gpa, self.count * D.ac_dyn_slots.len) catch return .out_of_memory;
            for (0..self.count) |id| {
                for (D.ac_dyn_slots) |s| list.appendAssumeCapacity(self.slots[id * n_u * n_u + s]);
            }
            return .{ .ok = {} };
        }

        /// `Hooks.ac_dyn`: one `D.acDyn` call per instance and lane-width
        /// chunk of `omegas`, a ragged tail padded with its last ω.
        fn acDyn(ctx: *anyopaque, x: []const f64, omegas: []const f64, re: []f64, im: []f64) usize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const K = D.ac_dyn_slots.len;
            const LW = std.simd.suggestVectorLength(f64) orelse 1;
            const V = @Vector(LW, f64);
            const nw = omegas.len;
            const sim = self.sim;
            for (0..self.count) |id| {
                const lx = self.localX(x, id);
                var j: usize = 0;
                while (j < nw) : (j += LW) {
                    const cnt = @min(LW, nw - j);
                    var ow: [LW]f64 = undefined;
                    for (0..LW) |l| ow[l] = omegas[j + @min(l, cnt - 1)];
                    var out: [K]std.math.Complex(V) = undefined;
                    D.acDyn(V, &self.models[id], &self.instances[id], &lx, sim, ow, &out);
                    for (out, 0..) |o, k| {
                        const e = (id * K + k) * nw + j;
                        const r: [LW]f64 = o.re;
                        const i: [LW]f64 = o.im;
                        @memcpy(re[e..][0..cnt], r[0..cnt]);
                        @memcpy(im[e..][0..cnt], i[0..cnt]);
                    }
                }
            }
            return self.count * K;
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

        fn copyState(dst_ctx: *anyopaque, src_ctx: *const anyopaque) void {
            const dst: *Self = @ptrCast(@alignCast(dst_ctx));
            const src: *const Self = @ptrCast(@alignCast(src_ctx));
            @memcpy(dst.models, src.models);
            @memcpy(dst.instances, src.instances);
            if (comptime has_state) @memcpy(dst.states, src.states);
            if (comptime has_q) @memcpy(dst.q_tape, src.q_tape);
            if (comptime has_attempt) {
                @memcpy(dst.saved_models, src.saved_models);
                dst.attempt_saved = src.attempt_saved;
            }
            if (comptime has_limit) {
                @memcpy(dst.lim_x, src.lim_x);
                dst.lim_active = src.lim_active;
            }
            if (comptime has_bp) dst.bp = src.bp;
            if (comptime has_src_brk) @memcpy(dst.src_brk, src.src_brk);
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
            if (comptime has_src_brk) self.src_brk = &.{};
            errdefer destroy(self, gpa);

            // Model/Instance are POD, so a byte copy is a deep copy.
            self.models = try gpa.dupe(D.Model, template.models);
            self.instances = try gpa.dupe(D.Instance, template.instances);
            if (comptime has_src_brk) self.src_brk = try gpa.dupe(SrcBrk, template.src_brk);
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
                    self.commitBirth();
                }
            }
            return self.binding();
        }

        fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            gpa.free(self.models);
            if (comptime has_attempt) gpa.free(self.saved_models);
            if (comptime has_limit) gpa.free(self.lim_x);
            if (comptime has_src_brk) gpa.free(self.src_brk);
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

/// Whether VerA generated D (every VerA device declares `lane_masks`; the
/// hand-written ones do not). A VerA Instance holds runtime state beside its
/// two parameters.
fn isVera(comptime D: type) bool {
    return @hasDecl(D, "lane_masks");
}

/// Whether D gets GPU kernels. Excluded, and kept on the host:
/// - `mutable_eval` devices, whose first-call snapshots need exclusive
///   evaluation;
/// - Newton-history devices (`advanceIteration`/`checkConvergence`), whose
///   `limiter_previous` the host advances on its own Instance copy;
/// - held variables (`holdsOnlyHeld`) together with `limit`: the launcher
///   runs a held device's `StateKernel` once per converged solve, not fused
///   into the per-iterate limit pass, which would latch Newton iterates;
/// - otherwise, `State` without `limit` (sources and FSMs whose eval reads
///   host-owned per-attempt state).
/// `State` with `limit` is the path-latch pattern that `StateKernel` and
/// `CtlKernel` run on the device; a held device's `State` is that latch plus
/// its held variables, all in the resident Instance. `SimState` is a kernel
/// argument, so a core that reads `analysis()` or `$abstime` (the Meyer MOS
/// models, jfet2) runs resident too.
// ponytail: the State-with-limit rule is decl correlation, not proof;
// `StateKernel` flags any non-`.ok` `updateState` so a device that breaks it
// falls back to the CPU instead of running wrong.
fn gpuEligible(comptime D: type) bool {
    if (@hasDecl(D, "mutable_eval") and D.mutable_eval) return false;
    if (@hasDecl(D, "advanceIteration") or @hasDecl(D, "checkConvergence")) return false;
    // ponytail: vbic13_4t holds variables and limits, so it stays on the
    // host; split `StateKernel` into its two halves to bring it over.
    if (holdsOnlyHeld(D)) return !@hasDecl(D, "limit");
    return @hasDecl(D, "limit") or !@hasDecl(D, "State");
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

/// Not carried in the frozen `GpuPayload`: the host derives it from
/// `kernelName`, so the prefix swap there must match this.
fn qTapeKernelName(comptime D: type) [:0]const u8 {
    return "arp_qtp_" ++ comptime baseName(D);
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

        // `Circuit.computeBaseline` stamps only batches whose whole Jacobian
        // is constant (`Batch.has_const_jacobian`). A lone constant half has
        // no baseline copy, so skipping it would drop it from the Newton
        // matrix: an idt's charge (C = 1) beside a non-constant G, say.
        const in_baseline = const_g and (!@hasDecl(D, "q") or const_c);
        pub const skip_g = skip_const and in_baseline;
        pub const skip_c = skip_const and in_baseline;
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
            sim: SimState,
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
            evalRange(D, false, gpuJacFloat(D), .{ .dense = true }, &sink, id, id + 1, sim, limiting != 0);
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
            sim: SimState,
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
                const lm = D.limit(Real, model, inst_c, cur, old, sim);
                if (!lm.converged) flag |= 1;
                inline for (0..n_u) |u| if (comptime (writes >> u) & 1 != 0) {
                    lim[id * n_u + u] = lm.x[u];
                };
            }
            if (comptime has_state) {
                const inst_m: *D.Instance = @addrSpaceCast(&instances[id]);
                const st: *StateT = @addrSpaceCast(&states[id]);
                switch (D.updateState(Real, model, inst_m, cur, st, sim)) {
                    .ok => {},
                    else => flag |= 2,
                }
            }
            if (flag != 0) _ = @atomicRmw(u32, &flags[0], .Or, flag, .monotonic);
        }
    };
}

/// Segmented sum, one output cell per thread: `out[i] = sum(in[seg[2i] ..
/// seg[2i + 1]])`. The launcher lays each cell's staging contributions out
/// contiguously in tape order, so this sums them in the order the host stamp
/// does, on every launch. Explicit ends let ranges skip the staging cells
/// that no plane cell reads (ground and structural-zero contributions). The
/// output is overwritten, not accumulated.
///
/// Strict left-to-right with one accumulator on purpose: no `.optimized`
/// float mode, and no interleaved partial sums. The tape emits rows in `ru`
/// order, so interleaving would group all the +1.8 contributions of a supply
/// row in one lane and all the -1.8 in another, measured at 4e-12 error
/// against 1.6e-17 in order. The launcher bounds the chain length instead.
/// The loads go out eight at a time ahead of the in-order adds, so a thread
/// waits on memory once per eight contributions, not once per contribution.
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
            const i: usize = @intCast(tid);
            var sum: f64 = 0;
            var k = seg[2 * i];
            const end = seg[2 * i + 1];
            while (k + 8 <= end) : (k += 8) {
                var v: [8]f64 = undefined;
                inline for (&v, 0..) |*e, j| e.* = stage[k + j];
                inline for (v) |e| sum += e;
            }
            while (k < end) : (k += 1) sum += stage[k];
            plane[i] = sum;
        }
    };
}

/// GPU charge-tape kernel, one thread per instance: the LTE charges
/// `evalQRange` records on the host, at `xs`, into `tape` (`count *
/// lteSites(D).len`). Same `RealFor` basis, so the charges match the host
/// tape to the device's rounding. The launcher runs it lazily, once per
/// transient step, instead of widening the frozen eval kernel's arguments.
fn QTapeKernel(comptime D: type, comptime block_size: u32) type {
    const n_u: usize = comptime contract.nU(D);
    const sites = comptime lteSites(D);
    return struct {
        pub fn run(
            count: u64,
            sim: SimState,
            xs: gompute.GlobalPtr(f64),
            gath: gompute.GlobalPtr(u32),
            models: gompute.GlobalPtr(D.Model),
            instances: gompute.GlobalPtr(D.Instance),
            tape: gompute.GlobalPtr(f64),
        ) callconv(gompute.kernel_callconv) void {
            @setFloatMode(.optimized);
            const tid = gompute.globalIdX(block_size);
            if (tid >= count) return;
            const id: usize = @intCast(tid);
            const S = RealFor(@hasDecl(D, "collapse"));
            var lx: [n_u]f64 = undefined;
            inline for (0..n_u) |u| lx[u] = xs[gath[id * n_u + u]];
            const qs = D.q(S, &lx, @addrSpaceCast(&models[id]), @addrSpaceCast(&instances[id]), sim);
            inline for (sites, 0..) |k, j| tape[id * sites.len + j] = qs[k].v;
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
    /// Every small-signal matrix adds the device's `acDyn` terms
    /// (`Hooks.ac_dyn`).
    pub const calls_ac_dyn = true;
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
            D.derive(Real, m);
        }

        fn collapseFn(model: [*]const u8, instance: [*]const u8, out: [*]i32) void {
            const m: *const D.Model = @ptrCast(@alignCast(model));
            const i: *const D.Instance = @ptrCast(@alignCast(instance));
            const col = D.collapse(Real, m, i);
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
                    if (@hasDecl(D, "q")) gompute.exportRaw(qTapeKernelName(D), &QTapeKernel(D, block_size).run);
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
    .Real = Real,
    .Sparse = DualFor(f64, &.{ 0, 1 }, hostLayout(false), false),
    .SparseF32 = DualFor(f32, &.{ 0, 1 }, hostLayout(false), false),
    .anyNonzero = anyNonzero,
} else {};
