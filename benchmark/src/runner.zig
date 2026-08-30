//! Benchmark runner — wall-clock timing AND accuracy of espice vs ngspice.
//!
//! Usage (via `zig build bench -- <flags>`):
//!   bench-runner ESPICE_BIN FIXTURES_DIR [--iters N] [--filter CAT[/NAME]]
//!               [--no-ngspice] [--list] [--out RESULTS.md] [--rtol 0.01]
//!
//! Every fixture is benchmark/fixtures/<cat>/<name>/circuit.sp.
//! No metadata files — if circuit.sp exists, it runs.
//!
//! For each fixture:
//!   1. Preflight both simulators (untimed)
//!   2. N timed iterations -> median wall-clock
//!   3. Parse both ngspice-format raw files
//!   4. Compare node voltages: max/RMS relative error
//!   5. Combined timing + accuracy table on stdout + RESULTS.md

const std = @import("std");
const Io = std.Io;

const Config = struct {
    engine_bin: []const u8,
    fixtures_dir: []const u8,
    iters: u32 = 10,
    filters: std.ArrayList([]const u8) = .empty,
    use_ngspice: bool = true,
    use_xyce: bool = true,
    list_only: bool = false,
    out_path: []const u8 = "benchmark/RESULTS.md",
    rtol: f64 = 1e-3,
    timeout: []const u8 = "300",
};

const Fixture = struct {
    category: []const u8,
    name: []const u8,
};

const Accuracy = struct {
    max_rel: f64,
    rms_rel: f64,
    pass: bool,
};

const Result = struct {
    category: []const u8,
    name: []const u8,
    zp_cpu_median_ns: ?u64 = null,
    zp_cpu_skip: []const u8 = "",
    zp_cpu_rss_kb: u64 = 0,
    zp_gpu_median_ns: ?u64 = null,
    zp_gpu_skip: []const u8 = "",
    ng_median_ns: ?u64 = null,
    ng_skip: []const u8 = "",
    ng_rss_kb: u64 = 0,
    xyce_median_ns: ?u64 = null,
    xyce_skip: []const u8 = "",
    xyce_rss_kb: u64 = 0,
    cpu_accuracy: ?Accuracy = null,
    gpu_accuracy: ?Accuracy = null,
};

