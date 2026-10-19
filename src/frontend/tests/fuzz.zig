//! Fuzz targets for `netlist.parse`: Smith bytes → a deck → `Netlist` or a
//! declared `netlist.Error`. Two input modes: raw bytes, and decks built
//! card by card from `templates` and a generated subcircuit hierarchy, so
//! most inputs reach past the tokenizer. Oracles, cheapest first: no panic,
//! no leak, no error outside the set; the same digest on a second parse
//! (determinism); the same digest after a transform the grammar says
//! changes nothing (a comment line inserted, the deck uppercased, a card
//! split onto a `+` continuation); and an injected allocation failure that
//! surfaces as `OutOfMemory`, never as a panic or another error.
//! `fuzz_corpus/` holds the seed decks and every input a fuzz run found;
//! plain `zig build test` replays it.
const std = @import("std");
const netlist = @import("../netlist.zig");
const Smith = std.testing.Smith;
const Dialect = netlist.Dialect;
const Netlist = netlist.Netlist;
const Value = netlist.Value;

/// Generated decks stop growing past this many bytes.
const deck_max = 1 << 14;
/// A transformed deck may grow by a comment line or a `+` per card.
const transformed_max = 2 * deck_max;
/// Cards per generated deck.
const cards_max = 64;
/// Expression nesting the generator recurses through; deeper parentheses
/// come from the `(`-run atom instead, which reaches `expr.max_depth`.
const expr_depth_max = 4;
/// Subcircuit definitions a generated hierarchy holds.
const hierarchy_max = 6;

/// A parse's outcome: the declared error, or a digest of everything the
/// parse decided that does not borrow the deck's original case.
const Outcome = union(enum) {
    err: netlist.Error,
    digest: u64,

    fn eql(a: Outcome, b: Outcome) bool {
        return switch (a) {
            .err => |e| b == .err and b.err == e,
            .digest => |d| b == .digest and b.digest == d,
        };
    }
};

fn outcome(gpa: std.mem.Allocator, src: []const u8, dialect: Dialect) Outcome {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const nl = netlist.parse(arena.allocator(), src, dialect) catch |err| return .{ .err = err };
    return .{ .digest = digest(&nl) };
}

/// Hashes the devices (name, letter, pins by net name, values, model),
/// the models and the analyses. Leaves out what keeps the deck's own case
/// (the title, paths, cards as written), so an uppercased deck matches.
fn digest(nl: *const Netlist) u64 {
    var h: std.hash.Wyhash = .init(0);
    const D = struct {
        fn int(hh: *std.hash.Wyhash, x: u64) void {
            hh.update(std.mem.asBytes(&x));
        }
        fn str(hh: *std.hash.Wyhash, s: []const u8) void {
            int(hh, s.len);
            hh.update(s);
        }
        fn val(hh: *std.hash.Wyhash, n: *const Netlist, v: Value) void {
            int(hh, @backingInt(std.meta.activeTag(v)));
            switch (v) {
                .num => |x| int(hh, @bitCast(x)),
                .name => |s| str(hh, s),
                .expr => |span| for (n.exprOps(span)) |op| {
                    int(hh, @backingInt(op.code));
                    // A constant by its value: its pool row is bookkeeping.
                    int(hh, if (op.code == .num) @bitCast(n.consts[op.a]) else op.a);
                    int(hh, op.b);
                },
                .group => |g| for (g.items) |item| val(hh, n, item),
            }
        }
        fn kvs(hh: *std.hash.Wyhash, n: *const Netlist, items: []const netlist.Kv) void {
            int(hh, items.len);
            for (items) |kv| {
                str(hh, kv.key);
                val(hh, n, kv.value);
            }
        }
    };
    D.int(&h, nl.deviceCount());
    for (0..nl.deviceCount()) |e| {
        const d = nl.device(.from(e));
        D.str(&h, d.name);
        D.int(&h, d.kind);
        D.int(&h, d.subckt_instance);
        D.int(&h, d.model_row);
        D.int(&h, d.pins.len);
        for (d.pins) |p| D.str(&h, nl.netName(p));
        D.int(&h, d.positional.len);
        for (d.positional) |v| D.val(&h, nl, v);
        D.kvs(&h, nl, d.kv);
    }
    D.int(&h, nl.models.len);
    for (nl.models) |m| {
        D.str(&h, m.name);
        D.str(&h, m.kind);
        D.kvs(&h, nl, m.kv);
    }
    D.int(&h, nl.deck.analyses.len);
    for (nl.deck.analyses) |a| {
        D.int(&h, @backingInt(a.kind));
        D.int(&h, @backingInt(std.meta.activeTag(a.sweep)));
        D.int(&h, a.pos);
        D.int(&h, a.neg);
        for (a.args) |v| D.val(&h, nl, v);
    }
    D.int(&h, nl.deck.config.len);
    D.int(&h, nl.deck.ic.len);
    D.int(&h, nl.deck.measures.len);
    D.int(&h, nl.deck.steps.len);
    D.int(&h, nl.live.names.len);
    return h.final();
}

