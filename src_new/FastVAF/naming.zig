//! Codegen support — stable declaration naming + the source-unit tracker.
//! This is the ONE Zig-like algorithm FastVAF owns (see docs/architecture/
//! 03-codegen.html#naming and 02-incremental.html). No LRM section; it exists to
//! make the external `zig -fincremental` skip unchanged units.
//!
//! Why it matters: `zig` re-analyzes at per-declaration granularity and tracks
//! declarations by NAME across edits (TrackedInst + src_hash). If FastVAF emits
//! a stable name for an unchanged unit, `zig` skips it. If names churn (the old
//! `v{d}` scheme), everything re-Semas. FastVAF's only job is stable names +
//! stable order; `zig` does the actual incremental work.
//!
//! DOD: names are built into a reused scratch buffer; no per-call allocation
//! beyond the returned owned slice.
//!
//! ABSOLUTE RULE (docs/architecture/03-codegen.html#canonicalization): nothing
//! that feeds a name may be a MIR index. Not `@intFromEnum(Mir.Value)`, not
//! `Mir.Inst`, not a `node_order` index. Only stable leaf identities — module
//! name, node NAMES, source identifiers — plus, where two units genuinely
//! collide, a group-local ordinal. Inserting one line in the .va renumbers
//! every later Value; a name built from one renumbers with it, and every
//! downstream declaration re-Semas. Do not reintroduce it.

const std = @import("std");
const Mir = @import("mir.zig");
const Lower = @import("lower.zig");
const token = @import("token.zig");

/// Identifies one emitted source unit. LRM units: §5.6 contribution,
/// §4.7 user function, §5.3.2 named block, §4.5 analog operator.
pub const Unit = struct {
    role: Role,
    /// For a contribution: access fn + node pair (e.g. "I_drain_source").
    /// For a named unit: its source name. STABLE across edits — never an ordinal
    /// unless disambiguating a genuine same-target collision.
    ///
    /// ALREADY SANITIZED: a target is a `_`-joined path of `sanitize`d leaves.
    /// `unitName` does NOT re-sanitize it (sanitization is not idempotent, and
    /// sanitizing a joined path instead of its leaves is not injective —
    /// {"a_b","c"} and {"a","b_c"} would collide). Build targets with
    /// `sanitize` per leaf, or let `enumerateUnits` do it.
    target: []const u8,
    /// Only set (>0) when two units share (role,target) in the same scope.
    disambig: u16 = 0,
};

pub const Role = enum {
    analog,
    analog_initial,
    function,
    block,
    analog_op,
    /// §9.4 the module's display tasks, chained into one root by
    /// `Lower.finishDisplays`. Like `common` it is deliberately NOT produced by
    /// `enumerateUnits`: there is exactly one per module, it carries no class-6
    /// verdict, and a phantom entry in the canonical order would desynchronize
    /// `proof.Verdict.unit_modes`. codegen names it directly with `unitName`.
    display,
    /// Not a source unit: the declaration codegen hoists the subexpressions
    /// SHARED by several units into, so the common core is emitted once instead
    /// of once per unit (docs/architecture/03-codegen.html#hoisting). It is
    /// deliberately NOT produced by `enumerateUnits` — `proof.Verdict`'s
    /// `unit_modes` is indexed by the canonical unit order below, and a phantom
    /// entry there would desynchronize the two. codegen builds its name
    /// directly with `unitName`.
    common,
};

/// Longest name we will build. Overflow is an error, never a silent truncation
/// (truncation would break injectivity).
///
/// Sized from the SOURCE bound so that no legal model can hit it: §2.7 caps an
/// identifier at 1024 characters, sanitization is 3x worst case (`Zxx` per
/// escaped byte), and the widest key holds two of them plus separators and a
/// role suffix — 2*3*1024 + slack. A stack array this size is fine: it only
/// ever lives in leaf helpers, never on a recursive path.
pub const max_name_len = 8192;

