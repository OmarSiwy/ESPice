// Shared context lives in types.zig so the leaves below never import this
// file — root.zig is the TOP of the analysis DAG (aggregation + dispatch),
// re-exporting analysis capabilities and the query execution seam.
const shared = @import("types.zig");
pub const device_ir = @import("device_ir");
pub const device_eval = @import("device_eval");
pub const Tolerances = @import("numerics").Tolerances;
pub const types = @import("numerics");
pub const freq = types;
pub const Circuit = shared.Circuit;
pub const EvalHook = shared.EvalHook;
pub const BbdBlock = shared.BbdBlock;
pub const BbdInfo = shared.BbdInfo;
pub const GROUND = shared.GROUND;
pub const ParamRef = shared.ParamRef;
pub const CardRef = shared.CardRef;
pub const AcParam = shared.AcParam;
pub const NoiseSource = shared.NoiseSource;
pub const NoiseGen = shared.NoiseGen;
pub const PsdTerm = shared.PsdTerm;
pub const RunCtx = shared.RunCtx;
pub const Result = shared.Result;

const dispatch = @import("executor.zig");
pub const op = dispatch.op;
pub const dc = dispatch.dc;
pub const tf = dispatch.tf;
pub const dcmatch = dispatch.dcmatch;
pub const ac = dispatch.ac;
pub const noise = dispatch.noise;
pub const sp = dispatch.sp;
pub const stb = dispatch.stb;
pub const tran = dispatch.tran;
pub const tran_noise = dispatch.tran_noise;
pub const envelope = dispatch.envelope;
pub const matex = dispatch.matex;
pub const pss = dispatch.pss;
pub const pac = dispatch.pac;
pub const pnoise = dispatch.pnoise;
pub const hb = dispatch.hb;
pub const pxf = dispatch.pxf;
pub const qpss = dispatch.qpss;
pub const four = dispatch.four;
pub const disto = dispatch.disto;
pub const sens = dispatch.sens;
pub const mc = dispatch.mc;
pub const temp_sweep = dispatch.temp_sweep;
pub const pz = dispatch.pz;
pub const AnalysisId = dispatch.AnalysisId;
pub const Analysis = dispatch.Analysis;
pub const Job = dispatch.Job;
pub const run = dispatch.run;
pub const validateOutputSchema = @import("session.zig").validateOutputSchema;
pub const session = @import("session.zig");
pub const Executor = @import("executor.zig").Executor;
pub const ExecutionConfig = @import("executor.zig").Config;
pub const validateBackend = @import("executor.zig").validateBackend;

test {
    _ = @import("tests/ac.zig");
    _ = @import("tests/circuit.zig");
    _ = @import("tests/eval.zig");
    _ = @import("tests/executor.zig");
    _ = @import("tests/four.zig");
    _ = @import("tests/gpu.zig");
    _ = @import("tests/periodic.zig");
    _ = @import("tests/pz.zig");
    _ = @import("tests/session.zig");
    _ = @import("tests/solvers.zig");
    _ = @import("tests/sweep.zig");
    _ = @import("tests/transient.zig");
    _ = @import("tests/integration.zig");
}
