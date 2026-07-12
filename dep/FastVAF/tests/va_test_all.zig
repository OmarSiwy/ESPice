const std = @import("std");
const zvaf = @import("zvaf");

test "compile trivial" {
    const source = @embedFile("fixtures/trivial.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("trivial", result.mir.name);
    try std.testing.expect(result.lower.contributions.len > 0);
}

test "compile minimal" {
    const source = @embedFile("fixtures/minimal.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("minimal", result.mir.name);
    try std.testing.expect(result.lower.params.len == 1);
}

test "compile resistor" {
    const source = @embedFile("fixtures/resistor.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("resistor", result.mir.name);
    try std.testing.expect(result.lower.params.len == 1);
    try std.testing.expectEqualStrings("R", result.lower.params.slice()[0].name);
}

test "compile diode" {
    const source = @embedFile("fixtures/diode.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("diode", result.mir.name);
    try std.testing.expect(result.lower.params.len >= 3);
    try std.testing.expect(result.lower.contributions.len > 0);
}

test "compile amplifier" {
    const source = @embedFile("fixtures/amplifier.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("amplifier_va", result.mir.name);
    try std.testing.expect(result.lower.params.len >= 3);
}

test "compile noise" {
    const source = @embedFile("fixtures/noise.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("noise_test", result.mir.name);
}

test "compile strings" {
    const source = @embedFile("fixtures/strings.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("strings_va", result.mir.name);
}

test "compile diode_lim" {
    const source = @embedFile("fixtures/diode_lim.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expect(result.mir.numBlocks() > 0);
}

test "compile openvaf_resistor" {
    const source = @embedFile("fixtures/openvaf_resistor.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expect(result.mir.numBlocks() > 0);
}

test "compile openvaf_diode" {
    const source = @embedFile("fixtures/openvaf_diode.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expect(result.mir.numBlocks() > 0);
}

test "compile hicuml2" {
    const source = @embedFile("fixtures/hicuml2.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expect(result.mir.numBlocks() > 0);
    try std.testing.expect(result.lower.params.len > 10);
}

test "compile bsim4" {
    const source = @embedFile("fixtures/bsim4.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expect(result.mir.numBlocks() > 0);
}

test "graceful parse error" {
    const source = "module broken(;\nendmodule";
    const result = zvaf.compileSource(std.testing.allocator, source, null);
    try std.testing.expectError(error.ParseError, result);
}

test "no module error" {
    const source = "// empty file\n";
    const result = zvaf.compileSource(std.testing.allocator, source, null);
    try std.testing.expectError(error.NoModule, result);
}

test "codegen resistor" {
    const source = @embedFile("fixtures/resistor.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const U = enum(u8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Model = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub fn eval(comptime S: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, ".div(") != null);
    // Physics must READ the parameter at runtime (I = V/R uses model.R), not
    // inline its default — the .model card must reach the computation.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "model.R") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "@import(\"contract\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "contract.validate(Self)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "num_ports") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "AD.lift") == null);
    // No unsupported opcode stubs in output
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "@compileError") == null);
}

test "codegen diode" {
    const source = @embedFile("fixtures/diode.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub fn eval(comptime S: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, ".exp()") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "AD.lift") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "@compileError") == null);
}

test "codegen amplifier" {
    const source = @embedFile("fixtures/amplifier.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub fn eval(comptime S: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "@compileError") == null);
}

test "codegen hicuml2" {
    const source = @embedFile("fixtures/hicuml2.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    try std.testing.expect(zig_src.len > 1000);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "@compileError") == null);
}

test "codegen bsim4" {
    const source = @embedFile("fixtures/bsim4.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    try std.testing.expect(zig_src.len > 5000);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "@compileError") == null);
}

test "codegen num_ports correct" {
    const source =
        \\`include "disciplines.vams"
        \\module with_internal(p, n);
        \\    inout p, n;
        \\    electrical p, n, mid;
        \\    parameter real r1 = 1.0k;
        \\    parameter real r2 = 1.0k;
        \\    analog begin
        \\        I(p, mid) <+ V(p, mid) / r1;
        \\        I(mid, n) <+ V(mid, n) / r2;
        \\    end
        \\endmodule
    ;
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    // 2 ports, 3 total nodes (p, n, mid)
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "num_ports: usize = 2") != null);
    // Ports first in U enum
    const u_start = std.mem.indexOf(u8, zig_src, "pub const U = enum(u8)").?;
    const p_pos = std.mem.indexOf(u8, zig_src[u_start..], "p,").?;
    const n_pos = std.mem.indexOf(u8, zig_src[u_start..], "n,").?;
    const mid_pos = std.mem.indexOf(u8, zig_src[u_start..], "mid,").?;
    try std.testing.expect(p_pos < mid_pos);
    try std.testing.expect(n_pos < mid_pos);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "@compileError") == null);
}

test "codegen temperature maps to t" {
    const source =
        \\`include "disciplines.vams"
        \\module temp_test(p, n);
        \\    inout p, n;
        \\    electrical p, n;
        \\    parameter real is = 1e-14;
        \\    analog begin
        \\        real vt;
        \\        vt = $vt;
        \\        I(p, n) <+ is * (exp(V(p, n) / vt) - 1.0);
        \\    end
        \\endmodule
    ;
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    // $temperature should map to function parameter t, not 0.0
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "0.0 // TODO") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "@compileError") == null);
}

test "codegen reactive produces q" {
    const source =
        \\`include "disciplines.vams"
        \\module cap_test(p, n);
        \\    inout p, n;
        \\    electrical p, n;
        \\    parameter real c = 1e-12;
        \\    analog
        \\        I(p, n) <+ c * ddt(V(p, n));
        \\endmodule
    ;
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub fn q(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "c_pattern_override") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "@compileError") == null);
}

test "codegen while loop" {
    const source =
        \\`include "disciplines.vams"
        \\module loop_test(p, n);
        \\    inout p, n;
        \\    electrical p, n;
        \\    parameter real r = 1.0k;
        \\    parameter integer count = 5;
        \\    analog begin
        \\        real sum;
        \\        integer i;
        \\        sum = 0.0;
        \\        i = 0;
        \\        while (i < count) begin
        \\            sum = sum + V(p, n);
        \\            i = i + 1;
        \\        end
        \\        I(p, n) <+ sum / r;
        \\    end
        \\endmodule
    ;
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "while (true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "break") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "@compileError") == null);
}

test "named branch: contributions stamp node KCL rows (P7)" {
    const source =
        \\`include "disciplines.vams"
        \\module nbres(a, b);
        \\    inout a, b;
        \\    electrical a, b;
        \\    branch (a, b) br;
        \\    parameter real R = 100.0;
        \\    analog I(br) <+ V(br) / R;
        \\endmodule
    ;
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    // Plain flow branch: NO extra unknown, direct node-pair stamps.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "_ibr") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "res[0] = res[0].add(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "res[1] = res[1].sub(") != null);
}

test "named branch: I() probe creates a branch-current unknown (P7)" {
    const source =
        \\`include "disciplines.vams"
        \\module nbcccs(inp, inm, outp, outm);
        \\    inout inp, inm, outp, outm;
        \\    electrical inp, inm, outp, outm;
        \\    branch (inp, inm) brin;
        \\    branch (outp, outm) brout;
        \\    parameter real G = 10.0;
        \\    analog begin
        \\        I(brout) <+ G * I(brin);
        \\        I(brin)  <+ V(brin) / 1.0;
        \\    end
        \\endmodule
    ;
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    // Probed branch gets its own row; ports stay the only num_ports entries.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "brin_ibr") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "num_ports: usize = 4") != null);
}

test "switch branch: V() contribution on a node pair collapses it (P7)" {
    const source =
        \\`include "disciplines.vams"
        \\module colr(a, b);
        \\    inout a, b;
        \\    electrical a, b, m;
        \\    parameter real R = 0.0;
        \\    analog begin
        \\        if (R > 0.0) I(a, m) <+ V(a, m) / R;
        \\        else V(a, m) <+ 0.0;
        \\        I(m, b) <+ V(m, b) / 100.0;
        \\    end
        \\endmodule
    ;
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    // Implicit switch branch: an extra unknown for the a-m pair.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "a_m_ibr") != null);
}

test "codegen ABI v3 exports" {
    const source = @embedFile("fixtures/resistor.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    // Contract-shaped device surface (batch dyn ABI wraps it .so-side).
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const U = enum(u8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const num_ports") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Model = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub const Instance = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub fn eval(comptime S: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "contract.validate(Self)") != null);
    // Old per-instance ABI surface must be gone.
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "zpicey_") == null);
}

test "codegen reactive emits q_ad" {
    const source =
        \\`include "disciplines.vams"
        \\module cap_gpu(p, n);
        \\    inout p, n;
        \\    electrical p, n;
        \\    parameter real c = 1e-12;
        \\    analog
        \\        I(p, n) <+ c * ddt(V(p, n));
        \\endmodule
    ;
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "pub fn q(comptime S: type") != null);
}

test "codegen function inlining" {
    const source =
        \\`include "disciplines.vams"
        \\module func_test(p, n);
        \\    inout p, n;
        \\    electrical p, n;
        \\    analog function real square;
        \\        input x;
        \\        real x;
        \\        square = x * x;
        \\    endfunction
        \\    analog
        \\        I(p, n) <+ square(V(p, n));
        \\endmodule
    ;
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("func_test", result.mir.name);
    // Function should be inlined — no generic call to "square"
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "square") == null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, ".mul(") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_src, "AD.lift") == null);
}
