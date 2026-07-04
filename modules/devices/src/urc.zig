const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Terminals: 3 external (p1, p2, ref) + 9 internal ladder nodes (n1..n9)
// ============================================================================

pub const U = enum(u8) {
    p1 = 0,
    p2 = 1,
    ref_ = 2,
    n1 = 3,
    n2 = 4,
    n3 = 5,
    n4 = 6,
    n5 = 7,
    n6 = 8,
    n7 = 9,
    n8 = 10,
    n9 = 11,
};

pub const num_ports: usize = 3;

// ============================================================================
// Internal constants
// ============================================================================

const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const VT: f64 = 0.02586; // k_B * 300.15 / q
const MAX_SECTIONS: usize = 10;

// ============================================================================
// Model parameters
// ============================================================================

pub const Model = struct {
    k: f32 = 1.5,
    fmax: f32 = 1.0e9,
    rperl: f32 = 1000.0,
    cperl: f32 = 1.0e-12,
    isperl: f32 = 0.0,
    rsperl: f32 = 0.0,
};

// ============================================================================
// Instance parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 1.0,
    n: i32 = 0,
};

// ============================================================================
// Ladder node index mapping
//
// The ladder consists of N+1 nodes indexed 0..N:
//   position 0 => p1
//   position 1 => n1  (internal)
//   position 2 => n2  (internal)
//   ...
//   position N-1 => n(N-1) (internal)
//   position N   => p2
//
// Section i (1-indexed) has a series resistor from position (i-1) to position (i),
// and a shunt element from position (i) to ref.
// ============================================================================

/// Map ladder position (0..10) to U enum index.
/// position 0 => p1, position 1..9 => n1..n9, position 10 => p2
inline fn ladderNode(pos: usize) usize {
    if (pos == 0) return @intFromEnum(U.p1);
    if (pos >= MAX_SECTIONS) return @intFromEnum(U.p2);
    // internal nodes n1..n9 are at enum positions 3..11
    return @intFromEnum(U.n1) + (pos - 1);
}

/// Compute the number of active sections from model and instance parameters.
/// Returns a value clamped to [1, 10].
inline fn computeNumSections(model: *const Model, instance: *const Instance) usize {
    const inst_n: i32 = instance.n;
    if (inst_n > 0) {
        // User-specified, clamp to [1, 10]
        const n_clamped: usize = if (inst_n < 1) 1 else if (inst_n > 10) 10 else @intCast(inst_n);
        return n_clamped;
    }

    // Auto-compute from FMAX
    const k_f: f64 = @as(f64, model.k);
    const fmax_f: f64 = @as(f64, model.fmax);
    const rperl_f: f64 = @as(f64, model.rperl);
    const cperl_f: f64 = @as(f64, model.cperl);
    const l_f: f64 = @as(f64, instance.l);

    // Guard against invalid parameters
    if (k_f <= 1.0 or fmax_f <= 0.0 or rperl_f <= 0.0 or cperl_f <= 0.0 or l_f <= 0.0) {
        return 1;
    }

    const r_total = rperl_f * l_f;
    const c_total = cperl_f * l_f;
    const tau = r_total * c_total;
    const arg = tau * fmax_f * 2.0 * 3.14159265358979323846;

    if (arg <= 1.0) return 1;

    const log_arg = @log(arg);
    const log_k = @log(k_f);

    // ceil(log(arg) / log(K))
    const ratio = log_arg / log_k;
    // Manual ceiling for positive values
    const floor_ratio: usize = @intFromFloat(ratio);
    const n_auto: usize = if (@as(f64, @floatFromInt(floor_ratio)) < ratio) floor_ratio + 1 else floor_ratio;

    // Clamp to [1, 10]
    return if (n_auto < 1) 1 else if (n_auto > 10) 10 else n_auto;
}