// ---------------------------------------------------------------------------
// Sanitization — Verilog-A identifier → Zig identifier, INJECTIVELY
// ---------------------------------------------------------------------------
//
// §2.7 simple identifiers are already legal Zig, but §2.8.1 escaped identifiers
// (`\bus[0]`, `\a+b`) carry arbitrary printable bytes, and node names may
// contain `_`, which is our separator alphabet. Injectivity is not optional: two
// units that sanitize alike become one duplicate Zig decl.
//
// Escape marker is `Z` (not `_`) precisely so that a sanitized leaf can never
// begin, end, or double a `_`. That gives the whole grammar a unique parse:
//
//   name  := leaf "__" role "__" leaf-path ("__" digits)?
//   leaf  := [A-Za-z0-9_]*   with no "__", no leading/trailing "_"
//   escape:= "Z" hex hex     (so a literal 'Z' is escaped to "Z5a")
//
// Decoding is unambiguous: a `Z` always starts an escape, a `_` is always
// literal. Nothing else in the engine decodes these — the property that matters
// is that the encoding is injective.

fn hexDigit(v: u8) u8 {
    return "0123456789abcdef"[v & 0xf];
}

/// Append `name` to `b`, escaping everything that would break injectivity or
/// Zig's identifier grammar.
fn sanitizeInto(b: *Buf, name: []const u8) error{NoSpaceLeft}!void {
    for (name, 0..) |c, i| {
        const bare = switch (c) {
            'a'...'z', 'A'...'Y' => true,
            // A Zig identifier may not start with a digit.
            '0'...'9' => i != 0,
            // Interior `_` survives (readability: `v_ds` stays `v_ds`). A
            // leading/trailing one, or one before another `_`, is escaped so no
            // leaf ever produces `__` or touches the separator.
            '_' => i != 0 and i + 1 < name.len and name[i + 1] != '_',
            else => false, // 'Z' included: it is the escape marker
        };
        if (bare) {
            try b.byte(c);
        } else {
            try b.byte('Z');
            try b.byte(hexDigit(c >> 4));
            try b.byte(hexDigit(c));
        }
    }
}

/// Sanitize one identifier leaf into `buf`. Injective: distinct inputs give
/// distinct outputs. Use this on every source name before it enters a Unit
/// target or any other emitted declaration name.
pub fn sanitize(buf: []u8, name: []const u8) error{NoSpaceLeft}![]const u8 {
    var b: Buf = .{ .buf = buf };
    try sanitizeInto(&b, name);
    // Character-legal is not Zig-legal: annex B does not reserve `pub`, `fn`,
    // `error`, `u32`..., so a model may legitimately name a parameter one of
    // them — `bsim4va.va:1088` declares `MPRnb( pub , ...)`, which emitted a
    // `Model` field spelled `pub` and broke the generated file at the struct.
    //
    // Marked with a trailing `Z` rather than `@"..."` quoting: the name is also
    // a hash input for the incremental-naming scheme above, and every consumer
    // interpolates it bare (`model.{s}`, `{s}__given`). `Z` stays injective —
    // it is the escape marker, so `sanitizeInto` emits it only as `Z<hi><lo>`,
    // and a trailing `Z` with no two digits after it cannot arise any other way.
    if (isZigReserved(b.slice())) try b.byte('Z');
    return b.slice();
}

/// Zig keywords and primitive type names — the identifiers that are legal in
/// Verilog-A but cannot be a bare declaration name in the emitted Zig.
fn isZigReserved(name: []const u8) bool {
    return std.zig.Token.keywords.has(name) or std.zig.primitives.isPrimitive(name);
}

