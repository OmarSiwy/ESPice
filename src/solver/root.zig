//! Linear and nonlinear solvers. Imports only `core` (and stdpp, the std
//! extension every host module gets); `analysis` is the only module
//! build.zig wires it into. The re-exports below are the module's API;
//! the engines behind `direct` (sparse_lu, tridiag, bbd, order) and
//! `freq_solve` (lane_lu) are reached through those two.
pub const direct = @import("direct.zig");
pub const lu_kernels = @import("lu_kernels.zig");
pub const dense_lu = @import("dense_lu.zig");
pub const freq_solve = @import("freq_solve.zig");
pub const fft = @import("fft.zig");
pub const gmres = @import("gmres.zig");
pub const converger = @import("converger.zig");

test {
    _ = @import("tests.zig");
    // In-file tests of the files the API reaches only through other files.
    _ = @import("sparse_lu.zig");
    _ = @import("lane_lu.zig");
    _ = @import("tridiag.zig");
    _ = @import("order.zig");
    _ = @import("bbd.zig");
}
