//! Cross-simulator waveform comparison; fixture correctness uses the numeric
//! oracles in test_correctness.zig instead of this relative waveform metric.
const std = @import("std");
const Io = std.Io;
pub const Accuracy = struct { complete: bool = true, max_rel: f64, rms_rel: f64, pass: bool };

pub const Plot = struct {
    plotname: []const u8,
    varnames: []const []const u8,
    is_complex: bool,
    npoints: usize,
    nvars: usize,
    data: []const f64,
};

pub fn parseRawFile(io: Io, gpa: std.mem.Allocator, path: []const u8) ?[]const Plot {
    const blob = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return null;
    return parseRawBlob(gpa, blob);
}

pub fn parseRawBlob(gpa: std.mem.Allocator, blob: []const u8) ?[]const Plot {
    var plots: std.ArrayList(Plot) = .empty;
    var rest = blob;
    while (std.mem.trim(u8, rest, " \t\r\n").len != 0) {
        const parsed = parseOnePlot(gpa, rest) orelse return null;
        plots.append(gpa, parsed.plot) catch return null;
        rest = rest[parsed.consumed..];
    }
    if (plots.items.len == 0) return null;
    return plots.items;
}

fn parseOnePlot(gpa: std.mem.Allocator, blob: []const u8) ?struct { plot: Plot, consumed: usize } {
    if (blob.len == 0) return null;

    var plotname: []const u8 = "";
    var nvars: usize = 0;
    var npoints: usize = 0;
    var is_complex = false;
    var varnames: std.ArrayList([]const u8) = .empty;
    var in_vars = false;
    var binary_offset: ?usize = null;

    var pos: usize = 0;
    while (pos < blob.len) {
        const nl = std.mem.indexOfScalarPos(u8, blob, pos, '\n') orelse blob.len;
        const raw_line = blob[pos..nl];
        const line = std.mem.trim(u8, raw_line, " \t\r");
        pos = @min(nl + 1, blob.len);

        if (std.mem.startsWith(u8, line, "Binary:")) {
            binary_offset = pos;
            break;
        }

        const lower = std.ascii.allocLowerString(gpa, line) catch return null;
        if (std.mem.startsWith(u8, lower, "plotname:")) {
            plotname = std.mem.trim(u8, line["Plotname:".len..], " \t");
        } else if (std.mem.startsWith(u8, lower, "flags:")) {
            is_complex = std.mem.indexOf(u8, lower, "complex") != null;
        } else if (std.mem.startsWith(u8, lower, "no. variables:")) {
            nvars = std.fmt.parseInt(usize, std.mem.trim(u8, line["No. Variables:".len..], " \t"), 10) catch return null;
        } else if (std.mem.startsWith(u8, lower, "no. points:")) {
            npoints = std.fmt.parseInt(usize, std.mem.trim(u8, line["No. Points:".len..], " \t"), 10) catch return null;
        } else if (std.mem.startsWith(u8, lower, "variables:")) {
            in_vars = true;
        } else if (in_vars and raw_line.len > 0 and (raw_line[0] == '\t' or std.ascii.isDigit(raw_line[0]))) {
            var fields = std.mem.splitScalar(u8, raw_line, '\t');
            _ = fields.next(); // empty before first tab (or index)
            _ = fields.next(); // index
            if (fields.next()) |name_field| {
                const name = std.ascii.allocLowerString(gpa, std.mem.trim(u8, name_field, " \t")) catch return null;
                varnames.append(gpa, normalizeVarName(gpa, name)) catch return null;
            }
        } else if (in_vars and line.len > 0 and raw_line.len > 0 and raw_line[0] != '\t' and !std.ascii.isDigit(raw_line[0])) {
            in_vars = false;
        }
    }

    if (binary_offset == null or nvars == 0 or npoints == 0 or varnames.items.len != nvars) return null;
    const boff = binary_offset.?;

    const per: usize = if (is_complex) 2 else 1;
    const count = std.math.mul(usize, std.math.mul(usize, nvars, npoints) catch return null, per) catch return null;
    const need = std.math.mul(usize, count, @sizeOf(f64)) catch return null;
    if (need > blob.len - boff) return null;

    const data = gpa.alloc(f64, count) catch return null;
    @memcpy(std.mem.sliceAsBytes(data), blob[boff .. boff + need]);

    return .{
        .plot = .{
            .plotname = plotname,
            .varnames = varnames.items,
            .is_complex = is_complex,
            .npoints = npoints,
            .nvars = nvars,
            .data = data,
        },
        .consumed = boff + need,
    };
}

