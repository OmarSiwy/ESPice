//! The HSPICE reference adapter, and the deck gate it shares with
//! spectre.zig. Both run the SPICE deck itself (HSPICE natively, Spectre
//! through its SPICE reader), so the work is deciding which decks mean the
//! same thing there, and reading the answers back.
//!
//! The rule is vacask.zig's, translate or refuse. An HSPICE-dialect fixture
//! is passed as-is apart from the cards below. An ngspice-dialect fixture
//! passes only if every card is on a list whose meaning matches in both
//! simulators; anything else refuses the deck by name. A deck that writes
//! one output per sweep point (`.alter`, `.data`, a `.temp` list, a nested
//! `.dc`) or runs an analysis other than `.op`, `.dc`, `.ac` and `.tran` is
//! refused in either dialect: there is no waveform to compare.
//!
//! Cards the gate adds before `.end`, each only where the deck sets none:
//! `.option tnom` and `.temp` at the dialect's defaults (ngspice 27/27,
//! HSPICE 25/TNOM, which is what ESPice applies), and, unless the runner
//! is told otherwise, ESPice's tolerances `reltol=1e-3 abstol=1e-12
//! vntol=1e-6`. ngspice's `.save v(x)` becomes `.probe v(x)` with `.option
//! probe`, so the vendor tool writes the same signals; the `.probe` goes
//! last because HSPICE ignores one that comes before every analysis. HSPICE
//! also gets `.option post=2`, its ASCII waveform format.
const std = @import("std");
const common = @import("job.zig");
const compare = @import("compare.zig");
const vacask = @import("vacask.zig");
pub const version_flag = "-v";

/// Which simulator a deck is staged for.
pub const Tool = enum { hspice, spectre };

/// A deck staged for a vendor simulator: the text it runs, or why not.
pub const Staged = union(enum) {
    deck: struct { text: []const u8, op: bool },
    refused: []const u8,
};

/// Copies `netlist` into `scratch`/deck.sp through `stage` and returns the
/// job that runs it there. Each run writes `hspice.lis` and the waveform
/// files beside it.
pub fn prepare(io: std.Io, a: std.mem.Allocator, bin: []const u8, args: []const []const u8, netlist: []const u8, scratch: []const u8, hspice_dialect: bool, match_tol: bool) common.Error!common.Job {
    const staged = try stageFile(io, a, netlist, scratch, .hspice, hspice_dialect, match_tol);
    if (staged == .refused) return .{ .refused = staged.refused };
    return .{
        .argv = try std.mem.concat(a, []const u8, &.{ &.{bin}, args, &.{ "-i", "deck.sp", "-o", "hspice" } }),
        .cwd = .{ .path = scratch },
        .reader = .hspice,
        .op = staged.deck.op,
    };
}

/// `stage` from file to file, shared with spectre.zig.
pub fn stageFile(io: std.Io, a: std.mem.Allocator, netlist: []const u8, scratch: []const u8, tool: Tool, hspice_dialect: bool, match_tol: bool) common.Error!Staged {
    const text = std.Io.Dir.cwd().readFileAlloc(io, netlist, a, .limited(1 << 28)) catch return error.DeckFailed;
    const staged = try stage(a, text, tool, hspice_dialect, match_tol);
    if (staged == .refused) return staged;
    std.Io.Dir.cwd().createDirPath(io, scratch) catch return error.ScratchFailed;
    const path = try std.fmt.allocPrint(a, "{s}/deck.sp", .{scratch});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = staged.deck.text }) catch return error.DeckFailed;
    return staged;
}

/// Cards whose meaning and output match in ngspice, HSPICE and Spectre's
/// SPICE reader. An ngspice-dialect deck with any other card is refused.
const checked_cards = std.StaticStringMap(void).initComptime(.{
    .{"op"},      .{"dc"},    .{"ac"},     .{"tran"},  .{"end"},   .{"ends"},
    .{"subckt"},  .{"model"}, .{"param"},  .{"option"}, .{"options"}, .{"opt"},
    .{"ic"},      .{"nodeset"}, .{"global"}, .{"temp"}, .{"print"}, .{"plot"},
    .{"probe"},   .{"meas"},  .{"measure"}, .{"four"}, .{"width"}, .{"title"},
    .{"save"},
});

