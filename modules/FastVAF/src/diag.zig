//! Class 0 — the diagnostic system: collection, lint levels, provenance, and
//! rendering.
//!
//! Transformation: (stage events) → one `Bag` of `Entry` rows → bytes on a
//! writer, or JSON for a tool.
//!
//! WHY ONE BAG. Before this file every stage owned its own diagnostic struct,
//! its own cap, its own allocator and its own idea of what a source location
//! is (a line, a byte, a token index, a MIR instruction). Five collectors meant
//! five conversion sites in the driver, five chances to drop a location, and no
//! way to sort a parser error and a proof error into source order. There is now
//! ONE collector, one currency (`Span`, a byte range in the preprocessed text),
//! and one renderer.
//!
//! DOD
//!   - TWO POOLS, `string_bytes` and `extra`, exactly as the Zig compiler
//!     stores its own errors (std/zig/ErrorBundle.zig). A diagnostic is a run
//!     of `u32` words in `extra` — its labels and notes trailing it in the
//!     same run — plus NUL-terminated text in `string_bytes`. No per-entry
//!     allocation, no side tables, no pointers to fix up.
//!
//!     WHY THAT FORMAT AND NOT A NICER ONE OF OUR OWN: orchestrator.zig
//!     already receives a real `std.zig.ErrorBundle` from the resident `zig`
//!     child, describing errors in the GENERATED Zig (see `Result.failed`).
//!     Keeping a second, incompatible shape for errors in the Verilog-A meant
//!     two representations of one concept and two ways to serialise them. One
//!     format, one renderer, and a bag is now `{[]u8, []u32}` — memcpy-able
//!     down that same pipe with no bespoke encoding.
//!   - Diagnostics are COLD by construction (capped at 64 per run, written
//!     once, read once). So this file optimises for one thing only: never
//!     paying anything on the path where no diagnostic is produced. The line
//!     index, the dedupe set and the sort all happen lazily, after the first
//!     entry exists.
//!   - Everything the stages allocate lives in the compilation arena. The one
//!     gpa copy happens in `detach`, at the API boundary, because a failed
//!     compilation frees its arena on the way out — and with the pools that
//!     copy is three `appendSlice`s instead of a walk over every string.
//!
//! SEVERITY comes from the code's first letter (`E`/`W`) — see diag_code.zig.
//! There is no second table to desynchronise.

const std = @import("std");
const Allocator = std.mem.Allocator;
const code_table = @import("diag_code.zig");

pub const Code = code_table.Code;
pub const Info = code_table.Info;
pub const info = code_table.info;

// ---------------------------------------------------------------------------
// Severity and lint levels
// ---------------------------------------------------------------------------

pub const Severity = enum(u8) {
    err,
    warning,

    pub fn word(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
        };
    }
};

/// Severity is a property of the CODE, read from its first letter. A code
/// cannot change severity without changing its name, which is the point.
pub fn severityOf(c: Code) Severity {
    return switch (c.name()[0]) {
        'W' => .warning,
        else => .err,
    };
}

/// What the user asked us to do with a code. Mirrors rustc's lint levels.
pub const Level = enum(u8) {
    /// Do not collect it at all.
    allow,
    /// Collect and report, but do not fail the compilation.
    warn,
    /// Report and fail the compilation.
    deny,
    /// Like `deny`, and a later `--allow`/`--warn` for the same code is
    /// refused rather than silently honoured.
    forbid,

    pub fn fromName(s: []const u8) ?Level {
        return std.meta.stringToEnum(Level, s);
    }
};

/// Default level of a code with no override. Errors are `deny` and stay there:
/// `--allow` on an `E` code is refused by `set`, because an error is a
/// statement about the program, not about our taste.
pub fn defaultLevel(c: Code) Level {
    return switch (severityOf(c)) {
        .err => .deny,
        .warning => .warn,
    };
}

/// Per-code level overrides from the command line. A sorted-by-nothing array
/// with a linear scan: this is consulted once per diagnostic on a path that is
/// already cold, and the override count is the number of flags a human typed.
pub const Levels = struct {
    items: std.ArrayList(Entry_) = .empty,

    const Entry_ = struct { code: Code, level: Level };

    pub const empty: Levels = .{};

    pub fn deinit(self: *Levels, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.* = .empty;
    }

    pub const SetError = error{ CannotAllowError, Forbidden } || Allocator.Error;

    /// Apply `--allow=X` / `--warn=X` / `--deny=X` / `--forbid=X`.
    pub fn set(self: *Levels, gpa: Allocator, c: Code, level: Level) SetError!void {
        if (severityOf(c) == .err and level != .forbid and level != .deny)
            return error.CannotAllowError;
        for (self.items.items) |*it| {
            if (it.code != c) continue;
            if (it.level == .forbid and level != .forbid) return error.Forbidden;
            it.level = level;
            return;
        }
        try self.items.append(gpa, .{ .code = c, .level = level });
    }

    pub fn get(self: *const Levels, c: Code) Level {
        for (self.items.items) |it| {
            if (it.code == c) return it.level;
        }
        return defaultLevel(c);
    }

    /// Parse `allow=W0650` / `deny=W0650`. Returns null if the text is not a
    /// level directive at all, so a caller can fall through to other flags.
    pub fn parseFlag(self: *Levels, gpa: Allocator, text: []const u8) SetError!bool {
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse return false;
        const level = Level.fromName(text[0..eq]) orelse return false;
        const c = std.meta.stringToEnum(Code, text[eq + 1 ..]) orelse return false;
        try self.set(gpa, c, level);
        return true;
    }
};

// ---------------------------------------------------------------------------
// Locations
// ---------------------------------------------------------------------------

/// A byte range in the PREPROCESSED text — the one currency every stage
/// reports in. `SourceMap` turns it back into a file, line and column.
///
/// `end == start` is a legal zero-width span: the renderer draws a single caret
/// there, and a `Fix` uses it to mean "insert here, delete nothing".
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,

    pub const none: Span = .{ .start = 0, .end = 0 };

    pub fn at(start: u32) Span {
        return .{ .start = start, .end = start };
    }

    pub fn len(self: Span) u32 {
        return self.end -| self.start;
    }

    pub fn isNone(self: Span) bool {
        return self.start == 0 and self.end == 0;
    }
};

/// 1-based, because humans and every editor count that way.
pub const Loc = struct { line: u32 = 0, col: u32 = 0 };

pub const FileId = enum(u16) {
    /// The top-level compilation unit.
    root = 0,
    _,
};

/// How a run of the preprocessed text came to exist. The preprocessor appends
/// one of these every time the ORIGIN of the output changes — entering an
/// `include, starting a macro expansion, or returning from either.
///
/// DOD: sorted by `out_start` by construction (the preprocessor only ever
/// appends), so lookup is a binary search with no sort step.
pub const Segment = struct {
    /// First byte of the preprocessed text this segment explains.
    out_start: u32,
    /// Corresponding byte in `file`'s ORIGINAL text. Meaningless for `.macro`,
    /// where the bytes came from a macro body rather than from a file run.
    in_start: u32,
    file: FileId,
    kind: enum(u8) { verbatim, macro },
    /// Index of the enclosing segment, or `no_parent`. Walking this chain
    /// produces rustc's "in this expansion of `FOO`" note stack.
    parent: u32 = no_parent,
    /// Macro name, for `.macro` segments. Borrowed from the arena.
    macro: []const u8 = "",

    pub const no_parent: u32 = std.math.maxInt(u32);
};

pub const File = struct {
    name: []const u8,
    /// ORIGINAL text, before preprocessing. Snippets are cut from here, so
    /// what the user sees is what the user wrote.
    text: []const u8,
};

/// Preprocessed offset → (file, original offset, expansion chain).
///
/// An EMPTY map is legal and means "the preprocessed text is the source": every
/// offset resolves to `root` unchanged. That is exactly right for the unit
/// tests and for `compilePreprocessed`, and it means no stage needs a null
/// check.
pub const SourceMap = struct {
    segs: []const Segment = &.{},
    /// Newlines contributed by the annex-D prelude, which is prepended to the
    /// text but is not part of anyone's source. Subtracted from every reported
    /// line of `root`.
    prelude_lines: u32 = 0,

    pub const empty: SourceMap = .{};

    pub const Resolved = struct {
        file: FileId,
        /// Offset within that file's ORIGINAL text.
        offset: u32,
        /// Index into `segs`, or `Segment.no_parent` when the map is empty.
        seg: u32,
    };

    pub fn resolve(self: *const SourceMap, off: u32) Resolved {
        if (self.segs.len == 0)
            return .{ .file = .root, .offset = off, .seg = Segment.no_parent };

        // Last segment with out_start <= off.
        var lo: usize = 0;
        var hi: usize = self.segs.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.segs[mid].out_start <= off) lo = mid else hi = mid;
        }
        const s = self.segs[lo];
        // Inside a macro expansion the output offset has no counterpart in any
        // file; the honest answer is the macro's INVOCATION site, which is what
        // the nearest enclosing verbatim segment records.
        if (s.kind == .macro) {
            var p = s.parent;
            while (p != Segment.no_parent) {
                const q = self.segs[p];
                if (q.kind == .verbatim)
                    return .{ .file = q.file, .offset = q.in_start, .seg = @intCast(lo) };
                p = q.parent;
            }
            return .{ .file = s.file, .offset = s.in_start, .seg = @intCast(lo) };
        }
        return .{
            .file = s.file,
            .offset = s.in_start + (off - s.out_start),
            .seg = @intCast(lo),
        };
    }
};

