//! Utility kernel: add gmin to diagonal slots of the conductance matrix
//! and gmin*x[i] to the rhs vector.
//! One thread per node.

fn gminDiagImpl(
    n: u32,
    gmin: f64,
    diag_slots: [*]addrspace(.global) const u32,
    g_vals: [*]addrspace(.global) f64,
    rhs: [*]addrspace(.global) f64,
    x: [*]addrspace(.global) const f64,
) callconv(.kernel) void {
    const i = @workGroupId(0) * @workGroupSize(0) + @workItemId(0);
    if (i >= n) return;
    const slot = diag_slots[i];
    _ = @atomicRmw(f64, &g_vals[slot], .Add, gmin, .monotonic);
    _ = @atomicRmw(f64, &rhs[i], .Add, gmin * x[i], .monotonic);
}

comptime {
    @export(&gminDiagImpl, .{ .name = "gmin_diag" });
}
