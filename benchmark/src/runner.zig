//! Benchmark runner — wall-clock timing AND accuracy of espice vs three
//! reference simulators: ngspice, Xyce and VACASK.
//!
//! Usage (via `zig build bench -- <flags>`):
//!   bench-runner ESPICE_BIN FIXTURES_DIR [--iters N] [--filter CAT[/NAME]]
//!               [--ngspice PATH] [--xyce PATH] [--vacask PATH] [--ngspice-klu]
//!               [--no-ngspice] [--no-xyce] [--no-vacask]
//!               [--list] [--out RESULTS.md] [--rtol 0.01]
//!
//! Every fixture is benchmark/fixtures/<cat>/<name>/circuit.sp.
//! No metadata files — if circuit.sp exists, it runs.
//!
//! For each fixture:
//!   1. Preflight every simulator (untimed)
//!   2. N timed iterations -> median wall-clock
//!   3. Parse each spice3 raw file
//!   4. Compare voltages and currents: max/RMS normalized error
//!   5. Combined timing + accuracy table on stdout + RESULTS.md

const std = @import("std");
const Io = std.Io;

// Reference binaries are PINNED to nix store paths. Two ngspice 44.2 builds on
// this machine differ by 8.5% in instruction count on
// scaling/parallel_inverters_100 (557M via ~/.nix-profile vs 513M from source),
// so a runner that resolves `ngspice` through $PATH silently reports a
// different speedup depending on what the shell happened to hand it. Pin the
// exact store path, fall back to $PATH with a loud note, and PRINT the binary
// and version each column used — a benchmark that cannot name its reference is
// not reproducible. Override any of them with --ngspice/--xyce/--vacask.
//
// These three paths are kept alive by GC roots in ~/.local/state/espice-refs;
// without one, `nix build --no-link` output is collected out from under the
// benchmark and a whole column silently turns into "DISABLED". Rebuild with:
//   nix build --out-link ~/.local/state/espice-refs/xyce nixpkgs#xyce
//   nix build --impure --out-link ~/.local/state/espice-refs/vacask \
//     --expr 'import ./nix/vacask.nix { ... }'
// ngspice stays on 44.2 on purpose: nixpkgs has moved to 45, and every number
// recorded in RESULTS.md so far was measured against 44.2.
const default_bin = std.enums.EnumArray(RefId, []const u8).init(.{
    .ngspice = "/nix/store/bywwgg84ccx0544z9qrfm4zc4ls30ghd-ngspice-44.2/bin/ngspice",
    .xyce = "/nix/store/7glhfffprbvfz11bi9pd1fr5np8nw5df-xyce-7.10.0/bin/Xyce",
    .vacask = "/nix/store/g5ial84gcp2da9h7y63r4c6dc1iqip57-vacask-unstable-2026/bin/vacask",
});

// PATH fallback names, used only when the pinned store path is absent.
const path_bin = std.enums.EnumArray(RefId, []const u8).init(.{
    .ngspice = "ngspice",
    .xyce = "Xyce",
    .vacask = "vacask",
});

const RefId = enum { ngspice, xyce, vacask };

/// A reference simulator, resolved and version-stamped at startup.
const Ref = struct {
    bin: []const u8,
    /// Column label; ngspice's changes to "ngspice+klu" under --ngspice-klu.
    label: []const u8,
    /// First line of the binary's own version banner. Empty means DISABLED —
    /// either --no-<ref> or the probe failed.
    version: []const u8 = "",

    fn on(self: Ref) bool {
        return self.version.len > 0;
    }
};

/// One timed batch, reduced two ways from the same samples.
///
/// `min_ns` is the headline. A simulator run is a deterministic amount of work
/// plus whatever the scheduler, the page cache and the other 31 cores did to
/// it; that contamination is one-sided, so the minimum is the sample that saw
/// the least of it and the median is not "typical", it is "typical for the load
/// that happened to be on the box". A `--iters 3` median on a busy machine
/// produced seven decks reported as espice regressions that three independent
/// methods later overturned (docs/perf/slow-decks-2026-09-10.md). `p50_ns` is
/// kept beside it so the difference between the two methods is a number in the
/// table rather than an argument.
const Timing = struct {
    min_ns: u64,
    p50_ns: u64,

    /// How far the median sits above the minimum: this batch's own contention
    /// noise, in its own units. Used as the resolution limit below which a
    /// floor-corrected time cannot be ranked.
    fn jitter(self: Timing) u64 {
        return self.p50_ns - self.min_ns;
    }
};

/// One reference's outcome on one fixture.
const RefRun = struct {
    time: ?Timing = null,
    skip: []const u8 = "",
    rss_kb: u64 = 0,
    /// Raw file to compare against; empty when the run produced none.
    raw: []const u8 = "",
};

/// argv plus the working directory it must run in. VACASK writes its result
/// file into the CWD under the analysis's own name and offers no output-path
/// flag, so every VACASK run needs a private scratch directory or fixtures
/// would overwrite each other's raws in the repo root.
const Job = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    /// Raw file this run will write. Empty when the simulator names the file
    /// itself (VACASK uses the analysis name), in which case the CWD is scanned
    /// afterwards instead.
    raw: []const u8 = "",
};

const Config = struct {
    engine_bin: []const u8,
    fixtures_dir: []const u8,
    iters: u32 = 10,
    filters: std.ArrayList([]const u8) = .empty,
    bins: std.enums.EnumArray(RefId, ?[]const u8) = .initFill(null),
    use: std.enums.EnumArray(RefId, bool) = .initFill(true),
    /// ngspice selects KLU with a `.options klu` CARD, not a CLI flag, so this
    /// makes the runner emit a rewritten deck per fixture. Measured on this
    /// suite KLU is slower on every deck (pi100 513M -> 555M Ir, mos6_inverter
    /// 149M -> 163M, rc_ladder_10k 2.60G -> 3.98G): KLU's ordering and BTF
    /// analysis are built for 1e5+ unknowns and are pure overhead on a 105x105
    /// matrix. ngspice's DEFAULT solver is therefore its strongest showing
    /// here, which is exactly why the default must stay default.
    ngspice_klu: bool = false,
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
    // Per-fixture coverage state (two values), cold alongside report metrics.
    complete: bool = true,
    max_rel: f64,
    rms_rel: f64,
    pass: bool,
};

const Result = struct {
    category: []const u8,
    name: []const u8,
    zp_cpu: ?Timing = null,
    zp_cpu_skip: []const u8 = "",
    zp_cpu_rss_kb: u64 = 0,
    zp_gpu: ?Timing = null,
    zp_gpu_skip: []const u8 = "",
    refs: std.enums.EnumArray(RefId, RefRun) = .initFill(.{}),
    /// espice-CPU against each reference; ngspice is the headline pair.
    cpu_accuracy: std.enums.EnumArray(RefId, ?Accuracy) = .initFill(null),
    gpu_accuracy: ?Accuracy = null,

    fn ng(self: *const Result) RefRun {
        return self.refs.get(.ngspice);
    }
};

/// What each timed binary costs before it has simulated anything: process
/// start, dynamic linking, parser bring-up, raw-file open and close.
///
/// This is not a detail. ngspice pays a fixed **10,229,999 Ir** of
/// dynamic-linker work (`do_lookup_x`, `_dl_lookup_symbol_x`,
/// `_dl_relocate_object`) on every single run — identical to the instruction
/// across four separate decks — where a statically linked espice pays ~0.87M.
/// On a 4 ms deck that difference IS the reported speedup, so a raw wall-clock
/// ratio on a small deck measures the linker, not the simulator. Correcting
/// only the reference would be the same sin in the other direction, so every
/// column carries its own floor, measured the same way in the same run.
const Floors = struct {
    zp_cpu: ?Timing = null,
    zp_gpu: ?Timing = null,
    refs: std.enums.EnumArray(RefId, ?Timing) = .initFill(null),
};

/// The smallest deck every SPICE-syntax simulator accepts: two devices, one
/// operating point. Two devices on purpose — it is the same shape the 0.83M Ir
/// espice floor in docs/perf/slow-decks-2026-09-10.md was measured on.
const floor_deck =
    \\* espice benchmark process floor — two devices, one operating point
    \\v1 1 0 dc 1
    \\r1 1 0 1k
    \\.op
    \\.end
    \\
;

/// What RESULTS.md has always printed: reference wall clock over candidate wall
/// clock, floors included. Kept beside the corrected column on purpose — the
/// difference between the two IS the finding, and deleting the old number would
/// make it unauditable.
fn rawRatio(ref: ?Timing, zp: ?Timing) ?f64 {
    const r = ref orelse return null;
    const z = zp orelse return null;
    if (z.min_ns == 0) return null;
    return @as(f64, @floatFromInt(r.min_ns)) / @as(f64, @floatFromInt(z.min_ns));
}

/// A deck is ranked only when the work left after subtracting BOTH floors is
/// bigger than the floor measurement's own run-to-run noise. Below that the
/// ratio is a measurement of the scheduler.
fn correctedRatio(ref: ?Timing, ref_floor: ?Timing, zp: ?Timing, zp_floor: ?Timing) ?f64 {
    const rt = ref orelse return null;
    const rf = ref_floor orelse return null;
    const zt = zp orelse return null;
    const zf = zp_floor orelse return null;
    const ref_work = rt.min_ns -| rf.min_ns;
    const zp_work = zt.min_ns -| zf.min_ns;
    if (ref_work <= rf.jitter() or zp_work <= zf.jitter()) return null;
    if (zp_work == 0) return null;
    return @as(f64, @floatFromInt(ref_work)) / @as(f64, @floatFromInt(zp_work));
}

/// The speed headline, derived from the same run that printed the table rather
/// than from a hand count afterwards. Both reductions over the same fixtures,
/// so the raw and corrected numbers are directly comparable.
///
/// Geometric mean, not arithmetic: these are ratios, and an arithmetic mean of
/// ratios is not symmetric under swapping which engine is the numerator — a
/// deck we win 4x and a deck we lose 4x average to 2.1x, which reads as a win.
const Summary = struct {
    raw_ranked: usize = 0,
    raw_wins: usize = 0,
    raw_log_sum: f64 = 0,
    raw_sum: f64 = 0,
    corr_ranked: usize = 0,
    corr_wins: usize = 0,
    corr_log_sum: f64 = 0,
    corr_sum: f64 = 0,
    /// Ranked raw, but the floor correction refuses to rank: what is left after
    /// subtracting both process floors is inside the floors' own jitter.
    below_floor: usize = 0,
    /// Decks whose win/lose verdict flips between min-of-N and median-of-N on
    /// the RAW ratio. Each one is a coin toss that a median-only table used to
    /// print as a fact; `docs/perf/slow-decks-2026-09-10.md` found seven.
    p50_flips: usize = 0,

    fn geo(n: usize, log_sum: f64) f64 {
        if (n == 0) return 0;
        return @exp(log_sum / @as(f64, @floatFromInt(n)));
    }

    fn mean(n: usize, sum: f64) f64 {
        if (n == 0) return 0;
        return sum / @as(f64, @floatFromInt(n));
    }
};

