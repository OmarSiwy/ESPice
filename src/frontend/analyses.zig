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

/// How `queries` copies jobs over `Deck.variants` rows.
pub const Fanout = struct {
    /// Rows every card runs (`.step` points, `.alter` runs): the jobs of
    /// all cards once per row, after the nominal jobs when `nominal`.
    global: Span = .{},
    /// Rows of each card's own HSPICE sweep, parallel to the cards; empty
    /// for a deck without one.
    cards: []const Span = &.{},
    /// Keep only this card's jobs: a rebuilt point of one card's sweep.
    only: ?u32 = null,

    /// Rows `first..first + count` of `Deck.variants`.
    pub const Span = struct {
        first: u32 = 0,
        count: u32 = 0,
        nominal: bool = true,
        /// Solve the rows as one DC lane query (`.dc DATA=`, `.dc MONTE=`)
        /// whose first column is `axis`.
        lanes: ?struct { axis: []const u8, dc_plot: bool } = null,
    };
};

/// Queries for `cards` (nets already circuit rows), in card order, allocated
/// in `arena`. `.noise` also yields its integrated plot, `.disto` its two
/// harmonic vectors; a single-value `.temp` yields none. An output `v(...)`
/// names one or two nodes in the deck; `appended` cards must name exactly one.
/// `fanout` copies them over the deck's variants.
pub fn queries(arena: std.mem.Allocator, cards: []const netlist.Analysis, appended: bool, sources: core.QueryBindings, card_refs: []const requests.CardRef, deck_opts: DeckOptions, fanout: Fanout) ![]const Job {
    for (cards) |c| {
        const args = c.args;
        const arg: usize = if (c.kind == .four) 1 else 0;
        if (arg < args.len) switch (args[arg]) {
            .group => |g| if (g.args.len > @as(usize, if (appended) 1 else 2) or (appended and g.args.len == 0))
                return cardError(c.line, error.UnsupportedAnalysisOutput),
            else => {},
        };
    }
    // What HSPICE forms borrow from the other cards: the first `.ac`,
    // `.tran` and `.sn`. A malformed one reports on its own turn below.
    var ctx: CardContext = .{ .arena = arena, .variations = deck_opts.variations };
    // Fan-out ceiling: `.disto` gives three plots per line, `.op t1 t2 ...`
    // one per time.
    var fan: usize = 3;
    for (cards) |c| switch (c.kind) {
        .ac => if (ctx.ac == null) {
            if (acGrid(arena, c.args, 0)) |g| ctx.ac = g.sweep else |_| {}
        },
        .tran => if (ctx.tran == null) {
            if (buildJob(c, sources, card_refs, ctx)) |job| {
                var tran = job.?;
                applyDeckOptions(&tran, deck_opts);
                ctx.tran = tran.tran;
            } else |_| {}
        },
        .pss => if (c.sn and ctx.sn_f0 == null) {
            if (buildJob(c, sources, card_refs, ctx)) |job| ctx.sn_f0 = 1 / job.?.pss.period else |_| {}
        },
        .op => fan = @max(fan, c.args.len),
        else => {},
    };
    const temps = @max(deck_opts.temp_list.len, 1);
    var per_card: usize = fan;
    for (fanout.cards) |span| per_card = @max(per_card, fan * (span.count + 1));
    const rows = fanout.global.count + @intFromBool(fanout.global.nominal);
    const jobs = try arena.alloc(Job, cards.len * per_card * (temps + 1) * rows);
    var n: usize = 0;
    // HSPICE's `.hbac`, `.hbxf`, `.hbnoise` and `.phasenoise` take the tone
    // and harmonic count (and oscillator node) of the deck's `.hb` or
    // `.hbosc` card unless the card gives its own.
    var hb: ?requests.Hb = null;
    for (cards) |c| if (c.kind == .hb) {
        hb = ((buildJob(c, sources, card_refs, ctx) catch |err| return cardError(c.line, err)).?).hb;
    };
    // HSPICE's `.lstb` sweeps the deck's `.ac` frequencies [CR .LSTB].
    const ac_sweep: ?numerics.FreqSweep = for (cards) |c| {
        if (c.kind == .ac) break frequencySweep(c.args, 0) catch null;
    } else null;
    var xf_sources: ?[]const requests.XfSource = null;
    for (cards, 0..) |c, ci| {
        if (fanout.only) |only| if (ci != only) continue;
        const span: Fanout.Span = if (ci < fanout.cards.len) fanout.cards[ci] else .{};
        if (span.lanes) |lanes| {
            var job: Job = .{ .mc = .{ .variants = .{ .first = span.first, .count = span.count }, .axis = lanes.axis, .dc_plot = lanes.dc_plot } };
            applyDeckOptions(&job, deck_opts);
            jobs[n] = job;
            n += 1;
            continue;
        }
        const first = n;
        var job = (buildJob(c, sources, card_refs, ctx) catch |err| return cardError(c.line, err)) orelse continue;
        switch (job) {
            .hbac, .hbxf, .hbnoise => |*o| if (o.f0 == 0) {
                const tone = hb orelse return cardError(c.line, error.InvalidAnalysisArguments);
                o.f0 = tone.f0;
                o.n_harmonics = tone.n_harmonics;
                o.n_sidebands = tone.n_harmonics;
            },
            .phasenoise => |*o| if (o.f0 == 0) {
                const tone = hb orelse return cardError(c.line, error.InvalidAnalysisArguments);
                if (tone.osc_node == GROUND) return cardError(c.line, error.InvalidAnalysisArguments);
                o.f0 = tone.f0;
                o.n_harmonics = tone.n_harmonics;
                o.osc_node = tone.osc_node;
            },
            .lstb => |*o| if (o.sweep.points == 0) {
                o.sweep = ac_sweep orelse return cardError(c.line, error.InvalidAnalysisArguments);
            },
            inline .dcxf, .acxf => |*o| {
                if (xf_sources == null) xf_sources = try xfSources(arena, sources);
                o.sources = xf_sources.?;
            },
            else => {},
        }
        applyDeckOptions(&job, deck_opts);
        // HSPICE `.op t1 t2 ...` [CR .OP]: one operating point per time, a
        // transient snapshot past t = 0.
        if (job == .op and hasNumber(c.args)) {
            for (c.args) |v| {
                const t = switch (v) {
                    .num => |t| t,
                    else => continue,
                };
                jobs[n] = if (t == 0) job else snapshot(t, ctx.tran);
                applyDeckOptions(&jobs[n], deck_opts);
                n += 1;
            }
            if (span.count != 0) n = first + copyVariants(jobs[first..], n - first, span);
            continue;
        }
        jobs[n] = job;
        n += 1;
        // `.lstb` also reports its margins.
        if (job == .lstb) {
            job.lstb.margins = true;
            jobs[n] = job;
            n += 1;
        }
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
        if (span.count != 0) n = first + copyVariants(jobs[first..], n - first, span);
    }
    if (fanout.global.count != 0) n = copyVariants(jobs, n, fanout.global);
    if (temps == 1) return jobs[0..n];
    // An HSPICE `.temp` list runs every query once per temperature [CR .TEMP].
    const base = n;
    n = 0;
    for (deck_opts.temp_list) |t| {
        const temp = switch (t) {
            .num => |v| v,
            else => return error.InvalidAnalysisArguments,
        };
        if (!(temp > -273.15) or !std.math.isFinite(temp)) return error.InvalidAnalysisArguments;
        for (jobs[0..base]) |job| {
            var copy = job;
            switch (copy) {
                inline else => |*opts| opts.tol.temp_c = temp,
            }
            jobs[base + n] = copy;
            n += 1;
        }
    }
    return jobs[base..][0..n];
}

