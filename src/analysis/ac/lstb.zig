//! Loop stability by double injection (`.lstb`, HSPICE; VACASK `acstb`).
//! Each frequency solves two right-hand sides on one lane factorization: a
//! unit current into the probe's `+` node, and a unit voltage across the
//! probe. VACASK's two-port reading of the four responses (coreacstb.cpp)
//! gives the DUT y-parameters and the forward, reverse and total loop gain;
//! the total is Tian's loop gain, exact for a bilateral loop and any
//! loading at the break. `diff` and `comm` drive a probe pair ±1 and read
//! the modal half of each response.
const std = @import("std");
const freq = @import("freq.zig");
const root = @import("../types.zig");
const core = @import("core");
const Complex = core.numerics.Complex;
const FreqSolver = @import("solver").freq_solve.FreqSolver;
const Dyn = @import("solver").freq_solve.Dyn;

/// Query options, defined in core/query.zig.
pub const Options = core.query.Lstb;

/// The probe responses in VACASK's names: the probe current (A, B) and the
/// `+` node voltage (C, D) under current (A, C) and voltage (B, D)
/// injection.
pub const Responses = struct { a: Complex, b: Complex, c: Complex, d: Complex };

/// Everything `.lstb` publishes at one frequency.
pub const Gains = struct {
    /// Total loop gain W = Wf + Wr, the return ratio: positive at DC for
    /// negative feedback, unstable at W = −1.
    w: Complex,
    wf: Complex,
    wr: Complex,
    y11: Complex,
    y12: Complex,
    y21: Complex,
    y22: Complex,

    /// VACASK coreacstb.cpp's formulas. The y-parameters divide by C, so
    /// they are infinite when the probe's `+` node is an ideal source.
    pub fn of(r: Responses) Gains {
        const one: Complex = .{ .re = 1, .im = 0 };
        const adbc = r.a.mul(r.d).sub(r.b.mul(r.c));
        const fwd = r.a.sub(adbc);
        const rev = r.d.sub(adbc);
        const den = one.add(adbc.scale(2)).sub(r.a).sub(r.d);
        const wf = fwd.div(den);
        const wr = rev.div(den);
        return .{
            .w = wf.add(wr),
            .wf = wf,
            .wr = wr,
            .y11 = one.add(adbc).sub(r.a).sub(r.d).div(r.c),
            .y12 = rev.div(r.c),
            .y21 = fwd.div(r.c),
            .y22 = adbc.div(r.c),
        };
    }
};

/// Excitation weight of each probe: `single` drives the first alone, `diff`
/// the pair +1/−1, `comm` +1/+1.
fn weights(mode: Options.Mode) [2]f64 {
    return switch (mode) {
        .single => .{ 1, 0 },
        .diff => .{ 1, -1 },
        .comm => .{ 1, 1 },
    };
}

/// The two stacked 2n right-hand sides: current injection, then voltage
/// injection. `rhs` must be zeroed.
fn fill(opts: Options, n: usize, rhs: []f64) void {
    for (opts.probes, weights(opts.mode)) |p, e| {
        if (p.p != root.GROUND) rhs[p.p] += e;
        rhs[2 * n + p.branch] += e;
    }
}

/// The modal responses in `x` (both solutions): each probe's reading times
/// its weight, averaged over the driven probes, so a symmetric pair reads
/// its half circuit.
fn responses(opts: Options, n: usize, x: []const f64) Responses {
    const e = weights(opts.mode);
    const share: f64 = if (opts.mode == .single) 1 else 0.5;
    var r: Responses = .{ .a = .zero, .b = .zero, .c = .zero, .d = .zero };
    for (opts.probes, e) |p, w| {
        if (w == 0) continue;
        const s = w * share;
        r.a = r.a.add(at(x, n, p.branch).scale(s));
        r.c = r.c.add(at(x, n, p.p).scale(s));
        r.b = r.b.add(at(x[2 * n ..], n, p.branch).scale(s));
        r.d = r.d.add(at(x[2 * n ..], n, p.p).scale(s));
    }
    return r;
}

fn at(x: []const f64, n: usize, r: u32) Complex {
    if (r == root.GROUND) return .zero;
    return .{ .re = x[r], .im = x[n + r] };
}