fn summarize(results: []const Result, floors: *const Floors) Summary {
    var s: Summary = .{};
    for (results) |r| {
        const ng = r.ng().time;
        if (rawRatio(ng, r.zp_cpu)) |ratio| {
            s.raw_ranked += 1;
            s.raw_wins += @intFromBool(ratio > 1.0);
            s.raw_log_sum += @log(ratio);
            s.raw_sum += ratio;
            const p50 = @as(f64, @floatFromInt(ng.?.p50_ns)) / @as(f64, @floatFromInt(r.zp_cpu.?.p50_ns));
            s.p50_flips += @intFromBool((ratio > 1.0) != (p50 > 1.0));
            if (correctedRatio(ng, floors.refs.get(.ngspice), r.zp_cpu, floors.zp_cpu)) |corr| {
                s.corr_ranked += 1;
                s.corr_wins += @intFromBool(corr > 1.0);
                s.corr_log_sum += @log(corr);
                s.corr_sum += corr;
            } else s.below_floor += 1;
        }
    }
    return s;
}

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

    const refs = resolveRefs(io, gpa, &cfg);
    try reportRefs(out, &refs);

    const floors = measureFloors(io, gpa, &cfg, &refs, out_dir, engine_ok);
    try reportFloors(out, &floors, &refs);

    try reportHeader(out, &refs);
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
            const zp_cpu_argv: []const []const u8 = &.{ cfg.engine_bin, "-b", "--backend", "cpu", "-r", zp_cpu_raw_path, netlist };
            const cap = runCapture(io, fxa, .{ .argv = zp_cpu_argv }, cfg.timeout);
            if (cap.ok and !std.mem.startsWith(u8, cap.text, "{\"skip\"")) {
                // A FIXTURE THAT FAILS MID-TIMING IS A SKIPPED FIXTURE, NOT A
                // DEAD RUN. `timed` returns `error.BenchRunFailed` if any
                // ONE of `iters` repeats fails, and a hard `try` here propagated
                // that out of the fixture loop and killed the whole benchmark —
                // throwing away every result gathered so far and never writing
                // RESULTS.md. The preflight above already passed, so this only
                // fires on a LATER repeat: a `timeout` kill under machine load,
                // or one of the paths we know is not yet deterministic. Both are
                // flaky by nature, which is why the crash looked random and why
                // it hit hardest exactly when the machine was busy. The GPU arm
                // below has always handled its own failure; the other three arms
                // simply never learned to.
                res.zp_cpu = timed(io, fxa, .{ .argv = zp_cpu_argv }, cfg.timeout, cfg.iters, .cpu) catch |err| blk: {
                    res.zp_cpu_skip = if (err == error.BenchRunFailed) "unstable under timing" else @errorName(err);
                    break :blk null;
                };
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
            const zp_gpu_argv: []const []const u8 = &.{ cfg.engine_bin, "-b", "--backend", "auto", "-r", zp_gpu_raw_path, netlist };
            const cap = runCapture(io, fxa, .{ .argv = zp_gpu_argv }, cfg.timeout);
            if (gpuSkipReason(cap.stderr)) |reason| {
                res.zp_gpu_skip = reason;
            } else if (cap.ok and !std.mem.startsWith(u8, cap.text, "{\"skip\"")) {
                res.zp_gpu = timed(io, fxa, .{ .argv = zp_gpu_argv }, cfg.timeout, cfg.iters, .gpu) catch |err| blk: {
                    // `else => return err` was the same run-killer as the CPU arm,
                    // one branch further in: only GpuFallback was survivable.
                    res.zp_gpu_skip = switch (err) {
                        error.GpuFallback => "GPU fell back during timing",
                        error.BenchRunFailed => "unstable under timing",
                        else => @errorName(err),
                    };
                    break :blk null;
                };
            } else if (skipReason(cap.text)) |reason| {
                res.zp_gpu_skip = reason;
            } else {
                res.zp_gpu_skip = "preflight failed";
            }
        } else {
            res.zp_gpu_skip = "engine not found";
        }

        // reference simulators
        for (std.enums.values(RefId)) |id| {
            const ref = refs.get(id);
            if (!ref.on()) continue;
            const run = res.refs.getPtr(id);

            // A reference that cannot READ this deck is a per-fixture skip with
            // a reason, never a dead run: VACASK speaks its own netlist
            // language, so 275 of 280 fixtures legitimately have nothing for it
            // to run.
            const job = buildJob(io, fxa, ref, id, &cfg, out_dir, fx, netlist) catch |err| {
                run.skip = jobSkipReason(err);
                continue;
            };
            // The GATE stays on exit status with output discarded. ngspice
            // prints 4.7 MB on scaling/rc_ladder_100k, past runCapture's 1 MiB
            // cap, and gating on a capture turned a fixture it runs fine into a
            // skip. Only a failure pays for a second, captured run — and it is
            // worth paying for, because a `skip` that cannot say why is what
            // this whole exercise exists to delete.
            // ponytail: a reference that HANGS pays the timeout twice, since
            // the recapture cannot know the first run was killed rather than
            // rejected. Upgrade path if that tail ever matters: return the exit
            // code instead of a bool and skip the recapture on `timeout`'s 124.
            if (!runOk(io, job, cfg.timeout)) {
                run.skip = refSkipReason(fxa, runCapture(io, fxa, job, cfg.timeout));
                continue;
            }
            run.time = timed(io, fxa, job, cfg.timeout, cfg.iters, .quiet) catch |err| blk: {
                run.skip = if (err == error.BenchRunFailed) "unstable under timing" else @errorName(err);
                break :blk null;
            };
            if (run.time == null) continue;
            run.rss_kb = measurePeakRss(io, fxa, job, cfg.timeout);
            run.raw = if (job.raw.len > 0) job.raw else findRaw(io, fxa, job.cwd);
            // Exit 0 is not evidence that anything was WRITTEN. ngspice 44.2
            // rejects `.temp -40 125 55`, finds no other analysis card, and
            // exits 0 having produced no raw at all; a missing raw then fell
            // through as a null Accuracy and printed N/A — "we could not
            // compare these" — when the truth is "there was nothing to
            // compare". Name it at the point where it is still knowable.
            if (run.raw.len > 0) Io.Dir.cwd().access(io, run.raw, .{}) catch {
                run.raw = "";
                run.skip = "ran but wrote no raw";
            };
        }

        // peak RSS (one extra run each, only for fixtures that succeeded)
        if (res.zp_cpu != null) {
            const zp_cpu_argv: []const []const u8 = &.{ cfg.engine_bin, "-b", "--backend", "cpu", "-r", zp_cpu_raw_path, netlist };
            res.zp_cpu_rss_kb = measurePeakRss(io, fxa, .{ .argv = zp_cpu_argv }, cfg.timeout);
        }

        for (std.enums.values(RefId)) |id| {
            const raw = res.refs.get(id).raw;
            if (raw.len == 0 or res.zp_cpu == null) continue;
            res.cpu_accuracy.set(id, compareRawFiles(io, fxa, raw, zp_cpu_raw_path, cfg.rtol));
        }
        if (res.zp_gpu != null and res.ng().raw.len > 0) {
            res.gpu_accuracy = compareRawFiles(io, fxa, res.ng().raw, zp_gpu_raw_path, cfg.rtol);
        }

        // skip strings may slice fixture-arena memory; dupe survivors
        if (res.zp_cpu_skip.len > 0) res.zp_cpu_skip = try gpa.dupe(u8, res.zp_cpu_skip);
        if (res.zp_gpu_skip.len > 0) res.zp_gpu_skip = try gpa.dupe(u8, res.zp_gpu_skip);
        for (std.enums.values(RefId)) |id| {
            const run = res.refs.getPtr(id);
            if (run.skip.len > 0) run.skip = try gpa.dupe(u8, run.skip);
            run.raw = "";
        }

        try reportRow(out, res, &floors, &prev_cat);
        try out.flush();
        try results.append(gpa, res);
    }

    // The floor again, after the sweep, on the same decks with the same
    // statistic. It is NOT used to correct anything — every `*` column above
    // was already printed against the opening floor, and a table whose rows
    // were computed against a number that changed underneath them is worse than
    // a slightly stale one. What it is for is the error bar: re-deriving the
    // headline against this second draw says how much of the corrected number
    // is the correction and how much is the half hour that passed.
    const closing = measureFloors(io, gpa, &cfg, &refs, out_dir, engine_ok);

    try reportFooter(out, summarize(results.items, &floors), summarize(results.items, &closing));
    try out.flush();

    writeResultsMd(io, gpa, cfg.out_path, results.items, cfg.rtol, &refs, &floors, &closing);
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

fn parseRawFile(io: Io, gpa: std.mem.Allocator, path: []const u8) ?[]const Plot {
    const blob = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return null;
    return parseRawBlob(gpa, blob);
}

