//! The parameter binder: card `name=value` pairs onto a device's Model or
//! Instance fields. eval.zig compiles it into every device object behind
//! `DeviceVtable.bind_model`/`bind_instance`, so built-in and runtime-loaded
//! devices bind a card identically. Cites ngspice's inpgval.c (integer
//! rounding), the bjt.c, dio.c and res.c IOPR tables (alternate spellings)
//! and LRM §9.19 `$param_given`.
const std = @import("std");

/// One card pair, key lowercased. `value` is null when the netlist value is
/// not a number (an unresolved name or expression): binding that to a known
/// field is an error, naming an unknown field is not.
pub const Param = struct { key: []const u8, value: ?f64 };

/// Binding outcome, as a plain enum so it can cross the object boundary.
pub const BindStatus = enum(u8) {
    ok,
    unresolved_parameter,
    non_finite_parameter,
    parameter_out_of_range,

    /// Converts back to the caller's own error values.
    pub fn unwrap(self: BindStatus) error{ UnresolvedParameter, NonFiniteParameter, ParameterOutOfRange }!void {
        return switch (self) {
            .ok => {},
            .unresolved_parameter => error.UnresolvedParameter,
            .non_finite_parameter => error.NonFiniteParameter,
            .parameter_out_of_range => error.ParameterOutOfRange,
        };
    }
};

/// Binds `params` onto every scalar field of `target.*`. A field takes the
/// first pair whose key is its lowercased name; only when there is none do its
/// alternate spellings (`aliasesOf`) apply, in table order, the last match
/// winning. Keys matching no field are ignored. On error, fields bound before
/// the failing one keep their new values.
pub fn apply(target: anytype, params: []const Param) BindStatus {
    applyKv(target, params) catch |err| return switch (err) {
        error.UnresolvedParameter => .unresolved_parameter,
        error.NonFiniteParameter => .non_finite_parameter,
        error.ParameterOutOfRange => .parameter_out_of_range,
    };
    return .ok;
}

fn applyKv(target: anytype, params: []const Param) !void {
    const T = @TypeOf(target.*);
    // BSIMSOI's Model has ~1600 fields, each lowered and alias-resolved at
    // comptime.
    @setEvalBranchQuota(1_000_000);
    const keys = Keys(T).table;
    const first = firstPairs(keys, params);
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (comptime isScalar(field_type)) {
            if (try number(params, first[comptime slot(keys, lowered(field_name))])) |num| {
                @field(target.*, field_name) = try castField(field_type, num);
                markGiven(target, field_name);
            } else {
                inline for (comptime aliasesOf(field_name)) |alias| {
                    if (try number(params, first[comptime slot(keys, alias)])) |num| {
                        @field(target.*, field_name) = try castField(field_type, num);
                        markGiven(target, field_name);
                    }
                }
            }
        }
    }
}

/// Sets `known[i]` for every `params[i]` whose key `apply` would bind on a
/// `T`: a scalar field's lowercased name or one of its `aliasesOf`.
/// Entries already set stay set. Asserts that `known` is parallel to
/// `params`.
pub fn markKnown(comptime T: type, params: []const Param, known: []bool) void {
    std.debug.assert(known.len == params.len);
    const keys = Keys(T).table;
    for (params, known) |p, *hit| {
        if (slotOf(keys, p.key) != null) hit.* = true;
    }
}

/// `firstPairs` slot of a key no pair names.
const absent = std.math.maxInt(u32);

/// For each of `keys`, the index of the first pair keyed so, or `absent`.
/// One binary search per pair, so a card costs O(pairs), not O(fields).
fn firstPairs(comptime keys: []const []const u8, params: []const Param) [keys.len]u32 {
    std.debug.assert(params.len < absent);
    var first: [keys.len]u32 = @splat(absent);
    if (keys.len == 0) return first;
    for (params, 0..) |p, i| if (slotOf(keys, p.key)) |k| {
        if (first[k] == absent) first[k] = @intCast(i);
    };
    return first;
}

/// The value of `params[index]`, or null when `index` is `absent`. Errors
/// rather than letting a recognized field fall back to its default.
fn number(params: []const Param, index: u32) !?f64 {
    if (index == absent) return null;
    const value = params[index].value orelse return error.UnresolvedParameter;
    if (!std.math.isFinite(value)) return error.NonFiniteParameter;
    return value;
}

