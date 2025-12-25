//! Backend-agnostic types shared by every GPU backend.
//! This file is pure data + error definitions and depends on NO backend,
//! which is what keeps the dependency graph acyclic:
//!
//!   interface.zig  <-- backend_cuda.zig
//!                  <-- backend_hip.zig
//!                  <-- compute.zig (uniform facade, runtime probe)

/// A 3-D launch dimension (grid or block). Unused dimensions default to 1.
pub const Dim3 = struct {
    x: u32 = 1,
    y: u32 = 1,
    z: u32 = 1,
};

/// One uniform error set across backends so host code never branches on
/// vendor-specific result codes.
pub const Error = error{
    InitFailed,
    NoDevice,
    ContextFailed,
    ModuleLoadFailed,
    KernelNotFound,
    AllocFailed,
    CopyFailed,
    LaunchFailed,
    SyncFailed,
};

/// A kernel argument is a pointer to the value the driver will forward to the
/// device. The driver memcpy's the pointee, so it must stay alive across the
/// launch call. Device buffers expose `.argPtr()` to produce one of these.
pub const Arg = ?*anyopaque;
