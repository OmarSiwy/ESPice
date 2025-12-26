//! Utility kernel: memset a contiguous f64 buffer to zero.
//! One thread per element. Used to zero g_vals, c_vals, rhs, q_vec planes
//! before device evaluation.

fn zeroPlanesImpl(
    n: u32,
    buf: [*]addrspace(.global) f64,
) callconv(.kernel) void {
    const i = @workGroupId(0) * @workGroupSize(0) + @workItemId(0);
    if (i >= n) return;
    buf[i] = 0.0;
}

comptime {
    @export(&zeroPlanesImpl, .{ .name = "zero_planes" });
}