/// The keys `apply` binds on a `T`, sorted and unique: every scalar field's
/// lowercased name and its `aliasesOf`. A key's index is its `firstPairs`
/// slot. Two fields may share a key (`vto` is a field and `vt0`'s alias).
fn Keys(comptime T: type) type {
    return struct {
        const table: []const []const u8 = blk: {
            @setEvalBranchQuota(10_000_000);
            const info = @typeInfo(T).@"struct";
            var n: usize = 0;
            for (info.field_names, info.field_types) |name, ty| {
                if (isScalar(ty)) n += 1 + aliasesOf(name).len;
            }
            var all: [n][]const u8 = undefined;
            var i: usize = 0;
            for (info.field_names, info.field_types) |name, ty| {
                if (!isScalar(ty)) continue;
                all[i] = lowered(name);
                i += 1;
                for (aliasesOf(name)) |alias| {
                    all[i] = alias;
                    i += 1;
                }
            }
            std.mem.sortUnstable([]const u8, &all, {}, keyLess);
            var unique: usize = 0;
            for (all) |key| {
                // Keys are never empty: "" would bind nothing anyway.
                std.debug.assert(key.len > 0);
                if (unique > 0 and std.mem.eql(u8, all[unique - 1], key)) continue;
                all[unique] = key;
                unique += 1;
            }
            const frozen = all;
            break :blk frozen[0..unique];
        };
    };
}

fn keyLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn keyOrder(key: []const u8, item: []const u8) std.math.Order {
    return std.mem.order(u8, key, item);
}

/// The index of `key` in the sorted `keys`, or null.
fn slotOf(keys: []const []const u8, key: []const u8) ?usize {
    return std.sort.binarySearch([]const u8, keys, key, keyOrder);
}

/// `slotOf` for a key `Keys` is known to hold.
fn slot(comptime keys: []const []const u8, comptime key: []const u8) usize {
    return comptime slotOf(keys, key).?;
}

/// `s` lowercased: card keys are lowercased at parse, VA fields keep their
/// spec spelling (BSIMSOI `VTH0`).
fn lowered(comptime s: []const u8) []const u8 {
    comptime {
        var buf: [s.len]u8 = undefined;
        for (s, &buf) |c, *o| o.* = std.ascii.toLower(c);
        const frozen = buf;
        return &frozen;
    }
}

/// Sets the `<field>__given` flag VerA emits for LRM §9.19 `$param_given`, if
/// the type has one. Without it a bound value still takes the model's
/// defaulted branch (bsim3's derived k1/k2/vth0 defaults, mos1's NSUB rules).
pub fn markGiven(target: anytype, comptime field: []const u8) void {
    const T = @TypeOf(target.*);
    if (comptime @hasField(T, field ++ "__given"))
        @field(target.*, field ++ "__given") = true;
}

fn isScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        else => false, // else: every other type is a non-scalar field
    };
}

/// Converts a card value to field type `T`. Integers round half up and must
/// land in range, floats must stay finite after narrowing, and bools are
/// `value != 0`. Fails with `NonFiniteParameter` on NaN or infinity and
/// `ParameterOutOfRange` when the value does not fit `T`.
pub fn castField(comptime T: type, value: f64) !T {
    if (!std.math.isFinite(value)) return error.NonFiniteParameter;
    return switch (@typeInfo(T)) {
        .float => blk: {
            const converted: T = @floatCast(value);
            if (!std.math.isFinite(converted)) return error.ParameterOutOfRange;
            break :blk converted;
        },
        .int => |info| blk: {
            // A power-of-two bound is exact in f64; maxInt(i64) is not.
            const upper: f64 = comptime std.math.pow(f64, 2, info.bits - @intFromBool(info.signedness == .signed));
            const lower: f64 = if (info.signedness == .signed) -upper else 0;
            // Rounds half up like ngspice inpgval.c:31 (`floor(0.5 + x)`): PDK
            // cards write integer parameters as reals (IHP's `level = 103.60`).
            const rounded = @floor(0.5 + value);
            if (rounded < lower or rounded >= upper) return error.ParameterOutOfRange;
            break :blk @intFromFloat(rounded);
        },
        .bool => value != 0,
        else => @compileError("unsupported numeric field type"), // else: binding a non-numeric field is a compile error by design
    };
}