test "sanitize escapes Zig keywords and primitives" {
    var buf: [64]u8 = undefined;
    // bsim4va.va:1088 — the case that motivated this.
    try std.testing.expectEqualStrings("pubZ", try sanitize(&buf, "pub"));
    try std.testing.expectEqualStrings("fnZ", try sanitize(&buf, "fn"));
    try std.testing.expectEqualStrings("errorZ", try sanitize(&buf, "error"));
    try std.testing.expectEqualStrings("f64Z", try sanitize(&buf, "f64"));
    // Non-reserved names are untouched — no baseline churn for ordinary models.
    try std.testing.expectEqualStrings("vth", try sanitize(&buf, "vth"));
    try std.testing.expectEqualStrings("public", try sanitize(&buf, "public"));
    // Injectivity at the boundary: a source name that already ends in `Z` has
    // that `Z` escaped, so it cannot collide with the keyword marker.
    const pubZ_src = try sanitize(&buf, "pubZ");
    try std.testing.expect(!std.mem.eql(u8, "pubZ", pubZ_src));
}

/// Bounded appender. `std.fmt.bufPrint` cannot do the per-byte escaping, and a
/// fixed buffer keeps `unitName` allocation-free (the stub's DOD note).
const Buf = struct {
    buf: []u8,
    len: usize = 0,

    fn byte(b: *Buf, c: u8) error{NoSpaceLeft}!void {
        if (b.len == b.buf.len) return error.NoSpaceLeft;
        b.buf[b.len] = c;
        b.len += 1;
    }

    fn str(b: *Buf, s: []const u8) error{NoSpaceLeft}!void {
        if (b.len + s.len > b.buf.len) return error.NoSpaceLeft;
        @memcpy(b.buf[b.len..][0..s.len], s);
        b.len += s.len;
    }

    fn slice(b: *const Buf) []const u8 {
        return b.buf[0..b.len];
    }
};

// ---------------------------------------------------------------------------
// The structural key
// ---------------------------------------------------------------------------

/// Build the stable structural key:  <module>__<role>__<target>[__<disambig>]
///
/// module + role + target are insert-tolerant: none of them is a position. The
/// disambig suffix is emitted only for disambig > 0, so the first (and, in the
/// common case, only) member of a collision group keeps a positionless name
/// even when a second member is later added next to it.
pub fn unitName(
    buf: []u8,
    module: []const u8,
    unit: Unit,
) error{NoSpaceLeft}![]const u8 {
    var b: Buf = .{ .buf = buf };
    try sanitizeInto(&b, module);
    try b.str("__");
    try b.str(@tagName(unit.role)); // closed set, already a legal leaf
    try b.str("__");
    try b.str(unit.target); // pre-sanitized, see Unit.target
    if (unit.disambig != 0) {
        try b.str("__");
        const printed = try std.fmt.bufPrint(b.buf[b.len..], "{d}", .{unit.disambig});
        b.len += printed.len;
    }
    return b.slice();
}

// ---------------------------------------------------------------------------
// Unit enumeration
// ---------------------------------------------------------------------------