/// What a card borrows from the rest of the deck: HSPICE's `.noise` runs
/// over the `.ac` sweep, `.fft` and `.op <time>` over the `.tran`, and
/// `.snac`/`.snnoise`/`.snxf` at the `.sn` fundamental.
pub const CardContext = struct {
    /// Owns the point lists and labels a card allocates.
    arena: std.mem.Allocator,
    /// The first `.ac` card's grid.
    ac: ?numerics.FreqSweep = null,
    /// The first `.tran` card, deck options applied.
    tran: ?requests.Tran = null,
    /// The first `.sn` card's fundamental, in Hz.
    sn_f0: ?f64 = null,
    /// The deck's variation groups (`DeckOptions.variations`).
    variations: requests.Variations = .{},
};

fn hasNumber(args: []const Value) bool {
    for (args) |v| if (v == .num) return true;
    return false;
}

/// A transient that publishes only its state at `t` (HSPICE `.op <time>`),
/// stepping as the deck's `.tran` does and at most t / 50.
fn snapshot(t: f64, tran: ?requests.Tran) Job {
    var s: requests.Tran = tran orelse .{ .t_stop = t, .dt_init = t / 50 };
    s.t_stop = t;
    s.t_start = 0;
    s.snapshot = true;
    s.dt_init = @min(s.dt_init, t / 50);
    s.dt_max = @min(s.dt_max orelse t / 50, t / 50);
    return .{ .tran = s };
}

/// Rewrites the first `n` jobs of `jobs` as their copies over `span`'s rows,
/// row-major, after the originals when `span.nominal`, and returns the count.
fn copyVariants(jobs: []Job, n: usize, span: Fanout.Span) usize {
    const skip: usize = @intFromBool(span.nominal);
    // Back to front, so no copy overwrites a job not yet copied.
    var row = span.count;
    while (row > 0) {
        row -= 1;
        for (0..n) |k| {
            var copy = jobs[k];
            switch (copy) {
                inline else => |*opts| opts.tol.variant = span.first + @as(u32, @intCast(row)),
            }
            jobs[(row + skip) * n + k] = copy;
        }
    }
    return (span.count + skip) * n;
}

/// Logs the card a query could not be built from, then returns `err`.
fn cardError(line: []const u8, err: anytype) @TypeOf(err) {
    // The test runner fails any test that logs an error.
    if (!@import("builtin").is_test) std.log.err("analysis: {s}: {s}", .{ line, @errorName(err) });
    return err;
}

/// Parsed `.options` overrides, in deck order: a later card wins.
pub const DeckOptions = struct {
    tol: numerics.Tolerances = .{},
    /// `.options method`; null keeps each query's default.
    method: ?requests.Method = null,
    /// `.temp` or `.options temp` in degrees Celsius; null when not given.
    temp_c: ?f64 = null,
    /// An HSPICE `.temp t1 t2 ...` list: every query runs at each.
    temp_list: []const Value = &.{},
    /// `.options delmax`: the transient step cap when the `.tran` card sets
    /// none.
    delmax: ?f64 = null,
    /// `.options tnom=<degC>`: the temperature model cards were extracted at
    /// (ngspice cktsopt.c:71-73 takes the card in Celsius; default 27 degC
    /// from cktntask.c:127). Unlike `temp`, where the circuit runs, it reaches
    /// the devices at build time, so no sweep can move it.
    tnom_c: f64 = 27.0,
    /// The variation block as `.dcmatch`, `.acmatch` and `.dcsens` groups.
    variations: requests.Variations = .{},
};

/// Option names outside this list are not simulated; the HSPICE dialect
/// warns about each. `gshunt` and `cshunt` are read by the netlist.
const Option = enum(u8) { method, reltol, abstol, vntol, gmin, trtol, chgtol, itl1, itl2, itl4, maxord, temp, tnom, delmax, gshunt, cshunt };

