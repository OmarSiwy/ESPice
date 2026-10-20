//! DC and sweep-family tests: the pure helpers of dc, xf, dcmatch, sens and
//! temp_sweep, then every DC analysis on a resistive divider whose answers
//! are closed-form, and the transient's tangent blocks against reruns at
//! each row. The helpers check against hand-computed values or a
//! second path (materialize-then-dot for `adjointFd`, bit for bit).

const DcmatchTests = struct {
    const impl = @import("../dc/dcmatch.zig");
    const pelgromSigma = impl.test_access.pelgromSigma;
    const root = @import("../types.zig");
    const std = @import("std");

    test "pelgromSigma: A_P / sqrt(W·L), unit without Pelgrom data, 0 for mfactor" {
        // 4 mV·um over 1 um^2: 4e-3 / sqrt(1e-12) = 4000.
        const cases = [_]struct { name: []const u8, ap: f64, wl: f64, want: f64 }{
            .{ .name = "vth0", .ap = 4e-3, .wl = 1e-12, .want = 4e3 },
            .{ .name = "vth0", .ap = 0, .wl = 1e-12, .want = 1 },
            .{ .name = "vth0", .ap = 4e-3, .wl = 0, .want = 1 },
            .{ .name = "vth0", .ap = 0, .wl = 0, .want = 1 },
            .{ .name = "mfactor", .ap = 0, .wl = 0, .want = 0 },
        };
        for (cases) |c| {
            const ref: root.ParamRef = .{ .ptr = undefined, .param_name = c.name, .index = 0, .is_instance = false, .primary = false, .pelgrom_ap = c.ap, .area_wl = c.wl };
            try std.testing.expectApproxEqRel(c.want, pelgromSigma(ref), 1e-12);
        }
    }
};