fn normalizeVarName(gpa: std.mem.Allocator, lower: []const u8) []const u8 {
    if (scale_names.has(lower)) return lower;
    if (scale_aliases.get(lower)) |canonical| return canonical;
    if (std.mem.startsWith(u8, lower, "v(") or std.mem.startsWith(u8, lower, "i(")) return lower;
    const branch = std.mem.indexOf(u8, lower, "#branch") orelse std.mem.indexOf(u8, lower, ":flow(");
    if (branch) |cut| return std.fmt.allocPrint(gpa, "i({s})", .{lower[0..cut]}) catch lower;
    return std.fmt.allocPrint(gpa, "v({s})", .{lower}) catch lower;
}

fn compareRawFiles(io: Io, gpa: std.mem.Allocator, ng_path: []const u8, zp_path: []const u8, rtol: f64) ?Accuracy {
    const ng = parseRawFile(io, gpa, ng_path) orelse return null;
    const zp = parseRawFile(io, gpa, zp_path) orelse return null;
    return compareRaws(gpa, ng, zp, rtol);
}

pub fn compareRaws(gpa: std.mem.Allocator, ng: []const Plot, zp: []const Plot, rtol: f64) ?Accuracy {
    var worst: Accuracy = .{ .max_rel = 0, .rms_rel = 0, .pass = true };
    var scored: usize = 0;
    const taken = gpa.alloc(bool, zp.len) catch return null;
    defer gpa.free(taken);
    @memset(taken, false);
    const pair = gpa.alloc(?usize, ng.len) catch return null;
    defer gpa.free(pair);
    for (&[_]bool{ true, false }) |exact| {
        for (ng, pair) |ng_plot, *slot| {
            if (exact) slot.* = null else if (slot.* != null) continue;
            var ng_buf: [128]u8 = undefined;
            const ng_key = if (exact) plotLower(&ng_buf, ng_plot.plotname) else plotClass(&ng_buf, ng_plot.plotname);
            slot.* = for (zp, 0..) |zp_plot, i| {
                if (taken[i]) continue;
                var zp_buf: [128]u8 = undefined;
                const zp_key = if (exact) plotLower(&zp_buf, zp_plot.plotname) else plotClass(&zp_buf, zp_plot.plotname);
                if (std.mem.eql(u8, ng_key, zp_key)) break i;
            } else null;
            if (slot.*) |i| taken[i] = true;
        }
    }

    for (ng, pair) |ng_plot, matched| {
        const zi = matched orelse {
            worst.complete = false;
            continue;
        };
        const acc = comparePlots(gpa, ng_plot, zp[zi], rtol) orelse {
            worst.complete = false;
            continue;
        };
        scored += 1;
        worst.complete = worst.complete and acc.complete;
        worst.pass = worst.pass and acc.pass;
        worst.max_rel = @max(worst.max_rel, acc.max_rel);
        worst.rms_rel = @max(worst.rms_rel, acc.rms_rel);
    }
    if (scored == 0) return null;
    worst.pass = worst.pass and worst.complete;
    return worst;
}