/// Byte offset → line, by binary search over precomputed line starts.
///
/// Built ONCE per rendered file, only when there is something to render. The
/// old code re-scanned the whole source from byte 0 for every diagnostic, from
/// three different call sites.
pub const LineIndex = struct {
    starts: []const u32,

    pub fn build(arena: Allocator, text: []const u8) Allocator.Error!LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(arena, 0);
        for (text, 0..) |c, i| {
            if (c == '\n') try starts.append(arena, @intCast(i + 1));
        }
        return .{ .starts = try starts.toOwnedSlice(arena) };
    }

    /// 1-based line and column of `off`.
    pub fn loc(self: LineIndex, off: u32) Loc {
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= off) lo = mid else hi = mid;
        }
        return .{ .line = @intCast(lo + 1), .col = off - self.starts[lo] + 1 };
    }

    /// The text of `line` (1-based), without its newline.
    pub fn lineText(self: LineIndex, text: []const u8, line: u32) []const u8 {
        if (line == 0 or line > self.starts.len) return "";
        const start = self.starts[line - 1];
        const end = if (line < self.starts.len) self.starts[line] else @as(u32, @intCast(text.len));
        var slice = text[@min(start, text.len)..@min(end, text.len)];
        if (slice.len > 0 and slice[slice.len - 1] == '\n') slice = slice[0 .. slice.len - 1];
        if (slice.len > 0 and slice[slice.len - 1] == '\r') slice = slice[0 .. slice.len - 1];
        return slice;
    }

    pub fn lineCount(self: LineIndex) u32 {
        return @intCast(self.starts.len);
    }
};

// ---------------------------------------------------------------------------
// Entries: the wire format
// ---------------------------------------------------------------------------

/// Which stage produced the diagnostic. Kept for filtering and for the JSON
/// output; the code's class digits say the same thing, but a stage is what a
/// person debugging the ENGINE wants to filter on.
pub const Stage = enum(u8) { preprocess, parse, lower, proof, codegen };

/// Index into `Bag.extra` at the first word of a `Message` — the handle a
/// caller keeps, and what `Bag.get` decodes. Zig's `ErrorBundle.MessageIndex`
/// (ErrorBundle.zig:33).
pub const MessageIndex = enum(u32) { _ };

/// Index into `Bag.string_bytes`, at the first byte of a NUL-terminated
/// string. 0 means "no string": byte 0 of the pool is a sentinel NUL, so no
/// real string can begin there. Zig's `String`/`OptionalString`
/// (ErrorBundle.zig:22).
pub const String = u32;

/// Word 0 of a `Message`: everything that identifies the diagnostic. `Code` is
/// u16 and `Severity`/`Stage` are u8, so the three fill one word exactly.
const Head = packed struct(u32) {
    code: Code,
    severity: Severity,
    stage: Stage,
};

/// Word 1. The `Builder` caps both at `max_children`; u16 is just what half a
/// word gives, and there was nothing left in `Head` to steal.
const Counts = packed struct(u32) {
    labels_len: u16,
    notes_len: u16,
};

/// One diagnostic, as words in `Bag.extra`.
///
/// WHAT THIS CARRIES THAT ZIG'S `ErrorMessage` DOES NOT. Zig's row is
/// `{msg, count, src_loc, notes_len}` (ErrorBundle.zig:70) — a string and a
/// place. FastVAF also needs the `Code` (the catalogue key that `--explain`,
/// the lint levels and 809 fixtures all pin), the `Severity` (Zig's renderer
/// hardcodes "error"), the `Stage`, the `point` text drawn beside the primary
/// caret, and a count of secondary `Label`s. Every one of them is another
/// WORD in the same flat record — never a side table, which is the whole
/// reason this file has one storage shape instead of two.
///
/// NO `SourceLocation` INDIRECTION. Zig indexes a separate record
/// (ErrorBundle.zig:53) because several messages can share one location and a
/// `ReferenceTrace` points at one. Here it is 1:1 and never shared, so the
/// three fields are inlined: the index word alone would have cost as much as
/// two of them. The `.none` sentinel is not needed either — `Span.isNone()`
/// already means "no place", and `place()` already tests it.
///
/// LINE AND COLUMN ARE NOT STORED. Zig resolves them while building the bundle
/// (ErrorBundle.zig:539); we keep byte offsets and resolve at render through
/// `LineIndex`, because a span here is an offset into the PREPROCESSED text
/// and only `SourceMap` knows which file's line that is — and because the
/// common case by far is a bag nobody ever renders.
///
/// Trailing:
///   * `LabelRec` for each `counts.labels_len`
///   * `NoteRec` for each `counts.notes_len`
const Message = struct {
    head: Head,
    counts: Counts,
    msg: String,
    point: String,
    /// `FileId` + 1, or 0 for "resolve `span` through the `SourceMap`". Set
    /// only by the preprocessor, whose offsets are file-local because it fails
    /// before a preprocessed text exists to map them through.
    src_file: u32,
    span_start: u32,
    span_end: u32,
};

/// A secondary span drawn INSIDE the primary snippet. Zig has no equivalent:
/// its nearest thing is a note with its own `SourceLocation`, which renders as
/// a separate message on its own line.
///
/// The file is the message's — a label never points into a different file than
/// the diagnostic that owns it — so the record is the span and its text.
const LabelRec = struct {
    span_start: u32,
    span_end: u32,
    text: String,
};

/// A note or help line, optionally carrying a machine-applicable rewrite.
///
/// Zig trails `MessageIndex`es (ErrorBundle.zig:69) because its notes ARE
/// messages and get written after the parent header (`reserveNotes`). Ours are
/// written inline: `Builder` holds the whole diagnostic before it commits, so
/// the indirection would buy nothing and cost a word each.
///
/// `fix_repl == 0` means "no fix" — which is exactly why `String` 0 is
/// reserved, since a fix whose replacement is EMPTY is a deletion and has to
/// stay distinguishable from no fix at all.
const NoteRec = struct {
    kind: Note.Kind,
    text: String,
    fix_repl: String,
    fix_start: u32,
    fix_end: u32,
};

fn wordCount(comptime T: type) u32 {
    return @typeInfo(T).@"struct".fields.len;
}

/// Every record field is exactly one `extra` word. Zig switches on the three
/// field types it uses (ErrorBundle.zig:135); switching on the KIND instead
/// means a new packed field type needs no arm here.
fn toWord(v: anytype) u32 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int => v,
        .@"enum" => @intFromEnum(v),
        .@"struct" => @bitCast(v),
        else => @compileError("not an extra field type: " ++ @typeName(@TypeOf(v))),
    };
}

fn fromWord(comptime T: type, word: u32) T {
    return switch (@typeInfo(T)) {
        .int => word,
        .@"enum" => @enumFromInt(word),
        .@"struct" => @bitCast(word),
        else => @compileError("not an extra field type: " ++ @typeName(T)),
    };
}

// ---------------------------------------------------------------------------
// Entries: the decoded views
// ---------------------------------------------------------------------------
//
// Everything below is produced BY VALUE from the pools and never stored, the
// way `ErrorBundle.getErrorMessage` returns an `ErrorMessage` (ErrorBundle.zig
// :109). The strings are slices into `Bag.string_bytes`, so a view is free to
// make and valid exactly as long as the bag is.

/// A machine-applicable rewrite. `span` is what to replace; a zero-width span
/// inserts. The renderer draws `+` under an insertion and `~` under a
/// replacement, like rustc.
pub const Fix = struct {
    span: Span,
    replacement: []const u8,
};

pub const Note = struct {
    pub const Kind = enum(u32) { note, help };

    kind: Kind,
    text: []const u8,
    fix: ?Fix = null,
};

/// A secondary span with its own text: "this is the parameter that is
/// unconstrained", pointing somewhere other than the primary span.
pub const Label = struct {
    span: Span,
    text: []const u8,
};

/// Labels or notes on ONE diagnostic. More than four of either is not clearer
/// for it, and the cap is what lets `Bag.labels`/`Bag.notes` decode into a
/// caller's array instead of allocating.
pub const max_children = 4;

pub const Entry = struct {
    /// Where this row lives in `extra` — what `Bag.labels`/`Bag.notes` need to
    /// find the trailing records.
    index: MessageIndex,
    code: Code,
    severity: Severity,
    stage: Stage,
    /// Primary span — where the caret goes. May be `Span.none` only for a
    /// whole-file condition such as E1001.
    span: Span,
    /// Set ONLY by the preprocessor; every other stage leaves it null and
    /// resolves through `Bag.map`. See `Message.src_file`.
    file: ?FileId = null,
    /// The headline under `Info.title`; when empty the renderer prints the
    /// title alone.
    message: []const u8,
    /// Short text drawn beside the primary caret. Usually empty: repeating the
    /// headline next to the caret is noise, and rustc only labels the primary
    /// span when the label says something the headline does not.
    point: []const u8 = "",
    n_labels: u32 = 0,
    n_notes: u32 = 0,
};

// ---------------------------------------------------------------------------
// The bag
// ---------------------------------------------------------------------------

/// Stop after this many entries in one run. A single broken expression
/// otherwise reports a cascade that buries the first, real error.
pub const max_entries: u32 = 64;

