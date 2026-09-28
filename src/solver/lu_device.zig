//! GPU kernel root for the device LU (docs/solvers/gpu-lu.md): exports
//! `arp_lu_refactor` (one block per pivot step, any grid size: blocks take
//! their step by ticket, so a block that starts late never holds a step an
//! earlier one waits on) and `arp_lu_lsolve`/`arp_lu_usolve` (one block of
//! `solve_block` lanes each). The bodies are `lu_kernels.zig`'s, shared with
//! the host threads.

const builtin = @import("builtin");
const gompute = @import("gompute");
const lu = @import("lu_kernels.zig");

const Sy = struct {
    pub const P = gompute.GlobalPtr;
    pub inline fn barrier() void {
        gompute.builtins.barrier();
    }
    pub inline fn pause() void {
        gompute.builtins.spinPause();
    }
    /// Device-scope acquire and release. Zig's atomics lower to system
    /// scope on NVPTX (stronger than a kernel needs, and slower); the done
    /// stamps never leave the device.
    /// ponytail: inline PTX until gompute has scoped acquire/release.
    pub inline fn acquire(p: *addrspace(.global) const u32) u32 {
        if (comptime builtin.cpu.arch != .nvptx64) return @atomicLoad(u32, p, .acquire);
        return asm volatile ("ld.acquire.gpu.global.u32 %[r], [%[p]];"
            : [r] "=r" (-> u32),
            : [p] "l" (p),
            : .{ .memory = true });
    }
    pub inline fn release(p: *addrspace(.global) u32, v: u32) void {
        if (comptime builtin.cpu.arch != .nvptx64) return @atomicStore(u32, p, v, .release);
        asm volatile ("st.release.gpu.global.u32 [%[p]], %[v];"
            :
            : [p] "l" (p),
              [v] "r" (v),
            : .{ .memory = true });
    }
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
