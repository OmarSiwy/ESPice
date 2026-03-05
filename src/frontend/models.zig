//! Frontend model catalog and netlist device selection. Model definitions
//! supply construction metadata; bound neutral vtables create device IR.
//! Runtime evaluation is implemented in src/analysis/eval.zig.

const std = @import("std");

// ===========================================================================
// Device catalog, auto-formed from the generated models.
// ===========================================================================

/// Neutral construction/evaluation ABI. No runtime evaluator is imported here.
pub const ir = @import("device_ir");
pub const vaload = @import("model_loader.zig");
/// Every build-time-generated device, keyed by module name. `models.NAME` is
/// the contract-shaped device type.
pub const models = @import("models");

pub const Entry = struct { name: []const u8, type: type };

/// The full device set, reflected from `models` — no hand list. Adding a
/// models/NAME.va makes `catalog` grow automatically.
pub const catalog: []const Entry = blk: {
    const decls = @typeInfo(models).@"struct".decls;
    var list: [decls.len]Entry = undefined;
    for (decls, 0..) |d, i| list[i] = .{ .name = d.name, .type = @field(models, d.name) };
    const frozen = list;
    break :blk &frozen;
};

/// Linked binding name for a generated model definition.
pub fn modelName(comptime D: type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    inline for (catalog) |e| {
        if (e.type == D) return e.name;
    }
    return null;
}

/// The device's own object, reached through the runtime ABI it already
/// defines. build.zig compiles `analysis/eval.zig` once per model into
/// `arp_device_<stem>`; everything the host needs from a generated device —
/// `derive`, `collapse`, the `Proto`, and behind that `DeviceBatch(D).eval`
/// and `Hooks` — hangs off this one symbol, so the executable's own
/// compilation never instantiates a device body.
///
/// ponytail: no ABI/layout check across the boundary, unlike `loadDevice`'s
/// `arp_layout_hash` gate. These objects are built from this tree, by this
/// build graph, at the same target and optimize mode — the two sides cannot
/// disagree without the build itself being wrong. Upgrade path if that ever
/// stops being true is the same exported hash the `.so` path uses.
pub fn vtable(comptime name: []const u8) *const ir.DeviceVtable {
    const get = @extern(*const fn () callconv(.c) *const ir.DeviceVtable, .{
        .name = "arp_device_" ++ name,
    });
    return get();
}

/// Resolve a device type by model name (comptime — `catalog` carries `type`).
pub fn byName(comptime name: []const u8) type {
    if (!has(name)) @compileError("devices: no model named '" ++ name ++ "'");
    return @field(models, name);
}

/// True at comptime if a model of this name was generated.
pub fn has(comptime name: []const u8) bool {
    return @hasDecl(models, name);
}

// ===========================================================================
// SPICE dispatch policy — semantic (netlist letter / model LEVEL -> model
// name). Kept explicit because it encodes SPICE conventions, not code shape;
// resolved back to a device type through the auto catalog. Extend as models
// are authored.
// ===========================================================================

/// Every model name the dispatch policy can name. This is a NAME list, not a
/// type list: the type behind a tag always comes from the auto catalog, via
/// `Type`. Names with no generated model (BSIM3, the B3SOI family, SOI3) are
/// tags anyway so the level tables can report them by name.
///
/// Written out rather than reflected from `catalog` because `@Enum` cannot
/// attach declarations and `DeviceId.Type` has to live on the enum.
pub const DeviceId = enum {
    // Netlist letters.
    resistor,
    capacitor,
    inductor,
    kinduc,
    vsource,
    isource,
    vcvs,
    vccs,
    cccs,
    ccvs,
    bsource,
    vswitch,
    cswitch,
    tline,
    lossy_tline,
    coupled_tlines,
    diode,
    // M card levels.
    mos1,
    mos2,
    mos3,
    mos6,
    mos9,
    bsim1,
    bsim2,
    bsim3,
    bsim4va,
    bsimsoi_va,
    b3soifd,
    b3soidd,
    b3soipd,
    soi3,
    hisim2_va,
    hisimhv_va,
    vdmos,
    // Q card levels.
    bjt,
    vbic13_4t,
    hicumL2_va,
    // J / Z card levels.
    jfet,
    jfet2,
    mes,
    mesa,
    hfet1,
    hfet2,

    /// The catalog device type behind a tag. A tag whose model is not in the
    /// catalog resolves to `Absent`, so the build still compiles (consumers
    /// switch `inline else` over every tag) and the instance is rejected
    /// instead of silently running some other device.
    pub fn Type(comptime id: DeviceId) type {
        const name = @tagName(id);
        if (comptime has(name)) return byName(name);
        return Absent(name);
    }
};

/// Stand-in for a policy name with no generated model. Deliberately NOT
/// value-form (no `eval`), which is what every consumer gates on.
fn Absent(comptime name: []const u8) type {
    return struct {
        pub const absent_model = name;
    };
}