/// HSPICE's own spellings and output-only cards, accepted in an HSPICE-dialect
/// deck on top of `checked_cards`.
const hspice_cards = std.StaticStringMap(void).initComptime(.{
    .{"macro"},   .{"eom"},       .{"parameter"}, .{"parameters"}, .{"temperature"},
    .{"connect"}, .{"protect"},   .{"unprotect"}, .{"prot"},       .{"unprot"},
    .{"dcvolt"},  .{"check"},     .{"biaschk"},   .{"power"},
});

/// ngspice device letters with the same card syntax and model in HSPICE and
/// Spectre's SPICE reader. B, S, W, A, U, O, Z, P, N, Y are not among them.
const checked_devices = "rclkviefghdqjmxt";

/// Builds the vendor deck from `spice`, or names the card that refuses it.
pub fn stage(a: std.mem.Allocator, spice: []const u8, tool: Tool, hspice_dialect: bool, match_tol: bool) error{OutOfMemory}!Staged {
    var title: []const u8 = "";
    var cards: std.ArrayList(vacask.Card) = .empty;
    try vacask.lex(a, spice, &title, &cards);

    var op = false;
    var analyses: usize = 0;
    var temp = false;
    var tnom: ?[]const u8 = null;
    var saves = false;
    // reltol, abstol, vntol, by their SPICE or HSPICE names.
    var tol_set: [3]bool = @splat(false);
    for (cards.items) |c| {
        const kw = c.tok(0).?;
        if (kw[0] != '.') {
            if (!hspice_dialect and std.mem.indexOfScalar(u8, checked_devices, kw[0]) == null)
                return refuse(a, "'{c}' device {s} has no counterpart checked for {t}", .{ kw[0], kw, tool });
            if (tool == .spectre and shortPulse(c)) return refuse(a, "{s}: a PULSE without all seven values; Spectre's SPICE reader defaults TR/TF/PW/PER differently", .{kw});
            continue;
        }
        const name = kw[1..];
        if (!checked_cards.has(name) and !(hspice_dialect and hspice_cards.has(name)))
            return refuse(a, "{s} is not a card this adapter checks or reads back", .{kw});
        if (eql(name, "op")) op = true;
        if (eql(name, "op") or eql(name, "dc") or eql(name, "ac") or eql(name, "tran")) analyses += 1;
        if (eql(name, "dc") and !singleSweep(c)) return refuse(a, ".dc with more than one sweep writes one output per outer point", .{});
        for (c.fields[1..]) |f| if (eql(f, "sweep") or std.mem.startsWith(u8, f, "monte") or std.mem.startsWith(u8, f, "data="))
            return refuse(a, "{s} {s} writes one output per sweep point", .{ kw, f });
        if (eql(name, "temp") or eql(name, "temperature")) {
            if (c.fields.len > 2) return refuse(a, "a .temp list writes one output per temperature", .{});
            temp = true;
        }
        if (eql(name, "save")) {
            // `.save v(a) i(v1)` lexes as `v a i v1`; anything else (`all`,
            // `@m1[id]`, `v(a,b)`) has no `.probe` twin here.
            const args = c.fields[1..];
            if (args.len == 0 or args.len % 2 != 0) return refuse(a, ".save other than v(node)/i(source) lists", .{});
            for (0..args.len / 2) |i| if (!eql(args[2 * i], "v") and !eql(args[2 * i], "i"))
                return refuse(a, ".save other than v(node)/i(source) lists", .{});
            saves = true;
        }
        if (eql(name, "model") and !hspice_dialect) if (modelRefusal(c)) |why| return refuse(a, "{s}", .{why});
        if (eql(name, "option") or eql(name, "options") or eql(name, "opt")) for (c.fields[1..]) |f| {
            const cut = std.mem.indexOfScalar(u8, f, '=') orelse f.len;
            const key = f[0..cut];
            if (eql(key, "temp")) temp = true;
            if (eql(key, "tnom") and cut < f.len) tnom = f[cut + 1 ..];
            for ([_][2][]const u8{ .{ "reltol", "relv" }, .{ "abstol", "absi" }, .{ "vntol", "absv" } }, &tol_set) |names, *set| {
                if (eql(key, names[0]) or eql(key, names[1])) set.* = true;
            }
        };
    }
    if (analyses == 0) return refuse(a, "no .op, .dc, .ac or .tran to compare", .{});

    // `.save` lines become comments, and their signals one `.probe` here.
    var probes: std.ArrayList(u8) = .empty;
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, spice, '\n');
    var first = true;
    var in_save = false;
    var end: ?usize = null;
    while (lines.next()) |line| {
        const body = std.mem.trimStart(u8, line, " \t");
        const word = body[0 .. std.mem.indexOfAny(u8, body, " \t\r") orelse body.len];
        if (!first and end == null and eql(word, ".end")) end = out.items.len;
        in_save = !first and (eql(word, ".save") or (in_save and body.len > 0 and body[0] == '+'));
        if (in_save) {
            try probes.appendSlice(a, std.mem.trimEnd(u8, body[if (body[0] == '+') 1 else word.len..], "\r"));
            try out.appendSlice(a, "* ");
        }
        try out.appendSlice(a, line);
        if (lines.peek() != null) try out.append(a, '\n');
        first = false;
    }

    var added: std.ArrayList(u8) = .empty;
    if (tool == .hspice) try added.print(a, ".option post=2\n", .{});
    if (saves) try added.print(a, ".option probe\n.probe{s}\n", .{probes.items});
    const default: []const u8 = if (hspice_dialect) "25" else "27";
    if (tnom == null) try added.print(a, ".option tnom={s}\n", .{default});
    // HSPICE runs at TNOM when no temperature is given; ngspice at 27.
    if (!temp) try added.print(a, ".temp {s}\n", .{if (hspice_dialect) tnom orelse default else default});
    if (match_tol) for ([_][]const u8{ "reltol=1e-3", "abstol=1e-12", "vntol=1e-6" }, tol_set) |option, set| {
        if (!set) try added.print(a, ".option {s}\n", .{option});
    };

    // Everything else stays byte for byte; the additions go before the
    // first `.end`, since anything after it is ignored.
    if (end) |at| {
        try out.insertSlice(a, at, added.items);
    } else {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
        try out.appendSlice(a, added.items);
    }
    return .{ .deck = .{ .text = out.items, .op = op } };
}

