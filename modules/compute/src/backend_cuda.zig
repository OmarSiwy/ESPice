//! CUDA backend via runtime loading (dlopen), not link-time linking.
//!
//! Instead of `extern "cuda" fn ...` (which forces libcuda to be present at
//! link time), we open the driver library at runtime with std.DynLib and look
//! up each symbol into a function-pointer table. This is what mainstream
//! wrappers do by default (e.g. cudarc's `dynamic-loading`): the binary builds
//! and ships without CUDA, and missing driver/GPU becomes a clean error rather
//! than a failure to start.
//!
//! The public types (Context/Buffer/Module/Kernel) are unchanged, so the
//! universal facade and host code are untouched. dlopen only changes *how the
//! symbols are bound*.
//!
//! CUDA driver-API symbols are versioned: the field names below use the `_v2`
//! suffixes, and the loader looks symbols up by field name, so the names must
//! match the real exports exactly.

const std = @import("std");
const builtin = @import("builtin");
const iface = @import("interface.zig");
const Dim3 = iface.Dim3;
const Error = iface.Error;

// ---------------------------------------------------------------------------
// Handle + scalar types
// ---------------------------------------------------------------------------
const CUresult = c_int;
const CUdevice = c_int;
const CUcontext = ?*anyopaque;
const CUmodule = ?*anyopaque;
const CUfunction = ?*anyopaque;
const CUstream = ?*anyopaque;
const CUgraph = ?*anyopaque;
const CUgraphExec = ?*anyopaque;
const CUdeviceptr = c_ulonglong;

// ---------------------------------------------------------------------------
// Function-pointer table. Field name == exported symbol name.
// ---------------------------------------------------------------------------
const Api = struct {
    lib: std.DynLib,
    cuInit: *const fn (c_uint) callconv(.c) CUresult,
    cuDeviceGet: *const fn (*CUdevice, c_int) callconv(.c) CUresult,
    cuCtxCreate_v2: *const fn (*CUcontext, c_uint, CUdevice) callconv(.c) CUresult,
    cuCtxDestroy_v2: *const fn (CUcontext) callconv(.c) CUresult,
    cuCtxSynchronize: *const fn () callconv(.c) CUresult,
    cuModuleLoadData: *const fn (*CUmodule, *const anyopaque) callconv(.c) CUresult,
    cuModuleUnload: *const fn (CUmodule) callconv(.c) CUresult,
    cuModuleGetFunction: *const fn (*CUfunction, CUmodule, [*:0]const u8) callconv(.c) CUresult,
    cuMemAlloc_v2: *const fn (*CUdeviceptr, usize) callconv(.c) CUresult,
    cuMemFree_v2: *const fn (CUdeviceptr) callconv(.c) CUresult,
    cuMemcpyHtoD_v2: *const fn (CUdeviceptr, *const anyopaque, usize) callconv(.c) CUresult,
    cuMemcpyDtoH_v2: *const fn (*anyopaque, CUdeviceptr, usize) callconv(.c) CUresult,
    cuLaunchKernel: *const fn (
        CUfunction,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        CUstream,
        ?[*]iface.Arg,
        ?[*]iface.Arg,
    ) callconv(.c) CUresult,
    cuMemcpyDtoD_v2: *const fn (CUdeviceptr, CUdeviceptr, usize) callconv(.c) CUresult,
    cuMemcpyHtoDAsync_v2: *const fn (CUdeviceptr, *const anyopaque, usize, CUstream) callconv(.c) CUresult,
    cuMemcpyDtoHAsync_v2: *const fn (*anyopaque, CUdeviceptr, usize, CUstream) callconv(.c) CUresult,
    // Cooperative launch: all blocks co-resident (required for the software
    // grid barrier in the analysis megakernel). No `extra` param on this one.
    cuLaunchCooperativeKernel: *const fn (CUfunction, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, CUstream, ?[*]iface.Arg) callconv(.c) CUresult,
    cuOccupancyMaxActiveBlocksPerMultiprocessor: *const fn (*c_int, CUfunction, c_int, usize) callconv(.c) CUresult,
    cuDeviceGetAttribute: *const fn (*c_int, c_int, CUdevice) callconv(.c) CUresult,
    cuStreamCreate: *const fn (*CUstream, c_uint) callconv(.c) CUresult,
    cuStreamDestroy_v2: *const fn (CUstream) callconv(.c) CUresult,
    cuStreamSynchronize: *const fn (CUstream) callconv(.c) CUresult,
    cuStreamBeginCapture_v2: *const fn (CUstream, c_uint) callconv(.c) CUresult,
    cuStreamEndCapture: *const fn (CUstream, *CUgraph) callconv(.c) CUresult,
    cuGraphInstantiate_v2: *const fn (*CUgraphExec, CUgraph, ?*anyopaque, ?*anyopaque, usize) callconv(.c) CUresult,
    cuGraphLaunch: *const fn (CUgraphExec, CUstream) callconv(.c) CUresult,
    cuGraphExecDestroy: *const fn (CUgraphExec) callconv(.c) CUresult,
    cuGraphDestroy: *const fn (CUgraph) callconv(.c) CUresult,
};

