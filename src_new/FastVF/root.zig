pub const codegen = @import("codegen.zig");
pub const verilator = @import("verilator.zig");

/// Verilog source → contract.zig-compliant Zig device code.
pub const fromVerilog = verilator.fromVerilog;
/// SystemVerilog source → sv2v → Verilog → device code.
pub const fromSystemVerilog = verilator.fromSystemVerilog;
/// VHDL source → ghdl synth → Verilog → device code.
pub const fromVhdl = verilator.fromVhdl;

test {
    _ = codegen;
    _ = verilator;
}
