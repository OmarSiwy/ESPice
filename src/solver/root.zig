//! Linear and nonlinear solvers. Imports only `core`; `analysis` is the
//! only module build.zig wires it into. The re-exports below are the module's API;
//! the engines behind `direct` (sparse_lu, tridiag, bbd, order) and
//! `freq_solve` (lane_lu) are reached through those two.
pub const direct = @import("direct.zig");
pub const lu_kernels = @import("lu_kernels.zig");
pub const dense_lu = @import("dense_lu.zig");
pub const freq_solve = @import("freq_solve.zig");
pub const fft = @import("fft.zig");
pub const gmres = @import("gmres.zig");
pub const converger = @import("converger.zig");
pub const lanes = @import("lanes.zig");
pub const lane_solver = @import("lane_solver.zig");
pub const lane_system = @import("lane_system.zig");
pub const lane_kernels = @import("lane_kernels.zig");

test {
    _ = @import("tests.zig");
    // In-file tests of the files the API reaches only through other files.
    _ = @import("sparse_lu.zig");
    _ = @import("lane_lu.zig");
    _ = @import("lanes.zig");
    _ = @import("lane_solver.zig");
    _ = @import("lane_system.zig");
    _ = @import("lane_kernels.zig");
    _ = @import("tridiag.zig");
    _ = @import("order.zig");
    _ = @import("bbd.zig");
}
