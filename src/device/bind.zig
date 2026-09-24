//! The one parameter binder: card `name=value` pairs onto a device's Model or
//! Instance fields. Built-in and runtime-loaded devices reach it through the
//! same vtable entry (`DeviceVtable.bind_model` / `bind_instance`), compiled
//! into each device's own object by eval.zig, so a card binds identically
//! whichever way the device was loaded.
const std = @import("std");

/// One card pair. `value` is null when the netlist value is not a number (an
/// unresolved name or expression): binding it to a known field is an error,
/// naming an unknown field is not.
pub const Param = struct { key: []const u8, value: ?f64 };

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

/// Bind `params` onto every scalar field of `target.*`. A field takes the FIRST
/// pair whose key is its lowercased name; only when there is none do its
/// alternate spellings (`aliasesOf`) apply, each in table order.
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
    // BSIMSOI's Model has ~1600 fields and each runs a comptime char-lowering
    // loop on top of the aliasesOf scan.
    @setEvalBranchQuota(1_000_000);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isScalar(field.type)) {
            // Card keys are lowercased at parse; VA fields keep their spec
            // spelling (BSIMSOI `VTH0`), so match the lowercased field name.
            const key = comptime blk: {
                var buf: [field.name.len]u8 = undefined;
                for (field.name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                const frozen = buf;
                break :blk frozen;
            };
            if (try number(params, &key)) |num| {
                @field(target.*, field.name) = try castField(field.type, num);
                markGiven(target, field.name);
            } else {
                inline for (comptime aliasesOf(field.name)) |alias| {
                    if (try number(params, alias)) |num| {
                        @field(target.*, field.name) = try castField(field.type, num);
                        markGiven(target, field.name);
                    }
                }
            }
        }
    }
}

/// A recognized field cannot silently fall back to its default.
fn number(params: []const Param, key: []const u8) !?f64 {
    for (params) |p| if (std.mem.eql(u8, p.key, key)) {
        const value = p.value orelse return error.UnresolvedParameter;
        if (!std.math.isFinite(value)) return error.NonFiniteParameter;
        return value;
    };
    return null;
}

/// §9.19 `$param_given`: VerA emits a `<name>__given: bool = false` companion
/// for every parameter the model queries. Binding a card value without raising
/// the flag leaves the model in its "defaulted" branch — bsim3's b3temp-style
/// derived defaults (k1/k2/vth0/vfb interdependence) mis-fire, and mos1's
/// NSUB-driven overrides never ran. No-op for fields without a companion.
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

pub fn castField(comptime T: type, value: f64) !T {
    if (!std.math.isFinite(value)) return error.NonFiniteParameter;
    return switch (@typeInfo(T)) {
        .float => blk: {
            const converted: T = @floatCast(value);
            if (!std.math.isFinite(converted)) return error.ParameterOutOfRange;
            break :blk converted;
        },
        .int => |info| blk: {
            // An exclusive power-of-two bound stays exact when maxInt(i64)
            // would round upward in f64.
            const upper: f64 = comptime std.math.pow(f64, 2, info.bits - @intFromBool(info.signedness == .signed));
            const lower: f64 = if (info.signedness == .signed) -upper else 0;
            const truncated = @trunc(value);
            if (truncated != value or truncated < lower or truncated >= upper) return error.ParameterOutOfRange;
            break :blk @intFromFloat(value);
        },
        .bool => value != 0,
        else => @compileError("unsupported numeric field type"),
    };
}

/// Card keys accepted for a field besides its own name, in probe order:
/// ngspice IOPR alternate spellings, then the VA name behind a VerA escape.
/// A field may carry SEVERAL keys (dio.c answers to `cjo`, `cj0` and `cj`).
///
/// The table is GLOBAL across every device, so a pair is only safe when no
/// other model declares the alias as a parameter in its own right. That is why
/// dio.c's `js`->`is` is NOT here: mos1/mos2/mos3/mos6/mos9 declare both `is`
/// (bulk junction current) and `js` (its area density), and the pair would
/// smear a MOS card's JS into IS as well.
fn aliasesOf(comptime field: []const u8) []const []const u8 {
    const pairs = [_][2][]const u8{
        .{ "vt0", "vto" }, .{ "vto", "vt0" },
        .{ "vaf", "va" },  .{ "VAR", "vb" },
        .{ "ikf", "ik" },  .{ "cjs", "ccs" },
        // BJT depletion-cap alternates (bjt.c IOPR).
        .{ "vje", "pe" },  .{ "mje", "me" },
        .{ "vjc", "pc" },  .{ "mjc", "mc" },
        .{ "vjs", "ps" },  .{ "mjs", "ms" },
        // mesa.va channel depth: ngspice's card key is `d`, which Verilog-A
        // cannot use as a parameter name (drain port).
        .{ "dch", "d" },
        // Diode alternates (dio.c IOPR). Only diode.va/vdmos.va declare `cjo`
        // and `vj`, and nothing declares `trs`/`cta`/`tpb` but diode.va, so
        // none of these can collide with another model's own parameter.
        .{ "tnom", "tref" },
        .{ "cjo", "cj0" },
        .{ "cjo", "cj" },
        .{ "vj", "pb" },
        .{ "trs", "trs1" },
        .{ "cta", "ctc" },
        .{ "tpb", "tvj" },
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
        // VerA emits a VA name that is a Zig primitive or keyword (`u0`, `type`,
        // `pub`) with a trailing `Z`; the card keeps the VA spelling.
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
    try std.testing.expectEqual(BindStatus.ok, apply(&m, &.{.{ .key = "unknown", .value = null }}));
}
