//! e2e smoke kernel: y[i] = a * x[i] + y[i].
//!
//! Compiled through the nvptx64 IR -> rewrite -> llc pipeline in the root
//! build.zig (direct build-obj hits "NVPTX aliasee must be a non-kernel
//! function definition" in Zig 0.16, so we emit LLVM IR, strip the alias,
//! and run llc ourselves). Device pointers MUST be annotated
//! `addrspace(.global)` or loads/stores land in the wrong memory space.

fn saxpyImpl(
    n: u32,
    a: f32,
    x: [*]addrspace(.global) const f32,
    y: [*]addrspace(.global) f32,
) callconv(.kernel) void {
    const i = @workGroupId(0) * @workGroupSize(0) + @workItemId(0);
    if (i >= n) return;
    y[i] = a * x[i] + y[i];
}

comptime {
    @export(&saxpyImpl, .{ .name = "saxpy" });
}
