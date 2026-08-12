//! Fuzz targets for `netlist.parse`: Smith bytes → a deck → `Netlist` or a
//! declared `netlist.Error`. The oracle is the test runner's: no panic, no
//! leak, no error outside the set. Two input modes: raw bytes, and decks
//! built card by card from `templates`, so most inputs reach past the
//! tokenizer. `fuzz_corpus/` holds the seed decks and every input a fuzz run
//! found; plain `zig build test` replays it.
const std = @import("std");
const netlist = @import("../netlist.zig");
const Smith = std.testing.Smith;
const Dialect = netlist.Dialect;

/// Generated decks stop growing past this many bytes.
const deck_max = 1 << 14;
/// Cards per generated deck.
const cards_max = 64;
/// Expression nesting the generator recurses through; deeper parentheses
/// come from the `(`-run atom instead, which reaches `expr.max_depth`.
const expr_depth_max = 4;

/// The oracle: parse in a fresh arena; a declared error is a pass.
fn check(gpa: std.mem.Allocator, src: []const u8, dialect: Dialect) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = netlist.parse(arena.allocator(), src, dialect) catch |err| switch (err) {
        error.OutOfMemory, error.ParseError, error.ModelBinNotFound, error.CircuitTooLarge, error.UnsupportedCard => {},
    };
}

fn rawBytes(_: void, s: *Smith) anyerror!void {
    const dialect = s.value(Dialect);
    var buf: [deck_max]u8 = undefined;
    check(std.testing.allocator, buf[0..s.slice(&buf)], dialect);
}

fn structured(_: void, s: *Smith) anyerror!void {
    var buf: [deck_max]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const dialect = deck(s, &w);
    check(std.testing.allocator, w.buffered(), dialect);
}

/// One raw-mode corpus entry: what `rawBytes` reads back as `dialect`, `text`.
fn raw(comptime dialect: Dialect, comptime text: []const u8) []const u8 {
    return std.mem.toBytes(@as(u64, @backingInt(dialect))) ++ std.mem.toBytes(std.mem.nativeToLittle(u32, text.len)) ++ text;
}

const seeds = [_][]const u8{
    @embedFile("fuzz_corpus/alter_cumulative.sp"),      @embedFile("fuzz_corpus/behavioural_sources.sp"),
    @embedFile("fuzz_corpus/bench_ngspice_schmitt.sp"), @embedFile("fuzz_corpus/data_sweep.sp"),
    @embedFile("fuzz_corpus/global_net.sp"),            @embedFile("fuzz_corpus/hspice_suffix.sp"),
    @embedFile("fuzz_corpus/meas_forms.sp"),            @embedFile("fuzz_corpus/monte_divider.sp"),
    @embedFile("fuzz_corpus/ngspice_syntax.sp"),        @embedFile("fuzz_corpus/param_distributions.sp"),
    @embedFile("fuzz_corpus/step_param_divider.sp"),    @embedFile("fuzz_corpus/subckt_params.sp"),
};

/// Every seed in every dialect.
const raw_corpus = blk: {
    var out: [seeds.len * 3][]const u8 = undefined;
    for (seeds, 0..) |text, i| {
        for (std.enums.values(Dialect), 0..) |d, k| out[i * 3 + k] = raw(d, text);
    }
    break :blk out;
};

test "fuzz netlist.parse: raw bytes" {
    std.testing.log_level = .err; // The parser warns per skipped card.
    try std.testing.fuzz({}, rawBytes, .{ .corpus = &raw_corpus });
}

test "fuzz netlist.parse: decks built from cards" {
    std.testing.log_level = .err;
    try std.testing.fuzz({}, structured, .{});
}

/// The structured generator driven by a seeded PRNG, so the merge gate runs
/// generated decks without `--fuzz` (it replays only the corpus).
const Seeded = struct {
    r: std.Random,

    pub fn index(self: *Seeded, len: usize) usize {
        return self.r.uintLessThan(usize, len);
    }

    pub fn eosWeightedSimple(self: *Seeded, false_weight: u64, true_weight: u64) bool {
        return self.r.uintLessThan(u64, false_weight + true_weight) < true_weight;
    }
};

test "netlist.parse survives 2000 seeded generated decks" {
    std.testing.log_level = .err;
    var prng: std.Random.DefaultPrng = .init(0x5eed_1ce);
    var src: Seeded = .{ .r = prng.random() };
    var buf: [deck_max]u8 = undefined;
    for (0..2000) |_| {
        var w: std.Io.Writer = .fixed(&buf);
        const dialect = deck(&src, &w);
        check(std.testing.allocator, w.buffered(), dialect);
    }
}

// The generator. `src` is a `*Smith` or a `*Seeded`. Writes past `deck_max`
// are dropped (`.fixed` refuses them), which only truncates the deck.