/// Folds the deck's `.options` and `.temp` cards; `InvalidAnalysisArguments`
/// on a value out of range. The HSPICE dialect defaults TNOM to 25 degC and
/// runs the circuit at TNOM [SA Ch.20]; ngspice defaults both to 27 degC.
pub fn deckOptions(config: []const netlist.Config, dialect: netlist.Dialect) !DeckOptions {
    // HSPICE spellings: ABSV/RELV/ABSI are VNTOL/RELTOL/ABSTOL, GMINDC the DC
    // gmin (ESPice has one gmin), METHOD=BDF its Gear.
    const names = std.StaticStringMap(Option).initComptime(.{
        .{ "method", .method }, .{ "reltol", .reltol }, .{ "abstol", .abstol },
        .{ "vntol", .vntol },   .{ "gmin", .gmin },     .{ "trtol", .trtol },
        .{ "chgtol", .chgtol }, .{ "itl1", .itl1 },     .{ "itl2", .itl2 },
        .{ "itl4", .itl4 },     .{ "maxord", .maxord }, .{ "temp", .temp },
        .{ "tnom", .tnom },     .{ "absv", .vntol },    .{ "relv", .reltol },
        .{ "absi", .abstol },   .{ "gmindc", .gmin },   .{ "delmax", .delmax },
        .{ "gshunt", .gshunt }, .{ "cshunt", .cshunt },
    });
    const methods = std.StaticStringMap(requests.Method).initComptime(.{
        .{ "gear", .gear_2 }, .{ "trap", .trapezoidal }, .{ "trapezoidal", .trapezoidal }, .{ "bdf", .gear_2 },
    });
    var o: DeckOptions = .{ .tnom_c = if (dialect == .hspice) 25 else 27 };
    var maxord: ?f64 = null;
    for (config) |card| {
        const args = card.args;
        if (card.temp) {
            if (args.len > 1) {
                o.temp_list = args;
                continue;
            }
            o.temp_c = try number(args, 0);
            if (o.temp_c.? <= -273.15) return error.InvalidAnalysisArguments;
            continue;
        }
        var lower: [16]u8 = undefined;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const key = nameAt(args, i) orelse continue;
            if (key.len > lower.len) continue;
            // Monte Carlo draws read these (frontend/variants.zig).
            if (std.ascii.eqlIgnoreCase(key, "seed") or std.ascii.eqlIgnoreCase(key, "sampling_method")) {
                i += 1;
                continue;
            }
            const option = names.get(std.ascii.lowerString(lower[0..key.len], key)) orelse {
                if (dialect == .hspice) std.log.warn("options: ignoring unsupported option '{s}'", .{key});
                continue;
            };
            i += 1;
            if (option == .method) {
                const method = nameAt(args, i) orelse return error.InvalidAnalysisArguments;
                if (method.len > lower.len) return error.InvalidAnalysisArguments;
                o.method = methods.get(std.ascii.lowerString(lower[0..method.len], method)) orelse return error.InvalidAnalysisArguments;
                continue;
            }
            const raw = try number(args, i);
            // ngspice reads an IF_INTEGER option as floor(0.5 + x)
            // (spiceif.c:501, inpgval.c:31), so itl4=1.5 is 2.
            const value = switch (option) {
                .itl1, .itl2, .itl4, .maxord => @floor(0.5 + raw),
                else => raw,
            };
            switch (option) {
                .method => unreachable,
                .temp, .tnom => {
                    if (value <= -273.15) return error.InvalidAnalysisArguments;
                    if (option == .temp) o.temp_c = value else o.tnom_c = value;
                },
                .itl1, .itl2, .itl4 => {
                    if (value < 1 or value > std.math.maxInt(u16)) return error.InvalidAnalysisArguments;
                    const iterations: u16 = @intFromFloat(value);
                    switch (option) {
                        .itl1 => o.tol.itl1 = iterations,
                        .itl2 => o.tol.itl2 = iterations,
                        .itl4 => o.tol.itl4 = iterations,
                        else => unreachable,
                    }
                },
                .maxord => {
                    if (value < 1) return error.InvalidAnalysisArguments;
                    maxord = value;
                },
                .delmax => {
                    if (!(value > 0)) return error.InvalidAnalysisArguments;
                    o.delmax = value;
                },
                .gshunt, .cshunt => if (value < 0) return error.InvalidAnalysisArguments,
                inline else => |field| {
                    if (value < 0) return error.InvalidAnalysisArguments;
                    @field(o.tol, @tagName(field)) = value;
                },
            }
        }
    }
    if (o.method == .gear_2 and maxord != null and maxord.? < 2) o.method = .backward_euler;
    if (dialect == .hspice and o.temp_c == null and o.temp_list.len == 0) o.temp_c = o.tnom_c;
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
    if (job.* == .tran) {
        const t = &job.tran;
        if (o.method) |m| t.method = m;
        // ngspice's default tmax, min(tstep, tstop / 50).
        t.dt_max = t.dt_max orelse o.delmax orelse @min(t.dt_init, t.t_stop / 50);
    }
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

/// Every independent source, V cards then I cards, in card order.
fn xfSources(arena: std.mem.Allocator, sources: core.QueryBindings) ![]const requests.XfSource {
    const out = try arena.alloc(requests.XfSource, sources.v_names.len + sources.i_names.len);
    for (sources.v_names, sources.v_branches, out[0..sources.v_names.len]) |name, br, *s| s.* = .{ .name = name, .branch = br };
    for (sources.i_names, sources.i_pos, sources.i_neg, out[sources.v_names.len..]) |name, p, m, *s| s.* = .{ .name = name, .branch = null, .nodes = .{ p, m } };
    return out;
}

/// `.lstb mode=single|diff|comm vsource=v1[,v2] [dec|oct|lin N f1 f2]`
/// [CR .LSTB]: the first three letters of the mode count. Without a sweep
/// the card takes the deck's `.ac` frequencies (`points` 0 until then).
fn lstbJob(args: []const Value, sources: core.QueryBindings) !requests.Lstb {
    const Key = enum { mode, vsource, dec, oct, lin };
    const keys = std.StaticStringMap(Key).initComptime(.{
        .{ "mode", .mode }, .{ "vsource", .vsource }, .{ "dec", .dec }, .{ "oct", .oct }, .{ "lin", .lin },
    });
    const modes = std.StaticStringMap(requests.Lstb.Mode).initComptime(.{
        .{ "sin", .single }, .{ "dif", .diff }, .{ "com", .comm },
    });
    var opts: requests.Lstb = .{ .sweep = .{ .f_start = 0, .f_stop = 0, .points = 0, .kind = .lin }, .probes = undefined };
    var n_probes: usize = 0;
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < args.len) {
        const key = keys.get(try keyword(args, i, &buf)) orelse return error.InvalidAnalysisArguments;
        switch (key) {
            .mode => {
                const m = try keyword(args, i + 1, &buf);
                opts.mode = modes.get(m[0..@min(m.len, 3)]) orelse return error.InvalidAnalysisArguments;
                i += 2;
            },
            .vsource => {
                i += 1;
                while (i < args.len) : (i += 1) {
                    if (keys.has(keyword(args, i, &buf) catch "")) break;
                    if (n_probes == 2) return error.InvalidAnalysisArguments;
                    const v = try voltageSource(args, i, sources);
                    opts.probes[n_probes] = .{ .p = sources.v_pos[v], .n = sources.v_neg[v], .branch = sources.v_branches[v] };
                    n_probes += 1;
                }
            },
            .dec, .oct, .lin => {
                try arity(args, i + 4, i + 4);
                opts.sweep = try frequencySweep(args, i);
                i += 4;
            },
        }
    }
    if (n_probes != @as(usize, if (opts.mode == .single) 1 else 2)) return error.InvalidAnalysisArguments;
    if (n_probes == 1) opts.probes[1] = opts.probes[0];
    return opts;
}

/// The `v(out)`, `v(a,b)` or `i(Vmeasure)` output of `.dcxf`/`.acxf`, and
/// whether a trailing `tf` asks for transfer functions only.
fn xfOutput(comptime T: type, args: []const Value, node: u32, neg: u32, sources: core.QueryBindings) !T {
    var opts: T = if (T == requests.Acxf)
        .{ .sweep = try frequencySweep(args, 1), .output_node = GROUND, .sources = &.{} }
    else
        .{ .output_node = GROUND, .sources = &.{} };
    if (currentProbeName(args, 0)) |probe| {
        opts.output_branch = sources.v_branches[netlist.nameIndex(sources.v_names, probe) orelse return error.AnalysisSourceNotFound];
    } else {
        opts.output_node = try outputNode(node);
        opts.output_neg = try outputNeg(neg);
    }
    const last = args.len - 1;
    if (last > 0) if (nameAt(args, last)) |word| {
        if (!std.ascii.eqlIgnoreCase(word, "tf")) return error.InvalidAnalysisArguments;
        opts.tf_only = true;
    };
    return opts;
}