/// Compute geometric section weight for section i (0-indexed) of N total sections.
inline fn sectionWeight(sec_idx: usize, num_sections: usize, k_f: f64) f64 {
    if (k_f <= 1.0) {
        // Uniform distribution
        return 1.0 / @as(f64, @floatFromInt(num_sections));
    }
    // Geometric: w_i = (K-1) * K^(i) / (K^N - 1)
    // (sec_idx is 0-indexed here, corresponding to 1-indexed section sec_idx+1)
    const k_pow_i = @exp(@as(f64, @floatFromInt(sec_idx)) * @log(k_f));
    const k_pow_n = @exp(@as(f64, @floatFromInt(num_sections)) * @log(k_f));
    return (k_f - 1.0) * k_pow_i / (k_pow_n - 1.0);
}

// ============================================================================
// Precomputed per-section parameters (pure model+instance, no x)
// ============================================================================

const Prep = struct {
    num_sec: usize,
    g_s: [MAX_SECTIONS]f64,
    c_s: [MAX_SECTIONS]f64,
    is_s: [MAX_SECTIONS]f64,
    g_rs_s: [MAX_SECTIONS]f64,
    has_diode: bool,
    has_diode_rs: bool,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    const k_f: f64 = @as(f64, model.k);
    const rperl_f: f64 = @as(f64, model.rperl);
    const cperl_f: f64 = @as(f64, model.cperl);
    const isperl_f: f64 = @as(f64, model.isperl);
    const rsperl_f: f64 = @as(f64, model.rsperl);
    const l_f: f64 = @as(f64, instance.l);

    const r_total = rperl_f * l_f;
    const c_total = cperl_f * l_f;
    const num_sec = computeNumSections(model, instance);
    const has_diode = isperl_f > 0.0;
    const has_diode_rs = has_diode and rsperl_f > 0.0;

    var p: Prep = .{
        .num_sec = num_sec,
        .g_s = .{0} ** MAX_SECTIONS,
        .c_s = .{0} ** MAX_SECTIONS,
        .is_s = .{0} ** MAX_SECTIONS,
        .g_rs_s = .{0} ** MAX_SECTIONS,
        .has_diode = has_diode,
        .has_diode_rs = has_diode_rs,
    };

    var s: usize = 0;
    while (s < num_sec) : (s += 1) {
        const w_s = sectionWeight(s, num_sec, k_f);
        const r_s = r_total * w_s;
        p.g_s[s] = if (r_s > 1.0e-30) 1.0 / r_s else GSHORT;
        p.c_s[s] = c_total * w_s;
        if (has_diode) {
            p.is_s[s] = isperl_f * l_f * w_s;
            if (has_diode_rs) {
                const l_s = l_f * w_s;
                const rs_s: f64 = if (l_s > 1.0e-30) rsperl_f / l_s else 1.0e30;
                p.g_rs_s[s] = if (rs_s > 1.0e-30) 1.0 / rs_s else GSHORT;
            }
        }
    }
    return p;
}

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

// ============================================================================
// Current contributions (KCL)
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const p = prep(model, instance);
    return evalFromPrep(S, x, &p, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;
    _ = t;

    const p2 = @intFromEnum(U.p2);
    const ref = @intFromEnum(U.ref_);
    const num_sec = pc.num_sec;

    var contrib: [n_u]S = .{S.con(0.0)} ** n_u;

    var s: usize = 0;
    while (s < num_sec) : (s += 1) {
        const left_idx = ladderNode(s);
        const right_idx = ladderNode(s + 1);

        const i_r = x[left_idx].sub(x[right_idx]).scale(pc.g_s[s]);
        contrib[left_idx] = contrib[left_idx].add(i_r);
        contrib[right_idx] = contrib[right_idx].sub(i_r);

        const v_shunt = x[right_idx].sub(x[ref]);

        const i_gmin = v_shunt.scale(GMIN);
        contrib[right_idx] = contrib[right_idx].add(i_gmin);
        contrib[ref] = contrib[ref].sub(i_gmin);

        if (pc.has_diode) {
            const arg_d = v_shunt.div(S.con(VT)).minC(80.0);
            const i_d = arg_d.exp().addC(-1.0).scale(pc.is_s[s]);
            contrib[right_idx] = contrib[right_idx].add(i_d);
            contrib[ref] = contrib[ref].sub(i_d);

            if (pc.has_diode_rs) {
                const i_rs = v_shunt.scale(pc.g_rs_s[s]);
                contrib[right_idx] = contrib[right_idx].add(i_rs);
                contrib[ref] = contrib[ref].sub(i_rs);
            }
        }
    }

    var j: usize = 0;
    while (j < 9) : (j += 1) {
        const node_idx = @intFromEnum(U.n1) + j;
        const pos = j + 1;
        if (pos >= num_sec) {
            const i_short = x[node_idx].sub(x[p2]).scale(GSHORT);
            contrib[node_idx] = contrib[node_idx].add(i_short);
            contrib[p2] = contrib[p2].sub(i_short);
        }
    }

    return contrib;
}

