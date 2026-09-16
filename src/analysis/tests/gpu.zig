const impl = @import("../gpu.zig");
const artifacts = @import("gompute_kernels");
const backend = impl.test_access.backend;
const std = @import("std");

test "backend selection matches the artifacts this binary carries" {
    // The one thing that is worth pinning without a GPU: a build with no images
    // must resolve `backend` to null, because every other declaration in this
    // file is guarded on that and would otherwise name a type gompute refuses
    // to instantiate.
    try std.testing.expectEqual(artifacts.has_cuda or artifacts.has_hip, backend != null);
}
