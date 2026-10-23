//! tests/grammar/include.peg -> an include expander driven by its tree,
//! checked against `netlist.source.expand` (SPICE) and `expandSpectre`
//! (Spectre) on the fixture corpus, the vendored Spectre corpus, targeted
//! cases and bounded-exhaustive library files. The grammar classifies each
//! physical line; this file holds the rules the grammar cannot: section
//! selection, path search, mode switching around an included file.
//!
//! What the two expanders produce is compared line by line, blank lines
//! dropped. `.data` tables are compared by the data oracle, not here, so a
//! `.data` ... `.enddata` block is dropped from both; a `.vec` file's
//! sources are vec.zig's, so the oracle marks where they go and any lines
//! may stand there.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const netlist = @import("netlist");
const peg = @import("peg.zig");
const corpus = @import("corpus.zig");

/// Where a `.vec` file's lines go in the oracle's output.
const vec_mark = "\x00vec";
/// The include depth both expanders stop at.
const depth_max = 32;

fn grammar(a: Allocator) !peg.Grammar {
    var d: peg.Diag = .{};
    return peg.compile(a, @embedFile("include.peg"), &d) catch |err| {
        std.debug.print("include.peg: {t} at byte {d} {s}\n", .{ err, d.offset, d.name });
        return err;
    };
}

