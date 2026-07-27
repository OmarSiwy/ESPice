//! espice.wasm's root: libespice's C API (src/c_api.zig, contract
//! include/espice.h) plus what a JS host cannot do through it alone:
//! allocate in wasm memory, and create a Problem from netlist text without
//! laying out `espice_create_options` by hand.
//!
//! A run from JS: copy the netlist into `espice_wasm_alloc` memory, call
//! `espice_wasm_create`, then `espice_run_all`, `espice_query_count`,
//! `espice_get_result_info`, `espice_copy_result_name` and
//! `espice_result_view` from the C API, and `espice_destroy`. Out-parameters
//! go in `espice_wasm_alloc` memory too.
const std = @import("std");
const c_api = @import("c_api");
const h = @import("espice_h");

comptime {
    _ = c_api; // its `export fn`s are the API
}

/// The C API's root-level options, as the native library sets them.
pub const std_options = c_api.std_options;
pub const vera_validate_contract = c_api.vera_validate_contract;

const gpa = std.heap.wasm_allocator;

/// `espice_create`'s diagnostic for the last failed `espice_wasm_create`.
var diagnostic: [256]u8 = @splat(0);

export fn espice_wasm_alloc(len: usize) ?[*]u8 {
    return (gpa.alloc(u8, len) catch return null).ptr;
}

export fn espice_wasm_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// A Problem from ngspice-dialect netlist text, CPU backend, results kept in
/// memory. Null on failure, with the reason in `espice_wasm_diagnostic`.
export fn espice_wasm_create(text: [*]const u8, len: usize) ?*h.espice_problem {
    var options: h.espice_create_options = undefined;
    h.espice_default_options(&options);
    options.source_kind = h.ESPICE_BYTES;
    options.source = .{ .data = text, .len = len };
    const origin = "playground.cir";
    options.origin = .{ .data = origin, .len = origin.len };
    var problem: ?*h.espice_problem = null;
    _ = h.espice_create(&options, &problem, &diagnostic, diagnostic.len);
    return problem;
}

/// NUL-terminated.
export fn espice_wasm_diagnostic() [*]const u8 {
    return &diagnostic;
}