/// Card keys accepted for a field besides its own name, in probe order:
/// ngspice IOPR alternate spellings, then the VA name behind a VerA escape.
///
/// The table is shared by every device, so an alias is only safe when no model
/// declares it as a parameter of its own. That is why dio.c's `js` for `is`
/// is missing: the MOS models declare both `is` and `js`.
fn aliasesOf(comptime field: []const u8) []const []const u8 {
    const pairs = [_][2][]const u8{
        .{ "vt0", "vto" },
        .{ "vto", "vt0" },
        .{ "vaf", "va" },
        .{ "VAR", "vb" },
        .{ "ikf", "ik" },
        .{ "cjs", "ccs" },
        // BJT depletion-cap alternates (bjt.c IOPR).
        .{ "vje", "pe" },
        .{ "mje", "me" },
        .{ "vjc", "pc" },
        .{ "mjc", "mc" },
        .{ "vjs", "ps" },
        .{ "mjs", "ms" },
        // Diode alternates (dio.c IOPR). `cjo`/`vj` exist only in diode.va
        // and vdmos.va, `trs`/`cta`/`tpb` only in diode.va.
        .{ "tnom", "tref" },
        .{ "cjo", "cj0" },
        .{ "cjo", "cj" },
        .{ "vj", "pb" },
        .{ "trs", "trs1" },
        .{ "cta", "ctc" },
        .{ "tpb", "tvj" },
        // Resistor noise switch (res.c IOPR, HSPICE NOISE=).
        .{ "noisy", "noise" },
    };
    comptime {
        var out: [pairs.len + 1][]const u8 = undefined;
        var n: usize = 0;
        for (pairs) |p| {
            if (std.mem.eql(u8, field, p[0])) {
                out[n] = p[1];
                n += 1;
            }
        }
        // The card keeps the VA spelling of a name VerA escaped.
        if (escaped(field)) |va| {
            out[n] = va;
            n += 1;
        }
        const frozen = out;
        return frozen[0..n];
    }
}

/// The lowercased VA name behind a VerA-sanitized field, or null when VerA
/// left the name alone. VerA appends `Z` to a Zig primitive or keyword
/// (`u0`, `type`, `pub`) and writes a literal `Z` and a leading, trailing or
/// doubled `_` as `Z<hex><hex>` (`ab__cd` is `abZ5f_cd`, `Zin` is `Z5ain`).
fn escaped(comptime field: []const u8) ?[]const u8 {
    if (field.len >= 2 and field[field.len - 1] == 'Z') {
        const stem = field[0 .. field.len - 1];
        if (std.zig.primitives.isPrimitive(stem) or std.zig.Token.getKeyword(stem) != null) return stem;
    }
    var out: [field.len]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < field.len) : (n += 1) {
        const hex: ?u8 = if (field[i] == 'Z' and i + 2 < field.len)
            std.fmt.parseInt(u8, field[i + 1 .. i + 3], 16) catch null
        else
            null;
        out[n] = std.ascii.toLower(hex orelse field[i]);
        i += if (hex == null) 1 else 3;
    }
    if (n == field.len) return null;
    const frozen = out;
    return frozen[0..n];
}

test "VerA escapes bind under the VA name; ordinary trailing Z does not" {
    const M = struct { u0Z: f64 = 0, typeZ: i64 = 1, pubZ: f64 = 0, RZ: f64 = 0, abZ5f_cd: f64 = 0, Z5ain: f64 = 0 };
    var m: M = .{};
    try apply(&m, &.{
        .{ .key = "u0", .value = 400 },   .{ .key = "type", .value = -1 },
        .{ .key = "pub", .value = 2 },    .{ .key = "r", .value = 5 },
        .{ .key = "ab__cd", .value = 3 }, .{ .key = "zin", .value = 50 },
    }).unwrap();
    try std.testing.expectEqual(M{ .u0Z = 400, .typeZ = -1, .pubZ = 2, .RZ = 0, .abZ5f_cd = 3, .Z5ain = 50 }, m);
}