/// The oracle expander: one per top-level deck.
const X = struct {
    a: Allocator,
    io: Io,
    g: peg.Grammar,
    /// The top deck's path: `.load`'s default file is named after it.
    deck: []const u8,
    /// `.option search=` directories of a SPICE top deck.
    dirs: []const []const u8 = &.{},
    out: std.ArrayList(u8) = .empty,

    fn is(x: *const X, t: peg.Tree, k: u32, name: []const u8) bool {
        return t.rows[k].rule == x.g.rule(name);
    }

    fn tree(x: *X, start: []const u8, text: []const u8) !peg.Tree {
        var d: peg.Diag = .{};
        return peg.parse(x.a, x.g, x.g.rule(start), text, &d) catch |err| {
            std.debug.print("include.peg: {s} rejects at byte {d}: {f}\n", .{ start, d.offset, std.zig.fmtString(text[0..@min(text.len, 300)]) });
            return err;
        };
    }

    fn emit(x: *X, line: []const u8) !void {
        try x.out.appendSlice(x.a, line);
        try x.out.append(x.a, '\n');
    }

    /// A file argument's value; InvalidInclude when it is missing or a
    /// punctuation field.
    fn file(x: *const X, t: peg.Tree, k: u32) ![]const u8 {
        if (x.is(t, k, "Missing") or x.is(t, k, "BadArg")) return error.InvalidInclude;
        return x.unquote(t, k);
    }

    /// A Word as written; a Quoted without its quotes, or, unclosed, to the
    /// last non-blank of its line.
    fn unquote(x: *const X, t: peg.Tree, k: u32) []const u8 {
        const s = t.text(k);
        if (x.is(t, k, "Word")) return s;
        if (s.len >= 2 and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
        return std.mem.trimEnd(u8, s[1..], " \t\r");
    }

    /// `name` beside `from`, else in the first search directory holding it,
    /// else beside `from` (so reading it fails as it should).
    fn locate(x: *X, from: []const u8, name: []const u8) ![]const u8 {
        const here = try std.fs.path.resolveAlloc(x.a, &.{ std.fs.path.dirname(from) orelse ".", name });
        if (x.dirs.len == 0 or std.fs.path.isAbsolute(name) or x.exists(here)) return here;
        for (x.dirs) |d| {
            const there = try std.fs.path.resolveAlloc(x.a, &.{ d, name });
            if (x.exists(there)) return there;
        }
        return here;
    }

    fn exists(x: *X, path: []const u8) bool {
        Io.Dir.cwd().access(x.io, path, .{}) catch return false;
        return true;
    }

    fn read(x: *X, path: []const u8) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(x.io, path, x.a, .unlimited);
    }

    /// One SPICE file: the title (top deck), then each line by its kind.
    fn spice(x: *X, path: []const u8, text: []const u8, section: ?[]const u8, depth: u32, top: bool) anyerror!void {
        const t = try x.tree(if (top) "SpiceDeck" else "SpiceFile", text);
        if (top) x.dirs = try x.searchDirs(t);
        var selected = section == null;
        var found = selected;
        var open = false;
        // Inside an external `.data` block, read by appendData to `.enddata`.
        var in_data = false;
        var it = t.children(0);
        while (it.next()) |k| {
            const line = lineAt(text, t.rows[k].start);
            if (in_data) {
                in_data = !x.is(t, k, "EndData");
                continue;
            }
            if (x.is(t, k, "Include") or x.is(t, k, "Vec")) {
                const name = try x.file(t, firstChild(t, k));
                if (selected) try x.pull(path, name, null, depth, x.is(t, k, "Vec"));
            } else if (x.is(t, k, "Lib")) {
                var args = t.children(k);
                const name = try x.file(t, args.next().?);
                const corner = args.next().?;
                if (x.is(t, corner, "BadArg")) return error.InvalidInclude;
                if (x.is(t, corner, "Missing")) {
                    // `.lib name`: a section opens.
                    if (open) return error.InvalidLibrarySection;
                    open = true;
                    selected = if (section) |w| std.ascii.eqlIgnoreCase(w, name) else false;
                    if (selected and found) return error.DuplicateLibrarySection;
                    found = found or selected;
                } else if (selected) try x.pull(path, name, x.unquote(t, corner), depth, false);
            } else if (x.is(t, k, "Endl")) {
                if (!open) return error.InvalidLibrarySection;
                open = false;
                selected = section == null;
            } else if (x.is(t, k, "Load")) {
                if (selected) try x.load(t, k, path, depth);
            } else if (x.is(t, k, "Data")) {
                if (selected and t.child(k, x.g.rule("Merge")) != null) in_data = true else if (selected) try x.emit(line);
            } else if (selected) try x.emit(line);
        }
        if (open) return error.InvalidLibrarySection;
        if (!found) return error.LibrarySectionNotFound;
    }

    /// The `.option search=` directories, against the deck's directory.
    fn searchDirs(x: *X, t: peg.Tree) ![]const []const u8 {
        var dirs: std.ArrayList([]const u8) = .empty;
        var it = t.children(0);
        while (it.next()) |k| {
            if (!x.is(t, k, "Option")) continue;
            var s = t.children(k);
            while (s.next()) |c| {
                const v = firstChild(t, c);
                try dirs.append(x.a, try std.fs.path.resolveAlloc(x.a, &.{ std.fs.path.dirname(x.deck) orelse ".", x.unquote(t, v) }));
            }
        }
        return dirs.items;
    }

    /// The file a SPICE directive names, one level down: an HDL module stays
    /// an `.include` of its path, a `.vec` file is marked, a netlist file is
    /// read in.
    fn pull(x: *X, from: []const u8, name: []const u8, section: ?[]const u8, depth: u32, vec: bool) !void {
        const path = try x.locate(from, name);
        const ext = std.fs.path.extension(name);
        for ([_][]const u8{ ".va", ".vams", ".veriloga", ".v", ".sv" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) {
            return x.emit(try std.fmt.allocPrint(x.a, ".include \"{s}\"", .{path}));
        };
        if (vec) {
            _ = try x.read(path);
            return x.emit(vec_mark);
        }
        if (depth + 1 == depth_max) return error.IncludeDepthExceeded;
        try x.spice(path, try x.read(path), section, depth + 1, false);
    }

    /// HSPICE `.load [FILE=f] [RUN=r]` (CR p.158): `f`, or the top deck's
    /// root name, with `.ic` read as `.ic0`; a file not there is skipped.
    fn load(x: *X, t: peg.Tree, k: u32, from: []const u8, depth: u32) !void {
        var name: ?[]const u8 = null;
        var it = t.children(k);
        while (it.next()) |c| {
            if (x.is(t, c, "LoadTail")) {
                if (std.mem.trim(u8, t.text(c), " \t\r").len > 0) return error.InvalidInclude;
                continue;
            }
            var kv = t.children(c);
            const key = t.text(kv.next().?);
            const value = try x.file(t, kv.next().?);
            if (std.ascii.eqlIgnoreCase(key, "file")) name = value else if (!std.ascii.eqlIgnoreCase(key, "run")) return error.InvalidInclude;
        }
        const want = if (name) |n|
            try std.mem.concat(x.a, u8, &.{ n, if (std.ascii.eqlIgnoreCase(std.fs.path.extension(n), ".ic")) "0" else "" })
        else
            try std.mem.concat(x.a, u8, &.{ std.fs.path.stem(x.deck), ".ic0" });
        const path = try x.locate(from, want);
        if (depth + 1 == depth_max) return error.IncludeDepthExceeded;
        const text = x.read(path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        try x.spice(path, text, null, depth + 1, false);
    }

    /// One Spectre file; returns whether it ends in SPICE mode.
    fn spectre(x: *X, path: []const u8, text: []const u8, section: ?[]const u8, depth: u32, top: bool) anyerror!bool {
        const t = try x.tree(if (top) "SpectreDeck" else "SpectreFile", text);
        var selected = section == null;
        var found = selected;
        var open = false;
        var ends_spice = false;
        var it = t.children(0);
        while (it.next()) |k| {
            const line = lineAt(text, t.rows[k].start);
            ends_spice = false;
            const block = x.is(t, k, "Section") or x.is(t, k, "EndSection") or x.is(t, k, "Library") or x.is(t, k, "EndLibrary");
            if (x.is(t, k, "Region")) {
                ends_spice = true;
                if (!selected) continue;
                var region: std.ArrayList(u8) = .empty;
                var lines = t.children(k);
                try x.emit(lineAt(text, t.rows[lines.next().?].start));
                var first = true;
                while (lines.next()) |l| {
                    if (!first) try region.append(x.a, '\n');
                    first = false;
                    try region.appendSlice(x.a, t.text(l));
                }
                try x.spice(path, region.items, null, depth, false);
            } else if (block and section != null) {
                if (x.is(t, k, "Section")) {
                    if (open) return error.InvalidLibrarySection;
                    open = true;
                    const name = if (t.child(k, x.g.rule("SName"))) |s| t.text(s) else "";
                    selected = std.mem.eql(u8, name, section.?);
                    if (selected and found) return error.DuplicateLibrarySection;
                    found = found or selected;
                } else if (x.is(t, k, "EndSection")) {
                    if (!open) return error.InvalidLibrarySection;
                    open = false;
                    selected = false;
                }
            } else if (x.is(t, k, "SInclude")) {
                if (!selected) continue;
                if (t.child(k, x.g.rule("IncBad")) != null) return error.InvalidInclude;
                const raw = t.text(t.child(k, x.g.rule("IncFile")).?);
                const name = try joinBreaks(x.a, raw[1 .. raw.len - 1]);
                const sec: ?[]const u8 = if (t.child(k, x.g.rule("IncSection"))) |s| t.text(t.child(s, x.g.rule("SecName")).?) else null;
                if (depth == depth_max - 1) return error.IncludeDepthExceeded;
                const inc = try x.locate(path, name);
                const body = try x.read(inc);
                var d: peg.Diag = .{};
                const spectre_mode = std.ascii.eqlIgnoreCase(std.fs.path.extension(inc), ".scs") or
                    if (peg.parse(x.a, x.g, x.g.rule("ModeSniff"), body, &d)) |_| true else |_| false;
                if (spectre_mode) {
                    if (try x.spectre(inc, body, sec, depth + 1, false)) try x.emit("simulator lang=spectre");
                } else {
                    try x.emit("simulator lang=spice");
                    try x.spice(inc, body, sec, depth + 1, false);
                    try x.emit("simulator lang=spectre");
                }
            } else if (selected) try x.emit(line);
        }
        if (open) return error.InvalidLibrarySection;
        if (!found) return error.LibrarySectionNotFound;
        return ends_spice;
    }
};

fn firstChild(t: peg.Tree, k: u32) u32 {
    var it = t.children(k);
    return it.next().?;
}

/// The physical line holding byte `at` of `src`.
fn lineAt(src: []const u8, at: usize) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |i| i + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, src, at, '\n') orelse src.len;
    return src[start..end];
}

