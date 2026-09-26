//! Linear and nonlinear solvers. Imports only `core`; `analysis` is the only
//! module build.zig wires it into.
pub const direct = @import("direct.zig");
pub const sparse_lu = @import("sparse_lu.zig");
pub const lane_lu = @import("lane_lu.zig");
pub const tridiag = @import("tridiag.zig");
pub const dense_lu = @import("dense_lu.zig");
pub const bbd = @import("bbd.zig");
pub const freq_solve = @import("freq_solve.zig");
pub const fft = @import("fft.zig");
pub const gmres = @import("gmres.zig");
pub const order = @import("order.zig");
pub const converger = @import("converger.zig");

test {
    _ = @import("tests.zig");
}