fn voltageSource(args: []const Value, i: usize, sources: core.QueryBindings) !usize {
    const name = nameAt(args, i) orelse return error.InvalidAnalysisArguments;
    return netlist.nameIndex(sources.v_names, name) orelse error.AnalysisSourceNotFound;
}

/// The swept quantity of `.dc <card|TEMP> start stop step`, as the
/// (device type, instance index, parameter) key `ParamRef` uses.
pub fn dcTarget(args: []const Value, i: usize, cards: []const requests.CardRef) !requests.Dc.SweepTarget {
    const name = nameAt(args, i) orelse return error.InvalidAnalysisArguments;
    if (std.ascii.eqlIgnoreCase(name, "temp")) return .temp;
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
        return .{ .device = .{ .type = c.type, .index = c.index, .param_name = param } };
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

/// A frequency grid at `args[offset..]` and the index past it: the
/// `dec|oct|lin N fstart fstop` grid, or HSPICE's `POI n f1 ... fn` [CR .AC]
/// with its frequencies ascending and positive, allocated in `arena`.
fn acGrid(arena: std.mem.Allocator, args: []const Value, offset: usize) !struct { sweep: numerics.FreqSweep, end: usize } {
    var lower: [4]u8 = undefined;
    const poi = nameAt(args, offset) != null and std.mem.eql(u8, keyword(args, offset, &lower) catch "", "poi");
    if (!poi) return .{ .sweep = try frequencySweep(args, offset), .end = offset + 4 };
    const n = try count(u32, args, offset + 1, 0);
    if (n == 0) return error.InvalidAnalysisArguments;
    const list = try arena.alloc(f64, n);
    for (list, 0..) |*f, k| {
        f.* = try positive(args, offset + 2 + k);
        if (k > 0 and !(f.* > list[k - 1])) return error.InvalidAnalysisArguments;
    }
    return .{ .sweep = .{ .kind = .poi, .points = n, .list = list, .f_start = list[0], .f_stop = list[n - 1] }, .end = offset + 2 + n };
}

/// One `.dc` axis, read from `args[i.*..]` and `i` advanced past it:
/// `start stop incr`, HSPICE `START= STOP= STEP=`, `LIN|DEC|OCT np start
/// stop` or `POI np v1 ... vn` [CR .DC]. The typed grids become explicit
/// `points`, allocated in `arena`.
const Axis = struct { start: f64 = 0, stop: f64 = 0, step: f64 = 1, points: []const f64 = &.{} };

fn dcAxis(arena: std.mem.Allocator, args: []const Value, i: *usize) !Axis {
    const Word = enum { lin, dec, oct, poi, start, stop, step };
    const words = std.StaticStringMap(Word).initComptime(.{
        .{ "lin", .lin },     .{ "dec", .dec },   .{ "oct", .oct },   .{ "poi", .poi },
        .{ "start", .start }, .{ "stop", .stop }, .{ "step", .step },
    });
    const wordAt = struct {
        fn f(a: []const Value, at: usize) ?Word {
            var lower: [8]u8 = undefined;
            const name = nameAt(a, at) orelse return null;
            if (name.len > lower.len) return null;
            return words.get(std.ascii.lowerString(lower[0..name.len], name));
        }
    }.f;
    var axis: Axis = .{};
    switch (wordAt(args, i.*) orelse {
        axis = .{ .start = try number(args, i.*), .stop = try number(args, i.* + 1), .step = try number(args, i.* + 2) };
        try checkStep(axis.start, axis.stop, axis.step);
        i.* += 3;
        return axis;
    }) {
        .start, .stop, .step => {
            var seen: u3 = 0;
            while (wordAt(args, i.*)) |key| : (i.* += 2) {
                const v = try number(args, i.* + 1);
                switch (key) {
                    .start => axis.start = v,
                    .stop => axis.stop = v,
                    .step => axis.step = v,
                    else => return error.InvalidAnalysisArguments,
                }
                seen |= @as(u3, 1) << @intCast(@intFromEnum(key) - @intFromEnum(Word.start));
            }
            if (seen != 0b111) return error.InvalidAnalysisArguments;
            try checkStep(axis.start, axis.stop, axis.step);
        },
        .poi => {
            const n = try count(u32, args, i.* + 1, 0);
            if (n == 0) return error.InvalidAnalysisArguments;
            const points = try arena.alloc(f64, n);
            for (points, 0..) |*p, k| p.* = try number(args, i.* + 2 + k);
            i.* += 2 + n;
            axis.points = points;
        },
        .lin, .dec, .oct => |kind| {
            const grid: numerics.FreqSweep = .{
                .kind = if (kind == .lin) .lin else if (kind == .dec) .dec else .oct,
                .points = try count(u32, args, i.* + 1, 0),
                .f_start = try number(args, i.* + 2),
                .f_stop = try number(args, i.* + 3),
            };
            if (grid.points == 0) return error.InvalidAnalysisArguments;
            if (kind != .lin and !(grid.f_start > 0 and grid.f_stop >= grid.f_start)) return error.InvalidAnalysisArguments;
            // ponytail: a 10M-point ceiling keeps a typo from allocating the heap.
            if (grid.count() > 10_000_000) return error.InvalidAnalysisArguments;
            const points = try arena.alloc(f64, grid.count());
            for (points, 0..) |*p, k| p.* = grid.at(@intCast(k));
            i.* += 4;
            axis.points = points;
        },
    }
    if (axis.points.len > 0) {
        axis.start = axis.points[0];
        axis.stop = axis.points[axis.points.len - 1];
    }
    return axis;
}

/// HSPICE `.tran tstep1 tstop1 [tstep2 tstop2 ...] [START=t] [UIC]` [CR
/// .TRAN]: one run to the last tstop. A double-point card whose tstep2 and
/// tstop2 are both below tstop1, with no START=, is the SPICE form
/// `tstep tstop tstart delmax`, as is a three-number card.
fn hspiceTran(args: []const Value) !requests.Tran {
    var nums: [32]f64 = undefined;
    var n: usize = 0;
    var start: ?f64 = null;
    var uic = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        var lower: [8]u8 = undefined;
        switch (args[i]) {
            .num => |v| {
                if (n == nums.len or !std.math.isFinite(v)) return error.InvalidAnalysisArguments;
                nums[n] = v;
                n += 1;
            },
            .name => {
                const word = try keyword(args, i, &lower);
                if (std.mem.eql(u8, word, "uic")) {
                    uic = true;
                } else if (std.mem.eql(u8, word, "start")) {
                    i += 1;
                    start = try number(args, i);
                } else return error.InvalidAnalysisArguments;
            },
            else => return error.InvalidAnalysisArguments,
        }
    }
    if (n < 2 or !(nums[0] > 0) or !(nums[1] > 0)) return error.InvalidAnalysisArguments;
    var t: requests.Tran = .{ .t_stop = nums[1], .dt_init = nums[0], .uic = uic, .dt_max = null };
    if (n == 3 or (n == 4 and start == null and nums[2] < nums[1] and nums[3] < nums[1])) {
        t.t_start = nums[2];
        if (n == 4) t.dt_max = if (nums[3] > 0) nums[3] else return error.InvalidAnalysisArguments;
    } else {
        if (n % 2 != 0) return error.InvalidAnalysisArguments;
        // ponytail: the finest tstep caps the whole run; a per-segment cap
        // would save steps in the coarse segments.
        var k: usize = 2;
        while (k < n) : (k += 2) {
            if (!(nums[k] > 0) or !(nums[k + 1] > nums[k - 1])) return error.InvalidAnalysisArguments;
            t.dt_init = @min(t.dt_init, nums[k]);
            t.t_stop = nums[k + 1];
        }
    }
    t.t_start = start orelse t.t_start;
    if (!(t.t_start >= 0) or t.t_start >= t.t_stop) return error.InvalidAnalysisArguments;
    return t;
}

