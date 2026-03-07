//! Native compatibility devices retained until exact AMS replacements pass.
pub const ltra_native = @import("ltra_native.zig");
pub const txl_native = @import("txl_native.zig");
pub const cpl_native_2 = @import("coupled_ltra.zig").CoupledLtra(2);
pub const cpl_native_3 = @import("coupled_ltra.zig").CoupledLtra(3);
pub const cpl_native_4 = @import("coupled_ltra.zig").CoupledLtra(4);

test {
    _ = @import("ltra_native.zig");
    _ = @import("txl_native.zig");
    _ = @import("coupled_ltra.zig");
}
