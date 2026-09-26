//! Analysis cards and deck options to resolved queries. Node references
//! arrive as circuit rows; source and card names resolve against the
//! construction bindings, which outlive the parse.
const std = @import("std");
const core = @import("core");
const Library = @import("device").Library;
const requests = @import("core").query;
const numerics = @import("core").numerics;
const netlist = @import("netlist");
const Value = netlist.Value;
const Job = requests.Query;
const GROUND = core.GROUND;
/// Unresolved or absent node row.
pub const NO_NODE = netlist.none;
/// Nodes a deck's output `v(...)` may name; appended cards take one.
pub const deck_output_nodes = 2;

/// Queries for `cards` (nets already circuit rows), in card order, allocated
/// in `arena`. `.noise` also yields its integrated plot, `.disto` its two
/// harmonic vectors; a single-value `.temp` yields none. `max_group_args` is
/// how many nodes an output `v(...)` may name.
pub fn queries(arena: std.mem.Allocator, cards: []const netlist.Analysis, max_group_args: usize, sources: core.QueryBindings, card_refs: []const requests.CardRef, deck_opts: DeckOptions) ![]const Job {
    for (cards) |c| {
        const args = c.args;
        const arg: usize = if (c.kind == .four) 1 else 0;
        if (arg < args.len) switch (args[arg]) {
            .group => |g| if (g.args.len > max_group_args or (max_group_args == 1 and g.args.len == 0))
                return error.UnsupportedAnalysisOutput,
            else => {},
        };
    }
    // Fan-out ceiling: `.disto` is the widest card at three plots per line.
    const jobs = try arena.alloc(Job, cards.len * 3);
    var n: usize = 0;
    for (cards) |c| {
        var job = (try buildJob(c, sources, card_refs)) orelse continue;
        applyDeckOptions(&job, deck_opts);
        jobs[n] = job;
        n += 1;
        // The "Integrated Noise" plot always exists; a degenerate band
        // integrates to zero and ngspice still prints the row.
        if (job == .noise) {
            job.noise.integrated = true;
            jobs[n] = job;
            n += 1;
        }
        // ngspice's `.disto` output is the pair of complex harmonic vectors.
        if (job == .disto) {
            inline for (.{ .second, .third }) |harmonic| {
                job.disto.plot = harmonic;
                jobs[n] = job;
                n += 1;
            }
        }
    }
    return jobs[0..n];
}

/// Parsed `.options` overrides, in deck order: a later card wins.
pub const DeckOptions = struct {
    tol: numerics.Tolerances = .{},
    /// `.options method`; null keeps each query's default.
    method: ?requests.Method = null,
    /// `.temp` or `.options temp` in degrees Celsius; null when not given.
    temp_c: ?f64 = null,
    /// `.options tnom=<degC>`: the temperature model cards were extracted at
    /// (ngspice cktsopt.c:71-73 takes the card in Celsius; default 27 degC
    /// from cktntask.c:127). Unlike `temp`, where the circuit runs, it reaches
    /// the devices at build time, so no sweep can move it.
    tnom_c: f64 = 27.0,
};

