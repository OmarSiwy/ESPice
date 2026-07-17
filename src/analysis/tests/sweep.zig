//! DC and sweep-family tests: the pure helpers of dc, xf, dcmatch, sens and
//! temp_sweep, then every DC analysis on a resistive divider whose answers
//! are closed-form.

const DcmatchTests = struct {
    const impl = @import("../dc/dcmatch.zig");
    const pelgromSigma = impl.test_access.pelgromSigma;
    const root = @import("../types.zig");
    const std = @import("std");

    test "pelgromSigma — real coefficients" {
        const ref = root.ParamRef{
            .ptr = undefined,
            .param_name = "vth0",
            .index = 0,
            .is_instance = false,
            .primary = false,
            .pelgrom_ap = 4e-3, // 4 mV·um
            .area_wl = 1e-12, // 1 um^2
        };
        const sigma = pelgromSigma(ref);
        // sigma = 4e-3 / sqrt(1e-12) = 4e-3 / 1e-6 = 4000
        try std.testing.expectApproxEqRel(sigma, 4e3, 1e-12);
    }

    test "pelgromSigma — unit fallback when pelgrom_ap is zero" {
        const ref = root.ParamRef{
            .ptr = undefined,
            .param_name = "vth0",
            .index = 0,
            .is_instance = false,
            .primary = false,
            .pelgrom_ap = 0,
            .area_wl = 1e-12,
        };
        try std.testing.expectEqual(pelgromSigma(ref), 1.0);
    }

    test "pelgromSigma — unit fallback when area_wl is zero" {
        const ref = root.ParamRef{
            .ptr = undefined,
            .param_name = "vth0",
            .index = 0,
            .is_instance = false,
            .primary = false,
            .pelgrom_ap = 4e-3,
            .area_wl = 0,
        };
        try std.testing.expectEqual(pelgromSigma(ref), 1.0);
    }

    test "pelgromSigma — both zero gives unit fallback" {
        const ref = root.ParamRef{
            .ptr = undefined,
            .param_name = "vth0",
            .index = 0,
            .is_instance = false,
            .primary = false,
        };
        try std.testing.expectEqual(pelgromSigma(ref), 1.0);
    }
};

const SensTests = struct {
    const impl = @import("../sweep/sens.zig");
    const W = impl.test_access.W;
    const adjointFd = impl.adjointFd;
    const copySimd = impl.test_access.copySimd;
    const std = @import("std");
    const testing = std.testing;

    /// Scalar oracle for adjointFd: materialize dF/dp, then dot with the same
    /// lane fold.
    fn adjointFdOracle(lambda: []const f64, pert: []const f64, nom: []const f64, inv_delta: f64) f64 {
        var dfdp: [64]f64 = undefined;
        for (0..lambda.len) |i| dfdp[i] = (pert[i] - nom[i]) * inv_delta;
        const V = @Vector(W, f64);
        var acc: V = @splat(0.0);
        var i: usize = 0;
        while (i + W <= lambda.len) : (i += W) {
            const av: V = lambda[i..][0..W].*;
            const bv: V = dfdp[i..][0..W].*;
            acc += av * bv;
        }
        const arr: [W]f64 = acc;
        var s: f64 = 0;
        for (arr) |v| s += v;
        while (i < lambda.len) : (i += 1) s += lambda[i] * dfdp[i];
        return s;
    }

    test "adjointFd: matches the materialize-then-dot oracle bit for bit" {
        var prng = std.Random.DefaultPrng.init(0xfeed);
        const rng = prng.random();
        var lambda: [64]f64 = undefined;
        var pert: [64]f64 = undefined;
        var nom: [64]f64 = undefined;
        for (0..64) |i| {
            lambda[i] = rng.floatNorm(f64);
            nom[i] = rng.floatNorm(f64);
            pert[i] = nom[i] + 1e-7 * rng.floatNorm(f64);
        }
        // every length across the vector boundary, plus the empty and tail cases
        for (0..65) |n| {
            const inv_delta = 1.0 / 1e-7;
            try testing.expectEqual(
                adjointFdOracle(lambda[0..n], pert[0..n], nom[0..n], inv_delta),
                adjointFd(lambda[0..n], pert[0..n], nom[0..n], inv_delta),
            );
        }
    }

    test "adjointFd: known value" {
        // dF/dp = (pert - nom) / delta = (2,4,6)/2 = (1,2,3); λ·dF/dp = 4+10+18 = 32
        const lambda = [_]f64{ 4.0, 5.0, 6.0 };
        const nom = [_]f64{ 0.0, 0.0, 0.0 };
        const pert = [_]f64{ 2.0, 4.0, 6.0 };
        try testing.expectApproxEqAbs(@as(f64, 32.0), adjointFd(&lambda, &pert, &nom, 0.5), 1e-15);
    }

    test "copySimd: round-trip" {
        var dst: [5]f64 = undefined;
        const src = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
        copySimd(&dst, &src);
        for (dst, src) |d, s| try testing.expectEqual(s, d);
    }
};