/// Contract entry. The sweep plot is complex (frequency, loop_gain,
/// loop_gain_forward, loop_gain_reverse, y11, y12, y21, y22); with
/// `margins` it is one real row instead (see `Margins`).
///
/// Returns error.InvalidProbe when a probe row is out of range.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const used: usize = if (opts.mode == .single) 1 else 2;
    for (opts.probes[0..used]) |p| if (p.p >= n or p.n >= n or p.branch >= n) return error.InvalidProbe;

    var fs = try FreqSolver.fromCircuit(scratch, ckt, ctx.x_op);
    defer fs.deinit(scratch);

    const n_points: usize = opts.sweep.count();
    const axis = try scratch.alloc(f64, 2 * n_points);
    defer scratch.free(axis);
    const freqs = axis[0..n_points];
    const omegas = axis[n_points..];
    opts.sweep.fill(freqs, omegas);

    const rhs = try scratch.alloc(f64, 4 * n);
    defer scratch.free(rhs);
    root.zeroSimd(rhs);
    fill(opts, n, rhs);

    const loop = try scratch.alloc(Complex, n_points);
    defer scratch.free(loop);
    const cols = 8;
    const data = try a.alloc(f64, if (opts.margins) 5 else n_points * cols * 2);
    errdefer a.free(data);

    var stream = try freq.Stream.init(scratch, &fs, ckt, ctx.x_op, omegas, rhs, false);
    defer stream.deinit(scratch);
    while (try stream.next(ckt)) |pt| {
        const g = Gains.of(responses(opts, n, pt.x));
        loop[pt.k] = g.w;
        if (opts.margins) continue;
        const row = data[pt.k * cols * 2 ..][0 .. cols * 2];
        row[0..2].* = .{ freqs[pt.k], 0 };
        for ([_]Complex{ g.w, g.wf, g.wr, g.y11, g.y12, g.y21, g.y22 }, 0..) |v, i| row[2 + 2 * i ..][0..2].* = .{ v.re, v.im };
    }

    if (!opts.margins) return .{
        .plotname = "Loop Stability Analysis",
        .varnames = try a.dupe([]const u8, &.{ "frequency", "loop_gain", "loop_gain_forward", "loop_gain_reverse", "y11", "y12", "y21", "y22" }),
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };

    var probe: Probe = try .init(scratch, &fs, ckt, ctx.x_op, rhs, opts);
    defer probe.deinit(scratch);
    const m = try Margins.find(&probe, freqs, loop);
    data[0..5].* = .{ m.gain_margin, m.phase_crossover_freq, m.phase_margin, m.unity_gain_freq, m.loop_gain_minifreq };
    return .{
        .plotname = "Loop Stability Margins",
        .varnames = try a.dupe([]const u8, &.{ "gain_margin", "phase_crossover_freq", "phase_margin", "unity_gain_freq", "loop_gain_minifreq" }),
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}