/// The full oracle on one deck. `src` drives the transforms' choices.
fn check(gpa: std.mem.Allocator, src: anytype, deck_text: []const u8, dialect: Dialect) !void {
    const base = outcome(gpa, deck_text, dialect);
    try expectSame("a second parse", base, outcome(gpa, deck_text, dialect), deck_text, deck_text);
    var buf: [transformed_max]u8 = undefined;
    if (withComment(src, deck_text, dialect, &buf)) |t|
        try expectSame("an inserted comment line", base, outcome(gpa, t, dialect), deck_text, t);
    if (dialect != .spectre) {
        const t = uppercased(deck_text, &buf);
        try expectSame("the deck uppercased", base, outcome(gpa, t, dialect), deck_text, t);
    }
    if (dialect == .ngspice) if (withContinuation(src, deck_text, &buf)) |t|
        try expectSame("a card split onto a `+` line", base, outcome(gpa, t, dialect), deck_text, t);
    try failOnce(gpa, src, deck_text, dialect, base);
}

fn expectSame(what: []const u8, want: Outcome, got: Outcome, before: []const u8, after: []const u8) !void {
    if (want.eql(got)) return;
    std.debug.print("netlist.parse changed its outcome under {s}: {any} -> {any}\n--- before\n{s}\n--- after\n{s}\n", .{ what, want, got, before, after });
    return error.TestUnexpectedResult;
}

/// Parses once with the `k`-th allocation failing, `k` drawn below the
/// count a clean parse makes: the parse must fail with `OutOfMemory`, or
/// with the clean parse's own error when it stops before reaching `k`.
fn failOnce(gpa: std.mem.Allocator, src: anytype, deck_text: []const u8, dialect: Dialect, base: Outcome) !void {
    var counting = std.testing.FailingAllocator.init(gpa, .{});
    _ = outcome(counting.allocator(), deck_text, dialect);
    if (counting.allocations == 0) return;
    const k = src.index(counting.allocations);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = k, .resize_fail_index = k });
    const got = outcome(failing.allocator(), deck_text, dialect);
    if (got == .err and got.err == error.OutOfMemory) return;
    if (!failing.has_induced_failure and base.eql(got)) return;
    std.debug.print("allocation {d} failing gave {any}, clean parse {any}:\n{s}\n", .{ k, got, base, deck_text });
    return error.TestUnexpectedResult;
}