const TempSweepTests = struct {
    const impl = @import("../sweep/temp_sweep.zig");
    const numPoints = impl.numPoints;
    const std = @import("std");
    const testing = std.testing;

    test "temp_sweep: numPoints calculation" {
        try testing.expectEqual(@as(u32, 166), numPoints(.{
            .t_start = -40.0,
            .t_stop = 125.0,
            .t_step = 1.0,
        }));
        try testing.expectEqual(@as(u32, 34), numPoints(.{
            .t_start = -40.0,
            .t_stop = 125.0,
            .t_step = 5.0,
        }));
        try testing.expectEqual(@as(u32, 1), numPoints(.{
            .t_start = 27.0,
            .t_stop = 27.0,
            .t_step = 1.0,
        }));
    }

    test "temp_sweep: numPoints edge cases" {
        // A non-positive step is one point, a descending span none.
        try testing.expectEqual(@as(u32, 1), numPoints(.{ .t_start = 0, .t_stop = 10, .t_step = 0 }));
        try testing.expectEqual(@as(u32, 1), numPoints(.{ .t_start = 0, .t_stop = 10, .t_step = -1 }));
        try testing.expectEqual(@as(u32, 0), numPoints(.{ .t_start = 10, .t_stop = 0, .t_step = 1 }));
        // The exact-integer ratio that lands just under itself keeps its endpoint.
        try testing.expectEqual(@as(u32, 131), numPoints(.{ .t_start = 0.3, .t_stop = 0.95, .t_step = 0.005 }));
        // A step that does not divide the span stops short of t_stop.
        try testing.expectEqual(@as(u32, 4), numPoints(.{ .t_start = 0, .t_stop = 1, .t_step = 0.3 }));
    }
};

