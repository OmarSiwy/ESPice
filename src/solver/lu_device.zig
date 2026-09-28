//! GPU kernel root for the device LU (docs/solvers/gpu-lu.md): exports
//! `arp_lu_refactor` (one block per pivot step, any grid size: blocks take
//! their step by ticket, so a block that starts late never holds a step an
//! earlier one waits on) and `arp_lu_lsolve`/`arp_lu_usolve` (one block of
//! `solve_block` lanes each). The bodies are `lu_kernels.zig`'s, shared with
//! the host threads.

const gompute = @import("gompute");
const lu = @import("lu_kernels.zig");

const Sy = struct {
    pub const P = gompute.GlobalPtr;
    pub inline fn barrier() void {
        gompute.builtins.barrier();
    }
    pub inline fn pause(_: u32) void {
        gompute.builtins.spinPause();
    }
    /// Device scope: the done stamps never leave the device, and Zig's own
    /// atomics lower to system scope on NVPTX (7.1 vs 3.7 ms on a refactor).
    pub const acquire = gompute.builtins.loadAcquireDevice;
    pub const release = gompute.builtins.storeReleaseDevice;
};
const P = gompute.GlobalPtr;

const K = lu.Kernels(Sy, lu.col_max, lu.refactor_block);
var sh: K.Shared addrspace(.shared) = undefined;

fn refactor(t: lu.Tab, x: P(u32), val: P(f64), a: P(f64), sy: P(u32), stamp: u32) callconv(gompute.kernel_callconv) void {
    _ = K.refactor(t, x, val, a, sy, stamp, &sh, gompute.builtins.localIdX(), lu.refactor_block);
}

const Solve = lu.Kernels(Sy, 0, 1);
var ssh: Solve.SolveShared addrspace(.shared) = undefined;

fn lsolve(t: lu.Tab, x: P(u32), val: P(f64), rhs: P(f64), y: P(f64), sy: P(u32)) callconv(gompute.kernel_callconv) void {
    Solve.lsolve(t, x, val, rhs, y, sy, &ssh, gompute.builtins.localIdX(), lu.solve_block);
}

fn usolve(t: lu.Tab, x: P(u32), val: P(f64), y: P(f64), dx: P(f64), sy: P(u32)) callconv(gompute.kernel_callconv) void {
    Solve.usolve(t, x, val, y, dx, sy, &ssh, gompute.builtins.localIdX(), lu.solve_block);
}

comptime {
    if (gompute.is_device) {
        gompute.exportRaw("arp_lu_refactor", &refactor);
        gompute.exportRaw("arp_lu_lsolve", &lsolve);
        gompute.exportRaw("arp_lu_usolve", &usolve);
    }
}
