//! All-source DC transfer (`.dcxf`, VACASK `dcxf`) at the operating point:
//! the transfer from every independent source to one output, and the input
//! impedance each source sees. One sparse factorization of G serves every
//! solve. `ac/xf.zig` runs the same readout over a frequency sweep.
const std = @import("std");
const root = @import("../types.zig");
const core = @import("core");
const Complex = core.numerics.Complex;
const XfSource = core.query.XfSource;

/// Query options, defined in core/query.zig.
pub const Options = core.query.Dcxf;

/// The finite stand-in for an infinite immittance (a source that moves no
/// current, or a current source across a short), as VACASK's coredcxf.cpp
/// writes it.
pub const infinite: f64 = 1e20;

/// Where an all-source transfer reads its output: a node pair or a branch.
pub const Output = struct {
    /// Output row; unused when `branch` is set.
    node: u32,
    /// `v(a,b)` reference row; GROUND is single-ended.
    neg: u32,
    /// `i(Vmeasure)`: that source's branch row.
    branch: ?u32,

    /// Writes the adjoint seed e_out into `rhs`, which must be zeroed: only
    /// the output's own rows are stored.
    pub fn seed(self: Output, rhs: []f64) void {
        if (self.branch) |br| {
            rhs[br] = 1;
            return;
        }
        rhs[self.node] = 1;
        if (self.neg != root.GROUND) rhs[self.neg] = -1;
    }

    /// The output read from solution `x` (see `at`).
    pub fn read(self: Output, x: []const f64, n: usize) Complex {
        if (self.branch) |br| return at(x, n, br);
        return at(x, n, self.node).sub(at(x, n, self.neg));
    }
};

/// Row `r` of a real length-n or stacked-real length-2n solution; ground
/// reads zero.
pub fn at(x: []const f64, n: usize, r: u32) Complex {
    if (r == root.GROUND) return .zero;
    return .{ .re = x[r], .im = if (x.len > n) x[n + r] else 0 };
}

/// The unit excitation of `src` into the first `n` rows of `rhs`: 1 V on
/// a V card's branch row, 1 A through an I card from `nodes[0]` to
/// `nodes[1]`, the stamps its AC magnitude makes.
pub fn excite(src: XfSource, rhs: []f64) void {
    if (src.branch) |br| {
        rhs[br] = 1;
        return;
    }
    if (src.nodes[0] != root.GROUND) rhs[src.nodes[0]] -= 1;
    if (src.nodes[1] != root.GROUND) rhs[src.nodes[1]] += 1;
}

/// The transfer of `src` from the adjoint solution `y` = A⁻ᵀ e_out.
pub fn adjointTf(src: XfSource, y: []const f64, n: usize) Complex {
    if (src.branch) |br| return at(y, n, br);
    return at(y, n, src.nodes[1]).sub(at(y, n, src.nodes[0]));
}

/// `src`'s input impedance and admittance from its own forward response
/// `x`: a V card's delivered current is −i_branch per volt, an I card's
/// terminal voltage v(nodes[1]) − v(nodes[0]) per ampere. A zero reads as
/// `infinite` in its reciprocal.
pub fn immittance(src: XfSource, x: []const f64, n: usize) [2]Complex {
    const one: Complex = .{ .re = 1, .im = 0 };
    const inf: Complex = .{ .re = infinite, .im = 0 };
    if (src.branch) |br| {
        const y = at(x, n, br).scale(-1);
        return .{ if (y.magSq() == 0) inf else one.div(y), y };
    }
    const z = at(x, n, src.nodes[1]).sub(at(x, n, src.nodes[0]));
    return .{ z, if (z.magSq() == 0) inf else one.div(z) };
}