/// Folds the deck's `.options` and `.temp` cards; `InvalidAnalysisArguments`
/// on a value out of range.
pub fn deckOptions(config: []const netlist.Config) !DeckOptions {
    const Option = enum(u8) { method, reltol, abstol, vntol, gmin, trtol, chgtol, itl1, itl2, itl4, maxord, temp, tnom };
    const names = std.StaticStringMap(Option).initComptime(.{
        .{ "method", .method }, .{ "reltol", .reltol }, .{ "abstol", .abstol },
        .{ "vntol", .vntol },   .{ "gmin", .gmin },     .{ "trtol", .trtol },
        .{ "chgtol", .chgtol }, .{ "itl1", .itl1 },     .{ "itl2", .itl2 },
        .{ "itl4", .itl4 },     .{ "maxord", .maxord }, .{ "temp", .temp },
        .{ "tnom", .tnom },
    });
    const methods = std.StaticStringMap(requests.Method).initComptime(.{
        .{ "gear", .gear_2 }, .{ "trap", .trapezoidal }, .{ "trapezoidal", .trapezoidal },
    });
    var o: DeckOptions = .{};
    var maxord: ?f64 = null;
    for (config) |card| {
        const args = card.args;
        if (card.temp) {
            o.temp_c = try number(args, 0);
            if (o.temp_c.? <= -273.15) return error.InvalidAnalysisArguments;
            continue;
        }
        var lower: [16]u8 = undefined;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const key = nameAt(args, i) orelse continue;
            if (key.len > lower.len) continue;
            const option = names.get(std.ascii.lowerString(lower[0..key.len], key)) orelse continue;
            i += 1;
            if (option == .method) {
                const method = nameAt(args, i) orelse return error.InvalidAnalysisArguments;
                if (method.len > lower.len) return error.InvalidAnalysisArguments;
                o.method = methods.get(std.ascii.lowerString(lower[0..method.len], method)) orelse return error.InvalidAnalysisArguments;
                continue;
            }
            const value = try number(args, i);
            switch (option) {
                .method => unreachable,
                .temp, .tnom => {
                    if (value <= -273.15) return error.InvalidAnalysisArguments;
                    if (option == .temp) o.temp_c = value else o.tnom_c = value;
                },
                .itl1, .itl2, .itl4 => {
                    if (value < 1 or value != @trunc(value) or value > std.math.maxInt(u16)) return error.InvalidAnalysisArguments;
                    const iterations: u16 = @intFromFloat(value);
                    switch (option) {
                        .itl1 => o.tol.itl1 = iterations,
                        .itl2 => o.tol.itl2 = iterations,
                        .itl4 => o.tol.itl4 = iterations,
                        else => unreachable,
                    }
                },
                .maxord => {
                    if (value < 1 or value != @trunc(value)) return error.InvalidAnalysisArguments;
                    maxord = value;
                },
                inline else => |field| {
                    if (value < 0) return error.InvalidAnalysisArguments;
                    @field(o.tol, @tagName(field)) = value;
                },
            }
        }
    }
    if (o.method == .gear_2 and maxord != null and maxord.? < 2) o.method = .backward_euler;
    return o;
}

/// Copies the deck tolerances, temperature and integration method into `job`.
pub fn applyDeckOptions(job: *Job, o: DeckOptions) void {
    switch (job.*) {
        inline else => |*opts| {
            if (comptime @hasField(@TypeOf(opts.*), "tol")) opts.tol = o.tol;
            if (comptime @hasField(@TypeOf(opts.*), "dc_options")) opts.dc_options.tol = o.tol;
        },
    }
    if (job.* == .temp) job.temp.t_nom = o.temp_c orelse 27;
    if (o.method) |m| switch (job.*) {
        .tran => |*t| t.method = m,
        else => {},
    };
}

fn nameAt(args: []const Value, i: usize) ?[]const u8 {
    if (i >= args.len) return null;
    return switch (args[i]) {
        .name => |n| n,
        else => null,
    };
}

fn numberAt(args: []const Value, i: usize) ?f64 {
    if (i >= args.len) return null;
    return switch (args[i]) {
        .num => |n| n,
        else => null,
    };
}

fn number(args: []const Value, i: usize) !f64 {
    const n = numberAt(args, i) orelse return error.InvalidAnalysisArguments;
    if (!std.math.isFinite(n)) return error.InvalidAnalysisArguments;
    return n;
}

fn positive(args: []const Value, i: usize) !f64 {
    const n = try number(args, i);
    if (n <= 0) return error.InvalidAnalysisArguments;
    return n;
}

fn count(comptime T: type, args: []const Value, i: usize, default: T) !T {
    if (i >= args.len) return default;
    const n = try positive(args, i);
    if (n != @trunc(n) or n > std.math.maxInt(T)) return error.InvalidAnalysisArguments;
    return @intFromFloat(n);
}

