//! FastVAF — compile Verilog or Verilog-A to Zig device code.
//!
//! Two pipelines under one roof:
//!   * `va` — Verilog-A → MIR → Zig (pure-Zig frontend/IR/backend).
//!   * `v`  — Verilog / SystemVerilog → Zig (via verilator + sv2v).

/// Verilog-A pipeline (lexer → parser → MIR → lower → codegen).
pub const va = @import("zvaf");
/// Verilog / SystemVerilog pipeline (verilator-backed).
pub const v = @import("zvf");

// --- Verilog-A entry points ---
pub const compileSource = va.compileSource;
pub const CompileResult = va.CompileResult;
pub const Diagnostic = va.Diagnostic;
pub const CompileError = va.CompileError;

// --- Verilog entry points ---
pub const fromVerilog = v.fromVerilog;
pub const fromSystemVerilog = v.fromSystemVerilog;

// --- Source → dlopen-ready shared object (runtime device loading) ---
const compile = @import("compile.zig");
pub const Options = compile.Options;
pub const CompiledLibrary = compile.CompiledLibrary;
pub const compileVerilogA = compile.compileVerilogA;
pub const compileVerilog = compile.compileVerilog;
pub const compileGenerated = compile.compileGenerated;
pub const moduleName = compile.moduleName;

test {
    _ = va;
    _ = v;
    _ = compile;
}
