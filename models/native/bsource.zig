//! bsource — ngspice's B element (ASRC, asrc/asrcload.c): V(p,n) or I(p,n)
//! equals an arbitrary expression of node voltages. The builder compiles the
//! card's expression into a postfix tape on the Model; `eval` interprets it
//! with the host's scalar S, so the Jacobian comes from the same forward-mode
//! AD as every generated device instead of ngspice's symbolic derivative
//! trees (inpptree.c PTdifferentiate).
//!
//! Data (DOD): one instance = 2 output ports, `max_probes` control ports
//! (unused ones tied to ground, so their stamps drop) and one branch current.
//! The tape is three parallel arrays (opcode and two u8 operands; the
//! contract admits only scalar arrays in a Model) plus a constant pool, all
//! fixed-capacity so the Model stays a POD. `eval` walks the tape once per
//! Newton iteration over a value stack of S. Instances are independent
//! (ParEval-safe).
//!
//! Semantics that differ from ngspice's defaults, on purpose:
//! - `x^k` with a constant integer k in [0, 255] keeps the sign of x (x·x·…·x),
//!   as ngspice's hspice/ltspice compat (ptfuncs.c PTpowerH) and the corpus
//!   oracles do; ngspice's default mode takes |x|^k. Any other exponent is
//!   |x|^y, as in ngspice's default; a non-constant exponent goes through
//!   exp(y·ln|x|), whose slope is not finite at x = 0.
//! - sqrt/log of a negative argument, log(0) and exp overflow follow IEEE
//!   (NaN/inf, caught by the solver's finiteness check) instead of
//!   ptfuncs.c's HUGE and ±1e99 substitutes. Division does follow ngspice.
//!
//! Temperature (asrcload.c): the expression is scaled by
//! 1 + tc1·dT + tc2·dT², dT = (T + dtemp) − 300.15 K, inverted when
//! reciproctc != 0.

const std = @import("std");
const contract = @import("contract");

const Self = @This();

// The contract admits only its own names as pub, so the builder reads these
// capacities off `num_ports` and the Model's array lengths.
const max_probes = 8;
const max_ops = 64;
const max_consts = 32;

pub const U = enum(u8) { p, n, c0, c1, c2, c3, c4, c5, c6, c7, br };
pub const num_ports: usize = 2 + max_probes;
/// Hand-written against VerA's device ABI 5 (`contract.abi_version`); review on a bump.
pub const contract_abi: u32 = 5;
const n_u = contract.nU(Self);
const br = @intFromEnum(U.br);
const dense = contract.denseMask(Self);

pub const u_kinds = [_]contract.UnknownKind{.voltage} ** num_ports ++ [_]contract.UnknownKind{.current};
pub const u_abstol = [_]f64{1e-6} ** num_ports ++ [_]f64{1e-12};

/// The output rows read only the branch current; the branch row reads
/// everything. Control rows are never written.
pub const jac_pattern = blk: {
    var pat: [n_u]u64 = @splat(0);
    pat[@intFromEnum(U.p)] = 1 << br;
    pat[@intFromEnum(U.n)] = 1 << br;
    pat[br] = (1 << n_u) - 1;
    break :blk pat;
};
pub const jac_rows: u64 = (1 << @intFromEnum(U.p)) | (1 << @intFromEnum(U.n)) | (1 << br);

/// Tape opcode, reached by the builder as the element type of `op_code`. Operands: `num` a = constant index; `v` a = control port;
/// `vd` a, b = control ports of V(a,b); `powi` a = the integer exponent;
/// `powc` a = constant index of the exponent. The rest pop their operands
/// (1, 2, or 3 for `sel`) and push one result.
const Code = enum(u8) {
    num,
    v,
    vd,
    neg,
    not,
    add,
    sub,
    mul,
    div,
    powi,
    powc,
    pow,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    @"and",
    @"or",
    sel,
    sqrt,
    abs,
    min,
    max,
    exp,
    ln,
    log10,
    sin,
    cos,
    tan,
    atan,
    tanh,
    floor,
    ceil,
};

pub const Model = struct {
    tc1: f64 = 0.0, // 1/K
    tc2: f64 = 0.0, // 1/K^2
    dtemp: f64 = 0.0, // K
    /// Instance temperature in K; <= 0 means the circuit temperature.
    temp: f64 = -1.0e3,
    reciproctc: bool = false,
    /// false: V(p,n) = f; true: I(p,n) = f.
    imode: bool = false,
    n_ops: u8 = 0,
    op_code: [max_ops]Code = @splat(.num),
    op_a: [max_ops]u8 = @splat(0),
    op_b: [max_ops]u8 = @splat(0),
    consts: [max_consts]f64 = @splat(0.0),
};

pub const Instance = struct {
    temperature: f64 = 300.15,
};