/// Every plot in the raw, in file order. A `.tran`+`.ac` deck writes two, and
/// the two engines do not agree on the order (espice writes Operating Point
/// first, ngspice writes AC first), so the caller matches by NAME — see
/// `compareRawFiles`. Returns null only when the file is unparseable; a raw
/// whose first plot parses and whose tail does not is null too, because a
/// partially-read raw silently drops analyses.
fn parseRawBlob(gpa: std.mem.Allocator, blob: []const u8) ?[]const Plot {
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

/// One spelling for a signal across four simulators. The same node is `v(out)`
/// to ngspice and espice, `OUT` (or `V(1)`) to Xyce and `2` to VACASK; the same
/// branch current is `i(vin)`, `VIN#branch` and `vs:flow(br)`. Without this,
/// every reference except ngspice matches zero columns and reports a vacuous
/// N/A while looking like it validated something.
fn normalizeVarName(gpa: std.mem.Allocator, lower: []const u8) []const u8 {
    if (scale_names.has(lower)) return lower;
    if (scale_aliases.get(lower)) |canonical| return canonical;
    if (std.mem.startsWith(u8, lower, "v(") or std.mem.startsWith(u8, lower, "i(")) return lower;
    const branch = std.mem.indexOf(u8, lower, "#branch") orelse std.mem.indexOf(u8, lower, ":flow(");
    if (branch) |cut| return std.fmt.allocPrint(gpa, "i({s})", .{lower[0..cut]}) catch lower;
    return std.fmt.allocPrint(gpa, "v({s})", .{lower}) catch lower;
}

// ============================================================================
// Accuracy comparison
// ============================================================================

fn compareRawFiles(io: Io, gpa: std.mem.Allocator, ng_path: []const u8, zp_path: []const u8, rtol: f64) ?Accuracy {
    const ng = parseRawFile(io, gpa, ng_path) orelse return null;
    const zp = parseRawFile(io, gpa, zp_path) orelse return null;
    return compareRaws(gpa, ng, zp, rtol);
}

/// Every reference plot against the candidate plot of the same analysis CLASS,
/// worst pair wins. Matching is by name, never by index: on every multi-analysis
/// deck the two engines write the plots in different orders (espice puts
/// Operating Point first, ngspice puts AC first), so index-matching would score
/// an AC sweep against an operating point and call it a failure.
///
/// A reference plot with no candidate counterpart is a coverage gap
/// (`complete = false` -> N/A), never a pass. A CANDIDATE-only plot is not: for
/// `.four` espice writes a `Fourier Analysis` plot into the raw where ngspice
/// prints its table to stdout, and an extra analysis nobody asked to compare is
/// not evidence of anything.
fn compareRaws(gpa: std.mem.Allocator, ng: []const Plot, zp: []const Plot, rtol: f64) ?Accuracy {
    var worst: Accuracy = .{ .max_rel = 0, .rms_rel = 0, .pass = true };
    var scored: usize = 0;
    // Each candidate plot answers for at most one reference plot, so a deck with
    // two `.dc` legs cannot score both against the same candidate.
    const taken = gpa.alloc(bool, zp.len) catch return null;
    defer gpa.free(taken);
    @memset(taken, false);

    for (ng) |ng_plot| {
        var ng_buf: [128]u8 = undefined;
        const ng_class = plotClass(&ng_buf, ng_plot.plotname);
        const zi = for (zp, 0..) |zp_plot, i| {
            if (taken[i]) continue;
            var zp_buf: [128]u8 = undefined;
            if (std.mem.eql(u8, ng_class, plotClass(&zp_buf, zp_plot.plotname))) break i;
        } else {
            worst.complete = false;
            continue;
        };
        taken[zi] = true;
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
    // Same rule `comparePlots` applies within one plot: an incomplete comparison
    // cannot be a pass. Without this a deck whose `.ac` leg matched and whose
    // `.tran` leg had no counterpart at all carries `pass = true` into any caller
    // that reads the field instead of `accuracyStatus`.
    worst.pass = worst.pass and worst.complete;
    return worst;
}

fn comparePlots(gpa: std.mem.Allocator, ng: Plot, zp: Plot, rtol: f64) ?Accuracy {
    // A complex plot against a real one is not a comparison — one of the two
    // engines ran a different analysis.
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
    // An `.ac`/`.sp`/`.pz` raw stores each entry as an (re, im) pair, so every
    // column is TWO real series and the scale lives in the real half. Both sides
    // agree on `is_complex` by the guard above.
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

    // Any column BOTH engines emit, keyed by name — v(node) and i(source)
    // alike. The old v( filter made every current-keyed fixture (gummel,
    // transfer) pass vacuously: espice raws had no i(...) columns to find,
    // so nothing was compared.
    for (ng.varnames, 0..) |ng_name, ni| {
        // Transient time grids differ; other scales still participate in error.
        if (interpolate and scale_names.has(ng_name)) continue;
        const zi = columns.get(ng_name) orelse {
            if (isInternalNode(ng_name)) continue;
            // A scale the candidate does not emit is not a missing SIGNAL.
            // Xyce runs `.op` as a one-point DC sweep and therefore writes a
            // sweep column that an operating point has no counterpart for;
            // holding that against coverage marked every Xyce `.op` fixture
            // N/A. `any` below still requires a real non-scale column to have
            // matched, so a plot that agreed only on its scale is not a pass.
            if (scale_names.has(ng_name)) continue;
            complete = false;
            continue;
        };
        // Real and imaginary are scored SEPARATELY and the worse one is kept.
        // Collapsing to magnitude first would let a phase-convention error read
        // as a pass, which is the one thing an AC comparison exists to catch.
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

            // Candidate-side bracket for the edge window below. Hoisted: x walks
            // ng_scale in increasing order, so this only ever moves forward.
            var j: usize = 0;

            for (ng_scale, ng_var, 0..) |x, ya, i| {
                var yb = if (interpolate) interp(zp_scale, zp_var, x) else blk: {
                    if (count < zp_var.len) break :blk zp_var[count] else return null;
                };
                if (!std.math.isFinite(yb)) return .{ .max_rel = std.math.inf(f64), .rms_rel = std.math.inf(f64), .pass = false };
                // Edge-phase tolerance: a steep edge cannot be timed below the
                // REFERENCE's own local grid. If the pointwise error is large,
                // re-sample the candidate inside one reference-step window each
                // way and keep the best match — a sub-grid timing offset on a
                // vertical edge then reads as ~0 instead of the full swing, while
                // a genuine level error (or a shift beyond the reference's own
                // resolution, e.g. schmitt's 5 ns snap delay) still fails.
                if (interpolate and @abs(ya - yb) / denom > 1e-3) {
                    const dt_lo = if (i > 0) x - ng_scale[i - 1] else 0;
                    const dt_hi = if (i + 1 < ng_scale.len) ng_scale[i + 1] - x else 0;
                    // A steep edge also cannot be timed below the CANDIDATE's own
                    // local grid. Right after a source breakpoint ngspice emits a
                    // sub-picosecond sample; interpolating our (2 ps) step across a
                    // genuine time-discontinuity there reads as the full jump.
                    // ponytail: local bracket only, no bisect — the scan is monotone.
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
                // Scale agreement alone proves nothing about circuit behavior.
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
    .{ "time", {} }, .{ "frequency", {} }, .{ "v(v-sweep)", {} }, .{ "i(i-sweep)", {} }, .{ "temp-sweep", {} },
});

/// One simulator's spelling of a scale another simulator already names. Xyce
/// calls the DC-sweep scale `sweep` whatever is being swept; ngspice and espice
/// name it after the swept source. Without the alias the column normalizes to
/// `v(sweep)`, matches nothing, and every DC fixture reports N/A on coverage
/// grounds while its real signals agree to machine precision.
///
/// `vsweep` is OURS. A VACASK sweep is named by its deck and VACASK
/// identifiers cannot contain `-`, so the decks under `fixtures/*/*/vacask`
/// spell that same scale `vsweep`.
const scale_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "sweep", "v(v-sweep)" },
    .{ "vsweep", "v(v-sweep)" },
});

/// Analysis class behind a plotname. Xyce runs `.op` as a one-point DC sweep
/// and labels the plot "DC transfer characteristic" (or, when an `.ac` card
/// follows, "DC operating point"); ngspice and espice label it "Operating
/// Point". Same analysis, three spellings. An unlisted plotname is its own
/// class, so the guard still rejects a transient-vs-DC mixup and a new analysis
/// can never silently alias onto an existing one.
const plot_classes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "operating point", "dc" },
    .{ "dc operating point", "dc" },
    .{ "dc transfer characteristic", "dc" },
});

/// `buf` must outlive the result. A plotname too long to lowercase in place
/// falls back to itself, so an unusually long name degrades to the old
/// exact-match rule rather than to a silent refusal to compare.
fn plotClass(buf: []u8, plotname: []const u8) []const u8 {
    if (plotname.len > buf.len) return plotname;
    const lower = std.ascii.lowerString(buf[0..plotname.len], plotname);
    return plot_classes.get(lower) orelse lower;
}

/// The tail Xyce gives a node its MODEL created rather than the deck. ngspice
/// marks these with `#` and VACASK with `:`, so they were already exempt;
/// Xyce spells them `q1_baseprime`, `d1_internal`, `t1_int1` — plain
/// identifiers with no marker at all, which held 28 fixtures at N/A on
/// coverage grounds while their deck nodes matched to 1e-12 or better.
///
/// Closed list on purpose. A Xyce device whose internal node is not named here
/// makes its fixture read N/A, which is loud; a wildcard would make it read
/// PASS, which is silent. If a new device appears, add it and say so.
const xyce_internal_nodes = std.StaticStringMap(void).initComptime(.{
    .{ "internal", {} }, // diode series resistance
    .{ "baseprime", {} }, .{ "collectorprime", {} }, .{ "emitterprime", {} }, // BJT
    .{ "drainprime", {} }, .{ "sourceprime", {} }, .{ "body", {} }, // MOSFET/JFET/MESFET
    .{ "branch1", {} }, .{ "branch2", {} }, // lossy transmission line
    .{ "i1", {} },       .{ "i2", {} },       .{ "int1", {} },      .{ "int2", {} }, // ideal transmission line
});

/// A node a MODEL created, not one the deck named. Which of these exist and
/// what they are called is an implementation choice, so an absent counterpart
/// is not a coverage gap. `!` is Xyce's marker for a device IT synthesised —
/// a mutual inductor becomes `ymil!k1_l1` — and `normalizeVarName` has already
/// eaten the `#branch` that would otherwise have flagged it.
fn isInternalNode(name: []const u8) bool {
    if (std.mem.indexOfAny(u8, name, "#:!") != null) return true;
    // Unwrap the `v(...)`/`i(...)` normalizeVarName put on, so the instance
    // name has to be there: `d1_internal` is a model node, `_body` is a deck
    // node whose name happens to start with an underscore.
    const inner = if (name.len > 3 and name[1] == '(' and name[name.len - 1] == ')') name[2 .. name.len - 1] else name;
    const cut = std.mem.lastIndexOfScalar(u8, inner, '_') orelse return false;
    return cut > 0 and xyce_internal_nodes.has(inner[cut + 1 ..]);
}

/// One real series out of the interleaved raw blob. `parts` is 1 for a real
/// plot and 2 for a complex one, where `part` selects re (0) or im (1).
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

    // An iteration error is NOT end-of-directory. `catch null` ends the loop,
    // so a transient readdir failure silently truncated the fixture list and
    // the run looked complete while quietly benchmarking a prefix of the suite.
    var cit = root.iterate();
    while (cit.next(io) catch |e| lbl: {
        std.debug.print("error: reading '{s}': {s}; fixture list is TRUNCATED\n", .{ fixtures_dir, @errorName(e) });
        break :lbl null;
    }) |ce| {
        if (ce.kind != .directory) continue;
        const category = try gpa.dupe(u8, ce.name);

        var cat_dir = root.openDir(io, category, .{ .iterate = true }) catch continue;
        defer cat_dir.close(io);
        var fit = cat_dir.iterate();
        while (fit.next(io) catch |e| lbl: {
            std.debug.print("error: reading '{s}': {s}; category is TRUNCATED\n", .{ category, @errorName(e) });
            break :lbl null;
        }) |fe| {
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
// Reference simulators
// ============================================================================

/// Resolve each reference's binary and stamp it with its own version banner.
/// A reference with no banner is DISABLED — that is the single gate for both
/// "--no-xyce" and "the binary is not installed".
fn resolveRefs(io: Io, gpa: std.mem.Allocator, cfg: *const Config) std.enums.EnumArray(RefId, Ref) {
    var refs: std.enums.EnumArray(RefId, Ref) = .initFill(.{ .bin = "", .label = "" });
    for (std.enums.values(RefId)) |id| {
        var ref: Ref = .{ .bin = cfg.bins.get(id) orelse pinnedOrPath(io, id), .label = refLabel(id, cfg) };
        if (cfg.use.get(id)) ref.version = probeVersion(io, gpa, id, ref.bin);
        refs.set(id, ref);
    }
    return refs;
}

/// Prefer the pinned store path; fall back to $PATH only when it is gone
/// (nix GC, or a non-NixOS host). `reportRefs` prints whichever won.
fn pinnedOrPath(io: Io, id: RefId) []const u8 {
    const pinned = default_bin.get(id);
    Io.Dir.cwd().access(io, pinned, .{}) catch return path_bin.get(id);
    return pinned;
}

fn refLabel(id: RefId, cfg: *const Config) []const u8 {
    return switch (id) {
        .ngspice => if (cfg.ngspice_klu) "ng+klu" else "ngspice",
        .xyce => "xyce",
        .vacask => "vacask",
    };
}

/// The flag each simulator answers a version query on. VACASK has no --version
/// at all: `-h` is the only thing that prints its banner and it exits NON-ZERO
/// doing so, which is why the banner text — not the exit status — is the probe.
fn versionFlag(id: RefId) []const u8 {
    return switch (id) {
        .ngspice => "--version",
        .xyce => "-v",
        .vacask => "-h",
    };
}

fn probeVersion(io: Io, gpa: std.mem.Allocator, id: RefId, bin: []const u8) []const u8 {
    return firstBannerLine(runCapture(io, gpa, .{ .argv = &.{ bin, versionFlag(id) } }, "30").text);
}

/// First line carrying an actual word: ngspice opens its banner with a row of
/// `******`, which names nothing.
fn firstBannerLine(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r*");
        for (line) |c| if (std.ascii.isAlphabetic(c)) return line;
    }
    return "";
}

const JobError = error{ NoDeck, DeckFailed, ScratchFailed, OutOfMemory };

fn jobSkipReason(err: JobError) []const u8 {
    return switch (err) {
        error.NoDeck => "no native vacask/ deck",
        error.DeckFailed => "deck rewrite failed",
        error.ScratchFailed => "scratch dir failed",
        error.OutOfMemory => "out of memory",
    };
}

/// Everything one reference needs to run one fixture. Returning an error here
/// is a PER-FIXTURE skip with a reason, never a dead run — VACASK legitimately
/// has nothing to run on the 275 fixtures that ship no vacask.sim.
fn buildJob(
    io: Io,
    gpa: std.mem.Allocator,
    ref: Ref,
    id: RefId,
    cfg: *const Config,
    out_dir: []const u8,
    fx: Fixture,
    netlist: []const u8,
) JobError!Job {
    switch (id) {
        // ngspice and Xyce both read SPICE and both write a spice3 binary raw
        // under -r, so they share an argv shape exactly.
        .ngspice, .xyce => {
            const raw = try std.fmt.allocPrint(gpa, "{s}/{s}--{s}.{s}.raw", .{ out_dir, fx.category, fx.name, @tagName(id) });
            const deck = if (id == .ngspice and cfg.ngspice_klu)
                try kluDeck(io, gpa, out_dir, fx, netlist)
            else if (id == .xyce)
                try xyceDeck(io, gpa, out_dir, fx, netlist)
            else
                netlist;
            return .{ .argv = try gpa.dupe([]const u8, &.{ ref.bin, "-b", "-r", raw, deck }), .raw = raw };
        },
        // VACASK speaks its own netlist language, not SPICE, so it runs only
        // where a native deck exists at <fixture>/vacask/runme.sim. Its own
        // subdirectory, byte-identical to upstream's benchmark layout, keeps
        // `models.inc`/`multiplier.inc` from colliding with the SPICE-syntax
        // files of the same name that already sit in the fixture.
        //
        // VACASK also has NO output-path flag — it drops <analysis>.raw into
        // the CWD — so the deck is staged into a private scratch dir. That
        // keeps deck-relative `include` resolving and stops fixtures from
        // overwriting each other's raws in the repo root.
        .vacask => {
            const deck_dir = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}/vacask", .{ cfg.fixtures_dir, fx.category, fx.name });
            Io.Dir.cwd().access(io, deck_dir, .{}) catch return error.NoDeck;
            const scratch = try std.fmt.allocPrint(gpa, "{s}/{s}--{s}.vacask", .{ out_dir, fx.category, fx.name });
            stageDir(io, deck_dir, scratch) catch return error.ScratchFailed;
            return .{
                .argv = try gpa.dupe([]const u8, &.{ ref.bin, "-se", "-sp", "runme.sim" }),
                .cwd = .{ .path = scratch },
            };
        },
    }
}

