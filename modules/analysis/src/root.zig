const std = @import("std");

const contract = @import("contract.zig");
const circuit_mod = @import("Circuit.zig");
pub const gpu_abi = @import("gpu_abi");

// -- Crate imports --
pub const solvers = @import("solvers");
pub const devices = @import("devices");
pub const converger = solvers.converger;
pub const types = solvers.types;
pub const freq = types;

// ---------------------------------------------------------------------------
// Re-exports from Circuit.zig — backward compat for analysis modules
// ---------------------------------------------------------------------------

pub const Circuit = circuit_mod.Circuit;
pub const EvalHook = circuit_mod.EvalHook;
pub const GpuHook = circuit_mod.GpuHook;
pub const BbdBlock = circuit_mod.BbdBlock;
pub const BbdInfo = circuit_mod.BbdInfo;
pub const GROUND = circuit_mod.GROUND;
pub const zeroSimd = circuit_mod.zeroSimd;
pub fn probeNames(ctx: *const RunCtx, first: ?[]const u8) ![]const []const u8 {
    return circuit_mod.probeNames(ctx.circuit, ctx.probes, ctx.allocator, first);
}

// ---------------------------------------------------------------------------
// Re-exports from devices — backward compat for analysis modules + src/
// ---------------------------------------------------------------------------

pub const Batch = devices.batch.Batch;
pub const Hooks = devices.batch.Hooks;
pub const Planes = devices.batch.Planes;
pub const ParamRef = devices.batch.ParamRef;
pub const NoiseSource = devices.batch.NoiseSource;
pub const NoiseGenKind = devices.batch.NoiseGenKind;
pub const NoiseGen = devices.batch.NoiseGen;
pub const StateCtlOp = devices.batch.StateCtlOp;
pub const UpdateResult = devices.batch.UpdateResult;

// ---------------------------------------------------------------------------
// Backward-compat: analysis.problem.* namespace for src/ consumers
// ---------------------------------------------------------------------------

pub const problem = struct {
    pub const Proto = devices.batch.Proto;
    pub const ProtoStore = devices.batch.ProtoStore;
    pub const PatternView = devices.batch.PatternView;
    pub const dyn = devices.dyn;
    pub const ParEval = devices.par.ParEval;
    pub const EvalTask = devices.par.EvalTask;
    pub const default_min_instances = devices.par.default_min_instances;
    pub const GpuProblem = circuit_mod.GpuProblem;
    pub const TranPack = circuit_mod.TranPack;
    pub const packGpuProblem = circuit_mod.packForGpu;
    pub const gpuEligible = circuit_mod.gpuEligible;
    pub const freeze = circuit_mod.init;
};

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
        return switch (self) {
            .ac => ac,
            .dc => dc,
            .dcmatch => dcmatch,
            .disto => disto,
            .envelope => envelope,
            .four => four,
            .hb => hb,
            .matex => matex,
            .mc => mc,
            .noise => noise,
            .op => op,
            .pac => pac,
            .pnoise => pnoise,
            .pss => pss,
            .pxf => pxf,
            .pz => pz,
            .qpss => qpss,
            .sens => sens,
            .sp => sp,
            .stb => stb,
            .temp => temp_sweep,
            .tf => tf,
            .tran => tran,
            .tran_noise => tran_noise,
        };
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
// Run context — everything an analysis needs, resolved before dispatch
// ---------------------------------------------------------------------------

pub const RunCtx = struct {
    circuit: *Circuit,
    x_op: ?[]f64,
    probes: []const u32,
    source_node: u32,
    source_branch: u32,
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// Uniform result — every analysis produces this
// ---------------------------------------------------------------------------

pub const Result = struct {
    plotname: []const u8,
    varnames: []const []const u8,
    is_complex: bool,
    npoints: usize,
    data: []const f64,
};

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
