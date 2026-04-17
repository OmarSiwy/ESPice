//! SPICE device selection: netlist letter and `.model` LEVEL -> device name.
//! The device types behind the names come from the device catalog.

const std = @import("std");
const device = @import("device");
const has = device.has;
const byName = device.byName;

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
    txl_native,
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
    gummel_poon,
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
    // Y cards require the TXL Padé/history algorithm; they are not LTRA cards.
    .{ "y", DeviceId.txl_native },
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
pub const ltra_native = byName("ltra_native");
pub const txl_native = byName("txl_native");
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
    .{ .level = 1, .model = .gummel_poon },
    .{ .level = 2, .model = .gummel_poon },
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