fn comparePlots(gpa: std.mem.Allocator, ng: Plot, zp: Plot, rtol: f64) ?Accuracy {
    if (ng.is_complex != zp.is_complex) return null;
    var ng_name_buf: [128]u8 = undefined;
    var zp_name_buf: [128]u8 = undefined;
    const ng_class = plotClass(&ng_name_buf, ng.plotname);
    const zp_class = plotClass(&zp_name_buf, zp.plotname);
    if (!std.mem.eql(u8, ng_class, zp_class)) return null;
    for (ng.data) |value| if (!std.math.isFinite(value)) return .{ .max_rel = std.math.inf(f64), .rms_rel = std.math.inf(f64), .pass = false };
    for (zp.data) |value| if (!std.math.isFinite(value)) return .{ .max_rel = std.math.inf(f64), .rms_rel = std.math.inf(f64), .pass = false };

    const interpolate = std.mem.indexOf(u8, ng_class, "transient") != null;

    var columns: std.StringHashMapUnmanaged(usize) = .empty;
    defer columns.deinit(gpa);
    columns.ensureTotalCapacity(gpa, std.math.cast(u32, zp.varnames.len) orelse return null) catch return null;
    for (zp.varnames, 0..) |name, i| {
        const entry = columns.getOrPutAssumeCapacity(name);
        if (!entry.found_existing) entry.value_ptr.* = i;
    }

    const ng_columns = gpa.alloc(f64, 2 * ng.npoints) catch return null;
    defer gpa.free(ng_columns);
    const zp_columns = gpa.alloc(f64, 2 * zp.npoints) catch return null;
    defer gpa.free(zp_columns);
    const ng_scale = ng_columns[0..ng.npoints];
    const zp_scale = zp_columns[0..zp.npoints];
    const ng_var = ng_columns[ng.npoints..];
    const zp_var = zp_columns[zp.npoints..];
    const parts: usize = if (ng.is_complex) 2 else 1;
    extractCol(ng.data, ng.nvars, 0, parts, 0, ng_scale);
    extractCol(zp.data, zp.nvars, 0, parts, 0, zp_scale);
    if (interpolate) {
        if (zp_scale[0] > ng_scale[0] or zp_scale[zp_scale.len - 1] < ng_scale[ng_scale.len - 1]) return null;
    } else if (ng.npoints != zp.npoints) return null;

    var worst_max: f64 = 0;
    var worst_rms: f64 = 0;
    var any = false;
    var complete = true;

    for (ng.varnames, 0..) |ng_name, ni| {
        if (interpolate and scale_names.has(ng_name)) continue;
        const zi = columns.get(ng_name) orelse {
            if (isInternalNode(ng_name)) continue;
            if (scale_names.has(ng_name)) continue;
            complete = false;
            continue;
        };
        for (0..parts) |part| {
            extractCol(ng.data, ng.nvars, ni, parts, part, ng_var);
            extractCol(zp.data, zp.nvars, zi, parts, part, zp_var);

            const peak = colPeak(ng_var);
            const ptp = colPtp(ng_var);
            const denom = @max(peak, ptp, 1.0);
            if (!std.math.isFinite(denom)) return .{ .max_rel = std.math.inf(f64), .rms_rel = std.math.inf(f64), .pass = false };

            var sum_sq: f64 = 0;
            var max_err: f64 = 0;
            var count: usize = 0;

            var j: usize = 0;

            for (ng_scale, ng_var, 0..) |x, ya, i| {
                var yb = if (interpolate) interp(zp_scale, zp_var, x) else blk: {
                    if (count < zp_var.len) break :blk zp_var[count] else return null;
                };
                if (!std.math.isFinite(yb)) return .{ .max_rel = std.math.inf(f64), .rms_rel = std.math.inf(f64), .pass = false };
                if (interpolate and @abs(ya - yb) / denom > 1e-3) {
                    const dt_lo = if (i > 0) x - ng_scale[i - 1] else 0;
                    const dt_hi = if (i + 1 < ng_scale.len) ng_scale[i + 1] - x else 0;
                    while (j + 1 < zp_scale.len and zp_scale[j + 1] < x) j += 1;
                    const dt_cand = zp_scale[@min(j + 1, zp_scale.len - 1)] - zp_scale[j];
                    const w = @max(dt_lo, dt_hi, dt_cand);
                    var best = @abs(ya - yb);
                    var k: usize = 0;
                    while (k <= 8) : (k += 1) {
                        const frac = (@as(f64, @floatFromInt(k)) / 4.0) - 1.0; // -1..+1
                        const cand = interp(zp_scale, zp_var, x + frac * w);
                        if (!std.math.isNan(cand)) best = @min(best, @abs(ya - cand));
                    }
                    yb = ya - std.math.copysign(best, ya - yb);
                }
                const e = @abs(ya - yb) / denom;
                if (e > max_err) max_err = e;
                sum_sq += e * e;
                count += 1;
            }

            if (count > 0) {
                const rms = @sqrt(sum_sq / @as(f64, @floatFromInt(count)));
                if (max_err > worst_max) worst_max = max_err;
                if (rms > worst_rms) worst_rms = rms;
                any = any or !scale_names.has(ng_name);
            }
        }
    }

    if (!any) return null;
    return .{
        .complete = complete,
        .max_rel = worst_max,
        .rms_rel = worst_rms,
        .pass = complete and worst_rms <= rtol and worst_max <= 10.0 * rtol,
    };
}

