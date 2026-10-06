//! The parameter binder: card `name=value` pairs onto a device's Model or
//! Instance fields. eval.zig compiles it into every device object behind
//! `DeviceVtable.bind_model`/`bind_instance`, so built-in and runtime-loaded
//! devices bind a card identically.
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
    // BSIMSOI's Model has ~1600 fields, each lowered and alias-scanned at
    // comptime.
    @setEvalBranchQuota(1_000_000);
    // A field whose key's `keyBit` no pair sets skips the scan: an instance
    // card binds a dozen pairs against BSIM4's ~1000 fields.
    var seen: u64 = 0;
    for (params) |p| seen |= keyBit(p.key);
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (comptime isScalar(field_type)) {
            // Card keys are lowercased at parse; VA fields keep their spec
            // spelling (BSIMSOI `VTH0`).
            const key = comptime blk: {
                var buf: [field_name.len]u8 = undefined;
                for (field_name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                const frozen = buf;
                break :blk frozen;
            };
            if (try number(params, seen, &key)) |num| {
                @field(target.*, field_name) = try castField(field_type, num);
                markGiven(target, field_name);
            } else {
                inline for (comptime aliasesOf(field_name)) |alias| {
                    if (try number(params, seen, alias)) |num| {
                        @field(target.*, field_name) = try castField(field_type, num);
                        markGiven(target, field_name);
                    }
                }
            }
        }
    }
}

/// The value of the first pair keyed `key`, or null when there is none.
/// Errors rather than letting a recognized field fall back to its default.
/// `seen` is the `keyBit` union of `params`' keys.
fn number(params: []const Param, seen: u64, key: []const u8) !?f64 {
    if (seen & keyBit(key) == 0) return null;
    for (params) |p| if (std.mem.eql(u8, p.key, key)) {
        const value = p.value orelse return error.UnresolvedParameter;
        if (!std.math.isFinite(value)) return error.NonFiniteParameter;
        return value;
    };
    return null;
}

/// One of 64 bits from a key's first byte and length; 0 for "".
fn keyBit(key: []const u8) u64 {
    if (key.len == 0) return 0;
    return @as(u64, 1) << @truncate(key[0] *% 7 +% @as(u8, @truncate(key.len)));
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
        else => false,
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
        else => @compileError("unsupported numeric field type"),
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
        .{ .key = "u0", .value = 400 }, .{ .key = "type", .value = -1 },
        .{ .key = "pub", .value = 2 },  .{ .key = "r", .value = 5 },
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