/// Every diagnostic of one compilation, in Zig's two-pool wire format.
///
/// A BUILDER, NOT A FROZEN BUNDLE. Zig splits the two: `ErrorBundle.Wip`
/// accumulates and `toOwnedBundle` freezes (ErrorBundle.zig:337, :370). It has
/// to — a `Compilation` merges bundles from several threads and stores them
/// across incremental updates. A `Bag` is appended to across stages 1–6 of one
/// compilation and then read by exactly one consumer, the renderer below, so a
/// second frozen type would be a shim that only ever wrapped the same two
/// slices. This IS the Wip, and it is read in place the way `Wip.tmpBundle`
/// (ErrorBundle.zig:406) reads one. `detach` is our `toOwnedBundle`: it does
/// not change the shape, only who owns the bytes.
pub const Bag = struct {
    arena: Allocator,
    /// Every diagnostic string, NUL-terminated: headlines, caret text, label
    /// text, note bodies, fix replacements. Byte 0 is a sentinel NUL so that
    /// `String` 0 can mean "none" (ErrorBundle.zig:353).
    string_bytes: std.ArrayList(u8) = .empty,
    /// `Message` records, each followed by its `LabelRec`s and `NoteRec`s.
    extra: std.ArrayList(u32) = .empty,
    /// One handle per diagnostic, in emission order until `sort` reorders it.
    /// Zig keeps the same list (`Wip.root_list`, ErrorBundle.zig:342) and
    /// appends it to `extra` when it freezes; we never freeze, so it stays.
    /// Sorting now moves 4-byte handles instead of 56-byte rows.
    list: std.ArrayList(MessageIndex) = .empty,
    levels: Levels = .empty,
    /// Every file that took part in the compilation, in the order the
    /// preprocessor opened them. `FileId` indexes this.
    ///
    /// It lives on the Bag rather than inside `SourceMap` because BOTH
    /// provenance paths need it: a lower/parse/proof span is an offset in the
    /// preprocessed text and reaches a file through `map`, while a preprocess
    /// span is ALREADY a file-local offset (the preprocessor fails before an
    /// output text exists) and names its file directly via `Entry.file`.
    ///
    /// NOT IN THE POOLS, deliberately. A `File.text` is the whole source —
    /// hundreds of kilobytes for a foundry model — BORROWED from the arena and
    /// re-pointed by `setFileText` once comments are stripped. Interning it
    /// into `string_bytes` would copy every byte of every file on the path
    /// where no diagnostic is ever produced, to save one `dupe` in `detach`.
    /// Zig dodges the question by interning only the single `source_line` it
    /// renders (ErrorBundle.zig:64); our renderer draws several lines per
    /// diagnostic plus a patched fix line, so it needs the text itself.
    files: std.ArrayList(File) = .empty,
    /// Preprocessed offset → file. Empty until the preprocessor splices
    /// something, which is exactly when it means "offsets are source offsets".
    map: SourceMap = .empty,

    /// Dropped because the cap was reached — reported as a trailer so a
    /// truncated run never looks like a complete one.
    suppressed: u32 = 0,
    /// Dropped because an identical (code, span) was already present.
    deduped: u32 = 0,
    err_count: u32 = 0,
    warn_count: u32 = 0,

    /// (code, span.start) pairs already emitted. Lazily created: a clean
    /// compilation never allocates it.
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn init(arena: Allocator) Bag {
        return .{ .arena = arena };
    }

    // -- the string pool ----------------------------------------------------

    /// Zig writes the sentinel NUL in `Wip.init` (ErrorBundle.zig:353). We
    /// cannot: `Bag.init` is infallible on purpose, and a compilation that
    /// reports nothing must not allocate. The first string written pays for it
    /// instead — same invariant, still nothing on the happy path.
    fn addString(self: *Bag, s: []const u8) Allocator.Error!String {
        if (self.string_bytes.items.len == 0)
            try self.string_bytes.append(self.arena, 0);
        const index: String = @intCast(self.string_bytes.items.len);
        try self.string_bytes.ensureUnusedCapacity(self.arena, s.len + 1);
        self.string_bytes.appendSliceAssumeCapacity(s);
        self.string_bytes.appendAssumeCapacity(0);
        return index;
    }

    /// Formats straight into the pool. This is where the old
    /// `std.fmt.allocPrint` per message, per label and per note went.
    fn printString(self: *Bag, comptime fmt: []const u8, args: anytype) Allocator.Error!String {
        if (self.string_bytes.items.len == 0)
            try self.string_bytes.append(self.arena, 0);
        const index: String = @intCast(self.string_bytes.items.len);
        try self.string_bytes.print(self.arena, fmt, args);
        try self.string_bytes.append(self.arena, 0);
        return index;
    }

    /// `String` → bytes. 0 is "none" and decodes to the empty string, which is
    /// also what the renderer wants: an absent `point` and an empty one print
    /// the same. `ErrorBundle.nullTerminatedString` (ErrorBundle.zig:150).
    pub fn str(self: *const Bag, index: String) []const u8 {
        if (index == 0) return "";
        const bytes = self.string_bytes.items;
        const end = std.mem.indexOfScalarPos(u8, bytes, index, 0) orelse bytes.len;
        return bytes[index..end];
    }

    // -- the extra pool -----------------------------------------------------

    /// One word per field, in declaration order. `ErrorBundle.Wip.addExtra`
    /// (ErrorBundle.zig:728), widened to any u32-sized field type so a packed
    /// `Head` rides along with the plain offsets.
    fn addExtra(self: *Bag, rec: anytype) Allocator.Error!u32 {
        const fields = @typeInfo(@TypeOf(rec)).@"struct".fields;
        const index: u32 = @intCast(self.extra.items.len);
        try self.extra.ensureUnusedCapacity(self.arena, fields.len);
        inline for (fields) |f| self.extra.appendAssumeCapacity(toWord(@field(rec, f.name)));
        return index;
    }

    /// The record at `index`, plus the index just past it — where its trailing
    /// records begin. `ErrorBundle.extraData` (ErrorBundle.zig:130).
    fn extraData(self: *const Bag, comptime T: type, index: u32) struct { data: T, end: u32 } {
        var i = index;
        var out: T = undefined;
        inline for (@typeInfo(T).@"struct".fields) |f| {
            @field(out, f.name) = fromWord(f.type, self.extra.items[i]);
            i += 1;
        }
        return .{ .data = out, .end = i };
    }

    // -- reading ------------------------------------------------------------

    /// Every diagnostic, in `sort` order once `sort` has run.
    /// `ErrorBundle.getMessages` (ErrorBundle.zig:104).
    pub fn messages(self: *const Bag) []const MessageIndex {
        return self.list.items;
    }

    pub fn count(self: *const Bag) usize {
        return self.list.items.len;
    }

    /// Decode one diagnostic. `ErrorBundle.getErrorMessage`
    /// (ErrorBundle.zig:109).
    pub fn get(self: *const Bag, mi: MessageIndex) Entry {
        const m = self.extraData(Message, @intFromEnum(mi)).data;
        return .{
            .index = mi,
            .code = m.head.code,
            .severity = m.head.severity,
            .stage = m.head.stage,
            .span = .{ .start = m.span_start, .end = m.span_end },
            .file = if (m.src_file == 0) null else @enumFromInt(m.src_file - 1),
            .message = self.str(m.msg),
            .point = self.str(m.point),
            .n_labels = m.counts.labels_len,
            .n_notes = m.counts.notes_len,
        };
    }

    /// The i'th diagnostic in list order.
    pub fn at(self: *const Bag, i: usize) Entry {
        return self.get(self.list.items[i]);
    }

    /// Decodes into `buf` rather than allocating: `max_children` is a hard cap
    /// the `Builder` enforces, so the caller's array is always big enough.
    pub fn labels(self: *const Bag, e: Entry, buf: *[max_children]Label) []const Label {
        var i = @intFromEnum(e.index) + wordCount(Message);
        for (buf[0..e.n_labels]) |*out| {
            const r = self.extraData(LabelRec, i);
            i = r.end;
            out.* = .{
                .span = .{ .start = r.data.span_start, .end = r.data.span_end },
                .text = self.str(r.data.text),
            };
        }
        return buf[0..e.n_labels];
    }

    /// `ErrorBundle.getNotes` (ErrorBundle.zig:118) — except the notes are the
    /// records themselves, sitting after the labels rather than behind an
    /// index each.
    pub fn notes(self: *const Bag, e: Entry, buf: *[max_children]Note) []const Note {
        var i = @intFromEnum(e.index) + wordCount(Message) + e.n_labels * wordCount(LabelRec);
        for (buf[0..e.n_notes]) |*out| {
            const r = self.extraData(NoteRec, i);
            i = r.end;
            out.* = .{
                .kind = r.data.kind,
                .text = self.str(r.data.text),
                .fix = if (r.data.fix_repl == 0) null else .{
                    .span = .{ .start = r.data.fix_start, .end = r.data.fix_end },
                    .replacement = self.str(r.data.fix_repl),
                },
            };
        }
        return buf[0..e.n_notes];
    }

    /// Register a file and get the id that names it. The FIRST file
    /// registered is `.root`, so the preprocessor must open the top-level
    /// compilation unit before any `include.
    pub fn addFile(self: *Bag, name: []const u8, text: []const u8) Allocator.Error!FileId {
        const id: FileId = @enumFromInt(@as(u16, @intCast(self.files.items.len)));
        try self.files.append(self.arena, .{ .name = name, .text = text });
        return id;
    }

    /// Point an already-registered file at different bytes. The preprocessor
    /// registers a file before it has stripped comments from it; this is how
    /// the snippet ends up cut from the text the spans actually index.
    pub fn setFileText(self: *Bag, id: FileId, text: []const u8) void {
        const i = @intFromEnum(id);
        if (i < self.files.items.len) self.files.items[i].text = text;
    }

    pub fn fileName(self: *const Bag, id: FileId) []const u8 {
        const i = @intFromEnum(id);
        if (i >= self.files.items.len) return "<source>";
        return self.files.items[i].name;
    }

    pub fn fileText(self: *const Bag, id: FileId) []const u8 {
        const i = @intFromEnum(id);
        if (i >= self.files.items.len) return "";
        return self.files.items[i].text;
    }

    /// The no-include, no-macro case: spans index straight into `text`.
    pub fn setSingleFile(
        self: *Bag,
        name: []const u8,
        text: []const u8,
        prelude_lines: u32,
    ) Allocator.Error!void {
        _ = try self.addFile(name, text);
        self.map = .{ .segs = &.{}, .prelude_lines = prelude_lines };
    }

    /// Where a span really points. `Entry.file` short-circuits the segment
    /// search for a preprocess diagnostic, whose offset is file-local already.
    pub fn locate(self: *const Bag, span: Span, file: ?FileId) SourceMap.Resolved {
        if (file) |f| return .{ .file = f, .offset = span.start, .seg = Segment.no_parent };
        return self.map.resolve(span.start);
    }

    /// Did anything at `deny`/`forbid` level land? This, not `entries.len`, is
    /// what decides whether the compilation failed — a bag holding only
    /// warnings is a successful compilation.
    pub fn failed(self: *const Bag) bool {
        return self.err_count != 0;
    }

    pub fn isEmpty(self: *const Bag) bool {
        return self.list.items.len == 0;
    }

    /// Would a diagnostic with this code be collected at all? Stages call it
    /// to skip building an expensive message for an allowed lint.
    pub fn enabled(self: *const Bag, c: Code) bool {
        return self.levels.get(c) != .allow;
    }

    /// Start one diagnostic. See `Builder`.
    pub fn build(self: *Bag, stage: Stage, c: Code, span: Span) Builder {
        return .{ .bag = self, .stage = stage, .code = c, .span = span };
    }

    /// The whole diagnostic in one call, for the common case with no labels
    /// and no notes.
    pub fn add(
        self: *Bag,
        stage: Stage,
        c: Code,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        var b = self.build(stage, c, span);
        b.msg(fmt, args);
        return b.emit();
    }

    /// Deep-copy every borrowed byte into `gpa`, so the bag outlives the
    /// compilation arena. Our `Wip.toOwnedBundle` (ErrorBundle.zig:370),
    /// except that the shape does not change — only the owner.
    ///
    /// THE OWNERSHIP BOUNDARY. During compilation the bag allocates from the
    /// per-compilation arena — no frees, no bookkeeping, and the file texts are
    /// borrowed rather than copied. But a failed compilation frees its arena on
    /// the way out and the caller still wants to render, so exactly one place
    /// pays for a copy: here.
    ///
    /// The diagnostics themselves are now three `appendSlice`s, because the
    /// pools hold no pointers: there is nothing to fix up after the copy. What
    /// is left is the provenance sidecar — file names, file texts and the
    /// macro names in `map.segs` — which is borrowed and does need duping.
    ///
    /// An EMPTY bag is detached too, provenance and all. It used to drop the
    /// borrowed tables and return, on the grounds that a bag with no messages
    /// can never need to render one — which stopped being true when codegen
    /// became a diagnostic-producing stage (E0515): that runs after `detach`,
    /// and a model whose only diagnostic is a codegen one would have rendered
    /// with no file text and therefore no source snippet. The cost is one copy
    /// of the source per clean compile, which is what every compile that emits
    /// a single warning already paid.
    ///
    /// After this the bag must be released with `deinit(gpa)`.
    pub fn detach(self: *Bag, gpa: Allocator) Allocator.Error!void {
        var string_bytes: std.ArrayList(u8) = .empty;
        try string_bytes.appendSlice(gpa, self.string_bytes.items);
        var extra: std.ArrayList(u32) = .empty;
        try extra.appendSlice(gpa, self.extra.items);
        var list: std.ArrayList(MessageIndex) = .empty;
        try list.appendSlice(gpa, self.list.items);

        var files: std.ArrayList(File) = .empty;
        try files.appendSlice(gpa, self.files.items);
        for (files.items) |*f| {
            f.name = try gpa.dupe(u8, f.name);
            f.text = try gpa.dupe(u8, f.text);
        }

        const segs = try gpa.dupe(Segment, self.map.segs);
        for (segs) |*sg| sg.macro = try gpa.dupe(u8, sg.macro);

        self.string_bytes = string_bytes;
        self.extra = extra;
        self.list = list;
        self.files = files;
        self.map = .{ .segs = segs, .prelude_lines = self.map.prelude_lines };
        // The dedupe set was arena memory and has done its job.
        self.seen = .empty;
        self.arena = gpa;
    }

    /// Release a bag that has been through `detach`. A bag that never was is
    /// freed with its arena instead — do not call this on one.
    pub fn deinit(self: *Bag, gpa: Allocator) void {
        for (self.files.items) |f| {
            gpa.free(f.name);
            gpa.free(f.text);
        }
        for (self.map.segs) |sg| gpa.free(sg.macro);
        gpa.free(self.map.segs);
        self.string_bytes.deinit(gpa);
        self.extra.deinit(gpa);
        self.list.deinit(gpa);
        self.files.deinit(gpa);
        // `detach` emptied the dedupe set and moved the bag onto `gpa`, so
        // anything in it now was allocated by a POST-detach `emit` — a codegen
        // diagnostic. Empty for every bag that never took one.
        self.seen.deinit(gpa);
        // NOT `levels`: it is CONFIGURATION the caller owns and copied in
        // (`bag.levels = opts.lint`). Freeing it here double-frees the
        // caller's list the moment it deinits its own.
        self.* = .{ .arena = gpa };
    }

    /// Source order, then code, so a run's output is stable and diffable no
    /// matter which stage produced what. Stages already run in order, but a
    /// proof error can precede a lower error in the text.
    ///
    /// Only `list` moves — the records stay where they were written, so a
    /// `MessageIndex` handed out before a sort is still valid after one.
    pub fn sort(self: *Bag) void {
        std.mem.sort(MessageIndex, self.list.items, @as(*const Bag, self), lessThan);
    }

    fn lessThan(self: *const Bag, a: MessageIndex, b: MessageIndex) bool {
        const x = self.extraData(Message, @intFromEnum(a)).data;
        const y = self.extraData(Message, @intFromEnum(b)).data;
        if (x.span_start != y.span_start) return x.span_start < y.span_start;
        if (x.span_end != y.span_end) return x.span_end < y.span_end;
        return @intFromEnum(x.head.code) < @intFromEnum(y.head.code);
    }

    fn dedupeKey(c: Code, span: Span) u64 {
        return (@as(u64, @intFromEnum(c)) << 32) | span.start;
    }
};

