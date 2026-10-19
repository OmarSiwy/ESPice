//! The device module: the build-time model catalog, runtime HDL loading, the
//! per-Problem `Library` of device types, and the frozen `Circuit`. `abi` is
//! the neutral device ABI; eval.zig implements it for every device type.
//! Cites nothing: it only re-exports.
/// The neutral device ABI (abi.zig), shared with every device object.
pub const abi = @import("device_abi");
/// The frozen circuit `Circuit.freeze` builds from the protos.
pub const Circuit = @import("Circuit.zig");
/// Runtime HDL compilation and dlopen; `Library.load` is its entry.
pub const loader = @import("loader.zig");
/// The per-Problem table of device types under dense ids.
pub const Library = @import("Library.zig");
/// A dense device-type id into a `Library`.
pub const DeviceType = abi.DeviceType;
const cat = @import("catalog.zig");
/// Every decl of `models`, in declaration order.
pub const catalog = cat.catalog;
/// The binding name of a device type, or null when it is not in the catalog.
pub const modelName = cat.modelName;
/// The vtable of a built-in model, from its linked object.
pub const vtable = cat.vtable;
/// The device type registered under a name; a compile error when there is none.
pub const byName = cat.byName;
/// Whether a model is registered under a name.
pub const has = cat.has;

test {
    _ = cat;
    _ = @import("tests/catalog.zig");
    _ = @import("tests/jacobian_fd.zig");
    _ = Circuit;
    _ = Library;
    _ = loader;
}