// ============================================================================
// Entry
// ============================================================================

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var cfg = parseArgs(gpa, init) catch |err| switch (err) {
        error.BadUsage => std.process.exit(2),
        else => return err,
    };

    var out_buf: [8192]u8 = undefined;
    var ow: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &ow.interface;

    const out_dir = "zig-out/bench-out";
    Io.Dir.cwd().createDirPath(io, out_dir) catch {};

    const fixtures = try discoverFixtures(io, gpa, cfg.fixtures_dir);
    if (fixtures.len == 0) {
        std.debug.print("error: no fixtures under '{s}'\n", .{cfg.fixtures_dir});
        std.process.exit(1);
    }

    if (cfg.list_only) {
        for (fixtures) |fx| {
            try out.print("{s}/{s}\n", .{ fx.category, fx.name });
        }
        try out.print("\n{d} fixtures.\n", .{fixtures.len});
        try out.flush();
        return;
    }

    const engine_ok = blk: {
        Io.Dir.cwd().access(io, cfg.engine_bin, .{}) catch break :blk false;
        break :blk true;
    };
    if (!engine_ok)
        try out.print("note: engine '{s}' not found — engine column disabled\n\n", .{cfg.engine_bin});

    const ngspice_ok = cfg.use_ngspice and probeNgspice(io);
    if (cfg.use_ngspice and !ngspice_ok)
        try out.writeAll("note: ngspice not found — comparison disabled\n\n");

    const xyce_ok = cfg.use_xyce and probeXyce(io);
    if (cfg.use_xyce and !xyce_ok)
        try out.writeAll("note: xyce not found — comparison disabled\n\n");

    try reportHeader(out);
    try out.flush();

    var prev_cat: []const u8 = "";
    var results: std.ArrayList(Result) = .empty;
    for (fixtures) |fx| {
        if (!matchesFilter(&cfg, fx.category, fx.name)) continue;

        // per-fixture arena: raw-file parses are 100s of MB across the suite;
        // retaining them in the run arena OOMs the host on long runs
        var fx_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer fx_arena.deinit();
        const fxa = fx_arena.allocator();

        var res: Result = .{ .category = fx.category, .name = fx.name };
        const netlist = try std.fmt.allocPrint(fxa, "{s}/{s}/{s}/circuit.sp", .{ cfg.fixtures_dir, fx.category, fx.name });

        // espice CPU
        var zp_cpu_raw_path: []const u8 = "";
        if (engine_ok) {
            zp_cpu_raw_path = try std.fmt.allocPrint(fxa, "{s}/{s}--{s}.zp-cpu.raw", .{ out_dir, fx.category, fx.name });
            const zp_cpu_argv: []const []const u8 = &.{ cfg.engine_bin, "-b", "-r", zp_cpu_raw_path, netlist };
            const cap = runCapture(io, fxa, zp_cpu_argv);
            if (cap.ok and !std.mem.startsWith(u8, cap.text, "{\"skip\"")) {
                res.zp_cpu_median_ns = try timedMedian(io, fxa, zp_cpu_argv, cfg.timeout, 1);
            } else if (skipReason(cap.text)) |reason| {
                res.zp_cpu_skip = reason;
            } else {
                res.zp_cpu_skip = "preflight failed";
            }
        } else {
            res.zp_cpu_skip = "engine not found";
        }

        // espice GPU
        var zp_gpu_raw_path: []const u8 = "";
        if (engine_ok) {
            zp_gpu_raw_path = try std.fmt.allocPrint(fxa, "{s}/{s}--{s}.zp-gpu.raw", .{ out_dir, fx.category, fx.name });
            const zp_gpu_argv: []const []const u8 = &.{ cfg.engine_bin, "-b", "--gpu", "-r", zp_gpu_raw_path, netlist };
            const cap = runCapture(io, fxa, zp_gpu_argv);
            if (cap.ok and !std.mem.startsWith(u8, cap.text, "{\"skip\"")) {
                res.zp_gpu_median_ns = try timedMedian(io, fxa, zp_gpu_argv, cfg.timeout, 1);
            } else if (skipReason(cap.text)) |reason| {
                res.zp_gpu_skip = reason;
            } else {
                res.zp_gpu_skip = "preflight failed";
            }
        } else {
            res.zp_gpu_skip = "engine not found";
        }

        // ngspice
        var ng_raw_path: []const u8 = "";
        if (ngspice_ok) {
            ng_raw_path = try std.fmt.allocPrint(fxa, "{s}/{s}--{s}.ng.raw", .{ out_dir, fx.category, fx.name });
            const ng_argv: []const []const u8 = &.{ "ngspice", "-b", "-r", ng_raw_path, netlist };
            if (runOk(io, ng_argv)) {
                res.ng_median_ns = try timedMedian(io, fxa, ng_argv, cfg.timeout, 1);
            } else {
                res.ng_skip = "preflight failed";
            }
        }

        // xyce
        if (xyce_ok) {
            const xyce_argv: []const []const u8 = &.{ "xyce", "-b", netlist };
            if (runOk(io, xyce_argv)) {
                res.xyce_median_ns = try timedMedian(io, fxa, xyce_argv, cfg.timeout, 1);
            } else {
                res.xyce_skip = "preflight failed";
            }
        }

        // peak RSS (one extra run each, only for fixtures that succeeded)
        if (res.zp_cpu_median_ns != null) {
            const zp_cpu_argv: []const []const u8 = &.{ cfg.engine_bin, "-b", "-r", zp_cpu_raw_path, netlist };
            res.zp_cpu_rss_kb = measurePeakRss(io, fxa, zp_cpu_argv, cfg.timeout);
        }
        if (res.ng_median_ns != null) {
            const ng_argv: []const []const u8 = &.{ "ngspice", "-b", "-r", ng_raw_path, netlist };
            res.ng_rss_kb = measurePeakRss(io, fxa, ng_argv, cfg.timeout);
        }
        if (res.xyce_median_ns != null) {
            const xyce_argv: []const []const u8 = &.{ "xyce", "-b", netlist };
            res.xyce_rss_kb = measurePeakRss(io, fxa, xyce_argv, cfg.timeout);
        }

        if (res.zp_cpu_median_ns != null and res.ng_median_ns != null) {
            res.cpu_accuracy = compareRawFiles(io, fxa, ng_raw_path, zp_cpu_raw_path, cfg.rtol);
        }
        if (res.zp_gpu_median_ns != null and res.ng_median_ns != null) {
            res.gpu_accuracy = compareRawFiles(io, fxa, ng_raw_path, zp_gpu_raw_path, cfg.rtol);
        }

        // skip strings may slice fixture-arena memory; dupe survivors
        if (res.zp_cpu_skip.len > 0) res.zp_cpu_skip = try gpa.dupe(u8, res.zp_cpu_skip);
        if (res.zp_gpu_skip.len > 0) res.zp_gpu_skip = try gpa.dupe(u8, res.zp_gpu_skip);

        try reportRow(out, res, &prev_cat);
        try out.flush();
        try results.append(gpa, res);
    }

    try reportFooter(out);
    try out.flush();

    writeResultsMd(io, gpa, cfg.out_path, results.items, cfg.rtol);
}