/// Accumulates one diagnostic's parts, then commits.
///
/// Methods return void rather than `*Builder`, and an allocation failure is
/// latched in `oom` instead of propagating: chaining `try` through a fluent
/// interface in Zig reads worse than it builds. `emit` is the only fallible
/// call.
///
/// Text is interned into the bag's pool AS IT IS BUILT, so nothing here is a
/// pointer: the builder holds `String` indices and the records it will commit.
/// A diagnostic that is then dropped (allowed, deduped, over the cap) leaves
/// its strings behind in the pool — exactly as the old code left its
/// `allocPrint`s on the arena.
/// ponytail: no rollback index. The cap bounds the waste at a few kilobytes of
/// arena on a run that is already failing; add a mark-and-truncate in `emit`
/// if a bag ever outlives its compilation for long enough to matter.
///
/// Labels and notes live in fixed inline arrays — more than `max_children` of
/// either is not clearer for it, and this keeps the builder from touching
/// `extra` until it commits.
pub const Builder = struct {
    bag: *Bag,
    stage: Stage,
    code: Code,
    span: Span,
    file: ?FileId = null,
    message: String = 0,
    point_text: String = 0,
    labels: [max_children]LabelRec = undefined,
    n_labels: u16 = 0,
    notes: [max_children]NoteRec = undefined,
    n_notes: u16 = 0,
    oom: bool = false,

    pub fn msg(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.message = self.bag.printString(fmt, args) catch {
            self.oom = true;
            return;
        };
    }

    /// Preprocessor only: this diagnostic's offsets are inside `id`'s own
    /// text, not inside the preprocessed output. See `Entry.file`.
    pub fn inFile(self: *Builder, id: FileId) void {
        self.file = id;
    }

    /// Short text beside the PRIMARY caret. Use it when the caret needs to say
    /// something the headline does not — otherwise leave it unset.
    pub fn point(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.point_text = self.bag.printString(fmt, args) catch {
            self.oom = true;
            return;
        };
    }

    pub fn label(self: *Builder, span: Span, comptime fmt: []const u8, args: anytype) void {
        if (self.n_labels == self.labels.len) return;
        const text = self.bag.printString(fmt, args) catch {
            self.oom = true;
            return;
        };
        self.labels[self.n_labels] = .{
            .span_start = span.start,
            .span_end = span.end,
            .text = text,
        };
        self.n_labels += 1;
    }

    pub fn note(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.note, null, fmt, args);
    }

    pub fn help(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.help, null, fmt, args);
    }

    /// A help line WITH a machine-applicable rewrite. The renderer shows the
    /// patched line under the help text.
    pub fn suggest(
        self: *Builder,
        fix: Fix,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.pushNote(.help, fix, fmt, args);
    }

    /// The did-you-mean shape: rewrite the PRIMARY span. Every "unknown name"
    /// diagnostic has it — the misspelled identifier is exactly what the caret
    /// is already under — so the alternative is thirteen call sites each
    /// restating `.span = b.span`, and one of them eventually getting it wrong.
    pub fn suggestHere(self: *Builder, replacement: []const u8) void {
        self.suggest(
            .{ .span = self.span, .replacement = replacement },
            "did you mean `{s}`?",
            .{replacement},
        );
    }

    fn pushNote(
        self: *Builder,
        kind: Note.Kind,
        fix: ?Fix,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (self.n_notes == self.notes.len) return;
        const text = self.bag.printString(fmt, args) catch {
            self.oom = true;
            return;
        };
        // `addString`, not 0, even for an empty replacement: 0 is what says
        // "no fix", and a fix that replaces a span with nothing is a deletion.
        const repl: String = if (fix) |f| self.bag.addString(f.replacement) catch {
            self.oom = true;
            return;
        } else 0;
        self.notes[self.n_notes] = .{
            .kind = kind,
            .text = text,
            .fix_repl = repl,
            .fix_start = if (fix) |f| f.span.start else 0,
            .fix_end = if (fix) |f| f.span.end else 0,
        };
        self.n_notes += 1;
    }

    /// Commit. Honours the lint level, the cap and the dedupe set; a dropped
    /// diagnostic is counted, never silent.
    pub fn emit(self: *Builder) Allocator.Error!void {
        if (self.oom) return error.OutOfMemory;
        const bag = self.bag;

        const level = bag.levels.get(self.code);
        if (level == .allow) return;

        if (bag.list.items.len >= max_entries) {
            bag.suppressed += 1;
            return;
        }

        const key = Bag.dedupeKey(self.code, self.span);
        const gop = try bag.seen.getOrPut(bag.arena, key);
        if (gop.found_existing) {
            bag.deduped += 1;
            return;
        }

        const severity: Severity = switch (level) {
            .allow => unreachable,
            .warn => severityOf(self.code),
            // `--deny=W0650` promotes the warning to a hard error.
            .deny, .forbid => .err,
        };

        // The message header first, then its trailing records: the reader
        // walks them by stride from the header, so the order is the format.
        const mi: MessageIndex = @enumFromInt(try bag.addExtra(Message{
            .head = .{ .code = self.code, .severity = severity, .stage = self.stage },
            .counts = .{ .labels_len = self.n_labels, .notes_len = self.n_notes },
            .msg = self.message,
            .point = self.point_text,
            .src_file = if (self.file) |f| @as(u32, @intFromEnum(f)) + 1 else 0,
            .span_start = self.span.start,
            .span_end = self.span.end,
        }));
        for (self.labels[0..self.n_labels]) |l| _ = try bag.addExtra(l);
        for (self.notes[0..self.n_notes]) |n| _ = try bag.addExtra(n);
        try bag.list.append(bag.arena, mi);

        switch (severity) {
            .err => bag.err_count += 1,
            .warning => bag.warn_count += 1,
        }
    }
};

