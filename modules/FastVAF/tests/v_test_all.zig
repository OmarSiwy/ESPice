const std = @import("std");
const zvf = @import("zvf");

test "generate device in devices contract shape" {
    const source = try zvf.codegen.generateDevice(std.testing.allocator, .{
        .name = "and2",
        .ports = &.{
            .{ .name = "a", .direction = .input },
            .{ .name = "b", .direction = .input },
            .{ .name = "y", .direction = .output },
        },
        .eval_stmts = "    const _y: u64 = a & b;\n",
    });
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "const contract = @import(\"contract\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const U = enum(u8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const Model = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn updateState(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn eval(comptime S: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn initState(") != null);
    // Contract-shaped device (batch dyn ABI wraps it .so-side); the old
    // per-instance zpicey_* export surface must be gone.
    try std.testing.expect(std.mem.indexOf(u8, source, "contract.validate(@This())") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "zpicey_") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "strength: f32 = 1.0") != null);
}

test "fromVerilog: AND gate end-to-end" {
    const verilog =
        \\module and2(input a, input b, output y);
        \\  assign y = a & b;
        \\endmodule
    ;
    const source = zvf.fromVerilog(std.testing.allocator, std.testing.io, verilog) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest; // verilator not on PATH
        return err;
    };
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "pub const U = enum(u8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn eval(comptime S: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "(a & b)") != null);
}

test "fromVerilog: async reset is rejected loudly" {
    const verilog =
        \\module dff_ar(input clk, input rst, input d, output reg q);
        \\  always @(posedge clk or posedge rst)
        \\    if (rst) q <= 1'b0; else q <= d;
        \\endmodule
    ;
    const result = zvf.fromVerilog(std.testing.allocator, std.testing.io, verilog);
    if (result) |source| {
        std.testing.allocator.free(source);
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest, // verilator not on PATH
        error.UnsupportedNode => {},
        else => return err,
    }
}
