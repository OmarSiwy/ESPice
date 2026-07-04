pub const direct = @import("direct.zig");
pub const dense_lu = @import("dense_lu.zig");
pub const bbd = @import("bbd.zig");
pub const freq_solve = @import("freq_solve.zig");
pub const fft = @import("fft.zig");

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
    // Pull in the per-file test blocks (zig only collects tests from
    // files referenced by the test root).
    @import("std").testing.refAllDecls(@This());
}
