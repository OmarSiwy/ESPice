//! Brute-force DC sensitivity: perturb one parameter, re-solve, finite-
//! difference the output node. One Workspace serves the nominal solve and
//! every perturbed solve — the pattern is frozen.
const std = @import("std");
const root = @import("../root.zig");
const dc = @import("../dc/dc.zig");
const converger = @import("../helper/converger.zig");

pub const SensParam = struct {
    ptr: *f32,
    device_name: []const u8,
    param_name: []const u8,
};

pub const SensEntry = struct {
    device_name: []const u8,
    param_name: []const u8,
    sensitivity: f64,
};

pub const Options = struct {
    tol: converger.Tolerances = .{},
    /// null → the last probe node.
    output_node: ?u32 = null,
    dc_opts: dc.Options = .{},
};

pub const SolveResult = struct {
    entries: []SensEntry,
    op_value: f64,

    pub fn deinit(self: *SolveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

pub fn solve(
    ckt: *root.Circuit,
    params: []const SensParam,
    output_node: u32,
    dc_opts: dc.Options,
    allocator: std.mem.Allocator,
) !SolveResult {
    const n: usize = ckt.n;

    // No computeBaseline() here: baseline would freeze const-Jacobian G
    // stamps (e.g. resistors) and mask the very perturbations we measure.
    const ws = try ckt.workspace();
    const nopts = dc_opts.tol.newtonOpts(dc_opts.tol.itl2);

    const x_op = try allocator.alloc(f64, n);
    defer allocator.free(x_op);

    @memset(x_op, 0);
    const dc_result = try converger.run(ckt, ws, x_op, 0, nopts, converger.EvalHook{});
    if (!dc_result.converged) return error.DcNotConverged;

    const v0 = x_op[output_node];

    const x_pert = try allocator.alloc(f64, n);
    defer allocator.free(x_pert);

    const entries = try allocator.alloc(SensEntry, params.len);
    errdefer allocator.free(entries);

    for (params, entries) |p, *entry| {
        const orig: f64 = p.ptr.*;
        const delta_req = 1e-6 * @abs(orig) + 1e-12;

        p.ptr.* = @floatCast(orig + delta_req);
        defer p.ptr.* = @floatCast(orig);
        ckt.recompute();
        // FD against the step the f32 actually took, not the requested one.
        const delta = @as(f64, p.ptr.*) - orig;

        @memset(x_pert, 0);
        const pert_result = try converger.run(ckt, ws, x_pert, 0, nopts, converger.EvalHook{});
        if (!pert_result.converged) return error.PerturbedDcNotConverged;

        const v_pert = x_pert[output_node];
        entry.* = .{
            .device_name = p.device_name,
            .param_name = p.param_name,
            .sensitivity = if (delta != 0) (v_pert - v0) / delta else 0,
        };
    }

    ckt.recompute();
    return .{ .entries = entries, .op_value = v0 };
}

/// Contract entry: every collected device parameter becomes one column
/// ("<type>#<index>.<param>"), one row of dVout/dp. Name strings live on
/// the run arena.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const output_node = opts.output_node orelse blk: {
        if (ctx.probes.len == 0) return error.NoOutputNode;
        break :blk ctx.probes[ctx.probes.len - 1];
    };

    const refs = try ctx.circuit.collectParams();
    const params = try a.alloc(SensParam, refs.len);
    defer a.free(params);
    for (refs, params) |ref, *p| p.* = .{
        .ptr = ref.ptr,
        .device_name = try std.fmt.allocPrint(a, "{s}#{d}", .{ ref.device_type, ref.index }),
        .param_name = ref.param_name,
    };

    var res = try solve(ctx.circuit, params, output_node, opts.dc_opts, a);
    defer res.deinit(a);

    const names = try a.alloc([]const u8, res.entries.len);
    const data = try a.alloc(f64, res.entries.len);
    for (res.entries, names, data) |e, *name, *out| {
        name.* = try std.fmt.allocPrint(a, "{s}.{s}", .{ e.device_name, e.param_name });
        out.* = e.sensitivity;
    }
    return .{
        .plotname = "DC Sensitivity",
        .varnames = names,
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}