const SensTests = struct {
    const impl = @import("../sweep/sens.zig");
    const std = @import("std");
    const testing = std.testing;

    test "fdStep: relative to the parameter, absolute only at 0 (#85)" {
        // IS = 1e-14 steps by 1e-20, not by a 1e-12 floor that is 100 IS.
        try testing.expectEqual(@as(f64, 1e-6 * 1e-14), impl.fdStep(1e-14));
        try testing.expectEqual(@as(f64, 1e-6 * 1e3), impl.fdStep(-1e3));
        try testing.expectEqual(@as(f64, 1e-12), impl.fdStep(0));
    }

    test "isSensParam: a source's dc, no waveform or table entry (#154)" {
        try testing.expect(impl.isSensParam("vsource", "dc"));
        try testing.expect(impl.isSensParam("isource", "dc"));
        try testing.expect(!impl.isSensParam("vsource", "acmag"));
        try testing.expect(!impl.isSensParam("vsource", "pulse_v1"));
        try testing.expect(!impl.isSensParam("vsource", "mfactor"));
        try testing.expect(!impl.isSensParam("vsource", "pwl_timesZ5b0Z5d"));
        try testing.expect(!impl.isSensParam("bsource", "coefZ5b3Z5d"));
        try testing.expect(impl.isSensParam("gummel_poon", "VAR"));
        try testing.expect(impl.isSensParam("resistor", "mfactor"));
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
        try t.expectApproxEqRel(@as(f64, 4e3), g.sigmas[0], 1e-12);
        try t.expectEqual(@as(f64, 1), g.sigmas[1]);

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
        try t.expectEqual(@as(f64, 1), g.sigmas[0]);
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
        try t.checkAllAllocationFailures(@import("core").testing.fixed_growth, initAndFree, .{ refs[0..], Variations{} });
        try t.checkAllAllocationFailures(@import("core").testing.fixed_growth, initAndFree, .{ refs[0..], grouped });
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

    test "xf: immittance reciprocals, and only an exact zero reads as infinite" {
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
        // VACASK clamps only an exact zero (coredcxf.cpp:268-282): a tiny
        // value inverts, as 1.0/yin does there, and a real one exactly (#199).
        try t.expectApproxEqRel(@as(f64, 1e30), xf.immittance(v, &.{ 0, 0, 0, -1e-30 }, 4)[0].re, 1e-15);
        try t.expectApproxEqRel(@as(f64, 1e160), xf.immittance(v, &.{ 0, 0, 0, -1e-160 }, 4)[0].re, 1e-15);
        try t.expectApproxEqRel(@as(f64, 1e25), xf.immittance(i, &.{ 0, 0, 1e-25, 0 }, 4)[1].re, 1e-15);
        // A complex 1e-160 phasor: |y|² underflows, Smith's division does
        // not. 1/(a + ja) = (1 - j)/(2a).
        const ac = xf.immittance(v, &.{ 0, 0, 0, -1e-160, 0, 0, 0, -1e-160 }, 4)[0];
        try t.expectApproxEqRel(@as(f64, 5e159), ac.re, 1e-15);
        try t.expectApproxEqRel(@as(f64, -5e159), ac.im, 1e-15);
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
        try t.checkAllAllocationFailures(@import("core").testing.fixed_growth, namesAndFree, .{false});
        try t.checkAllAllocationFailures(@import("core").testing.fixed_growth, namesAndFree, .{true});
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
        try b.addDevice(models.vsource, "", &.{ .dc = 10 }, &.{}, .{ n_in, GROUND });
        try b.addDevice(models.resistor, "", &.{ .r = 1000 }, &.{}, .{ n_in, n_out });
        try b.addDevice(models.resistor, "", &.{ .r = 3000 }, &.{}, .{ n_out, GROUND });
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

        const v = try tf.solve(&ckt, x, .{ .output_node = out }, try branchRow(&ckt), gpa);
        try t.expectApproxEqRel(@as(f64, 0.75), v.gain, 1e-9);
        try t.expectApproxEqRel(@as(f64, 4000), v.input_resistance, 1e-9);
        try t.expectApproxEqRel(@as(f64, 750), v.output_resistance, 1e-9);
        // A unit current into `out`: the transimpedance and Rin are R1 || R2.
        const i = try tf.solve(&ckt, x, .{ .output_node = out, .input_nodes = .{ GROUND, out } }, 0, gpa);
        try t.expectApproxEqRel(@as(f64, 750), i.gain, 1e-9);
        try t.expectApproxEqRel(@as(f64, 750), i.input_resistance, 1e-9);
        try t.expectApproxEqRel(@as(f64, 750), i.output_resistance, 1e-9);
    }

    test "tf: a source that moves no current reads 1e20 ohm, as ngspice does" {
        // ngspice-45 on the divider plus an open `V2 c 0 1`: `tf i(V2) V2`
        // prints 0, 1e20, 1e20, and `tf v(out) V2` 0, 1e20, 750.
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var b = try Builder.init(gpa, &lib);
        const n_in = try b.addNode();
        const n_out = try b.addNode();
        const n_c = try b.addNode();
        try b.addDevice(models.vsource, "", &.{ .dc = 10 }, &.{}, .{ n_in, GROUND });
        try b.addDevice(models.resistor, "", &.{ .r = 1000 }, &.{}, .{ n_in, n_out });
        try b.addDevice(models.resistor, "", &.{ .r = 3000 }, &.{}, .{ n_out, GROUND });
        try b.addDevice(models.vsource, "", &.{ .dc = 1 }, &.{}, .{ n_c, GROUND });
        var prepared = try b.compile();
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);
        try t.expect((try op.solve(&ckt, x, .{}, &.{}, &.{})).converged);
        // V2's branch: the one branch row that carries no current.
        const br2: u32 = for (ckt.current_row, x, 0..) |is_branch, current, row| {
            if (is_branch and current == 0) break @intCast(row);
        } else return error.TestUnexpectedResult;

        const i = try tf.solve(&ckt, x, .{ .output_node = n_out, .output_branch = br2 }, br2, gpa);
        try t.expectEqual(@as(f64, 0), i.gain);
        try t.expectEqual(@as(f64, 1e20), i.input_resistance);
        try t.expectEqual(@as(f64, 1e20), i.output_resistance);
        const v = try tf.solve(&ckt, x, .{ .output_node = n_out }, br2, gpa);
        try t.expectEqual(@as(f64, 0), v.gain);
        try t.expectEqual(@as(f64, 1e20), v.input_resistance);
        try t.expectApproxEqRel(@as(f64, 750), v.output_resistance, 1e-9);
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
            // One `Adjoint` serves both, and a unit scale is exact: bit for
            // bit, except where `.sens` zeroed a roundoff quotient at p = 0
            // (#91), a rule dcmatch does not apply.
            if (want != 0) try t.expectEqual(want, c.sensitivity) else try t.expectApproxEqAbs(want, c.sensitivity, 1e-12);
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

        // Tangent rows: row 1 sets R2 to 3.3k, row 2 sets R1 to 1.1k. Each
        // block is v(out) + dv with dv = -(F(row) - F) / (g1 + g2), F the
        // out row's current g1 (v(out) - vin) + g2 v(out): the input node is
        // held by V1, so only v(out) moves.
        var tctx = ctx;
        const ri = try paramIndex(refs, "r", 1000);
        const ro = try paramIndex(refs, "r", 3000);
        tctx.variants = .{ .labels = &.{ "", "", "" }, .temp_c = &.{ null, null, null }, .axis = &.{ 0, 0, 0 }, .starts = &.{ 0, 0, 1, 2 }, .refs = &.{ ro, ri }, .values = &.{ 3300, 1100 } };
        const Tangent = struct {
            fn predict(vs: f64, ra: f64, rb: f64, ra_row: f64, rb_row: f64) f64 {
                const g1 = 1 / ra;
                const g2 = 1 / rb;
                const vo = vs * rb / (ra + rb);
                const df = (1 / ra_row - g1) * (vo - vs) + (1 / rb_row - g2) * vo;
                return vo - df / (g1 + g2);
            }
        };
        const tangents = try dc.run(&tctx, .{ .start = 0, .stop = 10, .step = 5, .target = source, .tangents = &.{ 1, 2 } });
        try t.expectEqual(@as(usize, 9), tangents.npoints);
        for (0..3) |k| for (0..3) |p| {
            const vs: f64 = 5 * @as(f64, @floatFromInt(p));
            const want = switch (k) {
                0 => vs * 0.75,
                1 => Tangent.predict(vs, 1000, 3000, 1000, 3300),
                else => Tangent.predict(vs, 1000, 3000, 1100, 3000), // else: k is 0..2
            };
            try t.expectEqual(vs, tangents.data[(3 * k + p) * 2]);
            try t.expectApproxEqRel(want, tangents.data[(3 * k + p) * 2 + 1], 1e-12);
        };
        try expectNominals(&ckt);
        // Under an outer sweep the tangent block follows every outer level.
        const nested_tangent = try dc.run(&tctx, .{
            .start = 0,
            .stop = 10,
            .step = 5,
            .target = source,
            .target2 = .{ .device = .{ .type = r2.type, .index = r2.index, .param_name = "r" } },
            .points2 = &.{ 1000, 3000 },
            .tangents = &.{2},
        });
        try t.expectEqual(@as(usize, 12), nested_tangent.npoints);
        for (0..2) |po| for (0..3) |p| {
            const vs: f64 = 5 * @as(f64, @floatFromInt(p));
            const r2v: f64 = if (po == 0) 1000 else 3000;
            const row = (6 + 3 * po + p) * 2;
            try t.expectApproxEqRel(Tangent.predict(vs, 1000, r2v, 1100, r2v), nested_tangent.data[row + 1], 1e-12);
        };
        try expectNominals(&ckt);

        const temp_c = ckt.temp_c;
        const temps = try dc.run(&ctx, .{ .start = 0, .stop = 50, .step = 25, .target = .temp });
        try t.expectEqualStrings("temp-sweep", temps.varnames[0]);
        for ([_]f64{ 0, 7.5, 25, 7.5, 50, 7.5 }, temps.data) |want, got| try t.expectApproxEqAbs(want, got, 1e-9);
        try t.expectEqual(temp_c, ckt.temp_c);

        try t.expectError(error.DcSweepSourceNotFound, dc.run(&ctx, .{ .target = .{ .device = .{ .type = Library.builtin("isource") } } }));
    }

    test "tran: tangent blocks match the transient run at each row, to first order" {
        const tran = @import("../tran/tran.zig");
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var b = try Builder.init(gpa, &lib);
        _ = try b.addNode();
        _ = try b.addNode();
        try b.addDevice(models.vsource, "", &.{ .dc = 0.5, .waveform = 2, .sin_vo = 0.5, .sin_va = 1, .sin_freq = 1e3 }, &.{}, .{ vin, GROUND });
        try b.addDevice(models.resistor, "", &.{ .r = 1000 }, &.{}, .{ vin, out });
        try b.addDevice(models.capacitor, "", &.{ .c = 1e-7 }, &.{}, .{ out, GROUND });
        var prepared = try b.compile();
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);
        try t.expect((try op.solve(&ckt, x, .{}, &.{}, &.{})).converged);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var ctx = try ctxFor(&ckt, x, arena.allocator());
        const refs = try ckt.collectParams();
        const ri = try paramIndex(refs, "r", 1000);
        const ci = try paramIndex(refs, "c", 1e-7);
        // Row 1 moves R by 1e-4, row 2 moves C by 1e-4. A huge TRTOL keeps
        // the LTE off the grid, so every run steps on the same times.
        ctx.variants = .{ .labels = &.{ "", "", "" }, .temp_c = &.{ null, null, null }, .axis = &.{ 0, 0, 0 }, .starts = &.{ 0, 0, 1, 2 }, .refs = &.{ ri, ci }, .values = &.{ 1000.1, 1.0001e-7 } };
        const opts: tran.Options = .{ .t_stop = 2e-3, .dt_init = 1e-5, .dt_max = 1e-5, .tol = .{ .trtol = 1e12 } };
        const plain = try tran.run(&ctx, opts);
        var with = opts;
        with.tangents = &.{ 1, 2 };
        const tangents = try tran.run(&ctx, with);
        const len = plain.npoints;
        try t.expectEqual(len, tangents.npoints);
        try t.expectEqualSlices(f64, plain.data, tangents.data);
        try t.expectEqual(2 * 2 * len, tangents.tangents.len);
        for ([_]analysis.ParamRef{ refs[ri], refs[ci] }, [_]f64{ 1000.1, 1.0001e-7 }, 1..) |ref, value, k| {
            const nominal = ref.get();
            ref.set(value);
            try ckt.recompute();
            const row = try tran.run(&ctx, opts);
            ref.set(nominal);
            try ckt.recompute();
            try t.expectEqual(len, row.npoints);
            const block = tangents.tangents[2 * len * (k - 1) ..][0 .. 2 * len];
            var moved: f64 = 0;
            for (0..len) |p| moved = @max(moved, @abs(row.data[2 * p + 1] - plain.data[2 * p + 1]));
            try t.expect(moved > 1e-5);
            // The error is second order in the step, from the base run's
            // matrix standing in for the row's: 0.3% of the move for C.
            for (0..len) |p| {
                try t.expectEqual(row.data[2 * p], block[2 * p]);
                try t.expectApproxEqAbs(row.data[2 * p + 1], block[2 * p + 1], 1e-2 * moved);
            }
        }
        try t.expectEqual(@as(f64, 1000), refs[ri].get());
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
        const refs = try ckt.collectParams();
        const values = [_]f64{ 1000, 2000, 3000 };
        var results: [values.len]converger.Result = undefined;
        var rows: [2][values.len]f64 = undefined;
        const warm_x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(warm_x);
        @memset(warm_x, 0);
        for ([_]?[]const f64{ null, warm_x }, &rows) |warm, *pass_rows| {
            var setup: R2Lanes = .{ .ref = refs[try paramIndex(refs, "r", 3000)], .values = &values, .nominal = 3000 };
            try lanes.solveLanes(&ckt, &setup, 0, &probes, pass_rows, &results, converger.optionsFromTolerances(.{}, null), warm, gpa);
            try t.expectEqual(@as(u32, 1), setup.restores);
            for (values, results, pass_rows) |r2, r, v| {
                try t.expect(r.converged);
                try t.expectApproxEqRel(10 * r2 / (1000 + r2), v, 1e-9);
            }
            try expectNominals(&ckt);
        }
        for (rows[0], rows[1]) |cold, warm| try t.expectApproxEqAbs(cold, warm, 1e-9);
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
        // Trial k's draw depends only on the seed and k: a shorter run is a
        // prefix, and another seed moves the trials.
        const prefix = try mc.run(&ctx, .{ .n_trials = 3, .variation = 0.05, .seed = 7 });
        try t.expectEqualSlices(f64, first.data[0..prefix.data.len], prefix.data);
        const other = try mc.run(&ctx, .{ .n_trials = 8, .variation = 0.05, .seed = 8 });
        try t.expect(!std.mem.eql(f64, first.data, other.data));
        // Any trial computes alone: lane k is row k of the whole run, its
        // run column 0.
        for (0..8) |k| {
            const one = try mc.run(&ctx, .{ .n_trials = 8, .variation = 0.05, .seed = 7, .lane = @intCast(k) });
            try t.expectEqualSlices(f64, &.{ 0, first.data[2 * k + 1] }, one.data);
        }
        try expectNominals(&ckt);
    }

    test "temp_sweep: one row per temperature; the circuit's own temperature comes back" {
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
        const r = try temp_sweep.run(&ctx, .{ .t_start = 0, .t_stop = 50, .t_step = 25 });
        try t.expectEqual(@as(usize, 3), r.npoints);
        for ([_]f64{ 0, 7.5, 25, 7.5, 50, 7.5 }, r.data) |want, got| try t.expectApproxEqAbs(want, got, 1e-9);
        try t.expectEqual(temp_c, ckt.temp_c);
        const one = try temp_sweep.run(&ctx, .{ .t_start = 0, .t_stop = 50, .t_step = 25, .lane = 2 });
        try t.expectEqualSlices(f64, r.data[4..6], one.data);
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