test "first pair wins; an alias applies only when the field's own key is absent" {
    const M = struct { vt0: f64 = 0, cjo: f64 = 0, cjo__given: bool = false };
    var m: M = .{};
    try apply(&m, &.{
        .{ .key = "vto", .value = 9 }, .{ .key = "vt0", .value = 1 }, .{ .key = "vt0", .value = 2 },
        .{ .key = "cj", .value = 4 },  .{ .key = "cj0", .value = 3 },
    }).unwrap();
    // cjo: both aliases present, table order cj0 then cj, the last write stays.
    try std.testing.expectEqual(M{ .vt0 = 1, .cjo = 4, .cjo__given = true }, m);
    try std.testing.expectEqual(BindStatus.unresolved_parameter, apply(&m, &.{.{ .key = "vt0", .value = null }}));
    try std.testing.expectEqual(BindStatus.ok, apply(&m, &.{ .{ .key = "unknown", .value = null }, .{ .key = "", .value = null } }));
}

test castField {
    const cast = castField;
    try std.testing.expectEqual(@as(i32, 3), try cast(i32, 2.5));
    try std.testing.expectEqual(@as(i32, -2), try cast(i32, -2.5));
    try std.testing.expectEqual(@as(i32, 104), try cast(i32, 103.6));
    try std.testing.expectEqual(@as(u8, 255), try cast(u8, 255.4));
    try std.testing.expectError(error.ParameterOutOfRange, cast(u8, 255.5));
    try std.testing.expectEqual(@as(u8, 0), try cast(u8, -0.5));
    try std.testing.expectError(error.ParameterOutOfRange, cast(u8, -0.6));
    try std.testing.expectEqual(@as(i8, -128), try cast(i8, -128.5));
    try std.testing.expectError(error.ParameterOutOfRange, cast(i8, 127.5));
    // The i64/u64 bounds are powers of two, exact in f64.
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), try cast(i64, -0x1p63));
    try std.testing.expectError(error.ParameterOutOfRange, cast(i64, 0x1p63));
    try std.testing.expectError(error.ParameterOutOfRange, cast(u64, 0x1p64));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_f800), try cast(u64, 0x1.fffffffffffffp63));
    try std.testing.expectError(error.ParameterOutOfRange, cast(f32, 1e39));
    try std.testing.expectEqual(@as(f32, 0), try cast(f32, 1e-50));
    try std.testing.expectEqual(true, try cast(bool, 0.5));
    try std.testing.expectEqual(false, try cast(bool, -0.0));
    inline for (.{ f64, f32, i32, u8, bool }) |T| {
        try std.testing.expectError(error.NonFiniteParameter, cast(T, std.math.nan(f64)));
        try std.testing.expectError(error.NonFiniteParameter, cast(T, -std.math.inf(f64)));
    }
}

test "apply: errors by status, earlier fields keep their new values" {
    const M = struct { a: f64 = 0, b: u8 = 0, c: f64 = 0, noisy: bool = true, noisy__given: bool = false };
    var m: M = .{};
    // Fields bind in declaration order: `a` lands before `b` fails.
    try std.testing.expectEqual(BindStatus.parameter_out_of_range, apply(&m, &.{ .{ .key = "b", .value = 300 }, .{ .key = "a", .value = 1 } }));
    try std.testing.expectEqual(@as(f64, 1), m.a);
    try std.testing.expectEqual(BindStatus.non_finite_parameter, apply(&m, &.{.{ .key = "c", .value = std.math.inf(f64) }}));
    // An unresolved alias is as fatal as an unresolved name.
    try std.testing.expectEqual(BindStatus.unresolved_parameter, apply(&m, &.{.{ .key = "noise", .value = null }}));
    try std.testing.expectEqual(BindStatus.ok, apply(&m, &.{.{ .key = "noise", .value = 0 }}));
    try std.testing.expectEqual(M{ .a = 1, .noisy = false, .noisy__given = true }, m);
    try std.testing.expectEqual(BindStatus.ok, apply(&m, &.{}));
}

test markKnown {
    const T = struct { vto: f64 = 0, w: f64 = 0, list: [2]f64 = .{ 0, 0 } };
    const params = [_]Param{ .{ .key = "vt0", .value = 1 }, .{ .key = "ww", .value = 1 }, .{ .key = "w", .value = 1 }, .{ .key = "list", .value = 1 } };
    var known: [params.len]bool = @splat(false);
    markKnown(T, &params, &known);
    try std.testing.expectEqual([_]bool{ true, false, true, false }, known);
}