/// THE CANONICAL UNIT ORDER (proof.zig's `Verdict.unit_modes` and codegen.zig's
/// declaration emission MUST both index units this way):
///
///   1. every `Lower.contributions[i]`, in table order — which is source order
///      of the first `<+` to that (access, node pair), or of each individual
///      §5.6.7 indirect statement (those are never deduped). Role `.analog`;
///      several indirect contributions to one branch therefore land in the same
///      (role, target) collision group and take group-local ordinals.
///   2. every stateful analog operator (§4.5) / event function (§5.10) /
///      analog-kernel-control task (§9.17) `call` in the MIR, walked
///      block-creation order (`Mir.blockIter`) then intra-block emission order
///      (`Mir.blockInsts`). Role `.analog_op`.
///
///      The §9.17 entries are the synthetic `$bound_step` / `$discontinuity`
///      calls `Lower.finishKernelCtl` appends AFTER every analog block, so they
///      are always last within (2) and in that fixed order. They carry no
///      per-unit `Instance` field of their own (the two §9.17 fields are
///      unconditional members of `Instance`); the unit exists so `updateState`
///      has one named function to evaluate the requested value with.
///
/// Both walks are append-order walks over deterministic tables, so the order is
/// a pure function of the source. Within a (role, target) collision group,
/// disambig is 0,1,2… in that same order.
///
/// `gpa` should be the per-compilation arena: the returned slice AND each
/// `Unit.target` are allocated from it and are freed together with it.
pub fn enumerateUnits(gpa: std.mem.Allocator, mir: *const Mir, lower: *const Lower) ![]Unit {
    var units: std.ArrayList(Unit) = .empty;
    errdefer units.deinit(gpa);
    var scratch: [max_name_len]u8 = undefined;

    // (1) contributions — §5.6. Target is the ACCESS FUNCTION plus the NODE
    // NAMES (never node_order indices: inserting a net renumbers those).
    for (lower.contributions.items) |c| {
        var b: Buf = .{ .buf = &scratch };
        // §4.4: the two access roles are closed even when a user nature renames
        // the access identifier (§3.6.1.4), so V/I is the canonical spelling.
        try b.str(switch (c.access) {
            .potential => "V",
            .flow => "I",
        });
        for ([2]u16{ c.hi, c.lo }) |n| {
            try b.byte('_');
            // §1.3.1.1 global ground is not a node_order slot. Spell it "0"
            // (SPICE's ground node): `sanitize` escapes a leading digit, so no
            // real net — not even one literally named `gnd` — can collide.
            if (n == Lower.ground) try b.byte('0') else try sanitizeInto(&b, lower.nodeName(n));
        }
        try units.append(gpa, .{ .role = .analog, .target = try gpa.dupe(u8, b.slice()) });
    }

    // (2) stateful analog operators — §4.5. codegen keys their Instance state
    // fields off this unit id, so adding an unrelated operator must not
    // renumber existing state; that is exactly what the (role,target)+disambig
    // key gives us.
    var blocks = mir.blockIter();
    while (blocks.next()) |block| {
        var insts = mir.blockInsts(block);
        while (insts.next()) |inst| {
            if (mir.instOp(inst) != .call) continue;
            const callee = mir.instData(inst).call.name;
            if (!isStatefulAnalogOp(callee)) continue;
            // The `$` of a §9.17 task is dropped, not escaped: codegen looks the
            // OpKind up from `Unit.target`, and `sanitize` would turn it into
            // `Z24bound_step`. No collision is possible — every other unit
            // target here is a reserved keyword (annex B), which no user
            // identifier can be.
            const bare = if (callee[0] == '$') callee[1..] else callee;
            const t = try gpa.dupe(u8, try sanitize(&scratch, bare));
            try units.append(gpa, .{ .role = .analog_op, .target = t });
        }
    }

    assignDisambig(units.items);
    return units.toOwnedSlice(gpa);
}

/// Does this `call` callee name a per-instance-stateful analog operator?
/// Reuses token.zig's annex-A.8.2/A.6.5 groups rather than restating them.
pub fn isStatefulAnalogOp(name: []const u8) bool {
    // §9.17 kernel control: not keywords (they are `$` system tasks), but they
    // need a unit for the same reason — `updateState` evaluates it and writes
    // the result where the host can read it.
    if (std.mem.eql(u8, name, "$bound_step") or std.mem.eql(u8, name, "$discontinuity")) return true;
    const tag = token.keyword_map.get(name) orelse return false;
    // §4.5.13 limexp and §4.5.14 ddx are pure functions of their argument — no
    // state, so no unit and no Instance field.
    if (tag == .kw_limexp or tag == .kw_ddx) return false;
    return token.isFilterFunction(tag) or token.isEventFunction(tag);
}