/// True for an HSPICE `.lin` card, which runs as an `.sp` query.
fn isLin(line: []const u8) bool {
    const head = line[@min(line.len, 1) .. std.mem.indexOfAny(u8, line, " \t") orelse line.len];
    return std.ascii.eqlIgnoreCase(head, "lin");
}

/// HSPICE `.lin [sparcalc=1] [noisecalc=0|1|2] [gdcalc=0|1]
/// [mixedmode2port=ss] [format= filename= dataformat= modelname= ...]`
/// [CR .LIN] over the `.ac` sweep. S is always computed. noisecalc=2 (the
/// N-port correlation matrix) publishes the two-port parameters only.
/// `format=touchstone|touchstone2` also writes a Touchstone 1.0 file named
/// by `filename=`; the other formats (`selem`, `citi`) and the listing
/// keywords are checked for a value and unused.
fn lin(args: []const Value) !requests.Sp.Lin {
    const Key = enum { sparcalc, noisecalc, gdcalc, mixedmode2port, format, filename, dataformat, modelname, freqdigit, spardigit, listfreq, listcount, listfloor, listsources };
    var o: requests.Sp.Lin = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        var lower: [16]u8 = undefined;
        const key = std.meta.stringToEnum(Key, try keyword(args, i, &lower)) orelse return error.InvalidAnalysisArguments;
        if (i + 1 >= args.len) return error.InvalidAnalysisArguments;
        switch (key) {
            .sparcalc, .noisecalc, .gdcalc => {
                const v = try number(args, i + 1);
                if (v != @trunc(v) or v < 0 or v > @as(f64, if (key == .noisecalc) 2 else 1)) return error.InvalidAnalysisArguments;
                if (key == .noisecalc) o.noise = v != 0;
                if (key == .gdcalc) o.group_delay = v != 0;
            },
            .mixedmode2port => if (!std.ascii.eqlIgnoreCase(nameAt(args, i + 1) orelse "", "ss")) return error.UnsupportedAnalysisOutput,
            .format => {
                const f = nameAt(args, i + 1) orelse return error.InvalidAnalysisArguments;
                o.touchstone = std.ascii.startsWithIgnoreCase(f, "touchstone");
            },
            .filename => o.file = nameAt(args, i + 1) orelse return error.InvalidAnalysisArguments,
            else => {},
        }
    }
    return o;
}

/// HSPICE `.sn TRES= PERIOD=` or `.sn TONE= NHARMS=` [CR .SN] as `.pss`:
/// the period, and PERIOD/TRES steps when TRES is given. TRINIT,
/// MAXTRINITCYCLES and NUMPEROUT are read and unused: `.pss` shoots from
/// the operating point and publishes one period.
fn shootingNewton(args: []const Value) !requests.Pss {
    const Key = enum { tres, period, tone, nharms, trinit, maxtrinitcycles, numperout };
    var given: [@typeInfo(Key).@"enum".fields.len]?f64 = @splat(null);
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        var lower: [16]u8 = undefined;
        const key = std.meta.stringToEnum(Key, try keyword(args, i, &lower)) orelse return error.InvalidAnalysisArguments;
        given[@intFromEnum(key)] = try positive(args, i + 1);
    }
    const period = given[@intFromEnum(Key.period)] orelse
        1 / (given[@intFromEnum(Key.tone)] orelse return error.InvalidAnalysisArguments);
    var pss: requests.Pss = .{ .period = period };
    if (given[@intFromEnum(Key.tres)]) |tres| {
        const steps = @round(period / tres);
        if (!(steps >= 1) or steps > std.math.maxInt(u32) - 1) return error.InvalidAnalysisArguments;
        pss.n_samples = @intFromFloat(steps);
    }
    return pss;
}