/// Card templates. Placeholders: `@` net, `?` value, `~` expression, `` ` ``
/// model name, `|` model type, `!` subcircuit name, `%` parameter name, `#`
/// instance suffix. Every other byte is copied. Most of these parse alone;
/// the blocks carry the definitions they use.
const templates = [_][]const u8{
    "R# @ @ ?",
    "C# @ @ ?",
    "L# @ @ ?",
    "R# @ @ ? tc1=? m=?",
    "V# @ @ dc ? ac ?",
    "V# @ @ pulse(? ? ? ? ? ? ?)",
    "V# @ @ sin(? ? ?)",
    "V# @ @ pwl(? ? ? ?)",
    "I# @ @ ?",
    "E# @ @ @ @ ?",
    "G# @ @ @ @ ?",
    "F# @ @ V# ?",
    "H# @ @ V# ?",
    "G# @ @ value={~}",
    "B# @ @ v={~}",
    "B# @ @ i=~",
    "D# @ @ `",
    "Q# @ @ @ `",
    "M# @ @ @ @ ` w=? l=?",
    "J# @ @ @ `",
    "K# L# L# ?",
    "T# @ @ @ @ z0=? td=?",
    "S# @ @ @ @ `",
    "W# @ @ V# `",
    "O# @ @ @ @ ` len=?",
    "Z# @ @ @ `",
    "A# @ @ `",
    "U# @ @ @ ` l=? n=?",
    "P# @ @",
    ".param %=?",
    ".param %={~} %=?",
    ".param %='~'",
    ".model ` | (%=? %=?)",
    ".model ` | %=?",
    ".model `.# | lmin=? lmax=? wmin=? wmax=?",
    ".op",
    ".tran ? ?",
    ".tran ? ? ? uic",
    ".ac dec ? ? ?",
    ".ac lin ? ? ?",
    ".dc V# ? ? ?",
    ".dc % ? ? ? V# ? ? ?",
    ".noise v(@) V# dec ? ? ?",
    ".tf v(@,@) V#",
    ".temp ?",
    ".ic v(@)=?",
    ".nodeset v(@)=?",
    ".options reltol=? gmin=?",
    ".option seed=?",
    ".save v(@) i(V#)",
    ".print tran v(@)",
    ".meas tran % max v(@)",
    ".meas ac % find v(@) at=?",
    ".meas tran % trig v(@) val=? rise=1 targ v(@) val=? fall=1",
    ".include \"x.inc\"",
    ".global @ @",
    ".endc",
    ".end",
    ".pss ? ?",
    ".hb ?",
    ".sp lin ? ? ?",
    ".four ? v(@)",
    ".sens v(@)",
    ".pz @ @ @ @ vol pz",
    ".mc ?",
    ".data %\n% %\n? ?\n? ?\n.enddata",
    ".hdl \"m.va\"",
    ".connect @ @",
    ".disto dec ? ? ?",
    ".pac dec ? ? ?",
    ".hbac dec ? ? ?",
    ".stb V#",
    ".variation\n%=?\n.end_variation",
    ".mosra reltotaltime=?",
    "* comment @ ?",
    "",
    "R# @ @ ? $ trailing",
    "R# @ @ ? ; trailing",
    "V# @ @ ? // slash",
    ".title %",
    ".subckt cell a b w=1\nR1 a b {w}\nC1 b 0 ?\n.ends cell\nX# @ @ cell w=?",
    ".subckt rc in out\nR1 in out ?\nC1 out 0 ?\n.ends\nX# @ @ rc",
    ".model nm nmos level=1 vto=?\nM# @ @ @ @ nm w=? l=?",
    ".model dn d is=? n=?\nD# @ @ dn",
    ".model qn npn bf=?\nQ# @ @ @ qn",
    ".param p=?\n.step param p 1 3 1",
    ".if (~)\nR# @ @ ?\n.else\nC# @ @ ?\n.endif",
    ".control\nrun\n.endc",
    ".lib tt\nR# @ @ ?\n.endl",
    "E# @ @ poly(1) @ @ ? ?",
    "X# @ @ cell",
};

/// Cards that fail out of context (an unclosed `.subckt`, a stray `.endif`,
/// an unsupported card), drawn one card in eight.
const fragments = [_][]const u8{
    "E# @ @ poly(2) @ @ @ @ ? ? ? ?",
    "X# @ @ !",
    "X# @ @ ! %=?",
    "X# @ ! %={~}",
    ".subckt ! @ @ %=?",
    ".subckt ! @",
    ".ends",
    ".ends !",
    ".step param % ? ? ?",
    ".step % list ? ? ?",
    ".if (~)",
    ".elseif (~)",
    ".else",
    ".endif",
    ".lib \"x.lib\" tt",
    ".lib tt",
    ".endl",
    ".func %(x) {~}",
    ".control",
    "run",
    ".alter",
    ".sample %=?",
    "+ %=?",
    "+ @",
    "title text",
};