test BindStatus {
    inline for (@typeInfo(BindStatus).@"enum".field_names) |name| {
        const status = @field(BindStatus, name);
        if (status.unwrap()) |_| {
            try std.testing.expectEqual(BindStatus.ok, status);
        } else |err| {
            try std.testing.expect(status != .ok);
            try std.testing.expectEqual(status, switch (err) {
                error.UnresolvedParameter => BindStatus.unresolved_parameter,
                error.NonFiniteParameter => BindStatus.non_finite_parameter,
                error.ParameterOutOfRange => BindStatus.parameter_out_of_range,
            });
        }
    }
}

/// The binder before `Keys`: every field scans every pair. Kept as the
/// oracle the differential test checks `apply` and `markKnown` against.
const linear = struct {
    fn apply(target: anytype, params: []const Param) BindStatus {
        bindAll(target, params) catch |err| return switch (err) {
            error.UnresolvedParameter => .unresolved_parameter,
            error.NonFiniteParameter => .non_finite_parameter,
            error.ParameterOutOfRange => .parameter_out_of_range,
        };
        return .ok;
    }

    fn bindAll(target: anytype, params: []const Param) !void {
        const info = @typeInfo(@TypeOf(target.*)).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            if (comptime isScalar(field_type)) {
                if (try firstNumber(params, comptime lowered(field_name))) |num| {
                    @field(target.*, field_name) = try castField(field_type, num);
                    markGiven(target, field_name);
                } else {
                    inline for (comptime aliasesOf(field_name)) |alias| {
                        if (try firstNumber(params, alias)) |num| {
                            @field(target.*, field_name) = try castField(field_type, num);
                            markGiven(target, field_name);
                        }
                    }
                }
            }
        }
    }

    fn markKnown(comptime T: type, params: []const Param, known: []bool) void {
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            if (comptime isScalar(field_type)) {
                markKey(params, comptime lowered(field_name), known);
                inline for (comptime aliasesOf(field_name)) |alias| markKey(params, alias, known);
            }
        }
    }

    fn markKey(params: []const Param, key: []const u8, known: []bool) void {
        for (params, known) |p, *hit| if (std.mem.eql(u8, p.key, key)) {
            hit.* = true;
        };
    }

    fn firstNumber(params: []const Param, key: []const u8) !?f64 {
        for (params) |p| if (std.mem.eql(u8, p.key, key)) {
            const value = p.value orelse return error.UnresolvedParameter;
            if (!std.math.isFinite(value)) return error.NonFiniteParameter;
            return value;
        };
        return null;
    }
};

test "apply and markKnown match the linear-scan oracle on random cards" {
    // Shared keys (`vto` is a field and `vt0`'s alias), two aliases (`cjo`),
    // VerA escapes, a mixed-case field, a narrow int, a non-scalar field.
    const M = struct {
        vt0: f64 = 0,
        vto: f64 = 0,
        vto__given: bool = false,
        cjo: f64 = 0,
        cjo__given: bool = false,
        noisy: bool = true,
        u0Z: f64 = 0,
        typeZ: i64 = 1,
        abZ5f_cd: f64 = 0,
        VTH0: f64 = 0,
        b: u8 = 0,
        list: [2]f64 = .{ 0, 0 },
    };
    const key_pool = [_][]const u8{
        "vt0",  "vto",        "cjo",  "cj0",  "cj", "noisy",  "noise",    "u0",      "u0z",
        "type", "typez",      "vth0", "VTH0", "b",  "ab__cd", "abz5f_cd", "unknown", "",
        "list", "vto__given",
    };
    const inf = std.math.inf(f64);
    const value_pool = [_]?f64{ 1, -2.5, 0, 300, 0.5, 1e300, null, std.math.nan(f64), inf, -inf };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var params: [12]Param = undefined;
    for (0..20_000) |_| {
        const card = params[0..random.uintLessThan(usize, params.len + 1)];
        for (card) |*p| p.* = .{
            .key = key_pool[random.uintLessThan(usize, key_pool.len)],
            .value = value_pool[random.uintLessThan(usize, value_pool.len)],
        };
        var got: M = .{};
        var want: M = .{};
        try std.testing.expectEqual(linear.apply(&want, card), apply(&got, card));
        try std.testing.expectEqual(want, got);
        var known_got: [params.len]bool = @splat(false);
        var known_want: [params.len]bool = @splat(false);
        markKnown(M, card, known_got[0..card.len]);
        linear.markKnown(M, card, known_want[0..card.len]);
        try std.testing.expectEqual(known_want, known_got);
    }
}