/// Fresh copy of a fixture's files (deck plus whatever it includes) into a
/// scratch dir, so every timed repeat starts from the same state.
fn stageDir(io: Io, src: []const u8, dst: []const u8) !void {
    Io.Dir.cwd().deleteTree(io, dst) catch {};
    try Io.Dir.cwd().createDirPath(io, dst);
    var sd = try Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer sd.close(io);
    var dd = try Io.Dir.cwd().openDir(io, dst, .{});
    defer dd.close(io);
    var it = sd.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        try sd.copyFile(e.name, dd, e.name, io, .{});
    }
}

/// VACASK names its result file after the analysis (tran1.raw, tranmul.raw),
/// so the scratch dir is scanned rather than guessed. `stageDir` wipes it
/// before every run, so any .raw found there belongs to this fixture.
fn findRaw(io: Io, gpa: std.mem.Allocator, cwd: std.process.Child.Cwd) []const u8 {
    const dir_path = switch (cwd) {
        .path => |p| p,
        else => return "",
    };
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return "";
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".raw")) continue;
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, e.name }) catch "";
    }
    return "";
}

/// ngspice picks its solver from a CARD, not a CLI flag, so KLU mode means
/// writing a copy of the deck with `.options klu` spliced in after the title
/// (SPICE always treats line 1 as the title, never as a card). Decks that
/// already carry the option are used untouched — the five imported from
/// VACASK's own benchmark suite do, which also means their DEFAULT ngspice
/// column has been KLU all along.
fn kluDeck(io: Io, gpa: std.mem.Allocator, out_dir: []const u8, fx: Fixture, netlist: []const u8) JobError![]const u8 {
    const text = Io.Dir.cwd().readFileAlloc(io, netlist, gpa, .limited(1 << 26)) catch return error.DeckFailed;
    if (deckHasKlu(text)) return netlist;
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}--{s}.klu.sp", .{ out_dir, fx.category, fx.name });
    const body = try std.fmt.allocPrint(gpa, "{s}\n.options klu\n{s}", .{ text[0..nl], text[@min(nl + 1, text.len)..] });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch return error.DeckFailed;
    return path;
}

/// Cards Xyce reads but that only steer ITS OWN print files. We take the raw
/// off `-r`, so dropping them costs nothing — and keeping them is not free:
/// a `.print AC` card beside a `.tran` card is a hard Xyce error ("Analysis
/// type TRAN and print type AC are inconsistent") even though nothing in this
/// benchmark ever reads what it names, and `.print` lines naming an ngspice
/// spelling Xyce has no symbol for ("undefined symbol VIDS#BRANCH") abort the
/// run outright.
const xyce_dropped_cards = std.StaticStringMap(void).initComptime(.{
    .{ ".print", {} }, .{ ".plot", {} }, .{ ".width", {} },
});

/// Xyce is SPICE3-compatible on the CIRCUIT and diverges on ngspice's lexical
/// and output-control extensions, so it reads a respelled copy of the deck.
/// Three rules, all line-local:
///   1. ` $ ...` — ngspice's inline comment. Xyce spells it `;` and parses the
///      comment as extra device fields ("Unrecognized parameter AC Too Many
///      Terms for device VIN").
///   2. `.print`/`.plot`/`.width` — see xyce_dropped_cards.
///   3. `dc=V` on a source card — ngspice accepts the `=` form, Xyce takes
///      only the positional `DC V` ("Invalid DC value \"=\" for device VS").
/// Topology, models, parameters and analysis cards are passed through byte for
/// byte. This changes how the deck is SPELLED, never what it asks for — a
/// rewrite that changed the circuit would make every Xyce column meaningless.
fn xyceDeck(io: Io, gpa: std.mem.Allocator, out_dir: []const u8, fx: Fixture, netlist: []const u8) JobError![]const u8 {
    const text = Io.Dir.cwd().readFileAlloc(io, netlist, gpa, .limited(1 << 26)) catch return error.DeckFailed;
    var body: std.ArrayList(u8) = .empty;
    try body.ensureTotalCapacity(gpa, text.len);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripInlineComment(raw_line);
        if (isDroppedCard(line)) continue;
        var rest = line;
        while (std.mem.indexOf(u8, rest, "dc=")) |cut| {
            // Token boundary only: a bare `dc=` is a card field, `dc=` glued to
            // a name (ngspice's `sinedc=`) is a different parameter.
            const boundary = cut == 0 or rest[cut - 1] == ' ' or rest[cut - 1] == '\t';
            try body.appendSlice(gpa, rest[0..cut]);
            try body.appendSlice(gpa, if (boundary) "DC " else "dc=");
            rest = rest[cut + 3 ..];
        }
        try body.appendSlice(gpa, rest);
        try body.append(gpa, '\n');
    }

    const path = try std.fmt.allocPrint(gpa, "{s}/{s}--{s}.xyce.sp", .{ out_dir, fx.category, fx.name });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.items }) catch return error.DeckFailed;
    return path;
}

/// ngspice ends a line at an unquoted `$` that follows whitespace (or opens the
/// line). Anything else — a `$` glued to a token — is left alone.
fn stripInlineComment(line: []const u8) []const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, i, '$')) |cut| {
        if (cut == 0 or line[cut - 1] == ' ' or line[cut - 1] == '\t') return line[0..cut];
        i = cut + 1;
    }
    return line;
}

fn isDroppedCard(line: []const u8) bool {
    const start = std.mem.trimStart(u8, line, " \t");
    if (start.len == 0 or start[0] != '.') return false;
    const end = std.mem.indexOfAny(u8, start, " \t\r") orelse start.len;
    var buf: [16]u8 = undefined;
    if (end > buf.len) return false;
    return xyce_dropped_cards.has(std.ascii.lowerString(&buf, start[0..end]));
}

fn deckHasKlu(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var words = std.mem.tokenizeAny(u8, std.mem.trim(u8, raw, " \t\r"), " \t");
        const card = words.next() orelse continue;
        if (!std.ascii.startsWithIgnoreCase(card, ".option")) continue;
        while (words.next()) |w| if (std.ascii.eqlIgnoreCase(w, "klu")) return true;
    }
    return false;
}

// ============================================================================
// Child process
// ============================================================================

fn spawnQuiet(io: Io, job: Job, timeout: []const u8, stdout: std.process.SpawnOptions.StdIo) !std.process.Child {
    var buf: [64][]const u8 = undefined;
    buf[0] = "timeout";
    buf[1] = timeout;
    @memcpy(buf[2..][0..job.argv.len], job.argv);
    return std.process.spawn(io, .{
        .argv = buf[0 .. job.argv.len + 2],
        .cwd = job.cwd,
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

const Capture = struct { ok: bool, text: []const u8, stderr: []const u8 };

fn runCapture(io: Io, gpa: std.mem.Allocator, job: Job, timeout: []const u8) Capture {
    var buf: [64][]const u8 = undefined;
    buf[0] = "timeout";
    buf[1] = timeout;
    @memcpy(buf[2..][0..job.argv.len], job.argv);
    const result = std.process.run(gpa, io, .{
        .argv = buf[0 .. job.argv.len + 2],
        .cwd = job.cwd,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch return .{ .ok = false, .text = "", .stderr = "capture failed" };
    return .{
        .ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        },
        .text = std.mem.trim(u8, result.stdout, " \t\r\n"),
        .stderr = result.stderr,
    };
}

/// Did this run actually reach the device, or is its time a CPU time wearing a
/// GPU label?
///
/// Matched on the STABLE tokens of `engine.zig`'s three whole-run refusals
/// (`prepare`, ~line 345/354/369), not on their prose. The prose is what broke
/// this: the needles used to be the literal strings `--gpu declined` and
/// `--gpu unavailable`, the backend-policy revision reworded them to `auto
/// declined the GPU` / `GPU declined (...)` / `GPU unavailable (...)`, and the
/// matcher silently stopped firing. Every fixture the `min_work` gate declines
/// has been reporting its CPU time in the `zp-gpu` column ever since — which is
/// exactly the failure `engine.prepare`'s own comment says it exists to
/// prevent, landing one file over. "GPU" plus a refusal verb survives rewording;
/// four verbatim phrases and a "keep in sync" comment already did not.
fn gpuSkipReason(stderr: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "GPU") == null) continue;
        if (std.mem.indexOf(u8, line, "declin") != null or
            std.mem.indexOf(u8, line, "unavailable") != null or
            std.mem.indexOf(u8, line, "falling back to the CPU") != null) return line;
    }
    return null;
}

fn skipReason(text: []const u8) ?[]const u8 {
    const prefix = "{\"skip\":\"";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const rest = text[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// Substrings each reference puts on the one line that says WHY it refused a
/// deck. Ordered by how specific the line is, and scanned as substrings rather
/// than keyed, so this is a list and not a StaticStringMap. "preflight failed"
/// is the fallback and it is a bad answer — a bare skip is exactly what hid the
/// fact that Xyce had never been run on this suite at all.
const ref_failure_markers = [_][]const u8{
    "Model is required", // Xyce: a model LEVEL it does not implement
    "No model found",
    "not formatted correctly", // Xyce: model parameter it does not know
    "Unrecognized parameter",
    "Unrecognized fields",
    "undefined symbol",
    "are inconsistent",
    "Invalid DC value",
    "Netlist error:", // Xyce: e.g. "No analysis specified."
    "Time step too small",
    "has failed",
    "not supported",
    "Error on line", // ngspice
    "error:", // VACASK
};

/// BOTH streams: Xyce puts its netlist diagnostics on stdout, ngspice puts
/// `Error on line 5 or its substitute:` on stderr and the offending card on the
/// line after it. Scanning one stream, or one line, leaves 38 of the 40
/// ngspice skips saying nothing.
fn refSkipReason(gpa: std.mem.Allocator, cap: Capture) []const u8 {
    for (ref_failure_markers) |needle| {
        for ([_][]const u8{ cap.text, cap.stderr }) |haystack| {
            var lines = std.mem.splitScalar(u8, haystack, '\n');
            while (lines.next()) |raw| {
                if (std.mem.indexOf(u8, raw, needle) == null) continue;
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0) continue;
                if (line[line.len - 1] != ':') return line[0..@min(line.len, 90)];
                while (lines.next()) |next_raw| {
                    const next = std.mem.trim(u8, next_raw, " \t\r");
                    if (next.len == 0) continue;
                    const joined = std.fmt.allocPrint(gpa, "{s} {s}", .{ line, next }) catch line;
                    return joined[0..@min(joined.len, 90)];
                }
                return line[0..@min(line.len, 90)];
            }
        }
    }
    return "preflight failed";
}

fn runOk(io: Io, job: Job, timeout: []const u8) bool {
    var child = spawnQuiet(io, job, timeout, .ignore) catch return false;
    return waitOk(&child, io);
}

const TimingMode = enum { quiet, cpu, gpu };

fn timed(io: Io, gpa: std.mem.Allocator, job: Job, timeout: []const u8, iters: u32, mode: TimingMode) !Timing {
    const samples = try gpa.alloc(u64, iters);
    for (samples) |*s| {
        const t0 = Io.Timestamp.now(io, .awake);
        // External simulators print large tables; their exit status is the gate.
        const ok = if (mode == .quiet) runOk(io, job, timeout) else blk: {
            const cap = runCapture(io, gpa, job, timeout);
            if (mode == .gpu and gpuSkipReason(cap.stderr) != null) return error.GpuFallback;
            break :blk cap.ok and skipReason(cap.text) == null;
        };
        const t1 = Io.Timestamp.now(io, .awake);
        if (!ok) return error.BenchRunFailed;
        s.* = @intCast(t0.durationTo(t1).nanoseconds);
    }
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{ .min_ns = samples[0], .p50_ns = samples[samples.len / 2] };
}

/// One floor per timed binary, in the same run, with the same statistic, on the
/// same deck. Measured BEFORE the fixtures so it is not sitting inside whatever
/// page-cache state a 280-deck sweep leaves behind.
///
/// `timedMode` for the espice GPU column is `.cpu`, not `.gpu`, on purpose: the
/// null deck has no device work at all, so `--backend auto` declines the GPU and
/// says so, and treating that as a fallback error would leave the gpu column
/// with no floor. What we want here is the cost of STARTING `--backend auto`,
/// hardware probe included, which is exactly what this measures.
fn measureFloors(
    io: Io,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    refs: *const std.enums.EnumArray(RefId, Ref),
    out_dir: []const u8,
    engine_ok: bool,
) Floors {
    var floors: Floors = .{};
    const deck = std.fmt.allocPrint(gpa, "{s}/floor.sp", .{out_dir}) catch return floors;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = deck, .data = floor_deck }) catch return floors;
    const raw = std.fmt.allocPrint(gpa, "{s}/floor.raw", .{out_dir}) catch return floors;
    const fx: Fixture = .{ .category = "_floor", .name = "null" };
    // The floor is ONE number reused by every row, so it is worth far more
    // repeats than any single fixture gets — and a min-of-N converges from
    // ABOVE, so an under-sampled floor is systematically too HIGH, which
    // over-subtracts from both sides and refuses decks it should have ranked.
    // At 5-11 ms a run, 40 repeats of one two-device deck costs under a second.
    const iters = @max(cfg.iters, 40);

    if (engine_ok) {
        for ([_][]const u8{ "cpu", "auto" }, [_]*?Timing{ &floors.zp_cpu, &floors.zp_gpu }) |backend, slot| {
            const job: Job = .{ .argv = &.{ cfg.engine_bin, "-b", "--backend", backend, "-r", raw, deck } };
            if (!runOk(io, job, cfg.timeout)) continue;
            slot.* = timed(io, gpa, job, cfg.timeout, iters, .cpu) catch null;
        }
    }
    for (std.enums.values(RefId)) |id| {
        const ref = refs.get(id);
        if (!ref.on()) continue;
        // VACASK does not read SPICE, so it has no floor here and no
        // floor-corrected column; it also feeds no ratio.
        const job = buildJob(io, gpa, ref, id, cfg, out_dir, fx, deck) catch continue;
        if (!runOk(io, job, cfg.timeout)) continue;
        floors.refs.set(id, timed(io, gpa, job, cfg.timeout, iters, .quiet) catch null);
    }
    return floors;
}