fn arity(args: []const Value, min: usize, max: usize) !void {
    if (args.len < min or args.len > max) return error.InvalidAnalysisArguments;
}

/// One case-insensitive keyword argument, lowered into caller storage so the
/// `StaticStringMap` lookup that follows stays allocation-free.
fn keyword(args: []const Value, i: usize, buf: []u8) ![]const u8 {
    const name = nameAt(args, i) orelse return error.InvalidAnalysisArguments;
    if (name.len > buf.len) return error.InvalidAnalysisArguments;
    return std.ascii.lowerString(buf[0..name.len], name);
}

/// `uic` is a trailing keyword, not a positional: `.tran 1n 100n uic` and
/// `.tran 1n 100n 0 1n uic` are both legal, so scan rather than index.
fn hasUic(args: []const Value) bool {
    for (args) |a| switch (a) {
        .name => |n| if (std.ascii.eqlIgnoreCase(n, "uic")) return true,
        else => {},
    };
    return false;
}

fn outputNode(node: u32) !u32 {
    if (node == NO_NODE or node == GROUND) return error.AnalysisNodeNotFound;
    return node;
}

/// `v(a,b)` second node. Absent (single-ended) resolves to GROUND, which is
/// what every consumer already means by "no reference node"; a name the deck
/// never defines is a typo, not a ground reference.
fn outputNeg(node: u32) !u32 {
    if (node == NO_NODE) return GROUND;
    return node;
}

/// `i(name)`: a branch-current probe, as opposed to a `v(...)` output.
fn currentProbeName(args: []const Value, i: usize) ?[]const u8 {
    if (i >= args.len) return null;
    return switch (args[i]) {
        .group => |g| if (std.ascii.eqlIgnoreCase(g.name, "i") and g.args.len == 1)
            switch (g.args[0]) {
                .name => |n| n,
                else => null,
            }
        else
            null,
        else => null,
    };
}

fn findNameIndex(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, target)) return i;
    return null;
}

fn voltageSource(args: []const Value, i: usize, sources: core.QueryBindings) !usize {
    const name = nameAt(args, i) orelse return error.InvalidAnalysisArguments;
    return findNameIndex(sources.v_names, name) orelse error.AnalysisSourceNotFound;
}

/// The swept quantity of `.dc <card|TEMP> start stop step`, as the
/// (device type, instance index, parameter) key `ParamRef` uses.
fn dcTarget(args: []const Value, i: usize, cards: []const requests.CardRef) !requests.Dc.SweepTarget {
    const name = nameAt(args, i) orelse return error.InvalidAnalysisArguments;
    if (std.ascii.eqlIgnoreCase(name, "temp")) return .{ .is_temp = true };
    for (cards) |c| {
        if (!std.ascii.eqlIgnoreCase(c.name, name)) continue;
        // ngspice sweeps a card's primary value: `dc` on a source, the
        // element value on a passive.
        const param: []const u8 = switch (c.type) {
            Library.builtin("resistor") => "r",
            Library.builtin("capacitor") => "c",
            Library.builtin("inductor") => "l",
            else => "dc",
        };
        return .{ .type = c.type, .index = c.index, .param_name = param };
    }
    return error.AnalysisSourceNotFound;
}