// ---------------------------------------------------------------------------
// "did you mean"
// ---------------------------------------------------------------------------

/// Optimal string alignment distance (Damerau-Levenshtein restricted to
/// adjacent transpositions), capped at `limit` so a hopeless pair exits early.
///
/// Bounded stack, no allocation: names longer than this are not the ones a
/// typo suggestion helps with.
pub fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
    const cap = 64;
    if (a.len > cap or b.len > cap) return limit + 1;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > b.len + limit or b.len > a.len + limit) return limit + 1;

    var prev2: [cap + 1]usize = undefined;
    var prev: [cap + 1]usize = undefined;
    var cur: [cap + 1]usize = undefined;

    for (0..b.len + 1) |j| prev[j] = j;

    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        var row_min = cur[0];
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            var v = @min(
                @min(cur[j] + 1, prev[j + 1] + 1),
                prev[j] + cost,
            );
            if (i > 0 and j > 0 and ca == b[j - 1] and a[i - 1] == cb)
                v = @min(v, prev2[j - 1] + 1);
            cur[j + 1] = v;
            row_min = @min(row_min, v);
        }
        if (row_min > limit) return limit + 1;
        prev2 = prev;
        prev = cur;
    }
    return prev[b.len];
}

/// Nearest candidate to `name`, or null when nothing is close enough.
///
/// DETERMINISM: callers feed this from `StringHashMap` iterators, whose order
/// is unspecified. Ties therefore break on the NAME, lexicographically — never
/// on "whichever the iterator yielded first", which would make the same source
/// produce different suggestions across runs and the fixture suite flaky.
pub fn didYouMean(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    // One edit per three characters, and always at least one, so `vd` still
    // suggests `vds` but `a` suggests nothing.
    const limit = @max(@as(usize, 1), name.len / 3);
    var best: ?[]const u8 = null;
    var best_d: usize = limit + 1;
    for (candidates) |c| {
        if (std.mem.eql(u8, c, name)) continue;
        const d = editDistance(name, c, limit);
        if (d > limit) continue;
        if (best == null or d < best_d or (d == best_d and std.mem.lessThan(u8, c, best.?))) {
            best = c;
            best_d = d;
        }
    }
    return best;
}

/// `didYouMean` over the keys of any `StringHashMapUnmanaged`, which is the
/// shape every symbol table in lower.zig has. Collects into the arena first so
/// the deterministic tie-break above actually sees every candidate.
pub fn didYouMeanMap(arena: Allocator, name: []const u8, map: anytype) ?[]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = map.keyIterator();
    while (it.next()) |k| names.append(arena, k.*) catch return null;
    return didYouMean(name, names.items);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// SGR escapes, or all-empty when colour is off. Keeping the "off" palette as
/// a full struct of empty strings means the renderer has exactly ONE code path:
/// there is no `if (color)` anywhere below, so the coloured and plain outputs
/// cannot drift apart.
pub const Palette = struct {
    reset: []const u8 = "",
    bold: []const u8 = "",
    err: []const u8 = "",
    warn: []const u8 = "",
    gutter: []const u8 = "",
    note: []const u8 = "",
    help: []const u8 = "",
    good: []const u8 = "",

    pub const off: Palette = .{};

    pub const on: Palette = .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .err = "\x1b[1;31m", // bold red
        .warn = "\x1b[1;33m", // bold yellow
        .gutter = "\x1b[1;34m", // bold blue
        .note = "\x1b[1;36m", // bold cyan
        .help = "\x1b[1;36m",
        .good = "\x1b[1;32m", // bold green — suggested insertions
    };

    fn forSeverity(self: Palette, s: Severity) []const u8 {
        return switch (s) {
            .err => self.err,
            .warning => self.warn,
        };
    }
};

pub const RenderOptions = struct {
    palette: Palette = .off,
    /// Draw the source snippet with carets. Off gives one `file:line:col:`
    /// line per diagnostic, which is what an editor's error parser wants.
    snippets: bool = true,
    /// Print `= help: run --explain EXXXX` after the first diagnostic carrying
    /// each code.
    explain_hint: bool = true,
    /// Print the `N errors, M warnings emitted` trailer.
    summary: bool = true,
};

/// Tabs are expanded to this many spaces before a snippet is drawn, so a caret
/// lands under the character it means. (rustc does the same.)
const tab_width = 4;

fn displayCol(line: []const u8, byte_col: u32) u32 {
    var col: u32 = 0;
    const upto = @min(byte_col, line.len);
    for (line[0..upto]) |c| col += if (c == '\t') tab_width else 1;
    return col;
}

fn writeExpanded(w: *std.Io.Writer, line: []const u8) !void {
    for (line) |c| {
        if (c == '\t') try w.splatByteAll(' ', tab_width) else try w.writeByte(c);
    }
}

/// One span, resolved all the way to something printable.
const Placed = struct {
    file: FileId,
    /// 1-based line in the ORIGINAL file.
    line: u32,
    /// 1-based display column (tabs already expanded).
    col: u32,
    /// Display width of the underline, at least 1.
    width: u32,
    text: []const u8,
    primary: bool,
};

