//! Adjoint DC sensitivity (`.sens`): one factorization at the operating point
//! and one transpose solve give λ (J^T λ = e_out). Each parameter then costs
//! one re-eval of F(x_op) and a dot product, dy/dp = -λ^T · dF/dp with dF/dp
//! a forward difference, instead of a Newton solve per parameter.
//! In: the circuit at its operating point and the output node pair. Out:
//! one real point of dVout/dp per parameter, named as ngspice names it.
//! Cites ngspice cktsens.c and the IF_PRINCIPAL tables of res.c, cap.c,
//! ind.c, vsrc.c and isrc.c; #71, #85, #91, #154;
//! dev/analysis/sensitivity.md.
const std = @import("std");
const root = @import("../types.zig");
const xf = @import("../dc/xf.zig");
const num = @import("core").numerics;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Sens;

/// Forward-difference step for a parameter at `orig`: ngspice's relative
/// 1e-6 (cktsens.c `Sens_Delta`), absolute 1e-12 only at 0. An absolute
/// floor added to the relative step would move a diode IS = 1e-14 by 100x
/// (#85). `.sens`, `.dcmatch` and `.acmatch` share it.
pub fn fdStep(orig: f64) f64 {
    return if (orig == 0) 1e-12 else 1e-6 * @abs(orig);
}

/// The adjoint of one output at an operating point, shared by `.sens`,
/// `.dcmatch` and `.dcsens`: λ from J^T λ = e_out, and the nominal F(x_op)
/// each forward difference subtracts. Both slices are n long.
pub const Adjoint = struct {
    lambda: []f64,
    rhs_nom: []f64,

    /// Evals F at `x_op`, factors J on the circuit workspace and solves for
    /// λ. Overwrites the circuit's planes and the workspace factorization.
    /// Errors: OutOfMemory, and SingularMatrix from the factor. Free with
    /// `deinit` on `allocator`.
    pub fn init(ckt: *root.Circuit, x_op: []const f64, out: xf.Output, allocator: std.mem.Allocator) !Adjoint {
        const n: usize = ckt.n;
        std.debug.assert(x_op.len >= n);
        const ws = try ckt.workspace();
        const lambda = try allocator.alloc(f64, n);
        errdefer allocator.free(lambda);
        const rhs_nom = try allocator.alloc(f64, n);
        errdefer allocator.free(rhs_nom);
        // The full stamp, as every perturbed eval is: `recomputeType` drops
        // the constant-Jacobian baseline, so an `evalNewton` nominal would
        // difference two different summations.
        ckt.eval(x_op, 0);
        @memcpy(rhs_nom, ckt.rhs[0..n]);
        try ws.slv.factor(ckt.g_vals, ckt.solver_execution);
        @memset(lambda, 0);
        out.seed(lambda);
        ws.slv.solveT(lambda, lambda);
        return .{ .lambda = lambda, .rhs_nom = rhs_nom };
    }

    /// Frees both slices; `allocator` is the one `init` took.
    pub fn deinit(self: Adjoint, allocator: std.mem.Allocator) void {
        allocator.free(self.lambda);
        allocator.free(self.rhs_nom);
    }

    /// dy/dp = -λ^T dF/dp by a forward difference that moves `p` to `to`
    /// and back. Returns 0 when the move would change the topology,
    /// error.ZeroDelta when it rounds away. Overwrites the circuit's planes.
    pub fn fd(self: Adjoint, ckt: *root.Circuit, x_op: []const f64, p: root.ParamRef, to: f64) error{ZeroDelta}!f64 {
        std.debug.assert(self.lambda.len == ckt.n);
        const orig = p.get();
        // Only this parameter moves and temperature does not, so re-deriving
        // its own device type is the whole recompute (Circuit.recomputeType).
        p.set(to);
        defer {
            p.set(orig);
            ckt.recomputeType(p.type) catch unreachable; // restores the checked original parameter
        }
        // A parameter whose nominal value collapses an internal node
        // (gummel_poon RC/RE = 0, mos1 RD/RS = 0, ...) is re-wired by the
        // absolute step at 0 (`fdStep`): `collapse` stops folding c' onto c,
        // the builder never allocated a distinct c', and the batch reports
        // TopologyChanged. The perturbed circuit has a node the frozen pattern
        // lacks, so the derivative is not representable; report 0 rather than
        // fail the analysis. ngspice never perturbs a topology parameter
        // (cktsens.c uses per-device analytic sensitivities, not a generic FD).
        ckt.recomputeType(p.type) catch |e| switch (e) {
            error.TopologyChanged => return 0,
        };
        // Difference against the step actually stored: an f32 parameter
        // rounds it, and the requested delta would give a wrong derivative,
        // not a small one.
        const delta = p.get() - orig;
        if (delta == 0) return error.ZeroDelta;
        ckt.eval(x_op, 0);
        // dF = F(p + δ) − F(p) in the plane itself; `num.dot`'s fixed fold
        // keeps `.sens` and `.dcmatch` (which shares it) bit-reproducible.
        const df = ckt.rhs[0..self.lambda.len];
        num.sub(df, df, self.rhs_nom);
        return -num.dot(self.lambda, df) / delta;
    }
};