/// Assign the within-group ordinal: the n-th unit sharing a (role, target) with
/// an EARLIER unit gets disambig = n. First member keeps 0 ⇒ no suffix ⇒ its
/// name is unchanged when a second member appears later.
///
// ponytail: O(n²) over units. A module has tens of them; switch to a
// StringHashMap keyed on role++target if a model ever shows up with thousands.
fn assignDisambig(units: []Unit) void {
    for (units, 0..) |*u, i| {
        var n: u16 = 0;
        for (units[0..i]) |prev| {
            if (prev.role == u.role and std.mem.eql(u8, prev.target, u.target)) n += 1;
        }
        u.disambig = n;
    }
}

// ponytail: `.function` (§4.7) and `.block` (§5.3.2) units are never
// enumerated, because lower.zig INLINES user functions and named blocks into
// the caller's CFG — there is no separate MIR region to emit a decl from, and a
// phantom unit here would desynchronize proof.Verdict from codegen. The roles
// and `unitName` support stay, so the day lowering stops inlining, this file
// only grows two loops over `lower.module.?.functions` / the named SeqBlocks.
// Same for `.analog_initial`: §5.2.1 forbids contributions there, so it emits
// no units today.
//
// ponytail: an analog-operator target is just its callee name ("ddt"), so N
// ddt's in one module collide and take disambig 0..N-1 — inserting one in the
// middle shifts the later ones (bounded local re-Sema, the documented
// trade-off in 03-codegen.html). Qualifying the target with the enclosing
// contribution would shrink the groups, but lower.zig does not record which
// contribution a call belongs to; add that link there first.

// DEFERRED (optional upgrade, docs/architecture/03-codegen.html#naming): a full
// Zig-style TrackedInst matcher that retains the previous unit list and maps
// new→old by structural similarity, surviving arbitrary reorders. Only build it
// if profiling shows same-target reordering is a real hotspot. The structural
// key above is sufficient to be "zig-faithful" — it produces stable names.

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Ast = @import("ast.zig");
const diag = @import("diag.zig");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    mir: Mir = .{ .name = "mymod" },
    file: Ast.SourceFile = .empty,
    low: Lower = undefined,
    /// Naming is tested on a hand-built Lower with no source behind it, so the
    /// bag exists only to satisfy the signature: nothing here diagnoses.
    bag: diag.Bag = undefined,

    fn init(f: *Fixture) !void {
        const a0 = f.arena.allocator();
        f.bag = diag.Bag.init(a0);
        f.low = Lower.init(a0, &f.mir, &f.file, "", &.{}, &f.bag);
        const a = f.arena.allocator();
        try f.low.node_order.appendSlice(a, &.{ "drain", "gate", "source" });
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }

    /// enumerate + name, in the canonical order.
    fn names(f: *Fixture, out: *std.ArrayList([]const u8)) !void {
        const a = f.arena.allocator();
        const units = try enumerateUnits(a, &f.mir, &f.low);
        for (units) |u| {
            var buf: [max_name_len]u8 = undefined;
            try out.append(a, try a.dupe(u8, try unitName(&buf, f.mir.name, u)));
        }
    }
};

test "inserting a contribution for a different target renames nothing" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();

    // I(drain,source) and V(gate,gnd)
    try f.low.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 2 });
    try f.low.contributions.append(a, .{ .access = .potential, .hi = 1, .lo = Lower.ground });

    var before: std.ArrayList([]const u8) = .empty;
    try f.names(&before);
    try std.testing.expectEqualStrings("mymod__analog__I_drain_source", before.items[0]);
    try std.testing.expectEqualStrings("mymod__analog__V_gate_0", before.items[1]);

    // Insert a contribution for a DIFFERENT target. THE key property: every
    // pre-existing name must come back byte-identical, so `zig`'s TrackedInst
    // + src_hash skip those declarations entirely.
    try f.low.contributions.append(a, .{ .access = .flow, .hi = 1, .lo = 2 });

    var after: std.ArrayList([]const u8) = .empty;
    try f.names(&after);
    try std.testing.expectEqual(@as(usize, 3), after.items.len);
    for (before.items, after.items[0..before.items.len]) |b, x| {
        try std.testing.expectEqualStrings(b, x);
    }
    try std.testing.expectEqualStrings("mymod__analog__I_gate_source", after.items[2]);
}

