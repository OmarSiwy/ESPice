//! SPICE device selection: netlist letter and `.model` LEVEL to a device
//! name, following ngspice conventions. The types behind the names come
//! from the device catalog.

const std = @import("std");
const device = @import("device");
const has = device.has;
const byName = device.byName;

/// Every model name the dispatch policy can name. The type behind a tag
/// comes from the catalog via `Type`. Names with no generated model
/// (B3SOIPD, SOI3) are tags anyway so the level tables can report
/// them by name. Written out rather than reflected from the catalog because
/// `@Enum` cannot attach the `Type` declaration.
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
    bsource_i,
    bsource_q,
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
    psp103,
    /// PSP 103 with the NQS model built in; the builder swaps it in for a
    /// psp103 card that sets SWNQS != 0.
    psp103_nqs,
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

/// Stand-in for a policy name with no generated model. It has no `eval`,
/// which is what every consumer gates on.
fn Absent(comptime name: []const u8) type {
    return struct {
        pub const absent_model = name;
    };
}

/// Netlist first letter to device. Letters with a LEVEL table (m q j z) are
/// resolved by the *DeviceId functions below; 'd' is listed only so diode
/// cards pass the known-letter gate. Other letters fall through to the
/// runtime-loaded HDL devices.
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

/// Flat aliases for the devices the builder wires by hand instead of
/// dispatching through `DeviceId`.
/// ponytail: only the names the builder uses; everything else goes through
/// `DeviceId.Type`.
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
pub const bsource_i = DeviceId.Type(.bsource_i);
pub const bsource_q = DeviceId.Type(.bsource_q);
pub const cswitch = DeviceId.Type(.cswitch);
pub const tline = DeviceId.Type(.tline);
pub const lossy_tline = DeviceId.Type(.lossy_tline);
pub const ltra_native = byName("ltra_native");
pub const vcvs_laplace = byName("vcvs_laplace");
pub const vccs_laplace = byName("vccs_laplace");
pub const vcvs_pole = byName("vcvs_pole");
pub const vccs_pole = byName("vccs_pole");
pub const vcvs_delay = byName("vcvs_delay");
pub const vccs_delay = byName("vccs_delay");
pub const txl_native = byName("txl_native");
pub const wline_1 = byName("wline_1");
pub const wline_2 = byName("wline_2");
pub const wline_3 = byName("wline_3");
pub const wline_4 = byName("wline_4");
pub const sparam_1 = byName("sparam_1");
pub const sparam_2 = byName("sparam_2");
pub const sparam_3 = byName("sparam_3");
pub const sparam_4 = byName("sparam_4");

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
    // ngspice-45 has no PSP LEVEL (PSP103 is OSDI only there); 1040 is the
    // number the VACASK-derived corpus decks use.
    .{ .level = 1040, .model = .psp103 },
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

/// LEVEL to device. An unknown level, or one whose model is not in the
/// catalog, is an unsupported netlist: it logs a warning and returns
/// `UnsupportedDevice`, never a panic and never a different device.
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

/// The M card device for `.model ... LEVEL=level` (ngspice inpdomod.c).
pub fn mosfetDeviceId(level: u16) !DeviceId {
    return levelId("MOSFET", &mos_levels, level);
}
/// The Q card device for `level`.
pub fn bjtDeviceId(level: u16) !DeviceId {
    return levelId("BJT", &bjt_levels, level);
}
/// The D card device for `level`.
pub fn diodeDeviceId(level: u16) !DeviceId {
    return levelId("diode", &diode_levels, level);
}
/// The J card device for `level`.
pub fn jfetDeviceId(level: u16) !DeviceId {
    return levelId("JFET", &jfet_levels, level);
}
/// The Z card device for `level`.
pub fn mesDeviceId(level: u16) !DeviceId {
    return levelId("MESFET", &mes_levels, level);
}
