pub const codegen = @import("codegen.zig");
pub const verilator = @import("verilator.zig");

/// Verilog source → contract.zig-compliant Zig device code.
pub const fromVerilog = verilator.fromVerilog;
/// SystemVerilog source → sv2v → Verilog → device code.
pub const fromSystemVerilog = verilator.fromSystemVerilog;

test {
    _ = codegen;
    _ = verilator;
}