// GNU time peak RSS in KiB — returns 0 if unavailable or the run failed.
fn measurePeakRss(io: Io, gpa: std.mem.Allocator, job: Job, timeout: []const u8) u64 {
    // Resolve GNU time through PATH (Nix has no /usr/bin/time).
    var buf: [70][]const u8 = undefined;
    buf[0] = "time";
    buf[1] = "-v";
    buf[2] = "timeout";
    buf[3] = timeout;
    @memcpy(buf[4..][0..job.argv.len], job.argv);
    var child = std.process.spawn(io, .{
        .argv = buf[0 .. job.argv.len + 4],
        .cwd = job.cwd,
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
    if (!waitOk(&child, io)) return 0;
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

/// The reference the headline ratio and the PASS/FAIL gate are taken against.
const primary_ref: RefId = .ngspice;

const ref_mb_label = std.enums.EnumArray(RefId, []const u8).init(.{ .ngspice = "ng-MB", .xyce = "xy-MB", .vacask = "vc-MB" });
const ref_acc_label = std.enums.EnumArray(RefId, []const u8).init(.{ .ngspice = "ng", .xyce = "xy", .vacask = "vc" });

/// Name the binary and version behind every column, on stdout and in
/// RESULTS.md. Ratios quoted against an unnamed "ngspice" are not reproducible:
/// two 44.2 builds on this host differ by 8.5% in instruction count.
fn reportRefs(out: *Io.Writer, refs: *const std.enums.EnumArray(RefId, Ref)) !void {
    try out.writeAll("reference simulators:\n");
    for (std.enums.values(RefId)) |id| {
        const ref = refs.get(id);
        if (!ref.on()) {
            try out.print("  {s:<8} DISABLED ({s})\n", .{ ref.label, if (ref.bin.len > 0) ref.bin else "not selected" });
            continue;
        }
        // Say so out loud when the pin was not what ran. A silently-substituted
        // reference is the exact failure this pinning exists to prevent.
        const pinned = std.mem.eql(u8, ref.bin, default_bin.get(id));
        try out.print("  {s:<8} {s}\n           {s}{s}\n", .{
            ref.label, ref.version, ref.bin,
            @as([]const u8, if (pinned) "" else "   <- NOT the pinned build (pinned path missing)"),
        });
    }
    try out.writeAll("\n");
}

/// The per-binary process floor, printed before the table so every ratio below
/// it can be re-derived by hand. A floor that failed to measure prints `-`, and
/// that column then has no corrected ratio at all rather than a silently
/// uncorrected one.
fn reportFloors(out: *Io.Writer, floors: *const Floors, refs: *const std.enums.EnumArray(RefId, Ref)) !void {
    try out.writeAll("process floor (two devices, one .op — subtracted from every corrected ratio):\n");
    try printFloor(out, "zp-cpu", floors.zp_cpu);
    try printFloor(out, "zp-gpu", floors.zp_gpu);
    for (std.enums.values(RefId)) |id| {
        if (!refs.get(id).on()) continue;
        try printFloor(out, refs.get(id).label, floors.refs.get(id));
    }
    try out.writeAll("\n");
}

fn printFloor(out: *Io.Writer, label: []const u8, t: ?Timing) !void {
    try out.print("  {s:<8} ", .{label});
    if (t) |v| {
        try printDur(out, v);
        try out.print("  (median {d:.2} ms, jitter {d:.2} ms)\n", .{
            @as(f64, @floatFromInt(v.p50_ns)) / 1e6,
            @as(f64, @floatFromInt(v.jitter())) / 1e6,
        });
    } else {
        try out.writeAll("not measured — no corrected ratio for this column\n");
    }
}

fn reportHeader(out: *Io.Writer, refs: *const std.enums.EnumArray(RefId, Ref)) !void {
    try out.print("{s:<34} {s:>12} {s:>12}", .{ "fixture", "zp-cpu", "zp-gpu" });
    for (std.enums.values(RefId)) |id| try out.print(" {s:>12}", .{refs.get(id).label});
    try out.print(" {s:>7} {s:>7} {s:>7} {s:>7}  {s:>8}", .{ "cpu/ng", "cpu/ng*", "gpu/ng", "gpu/ng*", "zp-MB" });
    for (std.enums.values(RefId)) |id| try out.print(" {s:>8}", .{ref_mb_label.get(id)});
    try out.print("  {s:>10} {s:>10} {s:>5}  {s:>10} {s:>10} {s:>5}", .{ "cpu-max", "cpu-rms", "cpu", "gpu-max", "gpu-rms", "gpu" });
    for (std.enums.values(RefId)) |id| {
        if (id == primary_ref) continue;
        try out.print(" {s:>6}", .{ref_acc_label.get(id)});
    }
    try out.writeAll("\n");

    try out.print("{s:-<34} {s:->12} {s:->12}", .{ "", "", "" });
    for (std.enums.values(RefId)) |_| try out.print(" {s:->12}", .{""});
    try out.print(" {s:->7} {s:->7} {s:->7} {s:->7}  {s:->8}", .{ "", "", "", "", "" });
    for (std.enums.values(RefId)) |_| try out.print(" {s:->8}", .{""});
    try out.print("  {s:->10} {s:->10} {s:->5}  {s:->10} {s:->10} {s:->5}", .{ "", "", "", "", "", "" });
    for (std.enums.values(RefId)) |id| {
        if (id == primary_ref) continue;
        try out.print(" {s:->6}", .{""});
    }
    try out.writeAll("\n");
}

fn reportRow(out: *Io.Writer, r: Result, floors: *const Floors, prev_cat: *[]const u8) !void {
    if (!std.mem.eql(u8, prev_cat.*, r.category)) {
        if (prev_cat.*.len > 0) try out.writeAll("\n");
        prev_cat.* = r.category;
    }
    var namebuf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&namebuf, "{s}/{s}", .{ r.category, r.name }) catch r.name;

    try out.print("{s:<34} ", .{label});

    if (r.zp_cpu) |ns| {
        try printDur(out, ns);
    } else {
        try out.print("{s:>12}", .{"skip"});
    }
    try out.writeAll(" ");

    if (r.zp_gpu) |ns| {
        try printDur(out, ns);
    } else {
        try out.print("{s:>12}", .{"skip"});
    }
    try out.writeAll(" ");

    for (std.enums.values(RefId)) |id| {
        const run = r.refs.get(id);
        if (run.time) |ns| {
            try printDur(out, ns);
        } else {
            try out.print("{s:>12}", .{if (run.skip.len > 0) "skip" else "-"});
        }
        try out.writeAll(" ");
    }

    const ng_ns = r.ng().time;
    const ng_floor = floors.refs.get(.ngspice);
    try printRatio(out, rawRatio(ng_ns, r.zp_cpu));
    try out.writeAll(" ");
    try printRatio(out, correctedRatio(ng_ns, ng_floor, r.zp_cpu, floors.zp_cpu));
    try out.writeAll(" ");
    try printRatio(out, rawRatio(ng_ns, r.zp_gpu));
    try out.writeAll(" ");
    try printRatio(out, correctedRatio(ng_ns, ng_floor, r.zp_gpu, floors.zp_gpu));
    try out.writeAll("  ");

    // memory columns
    if (r.zp_cpu_rss_kb > 0) {
        try out.print("{d:>7.1}", .{@as(f64, @floatFromInt(r.zp_cpu_rss_kb)) / 1024.0});
    } else {
        try out.print("{s:>8}", .{"-"});
    }
    try out.writeAll(" ");
    for (std.enums.values(RefId)) |id| {
        const rss = r.refs.get(id).rss_kb;
        if (rss > 0) {
            try out.print("{d:>7.1}", .{@as(f64, @floatFromInt(rss)) / 1024.0});
        } else {
            try out.print("{s:>8}", .{"-"});
        }
        try out.writeAll(" ");
    }
    try out.writeAll(" ");

    if (r.cpu_accuracy.get(primary_ref)) |acc| {
        try out.print("{e:>10.2} {e:>10.2} {s:>5}", .{
            acc.max_rel, acc.rms_rel, accuracyStatus(acc),
        });
    } else {
        try out.print("{s:>10} {s:>10} {s:>5}", .{ "-", "-", refAccuracyStatus(r, primary_ref) });
    }
    try out.writeAll("  ");

    if (r.gpu_accuracy) |acc| {
        try out.print("{e:>10.2} {e:>10.2} {s:>5}", .{
            acc.max_rel, acc.rms_rel, accuracyStatus(acc),
        });
    } else {
        try out.print("{s:>10} {s:>10} {s:>5}", .{ "-", "-", @as([]const u8, if (ng_ns != null and r.zp_gpu != null) "N/A" else "-") });
    }

    // espice-CPU against each NON-primary reference, condensed to a verdict:
    // the max/RMS pair is only worth a column for the reference the gate uses.
    for (std.enums.values(RefId)) |id| {
        if (id == primary_ref) continue;
        try out.print(" {s:>6}", .{refAccuracyStatus(r, id)});
    }
    try out.writeAll("\n");

    if (r.zp_cpu_skip.len > 0)
        try out.print("    zp-cpu: {s}\n", .{r.zp_cpu_skip});
    if (r.zp_gpu_skip.len > 0)
        try out.print("    zp-gpu: {s}\n", .{r.zp_gpu_skip});
    for (std.enums.values(RefId)) |id| {
        const run = r.refs.get(id);
        if (run.skip.len > 0) try out.print("    {s}: {s}\n", .{ ref_acc_label.get(id), run.skip });
    }
}

fn accuracyStatus(acc: Accuracy) []const u8 {
    return if (!acc.complete) "N/A" else if (acc.pass) "PASS" else "FAIL";
}

/// espice-CPU vs one reference. "SKIP" means the reference never ran this
/// fixture, "N/A" means it ran but its output could not be compared — never
/// silently blank, so an unvalidated column cannot read as a passing one.
fn refAccuracyStatus(r: Result, id: RefId) []const u8 {
    if (r.cpu_accuracy.get(id)) |acc| return accuracyStatus(acc);
    if (r.zp_cpu == null) return "-";
    // Skip first: a reference can TIME a fixture and still have nothing to
    // compare (exit 0, no raw written), and that is a skip with a reason, not
    // an unexplained N/A.
    if (r.refs.get(id).skip.len > 0) return "SKIP";
    if (r.refs.get(id).time == null) return "-";
    return "N/A";
}

fn reportFooter(out: *Io.Writer, s: Summary, closing: Summary) !void {
    try out.writeAll(
        \\
        \\ratio = ngspice / espice (higher = espice faster). Timings are MIN of N.
        \\cpu/ng, gpu/ng = raw wall clock. cpu/ng*, gpu/ng* = both sides' process
        \\floor subtracted first; blank where what remains is inside the floor's noise.
        \\accuracy: per-variable RMS/max error normalized by max(peak, span, 1).
        \\ng/xy/vc columns are espice-CPU vs that reference; PASS/FAIL/N/A/SKIP.
        \\N/A = unvalidated (missing signals, mismatched point counts, or an unmatched plot).
        \\SKIP = the reference did not run this fixture (see the per-row reason).
        \\GPU timings exclude reported CPU fallback, including work below the offload threshold.
        \\
        \\
    );
    try out.print("espice vs ngspice, {d} ranked decks:\n", .{s.raw_ranked});
    try out.print("  raw wall clock   {d:>4} faster, geomean {d:.2}x, mean {d:.2}x\n", .{
        s.raw_wins, Summary.geo(s.raw_ranked, s.raw_log_sum), Summary.mean(s.raw_ranked, s.raw_sum),
    });
    try out.print("  floor-corrected  {d:>4} faster of {d} rankable, geomean {d:.2}x, mean {d:.2}x\n", .{
        s.corr_wins, s.corr_ranked, Summary.geo(s.corr_ranked, s.corr_log_sum), Summary.mean(s.corr_ranked, s.corr_sum),
    });
    try out.print("  {d} decks too small to rank after floor subtraction; {d} flip winner between min-of-N and median-of-N.\n", .{
        s.below_floor, s.p50_flips,
    });
    try out.print("  same decks against the CLOSING floor: {d} faster of {d}, geomean {d:.2}x  <- the error bar\n", .{
        closing.corr_wins, closing.corr_ranked, Summary.geo(closing.corr_ranked, closing.corr_log_sum),
    });
}

/// `-` where a corrected ratio exists but was refused: the deck is too small
/// for the floor subtraction to leave anything above the floors' own noise.
/// A blank is honest there; a number would not be.
fn printRatio(out: *Io.Writer, ratio: ?f64) !void {
    if (ratio) |v| try out.print("{d:>6.1}x", .{v}) else try out.print("{s:>7}", .{"-"});
}

/// Minimum of N, not median. See `Timing`.
fn printDur(out: *Io.Writer, t: Timing) !void {
    const ns = t.min_ns;
    const f = @as(f64, @floatFromInt(ns));
    if (ns < 1_000_000) {
        try out.print("{d:>9.1} us", .{f / 1e3});
    } else if (ns < 1_000_000_000) {
        try out.print("{d:>9.2} ms", .{f / 1e6});
    } else {
        try out.print("{d:>9.3} s ", .{f / 1e9});
    }
}

/// One markdown cell, printed straight out — the old version built every cell
/// into its own stack buffer first, which does not survive adding references.
fn mdDur(w: *Io.Writer, t: ?Timing) !void {
    var buf: [32]u8 = undefined;
    try w.print(" {s} |", .{if (t) |v| fmtDur(&buf, v.min_ns) else "skip"});
}

fn mdRatio(w: *Io.Writer, ratio: ?f64) !void {
    if (ratio) |v| try w.print(" {d:.1}x |", .{v}) else try w.writeAll(" - |");
}

fn mdMb(w: *Io.Writer, kb: u64) !void {
    if (kb == 0) return w.writeAll(" - |");
    try w.print(" {d:.1} |", .{@as(f64, @floatFromInt(kb)) / 1024.0});
}

fn mdAccuracy(w: *Io.Writer, acc: ?Accuracy, status: []const u8) !void {
    if (acc) |a| {
        try w.print(" {e:.2} | {e:.2} | {s} |", .{ a.max_rel, a.rms_rel, accuracyStatus(a) });
    } else {
        try w.print(" - | - | {s} |", .{status});
    }
}

fn writeResultsMd(
    io: Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    results: []const Result,
    rtol: f64,
    refs: *const std.enums.EnumArray(RefId, Ref),
    floors: *const Floors,
    closing: *const Floors,
) void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    writeResultsBody(w, results, rtol, refs, floors, closing) catch return;

    const text = aw.toOwnedSlice() catch return;
    const file = Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer file.close(io);
    var fbuf: [4096]u8 = undefined;
    var fw = file.writer(io, &fbuf);
    fw.interface.writeAll(text) catch {};
    fw.interface.flush() catch {};
}

/// The speed claim, stated twice with its method attached, because the two
/// numbers differ by more than anyone would guess and only one of them is about
/// the simulator.
///
/// `cpu/ng` is wall clock over wall clock, which is what a user feels and what
/// this file has always printed. `cpu/ng*` subtracts each binary's own measured
/// process floor from both sides first. ngspice is dynamically linked and pays a
/// fixed ~10.2M instructions of `do_lookup_x`/`_dl_relocate_object` before main;
/// espice is statically linked and pays ~0.87M. On a 4 ms deck that gap is the
/// entire reported speedup, and a raw ratio there measures ld.so.
///
/// Neither column is the "real" one. The raw column overstates the SIMULATOR and
/// the corrected column understates the PROGRAM. Quote whichever question is
/// being asked, and say which.
fn writeHeadline(
    w: *Io.Writer,
    s: Summary,
    closing: Summary,
    floors: *const Floors,
    closing_floors: *const Floors,
    refs: *const std.enums.EnumArray(RefId, Ref),
) !void {
    try w.writeAll("## Speed headline\n\n| statistic | raw wall clock | floor-corrected |\n|---|---|---|\n");
    try w.print("| decks ranked | {d} | {d} |\n", .{ s.raw_ranked, s.corr_ranked });
    try w.print("| espice faster | {d} | {d} |\n", .{ s.raw_wins, s.corr_wins });
    try w.print("| geometric mean | {d:.2}x | {d:.2}x |\n", .{
        Summary.geo(s.raw_ranked, s.raw_log_sum), Summary.geo(s.corr_ranked, s.corr_log_sum),
    });
    try w.print("| arithmetic mean | {d:.2}x | {d:.2}x |\n\n", .{
        Summary.mean(s.raw_ranked, s.raw_sum), Summary.mean(s.corr_ranked, s.corr_sum),
    });
    try w.print(
        \\{d} of the {d} ranked decks have no corrected ratio: after subtracting both
        \\process floors, what is left is smaller than the floor measurement's own
        \\min-to-median spread, so any ordering of the two engines there is a
        \\measurement of the scheduler. They are blank, not ranked. Timings are
        \\**minimum of N**, not median — see the note below.
        \\
        \\
    , .{ s.below_floor, s.raw_ranked });
    try w.print(
        \\{d} decks change winner between min-of-N and median-of-N on the raw ratio.
        \\That is the size of the effect that put seven false "espice is slower" rows
        \\into `docs/perf/baseline-446268a.md`: the minimum is the sample least
        \\contaminated by other load, the median is whatever the box was doing.
        \\
        \\
    , .{s.p50_flips});

    try w.print(
        \\### Uncertainty
        \\
        \\The floor was measured twice on the same deck with the same statistic:
        \\once before the sweep (used for every `*` column above) and once after it.
        \\Re-deriving the corrected headline against the CLOSING floor gives
        \\**{d:.2}x over {d} decks** against **{d:.2}x over {d}**. That spread is the
        \\error bar on the corrected number, and it is not small: a wall-clock floor
        \\on a shared machine is a measurement, not a constant.
        \\
        \\
    , .{
        Summary.geo(closing.corr_ranked, closing.corr_log_sum), closing.corr_ranked,
        Summary.geo(s.corr_ranked, s.corr_log_sum),             s.corr_ranked,
    });

    try w.writeAll("Measured process floor (two devices, one `.op`), subtracted from every `*` column:\n\n");
    try w.writeAll("| binary | opening min | opening median | closing min | closing median |\n|---|---|---|---|---|\n");
    try mdFloor(w, "zp-cpu", floors.zp_cpu, closing_floors.zp_cpu);
    try mdFloor(w, "zp-gpu", floors.zp_gpu, closing_floors.zp_gpu);
    for (std.enums.values(RefId)) |id| {
        if (!refs.get(id).on()) continue;
        try mdFloor(w, refs.get(id).label, floors.refs.get(id), closing_floors.refs.get(id));
    }
    try w.writeAll(
        \\
        \\The floor is wall clock, so it carries fork/exec, page-in and the runner's
        \\own `timeout` wrapper as well as the simulator's startup — and it carries
        \\them on BOTH sides, including the pipe-drain the runner puts on espice and
        \\not on the references. Everything constant per process therefore cancels in
        \\the subtraction, which is the point.
        \\
        \\
    );
}

fn mdFloor(w: *Io.Writer, label: []const u8, open: ?Timing, close: ?Timing) !void {
    var buf: [4][32]u8 = undefined;
    const cells: [4][]const u8 = .{
        if (open) |v| fmtDur(&buf[0], v.min_ns) else "-",
        if (open) |v| fmtDur(&buf[1], v.p50_ns) else "-",
        if (close) |v| fmtDur(&buf[2], v.min_ns) else "-",
        if (close) |v| fmtDur(&buf[3], v.p50_ns) else "-",
    };
    try w.print("| {s} | {s} | {s} | {s} | {s} |\n", .{ label, cells[0], cells[1], cells[2], cells[3] });
}

fn writeResultsBody(
    w: *Io.Writer,
    results: []const Result,
    rtol: f64,
    refs: *const std.enums.EnumArray(RefId, Ref),
    floors: *const Floors,
    closing: *const Floors,
) !void {
    try w.writeAll("# Benchmark results — espice vs ngspice, Xyce and VACASK\n\n");
    try writeHeadline(w, summarize(results, floors), summarize(results, closing), floors, closing, refs);

    // Which binary produced each column, verbatim. Ratios against an unnamed
    // "ngspice" are not reproducible — two 44.2 builds on the dev host differ
    // by 8.5% in instruction count on scaling/parallel_inverters_100.
    try w.writeAll("## Reference simulators\n\n| column | version | binary |\n|---|---|---|\n");
    for (std.enums.values(RefId)) |id| {
        const ref = refs.get(id);
        if (ref.on()) {
            try w.print("| {s} | {s} | `{s}` |\n", .{ ref.label, ref.version, ref.bin });
        } else {
            try w.print("| {s} | _disabled_ | - |\n", .{ref.label});
        }
    }
    try w.writeAll(
        \\
        \\ngspice runs its DEFAULT solver unless `--ngspice-klu` is passed. That is
        \\deliberate and measured: KLU is slower on every deck in this suite
        \\(parallel_inverters_100 513M -> 555M Ir, mos6_inverter 149M -> 163M,
        \\rc_ladder_10k 2.60G -> 3.98G). KLU's ordering and BTF analysis pay off at
        \\1e5+ unknowns, not on a 105x105 matrix, so the default is ngspice's
        \\STRONGEST configuration here and the reference is not a strawman.
        \\
        \\
    );

    try w.print("Pass: per-variable RMS ≤ {e:.0}, max ≤ {e:.0}; error normalized by max(peak, span, 1).\n", .{ rtol, 10 * rtol });
    try w.writeAll(
        \\N/A: unvalidated (missing signals, mismatched point counts, or a reference plot with no counterpart).
        \\SKIP: that reference did not run the fixture (VACASK only runs where a `vacask.sim` deck exists).
        \\GPU timings exclude reported CPU fallback.
        \\
        \\Every timing column is the **minimum** of N repeats, not the median.
        \\`cpu/ng` and `gpu/ng` are raw wall clock; `cpu/ng*` and `gpu/ng*` subtract
        \\each binary's own process floor from both sides first, and are blank where
        \\what remains is inside the floor's own noise.
        \\
        \\
    );

    try w.writeAll("| fixture | zp-cpu | zp-gpu |");
    for (std.enums.values(RefId)) |id| try w.print(" {s} |", .{refs.get(id).label});
    try w.writeAll(" cpu/ng | cpu/ng* | gpu/ng | gpu/ng* | zp-MB |");
    for (std.enums.values(RefId)) |id| try w.print(" {s} |", .{ref_mb_label.get(id)});
    try w.writeAll(" cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu |");
    // The non-primary references carry their max/RMS here and only a verdict on
    // the terminal table. Adjudicating a disagreement needs the numbers: "espice
    // FAILs ngspice at 4.8e-3 and matches Xyce at 2e-16" is a finding, "FAIL
    // PASS" is a puzzle.
    for (std.enums.values(RefId)) |id| {
        if (id == primary_ref) continue;
        try w.print(" {s}-max | {s}-rms | {s} |", .{ ref_acc_label.get(id), ref_acc_label.get(id), ref_acc_label.get(id) });
    }
    try w.writeAll("\n|---|---|---|");
    for (std.enums.values(RefId)) |_| try w.writeAll("---|");
    try w.writeAll("---|---|---|---|---|");
    for (std.enums.values(RefId)) |_| try w.writeAll("---|");
    try w.writeAll("---|---|---|---|---|---|");
    for (std.enums.values(RefId)) |id| {
        if (id == primary_ref) continue;
        try w.writeAll("---|---|---|");
    }
    try w.writeAll("\n");

    for (results) |r| {
        try w.print("| {s}/{s} |", .{ r.category, r.name });
        try mdDur(w, r.zp_cpu);
        try mdDur(w, r.zp_gpu);
        for (std.enums.values(RefId)) |id| try mdDur(w, r.refs.get(id).time);
        const ng_floor = floors.refs.get(.ngspice);
        try mdRatio(w, rawRatio(r.ng().time, r.zp_cpu));
        try mdRatio(w, correctedRatio(r.ng().time, ng_floor, r.zp_cpu, floors.zp_cpu));
        try mdRatio(w, rawRatio(r.ng().time, r.zp_gpu));
        try mdRatio(w, correctedRatio(r.ng().time, ng_floor, r.zp_gpu, floors.zp_gpu));
        try mdMb(w, r.zp_cpu_rss_kb);
        for (std.enums.values(RefId)) |id| try mdMb(w, r.refs.get(id).rss_kb);
        try mdAccuracy(w, r.cpu_accuracy.get(primary_ref), refAccuracyStatus(r, primary_ref));
        const gpu_status: []const u8 = if (r.zp_gpu_skip.len > 0) "SKIP" else if (r.ng().time != null and r.zp_gpu != null) "N/A" else "-";
        try mdAccuracy(w, r.gpu_accuracy, gpu_status);
        for (std.enums.values(RefId)) |id| {
            if (id == primary_ref) continue;
            try mdAccuracy(w, r.cpu_accuracy.get(id), refAccuracyStatus(r, id));
        }
        try w.writeAll("\n");
    }
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
    const usage =
        \\usage: bench-runner ESPICE_BIN FIXTURES_DIR [--iters N] [--filter CAT[/NAME]]
        \\       [--ngspice PATH] [--xyce PATH] [--vacask PATH] [--ngspice-klu]
        \\       [--no-ngspice] [--no-xyce] [--no-vacask]
        \\       [--timeout S] [--list] [--out PATH] [--rtol N]
        \\
    ;
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
        } else if (std.mem.eql(u8, arg, "--ngspice-klu")) {
            cfg.ngspice_klu = true;
        } else if (refFlag(arg, "--")) |id| {
            cfg.bins.set(id, it.next() orelse return error.BadUsage);
        } else if (refFlag(arg, "--no-")) |id| {
            cfg.use.set(id, false);
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

/// `--ngspice`/`--xyce`/`--vacask` and their `--no-` twins, matched off the
/// enum so a new reference needs no new flag-parsing branch.
fn refFlag(arg: []const u8, prefix: []const u8) ?RefId {
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    return std.meta.stringToEnum(RefId, arg[prefix.len..]);
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

// Run with: zig test benchmark/src/runner.zig
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
    try std.testing.expectEqualStrings("N/A", accuracyStatus(partial));
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
    // Get this wrong and Xyce/VACASK match zero columns, then report a vacuous
    // N/A that reads like "validated".
    inline for (.{
        .{ "v(out)", "v(out)" }, // ngspice / espice
        .{ "i(vin)", "i(vin)" },
        .{ "out", "v(out)" }, // Xyce named node
        .{ "v(1)", "v(1)" }, // Xyce numeric node
        .{ "vin#branch", "i(vin)" }, // Xyce branch current
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
        "v(d1_internal)", "v(q1_baseprime)", "v(t1_int2)", "v(m1_body)", // Xyce
        "i(ymil!k1_l1)", // Xyce's synthesised mutual-inductor device
    }) |internal| try std.testing.expect(isInternalNode(internal));
    // A deck node is not internal just because a model node could share a
    // prefix or a suffix with it.
    inline for (.{ "v(out)", "i(v1)", "v(internal)", "v(d1_internals)", "v(_body)", "v(i2)" }) |named|
        try std.testing.expect(!isInternalNode(named));
}

test "Xyce spells `.op` as a one-point DC sweep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Exactly what Xyce writes for `Vin in 0 DC 10 / R1 in out 5k / R2 out 0 5k`
    // under `.op`: a plot it calls a DC transfer characteristic, carrying a
    // `sweep` scale that an operating point has no counterpart for. Before the
    // alias and the plot class this pair was N/A on both counts while agreeing
    // to the last bit.
    const xyce: Plot = .{
        .plotname = "DC transfer characteristic",
        .varnames = &.{ normalizeVarName(a, "sweep"), normalizeVarName(a, "in"), normalizeVarName(a, "out"), normalizeVarName(a, "vin#branch") },
        .is_complex = false,
        .npoints = 1,
        .nvars = 4,
        .data = &.{ 0, 10, 5, -1e-3 },
    };
    const espice: Plot = .{
        .plotname = "Operating Point",
        .varnames = &.{ "i(vin)", "v(in)", "v(out)" },
        .is_complex = false,
        .npoints = 1,
        .nvars = 3,
        .data = &.{ -1e-3, 10, 5 },
    };
    const acc = comparePlots(a, xyce, espice, 1e-3).?;
    try std.testing.expect(acc.complete and acc.pass);
    // A dropped scale cannot BE the match: same plot with only the scale in
    // common has no signal to compare and must stay unvalidated.
    var scale_only = espice;
    scale_only.varnames = &.{"v(v-sweep)"};
    scale_only.nvars = 1;
    scale_only.data = &.{0};
    try std.testing.expect(comparePlots(a, xyce, scale_only, 1e-3) == null);
    // The class collapses `.op` spellings only. Transient vs DC is still a
    // refusal, not a comparison.
    var tran = espice;
    tran.plotname = "Transient Analysis";
    try std.testing.expect(comparePlots(a, xyce, tran, 1e-3) == null);
}

test "the Xyce deck rewrite respells, and leaves the circuit alone" {
    // ngspice's ` $` comment, its `.print`/`.plot`/`.width` output control and
    // its `dc=` source field are the three things Xyce will not read. Nothing
    // else may move.
    try std.testing.expectEqualStrings("Vin in 0 DC 0 AC 1 ", stripInlineComment("Vin in 0 DC 0 AC 1 $ small-signal stimulus"));
    try std.testing.expectEqualStrings("", stripInlineComment("$ whole-line comment"));
    try std.testing.expectEqualStrings("R1 n$1 0 1k", stripInlineComment("R1 n$1 0 1k"));
    try std.testing.expect(isDroppedCard(".PRINT TRAN V(2)"));
    try std.testing.expect(isDroppedCard("  .plot dc v(out)"));
    try std.testing.expect(isDroppedCard(".width out=80"));
    try std.testing.expect(!isDroppedCard(".tran 1n 10n"));
    try std.testing.expect(!isDroppedCard("Rprint 1 0 1k"));
    try std.testing.expect(!isDroppedCard(".averyverylongdotcardname 1"));
}

test "KLU is a deck rewrite, and an already-KLU deck is left alone" {
    // ngspice has no --klu flag, so the runner must SEE the card to avoid
    // duplicating it. The five fixtures imported from VACASK's benchmark suite
    // already carry one, which is also why their DEFAULT ngspice column has
    // been running KLU all along.
    try std.testing.expect(deckHasKlu("* title\n.options klu\n.end\n"));
    try std.testing.expect(deckHasKlu("* t\n.OPTIONS KLU method=gear maxord=2\n"));
    try std.testing.expect(deckHasKlu("* t\n  .option  reltol=1e-3  klu\n"));
    try std.testing.expect(!deckHasKlu("* t\n.options reltol=1e-3\n.end\n"));
    // "klu" inside a name or on a non-options card is not the solver.
    try std.testing.expect(!deckHasKlu("* t\nrklu 1 2 1k\n"));
    try std.testing.expect(!deckHasKlu("* klu is great\n.tran 1u 1m\n"));
}

test "reference flags come off the enum, not a hand-written list" {
    try std.testing.expectEqual(RefId.ngspice, refFlag("--ngspice", "--").?);
    try std.testing.expectEqual(RefId.vacask, refFlag("--vacask", "--").?);
    try std.testing.expectEqual(RefId.xyce, refFlag("--no-xyce", "--no-").?);
    try std.testing.expect(refFlag("--no-xyce", "--") == null);
    try std.testing.expect(refFlag("--iters", "--") == null);
    // --ngspice-klu is its own flag and must NOT read as a binary override.
    try std.testing.expect(refFlag("--ngspice-klu", "--") == null);

    // ngspice opens its banner with a row of '*' that names nothing.
    try std.testing.expectEqualStrings(
        "ngspice-44.2 : Circuit level simulation program",
        firstBannerLine("******\n** ngspice-44.2 : Circuit level simulation program\n"),
    );
    try std.testing.expectEqualStrings("Xyce Release 7.10.0-opensource", firstBannerLine("Xyce Release 7.10.0-opensource\n"));
    try std.testing.expectEqualStrings("", firstBannerLine(""));
}

test "a reference that refuses a deck says why" {
    // Verbatim Xyce and ngspice output. The point of the whole exercise: a row
    // that reads `skip` with no reason is indistinguishable from a row nobody
    // ever tried, which is how Xyce stayed absent from this suite.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ngspice writes the diagnostic to STDERR and the offending card to the
    // line after it; either half alone names nothing useful.
    try std.testing.expectEqualStrings(
        "Error on line 5 or its substitute: .pz",
        refSkipReason(a, .{ .ok = false, .text = "", .stderr = "\n\nError on line 5 or its substitute:\n  .pz\n" }),
    );
    try std.testing.expectEqualStrings(
        "Netlist error: No analysis specified.",
        refSkipReason(a, .{ .ok = false, .stderr = "", .text = "***** Reading and parsing netlist...\n Unrecognized dot line will be ignored\nNetlist error: No analysis specified.\n" }),
    );
    try std.testing.expectEqualStrings(
        "Model is required for device Q1 and no valid model card found.",
        refSkipReason(a, .{ .ok = false, .stderr = "", .text = "Netlist warning: No print specified\n Model is required for device Q1 and no valid model card found.\nNetlist error: bad\n" }),
    );
    try std.testing.expectEqualStrings(
        "Time step too small near step number: 71  Exiting transient loop.",
        refSkipReason(a, .{ .ok = false, .stderr = "", .text = "***** Beginning Transient Calculation...\nTime step too small near step number: 71  Exiting transient loop.\n" }),
    );
    try std.testing.expectEqualStrings("preflight failed", refSkipReason(a, .{ .ok = false, .stderr = "", .text = "***** Xyce ran fine\n" }));
}

test "an unrun reference reads as SKIP, never as blank" {
    var r: Result = .{ .category = "tran", .name = "rc_pulse", .zp_cpu = .{ .min_ns = 1000, .p50_ns = 1000 } };
    // Never ran this fixture -> SKIP, with the reason printed under the row.
    r.refs.set(.vacask, .{ .skip = "no native vacask/ deck" });
    try std.testing.expectEqualStrings("SKIP", refAccuracyStatus(r, .vacask));
    // Ran, but its output could not be compared -> N/A, not a pass.
    r.refs.set(.xyce, .{ .time = .{ .min_ns = 2000, .p50_ns = 2000 } });
    try std.testing.expectEqualStrings("N/A", refAccuracyStatus(r, .xyce));
    r.cpu_accuracy.set(.xyce, .{ .max_rel = 0, .rms_rel = 0, .pass = true });
    try std.testing.expectEqualStrings("PASS", refAccuracyStatus(r, .xyce));
    // espice itself did not run, so no comparison was even attempted. An
    // accuracy value cannot coexist with this, since it is only computed when
    // espice produced a raw.
    r.zp_cpu = null;
    r.cpu_accuracy.set(.xyce, null);
    try std.testing.expectEqualStrings("-", refAccuracyStatus(r, .xyce));
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
    try std.testing.expectEqualStrings("N/A", accuracyStatus(gap));
    // One bad plot out of two loses the whole fixture: worst pair wins.
    var wrong_op = op;
    wrong_op.data = &.{9};
    try std.testing.expect(!compareRaws(a, &.{ ac, op }, &.{ wrong_op, ac }, 1e-3).?.pass);
    // Nothing comparable at all is null, so the row reads N/A rather than PASS.
    try std.testing.expect(compareRaws(a, &.{ac}, &.{op}, 1e-3) == null);
}

test "the process floor is subtracted from both sides, and small decks go unranked" {
    const ms = 1_000_000;
    const ng_floor: Timing = .{ .min_ns = 10 * ms, .p50_ns = 10 * ms + ms / 10 };
    const zp_floor: Timing = .{ .min_ns = 1 * ms, .p50_ns = 1 * ms + ms / 20 };
    // 20 ms vs 5 ms reads as 4.0x raw. Ten of ngspice's twenty milliseconds are
    // ld.so, one of espice's five is its own startup: the simulators are 2.5x
    // apart, not 4x.
    const ng: Timing = .{ .min_ns = 20 * ms, .p50_ns = 21 * ms };
    const zp: Timing = .{ .min_ns = 5 * ms, .p50_ns = 5 * ms + ms / 5 };
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), rawRatio(ng, zp).?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), correctedRatio(ng, ng_floor, zp, zp_floor).?, 1e-9);
    // A deck whose work, after both floors come off, is inside the floor's own
    // min-to-median spread is not ranked at all. It still has a raw ratio, and
    // that raw ratio is 10.05/1.04 = 9.7x of pure process startup.
    const tiny_ng: Timing = .{ .min_ns = 10 * ms + ms / 20, .p50_ns = 11 * ms };
    const tiny_zp: Timing = .{ .min_ns = 1 * ms + ms / 25, .p50_ns = 1 * ms + ms / 10 };
    try std.testing.expect(rawRatio(tiny_ng, tiny_zp).? > 9.0);
    try std.testing.expect(correctedRatio(tiny_ng, ng_floor, tiny_zp, zp_floor) == null);
    // No floor measured for a column -> no corrected ratio for it, rather than
    // an uncorrected one wearing the corrected column's label.
    try std.testing.expect(correctedRatio(ng, null, zp, zp_floor) == null);
    try std.testing.expect(correctedRatio(ng, ng_floor, zp, null) == null);
}

