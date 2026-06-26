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
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isScalar(field.type)) {
            // Card keys are lowercased at parse; VA fields keep their spec
            // spelling (BSIMSOI `VTH0`).
            const key = comptime blk: {
                var buf: [field.name.len]u8 = undefined;
                for (field.name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                const frozen = buf;
                break :blk frozen;
            };
            if (try number(params, seen, &key)) |num| {
                @field(target.*, field.name) = try castField(field.type, num);
                markGiven(target, field.name);
            } else {
                inline for (comptime aliasesOf(field.name)) |alias| {
                    if (try number(params, seen, alias)) |num| {
                        @field(target.*, field.name) = try castField(field.type, num);
                        markGiven(target, field.name);
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
/// `value != 0`.
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
        // VerA appends `Z` to a VA name that is a Zig primitive or keyword
        // (`u0`, `type`, `pub`); the card keeps the VA spelling.
        if (escaped(field)) |va| {
            out[n] = va;
            n += 1;
        }
        const frozen = out;
        return frozen[0..n];
    }
}

fn escaped(comptime field: []const u8) ?[]const u8 {
    if (field.len < 2 or field[field.len - 1] != 'Z') return null;
    const stem = field[0 .. field.len - 1];
    if (std.zig.primitives.isPrimitive(stem) or std.zig.Token.getKeyword(stem) != null) return stem;
    return null;
}

test "VerA escapes bind under the VA name; ordinary trailing Z does not" {
    const M = struct { u0Z: f64 = 0, typeZ: i64 = 1, pubZ: f64 = 0, RZ: f64 = 0 };
    var m: M = .{};
    try apply(&m, &.{
        .{ .key = "u0", .value = 400 }, .{ .key = "type", .value = -1 },
        .{ .key = "pub", .value = 2 },  .{ .key = "r", .value = 5 },
    }).unwrap();
    try std.testing.expectEqual(M{ .u0Z = 400, .typeZ = -1, .pubZ = 2, .RZ = 0 }, m);
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