/// HSPICE `.fft v(a[,b]) [START=|FROM=] [STOP=|TO=] [NP=] [FORMAT=NORM|UNORM]
/// [WINDOW=] [ALFA=] [FREQ=] [FMIN=] [FMAX=]` [CR .FFT] over the deck's
/// `.tran`, whose window START and STOP default to. NP rounds up to a power
/// of two. FREQ, FMIN and FMAX only shape HSPICE's printed listing; they are
/// checked and not stored.
fn fft(ctx: CardContext, args: []const Value, pos: u32, neg: u32) !requests.Fft {
    const tran = ctx.tran orelse return error.MissingAnalysisCard;
    if (args.len == 0) return error.InvalidAnalysisArguments;
    if (currentProbeName(args, 0) != null) return error.UnsupportedAnalysisOutput;
    var o: requests.Fft = .{
        .tran = tran,
        .out_pos = try outputNode(pos),
        .out_neg = try outputNeg(neg),
        .start = tran.t_start,
        .stop = tran.t_stop,
        .label = try outputLabel(ctx.arena, args[0]),
    };
    const Key = enum { start, from, stop, to, np, format, window, alfa, freq, fmin, fmax };
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        var lower: [8]u8 = undefined;
        const key = std.meta.stringToEnum(Key, try keyword(args, i, &lower)) orelse return error.InvalidAnalysisArguments;
        switch (key) {
            .start, .from => o.start = try number(args, i + 1),
            .stop, .to => o.stop = try number(args, i + 1),
            .np => {
                const np = try positive(args, i + 1);
                if (np > 1 << 27) return error.InvalidAnalysisArguments;
                o.np = std.math.ceilPowerOfTwoAssert(u32, @intFromFloat(@max(@ceil(np), 4)));
            },
            .format => {
                const word = try keyword(args, i + 1, &lower);
                o.normalized = if (std.mem.eql(u8, word, "norm")) true else if (std.mem.eql(u8, word, "unorm")) false else return error.InvalidAnalysisArguments;
            },
            .window => o.window = std.meta.stringToEnum(requests.Fft.Window, try keyword(args, i + 1, &lower)) orelse return error.InvalidAnalysisArguments,
            .alfa => {
                o.alfa = try number(args, i + 1);
                if (o.alfa < 1 or o.alfa > 20) return error.InvalidAnalysisArguments;
            },
            .freq, .fmin, .fmax => if (try number(args, i + 1) < 0) return error.InvalidAnalysisArguments,
        }
    }
    if (o.start < tran.t_start or o.stop > tran.t_stop or !(o.stop > o.start)) return error.InvalidAnalysisArguments;
    return o;
}