const GroupsTests = struct {
    const std = @import("std");
    const t = std.testing;
    const root = @import("../types.zig");
    const Groups = @import("../dc/dcmatch.zig").Groups;
    const Variations = @import("core").query.Variations;

    var values = [_]f64{ 1, 2, 3 };
    const refs = [_]root.ParamRef{
        .{ .ptr = .{ .f64 = &values[0] }, .param_name = "a", .index = 0, .is_instance = false, .primary = true, .pelgrom_ap = 4e-3, .area_wl = 1e-12 },
        .{ .ptr = .{ .f64 = &values[1] }, .param_name = "b", .index = 1, .is_instance = false, .primary = true },
        .{ .ptr = .{ .f64 = &values[2] }, .param_name = "c", .index = 2, .is_instance = true, .primary = false },
    };
    const grouped: Variations = .{
        .labels = &.{ "a+c", "b" },
        .starts = &.{ 0, 2, 3 },
        .params = &.{ 0, 2, 1 },
        .sigmas = &.{ 0.1, 0.2, 0.3 },
    };

    test "Groups: without a variation block every parameter is its own Pelgrom group" {
        const g = try Groups.init(t.allocator, &refs, .{});
        defer g.deinit(t.allocator);
        try t.expectEqual(@as(usize, 3), g.count());
        for (0..3) |i| {
            const m = g.members(i);
            try t.expectEqual(@as(usize, 1), m.len);
            try t.expectEqual(@as(u32, @intCast(i)), m[0].param);
            try t.expectEqual(@as(f64, 1), m[0].scale);
        }
        try t.expectApproxEqRel(@as(f64, 4e3), g.sigma(0), 1e-12);
        try t.expectEqual(@as(f64, 1), g.sigma(1));

        const none = try Groups.init(t.allocator, &.{}, .{});
        defer none.deinit(t.allocator);
        try t.expectEqual(@as(usize, 0), none.count());
    }

    test "Groups: a variation block groups members at their one-sigma scale" {
        const g = try Groups.init(t.allocator, &refs, grouped);
        defer g.deinit(t.allocator);
        try t.expectEqual(@as(usize, 2), g.count());
        const m0 = g.members(0);
        try t.expectEqual(@as(usize, 2), m0.len);
        try t.expectEqual(@as(u32, 0), m0[0].param);
        try t.expectEqual(@as(f64, 0.1), m0[0].scale);
        try t.expectEqual(@as(u32, 2), m0[1].param);
        try t.expectEqual(@as(f64, 0.2), m0[1].scale);
        try t.expectEqual(@as(u32, 1), g.members(1)[0].param);
        // The members already carry the sigma, so the group's own is 1.
        try t.expectEqual(@as(f64, 1), g.sigma(0));
        const label = try g.label(t.allocator, undefined, &refs, 1);
        defer t.allocator.free(label);
        try t.expectEqualStrings("b", label);
    }

    test "Groups: a malformed variation table is rejected" {
        const bad = [_]Variations{
            .{ .starts = &.{ 0, 1 }, .params = &.{5}, .sigmas = &.{1} }, // past refs
            .{ .starts = &.{ 0, 2 }, .params = &.{0}, .sigmas = &.{1} }, // last offset past params
            .{ .starts = &.{ 1, 1 }, .params = &.{0}, .sigmas = &.{1} }, // does not start at 0
            .{ .starts = &.{ 0, 2, 1, 2 }, .params = &.{ 0, 1 }, .sigmas = &.{ 1, 1 } }, // decreasing
            .{ .starts = &.{ 0, 1 }, .params = &.{0}, .sigmas = &.{} }, // sigma missing
            .{ .labels = &.{ "x", "y" }, .starts = &.{ 0, 1 }, .params = &.{0}, .sigmas = &.{1} }, // label count
        };
        for (bad) |vars| try t.expectError(error.InvalidVariation, Groups.init(t.allocator, &refs, vars));
    }

    fn initAndFree(a: std.mem.Allocator, rs: []const root.ParamRef, vars: Variations) !void {
        const g = try Groups.init(a, rs, vars);
        g.deinit(a);
    }

    test "Groups: init frees everything on every allocation failure" {
        try t.checkAllAllocationFailures(t.allocator, initAndFree, .{ refs[0..], Variations{} });
        try t.checkAllAllocationFailures(t.allocator, initAndFree, .{ refs[0..], grouped });
    }
};

