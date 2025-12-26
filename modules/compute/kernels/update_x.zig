//! Utility kernel: x += dx with clamping.
//! One thread per node. Each thread also computes |dx[i]| for the
//! per-thread contribution to the max_dx reduction (written to dx_abs).

fn updateXImpl(
    n: u32,
    clamp_val: f64,
    x: [*]addrspace(.global) f64,
    dx: [*]addrspace(.global) f64,
    dx_abs: [*]addrspace(.global) f64,
) callconv(.kernel) void {
    const i = @workGroupId(0) * @workGroupSize(0) + @workItemId(0);
    if (i >= n) return;
    var d = dx[i];
    if (d > clamp_val) d = clamp_val;
    if (d < -clamp_val) d = -clamp_val;
    dx[i] = d;
    x[i] += d;
    dx_abs[i] = if (d >= 0) d else -d;
}

comptime {
    @export(&updateXImpl, .{ .name = "update_x" });
}
