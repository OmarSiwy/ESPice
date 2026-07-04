const std = @import("std");
const zvaf = @import("zvaf");
test "bsim4 codegen" {
    const source = @embedFile("fixtures/bsim4.va");
    var result = try zvaf.compileSource(std.testing.allocator, source, null);
    defer result.deinit();
    const zig_src = try zvaf.codegen.generate(std.testing.allocator, &result.mir, &result.lower);
    defer std.testing.allocator.free(zig_src);
    try std.testing.expect(zig_src.len > 5000);
}