var g: Api = undefined;
var loaded = false;

const lib_names = switch (builtin.os.tag) {
    .windows => &[_][]const u8{"nvcuda.dll"},
    // The absolute path is the NixOS driver location, which is NOT on the
    // default dlopen search path inside `nix develop` shells.
    else => &[_][]const u8{
        "libcuda.so",
        "libcuda.so.1",
        "/run/opengl-driver/lib/libcuda.so.1",
        "/run/opengl-driver/lib/libcuda.so",
    },
};

fn openFirst(names: []const []const u8) ?std.DynLib {
    for (names) |n| {
        if (std.DynLib.open(n)) |l| return l else |_| {}
    }
    return null;
}

/// Load libcuda and resolve every symbol exactly once. Field names double as
/// symbol names via comptime reflection, so adding an entry to `Api` is all
/// that's needed to bind a new call.
fn loadApi() Error!void {
    if (loaded) return;
    var lib = openFirst(lib_names) orelse return error.InitFailed;
    errdefer lib.close();
    inline for (@typeInfo(Api).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "lib")) continue;
        @field(g, field.name) = lib.lookup(@TypeOf(@field(g, field.name)), field.name) orelse return error.InitFailed;
    }
    g.lib = lib;
    loaded = true;
}

inline fn check(rc: CUresult, err: Error) Error!void {
    if (rc != 0) return err;
}

// ---------------------------------------------------------------------------
// Public, backend-uniform API (identical surface to the linked version)
// ---------------------------------------------------------------------------
pub const Context = struct {
    device: CUdevice = 0,
    ctx: CUcontext = null,

    pub fn init(ordinal: c_int) Error!Context {
        try loadApi(); // dlopen + symbol resolution (idempotent)
        try check(g.cuInit(0), error.InitFailed);
        var self: Context = .{};
        try check(g.cuDeviceGet(&self.device, ordinal), error.NoDevice);
        try check(g.cuCtxCreate_v2(&self.ctx, 0, self.device), error.ContextFailed);
        return self;
    }

    pub fn deinit(self: *Context) void {
        _ = g.cuCtxDestroy_v2(self.ctx);
        self.* = .{};
    }

    pub fn synchronize(_: *Context) Error!void {
        try check(g.cuCtxSynchronize(), error.SyncFailed);
    }

    pub fn createStream(_: *Context) Error!Stream {
        var s: Stream = .{};
        try check(g.cuStreamCreate(&s.stream, 0), error.SyncFailed);
        return s;
    }

    pub fn alloc(_: *Context, bytes: usize) Error!Buffer {
        var b: Buffer = .{ .bytes = bytes };
        try check(g.cuMemAlloc_v2(&b.handle, bytes), error.AllocFailed);
        return b;
    }

    pub fn loadModuleFromMemory(_: *Context, image: []const u8) Error!Module {
        var m: Module = .{};
        try check(g.cuModuleLoadData(&m.module, image.ptr), error.ModuleLoadFailed);
        return m;
    }

    /// CUdevice_attribute values (cuda.h).
    pub const attr_multiprocessor_count: c_int = 16;
    pub const attr_cooperative_launch: c_int = 95;

    pub fn deviceAttribute(self: *Context, attrib: c_int) Error!c_int {
        var v: c_int = 0;
        try check(g.cuDeviceGetAttribute(&v, attrib, self.device), error.NoDevice);
        return v;
    }

    /// Max co-resident grid for a cooperative launch of `k` at `block_dim`:
    /// occupancy-per-SM × SM count. 0 ⇒ cooperative launch unsupported.
    pub fn maxCoopBlocks(self: *Context, k: Kernel, block_dim: u32, shared_bytes: usize) Error!u32 {
        const coop = self.deviceAttribute(attr_cooperative_launch) catch 0;
        if (coop == 0) return 0;
        var per_sm: c_int = 0;
        try check(g.cuOccupancyMaxActiveBlocksPerMultiprocessor(&per_sm, k.func, @intCast(block_dim), shared_bytes), error.LaunchFailed);
        const sms = try self.deviceAttribute(attr_multiprocessor_count);
        return @intCast(per_sm * sms);
    }
};

