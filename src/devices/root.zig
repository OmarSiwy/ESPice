//! devices — Verilog-A models compiled to Zig at build time, plus the SPICE
//! dispatch policy over them.
//!
//! The generated devices arrive as the `models` aggregate (build.zig runs
//! tools/compile_va.zig once per models/NAME.va); the device `catalog` and
//! dispatch tables are FORMED FROM IT by reflection — there is no
//! hand-maintained per-device import/enum/switch list.

const std = @import("std");

// ===========================================================================
// Device catalog, auto-formed from the generated models.
// ===========================================================================

/// The device engine (batching, sink-eval, threading, runtime .so ABI + loader)
/// — one file. The `batch`/`par`/`dyn`/`vaload` names below are back-compat
/// namespaces onto it, so existing consumers (`devices.batch.Batch`,
/// `devices.par.ParEval`, `devices.dyn.DeviceVtable`, `devices.vaload.get`)
/// resolve unchanged.
pub const engine = @import("engine.zig");
pub const batch = engine;
pub const par = engine;
pub const dyn = engine;
/// Runtime HDL loader — app-only (FastVAF-dependent), kept out of the shared
/// engine core so the `.so` can compile engine.zig without FastVAF.
pub const vaload = @import("loader.zig");

/// gompute GPU kernel registration for builtin devices (comptime catalog loop).
/// The top-level build feeds this to gompute's `emitKernels`.
pub const kernels = @import("kernels.zig");

/// ngspice's LTRA recursive-convolution lossy line — hand-written against the
/// contract (unbounded per-instance history has no Verilog-A spelling, see
/// models/lossy_tline.va). NOT in `catalog` (that reflects generated models);
/// the builder routes RLC/RC O-cards here directly.
pub const ltra_native = @import("ltra_native.zig");

/// ngspice's TXL Padé device (Y card) — a deliberately different
/// approximation family from LTRA: the golden decks were made with it, and
/// exact physics measurably diverges from it (module header has numbers).
pub const txl_native = @import("txl_native.zig");

/// N-line coupled lossy lines (P card) — faithful port of ngspice's CPL
/// (cplsetup coupled() frequency-sampled fits + cplload convolutions);
/// replaces the 2-line even/odd VA cognate for N in supported_n.
pub const coupled_ltra = @import("coupled_ltra.zig");

comptime {
    _ = ltra_native; // pull tests into the devices test root
    _ = txl_native;
    _ = coupled_ltra;
}

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

// CONSUMING §4.2 / checklist item 5, over every builtin. `catalog` is the only
// place that names all of them unconditionally — `DeviceBatch(D)` is
// instantiated lazily, per device type a netlist actually uses, so a check
// there would pass a build that a netlist then fails.
comptime {
    for (catalog) |e| engine.checkHost(e.type);
}

/// Resolve a device type by model name (comptime — `catalog` carries `type`).
pub fn byName(comptime name: []const u8) type {
    // Consumers resolve every DeviceId tag in one comptime frame (an
    // `inline else` switch), so the quota has to cover catalog.len squared-ish.
    @setEvalBranchQuota(100_000);
    inline for (catalog) |e| {
        if (comptime std.mem.eql(u8, e.name, name)) return e.type;
    }
    @compileError("devices: no model named '" ++ name ++ "'");
}

/// True at comptime if a model of this name was generated.
pub fn has(comptime name: []const u8) bool {
    // Consumers resolve every DeviceId tag in one comptime frame (an
    // `inline else` switch), so the quota has to cover catalog.len squared-ish.
    @setEvalBranchQuota(100_000);
    inline for (catalog) |e| {
        if (comptime std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
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

test "catalog reflects the generated model set" {
    // Compiles only inside the devices module (models import present).
    try std.testing.expect(has("resistor"));
    try std.testing.expect(!has("does_not_exist"));
}

test "dispatch policy resolves letters and levels" {
    try std.testing.expectEqual(DeviceId.lossy_tline, letter_map.get("o").?);
    try std.testing.expectEqual(DeviceId.lossy_tline, letter_map.get("y").?);
    try std.testing.expectEqual(DeviceId.mos1, try mosfetDeviceId(1));
    try std.testing.expectEqual(DeviceId.bsim4va, try mosfetDeviceId(54));
    try std.testing.expectEqual(DeviceId.bsim3, try mosfetDeviceId(49));
    try std.testing.expectEqual(DeviceId.bsim3, try mosfetDeviceId(8));
    try std.testing.expectEqual(DeviceId.hicumL2_va, try bjtDeviceId(8));
    try std.testing.expectEqual(DeviceId.jfet2, try jfetDeviceId(2));
    try std.testing.expectEqual(DeviceId.mesa, try mesDeviceId(3));
    // Missing-from-catalog (b3soifd, level 55) and unknown levels are
    // unsupported netlists, not panics: the loader turns this into a clean skip.
    try std.testing.expectError(error.UnsupportedDevice, mosfetDeviceId(55));
    try std.testing.expectError(error.UnsupportedDevice, mosfetDeviceId(1040));
    // Every tag must resolve to a type — consumers switch `inline else` over
    // the whole enum, so a tag that fails to resolve breaks their build.
    inline for (@typeInfo(DeviceId).@"enum".fields) |f| _ = DeviceId.Type(@field(DeviceId, f.name));
}
