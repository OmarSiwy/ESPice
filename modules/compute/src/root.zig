pub const compute = @import("compute.zig");
pub const Compute = compute.Compute;
pub const Backend = compute.Backend;
pub const Buffer = compute.Buffer;
pub const Module = compute.Module;
pub const Kernel = compute.Kernel;
pub const Stream = compute.Stream;
pub const Graph = compute.Graph;
pub const beginCapture = compute.beginCapture;
pub const endCapture = compute.endCapture;
pub const Dim3 = compute.Dim3;
pub const Arg = compute.Arg;
pub const Error = compute.Error;

test {
    @import("std").testing.refAllDecls(@This());
}