const scale_names = std.StaticStringMap(void).initComptime(.{
    .{ "time", {} },       .{ "frequency", {} },  .{ "v(v-sweep)", {} },
    .{ "i(i-sweep)", {} }, .{ "temp-sweep", {} }, .{ "outersweep", {} },
});

const scale_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "sweep", "v(v-sweep)" },
    .{ "vsweep", "v(v-sweep)" },
});

const plot_classes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "operating point", "dc" },
    .{ "dc operating point", "dc" },
    .{ "dc transfer characteristic", "dc" },
    .{ "ac analysis", "ac" },
    .{ "ac small signal analysis", "ac" },
});

fn plotClass(buf: []u8, plotname: []const u8) []const u8 {
    return plot_classes.get(plotLower(buf, plotname)) orelse plotLower(buf, plotname);
}

fn plotLower(buf: []u8, plotname: []const u8) []const u8 {
    if (plotname.len > buf.len) return plotname;
    return std.ascii.lowerString(buf[0..plotname.len], plotname);
}

fn isInternalNode(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, "#:!") != null;
}

fn extractCol(data: []const f64, nvars: usize, col: usize, parts: usize, part: usize, out: []f64) void {
    for (out, 0..) |*value, p| value.* = data[(p * nvars + col) * parts + part];
}

fn colPeak(col: []const f64) f64 {
    var mx: f64 = 0;
    for (col) |v| {
        const a = @abs(v);
        if (a > mx) mx = a;
    }
    return mx;
}

fn colPtp(col: []const f64) f64 {
    if (col.len == 0) return 0;
    var lo = col[0];
    var hi = col[0];
    for (col) |v| {
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
    return hi - lo;
}

fn interp(xs: []const f64, ys: []const f64, x: f64) f64 {
    if (xs.len == 0) return 0;
    if (x <= xs[0]) return ys[0];
    if (x >= xs[xs.len - 1]) return ys[ys.len - 1];
    var lo: usize = 0;
    var hi: usize = xs.len - 1;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (xs[mid] <= x) lo = mid else hi = mid;
    }
    const dx = xs[hi] - xs[lo];
    const t = if (dx != 0) (x - xs[lo]) / dx else 0.5;
    return ys[lo] * (1.0 - t) + ys[hi] * t;
}