const nets = [_][]const u8{ "0", "gnd", "in", "out", "n1", "n2", "a", "b", "vdd", "x1.n", "N1", "1" };
const atoms = [_][]const u8{ "1", "1k", "2.2u", "1e-9", "-3", "0", "1meg", "10n", "1.5e3k", "1e400", "-0", "1m", "5mil", "inf", "nan", "1.", ".5", "1e", "0x1f", "3db" };
const models = [_][]const u8{ "nm", "pm", "dn", "qn", "mod1", "nm.1" };
const types = [_][]const u8{ "nmos", "pmos", "d", "npn", "pnp", "r", "c", "njf", "sw", "ltra", "nmos level=54", "pmos level=8", "nmos level=1 version=4.8", "zz" };
const subckts = [_][]const u8{ "cell", "sub", "rc" };
const params = [_][]const u8{ "p", "w0", "k", "base", "r" };
const suffixes = [_][]const u8{ "1", "2", "x", "1a", "" };
const ops = [_][]const u8{ "+", "-", "*", "/", "**", "^", "<", ">=", "==", "!=", "&&", "||", "%" };
const funcs = [_][]const u8{ "sin", "exp", "sqrt", "abs", "log", "pow", "max", "min", "limit", "pwr", "agauss", "gauss", "if", "u" };

/// Writes a title line and up to `cards_max` cards; returns the dialect to
/// parse them in.
fn deck(src: anytype, w: *std.Io.Writer) Dialect {
    // The templates are SPICE syntax: Spectre gets one deck in eight.
    const dialect: Dialect = if (src.eosWeightedSimple(7, 1)) .spectre else if (src.eosWeightedSimple(1, 1)) .hspice else .ngspice;
    // Defines every name `params` holds, so a bare `%` value resolves.
    put(w, "fuzz deck\n.param p=1 w0=1u k=2 base=3 r=1k\n");
    for (0..cards_max) |_| {
        if (src.eosWeightedSimple(7, 1)) break;
        card(src, w, if (src.eosWeightedSimple(7, 1)) pick(src, &fragments) else pick(src, &templates));
        put(w, if (src.eosWeightedSimple(15, 1)) "\r\n" else "\n");
    }
    return dialect;
}

fn card(src: anytype, w: *std.Io.Writer, template: []const u8) void {
    for (template) |c| switch (c) {
        '@' => put(w, pick(src, &nets)),
        '?' => value(src, w),
        '~' => expression(src, w, 0),
        '`' => put(w, pick(src, &models)),
        '|' => put(w, pick(src, &types)),
        '!' => put(w, pick(src, &subckts)),
        '%' => put(w, pick(src, &params)),
        '#' => put(w, pick(src, &suffixes)),
        else => w.writeByte(c) catch {}, // else: a literal template byte
    };
}

fn value(src: anytype, w: *std.Io.Writer) void {
    switch (src.index(12)) {
        0...6 => put(w, pick(src, &atoms)),
        7, 8 => put(w, pick(src, &params)),
        9 => {
            put(w, "{");
            expression(src, w, 0);
            put(w, "}");
        },
        10 => {
            put(w, "'");
            expression(src, w, 0);
            put(w, "'");
        },
        else => { // else: the last index
            // A parenthesis run past `expr.max_depth`, balanced or not.
            const depth = src.index(700);
            put(w, "{");
            for (0..depth) |_| put(w, "(");
            put(w, "1");
            for (0..depth - src.index(depth + 1)) |_| put(w, ")");
            put(w, "}");
        },
    }
}

fn expression(src: anytype, w: *std.Io.Writer, depth: u8) void {
    std.debug.assert(depth <= expr_depth_max);
    const leaf = depth == expr_depth_max;
    switch (if (leaf) 0 else src.index(7)) {
        0 => switch (src.index(4)) {
            0 => put(w, pick(src, &atoms)),
            1 => put(w, pick(src, &params)),
            2 => {
                put(w, "v(");
                put(w, pick(src, &nets));
                put(w, ")");
            },
            else => put(w, pick(src, &.{ "i(V1)", "temper", "time", "hertz" })), // else: the last index
        },
        1 => {
            put(w, "(");
            expression(src, w, depth + 1);
            put(w, ")");
        },
        2, 3 => {
            expression(src, w, depth + 1);
            put(w, pick(src, &ops));
            expression(src, w, depth + 1);
        },
        4 => {
            put(w, "-");
            expression(src, w, depth + 1);
        },
        5 => {
            put(w, pick(src, &funcs));
            put(w, "(");
            expression(src, w, depth + 1);
            if (src.eosWeightedSimple(1, 1)) {
                put(w, ",");
                expression(src, w, depth + 1);
            }
            put(w, ")");
        },
        else => { // else: the last index
            expression(src, w, depth + 1);
            put(w, "?");
            expression(src, w, depth + 1);
            put(w, ":");
            expression(src, w, depth + 1);
        },
    }
}

fn pick(src: anytype, comptime list: []const []const u8) []const u8 {
    return list[src.index(list.len)];
}

fn put(w: *std.Io.Writer, bytes: []const u8) void {
    w.writeAll(bytes) catch {};
}