const XfTests = struct {
    const std = @import("std");
    const t = std.testing;
    const xf = @import("../dc/xf.zig");
    const XfSource = @import("core").query.XfSource;

    test "xf: at reads ground as zero and the stacked imaginary half" {
        const real = [_]f64{ 0, 1, 2 };
        try t.expectEqual(@as(f64, 0), xf.at(&real, 3, 0).re);
        try t.expectEqual(@as(f64, 2), xf.at(&real, 3, 2).re);
        try t.expectEqual(@as(f64, 0), xf.at(&real, 3, 2).im);
        const stacked = [_]f64{ 0, 1, 2, 9, 5, 6 };
        const z = xf.at(&stacked, 3, 2);
        try t.expectEqual(@as(f64, 2), z.re);
        try t.expectEqual(@as(f64, 6), z.im);
        try t.expectEqual(@as(f64, 0), xf.at(&stacked, 3, 0).im);
    }

    test "xf: excite drives a V branch or an I node pair, never ground" {
        var rhs = [_]f64{ 0, 0, 0, 0 };
        xf.excite(.{ .name = "v1", .branch = 3 }, &rhs);
        try t.expectEqualSlices(f64, &.{ 0, 0, 0, 1 }, &rhs);
        rhs = .{ 0, 0, 0, 0 };
        xf.excite(.{ .name = "i1", .branch = null, .nodes = .{ 0, 2 } }, &rhs);
        try t.expectEqualSlices(f64, &.{ 0, 0, 1, 0 }, &rhs);
        rhs = .{ 0, 0, 0, 0 };
        xf.excite(.{ .name = "i2", .branch = null, .nodes = .{ 1, 2 } }, &rhs);
        try t.expectEqualSlices(f64, &.{ 0, -1, 1, 0 }, &rhs);
    }

    test "xf: immittance reciprocals, and a zero reads as infinite" {
        const v: XfSource = .{ .name = "v1", .branch = 3 };
        // i_branch = -0.25 A per volt delivers 0.25 A: 4 ohm, 0.25 S.
        const zy = xf.immittance(v, &.{ 0, 0, 0, -0.25 }, 4);
        try t.expectApproxEqRel(@as(f64, 4), zy[0].re, 1e-15);
        try t.expectApproxEqRel(@as(f64, 0.25), zy[1].re, 1e-15);
        try t.expectEqual(xf.infinite, xf.immittance(v, &.{ 0, 0, 0, 0 }, 4)[0].re);
        const i: XfSource = .{ .name = "i1", .branch = null, .nodes = .{ 0, 2 } };
        const open = xf.immittance(i, &.{ 0, 0, 500, 0 }, 4);
        try t.expectEqual(@as(f64, 500), open[0].re);
        try t.expectApproxEqRel(@as(f64, 2e-3), open[1].re, 1e-15);
        try t.expectEqual(xf.infinite, xf.immittance(i, &.{ 0, 0, 0, 0 }, 4)[1].re);
    }

    test "xf: Output seeds and reads a node pair or a branch" {
        var rhs = [_]f64{ 0, 0, 0, 0 };
        const pair: xf.Output = .{ .node = 1, .neg = 2, .branch = null };
        pair.seed(&rhs);
        try t.expectEqualSlices(f64, &.{ 0, 1, -1, 0 }, &rhs);
        const x = [_]f64{ 0, 5, 2, 7 };
        try t.expectEqual(@as(f64, 3), pair.read(&x, 4).re);
        const single: xf.Output = .{ .node = 2, .neg = 0, .branch = null };
        try t.expectEqual(@as(f64, 2), single.read(&x, 4).re);
        rhs = .{ 0, 0, 0, 0 };
        const br: xf.Output = .{ .node = 1, .neg = 2, .branch = 3 };
        br.seed(&rhs);
        try t.expectEqualSlices(f64, &.{ 0, 0, 0, 1 }, &rhs);
        try t.expectEqual(@as(f64, 7), br.read(&x, 4).re);
    }

    const sources = [_]XfSource{
        .{ .name = "V1", .branch = 3 },
        .{ .name = "Iin", .branch = null, .nodes = .{ 0, 2 } },
    };

    test "xf: names, lowercased, after an optional first column" {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const full = try xf.names(a, null, &sources, false);
        try t.expectEqual(@as(usize, 6), full.len);
        for ([_][]const u8{ "tf(v1)", "zin(v1)", "yin(v1)", "tf(iin)", "zin(iin)", "yin(iin)" }, full) |want, got|
            try t.expectEqualStrings(want, got);
        const short = try xf.names(a, "frequency", &sources, true);
        try t.expectEqual(@as(usize, 3), short.len);
        try t.expectEqualStrings("frequency", short[0]);
        try t.expectEqualStrings("tf(v1)", short[1]);
        try t.expectEqualStrings("tf(iin)", short[2]);
    }

    fn namesAndFree(a: std.mem.Allocator, tf_only: bool) !void {
        const ns = try xf.names(a, null, &sources, tf_only);
        for (ns) |s| a.free(s);
        a.free(ns);
    }

    test "xf: names frees everything on every allocation failure" {
        try t.checkAllAllocationFailures(t.allocator, namesAndFree, .{false});
        try t.checkAllAllocationFailures(t.allocator, namesAndFree, .{true});
    }
};