test "accuracy requires signals and complete real samples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reference: Plot = .{
        .plotname = "Transient Analysis",
        .varnames = &.{ "time", "v(out)" },
        .is_complex = false,
        .npoints = 2,
        .nvars = 2,
        .data = &.{ 0, 1, 1, 2 },
    };
    try std.testing.expect(comparePlots(a, reference, reference, 1e-3).?.pass);
    var with_current = reference;
    with_current.varnames = &.{ "time", "v(out)", "i(v1)" };
    with_current.nvars = 3;
    with_current.data = &.{ 0, 1, 0.1, 1, 2, 0.2 };
    const partial = comparePlots(a, with_current, reference, 1e-3).?;
    try std.testing.expect(!partial.complete and !partial.pass);
    try std.testing.expectEqual(@as(f64, 0), partial.max_rel);
    try std.testing.expect(!partial.complete and !partial.pass);
    var candidate = reference;
    candidate.varnames = &.{"time"};
    candidate.nvars = 1;
    candidate.data = &.{ 0, 1 };
    try std.testing.expect(comparePlots(a, reference, candidate, 1e-3) == null);
    try std.testing.expect(comparePlots(a, candidate, candidate, 1e-3) == null);
    candidate = reference;
    candidate.data = &.{ 0, 1, 0.5, 2 };
    try std.testing.expect(comparePlots(a, reference, candidate, 1e-3) == null);
    candidate = reference;
    candidate.data = &.{ 0, 1, 1, std.math.inf(f64) };
    try std.testing.expect(!comparePlots(a, reference, candidate, 1e-3).?.pass);
    candidate.is_complex = true;
    try std.testing.expect(comparePlots(a, reference, candidate, 1e-3) == null);
}

test "accuracy matches reordered signals and keeps the first duplicate" {
    const reference: Plot = .{
        .plotname = "Operating Point",
        .varnames = &.{ "v(out)", "i(v1)", "v(in)" },
        .is_complex = false,
        .npoints = 1,
        .nvars = 3,
        .data = &.{ 1, -0.001, 2 },
    };
    var candidate = reference;
    candidate.varnames = &.{ "v(in)", "v(out)", "i(v1)", "v(out)" };
    candidate.nvars = 4;
    candidate.data = &.{ 2, 1, -0.001, 9 };
    try std.testing.expect(comparePlots(std.testing.allocator, reference, candidate, 1e-3).?.pass);
    candidate.data = &.{ 2, 9, -0.001, 1 };
    try std.testing.expect(!comparePlots(std.testing.allocator, reference, candidate, 1e-3).?.pass);
}

test "one signal spelling across four simulators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Left column is what each simulator writes (already lowercased by the raw
    // parser); right column is the single spelling everything must collapse to.
    // Get this wrong and VACASK matches zero columns, then reports a vacuous
    // N/A that reads like "validated".
    inline for (.{
        .{ "v(out)", "v(out)" }, // ngspice / espice
        .{ "i(vin)", "i(vin)" },
        .{ "out", "v(out)" }, // a bare node name
        .{ "v(1)", "v(1)" }, // already wrapped, left alone
        .{ "vin#branch", "i(vin)" }, // ngspice branch current
        .{ "2", "v(2)" }, // VACASK node
        .{ "vs:flow(br)", "i(vs)" }, // VACASK branch current
        .{ "time", "time" }, // scales are never wrapped
        .{ "frequency", "frequency" },
    }) |case| try std.testing.expectEqualStrings(case[1], normalizeVarName(a, case[0]));

    // Internal device nodes keep their own spelling; comparePlots drops those
    // by name, and wrapping them as currents would silently invent a signal.
    try std.testing.expectEqualStrings("v(m1#drain)", normalizeVarName(a, "m1#drain"));
    inline for (.{
        "v(m1#drain)", // ngspice
        "v(d1:a_int)", // VACASK
    }) |internal| try std.testing.expect(isInternalNode(internal));
    // A deck node is not internal just because a model node could share a
    // prefix or a suffix with it.
    inline for (.{ "v(out)", "i(v1)", "v(internal)", "v(_body)", "v(i2)" }) |named|
        try std.testing.expect(!isInternalNode(named));
}

