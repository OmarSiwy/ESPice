const std = @import("std");

pub const contract = @import("contract");

// ---------------------------------------------------------------------------
// Devices that follow the contract above
// ---------------------------------------------------------------------------

pub const asm_esd = @import("asm_esd.zig");
pub const asm_hemt = @import("asm_hemt.zig");
pub const b3soidd = @import("b3soidd.zig");
pub const b3soifd = @import("b3soifd.zig");
pub const b3soipd = @import("b3soipd.zig");
pub const bjt = @import("bjt.zig");
pub const bsim1 = @import("bsim1.zig");
pub const bsim2 = @import("bsim2.zig");
pub const bsim3 = @import("bsim3.zig");
pub const bsim4 = @import("bsim4.zig");
pub const bsim_bulk = @import("bsim_bulk.zig");
pub const bsim_cmg = @import("bsim_cmg.zig");
pub const bsim_img = @import("bsim_img.zig");
pub const bsim_soi = @import("bsim_soi.zig");
pub const bsource = @import("bsource.zig");
pub const capacitor = @import("capacitor.zig");
pub const cccs = @import("cccs.zig");
pub const ccvs = @import("ccvs.zig");
pub const coupled_tlines = @import("coupled_tlines.zig");
pub const cswitch = @import("cswitch.zig");
pub const diode = @import("diode.zig");
pub const diode_cmc = @import("diode_cmc.zig");
pub const ekv = @import("ekv.zig");
pub const hfet1 = @import("hfet1.zig");
pub const hfet2 = @import("hfet2.zig");
pub const hicum_l0 = @import("hicum_l0.zig");
pub const hicum_l2 = @import("hicum_l2.zig");
pub const hisim2 = @import("hisim2.zig");
pub const hisim_hv = @import("hisim_hv.zig");
pub const hisim_soi = @import("hisim_soi.zig");
pub const hisim_sotb = @import("hisim_sotb.zig");
pub const inductor = @import("inductor.zig");
pub const isource = @import("isource.zig");
pub const jfet = @import("jfet.zig");
pub const jfet2 = @import("jfet2.zig");
pub const juncap = @import("juncap.zig");
pub const kinduc = @import("kinduc.zig");
pub const lossy_tline = @import("lossy_tline.zig");
pub const lutsoi = @import("lutsoi.zig");
pub const mesa = @import("mesa.zig");
pub const mesfet = @import("mesfet.zig");
pub const mextram = @import("mextram.zig");
pub const mos1 = @import("mos1.zig");
pub const mos2 = @import("mos2.zig");
pub const mos3 = @import("mos3.zig");
pub const mos6 = @import("mos6.zig");
pub const mos9 = @import("mos9.zig");
pub const mosvar = @import("mosvar.zig");
pub const mvsg = @import("mvsg.zig");
pub const psp = @import("psp.zig");
pub const r3_cmc = @import("r3_cmc.zig");
pub const resistor = @import("resistor.zig");
pub const @"switch" = @import("switch.zig");
pub const tline = @import("tline.zig");
pub const urc = @import("urc.zig");
pub const vbic = @import("vbic.zig");
pub const vccs = @import("vccs.zig");
pub const vcvs = @import("vcvs.zig");
pub const vdmos = @import("vdmos.zig");
pub const vsource = @import("vsource.zig");

// ---------------------------------------------------------------------------
// SPICE letter → device dispatch
// ---------------------------------------------------------------------------

pub const letter_map = std.StaticStringMap(DeviceId).initComptime(.{
    .{ "r", .resistor },
    .{ "c", .capacitor },
    .{ "l", .inductor },
    .{ "v", .vsource },
    .{ "i", .isource },
    .{ "d", .diode },
    .{ "q", .bjt },
    .{ "m", .mos1 },
    .{ "j", .jfet },
    .{ "e", .vcvs },
    .{ "f", .cccs },
    .{ "g", .vccs },
    .{ "h", .ccvs },
    .{ "k", .kinduc },
    .{ "s", .@"switch" },
    .{ "w", .cswitch },
    .{ "t", .tline },
    .{ "o", .lossy_tline },
    // ngspice TXL (Pade RLGC line) lowers onto the same lumped RLGC device;
    // the txl model card's `length=` is aliased to `len` in netlist.zig.
    .{ "y", .lossy_tline },
    .{ "b", .bsource },
    .{ "z", .mesfet },
    .{ "u", .urc },
    .{ "p", .coupled_tlines },
});