test "the headline is a geometric mean, and counts what it could not rank" {
    var results: [3]Result = .{
        .{ .category = "t", .name = "fast" },
        .{ .category = "t", .name = "slow" },
        .{ .category = "t", .name = "tiny" },
    };
    const ms = 1_000_000;
    var floors: Floors = .{ .zp_cpu = .{ .min_ns = ms, .p50_ns = ms + ms / 20 } };
    floors.refs.set(.ngspice, .{ .min_ns = 10 * ms, .p50_ns = 10 * ms + ms / 10 });

    // 4x raw / 2.5x corrected.
    results[0].zp_cpu = .{ .min_ns = 5 * ms, .p50_ns = 5 * ms };
    results[0].refs.set(.ngspice, .{ .time = .{ .min_ns = 20 * ms, .p50_ns = 20 * ms } });
    // 0.75x raw, 0.26x corrected — and it FLIPS to a win on median-of-N, which
    // is the shape of the seven false regressions in `baseline-446268a.md`.
    results[1].zp_cpu = .{ .min_ns = 20 * ms, .p50_ns = 20 * ms };
    results[1].refs.set(.ngspice, .{ .time = .{ .min_ns = 15 * ms, .p50_ns = 30 * ms } });
    // Below the floor: raw-ranked, not corrected-ranked.
    results[2].zp_cpu = .{ .min_ns = ms + ms / 25, .p50_ns = ms + ms / 10 };
    results[2].refs.set(.ngspice, .{ .time = .{ .min_ns = 10 * ms + ms / 20, .p50_ns = 11 * ms } });

    const s = summarize(&results, &floors);
    try std.testing.expectEqual(@as(usize, 3), s.raw_ranked);
    try std.testing.expectEqual(@as(usize, 2), s.raw_wins);
    try std.testing.expectEqual(@as(usize, 2), s.corr_ranked);
    try std.testing.expectEqual(@as(usize, 1), s.corr_wins);
    try std.testing.expectEqual(@as(usize, 1), s.below_floor);
    // A deck won 4x and a deck lost 4x is parity, not a 2.1x win: geometric.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), Summary.geo(2, @log(4.0) + @log(0.25)), 1e-12);
    // Deck 1 is espice-slower on min-of-N and espice-faster on median-of-N.
    try std.testing.expectEqual(@as(usize, 1), s.p50_flips);
}