/// `s` with each `\` line break (and the blanks after it) read as a blank.
fn joinBreaks(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            var j = i + 1;
            while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\r')) j += 1;
            if (j < s.len and s[j] == '\n') {
                j += 1;
                while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
                try out.append(a, ' ');
                i = j - 1;
                continue;
            }
        }
        try out.append(a, s[i]);
    }
    return out.items;
}

const Outcome = union(enum) { text: []const u8, err: anyerror };

fn frontend(a: Allocator, io: Io, spectre: bool, origin: []const u8, src: []const u8) Outcome {
    const r = if (spectre) netlist.source.expandSpectre(io, a, origin, src) else netlist.source.expand(io, std.heap.page_allocator, a, origin, src);
    return if (r) |t| .{ .text = t } else |e| .{ .err = e };
}

fn oracle(a: Allocator, io: Io, g: peg.Grammar, spectre: bool, origin: []const u8, src: []const u8) Outcome {
    var x: X = .{ .a = a, .io = io, .g = g, .deck = origin };
    const r = if (spectre) (if (x.spectre(origin, src, null, 0, true)) |_| {} else |e| e) else x.spice(origin, src, null, 0, true);
    return if (r) |_| .{ .text = x.out.items } else |e| .{ .err = e };
}

/// The lines compared: blank lines and `.data` blocks dropped.
fn normalize(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var data = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        const w = t[0 .. std.mem.indexOfAny(u8, t, " \t") orelse t.len];
        if (std.ascii.eqlIgnoreCase(w, ".data")) data = true;
        if (!data) try out.append(a, line);
        if (std.ascii.eqlIgnoreCase(w, ".enddata")) data = false;
    }
    return out.items;
}