test "the first pair for a key decides, even when it is null or non-finite" {
    const M = struct { b: u8 = 0, b__given: bool = false };
    var m: M = .{};
    try std.testing.expectEqual(BindStatus.ok, apply(&m, &.{ .{ .key = "b", .value = 1 }, .{ .key = "b", .value = null } }));
    try std.testing.expectEqual(M{ .b = 1, .b__given = true }, m);
    try std.testing.expectEqual(BindStatus.unresolved_parameter, apply(&m, &.{ .{ .key = "b", .value = null }, .{ .key = "b", .value = 2 } }));
    try std.testing.expectEqual(BindStatus.non_finite_parameter, apply(&m, &.{ .{ .key = "b", .value = std.math.nan(f64) }, .{ .key = "b", .value = 2 } }));
    try std.testing.expectEqual(M{ .b = 1, .b__given = true }, m);
}

test "aliases: probed only when the own key is absent, in table order" {
    const M = struct { vt0: f64 = 0, vto: f64 = 0, cjo: f64 = 0 };
    var m: M = .{};
    // `vt0` is present, so its alias `vto` is never probed for `vt0`, but
    // `vto` is the `vto` field's own key: the null still fails there.
    try std.testing.expectEqual(BindStatus.unresolved_parameter, apply(&m, &.{ .{ .key = "vt0", .value = 1 }, .{ .key = "vto", .value = null } }));
    // One key binds both the field it names and the field it aliases.
    m = .{};
    try std.testing.expectEqual(BindStatus.ok, apply(&m, &.{.{ .key = "vto", .value = 5 }}));
    try std.testing.expectEqual(M{ .vt0 = 5, .vto = 5 }, m);
    // `cj0` probes before `cj`: its null fails though `cj` has a value.
    try std.testing.expectEqual(BindStatus.unresolved_parameter, apply(&m, &.{ .{ .key = "cj", .value = 4 }, .{ .key = "cj0", .value = null } }));
    // A null alias is harmless when the own key binds first.
    const C = struct { cjo: f64 = 0 };
    var c: C = .{};
    try std.testing.expectEqual(BindStatus.ok, apply(&c, &.{ .{ .key = "cj", .value = null }, .{ .key = "cjo", .value = 7 } }));
    try std.testing.expectEqual(C{ .cjo = 7 }, c);
}

test "absent keys leave defaults; card keys match lowercased names exactly" {
    const M = struct { VTH0: f64 = 0.5, VTH0__given: bool = false, w: f64 = 1 };
    var m: M = .{};
    // Callers lowercase card keys; an uppercase key names nothing.
    const params = [_]Param{ .{ .key = "VTH0", .value = 9 }, .{ .key = "x", .value = 1 } };
    try std.testing.expectEqual(BindStatus.ok, apply(&m, &params));
    try std.testing.expectEqual(M{}, m);
    var known: [params.len]bool = @splat(false);
    markKnown(M, &params, &known);
    try std.testing.expectEqual([_]bool{ false, false }, known);
    try std.testing.expectEqual(BindStatus.ok, apply(&m, &.{.{ .key = "vth0", .value = 0.7 }}));
    try std.testing.expectEqual(M{ .VTH0 = 0.7, .VTH0__given = true }, m);
}

test "a type without scalar fields binds nothing" {
    const M = struct { list: [2]f64 = .{ 1, 2 } };
    var m: M = .{};
    const params = [_]Param{.{ .key = "list", .value = null }};
    try std.testing.expectEqual(BindStatus.ok, apply(&m, &params));
    try std.testing.expectEqual(BindStatus.ok, apply(&m, &.{}));
    var known: [1]bool = .{false};
    markKnown(M, &params, &known);
    try std.testing.expect(!known[0]);
}