fn refuse(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!Staged {
    return .{ .refused = try std.fmt.allocPrint(a, fmt, args) };
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.ascii.eqlIgnoreCase(x, y);
}

/// `.dc VAR START STOP STEP`, `.dc VAR LIN|DEC|OCT N START STOP` or
/// `.dc VAR POI N V1 ... VN`, with nothing after it.
fn singleSweep(c: vacask.Card) bool {
    const n = c.fields.len;
    if (n < 5) return false;
    const kind = c.fields[2];
    if (eql(kind, "lin") or eql(kind, "dec") or eql(kind, "oct")) return n == 6;
    if (eql(kind, "poi")) {
        const points = std.fmt.parseInt(usize, c.fields[3], 10) catch return false;
        return n == 4 + points;
    }
    return n == 5;
}

/// Whether a source's PULSE leaves any of V1 V2 TD TR TF PW PER to the
/// simulator. SPICE and HSPICE take TR/TF from TSTEP; Spectre's SPICE reader
/// does not (measured: an RC deck's edge took about TSTOP/100).
fn shortPulse(c: vacask.Card) bool {
    for (c.fields, 0..) |f, i| if (eql(f, "pulse")) {
        var n: usize = 0;
        for (c.fields[i + 1 ..]) |v| {
            if (eql(v, "ac") or eql(v, "dc")) break;
            n += 1;
        }
        return n < 7;
    };
    return false;
}

/// Why an ngspice `.model` card means something else in HSPICE or Spectre,
/// or null. The two number their model levels differently past the SPICE3
/// ones; ngspice's BSIM3 and BSIM4 levels 49 and 54 are HSPICE's too.
fn modelRefusal(c: vacask.Card) ?[]const u8 {
    const kind = c.tok(2) orelse return "a .model card with no type";
    var level: f64 = 1;
    for (c.fields[3..]) |f| if (std.mem.startsWith(u8, f, "level=")) {
        level = vacask.parseSpice(f["level=".len..]) orelse return "a .model LEVEL that is not a number";
    };
    const passive = eql(kind, "r") or eql(kind, "c") or eql(kind, "l") or eql(kind, "res") or eql(kind, "cap");
    const level_one = eql(kind, "d") or eql(kind, "npn") or eql(kind, "pnp") or eql(kind, "njf") or eql(kind, "pjf");
    if (passive) return null;
    if (level_one) return if (level == 1) null else "a diode, BJT or JFET model past LEVEL 1, numbered differently there";
    if (eql(kind, "nmos") or eql(kind, "pmos")) return switch (@as(u32, @intFromFloat(@max(0, @min(level, 1e6))))) {
        1, 2, 3, 49, 54 => null,
        else => "a MOSFET LEVEL other than 1, 2, 3, 49 (BSIM3) or 54 (BSIM4), numbered differently there", // else: every other LEVEL refuses
    };
    return "a .model type with no counterpart checked here";
}

/// Every plot of a finished run in `dir`: the `post=2` waveform files, and
/// the operating point HSPICE saves in `hspice.ic0` when the deck asked for
/// one.
pub fn readPlots(io: std.Io, a: std.mem.Allocator, dir: []const u8, op: bool) ![]const compare.Plot {
    var plots: std.ArrayList(compare.Plot) = .empty;
    for ([_][2][]const u8{ .{ "tr0", "Transient Analysis" }, .{ "ac0", "AC Analysis" }, .{ "sw0", "DC transfer characteristic" } }) |kind| {
        const path = try std.fmt.allocPrint(a, "{s}/hspice.{s}", .{ dir, kind[0] });
        const blob = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err, // else: any other read error fails the deck
        };
        try plots.append(a, try parseWaveform(a, blob, kind[1]));
    }
    if (op) {
        const path = try std.fmt.allocPrint(a, "{s}/hspice.ic0", .{dir});
        try plots.append(a, try parseIc0(a, try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited)));
    }
    if (plots.items.len == 0) return error.MissingOutput;
    return plots.items;
}