test "GPU fallback diagnostics cannot become GPU timings" {
    // VERBATIM from src/engine.zig `prepare` and src/gpu_context.zig, because a
    // paraphrase is what let this test stay green while the matcher was dead:
    // the first two lines used to read `--gpu declined` / `--gpu unavailable`,
    // the engine stopped printing that, and only this test still believed it.
    inline for (.{
        "note: auto declined the GPU; too little device work to beat the PCIe " ++
            "round trip (override with --gpu, or tune ESPICE_GPU_MIN_WORK)",
        "warning: GPU declined (CircuitNotEligible); nothing in this circuit has " ++
            "a device kernel — running on the CPU",
        "warning: GPU unavailable (NoGpuArtifacts); running on the CPU",
        "Error: GPU requested but unavailable (NoGpuArtifacts); detected artifacts: none",
        "warning: GPU device eval failed (LaunchFailed); falling back to the CPU stamp",
        "warning: GPU limit/state pass failed; falling back to the CPU walk",
    }) |diagnostic| try std.testing.expect(gpuSkipReason(diagnostic) != null);
    // A batch demotion is not a whole-run refusal: the rest of the circuit still
    // runs on the device, so the timing stands.
    try std.testing.expect(gpuSkipReason(
        "note: GPU batch 'bsim4va' (12 instances) stays on the CPU: no cuda kernel image in this build\n",
    ) == null);
    try std.testing.expect(gpuSkipReason("gpu-stats: eligible batches=2 nonlinear work=4096000 (gate 3200000)\n") == null);
    try std.testing.expect(gpuSkipReason("--- Simulation Summary ---\nDevices: 4000\n") == null);
}

