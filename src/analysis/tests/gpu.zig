//! GPU backend selection test; runs without a GPU.

const impl = @import("../gpu.zig");
const artifacts = @import("gompute_kernels");
const backend = impl.test_access.backend;
const std = @import("std");

test "backend selection matches the artifacts this binary carries" {
    // A build with no images must resolve `backend` to null: every other
    // declaration in gpu.zig is guarded on it.
    try std.testing.expectEqual(artifacts.has_cuda or artifacts.has_hip, backend != null);
}