/// Whether the frontend's lines are the oracle's, any lines standing at a
/// `.vec` mark.
fn sameLines(want: []const []const u8, got: []const []const u8) bool {
    var j: usize = 0;
    for (want, 0..) |w, i| {
        if (!std.mem.eql(u8, w, vec_mark)) {
            if (j >= got.len or !std.mem.eql(u8, w, got[j])) return false;
            j += 1;
            continue;
        }
        // The next line the oracle wrote, after the vector file's sources.
        const next = for (want[i + 1 ..]) |n| {
            if (!std.mem.eql(u8, n, vec_mark)) break n;
        } else return true;
        while (j < got.len and !std.mem.eql(u8, got[j], next)) j += 1;
    }
    return j == got.len;
}

/// One deck through both expanders; prints and returns false when they
/// disagree.
fn check(a: Allocator, io: Io, g: peg.Grammar, spectre: bool, name: []const u8, origin: []const u8, src: []const u8) !bool {
    const want = oracle(a, io, g, spectre, origin, src);
    const got = frontend(a, io, spectre, origin, src);
    const agree = switch (want) {
        .err => |e| got == .err and got.err == e,
        .text => |w| got == .text and sameLines(try normalize(a, w), try normalize(a, got.text)),
    };
    if (!agree) {
        std.debug.print("--- include {s} {f}\n", .{ name, std.zig.fmtString(src[0..@min(src.len, 400)]) });
        switch (want) {
            .err => |e| std.debug.print("oracle: {t}\n", .{e}),
            .text => |w| std.debug.print("oracle:\n{s}\n", .{w}),
        }
        switch (got) {
            .err => |e| std.debug.print("frontend: {t}\n", .{e}),
            .text => |w| std.debug.print("frontend:\n{s}\n", .{w}),
        }
    }
    return agree;
}