fn checkStep(start: f64, stop: f64, step: f64) !void {
    const intervals = (stop - start) / step;
    if (step == 0 or !std.math.isFinite(intervals) or intervals < 0 or
        intervals >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidAnalysisArguments;
}

/// The `dec|oct|lin N fstart fstop` grid every frequency-domain card shares,
/// read from `offset`. Only `lin` admits fstart = 0.
fn frequencySweep(args: []const Value, offset: usize) !numerics.FreqSweep {
    const mode = nameAt(args, offset) orelse return error.InvalidAnalysisArguments;
    const kinds = std.StaticStringMap(numerics.SweepKind).initComptime(.{
        .{ "dec", .dec }, .{ "oct", .oct }, .{ "lin", .lin },
    });
    var lower: [8]u8 = undefined;
    if (mode.len > lower.len) return error.UnsupportedFrequencySweep;
    const kind = kinds.get(std.ascii.lowerString(lower[0..mode.len], mode)) orelse return error.UnsupportedFrequencySweep;
    const first = if (kind == .lin) try number(args, offset + 2) else try positive(args, offset + 2);
    const last = try positive(args, offset + 3);
    if (first < 0 or last < first) return error.InvalidAnalysisArguments;
    return .{ .f_start = first, .f_stop = last, .points = try count(u32, args, offset + 1, 10), .kind = kind };
}

/// The query one analysis card asks for; null for a card that only
/// configures the deck (single-value `.temp`). Errors name the argument
/// that is wrong: `InvalidAnalysisArguments`, `AnalysisNodeNotFound`,
/// `AnalysisSourceNotFound`, `UnsupportedFrequencySweep`.
pub fn buildJob(a: netlist.Analysis, sources: core.QueryBindings, cards: []const requests.CardRef) !?Job {
    const args = a.args;
    const id = a.kind;
    const node_id = a.pos;
    const node_neg = a.neg;
    const ports = a.ports;
    switch (id) {
        .op => {
            try arity(args, 0, 0);
            return .{ .op = .{} };
        },
        .tran, .tran_noise, .matex => {
            try arity(args, 2, if (id == .tran) 5 else 2);
            const step = try positive(args, 0);
            const stop = try positive(args, 1);
            if (id == .matex) return .{ .matex = .{ .t_stop = stop, .h_output_cap = step } };
            if (id == .tran_noise) return .{ .tran_noise = .{ .t_stop = stop, .dt_init = step, .dt_max = step } };
            var numeric_end = args.len;
            const uic = hasUic(args);
            if (uic) numeric_end -= 1;
            if (numeric_end > 4) return error.InvalidAnalysisArguments;
            // ngspice tstart: suppresses OUTPUT before it, never the solve.
            const t_start = if (numeric_end > 2) try number(args, 2) else 0;
            if (!(t_start >= 0) or t_start >= stop) return error.InvalidAnalysisArguments;
            return .{ .tran = .{ .t_stop = stop, .dt_init = step, .t_start = t_start, .dt_max = if (numeric_end > 3) try positive(args, 3) else @min(step, stop / 50), .uic = uic } };
        },
        .ac, .disto => {
            try arity(args, 4, 4);
            const grid = try frequencySweep(args, 0);
            if (id == .ac) return .{ .ac = .{ .sweep = grid } };
            var opts: requests.Disto = .{ .sweep = grid };
            // ngspice cktdisto.c:100-117: the F1 drive is the card carrying
            // DISTOF1, not the first source, on that card's branch row
            // (`disto/bjt_ce`: Vcc comes first, DISTOF1 is on Vin).
            // ponytail: first such card only. ngspice sums every DISTOF1
            // source into one RHS; sum here when a deck has two.
            for (sources.v_branches, sources.v_distof1) |br, d| {
                if (d[0] == 0) continue;
                opts.drive_branch = br;
                opts.ac_magnitude = d[0];
                opts.ac_phase = d[1];
                break;
            }
            return .{ .disto = opts };
        },
        .dc => {
            if (args.len != 4 and args.len != 8) return error.InvalidAnalysisArguments;
            var opts: requests.Dc = .{ .target = try dcTarget(args, 0, cards), .start = try number(args, 1), .stop = try number(args, 2), .step = try number(args, 3) };
            // Only the outer variable may be the temperature: the inner march
            // writes one ParamRef, and temperature is a whole-circuit set plus
            // a re-derive.
            if (opts.target.is_temp) return error.UnsupportedTemperatureSweep;
            try checkStep(opts.start, opts.stop, opts.step);
            if (args.len == 8) {
                opts.target2 = try dcTarget(args, 4, cards);
                opts.start2 = try number(args, 5);
                opts.stop2 = try number(args, 6);
                opts.step2 = try number(args, 7);
                try checkStep(opts.start2, opts.stop2, opts.step2);
            }
            return .{ .dc = opts };
        },
        .noise => {
            // The input reference source does not drive the noise solve, but
            // a name no card carries is still an error, not a silent success.
            try arity(args, 5, 6);
            const in_branch: ?u32 = if (args.len == 6)
                sources.v_branches[try voltageSource(args, 1, sources)]
            else
                null;
            return .{ .noise = .{ .out_node = try outputNode(node_id), .out_neg = try outputNeg(node_neg), .in_branch = in_branch, .sweep = try frequencySweep(args, args.len - 4) } };
        },
        .pnoise => {
            try arity(args, 7, 8);
            const sweep = try frequencySweep(args, 2);
            const sidebands = if (args.len == 8) try number(args, 7) else 7;
            if (sidebands < 0 or sidebands != @trunc(sidebands) or sidebands > 31) return error.InvalidAnalysisArguments;
            return .{ .pnoise = .{ .out_node = try outputNode(node_id), .sweep = sweep, .f_fundamental = try positive(args, 6), .n_sidebands = @intFromFloat(sidebands) } };
        },
        .tf => {
            try arity(args, 2, 2);
            var opts: requests.Tf = .{};
            // `.tf i(Vmeasure) ...` measures a branch current.
            if (currentProbeName(args, 0)) |probe| {
                opts.output_branch = sources.v_branches[findNameIndex(sources.v_names, probe) orelse return error.AnalysisSourceNotFound];
            } else {
                opts.output_node = try outputNode(node_id);
                opts.output_neg = try outputNeg(node_neg);
            }
            // The drive is a V card (branch row) or an I card (node pair).
            const drive = nameAt(args, 1) orelse return error.InvalidAnalysisArguments;
            if (findNameIndex(sources.v_names, drive)) |v| {
                opts.input_branch = sources.v_branches[v];
            } else if (findNameIndex(sources.i_names, drive)) |i_idx| {
                opts.input_nodes = .{ sources.i_pos[i_idx], sources.i_neg[i_idx] };
            } else return error.AnalysisSourceNotFound;
            return .{ .tf = opts };
        },
        .sens, .dcmatch => {
            try arity(args, 1, 1);
            const node = try outputNode(node_id);
            if (id == .sens) return .{ .sens = .{ .output_node = node, .output_neg = try outputNeg(node_neg), .cards = cards } };
            return .{ .dcmatch = .{ .output_node = node } };
        },
        .four => {
            try arity(args, 2, 3);
            return .{ .four = .{ .f_fundamental = try positive(args, 0), .output_node = try outputNode(node_id), .n_harmonics = try count(u16, args, 2, 9) } };
        },
        .pz => {
            // Bare `.pz` asks for the circuit's own poles and names no transfer.
            if (args.len == 0) return .{ .pz = .{} };
            try arity(args, 6, 6);
            const drive_kind = std.StaticStringMap(enum { vol, cur })
                .initComptime(.{ .{ "vol", .vol }, .{ "cur", .cur } });
            const wanted = std.StaticStringMap(enum { pol, zer, pz })
                .initComptime(.{ .{ "pol", .pol }, .{ "zer", .zer }, .{ "pz", .pz } });
            var lower: [4]u8 = undefined;
            const kind = drive_kind.get(try keyword(args, 4, &lower)) orelse return error.InvalidAnalysisArguments;
            const want = wanted.get(try keyword(args, 5, &lower)) orelse return error.InvalidAnalysisArguments;
            var opts: requests.Pz = .{
                .in_pos = try outputNode(ports[0]),
                .in_neg = try outputNeg(ports[1]),
                .out_pos = try outputNode(ports[2]),
                .out_neg = try outputNeg(ports[3]),
                .want_poles = want != .zer,
                .want_zeros = want != .pol,
            };
            // A `vol` transfer is driven by the voltage source the deck already
            // put across the input port: its branch row is the column the
            // numerator's Cramer rule needs, and its presence in the nulled
            // matrix is the short the denominator needs. `cur` needs no card:
            // a current injection is just the node pair.
            if (kind == .vol) {
                opts.drive_branch = for (sources.v_pos, sources.v_neg, sources.v_branches) |p, m, br| {
                    if ((p == opts.in_pos and m == opts.in_neg) or (p == opts.in_neg and m == opts.in_pos)) break br;
                } else return error.AnalysisSourceNotFound;
            }
            return .{ .pz = opts };
        },
        .pss => {
            try arity(args, 1, 2);
            return .{ .pss = .{ .period = 1 / try positive(args, 0), .n_samples = try count(u32, args, 1, 256) } };
        },
        .hb => {
            // HB drives from whatever sources the deck has, current ones
            // included, so it names none.
            try arity(args, 1, 2);
            return .{ .hb = .{ .f0 = try positive(args, 0), .n_harmonics = try count(u16, args, 1, 8) } };
        },
        .qpss => {
            try arity(args, 2, 4);
            if (sources.v_names.len == 0) return error.AnalysisSourceNotFound;
            return .{ .qpss = .{ .f1 = try positive(args, 0), .f2 = try positive(args, 1), .k1 = try count(u16, args, 2, 5), .k2 = try count(u16, args, 3, 5) } };
        },
        .pac, .pxf => {
            try arity(args, 5, 5);
            const sweep = try frequencySweep(args, 1);
            const lo = try positive(args, 0);
            if (id == .pac) return .{ .pac = .{ .f_lo = lo, .sweep = sweep } };
            return .{ .pxf = .{ .f_lo = lo, .sweep = sweep } };
        },
        .sp => {
            try arity(args, 4, 4);
            return .{ .sp = .{ .sweep = try frequencySweep(args, 0), .ports = sources.ports } };
        },
        .stb => {
            // `.stb Vprobe dec N fstart fstop`: the named 0 V source is the
            // loop break; the sweep drives its branch row directly.
            try arity(args, 5, 5);
            const probe = try voltageSource(args, 0, sources);
            return .{ .stb = .{
                .sweep = try frequencySweep(args, 1),
                .probe_p = sources.v_pos[probe],
                .probe_n = sources.v_neg[probe],
                .probe_branch = sources.v_branches[probe],
            } };
        },
        .envelope => {
            try arity(args, 2, 2);
            return .{ .envelope = .{ .t_carrier = try positive(args, 0), .t_stop = try positive(args, 1) } };
        },
        .mc => {
            try arity(args, 1, 2);
            var opts: requests.Mc = .{ .n_trials = try count(u16, args, 0, 100) };
            if (args.len == 2) opts.variation = try number(args, 1);
            if (opts.variation < 0) return error.InvalidAnalysisArguments;
            return .{ .mc = opts };
        },
        .temp => {
            // A single-temperature card is deck configuration.
            if (args.len == 1) {
                if (try number(args, 0) <= -273.15) return error.InvalidAnalysisArguments;
                return null;
            }
            try arity(args, 3, 3);
            const opts: requests.Temp = .{ .t_start = try number(args, 0), .t_stop = try number(args, 1), .t_step = try number(args, 2) };
            try checkStep(opts.t_start, opts.t_stop, opts.t_step);
            if (opts.t_step <= 0 or (opts.t_stop - opts.t_start) / opts.t_step >= std.math.maxInt(u32) or
                @min(opts.t_start, opts.t_stop) <= -273.15) return error.InvalidAnalysisArguments;
            return .{ .temp = opts };
        },
    }
}