test "VACASK names a `.dc` scale after the deck, and calls the plot an operating point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // What VACASK writes for a translated `.dc`: a plot it calls an Operating
    // Point (a sweep IS a sweep of operating points there) whose scale is the
    // sweep block's own identifier. ngspice calls the same plot a DC transfer
    // characteristic and the same scale `v(v-sweep)`. Without the class map and
    // the scale alias this pair is N/A on both counts while agreeing to the
    // last bit.
    const vc: Plot = .{
        .plotname = "Operating Point",
        .varnames = &.{ normalizeVarName(a, "vsweep"), normalizeVarName(a, "in"), normalizeVarName(a, "out"), normalizeVarName(a, "vin:flow(br)") },
        .is_complex = false,
        .npoints = 1,
        .nvars = 4,
        .data = &.{ 0, 10, 5, -1e-3 },
    };
    const espice: Plot = .{
        .plotname = "DC transfer characteristic",
        .varnames = &.{ "i(vin)", "v(in)", "v(out)" },
        .is_complex = false,
        .npoints = 1,
        .nvars = 3,
        .data = &.{ -1e-3, 10, 5 },
    };
    const acc = comparePlots(a, vc, espice, 1e-3).?;
    try std.testing.expect(acc.complete and acc.pass);
    // A dropped scale cannot BE the match: same plot with only the scale in
    // common has no signal to compare and must stay unvalidated.
    var scale_only = espice;
    scale_only.varnames = &.{"v(v-sweep)"};
    scale_only.nvars = 1;
    scale_only.data = &.{0};
    try std.testing.expect(comparePlots(a, vc, scale_only, 1e-3) == null);
    // The class collapses DC spellings only. Transient vs DC is still a
    // refusal, not a comparison.
    var tran = espice;
    tran.plotname = "Transient Analysis";
    try std.testing.expect(comparePlots(a, vc, tran, 1e-3) == null);
}

test "VACASK's AC plotname is not ngspice's, and the class map knows it" {
    // ngspice writes "AC Analysis"; VACASK writes "AC Small Signal Analysis".
    // Same analysis, same columns. The translator made this reachable for the
    // first time: before it, no VACASK deck in the suite ran an `.ac` at all,
    // so the two labels had never met and every translated AC fixture would
    // have reported a coverage N/A over a spelling.
    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        plotClass(&buf_a, "AC Analysis"),
        plotClass(&buf_b, "AC Small Signal Analysis"),
    );
    // And it collapses those two only: noise is still its own class.
    try std.testing.expect(!std.mem.eql(
        u8,
        plotClass(&buf_a, "AC Analysis"),
        plotClass(&buf_b, "Small-Signal Noise Analysis"),
    ));
}

test "the raw parser reads every plot, and still refuses a truncated one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "Plotname: Operating Point\nNo. Variables: 1\nNo. Points: 1\nVariables:\n\t0\tv(out)\tvoltage\nBinary:\n" ++ "\x00" ** 8;
    try std.testing.expectEqual(@as(usize, 1), parseRawBlob(a, raw).?.len);
    // Used to be `== null`: a second plot meant the whole raw was thrown away,
    // which is branch P5 and 19 of the 64 N/A fixtures.
    try std.testing.expectEqual(@as(usize, 2), parseRawBlob(a, raw ++ raw).?.len);
    try std.testing.expect(parseRawBlob(a, raw[0 .. raw.len - 1]) == null);
    // A raw whose FIRST plot is whole and whose second is truncated is still
    // null: a partially-read raw silently drops an analysis.
    try std.testing.expect(parseRawBlob(a, raw ++ raw[0 .. raw.len - 1]) == null);
}