/// `text` with a `* fuzz` comment line after a random line past the
/// title; null when the line continues onto the next (`\\`, or HSPICE's
/// and Spectre's trailing `\`), where a comment would end the card.
fn withComment(src: anytype, text: []const u8, dialect: Dialect, buf: []u8) ?[]const u8 {
    const count = std.mem.countScalar(u8, text, '\n');
    if (count == 0) return null;
    const after = 1 + src.index(count); // 1-based line, never before the title
    var it = std.mem.splitScalar(u8, text, '\n');
    var w: std.Io.Writer = .fixed(buf);
    var k: usize = 0;
    while (it.next()) |line| {
        k += 1;
        w.writeAll(line) catch return null;
        if (it.index == null) break;
        w.writeByte('\n') catch return null;
        if (k != after) continue;
        const t = std.mem.trimEnd(u8, line, " \t\r");
        if (std.mem.endsWith(u8, t, "\\") and (dialect != .ngspice or std.mem.endsWith(u8, t, "\\\\"))) return null;
        w.writeAll("* fuzz\n") catch return null;
    }
    return w.buffered();
}

/// `text` with every byte past the title uppercased: the ngspice and
/// HSPICE dialects fold case before reading a card.
fn uppercased(text: []const u8, buf: []u8) []const u8 {
    const title = (std.mem.indexOfScalar(u8, text, '\n') orelse text.len);
    @memcpy(buf[0..text.len], text);
    for (buf[title..text.len]) |*c| c.* = std.ascii.toUpper(c.*);
    return buf[0..text.len];
}

/// `text` with one ngspice card split at a blank onto a `+` line: the
/// reader joins the pieces with one blank (ngspice-syntax.md §1.6). The
/// split sits outside quotes and before the line's comment, on a card
/// that neither continues onto its next line nor follows one that does.
/// Null when the chosen line has no such blank.
fn withContinuation(src: anytype, text: []const u8, buf: []u8) ?[]const u8 {
    const count = std.mem.countScalar(u8, text, '\n');
    if (count == 0) return null;
    const target = 1 + src.index(count); // 0-based line past the title
    var start: usize = 0;
    var prev_glued = false;
    for (0..target) |_| {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null;
        prev_glued = std.mem.endsWith(u8, std.mem.trimEnd(u8, text[start..nl], " \t\r"), "\\\\");
        start = nl + 1;
    }
    if (prev_glued) return null;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    const line = text[start..end];
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or std.mem.indexOfScalar(u8, "*#$;=[]?()&%\"!:,\x0c+@/", t[0]) != null) return null;
    if (std.mem.endsWith(u8, t, "\\\\")) return null;
    // The blanks outside quotes, before the comment (`;`, `//`, a `$`
    // after a blank, tab or comma), each after a non-blank.
    var cuts: [64]usize = undefined;
    var n: usize = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == '\\') i += 1 else if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            ';' => break,
            '/' => if (i + 1 < line.len and line[i + 1] == '/') break,
            '$' => if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t' or line[i - 1] == ',') break,
            ' ', '\t' => if (i > 0 and line[i - 1] != ' ' and line[i - 1] != '\t' and n < cuts.len) {
                cuts[n] = i;
                n += 1;
            },
            else => {}, // else: any other byte is text
        }
    }
    // A cut needs text after it, not only blanks or the comment.
    while (n > 0 and std.mem.trim(u8, line[cuts[n - 1]..i], " \t\r").len == 0) n -= 1;
    if (n == 0) return null;
    const cut = start + cuts[src.index(n)];
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(text[0..cut]) catch return null;
    w.writeAll("\n+") catch return null;
    w.writeAll(text[cut..]) catch return null;
    return w.buffered();
}

fn rawBytes(_: void, s: *Smith) anyerror!void {
    const dialect = s.value(Dialect);
    var buf: [deck_max]u8 = undefined;
    const text = buf[0..s.slice(&buf)];
    // Raw bytes rarely parse; the transforms need a deck that does.
    _ = outcome(std.testing.allocator, text, dialect);
}