/// The loop gain at any one frequency, for refining a crossing between two
/// sweep points: one single-lane `solveBatch` on the sweep's solver.
const Probe = struct {
    fs: *FreqSolver,
    ckt: *root.Circuit,
    x_op: []const f64,
    rhs: []const f64,
    opts: Options,
    /// Both solutions, then the `acDyn` terms re and im.
    buf: []f64,

    fn init(allocator: std.mem.Allocator, fs: *FreqSolver, ckt: *root.Circuit, x_op: []const f64, rhs: []const f64, opts: Options) !Probe {
        const buf = try allocator.alloc(f64, rhs.len + 2 * ckt.ac_dyn_slots.len);
        return .{ .fs = fs, .ckt = ckt, .x_op = x_op, .rhs = rhs, .opts = opts, .buf = buf };
    }

    fn deinit(self: *Probe, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    fn gain(self: *Probe, f: f64) !Complex {
        const omega = [1]f64{2 * std.math.pi * f};
        const slots = self.ckt.ac_dyn_slots.len;
        const x = self.buf[0..self.rhs.len];
        const re = self.buf[self.rhs.len..][0..slots];
        const im = self.buf[self.rhs.len + slots ..][0..slots];
        if (slots != 0) self.ckt.acDyn(self.x_op, &omega, re, im);
        const dyn: Dyn = .{ .slots = self.ckt.ac_dyn_slots, .re = re, .im = im };
        try self.fs.solveBatch(&omega, dyn, self.rhs, x, false);
        return Gains.of(responses(self.opts, self.ckt.n, x)).w;
    }
};

/// HSPICE's `.lstb` scalars [CR .MEASURE LSTB], plus the frequency the
/// gain margin is read at. A margin whose crossing the sweep never brackets
/// is NaN.
pub const Margins = struct {
    /// dB: −20·log10|W| where W is real and negative.
    gain_margin: f64,
    /// Hz.
    phase_crossover_freq: f64,
    /// Degrees: 180 + ∠W at |W| = 1.
    phase_margin: f64,
    /// Hz.
    unity_gain_freq: f64,
    /// dB: 20·log10|W| at the sweep's first frequency.
    loop_gain_minifreq: f64,

    /// Brackets the first unity-magnitude and first negative-real crossing
    /// of `loop` over `freqs`, then refines each on the circuit itself
    /// (`crossing`), so the margins do not depend on the grid.
    fn find(probe: *Probe, freqs: []const f64, loop: []const Complex) !Margins {
        const nan = std.math.nan(f64);
        var m: Margins = .{ .gain_margin = nan, .phase_crossover_freq = nan, .phase_margin = nan, .unity_gain_freq = nan, .loop_gain_minifreq = 20 * std.math.log10(loop[0].mag()) };
        if (try crossing(probe, freqs, loop, logMag)) |c| {
            m.unity_gain_freq = c.f;
            m.phase_margin = std.math.radiansToDegrees(reversed(c.w));
        } else std.debug.print("warning: .lstb: |loop gain| never crosses 1 in the sweep; no phase margin\n", .{});
        if (try crossing(probe, freqs, loop, reversedPhase)) |c| {
            m.phase_crossover_freq = c.f;
            m.gain_margin = -20 * std.math.log10(c.w.mag());
        } else std.debug.print("warning: .lstb: loop gain never crosses -180 degrees in the sweep; no gain margin\n", .{});
        return m;
    }
};

/// ∠(−W) in radians, (−π, π]: the phase margin angle.
fn reversed(w: Complex) f64 {
    return std.math.atan2(-w.im, -w.re);
}

fn logMag(w: Complex) ?f64 {
    return @log(w.mag());
}

/// ∠(−W), defined only near the negative real axis (Re W < 0), where it is
/// continuous and zero at the crossing.
fn reversedPhase(w: Complex) ?f64 {
    return if (w.re < 0) reversed(w) else null;
}

/// A refined crossing: its frequency and the loop gain there.
const Crossing = struct { f: f64, w: Complex };

/// The first sign change of `g` between neighbouring sweep points,
/// refined by Illinois regula falsi on `probe` to a relative frequency
/// width of 1e-13 (at most 100 solves). Null when no neighbours bracket a
/// root.
fn crossing(probe: *Probe, freqs: []const f64, loop: []const Complex, comptime g: fn (Complex) ?f64) !?Crossing {
    for (1..loop.len) |k| {
        var g_lo = g(loop[k - 1]) orelse continue;
        var g_hi = g(loop[k]) orelse continue;
        if (g_lo == 0) return .{ .f = freqs[k - 1], .w = loop[k - 1] };
        if ((g_lo < 0) == (g_hi < 0) or g_hi == 0) {
            if (g_hi == 0) return .{ .f = freqs[k], .w = loop[k] };
            continue;
        }
        var lo = freqs[k - 1];
        var hi = freqs[k];
        var best: Crossing = .{ .f = hi, .w = loop[k] };
        var side: i2 = 0;
        for (0..100) |_| {
            var f = hi - g_hi * (hi - lo) / (g_hi - g_lo);
            if (!(f > lo and f < hi)) f = 0.5 * (lo + hi);
            const w = try probe.gain(f);
            const gv = g(w) orelse break;
            best = .{ .f = f, .w = w };
            if (gv == 0 or hi - lo <= 1e-13 * hi) break;
            if ((gv < 0) == (g_hi < 0)) {
                hi = f;
                g_hi = gv;
                if (side == 1) g_lo *= 0.5;
                side = 1;
            } else {
                lo = f;
                g_lo = gv;
                if (side == -1) g_hi *= 0.5;
                side = -1;
            }
        }
        return best;
    }
    return null;
}