/// Files the targeted cases include, by name in the scratch directory.
const files = [_][2][]const u8{
    .{ "a.sp", ".inc 'b.sp'\nra 1 0 1\n" },
    .{ "b.sp", "rb 1 0 2\n" },
    .{ "lib.sp", "* lib\n.lib tt\nrt 1 0 1\n.lib 'lib.sp' common\n.endl tt\n.lib ss\nrs 1 0 2\n.endl\n.lib common\nrc 1 0 3\n.endl\n" },
    .{ "dup.sp", ".lib tt\n.endl\n.lib TT\n.endl\n" },
    .{ "open.sp", ".lib tt\nr1 1 0 1\n" },
    .{ "loop.sp", ".include 'loop.sp'\n" },
    .{ "sub/deep.sp", "rd 1 0 4\n" },
    .{ "deck.ic0", ".nodeset v(1)=1\n" },
    .{ "other.ic0", ".ic v(1)=2\n" },
    .{ "named.ic0", ".ic v(1)=3\n" },
    .{ "v.vec", "radix 1\nvname a\nio i\nperiod 10\n0\n1\n" },
    .{ "d1.txt", "1 2\n3 4\n" },
    .{ "s.sp", ".lib tt\nrs 1 0 5\n.endl\n.lib ff\nrf 1 0 6\n.endl\n" },
    .{ "lib.scs", "library l\nsection tt\nr1 (a 0) resistor r=1\ninclude \"b.sp\"\nendsection tt\nsection ss\nr1 (a 0) resistor r=2\nendsection\nendlibrary l\n" },
    .{ "b.scs", "rbs (a 0) resistor r=7\n" },
    .{ "c.inc", "simulator lang=spectre\nc1 (a 0) capacitor c=1p\nsimulator lang=spice\nc2 a 0 2p\n" },
    .{ "loop.scs", "include \"loop.scs\"\n" },
    .{ "bad.scs", "library l\nsection tt\nr1 (a 0) resistor r=1\n" },
    .{ "dup.scs", "section tt\nendsection\nsection tt\nendsection\n" },
    .{ "sec.scs", "section tt x\nr1 (a 0) resistor r=1\nendsection\n" },
    .{ "m.inc", "\n  \n  simulator lang=spectre\nr2 (a 0) resistor r=2\n" },
    .{ "reg.scs", "simulator lang=spice\n.include 'b.sp'\nsimulator lang=spectre\nr9 (a 0) resistor r=9\n" },
};

/// SPICE decks, each from a rule of include.peg (deck.sp in the scratch
/// directory).
const spice_cases = [_][]const u8{
    "t\n.include 'a.sp'\n",
    "t\n.INC \"a.sp\" $ c\nr1 1 0 1\n",
    "t\n.lib 'lib.sp' tt\n",
    "t\n.lib lib.sp ss\n.lib lib.sp common\n",
    "t\n.lib 'lib.sp' ff\n",
    "t\n.lib 'dup.sp' tt\n",
    "t\n.lib 'open.sp' tt\n",
    "t\n.endl\n",
    "t\n.include 'loop.sp'\n",
    "t\n.option search='sub'\n.include 'deep.sp'\n",
    "t\n.options post x=1 (search=sub) y= $c\n.inc deep.sp\n",
    "t\n.opt key=search search = 'nowhere'\n.inc deep.sp\n",
    "t\n.include 'm.va'\n.lib 'x.va' tt\n",
    "t\n.load\n",
    "t\n.load file='other.ic0' run=current\n",
    "t\n.load FILE=named.ic\n",
    "t\n.load file=missing.ic0\n",
    "t\n.load mode=x\n",
    "t\n.load file\n",
    "t\n.vec 'v.vec'\nr1 1 0 1\n",
    "t\n.data d MER\n+ FILE='d1.txt' x=1 y=2\n.enddata\nr2 1 0 1\n",
    "t\n.data 'q' lam FILE=d1.txt x=1\n.enddata\n",
    "t\n.data d x y\n+ 1 2\n.enddata\n.data = mer FILE=d1.txt x=1\n.enddata\n.data\n.enddata\n",
    "t\n.include\n",
    "t\n.include\r\n",
    "t\n.include",
    "t\n.include =x\n",
    "t\n.lib 'lib.sp' =\n",
    "t\n.include ;c\n",
    ".include nothing\nr1 1 0 1\n",
    "t\n* .include x\n.includes x\nr1 1 0 1\n",
    "t\n.inc 'a.sp\n",
    "t\n  .Lib\t'lib.sp'\ttt  \r\n",
    "t\n.lib tt\n.include 'nofile.sp'\n.endl\nr1 1 0 1\n",
    "t\n.lib tt\n.include =\n.endl\n",
    "t\n.include 'nofile.sp'\n",
    "t\n.lib tt\n.data d MER\n+ FILE='d1.txt' x=1\n.enddata\n.endl\n",
    "t\n.vec 'v.vec' extra\n.load file = other.ic0\n.data d x\n+ 1\n.enddata x\n.option a='b' search=sub\n.inc deep.sp  ",
};