/// Column labels: `tf(name)`, then `zin(name)` and `yin(name)` unless
/// `tf_only`, per source; after `first` when given. Caller owns the slice and
/// every label but `first` (borrowed), all allocated with `a`.
pub fn names(a: std.mem.Allocator, first: ?[]const u8, sources: []const XfSource, tf_only: bool) ![]const []const u8 {
    const kinds: []const []const u8 = if (tf_only) &.{"tf"} else &.{ "tf", "zin", "yin" };
    const extra: usize = @intFromBool(first != null);
    const out = try a.alloc([]const u8, extra + kinds.len * sources.len);
    errdefer a.free(out);
    if (first) |f| out[0] = f;
    var done: usize = 0;
    errdefer for (out[extra..][0..done]) |l| a.free(l);
    for (sources) |s| for (kinds) |k| {
        out[extra + done] = try label(a, k, s.name);
        done += 1;
    };
    return out;
}

/// `what(name)`, lowercased like the deck's probe labels.
fn label(a: std.mem.Allocator, what: []const u8, name: []const u8) ![]const u8 {
    const s = try std.fmt.allocPrint(a, "{s}({s})", .{ what, name });
    return std.ascii.lowerString(s, s);
}

/// Contract entry: one real point with `tf(src)` [, `zin(src)`, `yin(src)`]
/// per source. `tf_only` reads every transfer off one adjoint solve;
/// otherwise each source's own forward solve gives its three values.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const out: Output = .{ .node = opts.output_node, .neg = opts.output_neg, .branch = opts.output_branch };

    const ws = try ckt.workspace();
    ckt.eval(ctx.x_op, 0);
    try ws.slv.factor(ckt.g_vals, ckt.solver_execution);

    const buf = try ctx.scratch_allocator.alloc(f64, 2 * n);
    defer ctx.scratch_allocator.free(buf);
    const rhs = buf[0..n];
    const x = buf[n..];

    const per: usize = if (opts.tf_only) 1 else 3;
    const data = try a.alloc(f64, per * opts.sources.len);
    errdefer a.free(data);
    if (opts.tf_only) {
        root.zeroSimd(rhs);
        out.seed(rhs);
        ws.slv.solveT(rhs, x);
        for (opts.sources, data) |s, *d| d.* = adjointTf(s, x, n).re;
    } else for (opts.sources, 0..) |s, i| {
        root.zeroSimd(rhs);
        excite(s, rhs);
        ws.slv.solve(rhs, x);
        const zy = immittance(s, x, n);
        data[3 * i ..][0..3].* = .{ out.read(x, n).re, zy[0].re, zy[1].re };
    }
    return .{
        .plotname = "DC Transfer Functions",
        .varnames = try names(a, null, opts.sources, opts.tf_only),
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}

/// `.dcinc` (VACASK `dcinc`): the incremental solution G Δx = Δu, where
/// Δu is every source's AC excitation (its real part: VACASK's `mag`, with
/// the phase applied), published on the deck's probes as one real point.
pub const Inc = struct {
    /// Query options, defined in core/query.zig.
    pub const Options = core.query.Dcinc;

    /// Contract entry: one real point, one column per deck probe.
    pub fn run(ctx: *const root.RunCtx, _: Inc.Options) !root.Result {
        const a = ctx.allocator;
        const ckt = ctx.circuit;
        const n: usize = ckt.n;
        const ws = try ckt.workspace();
        ckt.eval(ctx.x_op, 0);
        try ws.slv.factor(ckt.g_vals, ckt.solver_execution);

        const buf = try ctx.scratch_allocator.alloc(f64, 2 * n);
        defer ctx.scratch_allocator.free(buf);
        const rhs = buf[0..n];
        const x = buf[n..];
        if (ctx.ac_drive.len == 0) root.zeroSimd(rhs) else @memcpy(rhs, ctx.ac_drive[0..n]);
        ws.slv.solve(rhs, x);

        const data = try a.alloc(f64, ctx.probes.len);
        errdefer a.free(data);
        for (ctx.probes, data) |row, *d| d.* = at(x, n, row).re;
        return .{
            .plotname = "DC Incremental Analysis",
            .varnames = try root.probeNames(ctx, null),
            .is_complex = false,
            .npoints = 1,
            .data = data,
        };
    }
};
