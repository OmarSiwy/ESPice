//! End-to-end GPU smoke test: probe -> load embedded PTX -> alloc/upload ->
//! launch saxpy over 1M floats -> download -> verify vs CPU.
//!
//! Built and run by `zig build -Dgpu=true test-gpu` at the repo root. Must
//! exit 0 with a "skipped" message whenever the kernel wasn't built
//! (-Dgpu=false) or there is no usable device/driver — CI without a GPU stays
//! green.

const std = @import("std");
const compute = @import("compute");
const kernels = @import("kernels");
const gpu_config = @import("gpu_config");

const n: u32 = 1 << 20; // 1M floats
const block: u32 = 256;

pub fn main() !void {
    if (comptime !gpu_config.gpu) {
        std.debug.print("test-gpu skipped: no GPU (built with -Dgpu=false)\n", .{});
        return;
    }

    var c = try compute.Compute.init(null); // probe cuda -> hip -> cpu
    defer c.deinit();
    switch (c.backend) {
        .cpu => {
            std.debug.print("test-gpu skipped: no GPU (no device/driver found)\n", .{});
            return;
        },
        .hip => {
            // We only build PTX (amdgcn codegen is broken in Zig 0.16); a HIP
            // device can't consume it.
            std.debug.print("test-gpu skipped: no GPU (HIP device found but no AMDGCN kernel built)\n", .{});
            return;
        },
        .cuda => {},
    }

    // @embedFile guarantees a trailing NUL, which cuModuleLoadData requires
    // for PTX text images.
    var module = try c.loadModule(kernels.saxpy);
    defer module.deinit();
    const kernel = try module.getKernel("saxpy");

    const gpa = std.heap.smp_allocator;
    const x = try gpa.alloc(f32, n);
    defer gpa.free(x);
    const y = try gpa.alloc(f32, n);
    defer gpa.free(y);
    // Values chosen so a*x + y is exact in f32: no fma-vs-mul+add ambiguity.
    for (x, 0..) |*v, i| v.* = @floatFromInt(i % 1024);
    for (y, 0..) |*v, i| v.* = @floatFromInt((i / 1024) % 512);
    const a: f32 = 2.0;

    var x_buf = try c.alloc(n * @sizeOf(f32));
    defer x_buf.free();
    var y_buf = try c.alloc(n * @sizeOf(f32));
    defer y_buf.free();
    try x_buf.upload(x.ptr, n * @sizeOf(f32));
    try y_buf.upload(y.ptr, n * @sizeOf(f32));

    var n_arg: u32 = n;
    var a_arg: f32 = a;
    const args = [_]compute.Arg{
        @ptrCast(&n_arg),
        @ptrCast(&a_arg),
        x_buf.argPtr(),
        y_buf.argPtr(),
    };
    try kernel.launch(
        .{ .x = (n + block - 1) / block },
        .{ .x = block },
        0,
        &args,
    );
    try c.synchronize();

    const got = try gpa.alloc(f32, n);
    defer gpa.free(got);
    try y_buf.download(got.ptr, n * @sizeOf(f32));

    var mismatches: usize = 0;
    for (got, x, y) |g, xi, yi| {
        if (g != a * xi + yi) mismatches += 1;
    }
    if (mismatches != 0) {
        std.debug.print("test-gpu FAILED: {d}/{d} elements wrong\n", .{ mismatches, n });
        return error.Mismatch;
    }
    std.debug.print("test-gpu OK: saxpy on {t}, {d} elements verified\n", .{ c.backend, n });
}