/// Netlist first-letter -> device. Letters with a LEVEL table (m q j z) are
/// resolved by the *DeviceId functions below, not here; 'd' is listed only so
/// diode cards pass the "known letter" gate. Unknown letters fall through to
/// runtime VA/Verilog loading.
pub const letter_map = std.StaticStringMap(DeviceId).initComptime(.{
    .{ "r", DeviceId.resistor },
    .{ "c", DeviceId.capacitor },
    .{ "l", DeviceId.inductor },
    .{ "k", DeviceId.kinduc },
    .{ "v", DeviceId.vsource },
    .{ "i", DeviceId.isource },
    .{ "e", DeviceId.vcvs },
    .{ "g", DeviceId.vccs },
    .{ "f", DeviceId.cccs },
    .{ "h", DeviceId.ccvs },
    .{ "b", DeviceId.bsource },
    .{ "s", DeviceId.vswitch },
    .{ "w", DeviceId.cswitch },
    .{ "t", DeviceId.tline },
    .{ "o", DeviceId.lossy_tline },
    // TXL (y card): frequency-independent RLGC line — the same physics
    // lossy_tline models; its card spells the length `length=`, which the
    // builder already translates to `len` for this device.
    .{ "y", DeviceId.lossy_tline },
    .{ "p", DeviceId.coupled_tlines },
    .{ "d", DeviceId.diode },
});

/// Flat aliases, for the devices a consumer names directly
/// (`devices.resistor`) because it wires their ports/branches by hand instead
/// of dispatching through `DeviceId`. Types still come from the catalog.
/// ponytail: only the names consumers actually use — everything else reaches
/// its type via `DeviceId.Type`.
pub const resistor = DeviceId.Type(.resistor);
pub const capacitor = DeviceId.Type(.capacitor);
pub const inductor = DeviceId.Type(.inductor);
pub const kinduc = DeviceId.Type(.kinduc);
pub const vsource = DeviceId.Type(.vsource);
pub const isource = DeviceId.Type(.isource);
pub const cccs = DeviceId.Type(.cccs);
pub const ccvs = DeviceId.Type(.ccvs);
pub const vcvs = DeviceId.Type(.vcvs);
pub const bsource = DeviceId.Type(.bsource);
pub const cswitch = DeviceId.Type(.cswitch);
pub const tline = DeviceId.Type(.tline);
pub const lossy_tline = DeviceId.Type(.lossy_tline);
pub const coupled_tlines = DeviceId.Type(.coupled_tlines);

/// `.model` LEVEL tables, per ngspice src/spicelib/parser/inpdomod.c.
const Level = struct { level: u16, model: DeviceId };

const mos_levels = [_]Level{
    .{ .level = 1, .model = .mos1 },
    .{ .level = 2, .model = .mos2 },
    .{ .level = 3, .model = .mos3 },
    .{ .level = 4, .model = .bsim1 },
    .{ .level = 5, .model = .bsim2 },
    .{ .level = 6, .model = .mos6 },
    .{ .level = 8, .model = .bsim3 },
    .{ .level = 49, .model = .bsim3 },
    .{ .level = 9, .model = .mos9 },
    .{ .level = 10, .model = .bsimsoi_va },
    .{ .level = 58, .model = .bsimsoi_va },
    .{ .level = 14, .model = .bsim4va },
    .{ .level = 54, .model = .bsim4va },
    .{ .level = 55, .model = .b3soifd },
    .{ .level = 56, .model = .b3soidd },
    .{ .level = 57, .model = .b3soipd },
    .{ .level = 60, .model = .soi3 },
    .{ .level = 68, .model = .hisim2_va },
    .{ .level = 73, .model = .hisimhv_va },
};

const bjt_levels = [_]Level{
    .{ .level = 1, .model = .bjt },
    .{ .level = 2, .model = .bjt },
    .{ .level = 4, .model = .vbic13_4t },
    .{ .level = 9, .model = .vbic13_4t },
    .{ .level = 8, .model = .hicumL2_va },
};

const diode_levels = [_]Level{
    .{ .level = 1, .model = .diode },
    .{ .level = 3, .model = .diode },
};

const jfet_levels = [_]Level{
    .{ .level = 1, .model = .jfet },
    .{ .level = 2, .model = .jfet2 },
};

const mes_levels = [_]Level{
    .{ .level = 1, .model = .mes },
    .{ .level = 2, .model = .mesa },
    .{ .level = 3, .model = .mesa },
    .{ .level = 4, .model = .mesa },
    .{ .level = 5, .model = .hfet1 },
    .{ .level = 6, .model = .hfet2 },
};

/// LEVEL -> device. An unknown level, or a level whose model is not in the
/// catalog, is an unsupported NETLIST, not a programmer bug: it errors so the
/// loader reports a clean `{"skip":...}` instead of a panic (a bsim3 card
/// took the whole benchmark runner down with it). Never a silent fall back
/// to a different device.
fn levelId(comptime kind: []const u8, comptime table: []const Level, level: u16) error{UnsupportedDevice}!DeviceId {
    inline for (table) |e| {
        if (e.level == level) {
            if (comptime !has(@tagName(e.model))) {
                std.log.warn("devices: " ++ kind ++ " LEVEL {d} needs model '" ++
                    @tagName(e.model) ++ "', which is not in the device catalog", .{level});
                return error.UnsupportedDevice;
            }
            return e.model;
        }
    }
    std.log.warn("devices: unsupported " ++ kind ++ " LEVEL {d}", .{level});
    return error.UnsupportedDevice;
}

pub fn mosfetDeviceId(level: u16) !DeviceId {
    return levelId("MOSFET", &mos_levels, level);
}
pub fn bjtDeviceId(level: u16) !DeviceId {
    return levelId("BJT", &bjt_levels, level);
}
pub fn diodeDeviceId(level: u16) !DeviceId {
    return levelId("diode", &diode_levels, level);
}
pub fn jfetDeviceId(level: u16) !DeviceId {
    return levelId("JFET", &jfet_levels, level);
}
pub fn mesDeviceId(level: u16) !DeviceId {
    return levelId("MESFET", &mes_levels, level);
}