test "same-target collisions take group-local ordinals, first stays bare" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();

    _ = try f.mir.addBlock(a);
    const ddt = try f.mir.internString(a, "ddt");
    const transition = try f.mir.internString(a, "transition");
    const ln = try f.mir.internString(a, "ln"); // not an analog operator: no unit
    _ = try f.mir.emitCall(a, .entry, ddt, &.{});
    _ = try f.mir.emitCall(a, .entry, ln, &.{});
    _ = try f.mir.emitCall(a, .entry, transition, &.{});
    _ = try f.mir.emitCall(a, .entry, ddt, &.{});

    var got: std.ArrayList([]const u8) = .empty;
    try f.names(&got);
    try std.testing.expectEqual(@as(usize, 3), got.items.len);
    try std.testing.expectEqualStrings("mymod__analog_op__ddt", got.items[0]);
    try std.testing.expectEqualStrings("mymod__analog_op__transition", got.items[1]);
    try std.testing.expectEqualStrings("mymod__analog_op__ddt__1", got.items[2]);
}

test "sanitize is injective on the names that would otherwise collide" {
    var b0: [max_name_len]u8 = undefined;
    var b1: [max_name_len]u8 = undefined;

    // readable common case survives untouched
    try std.testing.expectEqualStrings("v_ds", try sanitize(&b0, "v_ds"));

    // pairs that a naive `_`-join would map together
    const pairs = [_][2][]const u8{
        .{ "a_b", "a" }, // vs a later leaf "b"
        .{ "_a", "Za" },
        .{ "a_", "a" },
        .{ "a__b", "a_b" },
        .{ "bus[0]", "bus0" },
        .{ "Z", "Z5a" },
        .{ "0", "Z30" },
    };
    for (pairs) |p| {
        const s0 = try sanitize(&b0, p[0]);
        const s1 = try sanitize(&b1, p[1]);
        try std.testing.expect(!std.mem.eql(u8, s0, s1));
        // and no sanitized leaf may contain the "__" separator or touch its edges
        try std.testing.expect(std.mem.indexOf(u8, s0, "__") == null);
        try std.testing.expect(s0[0] != '_' and s0[s0.len - 1] != '_');
    }
}

test "names never overflow silently" {
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, unitName(&small, "a_very_long_module", .{
        .role = .analog,
        .target = "I_a_b",
    }));
}

test "§9.17 kernel-control units drop the `$` and stay after the operator units" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();

    try f.low.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 2 });
    _ = try f.mir.addBlock(a);
    const ddt = try f.mir.internString(a, "ddt");
    const bs = try f.mir.internString(a, "$bound_step");
    const disc = try f.mir.internString(a, "$discontinuity");
    _ = try f.mir.emitCall(a, .entry, ddt, &.{});
    // `Lower.finishKernelCtl` appends these last, in this order.
    _ = try f.mir.emitCall(a, .entry, bs, &.{});
    _ = try f.mir.emitCall(a, .entry, disc, &.{});

    var got: std.ArrayList([]const u8) = .empty;
    try f.names(&got);
    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    // (1) contributions first — proof.zig indexes unit_modes by exactly this.
    try std.testing.expectEqualStrings("mymod__analog__I_drain_source", got.items[0]);
    try std.testing.expectEqualStrings("mymod__analog_op__ddt", got.items[1]);
    // The `$` is DROPPED, not escaped to `Z24`: codegen recovers the OpKind
    // from `Unit.target`.
    try std.testing.expectEqualStrings("mymod__analog_op__bound_step", got.items[2]);
    try std.testing.expectEqualStrings("mymod__analog_op__discontinuity", got.items[3]);
}