/// One `post=2` ASCII waveform file. The header ends at `$&%#`: its first
/// eight columns count the variables, and its last tokens are the sweep
/// count, then each variable's type code, then each name. Values follow as
/// `0.1234567E+01` with no separator; a scale value of 1e30 or more ends the
/// data. An AC file holds (re, im) for every variable but the scale.
fn parseWaveform(a: std.mem.Allocator, blob: []const u8, plotname: []const u8) !compare.Plot {
    const end = std.mem.indexOf(u8, blob, "$&%#") orelse return error.InvalidWaveform;
    if (end < 8) return error.InvalidWaveform;
    const nvars = try std.fmt.parseInt(usize, blob[0..4], 10) + try std.fmt.parseInt(usize, blob[4..8], 10);
    var tokens: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, blob[0..end], " \t\r\n");
    while (it.next()) |t| try tokens.append(a, t);
    if (nvars == 0 or tokens.items.len < 2 * nvars + 1) return error.InvalidWaveform;
    const tail = tokens.items[tokens.items.len - 2 * nvars - 1 ..];
    if (!std.mem.eql(u8, tail[0], "0")) return error.SweptWaveform; // the stage refuses these
    const complex = std.mem.eql(u8, plotname, "AC Analysis");

    // Ground (`v(0`) is dropped: nothing else writes it.
    var names: std.ArrayList([]const u8) = .empty;
    var keep: std.ArrayList(bool) = .empty;
    for (tail[1 + nvars ..], 0..) |raw, i| {
        const lower = try std.ascii.allocLowerString(a, raw);
        const name = if (i == 0)
            (if (complex) "frequency" else if (std.mem.eql(u8, plotname, "Transient Analysis")) "time" else "v(v-sweep)")
        else if ((std.mem.startsWith(u8, lower, "v(") or std.mem.startsWith(u8, lower, "i(")) and lower[lower.len - 1] != ')')
            try std.fmt.allocPrint(a, "{s})", .{lower})
        else
            lower;
        const ground = std.mem.eql(u8, name, "v(0)");
        try keep.append(a, !ground);
        if (!ground) try names.append(a, name);
    }

    var values = std.mem.tokenizeAny(u8, blob[end + 4 ..], " \t\r\n");
    var stream: Fixed = .{ .rest = "" };
    var data: std.ArrayList(f64) = .empty;
    var npoints: usize = 0;
    points: while (true) {
        for (keep.items, 0..) |kept, i| {
            const parts: usize = if (complex and i > 0) 2 else 1;
            for (0..parts) |_| {
                const v = stream.next(&values) orelse return error.TruncatedWaveform;
                if (i == 0 and v >= 1e30) break :points;
                if (kept) try data.append(a, v);
            }
            if (complex and i == 0) try data.append(a, 0); // the scale is real
        }
        npoints += 1;
    }
    return .{ .plotname = plotname, .varnames = names.items, .is_complex = complex, .npoints = npoints, .nvars = names.items.len, .data = data.items };
}