/// Renders `bag` to `w`. Entries are sorted into source order first, so the
/// output of a run is stable regardless of which stage found what.
pub fn render(bag: *Bag, w: *std.Io.Writer, opts: RenderOptions) !void {
    if (bag.list.items.len == 0 and bag.suppressed == 0) return;
    bag.sort();

    const p = opts.palette;

    // Rendering scratch (line indices, the per-entry placed list, the
    // seen-codes set) is freed here rather than left on `bag.arena`: after
    // `detach` that arena IS the caller's gpa, so leaving it would leak on
    // every render of a detached bag.
    var scratch_state = std.heap.ArenaAllocator.init(bag.arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    // Line indices are built lazily, once per file that actually appears in a
    // diagnostic. A 60-file include tree with one error touches one index.
    const n_files = @max(bag.files.items.len, 1);
    const indices = try scratch.alloc(?LineIndex, n_files);
    @memset(indices, null);

    var explained: std.AutoHashMapUnmanaged(Code, void) = .empty;

    for (bag.messages()) |mi| {
        try renderOne(bag, scratch, w, opts, bag.get(mi), indices, &explained);
    }

    if (bag.suppressed != 0) {
        try w.print("{s}{s}:{s} {d} further diagnostic(s) not shown (limit {d})\n", .{
            p.warn, "warning", p.reset, bag.suppressed, max_entries,
        });
    }
    if (opts.summary and (bag.err_count != 0 or bag.warn_count != 0)) {
        if (bag.err_count != 0) {
            try w.print("{s}error{s}: could not compile due to {d} previous error(s)", .{
                p.err, p.reset, bag.err_count,
            });
            if (bag.warn_count != 0) try w.print("; {d} warning(s) emitted", .{bag.warn_count});
            try w.writeByte('\n');
        } else {
            try w.print("{s}warning{s}: {d} warning(s) emitted\n", .{
                p.warn, p.reset, bag.warn_count,
            });
        }
    }
}

fn lineIndexFor(bag: *Bag, scratch: Allocator, indices: []?LineIndex, file: FileId) !LineIndex {
    const i = @min(@intFromEnum(file), indices.len - 1);
    if (indices[i]) |idx| return idx;
    const idx = try LineIndex.build(scratch, bag.fileText(file));
    indices[i] = idx;
    return idx;
}

/// Line number a human should see: the prelude is prepended to the root file's
/// text but is nobody's source, so its newlines come back off.
fn userLine(bag: *const Bag, file: FileId, line: u32) u32 {
    if (file != .root) return line;
    return line -| bag.map.prelude_lines;
}

fn place(
    bag: *Bag,
    scratch: Allocator,
    indices: []?LineIndex,
    span: Span,
    file: ?FileId,
    text: []const u8,
    primary: bool,
) !?Placed {
    if (span.isNone()) return null;
    const r = bag.locate(span, file);
    const idx = try lineIndexFor(bag, scratch, indices, r.file);
    const file_text = bag.fileText(r.file);
    if (file_text.len == 0) return null;

    const loc = idx.loc(r.offset);
    const line_text = idx.lineText(file_text, loc.line);
    const start_col = displayCol(line_text, loc.col - 1);

    // A span that runs past the end of its line is clamped: an underline may
    // not wrap, and the first line is the informative one.
    const end_off = r.offset + span.len();
    const line_end = r.offset + @as(u32, @intCast(line_text.len)) - (loc.col - 1);
    const clamped = @min(end_off, line_end);
    const end_col = displayCol(line_text, clamped - r.offset + (loc.col - 1));

    return .{
        .file = r.file,
        .line = loc.line,
        .col = start_col,
        .width = @max(@as(u32, 1), end_col -| start_col),
        .text = text,
        .primary = primary,
    };
}

fn renderOne(
    bag: *Bag,
    scratch: Allocator,
    w: *std.Io.Writer,
    opts: RenderOptions,
    e: Entry,
    indices: []?LineIndex,
    explained: *std.AutoHashMapUnmanaged(Code, void),
) !void {
    const p = opts.palette;
    const sev = p.forSeverity(e.severity);
    const meta = info(e.code);

    // --- headline: `error[E0313]: unknown variable` -------------------------
    try w.print("{s}{s}[{s}]{s}{s}: {s}{s}", .{
        sev,    e.severity.word(), e.code.name(), p.reset,
        p.bold, meta.title,        p.reset,
    });
    if (e.message.len != 0) try w.print(": {s}", .{e.message});
    try w.writeByte('\n');

    const primary = try place(bag, scratch, indices, e.span, e.file, e.point, true);

    // --- location: `  --> file.va:12:5` -------------------------------------
    var width: u32 = 1;
    if (primary) |pr| {
        const shown = userLine(bag, pr.file, pr.line);
        width = digits(shown);
        try w.print("{s}{s}-->{s} {s}:{d}:{d}\n", .{
            spaces(width), p.gutter, p.reset, bag.fileName(pr.file), shown, pr.col + 1,
        });
    }

    if (opts.snippets and primary != null) {
        var placed: std.ArrayList(Placed) = .empty;
        try placed.append(scratch, primary.?);
        var lbuf: [max_children]Label = undefined;
        for (bag.labels(e, &lbuf)) |l| {
            if (try place(bag, scratch, indices, l.span, e.file, l.text, false)) |q| try placed.append(scratch, q);
        }
        // Widen the gutter to the largest line number that will be printed.
        for (placed.items) |q| width = @max(width, digits(userLine(bag, q.file, q.line)));
        try renderSnippet(bag, scratch, w, opts, indices, placed.items, e.severity, width);
    }

    // --- the rule this diagnostic enforces ----------------------------------
    if (meta.lrm.len != 0) {
        try w.print("{s}{s} ={s} {s}note{s}: LRM {s}{s}\n", .{
            spaces(width),       p.gutter, p.reset, p.note, p.reset,
            annexWord(meta.lrm), meta.lrm,
        });
    }

    // --- notes, helps, suggestions ------------------------------------------
    var nbuf: [max_children]Note = undefined;
    for (bag.notes(e, &nbuf)) |n| {
        const word = switch (n.kind) {
            .note => "note",
            .help => "help",
        };
        const colour = switch (n.kind) {
            .note => p.note,
            .help => p.help,
        };
        try w.print("{s}{s} ={s} {s}{s}{s}: {s}\n", .{
            spaces(width), p.gutter, p.reset, colour, word, p.reset, n.text,
        });
        if (n.fix) |fix| try renderFix(bag, scratch, w, opts, indices, fix, e.file, width);
    }

    // --- `--explain` hint, once per code ------------------------------------
    if (opts.explain_hint) {
        const gop = try explained.getOrPut(scratch, e.code);
        if (!gop.found_existing) {
            try w.print("{s}{s} ={s} {s}help{s}: run `fastvaf --explain {s}` for a detailed explanation\n", .{
                spaces(width), p.gutter, p.reset, p.help, p.reset, e.code.name(),
            });
        }
    }
    try w.writeByte('\n');
}

/// The ` 12 | source text` / `    | ^^^ label` block. Placed spans are grouped
/// by line; a gap between printed lines becomes `...`, like rustc.
fn renderSnippet(
    bag: *Bag,
    scratch: Allocator,
    w: *std.Io.Writer,
    opts: RenderOptions,
    indices: []?LineIndex,
    placed: []Placed,
    sev: Severity,
    width: u32,
) !void {
    const p = opts.palette;
    std.mem.sort(Placed, placed, {}, struct {
        fn f(_: void, a: Placed, b: Placed) bool {
            if (a.line != b.line) return a.line < b.line;
            return a.col < b.col;
        }
    }.f);

    try w.print("{s}{s} |{s}\n", .{ spaces(width), p.gutter, p.reset });

    var i: usize = 0;
    var prev_line: u32 = 0;
    while (i < placed.len) {
        const line = placed[i].line;
        const file = placed[i].file;
        var j = i;
        while (j < placed.len and placed[j].line == line and placed[j].file == file) j += 1;

        if (prev_line != 0 and line > prev_line + 1) try w.print("{s}...{s}\n", .{ p.gutter, p.reset });
        prev_line = line;

        const idx = try lineIndexFor(bag, scratch, indices, file);
        const text = idx.lineText(bag.fileText(file), line);
        const shown = userLine(bag, file, line);

        try w.print("{s}{d}{s} |{s} ", .{ p.gutter, shown, spaces(width -| digits(shown)), p.reset });
        try writeExpanded(w, text);
        try w.writeByte('\n');

        // One underline row per span on this line, deepest column last so the
        // labels stack instead of overlapping.
        for (placed[i..j], 0..) |q, k| {
            _ = k;
            try w.print("{s}{s} |{s} ", .{ spaces(width), p.gutter, p.reset });
            try w.splatByteAll(' ', q.col);
            const colour = if (q.primary) p.forSeverity(sev) else p.gutter;
            const mark: u8 = if (q.primary) '^' else '-';
            try w.print("{s}", .{colour});
            try w.splatByteAll(mark, q.width);
            if (q.text.len != 0) try w.print(" {s}", .{q.text});
            try w.print("{s}\n", .{p.reset});
        }
        i = j;
    }
    try w.print("{s}{s} |{s}\n", .{ spaces(width), p.gutter, p.reset });
}

/// Show a machine-applicable rewrite as the patched line, with `+` under an
/// insertion and `~` under a replacement.
fn renderFix(
    bag: *Bag,
    scratch: Allocator,
    w: *std.Io.Writer,
    opts: RenderOptions,
    indices: []?LineIndex,
    fix: Fix,
    file: ?FileId,
    width: u32,
) !void {
    const p = opts.palette;
    const r = bag.locate(fix.span, file);
    const file_text = bag.fileText(r.file);
    if (file_text.len == 0) return;
    const idx = try lineIndexFor(bag, scratch, indices, r.file);
    const loc = idx.loc(r.offset);
    const line = idx.lineText(file_text, loc.line);
    const shown = userLine(bag, r.file, loc.line);

    const cut = @min(loc.col - 1, line.len);
    const cut_end = @min(cut + fix.span.len(), line.len);

    try w.print("{s}{s} |{s}\n", .{ spaces(width), p.gutter, p.reset });
    try w.print("{s}{d}{s} |{s} ", .{ p.gutter, shown, spaces(width -| digits(shown)), p.reset });
    try writeExpanded(w, line[0..cut]);
    try w.print("{s}{s}{s}", .{ p.good, fix.replacement, p.reset });
    try writeExpanded(w, line[cut_end..]);
    try w.writeByte('\n');

    try w.print("{s}{s} |{s} ", .{ spaces(width), p.gutter, p.reset });
    try w.splatByteAll(' ', displayCol(line, @intCast(cut)));
    try w.print("{s}", .{p.good});
    // `+` when nothing was removed, `~` when text was replaced.
    try w.splatByteAll(
        if (fix.span.len() == 0) '+' else '~',
        @max(@as(usize, 1), fix.replacement.len),
    );
    try w.print("{s}\n", .{p.reset});
}

/// `"annex "` when a citation names one, `""` when it is a clause number.
///
/// The LRM numbers its clauses (`5.6.1`) and letters its annexes (`A.6.4`,
/// `C`), so a bare `LRM C` reads as a typo where `LRM annex C` reads as a
/// pointer. One test on the first byte; the citations are the fixed set in
/// `diag_code.zig` and every one of them starts with either a digit or an
/// annex letter.
fn annexWord(lrm: []const u8) []const u8 {
    return if (lrm.len != 0 and lrm[0] >= 'A' and lrm[0] <= 'H') "annex " else "";
}

fn digits(n: u32) u32 {
    var v = n;
    var d: u32 = 1;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

const spaces_pad = " " ** 24;

fn spaces(n: u32) []const u8 {
    return spaces_pad[0..@min(n, spaces_pad.len)];
}

/// `--explain EXXXX`. Wraps `Info.explain`'s pre-wrapped paragraphs verbatim —
/// they are authored at 76 columns in diag_code.zig.
pub fn explain(c: Code, w: *std.Io.Writer, palette: Palette) !void {
    const meta = info(c);
    try w.print("{s}{s}{s}: {s}{s}{s}\n", .{
        palette.bold, c.name(), palette.reset, palette.bold, meta.title, palette.reset,
    });
    if (meta.lrm.len != 0)
        try w.print("{s}LRM {s}{s}{s}\n", .{
            palette.note, annexWord(meta.lrm), meta.lrm, palette.reset,
        });
    try w.print("\n{s}\n", .{meta.explain});
}

/// One JSON object per line (JSON Lines), because that is what a build system
/// wants to stream. Shape is deliberately close to rustc's `--message-format
/// json` so existing editor plumbing can consume it.
pub fn renderJson(bag: *Bag, w: *std.Io.Writer) !void {
    bag.sort();
    var scratch_state = std.heap.ArenaAllocator.init(bag.arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const n_files = @max(bag.files.items.len, 1);
    const indices = try scratch.alloc(?LineIndex, n_files);
    @memset(indices, null);

    for (bag.messages()) |mi| {
        const e = bag.get(mi);
        const meta = info(e.code);
        try w.writeAll("{\"code\":\"");
        try w.writeAll(e.code.name());
        try w.print("\",\"level\":\"{s}\",\"stage\":\"{s}\",\"lrm\":\"{s}\",\"title\":", .{
            e.severity.word(), @tagName(e.stage), meta.lrm,
        });
        try writeJsonString(w, meta.title);
        try w.writeAll(",\"message\":");
        try writeJsonString(w, e.message);

        try w.writeAll(",\"span\":");
        try writeJsonSpan(bag, scratch, w, indices, e.span, e.file);

        try w.writeAll(",\"labels\":[");
        var lbuf: [max_children]Label = undefined;
        for (bag.labels(e, &lbuf), 0..) |l, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"text\":");
            try writeJsonString(w, l.text);
            try w.writeAll(",\"span\":");
            try writeJsonSpan(bag, scratch, w, indices, l.span, e.file);
            try w.writeByte('}');
        }

        try w.writeAll("],\"notes\":[");
        var nbuf: [max_children]Note = undefined;
        for (bag.notes(e, &nbuf), 0..) |n, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("{{\"kind\":\"{s}\",\"text\":", .{@tagName(n.kind)});
            try writeJsonString(w, n.text);
            if (n.fix) |fx| {
                try w.writeAll(",\"fix\":{\"replacement\":");
                try writeJsonString(w, fx.replacement);
                try w.writeAll(",\"span\":");
                try writeJsonSpan(bag, scratch, w, indices, fx.span, e.file);
                try w.writeByte('}');
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}\n");
    }
}

fn writeJsonSpan(
    bag: *Bag,
    scratch: Allocator,
    w: *std.Io.Writer,
    indices: []?LineIndex,
    span: Span,
    file: ?FileId,
) !void {
    if (span.isNone()) {
        try w.writeAll("null");
        return;
    }
    const r = bag.locate(span, file);
    const idx = try lineIndexFor(bag, scratch, indices, r.file);
    const loc = idx.loc(r.offset);
    try w.writeAll("{\"file\":");
    try writeJsonString(w, bag.fileName(r.file));
    try w.print(",\"line\":{d},\"col\":{d},\"byte_start\":{d},\"byte_end\":{d}}}", .{
        userLine(bag, r.file, loc.line), loc.col, span.start, span.end,
    });
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "edit distance and suggestion" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("abc", "abc", 4));
    try std.testing.expectEqual(@as(usize, 1), editDistance("abc", "abd", 4));
    // Transposition is one edit, not two.
    try std.testing.expectEqual(@as(usize, 1), editDistance("abc", "acb", 4));
    try std.testing.expect(editDistance("abc", "zzzzzz", 2) > 2);

    const cands = [_][]const u8{ "vds", "vgs", "temp" };
    try std.testing.expectEqualStrings("vds", didYouMean("vdss", &cands).?);
    try std.testing.expect(didYouMean("completely_different", &cands) == null);
}

