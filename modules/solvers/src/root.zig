// Solver module exports — all sub-modules exposed for analysis consumers.
pub const direct = @import("direct.zig");
pub const sparse_lu = @import("sparse_lu.zig");
pub const tridiag = @import("tridiag.zig");
pub const dense_lu = @import("dense_lu.zig");
pub const bbd = @import("bbd.zig");
pub const freq_solve = @import("freq_solve.zig");
pub const fft = @import("fft.zig");
pub const gmres = @import("gmres.zig");
pub const preconditioner = @import("preconditioner.zig");
pub const order = @import("order.zig");
pub const converger = @import("converger.zig");
pub const types = @import("types.zig");

// Types re-exported for analysis consumers (BbdBlock/BbdInfo used by analysis/root.zig).
pub const BbdBlock = struct {
    start: u32,
    size: u32,
    type_id: u16,
    instance_id: u32,
};

pub const BbdInfo = struct {
    blocks: []BbdBlock,
    coupling_start: u32,
    coupling_size: u32,
};

test {
    @import("std").testing.refAllDecls(@This());
}