/// Splits HSPICE's run-together `0.1000000E+01-.5000000E-03` values: each
/// ends two digits after the sign that follows its `E`.
const Fixed = struct {
    rest: []const u8,

    fn next(f: *Fixed, lines: *std.mem.TokenIterator(u8, .any)) ?f64 {
        if (f.rest.len == 0) f.rest = lines.next() orelse return null;
        const e = std.mem.indexOfAny(u8, f.rest, "Ee") orelse return null;
        const len = @min(e + 4, f.rest.len);
        defer f.rest = f.rest[len..];
        return std.fmt.parseFloat(f64, f.rest[0..len]) catch null;
    }
};

/// The `.nodeset` block of `hspice.ic0` as an operating-point plot:
/// `+ NODE = VALUE` lines with engineering suffixes, node voltages only.
fn parseIc0(a: std.mem.Allocator, blob: []const u8) !compare.Plot {
    const start = std.mem.indexOf(u8, blob, ".nodeset") orelse return error.InvalidIc0;
    var names: std.ArrayList([]const u8) = .empty;
    var data: std.ArrayList(f64) = .empty;
    var lines = std.mem.splitScalar(u8, blob[start..], '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        const body = std.mem.trim(u8, line, " \t\r");
        if (body.len == 0 or body[0] != '+') break;
        const eq = std.mem.indexOfScalar(u8, body, '=') orelse return error.InvalidIc0;
        const node = std.mem.trim(u8, body[1..eq], " \t");
        try names.append(a, try std.fmt.allocPrint(a, "v({s})", .{try std.ascii.allocLowerString(a, node)}));
        try data.append(a, vacask.parseSpice(std.mem.trim(u8, body[eq + 1 ..], " \t")) orelse return error.InvalidIc0);
    }
    return .{ .plotname = "Operating Point", .varnames = names.items, .is_complex = false, .npoints = 1, .nvars = names.items.len, .data = data.items };
}

/// HSPICE's own account of the run in `dir`, from `hspice.lis`: total
/// elapsed time less license checkout, and the sum of the per-analysis rows
/// of its runtime statistics (10 ms resolution).
pub fn reported(io: std.Io, a: std.mem.Allocator, dir: []const u8) !common.Reported {
    const path = try std.fmt.allocPrint(a, "{s}/hspice.lis", .{dir});
    return parseLis(try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 28)));
}

fn parseLis(lis: []const u8) !common.Reported {
    const elapsed = numberAfter(lis, "total elapsed time") orelse return error.MissingTiming;
    const license = numberAfter(lis, "license checkout elapse time:") orelse 0;
    const table = std.mem.indexOf(u8, lis, "Runtime Statistics") orelse return error.MissingTiming;
    var lines = std.mem.splitScalar(u8, lis[table..], '\n');
    _ = lines.next();
    var analysis: f64 = 0;
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = words.next() orelse continue;
        if (eql(first, "analysis")) continue; // the column header
        if (eql(first, "readin")) break; // setup rows follow the analyses
        while (words.next()) |word| if (std.fmt.parseFloat(f64, word)) |seconds| {
            analysis += seconds;
            break;
        } else |_| {};
    }
    return .{ .run_ms = (elapsed - license) * 1e3, .analysis_ms = analysis * 1e3 };
}

/// The first number after `label`, stopping at a `(` unit.
fn numberAfter(text: []const u8, label: []const u8) ?f64 {
    const at = std.mem.indexOf(u8, text, label) orelse return null;
    var words = std.mem.tokenizeAny(u8, text[at + label.len ..], " \t\r\n(");
    return std.fmt.parseFloat(f64, words.next() orelse return null) catch null;
}

test "an ngspice deck gains HSPICE's output option and ngspice's defaults before .end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const staged = try stage(arena.allocator(), "rc\nv1 in 0 1\nr1 in out 1k\n.save v(out)\n+ i(v1)\n.tran 1u 1m\n.end\n", .hspice, false, true);
    try std.testing.expectEqualStrings(
        "rc\nv1 in 0 1\nr1 in out 1k\n* .save v(out)\n* + i(v1)\n.tran 1u 1m\n" ++
            ".option post=2\n.option probe\n.probe v(out) i(v1)\n.option tnom=27\n.temp 27\n.option reltol=1e-3\n.option abstol=1e-12\n.option vntol=1e-6\n.end\n",
        staged.deck.text,
    );
    try std.testing.expect(!staged.deck.op);
}