/// Spectre decks (deck.scs in the scratch directory).
const spectre_cases = [_][]const u8{
    "t\ninclude \"lib.scs\" section=tt // corner\n",
    "t\ninclude \"c.inc\"\nv1 (a 0) vsource dc=1\n",
    "t\nsimulator lang=spice\n.include 'b.sp'\nsimulator lang=spectre\n",
    "t\ninclude \"lib.scs\" section=TT\n",
    "t\ninclude lib.scs\n",
    "t\ninclude \"lib.scs\" corner=tt\n",
    "t\ninclude \"s.sp\" section=ff\n",
    "t\ninclude \\\n  \"b.scs\"\ninclude \"lib.scs\" \\\nsection = ss\n",
    "t\ninclude \"b.\\\nscs\"\n",
    "t\ninclude \"loop.scs\"\n",
    "t\ninclude \"bad.scs\" section=tt\n",
    "t\ninclude \"dup.scs\" section=tt\n",
    "t\ninclude\nr1 (a 0) resistor r=1\n",
    "t\nsimulator lang=spice\ninclude a 0 1m\n.include 'b.sp'\n",
    "t\ninclude \"reg.scs\"\n",
    "t\ninclude \"lib.scs\" section=\n",
    "t\nsection tt\nlibrary x\nendsection\nendlibrary\n",
    "t\ninclude \"b.scs\" // c \\\nr1 (a 0) resistor r=1\n",
    "t\ninclude \"lib.scs\"section=tt//c\n",
    "t\ninclude \"lib.scs\" section=t/x\n",
    "t\ninclude \"nofile.scs\"\n",
    "t\nsimulator lang = spice insensitive=yes\nr1 a 0 1\nsimulator lang = spectre\nsimulator lang=spicex\ninclude \"b.scs\"  \ninclude \\  \r\n\"b.scs\"\n",
    "t\ninclude \"sec.scs\" section=tt\ninclude \"m.inc\"\r\n",
};

