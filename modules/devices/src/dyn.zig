//! Dyn (dlopen'd) generated devices — the whole .so boundary in one file.
//!
//! Unlike the old per-instance ABI (eval_ad crossing per device: scratch
//! copies, no dedup, no prep cache), this ABI crosses PER BATCH: the shared
//! object compiles batch.zig's ProtoStore(D)/DeviceBatch(D) itself and hands
//! the app the same type-erased Proto the baked path uses. Hot-loop machine
//! code is identical to a compiled-in device; overhead is the one indirect
//! Batch.eval call per batch that builtins already pay.
//!
//! Safety: the surface is Zig-ABI (slices, Allocator, anyerror), valid only
//! when both sides were built from the same source with the same compiler.
//! `layoutHash()` is compiled into both sides and checked at open(); a
//! mismatch rejects the .so so the loader recompiles it.
//!
//! Known wart: anyerror values coming out of the .so carry the .so's error
//! numbering — propagation works, @errorName may not. Errors here are OOM in
//! practice.

const std = @import("std");
const builtin = @import("builtin");
const batch_mod = @import("batch.zig");
const contract = @import("contract");

const Batch = batch_mod.Batch;
const Hooks = batch_mod.Hooks;
const Planes = batch_mod.Planes;
const PatternBuilder = batch_mod.PatternBuilder;
const PatternView = batch_mod.PatternView;
const Proto = batch_mod.Proto;
const ParamRef = batch_mod.ParamRef;
const NoiseSource = batch_mod.NoiseSource;
const ProtoStore = batch_mod.ProtoStore;
const DeviceBatchFn = batch_mod.DeviceBatch;

pub const abi_version: u32 = 4;

/// Everything a runtime device exposes. One static instance per .so,
/// reached through the `arp_device` symbol.
pub const DeviceVtable = struct {
    /// Model name netlist instances bind to (static string in the .so).
    name: []const u8,
    n_u: u32,
    num_ports: u32,
    model_size: usize,
    instance_size: usize,
    /// Write a default-initialized Model/Instance into caller-owned bytes
    /// (align 16 suffices — device params are f32/f64/int/bool).
    init_model: *const fn ([*]u8) void,
    init_instance: *const fn ([*]u8) void,
    /// Name-addressed numeric param write; false = no such field.
    set_model_param: *const fn ([*]u8, []const u8, f64) bool,
    set_instance_param: *const fn ([*]u8, []const u8, f64) bool,
    /// Internal-unknown collapse map (null when D has no collapse decl):
    /// fills out[num_ports..n_u] with the port index to collapse onto, or -1
    /// for "allocate a fresh internal node". Node allocation stays app-side.
    collapse: ?*const fn (model: [*]const u8, instance: [*]const u8, out: [*]i32) void,
    /// New ProtoStore(D)-backed Proto. Its finalize() builds the full
    /// DeviceBatch inside the .so — dedup, prep cache, limiting, the lot —
    /// with gpu_pack nulled (the baked megakernel cannot know this kind).
    proto_create: *const fn (std.mem.Allocator) anyerror!Proto,
    /// Append one instance to the proto: param blobs + nodes[n_u]
    /// (ports first, internal unknowns pre-assigned by the caller).
    proto_add: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, model: [*]const u8, instance: [*]const u8, nodes: [*]const u32) anyerror!void,
};

/// Layout guard over every type that crosses the boundary, plus the compiler
/// version. Both sides compile this same source; equal hashes ⇒ compatible.
pub fn layoutHash() u64 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var h: u64 = 0xcbf29ce484222325;
        for (builtin.zig_version_string) |c| h = mix(h, c);
        // Backend (self-hosted vs LLVM) and mode both change Zig-ABI details;
        // a .so must match the app on all of them.
        h = mix(h, @intFromEnum(builtin.zig_backend));
        h = mix(h, @intFromEnum(builtin.mode));
        for ([_]type{
            DeviceVtable,       Proto,              Batch,
            Hooks,              Planes,             PatternView,
            PatternBuilder,     ParamRef,           NoiseSource,
            std.mem.Allocator,
        }) |T| h = hashType(h, T);
        break :blk h;
    };
}

fn mix(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x100000001b3;
}