test "an HSPICE deck keeps its own settings and runs at its TNOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const staged = try stage(arena.allocator(), "t\n.option tnom = 30 absv=1u\nw1 a 0 b 0 n=1\n.op\n", .spectre, true, true);
    try std.testing.expectEqualStrings("t\n.option tnom = 30 absv=1u\nw1 a 0 b 0 n=1\n.op\n.temp 30\n.option reltol=1e-3\n.option abstol=1e-12\n", staged.deck.text);
    try std.testing.expect(staged.deck.op);
}

test "the gate refuses what would not mean the same thing, by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{
        "t\nb1 a 0 v=1\n.op\n", // ngspice B source
        "t\n.model m nmos level=8\n.op\n", // BSIM3 is 49 in HSPICE
        "t\n.model d1 d level=3\n.op\n",
        "t\n.noise v(out) v1 dec 10 1 1k\n",
        "t\n.dc v1 0 1 0.1 v2 0 1 0.5\n",
        "t\n.temp 0 27 50\n.op\n",
        "t\n.save all\n.op\n",
        "t\n.include models.lib\n.op\n",
        "t\n.tran 1n 1u sweep r 1 2 1\n",
        "t\nr1 a 0 1\n", // nothing to compare
    }) |deck| try std.testing.expect((try stage(a, deck, .hspice, false, true)) == .refused);
    const short = "t\nv1 1 0 pulse (0 1) ac 1\n.tran 0.1 7\n";
    try std.testing.expect((try stage(a, short, .spectre, false, true)) == .refused);
    try std.testing.expect((try stage(a, short, .hspice, false, true)) == .deck);
    try std.testing.expect((try stage(a, "t\nv1 1 0 pulse(0 1 0 1n 1n 5u 10u) ac 1\n.tran 1n 1u\n", .spectre, false, true)) == .deck);
    try std.testing.expect((try stage(a, "t\n.model m nmos level=54\n.dc v1 lin 3 0 1\n", .hspice, false, false)) == .deck);
    try std.testing.expect((try stage(a, "t\n.dc v1 poi 3 0 0.5 1\n", .hspice, false, false)) == .deck);
}

test "a post=2 waveform reads by column name, without ground" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Verbatim layout of an HSPICE V-2023.12 `.tr0` (RC, two points).
    const tr0 = "000400000000000000002001* rc\n        10/17/2026      17:06:26 Copyright\n Rights Reserved.          0\n" ++
        "                          1       1       1       8     TIME\nv(0             v(out           i(v1            $&%#\n" ++
        "0.0000000E+000.0000000E+000.0000000E+000.0000000E+000.1000000E-05\n0.0000000E+000.5000000E+00-.5000000E-030.1000000E+31\n";
    const p = try parseWaveform(a, tr0, "Transient Analysis");
    try std.testing.expectEqual(@as(usize, 2), p.npoints);
    try std.testing.expectEqualStrings("time", p.varnames[0]);
    try std.testing.expectEqualStrings("v(out)", p.varnames[1]);
    try std.testing.expectEqualStrings("i(v1)", p.varnames[2]);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0, 1e-6, 0.5, -5e-4 }, p.data);
    try std.testing.expectError(error.TruncatedWaveform, parseWaveform(a, tr0[0 .. tr0.len - 15], "Transient Analysis"));

    const ic0 = "*** BEGIN\n.option\n+ gmindc=   1.0000p\n.nodeset\n+ in =   1.0000\n+ out =   500.0000m\n***   END\n";
    const op = try parseIc0(a, ic0);
    try std.testing.expectEqualStrings("v(out)", op.varnames[1]);
    try std.testing.expectEqualSlices(f64, &.{ 1, 0.5 }, op.data);
}

test "the listing's runtime statistics give the run and analysis times" {
    const lis =
        \\  ******  Runtime Statistics (seconds)  ******
        \\
        \\  analysis           time    # points   tot. iter  conv.iter
        \\  op point           0.01           1           1
        \\  transient          0.20       10001         882         441 rev=        20
        \\  readin             0.01
        \\           total elapsed time        0.55 seconds
        \\ lic: total license checkout elapse time:        0.37(s)
    ;
    const r = try parseLis(lis);
    try std.testing.expectApproxEqAbs(@as(f64, 180), r.run_ms, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 210), r.analysis_ms, 1e-9);
}