pub fn eval(comptime S: type, xv: *const [n_u]S.V, model: *const Model, inst: *const Instance, _: contract.SimState) contract.Rows(Self, S) {
    const x = contract.probes(Self, S, xv);
    const f = run(S, x, model).scale(tempFactor(model, inst));
    // The output rows carry the branch current's lane alone.
    const ib = S.probe(br, xv[br]);
    var res: contract.Rows(Self, S) = undefined;
    inline for (0..n_u) |u| res[u] = S.con(0.0).to(contract.rowMask(Self, u));
    res[@intFromEnum(U.p)] = ib.to(contract.rowMask(Self, @intFromEnum(U.p)));
    res[@intFromEnum(U.n)] = ib.neg().to(contract.rowMask(Self, @intFromEnum(U.n)));
    res[br] = (if (model.imode) x[br].sub(f) else x[@intFromEnum(U.p)].sub(x[@intFromEnum(U.n)]).sub(f)).to(contract.rowMask(Self, br));
    return res;
}

fn tempFactor(model: *const Model, inst: *const Instance) f64 {
    const tdev = if (model.temp <= 0.0) inst.temperature else model.temp;
    const dt = (tdev + model.dtemp) - 300.15;
    const factor = 1.0 + model.tc1 * dt + model.tc2 * dt * dt;
    return if (model.reciproctc) 1.0 / factor else factor;
}

/// The tape's value at `x`. An empty tape is 0. min, max and abs keep
/// ngspice's tie rules (a tie goes to `a`, abs keeps -0) over `lt`/`le`/`sel`.
fn run(comptime S: type, x: [n_u]S.Of(dense), model: *const Model) S.Of(dense) {
    const T = S.Of(dense);
    const k = struct {
        fn c(v: f64) T {
            return S.con(v).to(dense);
        }
        fn abs(a: T) T {
            return S.sel(a.lt(S.con(0.0)), a.neg(), a);
        }
    };
    // ponytail: sized for the worst case (every op a push), ~6 KB of Dual on
    // the stack; bound it by the tape's real depth if B sources reach the GPU.
    var st: [max_ops]T = undefined;
    var sp: usize = 0;
    const ctl = x[2..num_ports];
    const n = model.n_ops;
    for (model.op_code[0..n], model.op_a[0..n], model.op_b[0..n]) |code, oa, ob| {
        switch (code) {
            .num, .v, .vd => {
                st[sp] = switch (code) {
                    .num => k.c(model.consts[oa]),
                    .v => ctl[oa],
                    else => ctl[oa].sub(ctl[ob]),
                };
                sp += 1;
            },
            .sel => {
                sp -= 2;
                st[sp - 1] = S.sel(st[sp - 1], st[sp], st[sp + 1]);
            },
            .add, .sub, .mul, .div, .pow, .lt, .gt, .le, .ge, .eq, .ne, .@"and", .@"or", .min, .max => {
                sp -= 1;
                const a = st[sp - 1];
                const b = st[sp];
                const one = k.c(1.0);
                const zero = k.c(0.0);
                st[sp - 1] = switch (code) {
                    .add => a.add(b),
                    .sub => a.sub(b),
                    .mul => a.mul(b),
                    // ptfuncs.c PTdivide: the divisor moves 1e-32 (ifeval.c's
                    // gmin·1e-20 at the default gmin) away from zero, so 0/0 at
                    // an all-zero starting point is 0 instead of NaN.
                    .div => a.div(b.addC(if (b.val() >= 0.0) 1e-32 else -1e-32)),
                    .pow => k.abs(a).log().mul(b).exp(),
                    .lt => a.lt(b).to(dense),
                    .gt => b.lt(a).to(dense),
                    .le => a.le(b).to(dense),
                    .ge => b.le(a).to(dense),
                    .eq => a.eq(b).to(dense),
                    .ne => one.sub(a.eq(b)),
                    .@"and" => S.sel(a, S.sel(b, one, zero), zero),
                    .@"or" => S.sel(a, one, S.sel(b, one, zero)),
                    .min => S.sel(a.le(b), a, b),
                    else => S.sel(b.le(a), a, b),
                };
            },
            else => {
                const a = st[sp - 1];
                st[sp - 1] = switch (code) {
                    .neg => a.neg(),
                    .not => a.eq(S.con(0.0)).to(dense),
                    // x·(x·(x·…)): the base multiplies the running power.
                    .powi => blk: {
                        if (oa == 0) break :blk k.c(1.0);
                        var r = a;
                        for (1..oa) |_| r = a.mul(r);
                        break :blk r;
                    },
                    .powc => k.abs(a).pow(model.consts[oa]),
                    .sqrt => a.sqrt(),
                    .abs => k.abs(a),
                    .exp => a.exp(),
                    .ln => a.log(),
                    .log10 => a.log().scale(1.0 / std.math.ln10),
                    .sin => a.sin(),
                    .cos => a.cos(),
                    .tan => a.sin().div(a.cos()),
                    .atan => a.atan(),
                    .tanh => a.tanh(),
                    .floor => k.c(@floor(a.val())),
                    .ceil => k.c(@ceil(a.val())),
                    else => unreachable,
                };
            },
        }
    }
    return if (sp == 0) k.c(0.0) else st[0];
}

comptime {
    contract.validate(Self);
}