fn hashType(h0: u64, comptime T: type) u64 {
    var h = mix(mix(h0, @sizeOf(T)), @alignOf(T));
    switch (@typeInfo(T)) {
        .@"struct" => |si| inline for (si.fields) |f| {
            if (!f.is_comptime and @sizeOf(f.type) > 0) h = mix(h, @offsetOf(T, f.name));
        },
        else => {},
    }
    return h;
}

// ---------------------------------------------------------------------------
// .so side: called at comptime by the generated shim root.
// ---------------------------------------------------------------------------

/// Export a contract-shaped device under the runtime ABI. The generated shim
/// is one line: `comptime { dyn.exportDevice(@import("device"), "name"); }`.
pub fn exportDevice(comptime D: type, comptime device_name: []const u8) void {
    const impl = Impl(D, device_name);
    @export(&impl.abiVersion, .{ .name = "arp_abi_version" });
    @export(&impl.layoutHashC, .{ .name = "arp_layout_hash" });
    @export(&impl.getVtable, .{ .name = "arp_device" });
}

/// In-process vtable (tests, embedding without dlopen).
pub fn deviceVtable(comptime D: type, comptime device_name: []const u8) *const DeviceVtable {
    return &Impl(D, device_name).vtable;
}

fn Impl(comptime D: type, comptime device_name: []const u8) type {
    return struct {
        const Store = ProtoStore(D);
        const n_u = @typeInfo(D.U).@"enum".fields.len;

        fn abiVersion() callconv(.c) u32 {
            return abi_version;
        }
        fn layoutHashC() callconv(.c) u64 {
            return layoutHash();
        }
        fn getVtable() callconv(.c) *const DeviceVtable {
            return &vtable;
        }

        const vtable: DeviceVtable = .{
            .name = device_name,
            .n_u = n_u,
            .num_ports = D.num_ports,
            .model_size = @sizeOf(D.Model),
            .instance_size = @sizeOf(D.Instance),
            .init_model = initBlob(D.Model),
            .init_instance = initBlob(D.Instance),
            .set_model_param = setParam(D.Model),
            .set_instance_param = setParam(D.Instance),
            .collapse = if (@hasDecl(D, "collapse")) collapseFn else null,
            .proto_create = protoCreate,
            .proto_add = protoAdd,
        };

        fn initBlob(comptime T: type) *const fn ([*]u8) void {
            return struct {
                fn f(dest: [*]u8) void {
                    const p: *T = @ptrCast(@alignCast(dest));
                    p.* = .{};
                }
            }.f;
        }

        /// Same field walk as netlist applyKv, addressed by name at runtime.
        /// Case-insensitive: the netlist tokenizer lowercases keys while
        /// generated Model fields keep their Verilog-A spelling (R, VOFF).
        fn setParam(comptime T: type) *const fn ([*]u8, []const u8, f64) bool {
            return struct {
                fn f(dest: [*]u8, param: []const u8, value: f64) bool {
                    @setEvalBranchQuota(10_000);
                    const p: *T = @ptrCast(@alignCast(dest));
                    inline for (@typeInfo(T).@"struct".fields) |field| {
                        switch (@typeInfo(field.type)) {
                            .float => if (std.ascii.eqlIgnoreCase(param, field.name)) {
                                @field(p, field.name) = @floatCast(value);
                                return true;
                            },
                            .int => if (std.ascii.eqlIgnoreCase(param, field.name)) {
                                @field(p, field.name) = @intFromFloat(value);
                                return true;
                            },
                            .bool => if (std.ascii.eqlIgnoreCase(param, field.name)) {
                                @field(p, field.name) = value != 0;
                                return true;
                            },
                            else => {},
                        }
                    }
                    return false;
                }
            }.f;
        }

        fn collapseFn(model: [*]const u8, instance: [*]const u8, out: [*]i32) void {
            const m: *const D.Model = @ptrCast(@alignCast(model));
            const i: *const D.Instance = @ptrCast(@alignCast(instance));
            const col = D.collapse(m, i);
            inline for (D.num_ports..n_u) |u|
                out[u] = if (col[u]) |p| @intCast(p) else -1;
        }

        fn protoCreate(gpa: std.mem.Allocator) anyerror!Proto {
            const store = try gpa.create(Store);
            store.* = .{};
            return .{
                .ctx = store,
                // vtable.name, so Builder's identity check (type_name.ptr)
                // dedups repeat instances into one proto.
                .type_name = device_name,
                .pattern = Store.addPattern,
                .finalize = finalizeNoGpu,
                .destroy = Store.destroy,
                .apply_perm = Store.applyPerm,
            };
        }

        fn protoAdd(ctx: *anyopaque, gpa: std.mem.Allocator, model: [*]const u8, instance: [*]const u8, nodes: [*]const u32) anyerror!void {
            const store: *Store = @ptrCast(@alignCast(ctx));
            const m: *const D.Model = @ptrCast(@alignCast(model));
            const i: *const D.Instance = @ptrCast(@alignCast(instance));
            try store.models.append(gpa, m.*);
            try store.instances.append(gpa, i.*);
            try store.nodes.append(gpa, nodes[0..n_u].*);
        }

        /// Real finalize, then strip GPU: this kind is not baked into the
        /// megakernel, so gpuEligible() must see gpu_pack == null (whole
        /// circuit falls back to CPU, loudly reported by the gpu driver).
        fn finalizeNoGpu(ctx: *anyopaque, gpa: std.mem.Allocator, pv: PatternView) anyerror!Batch {
            var b = try Store.finalize(ctx, gpa, pv);
            b.gpu_kind_id = 0;
            b.hooks = &nogpu_hooks;
            return b;
        }
        const nogpu_hooks: Hooks = blk: {
            var h = DeviceBatchFn(D).hooks;
            h.gpu_pack = null;
            h.gpu_pack_size = null;
            break :blk h;
        };
    };
}