// ============================================================================
// Charge contributions (displacement current via dQ/dt)
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const p = prep(model, instance);
    return qFromPrep(S, x, &p, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;
    _ = t;

    const ref = @intFromEnum(U.ref_);

    var charge: [n_u]S = .{S.con(0.0)} ** n_u;

    var s: usize = 0;
    while (s < pc.num_sec) : (s += 1) {
        const right_idx = ladderNode(s + 1);
        const q_s = x[right_idx].sub(x[ref]).scale(pc.c_s[s]);
        charge[right_idx] = charge[right_idx].add(q_s);
        charge[ref] = charge[ref].sub(q_s);
    }

    return charge;
}

// ============================================================================
// Noise sources: thermal noise from each series resistor section
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Series resistor from p1 to n1 (section 1)
    .{ .row = @intFromEnum(U.p1), .col = @intFromEnum(U.n1), .kind = .thermal },
    // Series resistor from n1 to n2 (section 2)
    .{ .row = @intFromEnum(U.n1), .col = @intFromEnum(U.n2), .kind = .thermal },
    // Series resistor from n2 to n3 (section 3)
    .{ .row = @intFromEnum(U.n2), .col = @intFromEnum(U.n3), .kind = .thermal },
    // Series resistor from n3 to n4 (section 4)
    .{ .row = @intFromEnum(U.n3), .col = @intFromEnum(U.n4), .kind = .thermal },
    // Series resistor from n4 to n5 (section 5)
    .{ .row = @intFromEnum(U.n4), .col = @intFromEnum(U.n5), .kind = .thermal },
    // Series resistor from n5 to n6 (section 6)
    .{ .row = @intFromEnum(U.n5), .col = @intFromEnum(U.n6), .kind = .thermal },
    // Series resistor from n6 to n7 (section 7)
    .{ .row = @intFromEnum(U.n6), .col = @intFromEnum(U.n7), .kind = .thermal },
    // Series resistor from n7 to n8 (section 8)
    .{ .row = @intFromEnum(U.n7), .col = @intFromEnum(U.n8), .kind = .thermal },
    // Series resistor from n8 to n9 (section 9)
    .{ .row = @intFromEnum(U.n8), .col = @intFromEnum(U.n9), .kind = .thermal },
    // Series resistor from n9 to p2 (section 10)
    .{ .row = @intFromEnum(U.n9), .col = @intFromEnum(U.p2), .kind = .thermal },
    // Shot noise from shunt diodes (when ISPERL > 0)
    .{ .row = @intFromEnum(U.n1), .col = @intFromEnum(U.ref_), .kind = .shot },
    .{ .row = @intFromEnum(U.n2), .col = @intFromEnum(U.ref_), .kind = .shot },
    .{ .row = @intFromEnum(U.n3), .col = @intFromEnum(U.ref_), .kind = .shot },
    .{ .row = @intFromEnum(U.n4), .col = @intFromEnum(U.ref_), .kind = .shot },
    .{ .row = @intFromEnum(U.n5), .col = @intFromEnum(U.ref_), .kind = .shot },
    .{ .row = @intFromEnum(U.n6), .col = @intFromEnum(U.ref_), .kind = .shot },
    .{ .row = @intFromEnum(U.n7), .col = @intFromEnum(U.ref_), .kind = .shot },
    .{ .row = @intFromEnum(U.n8), .col = @intFromEnum(U.ref_), .kind = .shot },
    .{ .row = @intFromEnum(U.n9), .col = @intFromEnum(U.ref_), .kind = .shot },
    .{ .row = @intFromEnum(U.p2), .col = @intFromEnum(U.ref_), .kind = .shot },
};