pub const Buffer = struct {
    handle: CUdeviceptr = 0,
    bytes: usize = 0,

    pub fn upload(self: *Buffer, host: *const anyopaque, n: usize) Error!void {
        try check(g.cuMemcpyHtoD_v2(self.handle, host, n), error.CopyFailed);
    }

    pub fn download(self: *Buffer, host: *anyopaque, n: usize) Error!void {
        try check(g.cuMemcpyDtoH_v2(host, self.handle, n), error.CopyFailed);
    }

    pub fn downloadAt(self: *Buffer, host: *anyopaque, offset: usize, n: usize) Error!void {
        try check(g.cuMemcpyDtoH_v2(host, self.handle + offset, n), error.CopyFailed);
    }

    pub fn uploadAt(self: *Buffer, host: *const anyopaque, offset: usize, n: usize) Error!void {
        try check(g.cuMemcpyHtoD_v2(self.handle + offset, host, n), error.CopyFailed);
    }

    pub fn free(self: *Buffer) void {
        _ = g.cuMemFree_v2(self.handle);
        self.* = .{};
    }

    pub fn argPtr(self: *Buffer) iface.Arg {
        return @ptrCast(&self.handle);
    }

    pub fn copyFrom(self: *Buffer, src: *const Buffer, src_offset: usize, dst_offset: usize, n: usize) Error!void {
        try check(g.cuMemcpyDtoD_v2(self.handle + dst_offset, src.handle + src_offset, n), error.CopyFailed);
    }

    pub fn downloadAtAsync(self: *Buffer, host: *anyopaque, offset: usize, n: usize, stream: CUstream) Error!void {
        try check(g.cuMemcpyDtoHAsync_v2(host, self.handle + offset, n, stream), error.CopyFailed);
    }

    pub fn uploadAtAsync(self: *Buffer, host: *const anyopaque, offset: usize, n: usize, stream: CUstream) Error!void {
        try check(g.cuMemcpyHtoDAsync_v2(self.handle + offset, host, n, stream), error.CopyFailed);
    }
};

pub const Module = struct {
    module: CUmodule = null,

    pub fn getKernel(self: *Module, name: [*:0]const u8) Error!Kernel {
        var k: Kernel = .{};
        try check(g.cuModuleGetFunction(&k.func, self.module, name), error.KernelNotFound);
        return k;
    }

    pub fn deinit(self: *Module) void {
        _ = g.cuModuleUnload(self.module);
        self.* = .{};
    }
};

pub const Kernel = struct {
    func: CUfunction = null,

    pub fn launch(self: Kernel, grid: Dim3, block: Dim3, shared_bytes: u32, args: []const iface.Arg) Error!void {
        try self.launchOnStream(grid, block, shared_bytes, args, null);
    }

    pub fn launchOnStream(self: Kernel, grid: Dim3, block: Dim3, shared_bytes: u32, args: []const iface.Arg, stream: CUstream) Error!void {
        try check(g.cuLaunchKernel(
            self.func,
            grid.x,
            grid.y,
            grid.z,
            block.x,
            block.y,
            block.z,
            shared_bytes,
            stream,
            @constCast(args.ptr),
            null,
        ), error.LaunchFailed);
    }

    /// Cooperative launch: driver guarantees all blocks are co-resident, so
    /// a software grid barrier inside the kernel cannot deadlock. Grid must
    /// be ≤ Context.maxCoopBlocks().
    pub fn launchCooperative(self: Kernel, grid: Dim3, block: Dim3, shared_bytes: u32, args: []const iface.Arg, stream: CUstream) Error!void {
        try check(g.cuLaunchCooperativeKernel(
            self.func,
            grid.x,
            grid.y,
            grid.z,
            block.x,
            block.y,
            block.z,
            shared_bytes,
            stream,
            @constCast(args.ptr),
        ), error.LaunchFailed);
    }
};

pub const Stream = struct {
    stream: CUstream = null,

    pub fn synchronize(self: *Stream) Error!void {
        try check(g.cuStreamSynchronize(self.stream), error.SyncFailed);
    }

    pub fn deinit(self: *Stream) void {
        _ = g.cuStreamDestroy_v2(self.stream);
        self.* = .{};
    }
};

/// Record N kernel launches once, replay as a single GPU submission.
pub const Graph = struct {
    exec: CUgraphExec = null,
    graph: CUgraph = null,

    pub fn deinit(self: *Graph) void {
        if (self.exec != null) _ = g.cuGraphExecDestroy(self.exec);
        if (self.graph != null) _ = g.cuGraphDestroy(self.graph);
        self.* = .{};
    }

    pub fn launch(self: *Graph, stream: *Stream) Error!void {
        try check(g.cuGraphLaunch(self.exec, stream.stream), error.LaunchFailed);
    }
};

pub fn beginCapture(stream: *Stream) Error!void {
    // 0 = cudaStreamCaptureModeGlobal
    try check(g.cuStreamBeginCapture_v2(stream.stream, 0), error.LaunchFailed);
}

pub fn endCapture(stream: *Stream) Error!Graph {
    var gr: Graph = .{};
    try check(g.cuStreamEndCapture(stream.stream, &gr.graph), error.LaunchFailed);
    errdefer gr.deinit(); // exec still null here: only the captured graph is destroyed
    try check(g.cuGraphInstantiate_v2(&gr.exec, gr.graph, null, null, 0), error.LaunchFailed);
    return gr;
}