test "include expansion: grammar oracle against source.expand" {
    std.testing.log_level = .err;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try grammar(a);
    var bad: usize = 0;
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();

    // The fixture corpus, each deck in its dialect.
    for (try corpus.load(a, io)) |deck| {
        _ = scratch.reset(.retain_capacity);
        const origin = try std.fmt.allocPrint(a, "tests/conformance/tests/netlist/{s}", .{deck.path});
        if (!try check(scratch.allocator(), io, g, deck.dialect == .spectre, deck.path, origin, deck.src)) bad += 1;
    }
    // The vendored Spectre corpus, a title line first as root.zig reads it.
    {
        var dir = try Io.Dir.cwd().openDir(io, "tests/grammar/spectre_corpus", .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".scs")) continue;
            _ = scratch.reset(.retain_capacity);
            const s = scratch.allocator();
            const origin = try std.fmt.allocPrint(s, "tests/grammar/spectre_corpus/{s}", .{entry.path});
            const body = try dir.readFileAlloc(io, entry.path, s, .limited(1 << 20));
            if (!try check(s, io, g, true, origin, origin, try std.mem.concat(s, u8, &.{ "// title\n", body }))) bad += 1;
        }
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const deck_sp = try std.fmt.allocPrint(a, "{s}/deck.sp", .{base});
    const deck_scs = try std.fmt.allocPrint(a, "{s}/deck.scs", .{base});
    for (spice_cases) |c| {
        _ = scratch.reset(.retain_capacity);
        if (!try check(scratch.allocator(), io, g, false, "case", deck_sp, c)) bad += 1;
    }
    for (spectre_cases) |c| {
        _ = scratch.reset(.retain_capacity);
        if (!try check(scratch.allocator(), io, g, true, "case", deck_scs, c)) bad += 1;
    }

    // Bounded-exhaustive: every library file of up to 4 lines over the lines
    // section selection turns on, read through one section reference; and
    // the same lines as a deck of their own.
    const spice_vocab = [_][]const u8{ ".lib tt", ".lib ss", ".endl", ".lib 'l.sp' ss", ".include 'b.sp'", "r1 1 0 1", ".lib x.va tt" };
    const spectre_vocab = [_][]const u8{ "section tt", "section ss", "endsection", "library l", "include \"b.sp\"", "include \"l.scs\" section=ss", "simulator lang=spice", "simulator lang=spectre", "r1 (a 0) resistor r=1" };
    bad += try exhaust(a, io, g, tmp.dir, base, &spice_vocab, "l.sp", "t\n.lib 'l.sp' tt\n", false);
    bad += try exhaust(a, io, g, tmp.dir, base, &spectre_vocab, "l.scs", "t\ninclude \"l.scs\" section=tt\n", true);

    const holes = try peg.gaps(a, g);
    for (holes) |h| {
        var w: std.Io.Writer.Allocating = .init(a);
        try peg.render(&w.writer, g, h.node);
        std.debug.print("include.peg: rule {s}: never matched: {s}\n", .{ h.rule, w.written() });
    }
    if (bad > 0 or holes.len > 0) {
        std.debug.print("include: {d} disagree, {d} coverage gaps\n", .{ bad, holes.len });
        return error.Mismatch;
    }
}

/// Every file of up to 4 lines from `vocab`, written as `lib` and read
/// through `deck`, then the same lines as a deck; the count of
/// disagreements.
fn exhaust(a: Allocator, io: Io, g: peg.Grammar, dir: Io.Dir, base: []const u8, vocab: []const []const u8, lib: []const u8, deck: []const u8, spectre: bool) !usize {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const origin = try std.fmt.allocPrint(a, "{s}/deck.{s}", .{ base, if (spectre) "scs" else "sp" });
    var bad: usize = 0;
    var digits: [4]usize = undefined;
    for (0..digits.len + 1) |len| {
        @memset(digits[0..len], 0);
        while (true) {
            _ = scratch.reset(.retain_capacity);
            const s = scratch.allocator();
            var text: std.ArrayList(u8) = .empty;
            for (digits[0..len]) |d| {
                try text.appendSlice(s, vocab[d]);
                try text.append(s, '\n');
            }
            try dir.writeFile(io, .{ .sub_path = lib, .data = text.items });
            if (!try check(s, io, g, spectre, lib, origin, deck)) bad += 1;
            if (!try check(s, io, g, spectre, "deck", origin, try std.mem.concat(s, u8, &.{ "t\n", text.items }))) bad += 1;
            if (bad > 20) return bad;
            var i = len;
            while (i > 0) {
                i -= 1;
                digits[i] += 1;
                if (digits[i] < vocab.len) break;
                digits[i] = 0;
            } else break;
        }
    }
    return bad;
}
