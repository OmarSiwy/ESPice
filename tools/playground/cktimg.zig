//! cktimg.wasm's exports: SPICE text in, an SVG schematic out, drawn with
//! cktImg's test symbol set. The JS host copies the netlist into a buffer
//! from `cktimg_alloc`, calls `cktimg_render`, then reads
//! `cktimg_output_ptr()[0..cktimg_output_len()]`: the SVG on 0, an error
//! message on 1. The output stays valid until the next render.
const std = @import("std");
const np = @import("NetlistParser");
const svg = @import("svg");
const symbols = @import("symbols").text;

const gpa = std.heap.wasm_allocator;
/// Per-render memory: the placed schematic and the output text.
var scratch: std.heap.ArenaAllocator = .init(gpa);
var output: []const u8 = "";
/// Loaded once. `place` adds a generated box class per unknown device kind,
/// so it grows by at most the number of distinct kinds ever drawn.
var library: ?np.Library = null;

export fn cktimg_alloc(len: usize) ?[*]u8 {
    return (gpa.alloc(u8, len) catch return null).ptr;
}

export fn cktimg_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

export fn cktimg_output_ptr() [*]const u8 {
    return output.ptr;
}

export fn cktimg_output_len() usize {
    return output.len;
}

export fn cktimg_render(text: [*]const u8, len: usize) u32 {
    _ = scratch.reset(.retain_capacity);
    const a = scratch.allocator();
    var diag: np.netlist.Diagnostic = .{};
    output = render(a, text[0..len], &diag) catch |err| {
        output = if (diag.line > 0)
            std.fmt.allocPrint(a, "line {d} ({s}): {s}", .{ diag.line, diag.token(), @errorName(err) }) catch "OutOfMemory"
        else
            @errorName(err);
        return 1;
    };
    return 0;
}

fn render(a: std.mem.Allocator, text: []const u8, diag: *np.netlist.Diagnostic) ![]const u8 {
    if (library == null) {
        var lib: np.Library = .init(gpa);
        // The classes borrow the parsed symbol text, so it is never freed.
        try lib.loadZon(gpa, symbols, null);
        library = lib;
    }
    var placed = try np.place(a, &np.Config.default, &library.?, &.{text}, diag);
    defer placed.deinit();
    return svg.alloc(a, &placed, &library.?, .{});
}
