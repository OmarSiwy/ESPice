//! Per-model megakernel stub TU. Instantiated once per builtin device model
//! (stub_options.model_name = decl name in devices/root.zig) plus once with
//! model_name = "" covering ALL baked VA models. Exports the concrete
//! evalBatch/limitBatch wrappers the driver TU (kernel.zig) resolves by name
//! at nvlink time — ptxas compiles each model's physics in isolation instead
//! of one 37 MB megablob.

const common = @import("kernel_common.zig");
const devices = @import("dev_models");
const va_devices = @import("va_devices");
const abi = @import("gpu_abi");

const model_name = @import("stub_options").model_name;

comptime {
    @setEvalBranchQuota(100_000);
    if (model_name.len == 0) {
        // VA stub: every baked Verilog-A/Verilog model in one TU (few, and
        // their decl names aren't known to build.zig at configure time).
        for (@typeInfo(va_devices).@"struct".decls) |decl| exportModel(va_devices, decl.name);
    } else {
        exportModel(devices, model_name);
    }
}

fn exportModel(comptime M: type, comptime name: []const u8) void {
    if (@TypeOf(@field(M, name)) != type) return;
    const D = @field(M, name);
    if (!common.isDevice(D)) return;

    const W = struct {
        fn ebDiag(
            g: *const common.G,
            desc: *addrspace(.global) const abi.BatchDesc,
            blob: [*]addrspace(.global) u8,
            x: [*]addrspace(.global) const f64,
            t: f64,
            env: *const common.TranEnv,
            limiting: bool,
            x_base: [*]addrspace(.global) const f64,
        ) callconv(.c) void {
            common.evalBatch(D, true, g, desc, blob, x, t, env.*, limiting, x_base);
        }
        fn ebRes(
            g: *const common.G,
            desc: *addrspace(.global) const abi.BatchDesc,
            blob: [*]addrspace(.global) u8,
            x: [*]addrspace(.global) const f64,
            t: f64,
            env: *const common.TranEnv,
            limiting: bool,
            x_base: [*]addrspace(.global) const f64,
        ) callconv(.c) void {
            common.evalBatch(D, false, g, desc, blob, x, t, env.*, limiting, x_base);
        }
        fn lb(
            g: *const common.G,
            desc: *addrspace(.global) const abi.BatchDesc,
            blob: [*]addrspace(.global) u8,
            x: [*]addrspace(.global) const f64,
            x_old: [*]addrspace(.global) const f64,
            lim_active: bool,
        ) callconv(.c) f64 {
            return common.limitBatch(D, g, desc, blob, x, x_old, lim_active);
        }
    };
    @export(&W.ebDiag, .{ .name = "arp_eb_" ++ name ++ "_d" });
    @export(&W.ebRes, .{ .name = "arp_eb_" ++ name ++ "_r" });
    if (@hasDecl(D, "limit")) @export(&W.lb, .{ .name = "arp_lb_" ++ name });
}