/// dV(output_node, output_neg)/dp for each of `params` at `x_op`, parallel to
/// `params` and owned by `allocator`. `x_op` is the executor's operating point
/// (the full OP ladder; a plain Newton here fails on circuits that need
/// stepping). Each parameter is restored before the next. A parameter whose
/// step would change the topology reads 0, and so does one at its "infinite"
/// default 0 whose quotient does not survive a doubled step (#91).
/// Overwrites the circuit's planes and the workspace factorization. Returns
/// error.ZeroDelta when a parameter's step rounds away entirely.
pub fn solve(
    ckt: *root.Circuit,
    x_op: []const f64,
    params: []const root.ParamRef,
    output_node: u32,
    output_neg: u32,
    allocator: std.mem.Allocator,
) ![]f64 {
    // No `computeBaseline()`: the baseline would freeze the const-Jacobian
    // stamps (resistors) and mask the very perturbations being measured.
    const adj = try Adjoint.init(ckt, x_op, .{ .node = output_node, .neg = output_neg, .branch = null }, allocator);
    defer adj.deinit(allocator);

    const sens = try allocator.alloc(f64, params.len);
    errdefer allocator.free(sens);

    for (params, sens, 0..) |p, *out, index| {
        if (index != 0) try ckt.checkpoint(.{ .phase = .sweep, .completed = index, .total = params.len });
        const orig: f64 = p.get();
        out.* = try adj.fd(ckt, x_op, p, orig + fdStep(orig));
        // 0 is the "infinite" default of a 1/p parameter (gummel_poon VAF,
        // IKF: `inv_vaf = 0` unless vaf > 0), where dV/dp tends to 0, while
        // the step lands on a finite p and swaps the term in whole: the
        // quotient is roundoff-dominated and flips sign with line order
        // (#91). A smooth parameter's quotient barely moves when the step
        // doubles; this one's halves or worse, so it reports 0 as ngspice.
        if (orig == 0 and out.* != 0) {
            const twice = try adj.fd(ckt, x_op, p, 2 * fdStep(0));
            if (@abs(twice - out.*) > 0.25 * @abs(out.*)) out.* = 0;
        }
    }

    return sens;
}

/// ngspice's IF_PRINCIPAL parameter (IOPP/IOPAP in res.c, cap.c, ind.c,
/// vsrc.c, isrc.c) by device type; every other device has none, so all its
/// columns are `<card>:<param>` (`v(d1:is)`, #71).
const principal = std.StaticStringMap([]const u8).initComptime(.{
    .{ "resistor", "r" }, .{ "capacitor", "c" }, .{ "inductor", "l" },
    .{ "vsource", "dc" }, .{ "isource", "dc" },
});

/// Whether `.sens` lists parameter `name` of a `type_name` device. ngspice
/// lists device and model parameters but no source waveform (vsrc.c's
/// sensitivity table is `dc` and the port parameters) and no table entry,
/// which VerA flattens into one field per slot (`pwl_timesZ5b0Z5d`, #154).
pub fn isSensParam(type_name: []const u8, name: []const u8) bool {
    if (std.mem.indexOf(u8, name, "Z5b") != null) return false;
    const src = std.mem.eql(u8, type_name, "vsource") or std.mem.eql(u8, type_name, "isource");
    return !src or std.mem.eql(u8, name, "dc");
}

/// Contract entry: one real point, one column per collected device parameter
/// holding dVout/dp. Columns carry ngspice's names (cktsens.c:224-238):
///   model parameter                  -> `<card>:<param>`   (r1:tc1)
///   principal instance parameter     -> `<card>`           (r1)
///   any other instance parameter     -> `<card>_<param>`   (r1_scale)
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const all = try ctx.circuit.collectParams();
    var kept: std.ArrayList(root.ParamRef) = .empty;
    defer kept.deinit(scratch);
    for (all) |ref| if (isSensParam(ctx.circuit.typeName(ref.type), ref.param_name)) try kept.append(scratch, ref);
    const refs = kept.items;
    const sens = try solve(ctx.circuit, ctx.x_op, refs, opts.output_node, opts.output_neg, scratch);
    defer scratch.free(sens);

    const names = try a.alloc([]const u8, refs.len);
    errdefer a.free(names);
    var done: usize = 0;
    errdefer for (names[0..done]) |s| a.free(s);
    for (refs, names) |ref, *name| {
        const card = opts.card_names.get(ref.type, ref.index);
        const dev = card orelse try std.fmt.allocPrint(scratch, "{s}#{d}", .{ ctx.circuit.typeName(ref.type), ref.index });
        defer if (card == null) scratch.free(dev);
        // The table rather than is_instance: ngspice's IF_PRINCIPAL flag lives
        // on the instance parameter table, but VerA puts every Verilog-A
        // `parameter` on Model. The `v(...)` wrapper is ngspice's too:
        // cktsens.c hands the raw writer a UID_OTHER name, which types as a
        // voltage, so readers of an ngspice raw look the column up as
        // `v(r1)`. The instance's $mfactor is ngspice's instance parameter `m`.
        const pname = if (std.mem.eql(u8, ref.param_name, "mfactor")) "m" else ref.param_name;
        const is_principal = if (principal.get(ctx.circuit.typeName(ref.type))) |pp|
            std.mem.eql(u8, ref.param_name, pp)
        else
            false;
        if (is_principal) {
            name.* = try std.fmt.allocPrint(a, "v({s})", .{dev});
        } else {
            // ngspice prints keywords in lower case; gummel_poon spells
            // `VAR` upper case because `var` is a Zig keyword.
            const s = try std.fmt.allocPrint(a, "v({s}{s}{s})", .{ dev, if (ref.is_instance) "_" else ":", pname });
            name.* = std.ascii.lowerString(s, s);
        }
        done += 1;
    }
    const data = try a.dupe(f64, sens);

    return .{
        .plotname = "Sensitivity Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}