test "timing discards large external output and preserves espice diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    _ = try timed(io, a, .{ .argv = &.{ "head", "-c", "2097152", "/dev/zero" } }, "5", 1, .quiet);
    try std.testing.expectError(error.BenchRunFailed, timed(io, a, .{ .argv = &.{ "sh", "-c", "printf '%s' '{\"skip\":\"test\"}'" } }, "5", 1, .cpu));
    // Verbatim `gpu_context.evalPlanes`, for the same reason as the matcher's
    // own test: a paraphrased fixture is what let the old needles rot unnoticed.
    try std.testing.expectError(error.GpuFallback, timed(io, a, .{ .argv = &.{ "sh", "-c", "printf '%s' 'warning: GPU device eval failed (LaunchFailed); falling back to the CPU stamp' >&2" } }, "5", 1, .gpu));
}

test "a repeat that fails only AFTER the preflight is BenchRunFailed, not a dead run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    // The shape that used to kill the whole benchmark: a fixture preflights
    // clean, then one repeat out of `iters` dies. Every call site maps
    // BenchRunFailed onto a per-fixture skip, so this error VALUE is what keeps
    // 280 fixtures' worth of results from being thrown away by one flake.
    // The load-induced cause is the timeout kill, so test that spelling too.
    try std.testing.expectError(error.BenchRunFailed, timed(io, a, .{ .argv = &.{ "sh", "-c", "exit 1" } }, "5", 3, .quiet));
    try std.testing.expectError(error.BenchRunFailed, timed(io, a, .{ .argv = &.{ "sh", "-c", "sleep 5" } }, "1", 1, .quiet));
    try std.testing.expectError(error.BenchRunFailed, timed(io, a, .{ .argv = &.{ "sh", "-c", "sleep 5" } }, "1", 1, .cpu));
}