pub fn mosfetDeviceId(level: u16) DeviceId {
    return switch (level) {
        1 => .mos1,
        2 => .mos2,
        3 => .mos3,
        4 => .bsim1,
        5 => .bsim2,
        6 => .mos6,
        8, 49 => .bsim3,
        9 => .mos9,
        // ponytail: 58 is ngspice B4SOI 4.4; b3soipd (BSIMPD 2.x) is the closest
        // cognate we have (floating-body PD SOI). Upgrade path: dedicated b4soi.
        10, 57, 58 => .b3soipd,
        11, 55 => .b3soifd,
        12, 56 => .b3soidd,
        14, 54 => .bsim4,
        44 => .ekv,
        72, 107 => .bsim_cmg,
        103 => .bsim_bulk,
        110 => .bsim_img,
        1020, 1021, 1040 => .psp,
        else => .mos1,
    };
}

pub fn bjtDeviceId(level: u16) DeviceId {
    return switch (level) {
        1 => .bjt,
        4 => .vbic,
        7 => .hicum_l0,
        8, 10 => .hicum_l2, // ngspice: level 8 = HICUM/L2
        9 => .mextram,
        else => .bjt,
    };
}

pub fn diodeDeviceId(level: u16) DeviceId {
    return switch (level) {
        1 => .diode,
        3 => .diode_cmc,
        else => .diode,
    };
}

pub fn jfetDeviceId(level: u16) DeviceId {
    return switch (level) {
        1 => .jfet,
        2 => .jfet2,
        else => .jfet,
    };
}

/// ngspice inpdomod.c: nmf/pmf/nhfet/phfet models dispatch on LEVEL only —
/// 0,1 → MES (Statz), 2-4 → MESA (Ytterdal), 5 → HFET1, 6 → HFET2.
pub fn mesDeviceId(level: u16) DeviceId {
    return switch (level) {
        0, 1 => .mesfet,
        2, 3, 4 => .mesa,
        5 => .hfet1,
        6 => .hfet2,
        else => .mesfet,
    };
}

pub const DeviceId = enum {
    asm_esd,
    asm_hemt,
    b3soidd,
    b3soifd,
    b3soipd,
    bjt,
    bsim1,
    bsim2,
    bsim3,
    bsim4,
    bsim_bulk,
    bsim_cmg,
    bsim_img,
    bsim_soi,
    bsource,
    capacitor,
    cccs,
    ccvs,
    coupled_tlines,
    cswitch,
    diode,
    diode_cmc,
    ekv,
    hfet1,
    hfet2,
    hicum_l0,
    hicum_l2,
    hisim2,
    hisim_hv,
    hisim_soi,
    hisim_sotb,
    inductor,
    isource,
    jfet,
    jfet2,
    juncap,
    kinduc,
    lossy_tline,
    lutsoi,
    mesa,
    mesfet,
    mextram,
    mos1,
    mos2,
    mos3,
    mos6,
    mos9,
    mosvar,
    mvsg,
    psp,
    r3_cmc,
    resistor,
    @"switch",
    tline,
    urc,
    vbic,
    vccs,
    vcvs,
    vdmos,
    vsource,

    pub fn Type(comptime id: DeviceId) type {
        return switch (id) {
            .asm_esd => asm_esd,
            .asm_hemt => asm_hemt,
            .b3soidd => b3soidd,
            .b3soifd => b3soifd,
            .b3soipd => b3soipd,
            .bjt => bjt,
            .bsim1 => bsim1,
            .bsim2 => bsim2,
            .bsim3 => bsim3,
            .bsim4 => bsim4,
            .bsim_bulk => bsim_bulk,
            .bsim_cmg => bsim_cmg,
            .bsim_img => bsim_img,
            .bsim_soi => bsim_soi,
            .bsource => bsource,
            .capacitor => capacitor,
            .cccs => cccs,
            .ccvs => ccvs,
            .coupled_tlines => coupled_tlines,
            .cswitch => cswitch,
            .diode => diode,
            .diode_cmc => diode_cmc,
            .ekv => ekv,
            .hfet1 => hfet1,
            .hfet2 => hfet2,
            .hicum_l0 => hicum_l0,
            .hicum_l2 => hicum_l2,
            .hisim2 => hisim2,
            .hisim_hv => hisim_hv,
            .hisim_soi => hisim_soi,
            .hisim_sotb => hisim_sotb,
            .inductor => inductor,
            .isource => isource,
            .jfet => jfet,
            .jfet2 => jfet2,
            .juncap => juncap,
            .kinduc => kinduc,
            .lossy_tline => lossy_tline,
            .lutsoi => lutsoi,
            .mesa => mesa,
            .mesfet => mesfet,
            .mextram => mextram,
            .mos1 => mos1,
            .mos2 => mos2,
            .mos3 => mos3,
            .mos6 => mos6,
            .mos9 => mos9,
            .mosvar => mosvar,
            .mvsg => mvsg,
            .psp => psp,
            .r3_cmc => r3_cmc,
            .resistor => resistor,
            .@"switch" => @"switch",
            .tline => tline,
            .urc => urc,
            .vbic => vbic,
            .vccs => vccs,
            .vcvs => vcvs,
            .vdmos => vdmos,
            .vsource => vsource,
        };
    }
};