// ============================================================================
// Raw file parsing (ngspice binary format)
// ============================================================================

const Plot = struct {
    plotname: []const u8,
    varnames: []const []const u8,
    is_complex: bool,
    npoints: usize,
    nvars: usize,
    data: []const f64,
};

fn parseRawFile(io: Io, gpa: std.mem.Allocator, path: []const u8) ?Plot {
    const blob = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return null;
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
                varnames.append(gpa, name) catch return null;
            }
        } else if (in_vars and line.len > 0 and raw_line.len > 0 and raw_line[0] != '\t' and !std.ascii.isDigit(raw_line[0])) {
            in_vars = false;
        }
    }

    if (binary_offset == null or nvars == 0 or npoints == 0) return null;
    const boff = binary_offset.?;

    const per: usize = if (is_complex) 2 else 1;
    const count = nvars * npoints * per;
    const need = count * 8;
    if (boff + need > blob.len) return null;

    const data = gpa.alloc(f64, count) catch return null;
    @memcpy(std.mem.sliceAsBytes(data), blob[boff .. boff + need]);

    return .{
        .plotname = plotname,
        .varnames = varnames.items,
        .is_complex = is_complex,
        .npoints = npoints,
        .nvars = nvars,
        .data = data,
    };
}

// ============================================================================
// Accuracy comparison
// ============================================================================

fn compareRawFiles(io: Io, gpa: std.mem.Allocator, ng_path: []const u8, zp_path: []const u8, rtol: f64) ?Accuracy {
    const ng = parseRawFile(io, gpa, ng_path) orelse return null;
    const zp = parseRawFile(io, gpa, zp_path) orelse return null;
    if (ng.is_complex or zp.is_complex) return null;

    const interpolate = std.mem.indexOf(u8, std.ascii.allocLowerString(gpa, ng.plotname) catch return null, "transient") != null;

    var worst_max: f64 = 0;
    var worst_rms: f64 = 0;
    var any = false;

    for (ng.varnames, 0..) |ng_name, ni| {
        if (!std.mem.startsWith(u8, ng_name, "v(")) continue;
        const zi = findVar(zp.varnames, ng_name) orelse continue;

        const ng_scale = extractCol(gpa, ng.data, ng.nvars, ng.npoints, 0) orelse continue;
        const zp_scale = extractCol(gpa, zp.data, zp.nvars, zp.npoints, 0) orelse continue;
        const ng_var = extractCol(gpa, ng.data, ng.nvars, ng.npoints, ni) orelse continue;
        const zp_var = extractCol(gpa, zp.data, zp.nvars, zp.npoints, zi) orelse continue;

        const peak = colPeak(ng_var);
        const ptp = colPtp(ng_var);
        const denom = @max(peak, ptp, 1.0);

        var sum_sq: f64 = 0;
        var max_err: f64 = 0;
        var count: usize = 0;

        for (ng_scale, ng_var) |x, ya| {
            const yb = if (interpolate) interp(zp_scale, zp_var, x) else blk: {
                if (count < zp_var.len) break :blk zp_var[count] else return null;
            };
            if (std.math.isNan(yb) or std.math.isNan(ya)) {
                max_err = std.math.inf(f64);
                sum_sq = std.math.inf(f64);
                count += 1;
                continue;
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
            any = true;
        }
    }

    if (!any) return null;
    return .{
        .max_rel = worst_max,
        .rms_rel = worst_rms,
        .pass = worst_rms <= rtol and worst_max <= 10.0 * rtol,
    };
}

fn extractCol(gpa: std.mem.Allocator, data: []const f64, nvars: usize, npoints: usize, col: usize) ?[]const f64 {
    const buf = gpa.alloc(f64, npoints) catch return null;
    for (0..npoints) |p| buf[p] = data[p * nvars + col];
    return buf;
}

fn findVar(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, target)) return i;
    }
    return null;
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