test "a complex plot is scored re and im separately, not as a magnitude" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (re, im) interleaved per entry: freq=1 v(out)=3+4j, freq=2 v(out)=5+6j.
    const reference: Plot = .{
        .plotname = "AC Analysis",
        .varnames = &.{ "frequency", "v(out)" },
        .is_complex = true,
        .npoints = 2,
        .nvars = 2,
        .data = &.{ 1, 0, 3, 4, 2, 0, 5, 6 },
    };
    try std.testing.expect(comparePlots(a, reference, reference, 1e-3).?.pass);
    // Same magnitude at every point, re and im swapped — a phase-convention
    // error. Collapsing to |z| first would call this a PASS, which is the one
    // thing an AC comparison exists to catch.
    var swapped = reference;
    swapped.data = &.{ 1, 0, 4, 3, 2, 0, 6, 5 };
    try std.testing.expect(!comparePlots(a, reference, swapped, 1e-3).?.pass);
}

test "multi-analysis plots are matched by name, never by index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ac: Plot = .{
        .plotname = "AC Analysis",
        .varnames = &.{ "frequency", "v(out)" },
        .is_complex = true,
        .npoints = 1,
        .nvars = 2,
        .data = &.{ 1, 0, 3, 4 },
    };
    const op: Plot = .{
        .plotname = "Operating Point",
        .varnames = &.{"v(out)"},
        .is_complex = false,
        .npoints = 1,
        .nvars = 1,
        .data = &.{7},
    };
    // ngspice writes AC first, espice writes Operating Point first, on every
    // multi-analysis deck. Index matching would score the AC sweep against the
    // operating point and report a failure.
    try std.testing.expect(compareRaws(a, &.{ ac, op }, &.{ op, ac }, 1e-3).?.pass);
    // A CANDIDATE-only plot is not evidence of anything: espice writes a
    // `Fourier Analysis` plot where ngspice prints `.four` to stdout.
    var four = op;
    four.plotname = "Fourier Analysis";
    try std.testing.expect(compareRaws(a, &.{ac}, &.{ four, ac }, 1e-3).?.pass);
    // A REFERENCE plot with no counterpart is a coverage gap -> N/A, not a pass.
    const gap = compareRaws(a, &.{ ac, op }, &.{ac}, 1e-3).?;
    try std.testing.expect(!gap.complete and !gap.pass);
    try std.testing.expect(!gap.complete and !gap.pass);
    // One bad plot out of two loses the whole fixture: worst pair wins.
    var wrong_op = op;
    wrong_op.data = &.{9};
    try std.testing.expect(!compareRaws(a, &.{ ac, op }, &.{ wrong_op, ac }, 1e-3).?.pass);
    // Nothing comparable at all is null, so the row reads N/A rather than PASS.
    try std.testing.expect(compareRaws(a, &.{ac}, &.{op}, 1e-3) == null);
}

test "an exact plotname beats an aliased one, whatever the order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `plot_classes` aliases both of these to "dc" so that a one-point DC
    // sweep can answer for an ngspice `.op`. That alias also makes them
    // interchangeable, so a deck carrying BOTH — `devices/jfet_vds_vgs` — must
    // still pair each with its namesake or the point counts collide and a
    // fixture that agrees to 3e-6 reads N/A.
    const sweep: Plot = .{
        .plotname = "DC transfer characteristic",
        .varnames = &.{ "v(v-sweep)", "v(out)" },
        .is_complex = false,
        .npoints = 2,
        .nvars = 2,
        .data = &.{ 0, 1, 1, 2 },
    };
    const op: Plot = .{
        .plotname = "Operating Point",
        .varnames = &.{"v(out)"},
        .is_complex = false,
        .npoints = 1,
        .nvars = 1,
        .data = &.{7},
    };
    try std.testing.expect(compareRaws(a, &.{ sweep, op }, &.{ op, sweep }, 1e-3).?.pass);
    try std.testing.expect(compareRaws(a, &.{ op, sweep }, &.{ sweep, op }, 1e-3).?.pass);
    // The alias still does its job when there IS no namesake: VACASK spells a
    // DC sweep "Operating Point" and must still match ngspice's own label.
    var vc_dc = op;
    vc_dc.plotname = "DC transfer characteristic";
    try std.testing.expect(compareRaws(a, &.{op}, &.{vc_dc}, 1e-3).?.pass);
}