test "suggestion ties break lexicographically, not by input order" {
    // "vas" is one edit from both. Whichever order the candidates arrive in,
    // the answer must be the same.
    const a = [_][]const u8{ "vbs", "vas_" };
    const b = [_][]const u8{ "vas_", "vbs" };
    try std.testing.expectEqualStrings(didYouMean("vas", &a).?, didYouMean("vas", &b).?);
}

test "lint levels" {
    const gpa = std.testing.allocator;
    var levels: Levels = .empty;
    defer levels.deinit(gpa);

    try std.testing.expectEqual(Level.warn, levels.get(.W0650));
    try std.testing.expectEqual(Level.deny, levels.get(.E0601));

    try levels.set(gpa, .W0650, .allow);
    try std.testing.expectEqual(Level.allow, levels.get(.W0650));

    // An error cannot be allowed away.
    try std.testing.expectError(error.CannotAllowError, levels.set(gpa, .E0601, .allow));

    // forbid is a one-way door.
    try levels.set(gpa, .W0651, .forbid);
    try std.testing.expectError(error.Forbidden, levels.set(gpa, .W0651, .allow));

    try std.testing.expect(try levels.parseFlag(gpa, "deny=W0652"));
    try std.testing.expectEqual(Level.deny, levels.get(.W0652));
    try std.testing.expect(!try levels.parseFlag(gpa, "not-a-flag"));
}

test "bag: dedupe, cap, level promotion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = Bag.init(arena_state.allocator());

    try bag.add(.lower, .E0313, .{ .start = 10, .end = 13 }, "unknown variable {s}", .{"vd"});
    // Same code, same start ⇒ deduped.
    try bag.add(.lower, .E0313, .{ .start = 10, .end = 13 }, "unknown variable {s}", .{"vd"});
    try std.testing.expectEqual(@as(usize, 1), bag.count());
    try std.testing.expectEqual(@as(u32, 1), bag.deduped);
    try std.testing.expectEqual(@as(u32, 1), bag.err_count);
    try std.testing.expect(bag.failed());

    // A warning does not fail the compilation.
    try bag.add(.proof, .W0650, .{ .start = 20, .end = 24 }, "", .{});
    try std.testing.expectEqual(@as(u32, 1), bag.warn_count);
    try std.testing.expectEqual(@as(u32, 1), bag.err_count);

    // ...until it is denied.
    try bag.levels.set(arena_state.allocator(), .W0650, .deny);
    try bag.add(.proof, .W0650, .{ .start = 30, .end = 34 }, "", .{});
    try std.testing.expectEqual(@as(u32, 2), bag.err_count);

    // ...or allowed, in which case it is not collected at all.
    try bag.levels.set(arena_state.allocator(), .W0650, .allow);
    const before = bag.count();
    try bag.add(.proof, .W0650, .{ .start = 40, .end = 44 }, "", .{});
    try std.testing.expectEqual(before, bag.count());
}

test "bag: cap counts what it drops" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = Bag.init(arena_state.allocator());

    for (0..max_entries + 10) |i| {
        try bag.add(.lower, .E0313, .{ .start = @intCast(i * 4), .end = @intCast(i * 4 + 2) }, "x", .{});
    }
    try std.testing.expectEqual(@as(usize, max_entries), bag.count());
    try std.testing.expectEqual(@as(u32, 10), bag.suppressed);
}

test "bag: the flat records survive a round trip, in order, through a sort" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = Bag.init(arena_state.allocator());

    // Emitted out of source order, so `sort` has something to do and the
    // handles have to stay valid across it.
    var b = bag.build(.lower, .E0313, .{ .start = 50, .end = 52 });
    b.msg("second", .{});
    b.label(.{ .start = 51, .end = 53 }, "one", .{});
    b.label(.{ .start = 54, .end = 55 }, "two", .{});
    // An EMPTY replacement is a deletion, not "no fix": the two must not
    // collapse, which is the whole reason `String` 0 is reserved.
    b.suggest(.{ .span = .{ .start = 50, .end = 52 }, .replacement = "" }, "drop it", .{});
    b.note("plain", .{});
    try b.emit();

    try bag.add(.parse, .E0207, .{ .start = 10, .end = 12 }, "first", .{});
    bag.sort();

    try std.testing.expectEqualStrings("first", bag.at(0).message);

    const e = bag.at(1);
    try std.testing.expectEqualStrings("second", e.message);
    // No `point` was set: `String` 0 decodes to the empty string.
    try std.testing.expectEqualStrings("", e.point);
    try std.testing.expectEqual(Stage.lower, e.stage);
    try std.testing.expectEqual(Severity.err, e.severity);
    try std.testing.expectEqual(@as(u32, 50), e.span.start);
    try std.testing.expect(e.file == null);

    var lbuf: [max_children]Label = undefined;
    const ls = bag.labels(e, &lbuf);
    try std.testing.expectEqual(@as(usize, 2), ls.len);
    try std.testing.expectEqualStrings("one", ls[0].text);
    try std.testing.expectEqualStrings("two", ls[1].text);
    try std.testing.expectEqual(@as(u32, 55), ls[1].span.end);

    var nbuf: [max_children]Note = undefined;
    const ns = bag.notes(e, &nbuf);
    try std.testing.expectEqual(@as(usize, 2), ns.len);
    try std.testing.expectEqual(Note.Kind.help, ns[0].kind);
    try std.testing.expectEqualStrings("", ns[0].fix.?.replacement);
    try std.testing.expectEqual(@as(u32, 52), ns[0].fix.?.span.end);
    try std.testing.expectEqual(Note.Kind.note, ns[1].kind);
    try std.testing.expect(ns[1].fix == null);
}

test "line index" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = "aaa\nbbbb\n\nccc";
    const idx = try LineIndex.build(arena_state.allocator(), text);

    try std.testing.expectEqual(Loc{ .line = 1, .col = 1 }, idx.loc(0));
    try std.testing.expectEqual(Loc{ .line = 1, .col = 3 }, idx.loc(2));
    try std.testing.expectEqual(Loc{ .line = 2, .col = 1 }, idx.loc(4));
    try std.testing.expectEqual(Loc{ .line = 4, .col = 2 }, idx.loc(11));
    try std.testing.expectEqualStrings("bbbb", idx.lineText(text, 2));
    try std.testing.expectEqualStrings("", idx.lineText(text, 3));
    try std.testing.expectEqualStrings("ccc", idx.lineText(text, 4));
}