/// An output as the card wrote it, `v(a)` or `v(a,b)`, allocated in `arena`.
fn outputLabel(arena: std.mem.Allocator, value: Value) ![]const u8 {
    const g = switch (value) {
        .group => |g| g,
        else => return error.InvalidAnalysisArguments,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("{s}(", .{g.name}) catch return error.OutOfMemory;
    for (g.args, 0..) |v, k| {
        if (k > 0) w.writeByte(',') catch return error.OutOfMemory;
        switch (v) {
            .name => |n| w.writeAll(n) catch return error.OutOfMemory,
            .num => |n| w.print("{d}", .{n}) catch return error.OutOfMemory,
            else => return error.InvalidAnalysisArguments,
        }
    }
    w.writeByte(')') catch return error.OutOfMemory;
    return out.written();
}

/// The query one analysis card asks for; null for a card that only
/// configures the deck (single-value `.temp`). Errors name the argument
/// that is wrong: `InvalidAnalysisArguments`, `AnalysisNodeNotFound`,
/// `AnalysisSourceNotFound`, `UnsupportedFrequencySweep`,
/// `UnsupportedAnalysisOutput`, and `MissingAnalysisCard` for an HSPICE form
/// whose deck lacks the card it reads (`ctx`).
pub fn buildJob(a: netlist.Analysis, sources: core.QueryBindings, cards: []const requests.CardRef, ctx: CardContext) !?Job {
    const args = a.args;
    const id = a.kind;
    const node_id = a.pos;
    const node_neg = a.neg;
    const ports = a.ports;
    switch (id) {
        .op => {
            // HSPICE `.op [format] [time ...]` [CR .OP]; `queries` turns the
            // times into snapshots.
            const formats = std.StaticStringMap(void).initComptime(.{
                .{"all"}, .{"brief"}, .{"current"}, .{"debug"}, .{"none"}, .{"voltage"},
            });
            var lower: [8]u8 = undefined;
            for (args, 0..) |v, i| switch (v) {
                .num => |t| if (!(t >= 0) or !std.math.isFinite(t)) return error.InvalidAnalysisArguments,
                .name => if (!formats.has(try keyword(args, i, &lower))) return error.InvalidAnalysisArguments,
                else => return error.InvalidAnalysisArguments,
            };
            return .{ .op = .{} };
        },
        .tran, .tran_noise, .matex => {
            if (id == .tran and a.dialect == .hspice) return .{ .tran = try hspiceTran(args) };
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
            return .{ .tran = .{ .t_stop = stop, .dt_init = step, .t_start = t_start, .dt_max = if (numeric_end > 3) try positive(args, 3) else null, .uic = uic } };
        },
        .ac => {
            const grid = try acGrid(ctx.arena, args, 0);
            if (grid.end != args.len) return error.InvalidAnalysisArguments;
            return .{ .ac = .{ .sweep = grid.sweep } };
        },
        .disto => {
            try arity(args, 4, 4);
            const grid = try frequencySweep(args, 0);
            var opts: requests.Disto = .{ .sweep = grid, .output_node = try outputNode(node_id) };
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
            var opts: requests.Dc = .{ .target = try dcTarget(args, 0, cards) };
            var i: usize = 1;
            const inner = try dcAxis(ctx.arena, args, &i);
            opts.start = inner.start;
            opts.stop = inner.stop;
            opts.step = inner.step;
            opts.points = inner.points;
            if (i < args.len) {
                opts.target2 = try dcTarget(args, i, cards);
                i += 1;
                const outer = try dcAxis(ctx.arena, args, &i);
                opts.start2 = outer.start;
                opts.stop2 = outer.stop;
                opts.step2 = outer.step;
                opts.points2 = outer.points;
            }
            if (i != args.len) return error.InvalidAnalysisArguments;
            return .{ .dc = opts };
        },
        .noise => {
            // ngspice: `v(out) [src] dec|oct|lin N f1 f2 [pts]`; HSPICE:
            // `v(out) src [inter]` over the `.ac` sweep [CR .NOISE]. A
            // nonzero pts or inter asks for the per-device contributions.
            // The input reference source does not drive the noise solve, but
            // a name no card carries is still an error, not a silent success.
            var i: usize = 1;
            var in_branch: ?u32 = null;
            const grid_words = std.StaticStringMap(void).initComptime(.{ .{"dec"}, .{"oct"}, .{"lin"}, .{"poi"} });
            var lower: [4]u8 = undefined;
            const isGrid = struct {
                fn f(words: anytype, xs: []const Value, at: usize, buf: *[4]u8) bool {
                    const name = nameAt(xs, at) orelse return false;
                    return name.len <= buf.len and words.has(std.ascii.lowerString(buf[0..name.len], name));
                }
            }.f;
            if (i < args.len and !isGrid(grid_words, args, i, &lower)) {
                in_branch = sources.v_branches[try voltageSource(args, i, sources)];
                i += 1;
            }
            var sweep: numerics.FreqSweep = undefined;
            if (i < args.len and isGrid(grid_words, args, i, &lower)) {
                const g = try acGrid(ctx.arena, args, i);
                sweep = g.sweep;
                i = g.end;
            } else sweep = ctx.ac orelse return error.MissingAnalysisCard;
            const contributions = i < args.len and try number(args, i) > 0;
            if (i < args.len) i += 1;
            if (i != args.len) return error.InvalidAnalysisArguments;
            return .{ .noise = .{
                .out_node = try outputNode(node_id),
                .out_neg = try outputNeg(node_neg),
                .in_branch = in_branch,
                .sweep = sweep,
                .contributions = contributions,
                .cards = cards,
            } };
        },
        .pnoise => {
            // HSPICE `.snnoise v(out) insrc <sweep> [n1 +/-1]` [CR .SNNOISE]
            // at the `.sn` fundamental. Only the n1 = 0 band, the input's
            // own frequency, is the band `.pnoise` measures.
            if (a.sn) {
                const f0 = ctx.sn_f0 orelse return error.MissingAnalysisCard;
                _ = nameAt(args, 1) orelse return error.InvalidAnalysisArguments;
                const grid = try acGrid(ctx.arena, args, 2);
                if (args.len > grid.end + 2) return error.InvalidAnalysisArguments;
                if (grid.end < args.len and try number(args, grid.end) != 0) return error.InvalidAnalysisArguments;
                return .{ .pnoise = .{ .out_node = try outputNode(node_id), .sweep = grid.sweep, .f_fundamental = f0 } };
            }
            try arity(args, 7, 8);
            const sweep = try frequencySweep(args, 2);
            const sidebands = if (args.len == 8) try number(args, 7) else 7;
            if (sidebands < 0 or sidebands != @trunc(sidebands) or sidebands > 31) return error.InvalidAnalysisArguments;
            return .{ .pnoise = .{ .out_node = try outputNode(node_id), .out_neg = try outputNeg(node_neg), .sweep = sweep, .f_fundamental = try positive(args, 6), .n_sidebands = @intFromFloat(sidebands) } };
        },
        .tf => {
            try arity(args, 2, 2);
            var opts: requests.Tf = .{ .output_node = GROUND };
            // `.tf i(Vmeasure) ...` measures a branch current.
            if (currentProbeName(args, 0)) |probe| {
                opts.output_branch = sources.v_branches[netlist.nameIndex(sources.v_names, probe) orelse return error.AnalysisSourceNotFound];
            } else {
                opts.output_node = try outputNode(node_id);
                opts.output_neg = try outputNeg(node_neg);
            }
            // The drive is a V card (branch row) or an I card (node pair).
            const drive = nameAt(args, 1) orelse return error.InvalidAnalysisArguments;
            if (netlist.nameIndex(sources.v_names, drive)) |v| {
                opts.input_branch = sources.v_branches[v];
            } else if (netlist.nameIndex(sources.i_names, drive)) |i_idx| {
                opts.input_nodes = .{ sources.i_pos[i_idx], sources.i_neg[i_idx] };
            } else return error.AnalysisSourceNotFound;
            return .{ .tf = opts };
        },
        .sens, .dcmatch => {
            try arity(args, 1, 1);
            const node = try outputNode(node_id);
            const neg = try outputNeg(node_neg);
            if (id == .sens) return .{ .sens = .{ .output_node = node, .output_neg = neg, .cards = cards } };
            return .{ .dcmatch = .{ .output_node = node, .output_neg = neg, .variations = ctx.variations } };
        },
        .acmatch, .dcsens => {
            // HSPICE `.acmatch v(out) [THRESHOLD= FILE= INTERVAL=
            // VIRTUAL_SENSITIVITY= SENS_THRESHOLD=]` over the `.ac` sweep, and
            // `.dcsens v(out) [FILE= PERTURBATION= INTERVAL= THRESHOLD=
            // GROUPBYDEVICE=]` [CR .ACMATCH, .DCSENS]. Every group is
            // published, so the listing keywords are checked and unused;
            // the derivative is the adjoint one, so PERTURBATION is too.
            if (args.len == 0 or args.len % 2 != 1) return error.InvalidAnalysisArguments;
            const keys = std.StaticStringMap(void).initComptime(.{
                .{"threshold"}, .{"file"}, .{"interval"}, .{"virtual_sensitivity"}, .{"virtual_sens"},
                .{"sens_threshold"}, .{"perturbation"}, .{"groupbydevice"},
            });
            var i: usize = 1;
            while (i < args.len) : (i += 2) {
                var lower: [24]u8 = undefined;
                if (!keys.has(try keyword(args, i, &lower))) return error.InvalidAnalysisArguments;
            }
            const node = try outputNode(node_id);
            const neg = try outputNeg(node_neg);
            if (id == .dcsens) return .{ .dcsens = .{ .output_node = node, .output_neg = neg, .variations = ctx.variations } };
            return .{ .acmatch = .{ .sweep = ctx.ac orelse return error.MissingAnalysisCard, .output_node = node, .output_neg = neg, .variations = ctx.variations } };
        },
        .four => {
            try arity(args, 2, 3);
            return .{ .four = .{
                .f_fundamental = try positive(args, 0),
                .output_node = try outputNode(node_id),
                .n_harmonics = try count(u16, args, 2, 9),
                .label = if (a.split) try outputLabel(ctx.arena, args[1]) else "",
            } };
        },
        .fft => return .{ .fft = try fft(ctx, args, node_id, node_neg) },
        .pz => {
            // Bare `.pz` asks for the circuit's own poles and names no transfer.
            if (args.len == 0) return .{ .pz = .{} };
            // HSPICE `.pz v(out[,ref]) src` [CR .PZ]: the input is the
            // source's own node pair, `vol` for a V card and `cur` for an I
            // card; poles and zeros both.
            if (args.len == 2) {
                if (currentProbeName(args, 0) != null) return error.UnsupportedAnalysisOutput;
                var opts: requests.Pz = .{ .out_pos = try outputNode(node_id), .out_neg = try outputNeg(node_neg), .want = .both };
                const name = nameAt(args, 1) orelse return error.InvalidAnalysisArguments;
                if (netlist.nameIndex(sources.v_names, name)) |v| {
                    opts.in_pos = sources.v_pos[v];
                    opts.in_neg = sources.v_neg[v];
                    opts.drive_branch = sources.v_branches[v];
                } else if (netlist.nameIndex(sources.i_names, name)) |v| {
                    opts.in_pos = sources.i_pos[v];
                    opts.in_neg = sources.i_neg[v];
                } else return error.AnalysisSourceNotFound;
                // The drive's node pair is unordered for poles and zeros;
                // keep the grounded side second, as the SPICE form must.
                if (opts.in_pos == GROUND) std.mem.swap(u32, &opts.in_pos, &opts.in_neg);
                _ = try outputNode(opts.in_pos);
                return .{ .pz = opts };
            }
            try arity(args, 6, 6);
            const drive_kind = std.StaticStringMap(enum { vol, cur })
                .initComptime(.{ .{ "vol", .vol }, .{ "cur", .cur } });
            const wanted = std.StaticStringMap(requests.Pz.Want)
                .initComptime(.{ .{ "pol", .poles }, .{ "zer", .zeros }, .{ "pz", .both } });
            var lower: [4]u8 = undefined;
            const kind = drive_kind.get(try keyword(args, 4, &lower)) orelse return error.InvalidAnalysisArguments;
            const want = wanted.get(try keyword(args, 5, &lower)) orelse return error.InvalidAnalysisArguments;
            var opts: requests.Pz = .{
                .in_pos = try outputNode(ports[0]),
                .in_neg = try outputNeg(ports[1]),
                .out_pos = try outputNode(ports[2]),
                .out_neg = try outputNeg(ports[3]),
                .want = want,
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
            if (a.sn) return .{ .pss = try shootingNewton(args) };
            // `.pss v(osc) f [n [settle]]` (HSPICE `.snosc`) solves an
            // oscillator: f is the first guess and osc the phase node.
            const osc = args.len != 0 and args[0] == .group;
            const at: usize = @intFromBool(osc);
            try arity(args, at + 1, at + @as(usize, if (osc) 3 else 2));
            var opts: requests.Pss = .{ .period = 1 / try positive(args, at), .n_samples = try count(u32, args, at + 1, 256) };
            if (osc) {
                opts.osc_node = try outputNode(node_id);
                opts.osc_settle_periods = try count(u16, args, at + 2, 30);
            }
            return .{ .pss = opts };
        },
        .hb => {
            // HB drives from whatever sources the deck has, current ones
            // included, so it names none. `.hb v(osc) f [K]` (HSPICE
            // `.hbosc`) solves an oscillator from the first guess f.
            const osc = args.len != 0 and args[0] == .group;
            const at: usize = @intFromBool(osc);
            try arity(args, at + 1, at + 2);
            return .{ .hb = .{
                .f0 = try positive(args, at),
                .n_harmonics = try count(u16, args, at + 1, 8),
                .osc_node = if (osc) try outputNode(node_id) else GROUND,
            } };
        },
        .qpss => {
            // Like HB, QPSS drives from every source the deck stamps.
            try arity(args, 2, 4);
            return .{ .qpss = .{ .f1 = try positive(args, 0), .f2 = try positive(args, 1), .k1 = try count(u16, args, 2, 5), .k2 = try count(u16, args, 3, 5) } };
        },
        .hbac, .hbxf, .hbnoise => {
            // `.hbac sweep`, `.hbxf v(out) sweep` and
            // `.hbnoise v(out[,ref]) [Vsrc] sweep`, each optionally followed
            // by `f0 [K]` (`.hbnoise`: `f0 [K [M]]`). Without f0, `queries`
            // fills the tone from the deck's `.hb` card, as HSPICE does.
            var at: usize = @intFromBool(id != .hbac);
            // As in `.pnoise`, the input source is checked but does not
            // drive the solve.
            if (id == .hbnoise and nameAt(args, at) != null and std.meta.isError(frequencySweep(args, at))) {
                _ = try voltageSource(args, at, sources);
                at += 1;
            }
            const grid = try frequencySweep(args, at);
            at += 4;
            try arity(args, at, at + @as(usize, if (id == .hbnoise) 3 else 2));
            if (id != .hbnoise and node_neg != NO_NODE) return error.InvalidAnalysisArguments;
            var opts: requests.HbLptv = .{ .f0 = 0, .sweep = grid, .out_node = try outputNode(node_id), .out_neg = try outputNeg(node_neg) };
            if (at < args.len) {
                opts.f0 = try positive(args, at);
                opts.n_harmonics = try count(u16, args, at + 1, 8);
                opts.n_sidebands = opts.n_harmonics;
                if (at + 2 < args.len) {
                    const m = try number(args, at + 2);
                    if (m < 0 or m != @trunc(m) or m > 31) return error.InvalidAnalysisArguments;
                    opts.n_sidebands = @intFromFloat(m);
                }
            }
            return switch (id) {
                .hbac => .{ .hbac = opts },
                .hbxf => .{ .hbxf = opts },
                else => .{ .hbnoise = opts },
            };
        },
        .phasenoise => {
            // `.phasenoise v(out) sweep [f0 [K]]`: without f0 the oscillator
            // is the deck's `.hbosc`; with it, v(out) is the phase node.
            const out = try outputNode(node_id);
            const grid = try frequencySweep(args, 1);
            try arity(args, 5, 7);
            if (args.len == 5) return .{ .phasenoise = .{ .f0 = 0, .osc_node = out, .sweep = grid } };
            return .{ .phasenoise = .{ .f0 = try positive(args, 5), .n_harmonics = try count(u16, args, 6, 8), .osc_node = out, .sweep = grid } };
        },
        .pac, .pxf => {
            // HSPICE `.snac <sweep>` and `.snxf v(out) <sweep>` [CR .SNAC,
            // .SNXF] run at the `.sn` fundamental.
            if (a.sn) {
                const lo = ctx.sn_f0 orelse return error.MissingAnalysisCard;
                const first: usize = @intFromBool(id == .pxf);
                const grid = try acGrid(ctx.arena, args, first);
                if (grid.end != args.len) return error.InvalidAnalysisArguments;
                const opts: requests.Pac = .{ .f_lo = lo, .sweep = grid.sweep, .out_node = try outputNode(node_id) };
                return if (id == .pac) .{ .pac = opts } else .{ .pxf = opts };
            }
            try arity(args, 5, 5);
            const sweep = try frequencySweep(args, 1);
            const lo = try positive(args, 0);
            const out = try outputNode(node_id);
            if (id == .pac) return .{ .pac = .{ .f_lo = lo, .sweep = sweep, .out_node = out } };
            return .{ .pxf = .{ .f_lo = lo, .sweep = sweep, .out_node = out } };
        },
        .sp => {
            if (isLin(a.line)) return .{ .sp = .{ .sweep = ctx.ac orelse return error.MissingAnalysisCard, .ports = sources.ports, .lin = try lin(args) } };
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
        .lstb => return .{ .lstb = try lstbJob(args, sources) },
        .dcxf => {
            try arity(args, 1, 2);
            return .{ .dcxf = try xfOutput(requests.Dcxf, args, node_id, node_neg, sources) };
        },
        .acxf => {
            try arity(args, 5, 6);
            return .{ .acxf = try xfOutput(requests.Acxf, args, node_id, node_neg, sources) };
        },
        .dcinc => {
            try arity(args, 0, 0);
            return .{ .dcinc = .{} };
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