fn structured(_: void, s: *Smith) anyerror!void {
    var buf: [deck_max]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const dialect = deck(s, &w);
    try check(std.testing.allocator, s, w.buffered(), dialect);
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

test "netlist.parse holds every oracle on 1000 seeded generated decks" {
    std.testing.log_level = .err;
    var prng: std.Random.DefaultPrng = .init(0x5eed_1ce);
    var src: Seeded = .{ .r = prng.random() };
    var buf: [deck_max]u8 = undefined;
    var parsed: usize = 0;
    for (0..1000) |_| {
        var w: std.Io.Writer = .fixed(&buf);
        const dialect = deck(&src, &w);
        try check(std.testing.allocator, &src, w.buffered(), dialect);
        parsed += @intFromBool(outcome(std.testing.allocator, w.buffered(), dialect) == .digest);
    }
    // The generator is only worth its oracles while most decks parse.
    try std.testing.expect(parsed > 300);
}

test "the seed decks hold every oracle in every dialect" {
    std.testing.log_level = .err;
    var prng: std.Random.DefaultPrng = .init(0xc0de);
    var src: Seeded = .{ .r = prng.random() };
    for (seeds) |text| for (std.enums.values(Dialect)) |d| try check(std.testing.allocator, &src, text, d);
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
    "V# @ @ pat (? ? ? ? ? ? b10m1 r=1)",
    "I# @ @ ?",
    "E# @ @ @ @ ?",
    "G# @ @ @ @ ?",
    "F# @ @ V# ?",
    "H# @ @ V# ?",
    "G# @ @ value={~}",
    "B# @ @ v={~}",
    "B# @ @ i=~",
    "E# @ @ laplace @ @ ? / ? ?",
    "E# @ @ table {~} = (? ?) (? ?)",
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
    ".func %(x) {x*~}",
    ".model ` | (%=? %=?)",
    ".model ` | %=?",
    ".model `.# | lmin=? lmax=? wmin=? wmax=?",
    ".op",
    ".tran ? ?",
    ".tran ? ? ? uic",
    ".tran ? ? sweep monte=?",
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
    ".options gshunt=?",
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
    ".four ? v(@) v(@)",
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
    ".sample fs=?",
    "* comment @ ?",
    "",
    "R# @ @ ? $ trailing",
    "R# @ @ ? ; trailing",
    "V# @ @ ? // slash",
    "R# @ @\n+ ?",
    "R# @ @ \\\\\n?",
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

/// Spectre statements: one deck in eight is read as Spectre, and SPICE
/// cards alone would mostly test its refusals.
const spectre_templates = [_][]const u8{
    "r# (@ @) resistor r=?",
    "c# (@ @) capacitor c=?",
    "l# (@ @) inductor l=?",
    "v# (@ @) vsource dc=? mag=?",
    "v# (@ @) vsource type=pulse val0=? val1=? period=?",
    "i# (@ @) isource dc=?",
    "e# (@ @ @ @) vcvs gain=?",
    "d# (@ @) dmod",
    "model dmod diode is=?",
    "parameters %=? %=?",
    "parameters %=~",
    "subckt cell a b\nparameters w=1\nr1 (a b) resistor r=w\nends cell\nx# (@ @) cell w=?",
    "subckt cell a b",
    "ends cell",
    "x# (@ @) cell",
    "tr# tran stop=?",
    "op# dc",
    "ac# ac start=? stop=? dec=?",
    "simulator lang=spice",
    "R# @ @ ?",
    "simulator lang=spectre",
    "global @",
    "// comment",
    "* comment",
    "ic @=?",
    "r# (@ @) resistor r=? \\\n  m=?",
    "save @",
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
    ".enddata",
    ".pat % = b1 r=?",
    "V# @ @ pat (? ? ? ? ? ? [b1 b0] r=?)",
};

const nets = [_][]const u8{ "0", "gnd", "in", "out", "n1", "n2", "a", "b", "vdd", "x1.n", "N1", "1" };
const atoms = [_][]const u8{ "1", "1k", "2.2u", "1e-9", "-3", "0", "1meg", "10n", "1.5e3k", "1e400", "-0", "1m", "5mil", "inf", "nan", "1.", ".5", "1e", "0x1f", "3db", "1d3", "2a", "1x", "1e-330" };
/// The atoms every reader takes as a number.
const good_atoms = [_][]const u8{ "1", "1k", "2.2u", "1e-9", "3", "0", "1meg", "10n", "1m", "5mil", ".5", "2.5", "1d3", "100" };
const models = [_][]const u8{ "nm", "pm", "dn", "qn", "mod1", "nm.1" };
const types = [_][]const u8{ "nmos", "pmos", "d", "npn", "pnp", "r", "c", "njf", "sw", "ltra", "nmos level=54", "pmos level=8", "nmos level=1 version=4.8", "zz" };
const subckts = [_][]const u8{ "cell", "sub", "rc", "h0", "h1", "h2" };
const params = [_][]const u8{ "p", "w0", "k", "base", "r" };
const suffixes = [_][]const u8{ "1", "2", "x", "1a", "" };
const ops = [_][]const u8{ "+", "-", "*", "/", "**", "^", "<", ">=", "==", "!=", "&&", "||", "%" };
const funcs = [_][]const u8{ "sin", "exp", "sqrt", "abs", "log", "pow", "max", "min", "limit", "pwr", "agauss", "gauss", "if", "u", "p" };

/// Writes a title line and up to `cards_max` cards; returns the dialect to
/// parse them in.
fn deck(src: anytype, w: *std.Io.Writer) Dialect {
    // The templates are SPICE syntax: Spectre gets one deck in eight.
    const dialect: Dialect = if (src.eosWeightedSimple(7, 1)) .spectre else if (src.eosWeightedSimple(1, 1)) .hspice else .ngspice;
    // Defines every name `params` holds, so a bare `%` value resolves.
    put(w, if (dialect == .spectre) "fuzz deck\nparameters p=1 w0=1u k=2 base=3 r=1k\n" else "fuzz deck\n.param p=1 w0=1u k=2 base=3 r=1k\n");
    // Swarm testing: half the decks leave out the fragments and the
    // malformed atoms, so they mostly parse and the transforms have
    // something to compare.
    const clean = src.eosWeightedSimple(1, 1);
    if (dialect != .spectre and src.eosWeightedSimple(3, 1)) hierarchy(src, w, clean);
    for (0..cards_max) |_| {
        if (src.eosWeightedSimple(7, 1)) break;
        const template = if (!clean and src.eosWeightedSimple(7, 1))
            pick(src, &fragments)
        else if (dialect == .spectre and src.eosWeightedSimple(1, 3))
            pick(src, &spectre_templates)
        else
            pick(src, &templates);
        // Case is folded before a SPICE card is read; Spectre keeps it.
        card(src, w, template, dialect != .spectre and src.eosWeightedSimple(7, 1), clean);
        put(w, if (src.eosWeightedSimple(15, 1)) "\r\n" else "\n");
    }
    return dialect;
}

/// Subcircuits `h0..h(n-1)`, each instancing the ones before it and some
/// nested inside the one before, with defaults that read the globals and
/// their own parameters; then the top-level instances.
fn hierarchy(src: anytype, w: *std.Io.Writer, clean: bool) void {
    const n = 1 + src.index(hierarchy_max);
    var nested = false;
    for (0..n) |k| {
        if (nested) {
            // Close the definition `h(k-1)` holds nested inside it.
            put(w, ".ends\n");
            nested = false;
        }
        print(w, ".subckt h{d} a b g=1 q={{g*2}}\n", .{k});
        if (src.eosWeightedSimple(3, 1)) put(w, ".param l1={q+g}\n");
        for (0..1 + src.index(4)) |c| {
            switch (src.index(6)) {
                0 => print(w, "r{d} a m{d} {{g*1k}}\n", .{ c, c }),
                1 => print(w, "c{d} m{d} b q\n", .{ c, c }),
                2 => print(w, "v{d} a b dc {{q}}\n", .{c}),
                3 => print(w, ".if (g > {d})\nr{d}i a b 1\n.else\nc{d}i a b 1p\n.endif\n", .{ src.index(3), c, c }),
                4 => print(w, "b{d} a b v={{v(m{d})*g}}\n", .{ c, c }),
                else => if (k > 0) { // else: an instance of an earlier subcircuit
                    print(w, "x{d} a m{d} h{d} g={{q+{d}}}\n", .{ c, c, src.index(k), c });
                } else put(w, "r9 a b 1\n"),
            }
        }
        if (k + 1 < n and src.eosWeightedSimple(3, 1)) {
            // `h(k+1)` sits inside `h(k)`, as HSPICE and ngspice allow.
            nested = true;
            continue;
        }
        put(w, ".ends\n");
    }
    if (nested) put(w, ".ends\n");
    for (0..1 + src.index(4)) |i| print(w, "xh{d} {s} {s} h{d} g={s}\n", .{ i, pick(src, &nets), pick(src, &nets), src.index(n), pick(src, if (clean) &good_atoms else &atoms) });
}

fn card(src: anytype, w: *std.Io.Writer, template: []const u8, upper: bool, clean: bool) void {
    var buf: [1024]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&buf);
    for (template) |c| switch (c) {
        '@' => put(&cw, pick(src, &nets)),
        '?' => value(src, &cw, clean),
        '~' => expression(src, &cw, 0, clean),
        '`' => put(&cw, pick(src, &models)),
        '|' => put(&cw, pick(src, &types)),
        '!' => put(&cw, pick(src, &subckts)),
        '%' => put(&cw, pick(src, &params)),
        '#' => put(&cw, pick(src, &suffixes)),
        else => cw.writeByte(c) catch {}, // else: a literal template byte
    };
    const text = cw.buffered();
    if (upper) for (text) |*b| {
        b.* = std.ascii.toUpper(b.*);
    };
    put(w, text);
}

fn value(src: anytype, w: *std.Io.Writer, clean: bool) void {
    switch (src.index(if (clean) 11 else 12)) {
        0...6 => put(w, pick(src, if (clean) &good_atoms else &atoms)),
        7, 8 => put(w, pick(src, &params)),
        9 => {
            put(w, "{");
            expression(src, w, 0, clean);
            put(w, "}");
        },
        10 => {
            put(w, "'");
            expression(src, w, 0, clean);
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

fn expression(src: anytype, w: *std.Io.Writer, depth: u8, clean: bool) void {
    std.debug.assert(depth <= expr_depth_max);
    const leaf = depth == expr_depth_max;
    switch (if (leaf) 0 else src.index(7)) {
        0 => switch (src.index(4)) {
            0 => put(w, pick(src, if (clean) &good_atoms else &atoms)),
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
            expression(src, w, depth + 1, clean);
            put(w, ")");
        },
        2, 3 => {
            expression(src, w, depth + 1, clean);
            put(w, pick(src, &ops));
            expression(src, w, depth + 1, clean);
        },
        4 => {
            put(w, "-");
            expression(src, w, depth + 1, clean);
        },
        5 => {
            put(w, pick(src, &funcs));
            put(w, "(");
            expression(src, w, depth + 1, clean);
            if (src.eosWeightedSimple(1, 1)) {
                put(w, ",");
                expression(src, w, depth + 1, clean);
            }
            put(w, ")");
        },
        else => { // else: the last index
            expression(src, w, depth + 1, clean);
            put(w, "?");
            expression(src, w, depth + 1, clean);
            put(w, ":");
            expression(src, w, depth + 1, clean);
        },
    }
}

fn pick(src: anytype, list: []const []const u8) []const u8 {
    return list[src.index(list.len)];
}

fn put(w: *std.Io.Writer, bytes: []const u8) void {
    w.writeAll(bytes) catch {};
}

fn print(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    w.print(fmt, args) catch {};
}