// ============================================================================
// Fixture discovery
// ============================================================================

fn discoverFixtures(io: Io, gpa: std.mem.Allocator, fixtures_dir: []const u8) ![]Fixture {
    var fixtures: std.ArrayList(Fixture) = .empty;

    var root = Io.Dir.cwd().openDir(io, fixtures_dir, .{ .iterate = true }) catch {
        std.debug.print("error: cannot open '{s}'\n", .{fixtures_dir});
        std.process.exit(1);
    };
    defer root.close(io);

    var cit = root.iterate();
    while (cit.next(io) catch null) |ce| {
        if (ce.kind != .directory) continue;
        const category = try gpa.dupe(u8, ce.name);

        var cat_dir = root.openDir(io, category, .{ .iterate = true }) catch continue;
        defer cat_dir.close(io);
        var fit = cat_dir.iterate();
        while (fit.next(io) catch null) |fe| {
            if (fe.kind != .directory) continue;
            const sp_path = try std.fmt.allocPrint(gpa, "{s}/circuit.sp", .{fe.name});
            cat_dir.access(io, sp_path, .{}) catch continue;
            try fixtures.append(gpa, .{
                .category = category,
                .name = try gpa.dupe(u8, fe.name),
            });
        }
    }

    std.mem.sort(Fixture, fixtures.items, {}, lessThanFixture);
    return fixtures.items;
}

fn lessThanFixture(_: void, a: Fixture, b: Fixture) bool {
    const c = std.mem.order(u8, a.category, b.category);
    if (c != .eq) return c == .lt;
    return std.mem.lessThan(u8, a.name, b.name);
}

// ============================================================================
// Child process
// ============================================================================

fn spawnQuiet(io: Io, argv: []const []const u8, timeout: []const u8, stdout: std.process.SpawnOptions.StdIo) !std.process.Child {
    var buf: [64][]const u8 = undefined;
    buf[0] = "timeout";
    buf[1] = timeout;
    @memcpy(buf[2..][0..argv.len], argv);
    return std.process.spawn(io, .{
        .argv = buf[0 .. argv.len + 2],
        .stdin = .ignore,
        .stdout = stdout,
        .stderr = .ignore,
    });
}