// ============================================================================
// Validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "urc: single section, pure series resistance" {
    // n=1, l=1 => one section: p1 --R-- n1, w_0 = (1.5-1)*1.5^0/(1.5^1-1) = 1,
    // R = rperl*l*w = 1000 ohm. With V(p1)=1, all other nodes 0:
    //   i_r = (1 - 0)/1000 = 1e-3 into p1, -1e-3 into n1.
    // Shunt at n1: v_shunt = 0 => GMIN/diode terms 0 (isperl=0 anyway).
    // Shorting n1..n9 to p2: all node voltages equal p2 (=0) => 0.
    const model: Model = .{};
    const inst: Instance = .{ .l = 1.0, .n = 1 };
    const x = [n_u]f64{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1e-3), out[@intFromEnum(U.p1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1e-3), out[@intFromEnum(U.n1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.p2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.ref_)], 1e-12);
}

test "urc: two sections, geometric weights" {
    // n=2, k=1.5: w_0 = 0.5*1/(1.5^2-1) = 0.5/1.25 = 0.4, w_1 = 0.5*1.5/1.25 = 0.6.
    // R_0 = 1000*0.4 = 400, R_1 = 1000*0.6 = 600.
    // V(p1)=1, all others 0:
    //   section 0: i = (1-0)/400 = 2.5e-3 (p1 -> n1)
    //   section 1: i = (0-0)/600 = 0
    // out[p1] = 2.5e-3, out[n1] = -2.5e-3.
    const model: Model = .{};
    const inst: Instance = .{ .l = 1.0, .n = 2 };
    const x = [n_u]f64{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 2.5e-3), out[@intFromEnum(U.p1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -2.5e-3), out[@intFromEnum(U.n1)], 1e-12);
}

test "urc: forward-biased diode shunt" {
    // isperl=1e-6 (f32 storage: 9.999999974752427e-07), n=1, l=1, w_0=1.
    // V(p1)=0, V(n1)=V(p2)=V(n2..n9)=0.1, V(ref)=0.
    //   series:  i_r = (0 - 0.1)/1000 = -1e-4  => p1: -1e-4, n1: +1e-4
    //   GMIN:    i_gmin = 1e-12 * 0.1 = 1e-13  => n1: +1e-13, ref: -1e-13
    //   diode:   arg = 0.1/0.02586 = 3.8669760247486464 (< 80, unclamped)
    //            exp(arg) = 47.79762847384091
    //            i_d = 9.999999974752427e-07 * 46.79762847384091
    //                = 4.6797628355688254e-05  => n1: +i_d, ref: -i_d
    //   shorting: all internal nodes at V(p2) => 0
    // out[p1]  = -1e-4
    // out[n1]  = 1e-4 + 1e-13 + i_d = 1.4679762845568826e-4
    // out[ref] = -(1e-13 + i_d)    = -4.679762845568825e-5
    const model: Model = .{ .isperl = 1e-6 };
    const inst: Instance = .{ .l = 1.0, .n = 1 };
    const x = [n_u]f64{ 0.0, 0.1, 0.0, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1 };
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -1e-4), out[@intFromEnum(U.p1)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1.4679762845568826e-4), out[@intFromEnum(U.n1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -4.679762845568825e-5), out[@intFromEnum(U.ref_)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.p2)], 1e-15);
}

test "urc: shunt charge" {
    // n=1, l=1, cperl=1e-12, w_0=1 => C = 1e-12 at n1-ref.
    // V(n1)=1, V(ref)=0: q[n1] = 1e-12 * 1 = 1e-12, q[ref] = -1e-12.
    const model: Model = .{};
    const inst: Instance = .{ .l = 1.0, .n = 1 };
    const x = [n_u]f64{ 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    const out = contract.qValues(Self, x, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1e-12), out[@intFromEnum(U.n1)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -1e-12), out[@intFromEnum(U.ref_)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.p1)], 1e-15);
}
