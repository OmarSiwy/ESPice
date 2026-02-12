const std = @import("std");
const modules = @This();

const contract = @import("contract.zig");

// Shared context lives in types.zig so the leaves below never import this
// file — root.zig is the TOP of the analysis DAG (aggregation + dispatch),
// re-exporting everything for src/ consumers (engine, builder, gpu_context).
const shared = @import("types.zig");
pub const solvers = @import("solvers");
pub const devices = @import("devices");
pub const converger = solvers.converger;
pub const types = solvers.types;
pub const freq = types;
pub const Circuit = shared.Circuit;
pub const EvalHook = shared.EvalHook;
pub const GpuHook = shared.GpuHook;
pub const BbdBlock = shared.BbdBlock;
pub const BbdInfo = shared.BbdInfo;
pub const GROUND = shared.GROUND;
pub const ParamRef = shared.ParamRef;
pub const NoiseSource = shared.NoiseSource;
pub const NoiseGen = shared.NoiseGen;
pub const freeze = shared.freeze;
pub const RunCtx = shared.RunCtx;
pub const Result = shared.Result;

// -- DC / Operating Point --
pub const op = @import("dc/op.zig");
pub const dc = @import("dc/dc.zig");
pub const tf = @import("dc/tf.zig");
pub const dcmatch = @import("dc/dcmatch.zig");

// -- Frequency-domain (small-signal AC) --
pub const ac = @import("ac/ac.zig");
pub const noise = @import("ac/noise.zig");
pub const sp = @import("ac/sp.zig");
pub const stb = @import("ac/stb.zig");

// -- Time-domain --
pub const tran = @import("tran/tran.zig");
pub const tran_noise = @import("tran/tran_noise.zig");
pub const envelope = @import("tran/envelope.zig");
pub const matex = @import("tran/matex.zig");

// -- Periodic steady-state / LPTV --
pub const pss = @import("pss/pss.zig");
pub const pac = @import("pss/pac.zig");
pub const pnoise = @import("pss/pnoise.zig");
pub const hb = @import("pss/hb.zig");
pub const pxf = @import("pss/pxf.zig");
pub const qpss = @import("pss/qpss.zig");

// -- Time→Frequency post-processing --
pub const four = @import("post/four.zig");
pub const disto = @import("post/disto.zig");

// -- Parameter sweep / statistical --
pub const sens = @import("sweep/sens.zig");
pub const mc = @import("sweep/mc.zig");
pub const temp_sweep = @import("sweep/temp_sweep.zig");

// -- Eigenvalue --
pub const pz = @import("eigen/pz.zig");

// ---------------------------------------------------------------------------
// Analysis dispatch: SPICE keyword → AnalysisId → module.run()
// ---------------------------------------------------------------------------

pub const AnalysisId = enum {
    ac,
    dc,
    dcmatch,
    disto,
    envelope,
    four,
    hb,
    matex,
    mc,
    noise,
    op,
    pac,
    pnoise,
    pss,
    pxf,
    pz,
    qpss,
    sens,
    sp,
    stb,
    temp,
    tf,
    tran,
    tran_noise,

    pub fn Module(comptime self: AnalysisId) type {
        return @field(modules, if (self == .temp) "temp_sweep" else @tagName(self));
    }
};

pub const Analysis = std.StaticStringMap(AnalysisId).initComptime(.{
    .{ "ac", .ac },
    .{ "dc", .dc },
    .{ "dcmatch", .dcmatch },
    .{ "disto", .disto },
    .{ "envelope", .envelope },
    .{ "envlp", .envelope },
    .{ "four", .four },
    .{ "hb", .hb },
    .{ "matex", .matex },
    .{ "mc", .mc },
    .{ "montecarlo", .mc },
    .{ "noise", .noise },
    .{ "op", .op },
    .{ "pac", .pac },
    .{ "pnoise", .pnoise },
    .{ "pss", .pss },
    .{ "pxf", .pxf },
    .{ "pz", .pz },
    .{ "qpss", .qpss },
    .{ "sens", .sens },
    .{ "sp", .sp },
    .{ "stb", .stb },
    .{ "temp", .temp },
    .{ "tf", .tf },
    .{ "tran", .tran },
    .{ "trannoise", .tran_noise },
    .{ "tran_noise", .tran_noise },
});

// ---------------------------------------------------------------------------
// Job — tagged union, each variant is that module's Options
// ---------------------------------------------------------------------------

pub const Job = union(AnalysisId) {
    ac: ac.Options,
    dc: dc.Options,
    dcmatch: dcmatch.Options,
    disto: disto.Options,
    envelope: envelope.Options,
    four: four.Options,
    hb: hb.Options,
    matex: matex.Options,
    mc: mc.Options,
    noise: noise.Options,
    op: op.Options,
    pac: pac.Options,
    pnoise: pnoise.Options,
    pss: pss.Options,
    pxf: pxf.Options,
    pz: pz.Options,
    qpss: qpss.Options,
    sens: sens.Options,
    sp: sp.Options,
    stb: stb.Options,
    temp: temp_sweep.Options,
    tf: tf.Options,
    tran: tran.Options,
    tran_noise: tran_noise.Options,
};

// ---------------------------------------------------------------------------
// Dispatch — n lines, one switch, pure function per analysis
// ---------------------------------------------------------------------------

pub fn run(ctx: *const RunCtx, job: Job) !Result {
    switch (job) {
        inline else => |opts, tag| return tag.Module().run(ctx, opts),
    }
}

// ---------------------------------------------------------------------------
// Contract: every analysis is a pure fn run(*const RunCtx, Options) !Result
// ---------------------------------------------------------------------------

comptime {
    for (@typeInfo(AnalysisId).@"enum".fields) |f|
        contract.validate(@field(AnalysisId, f.name).Module());
}

fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

test {
    refAllDeclsRecursive(@This());
}
