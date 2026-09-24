//! Linear and nonlinear solvers. Only `analysis` imports this module; build.zig
//! wires it into no other root.
pub const direct = @import("direct.zig");
pub const sparse_lu = @import("sparse_lu.zig");
pub const lane_lu = @import("lane_lu.zig");
pub const tridiag = @import("tridiag.zig");
pub const dense_lu = @import("dense_lu.zig");
pub const bbd = @import("bbd.zig");
pub const freq_solve = @import("freq_solve.zig");
pub const fft = @import("fft.zig");
pub const gmres = @import("gmres.zig");
pub const preconditioner = @import("preconditioner.zig");
pub const order = @import("order.zig");
pub const converger = @import("converger.zig");
pub const newton_core = @import("newton_core.zig");
pub const types = @import("numerics");

// Shared numerical contracts. Solver leaves import numerics directly.
pub const BbdBlock = types.BbdBlock;
pub const BbdInfo = types.BbdInfo;

test {
    _ = @import("tests.zig");
}