fn waitOk(child: *std.process.Child, io: Io) bool {
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

const Capture = struct { ok: bool, text: []const u8 };

fn runCapture(io: Io, gpa: std.mem.Allocator, argv: []const []const u8) Capture {
    var child = spawnQuiet(io, argv, "30", .pipe) catch return .{ .ok = false, .text = "" };
    var rbuf: [4096]u8 = undefined;
    var fr = child.stdout.?.reader(io, &rbuf);
    const text = fr.interface.allocRemaining(gpa, .limited(1 << 20)) catch {
        _ = child.wait(io) catch {};
        return .{ .ok = false, .text = "" };
    };
    const ok = waitOk(&child, io);
    return .{ .ok = ok, .text = std.mem.trim(u8, text, " \t\r\n") };
}

fn skipReason(text: []const u8) ?[]const u8 {
    const prefix = "{\"skip\":\"";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const rest = text[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

fn runOk(io: Io, argv: []const []const u8) bool {
    var child = spawnQuiet(io, argv, "30", .ignore) catch return false;
    return waitOk(&child, io);
}

fn probeNgspice(io: Io) bool {
    return runOk(io, &.{ "ngspice", "--version" });
}

fn probeXyce(io: Io) bool {
    return runOk(io, &.{ "xyce", "--version" });
}

fn timedMedian(io: Io, gpa: std.mem.Allocator, argv: []const []const u8, timeout: []const u8, iters: u32) !u64 {
    const samples = try gpa.alloc(u64, iters);
    for (samples) |*s| {
        const t0 = Io.Timestamp.now(io, .awake);
        var child = try spawnQuiet(io, argv, timeout, .ignore);
        const ok = waitOk(&child, io);
        const t1 = Io.Timestamp.now(io, .awake);
        if (!ok) return error.BenchRunFailed;
        s.* = @intCast(t0.durationTo(t1).nanoseconds);
    }
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

// Peak RSS in KB from /proc/[pid]/status — returns 0 if unavailable
fn measurePeakRss(io: Io, gpa: std.mem.Allocator, argv: []const []const u8, timeout: []const u8) u64 {
    // Use /usr/bin/time -v to capture peak RSS
    var buf: [70][]const u8 = undefined;
    buf[0] = "/usr/bin/time";
    buf[1] = "-v";
    buf[2] = "timeout";
    buf[3] = timeout;
    @memcpy(buf[4..][0..argv.len], argv);
    var child = std.process.spawn(io, .{
        .argv = buf[0 .. argv.len + 4],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch return 0;
    var rbuf: [8192]u8 = undefined;
    var fr = child.stderr.?.reader(io, &rbuf);
    const text = fr.interface.allocRemaining(gpa, .limited(1 << 16)) catch {
        _ = child.wait(io) catch {};
        return 0;
    };
    _ = child.wait(io) catch {};
    // Parse "Maximum resident set size (kbytes): NNN"
    const needle = "Maximum resident set size";
    if (std.mem.indexOf(u8, text, needle)) |pos| {
        const rest = text[pos..];
        if (std.mem.indexOf(u8, rest, ": ")) |colon| {
            const num_start = rest[colon + 2 ..];
            const end = std.mem.indexOfScalar(u8, num_start, '\n') orelse num_start.len;
            return std.fmt.parseInt(u64, std.mem.trim(u8, num_start[0..end], " \t\r"), 10) catch 0;
        }
    }
    return 0;
}

// ============================================================================
// Reporting
// ============================================================================

fn reportHeader(out: *Io.Writer) !void {
    try out.print("{s:<34} {s:>12} {s:>12} {s:>12} {s:>12} {s:>7} {s:>7}  {s:>8} {s:>8} {s:>8}  {s:>10} {s:>10} {s:>5}  {s:>10} {s:>10} {s:>5}\n", .{
        "fixture", "zp-cpu", "zp-gpu", "ngspice", "xyce", "cpu/ng", "gpu/ng", "zp-MB", "ng-MB", "xy-MB", "cpu-max", "cpu-rms", "cpu", "gpu-max", "gpu-rms", "gpu",
    });
    try out.print("{s:-<34} {s:->12} {s:->12} {s:->12} {s:->12} {s:->7} {s:->7}  {s:->8} {s:->8} {s:->8}  {s:->10} {s:->10} {s:->5}  {s:->10} {s:->10} {s:->5}\n", .{
        "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    });
}

fn reportRow(out: *Io.Writer, r: Result, prev_cat: *[]const u8) !void {
    if (!std.mem.eql(u8, prev_cat.*, r.category)) {
        if (prev_cat.*.len > 0) try out.writeAll("\n");
        prev_cat.* = r.category;
    }
    var namebuf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&namebuf, "{s}/{s}", .{ r.category, r.name }) catch r.name;

    try out.print("{s:<34} ", .{label});

    if (r.zp_cpu_median_ns) |ns| {
        try printDur(out, ns);
    } else {
        try out.print("{s:>12}", .{"skip"});
    }
    try out.writeAll(" ");

    if (r.zp_gpu_median_ns) |ns| {
        try printDur(out, ns);
    } else {
        try out.print("{s:>12}", .{"skip"});
    }
    try out.writeAll(" ");

    if (r.ng_median_ns) |ns| {
        try printDur(out, ns);
    } else {
        try out.print("{s:>12}", .{if (r.ng_skip.len > 0) "skip" else "-"});
    }
    try out.writeAll(" ");

    if (r.xyce_median_ns) |ns| {
        try printDur(out, ns);
    } else {
        try out.print("{s:>12}", .{if (r.xyce_skip.len > 0) "skip" else "-"});
    }
    try out.writeAll(" ");

    if (r.zp_cpu_median_ns != null and r.ng_median_ns != null) {
        const ratio = @as(f64, @floatFromInt(r.ng_median_ns.?)) / @as(f64, @floatFromInt(r.zp_cpu_median_ns.?));
        try out.print("{d:>6.1}x", .{ratio});
    } else {
        try out.print("{s:>7}", .{"-"});
    }
    try out.writeAll(" ");

    if (r.zp_gpu_median_ns != null and r.ng_median_ns != null) {
        const ratio = @as(f64, @floatFromInt(r.ng_median_ns.?)) / @as(f64, @floatFromInt(r.zp_gpu_median_ns.?));
        try out.print("{d:>6.1}x", .{ratio});
    } else {
        try out.print("{s:>7}", .{"-"});
    }
    try out.writeAll("  ");

    // memory columns
    if (r.zp_cpu_rss_kb > 0) {
        try out.print("{d:>7.1}", .{@as(f64, @floatFromInt(r.zp_cpu_rss_kb)) / 1024.0});
    } else {
        try out.print("{s:>8}", .{"-"});
    }
    try out.writeAll(" ");
    if (r.ng_rss_kb > 0) {
        try out.print("{d:>7.1}", .{@as(f64, @floatFromInt(r.ng_rss_kb)) / 1024.0});
    } else {
        try out.print("{s:>8}", .{"-"});
    }
    try out.writeAll(" ");
    if (r.xyce_rss_kb > 0) {
        try out.print("{d:>7.1}", .{@as(f64, @floatFromInt(r.xyce_rss_kb)) / 1024.0});
    } else {
        try out.print("{s:>8}", .{"-"});
    }
    try out.writeAll("  ");

    if (r.cpu_accuracy) |acc| {
        try out.print("{e:>10.2} {e:>10.2} {s:>5}", .{
            acc.max_rel, acc.rms_rel, @as([]const u8, if (acc.pass) "PASS" else "FAIL"),
        });
    } else {
        try out.print("{s:>10} {s:>10} {s:>5}", .{ "-", "-", "-" });
    }
    try out.writeAll("  ");

    if (r.gpu_accuracy) |acc| {
        try out.print("{e:>10.2} {e:>10.2} {s:>5}", .{
            acc.max_rel, acc.rms_rel, @as([]const u8, if (acc.pass) "PASS" else "FAIL"),
        });
    } else {
        try out.print("{s:>10} {s:>10} {s:>5}", .{ "-", "-", "-" });
    }
    try out.writeAll("\n");

    if (r.zp_cpu_skip.len > 0)
        try out.print("    zp-cpu: {s}\n", .{r.zp_cpu_skip});
    if (r.zp_gpu_skip.len > 0)
        try out.print("    zp-gpu: {s}\n", .{r.zp_gpu_skip});
}

fn reportFooter(out: *Io.Writer) !void {
    try out.writeAll(
        \\
        \\ratio = ngspice / espice (higher = espice faster).
        \\accuracy: per-variable RMS/max relative error against ngspice.
        \\
    );
}

fn printDur(out: *Io.Writer, ns: u64) !void {
    const f = @as(f64, @floatFromInt(ns));
    if (ns < 1_000_000) {
        try out.print("{d:>9.1} us", .{f / 1e3});
    } else if (ns < 1_000_000_000) {
        try out.print("{d:>9.2} ms", .{f / 1e6});
    } else {
        try out.print("{d:>9.3} s ", .{f / 1e9});
    }
}

fn writeResultsMd(io: Io, gpa: std.mem.Allocator, path: []const u8, results: []const Result, rtol: f64) void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;

    w.print("# Benchmark results — espice vs ngspice vs xyce\n\n", .{}) catch return;
    w.print("Pass: per-variable RMS ≤ {e:.0}, max ≤ {e:.0}\n\n", .{ rtol, 10 * rtol }) catch return;
    w.print("| fixture | zp-cpu | zp-gpu | ngspice | xyce | cpu/ng | gpu/ng | zp-MB | ng-MB | xy-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu |\n", .{}) catch return;
    w.print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n", .{}) catch return;

    for (results) |r| {
        var namebuf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&namebuf, "{s}/{s}", .{ r.category, r.name }) catch r.name;

        var zp_cpu_buf: [32]u8 = undefined;
        const zp_cpu_str = if (r.zp_cpu_median_ns) |ns| fmtDur(&zp_cpu_buf, ns) else "skip";

        var zp_gpu_buf: [32]u8 = undefined;
        const zp_gpu_str = if (r.zp_gpu_median_ns) |ns| fmtDur(&zp_gpu_buf, ns) else "skip";

        var ng_buf: [32]u8 = undefined;
        const ng_str = if (r.ng_median_ns) |ns| fmtDur(&ng_buf, ns) else "skip";

        var xyce_buf: [32]u8 = undefined;
        const xyce_str = if (r.xyce_median_ns) |ns| fmtDur(&xyce_buf, ns) else "skip";

        var cpu_ratio_buf: [16]u8 = undefined;
        const cpu_ratio_str = if (r.zp_cpu_median_ns != null and r.ng_median_ns != null)
            std.fmt.bufPrint(&cpu_ratio_buf, "{d:.1}x", .{@as(f64, @floatFromInt(r.ng_median_ns.?)) / @as(f64, @floatFromInt(r.zp_cpu_median_ns.?))}) catch "-"
        else
            "-";

        var gpu_ratio_buf: [16]u8 = undefined;
        const gpu_ratio_str = if (r.zp_gpu_median_ns != null and r.ng_median_ns != null)
            std.fmt.bufPrint(&gpu_ratio_buf, "{d:.1}x", .{@as(f64, @floatFromInt(r.ng_median_ns.?)) / @as(f64, @floatFromInt(r.zp_gpu_median_ns.?))}) catch "-"
        else
            "-";

        var zp_mb_buf: [16]u8 = undefined;
        const zp_mb_str = if (r.zp_cpu_rss_kb > 0)
            std.fmt.bufPrint(&zp_mb_buf, "{d:.1}", .{@as(f64, @floatFromInt(r.zp_cpu_rss_kb)) / 1024.0}) catch "-"
        else
            "-";
        var ng_mb_buf: [16]u8 = undefined;
        const ng_mb_str = if (r.ng_rss_kb > 0)
            std.fmt.bufPrint(&ng_mb_buf, "{d:.1}", .{@as(f64, @floatFromInt(r.ng_rss_kb)) / 1024.0}) catch "-"
        else
            "-";
        var xy_mb_buf: [16]u8 = undefined;
        const xy_mb_str = if (r.xyce_rss_kb > 0)
            std.fmt.bufPrint(&xy_mb_buf, "{d:.1}", .{@as(f64, @floatFromInt(r.xyce_rss_kb)) / 1024.0}) catch "-"
        else
            "-";

        var cpu_mx_buf: [16]u8 = undefined;
        var cpu_rms_buf: [16]u8 = undefined;
        const cpu_mx_str = if (r.cpu_accuracy) |a| std.fmt.bufPrint(&cpu_mx_buf, "{e:.2}", .{a.max_rel}) catch "-" else "-";
        const cpu_rms_str = if (r.cpu_accuracy) |a| std.fmt.bufPrint(&cpu_rms_buf, "{e:.2}", .{a.rms_rel}) catch "-" else "-";
        const cpu_status: []const u8 = if (r.cpu_accuracy) |a| (if (a.pass) "PASS" else "FAIL") else if (r.zp_cpu_skip.len > 0) "SKIP" else "-";

        var gpu_mx_buf: [16]u8 = undefined;
        var gpu_rms_buf: [16]u8 = undefined;
        const gpu_mx_str = if (r.gpu_accuracy) |a| std.fmt.bufPrint(&gpu_mx_buf, "{e:.2}", .{a.max_rel}) catch "-" else "-";
        const gpu_rms_str = if (r.gpu_accuracy) |a| std.fmt.bufPrint(&gpu_rms_buf, "{e:.2}", .{a.rms_rel}) catch "-" else "-";
        const gpu_status: []const u8 = if (r.gpu_accuracy) |a| (if (a.pass) "PASS" else "FAIL") else if (r.zp_gpu_skip.len > 0) "SKIP" else "-";

        w.print("| {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} |\n", .{
            label, zp_cpu_str, zp_gpu_str, ng_str, xyce_str, cpu_ratio_str, gpu_ratio_str,
            zp_mb_str, ng_mb_str, xy_mb_str, cpu_mx_str, cpu_rms_str, cpu_status,
            gpu_mx_str, gpu_rms_str, gpu_status,
        }) catch return;
    }

    const text = aw.toOwnedSlice() catch return;
    const file = Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer file.close(io);
    var fbuf: [4096]u8 = undefined;
    var fw = file.writer(io, &fbuf);
    fw.interface.writeAll(text) catch {};
    fw.interface.flush() catch {};
}

fn fmtDur(buf: []u8, ns: u64) []const u8 {
    const f = @as(f64, @floatFromInt(ns));
    if (ns < 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1}us", .{f / 1e3}) catch "-";
    } else if (ns < 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d:.2}ms", .{f / 1e6}) catch "-";
    } else {
        return std.fmt.bufPrint(buf, "{d:.3}s", .{f / 1e9}) catch "-";
    }
}

// ============================================================================
// Args
// ============================================================================

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init) !Config {
    const usage = "usage: bench-runner ESPICE_BIN FIXTURES_DIR [--iters N] [--filter CAT[/NAME]] [--no-ngspice] [--no-xyce] [--timeout S] [--list] [--out PATH] [--rtol N]\n";
    var it = init.minimal.args.iterate();
    _ = it.skip();
    const engine_bin = it.next() orelse {
        std.debug.print(usage, .{});
        return error.BadUsage;
    };
    const fixtures_dir = it.next() orelse {
        std.debug.print(usage, .{});
        return error.BadUsage;
    };
    var cfg: Config = .{ .engine_bin = engine_bin, .fixtures_dir = fixtures_dir };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--iters")) {
            const v = it.next() orelse return error.BadUsage;
            cfg.iters = std.fmt.parseInt(u32, v, 10) catch return error.BadUsage;
            if (cfg.iters == 0) return error.BadUsage;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            try cfg.filters.append(gpa, it.next() orelse return error.BadUsage);
        } else if (std.mem.eql(u8, arg, "--no-ngspice")) {
            cfg.use_ngspice = false;
        } else if (std.mem.eql(u8, arg, "--no-xyce")) {
            cfg.use_xyce = false;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            cfg.timeout = it.next() orelse return error.BadUsage;
        } else if (std.mem.eql(u8, arg, "--list")) {
            cfg.list_only = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            cfg.out_path = it.next() orelse return error.BadUsage;
        } else if (std.mem.eql(u8, arg, "--rtol")) {
            const v = it.next() orelse return error.BadUsage;
            cfg.rtol = std.fmt.parseFloat(f64, v) catch return error.BadUsage;
        } else {
            std.debug.print("error: unknown flag '{s}'\n", .{arg});
            return error.BadUsage;
        }
    }
    return cfg;
}

fn matchesFilter(cfg: *const Config, category: []const u8, name: []const u8) bool {
    if (cfg.filters.items.len == 0) return true;
    var full_buf: [128]u8 = undefined;
    const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ category, name }) catch return true;
    for (cfg.filters.items) |f| {
        if (std.mem.eql(u8, f, category) or std.mem.eql(u8, f, full)) return true;
    }
    return false;
}
