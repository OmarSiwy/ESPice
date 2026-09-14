//! host_device.zig — the CPU half of ONE device model, as its own object.
//!
//! build.zig compiles this file once per models/NAME.*, each time against a
//! `models` aggregate holding that one device, and links the 38 objects into
//! the executable. Exactly the same shape as kernels.zig does for the GPU.
//!
//! Why an object at all: every `DeviceBatch(D)` monomorphization used to be
//! instantiated inside the ONE `zig build-exe` that also holds solvers,
//! analysis and the app, so Zig cached the whole thing as a unit — a one-line
//! solver edit recompiled all 38 whale evals, single-threaded. Split, a model
//! that did not change is a cache hit and the ones that did compile in
//! parallel.
//!
//! The symbol is the one the runtime `.so` ABI already defines
//! (`engine.DeviceVtable`), so nothing new crosses the boundary: `Batch.eval`
//! and `Hooks` were already function pointers, and `Proto` was already
//! type-erased. Name-mangled per model (`arp_device_<name>`) because 38 of
//! these land in one link.
//!
//! `@typeName(D)` rather than the catalog stem as the vtable name: `Proto`
//! carries it and `Circuit.freeze` prints it in `--memstats`, so using the
//! stem would rename every device row in a diagnostic this split is supposed
//! to leave alone.

const engine = @import("engine.zig");
const models = @import("models");

/// A getter, not the vtable itself: `DeviceVtable` has automatic layout, which
/// `@export` refuses outright. The `.so` ABI's `arp_device` is a getter for
/// exactly the same reason, so this is the same symbol shape, renamed.
fn Export(comptime D: type) type {
    return struct {
        fn get() callconv(.c) *const engine.DeviceVtable {
            return engine.deviceVtable(D, @typeName(D));
        }
    };
}

comptime {
    for (@typeInfo(models).@"struct".decls) |d| {
        const D = @field(models, d.name);
        // A model with no `eval` is not value-form; the builder refuses it
        // (`error.UnsupportedDevice`) and there is no batch to build.
        if (@hasDecl(D, "eval"))
            @export(&Export(D).get, .{ .name = "arp_device_" ++ d.name });
    }
}