/// Renders a bag to an arena-owned string. Test helper, and the shape a host
/// that wants the text rather than a writer would use.
fn renderToString(bag: *Bag, opts: RenderOptions) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(bag.arena, &buf);
    defer buf = aw.toArrayList();
    try render(bag, &aw.writer, opts);
    return aw.writer.buffered();
}

test "render: full diagnostic with label, note, suggestion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module r(a, b);
        \\  parameter real k = 1.0;
        \\  analog I(a, b) <+ V(a, b) / k;
        \\endmodule
        \\
    ;
    var bag = Bag.init(arena);
    try bag.setSingleFile("res.va", src, 0);

    const k_decl = @as(u32, @intCast(std.mem.indexOf(u8, src, "k = 1.0").?));
    const divisor = @as(u32, @intCast(std.mem.lastIndexOfScalar(u8, src, 'k').?));

    var b = bag.build(.proof, .E0601, .{ .start = divisor, .end = divisor + 1 });
    b.msg("divisor is parameter `k`", .{});
    b.point("divisor", .{});
    b.label(.{ .start = k_decl, .end = k_decl + 1 }, "`k` is unconstrained: (-inf, inf)", .{});
    b.suggest(
        .{ .span = Span.at(k_decl + 7), .replacement = " from (0:inf)" },
        "constrain the parameter so zero is excluded",
        .{},
    );
    try b.emit();

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });

    // Headline carries severity, code and the catalogue title.
    try std.testing.expect(std.mem.startsWith(u8, out, "error[E0601]: divisor cannot be proven non-zero: divisor is parameter `k`\n"));
    // Location resolves to the right line and column.
    try std.testing.expect(std.mem.indexOf(u8, out, "--> res.va:3:31\n") != null);
    // Both the primary caret and the secondary label are drawn.
    try std.testing.expect(std.mem.indexOf(u8, out, "^ divisor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- `k` is unconstrained") != null);
    // The LRM citation comes from the code table, not from the message.
    try std.testing.expect(std.mem.indexOf(u8, out, "= note: LRM 4.2.4") != null);
    // The suggestion renders as a patched line plus an insertion ruler.
    try std.testing.expect(std.mem.indexOf(u8, out, "= help: constrain the parameter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "parameter real k = 1.0 from (0:inf);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+++++++++++++") != null);
    // Lines 2 and 3 are adjacent, so nothing is elided.
    try std.testing.expect(std.mem.indexOf(u8, out, "...") == null);
}

test "render: a gap between labelled lines is elided" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\parameter real k = 1.0;
        \\real filler_a;
        \\real filler_b;
        \\analog I(a, b) <+ V(a, b) / k;
        \\
    ;
    var bag = Bag.init(arena);
    try bag.setSingleFile("gap.va", src, 0);
    const k_decl = @as(u32, @intCast(std.mem.indexOf(u8, src, "k = 1.0").?));
    const divisor = @as(u32, @intCast(std.mem.lastIndexOfScalar(u8, src, 'k').?));

    var b = bag.build(.proof, .E0601, .{ .start = divisor, .end = divisor + 1 });
    b.label(.{ .start = k_decl, .end = k_decl + 1 }, "declared here", .{});
    try b.emit();

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    // Lines 1 and 4 are shown; 2 and 3 collapse to `...`.
    try std.testing.expect(std.mem.indexOf(u8, out, "...") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "filler_a") == null);
}

test "render: colour is opt-in and structural" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag = Bag.init(arena);
    try bag.setSingleFile("x.va", "analog begin\n  x = 1;\nend\n", 0);
    try bag.add(.lower, .E0313, .{ .start = 15, .end = 16 }, "no variable `x`", .{});
    try bag.add(.proof, .W0650, .{ .start = 15, .end = 16 }, "", .{});

    const plain = try renderToString(&bag, .{});
    try std.testing.expect(std.mem.indexOfScalar(u8, plain, 0x1b) == null);

    var bag2 = Bag.init(arena);
    try bag2.setSingleFile("x.va", "analog begin\n  x = 1;\nend\n", 0);
    try bag2.add(.lower, .E0313, .{ .start = 15, .end = 16 }, "no variable `x`", .{});
    try bag2.add(.proof, .W0650, .{ .start = 15, .end = 16 }, "", .{});
    const coloured = try renderToString(&bag2, .{ .palette = .on });

    // Error red and warning yellow are distinct, and both appear.
    try std.testing.expect(std.mem.indexOf(u8, coloured, "\x1b[1;31merror[E0601") == null);
    try std.testing.expect(std.mem.indexOf(u8, coloured, "\x1b[1;31merror[E0313]") != null);
    try std.testing.expect(std.mem.indexOf(u8, coloured, "\x1b[1;33mwarning[W0650]") != null);
    // A warning alone does not fail the compilation.
    try std.testing.expectEqual(@as(u32, 1), bag2.err_count);
    try std.testing.expectEqual(@as(u32, 1), bag2.warn_count);
}

test "render: tabs expand so carets line up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "module m;\n\t\tbadtok\nendmodule\n";
    var bag = Bag.init(arena);
    try bag.setSingleFile("t.va", src, 0);
    const at = @as(u32, @intCast(std.mem.indexOf(u8, src, "badtok").?));
    try bag.add(.parse, .E0207, .{ .start = at, .end = at + 6 }, "", .{});

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    // Two tabs become eight spaces in the source line AND in the caret row, so
    // the six carets sit under the six characters of `badtok`.
    try std.testing.expect(std.mem.indexOf(u8, out, "|         badtok") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "|         ^^^^^^") != null);
    // The reported column is the display column, not the byte column.
    try std.testing.expect(std.mem.indexOf(u8, out, "t.va:2:9") != null);
}

test "render: json is one object per line and escapes properly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag = Bag.init(arena);
    try bag.setSingleFile("j.va", "analog x;\n", 0);
    var b = bag.build(.lower, .E0313, .{ .start = 7, .end = 8 });
    b.msg("quote \" and \\ and newline", .{});
    b.help("try `y`", .{});
    try b.emit();

    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    try renderJson(&bag, &aw.writer);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":\"E0313\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\" and \\\\ and") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":1,\"col\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"help\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
}

test "render: prelude lines are subtracted from reported line numbers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two lines of annex-D prelude, then the user's first line.
    const src = "// prelude\n// prelude\nmodule m; endmodule\n";
    var bag = Bag.init(arena);
    try bag.setSingleFile("u.va", src, 2);
    const at = @as(u32, @intCast(std.mem.indexOf(u8, src, "module").?));
    try bag.add(.parse, .E0205, .{ .start = at, .end = at + 6 }, "", .{});

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    // Physical line 3, user line 1.
    try std.testing.expect(std.mem.indexOf(u8, out, "u.va:1:1") != null);
}

test "explain prints the catalogue entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena_state.allocator(), &buf);
    try explain(.W0650, &aw.writer, .off);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "W0650: unit is not provably finite"));
    try std.testing.expect(std.mem.indexOf(u8, out, "@setFloatMode(.optimized)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--allow=W0650") != null);
}

test "detach survives the compilation arena, and deinit is leak-free" {
    const gpa = std.testing.allocator;
    var bag: Bag = undefined;

    // Everything below is allocated from an arena that dies before we render,
    // which is exactly the failed-compilation shape.
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        bag = Bag.init(arena);
        const src = "module m;\n  analog x = 1;\nendmodule\n";
        try bag.setSingleFile("owned.va", src, 0);

        // Offset 19 is the `x` in `analog x = 1;`.
        var b = bag.build(.lower, .E0313, .{ .start = 19, .end = 20 });
        b.msg("`{s}`", .{"x"});
        b.point("not declared", .{});
        b.label(.{ .start = 12, .end = 18 }, "in this block", .{});
        b.suggest(.{ .span = Span.at(12), .replacement = "real x; " }, "declare it", .{});
        try b.emit();

        try bag.detach(gpa);
    }
    defer bag.deinit(gpa);

    // The arena is gone. Rendering must still work off gpa-owned bytes.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = aw.toArrayList();
    try render(&bag, &aw.writer, .{ .explain_hint = false, .summary = false });
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "error[E0313]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "owned.va:2:10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^ not declared") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- in this block") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "real x; analog x = 1;") != null);
}

test "detach on a clean bag allocates nothing" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    var bag = Bag.init(arena_state.allocator());
    try bag.setSingleFile("clean.va", "module m; endmodule\n", 0);
    try bag.detach(gpa);
    arena_state.deinit();
    defer bag.deinit(gpa);
    try std.testing.expect(bag.isEmpty());
    try std.testing.expect(!bag.failed());
}

test "source map resolves includes and macro expansions" {
    const segs = [_]Segment{
        .{ .out_start = 0, .in_start = 0, .file = .root, .kind = .verbatim },
        .{ .out_start = 5, .in_start = 0, .file = @enumFromInt(1), .kind = .verbatim },
        .{ .out_start = 10, .in_start = 5, .file = .root, .kind = .verbatim },
        .{ .out_start = 14, .in_start = 0, .file = .root, .kind = .macro, .parent = 2, .macro = "FOO" },
    };
    const map: SourceMap = .{ .segs = &segs };

    const a = map.resolve(2);
    try std.testing.expectEqual(FileId.root, a.file);
    try std.testing.expectEqual(@as(u32, 2), a.offset);

    const b = map.resolve(6);
    try std.testing.expectEqual(@as(FileId, @enumFromInt(1)), b.file);
    try std.testing.expectEqual(@as(u32, 1), b.offset);

    // Inside an expansion: report the invocation site, not a phantom offset.
    const c = map.resolve(16);
    try std.testing.expectEqual(FileId.root, c.file);
    try std.testing.expectEqual(@as(u32, 5), c.offset);
    try std.testing.expectEqualStrings("FOO", segs[c.seg].macro);

    // An empty map is the identity.
    const none: SourceMap = .empty;
    try std.testing.expectEqual(@as(u32, 99), none.resolve(99).offset);
}