/// Every DC analysis on 10 V across 1 kOhm over 3 kOhm, where v(out) =
/// 10 * R2 / (R1 + R2) = 7.5 V and each answer has a closed form.
const DividerTests = struct {
    const std = @import("std");
    const t = std.testing;
    const analysis = @import("../types.zig");
    const converger = @import("solver").converger;
    const Builder = @import("builder").Builder;
    const Library = @import("device").Library;
    const models = @import("models");
    const op = @import("../dc/op.zig");
    const dc = @import("../dc/dc.zig");
    const tf = @import("../dc/tf.zig");
    const xf = @import("../dc/xf.zig");
    const dcmatch = @import("../dc/dcmatch.zig");
    const sens = @import("../sweep/sens.zig");
    const lanes = @import("../sweep/lanes.zig");
    const mc = @import("../sweep/mc.zig");
    const temp_sweep = @import("../sweep/temp_sweep.zig");
    const GROUND = analysis.GROUND;
    const gpa = t.allocator;

    const vin: u32 = 1;
    const out: u32 = 2;
    const probes = [_]u32{out};
    const labels = [_][]const u8{"v(out)"};

    fn build(lib: *const Library) !@import("device").Circuit {
        var b = try Builder.init(gpa, lib);
        const n_in = try b.addNode();
        const n_out = try b.addNode();
        try t.expectEqual(vin, n_in);
        try t.expectEqual(out, n_out);
        try b.addDevice(models.vsource, "", .{ .dc = 10 }, .{}, .{ n_in, GROUND });
        try b.addDevice(models.resistor, "", .{ .r = 1000 }, .{}, .{ n_in, n_out });
        try b.addDevice(models.resistor, "", .{ .r = 3000 }, .{}, .{ n_out, GROUND });
        return b.compile();
    }

    fn branchRow(ckt: *const analysis.Circuit) !u32 {
        for (ckt.current_row, 0..) |is_branch, i| if (is_branch) return @intCast(i);
        return error.TestUnexpectedResult;
    }

    /// The ordinal in `refs` of the parameter `name` currently at `value`.
    fn paramIndex(refs: []const analysis.ParamRef, name: []const u8, value: f64) !u32 {
        for (refs, 0..) |r, i| if (std.mem.eql(u8, r.param_name, name) and r.get() == value) return @intCast(i);
        return error.TestUnexpectedResult;
    }

    fn ctxFor(ckt: *analysis.Circuit, x_op: []f64, results: std.mem.Allocator) !analysis.RunCtx {
        return .{
            .circuit = ckt,
            .x_op = x_op,
            .probes = &probes,
            .probe_labels = &labels,
            .source_node = vin,
            .source_branch = try branchRow(ckt),
            .allocator = results,
            .scratch_allocator = gpa,
        };
    }

    /// The divider's three parameters still at their nominals.
    fn expectNominals(ckt: *analysis.Circuit) !void {
        const refs = try ckt.collectParams();
        _ = try paramIndex(refs, "dc", 10);
        _ = try paramIndex(refs, "r", 1000);
        _ = try paramIndex(refs, "r", 3000);
    }

    test "op: divider operating point; nodesets and a standalone op's ic do not move it" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var prepared = try build(&lib);
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);

        const guess = [_]@import("core").Ic{.{ .node = out, .value = 1 }};
        for ([_][]const @import("core").Ic{ &.{}, &guess }, [_][]const @import("core").Ic{ &.{}, &.{} }) |nodeset, ic| {
            const r = try op.solve(&ckt, x, .{}, nodeset, ic);
            try t.expect(r.converged);
            try t.expectApproxEqAbs(@as(f64, 10), x[vin], 1e-9);
            try t.expectApproxEqAbs(@as(f64, 7.5), x[out], 1e-9);
        }
        // `ic` binds only a TRANOP.
        const r = try op.solve(&ckt, x, .{}, &.{}, &guess);
        try t.expect(r.converged);
        try t.expectApproxEqAbs(@as(f64, 7.5), x[out], 1e-9);
    }

    test "tf: gain, input and output resistance, for a voltage and a current input" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var prepared = try build(&lib);
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);
        try t.expect((try op.solve(&ckt, x, .{}, &.{}, &.{})).converged);

        const v = try tf.solve(&ckt, x, .{ .output_node = out }, try branchRow(&ckt), out, GROUND, gpa);
        try t.expectApproxEqRel(@as(f64, 0.75), v.gain, 1e-9);
        try t.expectApproxEqRel(@as(f64, 4000), v.input_resistance, 1e-9);
        try t.expectApproxEqRel(@as(f64, 750), v.output_resistance, 1e-9);
        // A unit current into `out`: the transimpedance and Rin are R1 || R2.
        const i = try tf.solve(&ckt, x, .{ .output_node = out, .input_nodes = .{ GROUND, out } }, 0, out, GROUND, gpa);
        try t.expectApproxEqRel(@as(f64, 750), i.gain, 1e-9);
        try t.expectApproxEqRel(@as(f64, 750), i.input_resistance, 1e-9);
        try t.expectApproxEqRel(@as(f64, 750), i.output_resistance, 1e-9);
    }

    test "dcxf: forward and adjoint transfers agree; dcinc follows the AC drive" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var prepared = try build(&lib);
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);
        try t.expect((try op.solve(&ckt, x, .{}, &.{}, &.{})).converged);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var ctx = try ctxFor(&ckt, x, arena.allocator());

        const sources = [_]@import("core").query.XfSource{
            .{ .name = "V1", .branch = ctx.source_branch },
            .{ .name = "I1", .branch = null, .nodes = .{ GROUND, out } },
        };
        const full = try xf.run(&ctx, .{ .output_node = out, .sources = &sources });
        try t.expectEqual(@as(usize, 6), full.data.len);
        for ([_]f64{ 0.75, 4000, 2.5e-4, 750, 750, 1.0 / 750.0 }, full.data) |want, got|
            try t.expectApproxEqRel(want, got, 1e-9);
        try t.expectEqualStrings("zin(v1)", full.varnames[1]);
        const adjoint = try xf.run(&ctx, .{ .output_node = out, .sources = &sources, .tf_only = true });
        try t.expectEqual(@as(usize, 2), adjoint.data.len);
        try t.expectApproxEqRel(full.data[0], adjoint.data[0], 1e-12);
        try t.expectApproxEqRel(full.data[3], adjoint.data[1], 1e-12);

        // No AC source: a zero response, as in ngspice.
        const quiet = try xf.Inc.run(&ctx, .{});
        try t.expectEqual(@as(f64, 0), quiet.data[0]);
        const drive = try arena.allocator().alloc(f64, 2 * ckt.n);
        @memset(drive, 0);
        drive[ctx.source_branch] = 1;
        ctx.ac_drive = drive;
        const inc = try xf.Inc.run(&ctx, .{});
        try t.expectApproxEqRel(@as(f64, 0.75), inc.data[0], 1e-9);
    }

    test "sens and dcmatch: closed-form dV/dp, and the two adjoint paths agree" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var prepared = try build(&lib);
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);
        try t.expect((try op.solve(&ckt, x, .{}, &.{}, &.{})).converged);

        const refs = try ckt.collectParams();
        const i_v = try paramIndex(refs, "dc", 10);
        const i_r1 = try paramIndex(refs, "r", 1000);
        const i_r2 = try paramIndex(refs, "r", 3000);
        const s = try sens.solve(&ckt, x, refs, out, GROUND, gpa);
        defer gpa.free(s);
        // v = V R2 / (R1 + R2): dv/dV = 0.75, dv/dR1 = -V R2 / 4e3^2, dv/dR2 = V R1 / 4e3^2.
        try t.expectApproxEqRel(@as(f64, 0.75), s[i_v], 1e-5);
        try t.expectApproxEqRel(@as(f64, -1.875e-3), s[i_r1], 1e-5);
        try t.expectApproxEqRel(@as(f64, 6.25e-4), s[i_r2], 1e-5);
        try expectNominals(&ckt);

        // Without a variation block dcmatch's columns are the same dy/dp.
        const each = try dcmatch.Groups.init(gpa, refs, .{});
        defer each.deinit(gpa);
        const m = try dcmatch.solve(&ckt, x, out, GROUND, refs, each, gpa);
        defer gpa.free(m.contributions);
        var total: f64 = 0;
        for (m.contributions, s) |c, want| {
            // Same step, different eval entry: equal up to the difference's
            // rounding, which cancellation lifts to ~1e-8 relative.
            try t.expectApproxEqAbs(want, c.sensitivity, 1e-12 + 1e-6 * @abs(want));
            total += c.variance_contrib;
        }
        try t.expectApproxEqRel(@sqrt(total), m.total_sigma, 1e-12);

        // Both resistors up by the same 1%: the ratio, and so v(out), holds.
        const members = [_]u32{ i_r1, i_r1, i_r2 };
        const vars: @import("core").query.Variations = .{
            .labels = &.{ "r1", "both" },
            .starts = &.{ 0, 1, 3 },
            .params = &members,
            .sigmas = &.{ 10, 10, 30 },
        };
        const grouped = try dcmatch.Groups.init(gpa, refs, vars);
        defer grouped.deinit(gpa);
        const g = try dcmatch.solve(&ckt, x, out, GROUND, refs, grouped, gpa);
        defer gpa.free(g.contributions);
        try t.expectApproxEqRel(@as(f64, -1.875e-2), g.contributions[0].sensitivity, 1e-5);
        try t.expectApproxEqAbs(@as(f64, 0), g.contributions[1].sensitivity, 1e-8);
        try t.expectApproxEqRel(@as(f64, 1.875e-2), g.total_sigma, 1e-5);
        try expectNominals(&ckt);
    }

    test "dc: source sweep, nested resistor sweep and temperature sweep, circuit restored" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var prepared = try build(&lib);
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);
        try t.expect((try op.solve(&ckt, x, .{}, &.{}, &.{})).converged);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const ctx = try ctxFor(&ckt, x, arena.allocator());
        const refs = try ckt.collectParams();
        const r2 = refs[try paramIndex(refs, "r", 3000)];
        const source: dc.Options.SweepTarget = .{ .device = .{ .type = Library.builtin("vsource"), .index = 0, .param_name = "dc" } };

        const inner = try dc.run(&ctx, .{ .start = 0, .stop = 10, .step = 5, .target = source });
        try t.expectEqual(@as(usize, 3), inner.npoints);
        try t.expectEqualStrings("v(v-sweep)", inner.varnames[0]);
        for ([_]f64{ 0, 0, 5, 3.75, 10, 7.5 }, inner.data) |want, got| try t.expectApproxEqAbs(want, got, 1e-9);
        try expectNominals(&ckt);

        const nested = try dc.run(&ctx, .{
            .start = 0,
            .stop = 10,
            .step = 5,
            .target = source,
            .target2 = .{ .device = .{ .type = r2.type, .index = r2.index, .param_name = "r" } },
            .points2 = &.{ 1000, 3000 },
        });
        try t.expectEqual(@as(usize, 6), nested.npoints);
        for ([_]f64{ 0, 0, 5, 2.5, 10, 5, 0, 0, 5, 3.75, 10, 7.5 }, nested.data) |want, got| try t.expectApproxEqAbs(want, got, 1e-9);
        try expectNominals(&ckt);

        const temp_c = ckt.temp_c;
        const temps = try dc.run(&ctx, .{ .start = 0, .stop = 50, .step = 25, .target = .temp });
        try t.expectEqualStrings("temp-sweep", temps.varnames[0]);
        for ([_]f64{ 0, 7.5, 25, 7.5, 50, 7.5 }, temps.data) |want, got| try t.expectApproxEqAbs(want, got, 1e-9);
        try t.expectEqual(temp_c, ckt.temp_c);

        try t.expectError(error.DcSweepSourceNotFound, dc.run(&ctx, .{ .target = .{ .device = .{ .type = Library.builtin("isource") } } }));
    }

    const R2Lanes = struct {
        ref: analysis.ParamRef,
        values: []const f64,
        nominal: f64,
        restores: u32 = 0,

        pub fn apply(self: *R2Lanes, k: usize) void {
            self.ref.set(self.values[k]);
        }

        pub fn restore(self: *R2Lanes) void {
            self.ref.set(self.nominal);
            self.restores += 1;
        }
    };

    test "solveLanes: warm and cold lanes agree with the closed form, nominals restored" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var prepared = try build(&lib);
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const n: usize = ckt.n;
        const refs = try ckt.collectParams();
        const values = [_]f64{ 1000, 2000, 3000 };
        var results: [values.len]converger.Result = undefined;
        const x_lanes = try gpa.alloc(f64, 2 * values.len * n);
        defer gpa.free(x_lanes);
        for ([_]bool{ false, true }, 0..) |warm, pass| {
            var setup: R2Lanes = .{ .ref = refs[try paramIndex(refs, "r", 3000)], .values = &values, .nominal = 3000 };
            const xs = x_lanes[pass * values.len * n ..][0 .. values.len * n];
            try lanes.solveLanes(&ckt, &setup, xs, &results, converger.optionsFromTolerances(.{}, null), warm);
            try t.expectEqual(@as(u32, 1), setup.restores);
            for (values, results, 0..) |r2, r, k| {
                try t.expect(r.converged);
                try t.expectApproxEqRel(10 * r2 / (1000 + r2), xs[k * n + out], 1e-9);
            }
            try expectNominals(&ckt);
        }
        for (x_lanes[0 .. values.len * n], x_lanes[values.len * n ..]) |cold, warm|
            try t.expectApproxEqAbs(cold, warm, 1e-9);
    }

    test "mc: zero variation is the nominal; a seed reproduces its trials" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var prepared = try build(&lib);
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);
        try t.expect((try op.solve(&ckt, x, .{}, &.{}, &.{})).converged);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const ctx = try ctxFor(&ckt, x, arena.allocator());

        const flat = try mc.run(&ctx, .{ .n_trials = 4, .variation = 0 });
        try t.expectEqual(@as(usize, 4), flat.npoints);
        for (0..4) |k| {
            try t.expectEqual(@as(f64, @floatFromInt(k)), flat.data[2 * k]);
            try t.expectApproxEqAbs(@as(f64, 7.5), flat.data[2 * k + 1], 1e-9);
        }
        const first = try mc.run(&ctx, .{ .n_trials = 8, .variation = 0.05, .seed = 7 });
        try expectNominals(&ckt);
        const again = try mc.run(&ctx, .{ .n_trials = 8, .variation = 0.05, .seed = 7 });
        try t.expectEqual(@as(usize, 8), first.npoints);
        try t.expectEqualSlices(f64, first.data, again.data);
        try expectNominals(&ckt);
    }

    test "temp_sweep: one row per temperature; the circuit's own temperature comes back, not t_nom" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var prepared = try build(&lib);
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);
        try t.expect((try op.solve(&ckt, x, .{}, &.{}, &.{})).converged);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const ctx = try ctxFor(&ckt, x, arena.allocator());

        const temp_c = ckt.temp_c;
        const r = try temp_sweep.run(&ctx, .{ .t_start = 0, .t_stop = 50, .t_step = 25, .t_nom = 99 });
        try t.expectEqual(@as(usize, 3), r.npoints);
        for ([_]f64{ 0, 7.5, 25, 7.5, 50, 7.5 }, r.data) |want, got| try t.expectApproxEqAbs(want, got, 1e-9);
        try t.expectEqual(temp_c, ckt.temp_c);
    }
};

test {
    _ = DcmatchTests;
    _ = SensTests;
    _ = TempSweepTests;
    _ = GroupsTests;
    _ = XfTests;
    _ = DividerTests;
    // In-file tests of the DC leaves.
    _ = @import("../dc/dc.zig");
}