// ---------------------------------------------------------------------------
// App side: dlopen + handshake.
// ---------------------------------------------------------------------------

test "dyn vtable: blob init, param set by name, proto add" {
    const R = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct { r: f32 = 1000 };
        pub const Instance = struct { temp: f32 = 300.15 };
        pub fn eval(comptime S: type, x: [2]S, m: *const Model, _: *const Instance, _: f64) [2]S {
            const i = x[0].sub(x[1]).scale(1.0 / @as(f64, m.r));
            return .{ i, i.neg() };
        }
    };
    const testing = std.testing;
    const vt = deviceVtable(R, "tres");
    try testing.expectEqual(@as(u32, 2), vt.n_u);
    try testing.expectEqual(@sizeOf(R.Model), vt.model_size);

    var mblob: [@sizeOf(R.Model)]u8 align(16) = undefined;
    vt.init_model(&mblob);
    try testing.expect(vt.set_model_param(&mblob, "r", 42));
    try testing.expect(!vt.set_model_param(&mblob, "bogus", 1));
    const m: *R.Model = @ptrCast(@alignCast(&mblob));
    try testing.expectEqual(@as(f32, 42), m.r);

    var iblob: [@sizeOf(R.Instance)]u8 align(16) = undefined;
    vt.init_instance(&iblob);

    const proto = try vt.proto_create(testing.allocator);
    const nodes = [2]u32{ 1, 2 };
    try vt.proto_add(proto.ctx, testing.allocator, &mblob, &iblob, &nodes);
    const store: *batch_mod.ProtoStore(R) = @ptrCast(@alignCast(proto.ctx));
    try testing.expectEqual(@as(usize, 1), store.models.items.len);
    try testing.expectEqual(@as(f32, 42), store.models.items[0].r);
    proto.destroy(proto.ctx, testing.allocator);
}

pub const LoadedDevice = struct {
    lib: std.DynLib,
    vt: *const DeviceVtable,

    /// C-ABI handshake (version + layout hash) BEFORE touching the Zig-ABI
    /// vtable — a stale .so is rejected, never misread.
    pub fn open(path: []const u8) !LoadedDevice {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();

        const u32_fn = *const fn () callconv(.c) u32;
        const u64_fn = *const fn () callconv(.c) u64;
        const ver = lib.lookup(u32_fn, "arp_abi_version") orelse return error.NotArpDevice;
        if (ver() != abi_version) return error.WrongAbiVersion;
        const lh = lib.lookup(u64_fn, "arp_layout_hash") orelse return error.NotArpDevice;
        if (lh() != layoutHash()) return error.LayoutMismatch;

        const get = lib.lookup(*const fn () callconv(.c) *const DeviceVtable, "arp_device") orelse
            return error.NotArpDevice;
        return .{ .lib = lib, .vt = get() };
    }

    pub fn close(self: *LoadedDevice) void {
        self.lib.close();
        self.* = undefined;
    }
};
