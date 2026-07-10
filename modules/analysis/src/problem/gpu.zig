//! GPU problem packing — one contiguous blob, offsets not pointers.

const std = @import("std");
const root = @import("../root.zig");
const gpu_abi = @import("../gpu_abi.zig");

const Circuit = root.Circuit;

// ============================================================================
// GPU problem packing — one contiguous blob, offsets not pointers.
// Layout: Header | batch table | current_row | batch payloads | x | result |
// device-only workspace. Host uploads [0, off_ws) once per problem; per
// solve it re-uploads only the payload+x window and downloads the single
// contiguous [off_x, off_ws) window (x + ResultHeader).
// ============================================================================

pub const GpuProblem = struct {
    hdr: gpu_abi.Header,
    /// Staged upload prefix [0, off_ws), 8-aligned.
    stage: []align(8) u8,
    /// Blob offset where the per-solve dirty region starts (batch payloads —
    /// models/instances change under sweeps; tapes don't, but one contiguous
    /// window beats bookkeeping).
    off_dirty: u32,

    pub fn deinit(self: *GpuProblem, gpa: std.mem.Allocator) void {
        gpa.free(self.stage);
        self.* = undefined;
    }

    pub fn xBytes(self: *const GpuProblem) []u8 {
        return self.stage[self.hdr.off_x..][0 .. @as(usize, self.hdr.n) * 8];
    }

    /// Refresh the staged batch payloads from live batch storage — sweeps
    /// (dc/mc/temp) mutate models/instances through ParamRef pointers after
    /// packing. Offsets are layout-stable; only the bytes change.
    pub fn repack(self: *GpuProblem, ckt: *const Circuit) void {
        const table: [*]gpu_abi.BatchDesc = @ptrCast(@alignCast(self.stage.ptr + self.hdr.off_batch_table));
        var p: usize = self.off_dirty;
        for (ckt.batches, 0..) |b, i| {
            const sz = b.hooks.gpu_pack_size.?(b.ctx);
            table[i] = b.hooks.gpu_pack.?(b.ctx, self.stage[p..][0..sz], @intCast(p), ckt.n);
            p += sz;
        }
    }
};

/// Every batch packable ⇒ whole circuit can solve on-device.
pub fn gpuEligible(ckt: *const Circuit) bool {
    if (ckt.has_history) return false;
    for (ckt.batches) |b| if (b.hooks.gpu_pack == null) return false;
    return true;
}

/// Transient sections for arp_tran: empty for a pure solve pack (zero-length
/// sections, identical layout either way). Scalar tran knobs (dt/method/...)
/// are patched into the staged header per launch by the driver, not baked in.
pub const TranPack = struct {
    probes: []const u32 = &.{},
    breakpoints: []const f64 = &.{}, // sorted ascending, < t_stop
    wave_capacity: u32 = 0, // points; one point = (1 + n_probes) f64
};

pub fn packGpuProblem(gpa: std.mem.Allocator, ckt: *const Circuit, tol: gpu_abi.Tol, n_blocks: u32, tp: TranPack) !GpuProblem {
    const a8 = gpu_abi.alignUp;
    const n: usize = ckt.n;
    const m: usize = @min(tol.gmres_m, ckt.n);
    const nb = ckt.batches.len;

    const off_table = a8(@sizeOf(gpu_abi.Header), 8);
    const off_current_row = a8(off_table + nb * @sizeOf(gpu_abi.BatchDesc), 8);
    var off: usize = a8(off_current_row + n, 8);
    const off_dirty = off;
    var payload_sizes = try gpa.alloc(usize, nb);
    defer gpa.free(payload_sizes);
    for (ckt.batches, 0..) |b, i| {
        payload_sizes[i] = (b.hooks.gpu_pack_size orelse return error.NotGpuEligible)(b.ctx);
        off += payload_sizes[i];
    }
    const off_probes = a8(off, 8);
    const off_breakpoints = a8(off_probes + tp.probes.len * 4, 8);
    const off_x = a8(off_breakpoints + tp.breakpoints.len * 8, 8);
    const off_result = a8(off_x + n * 8, 8);
    const off_wave = a8(off_result + @sizeOf(gpu_abi.ResultHeader), 8);
    const wave_bytes = @as(usize, tp.wave_capacity) * (1 + tp.probes.len) * 8;
    const off_ws = a8(off_wave + wave_bytes, 8);
    const total = off_ws + gpu_abi.wsF64Count(n, m) * 8;

    const stage = try gpa.alignedAlloc(u8, .@"8", off_ws);
    errdefer gpa.free(stage);
    @memset(stage, 0);

    var hdr: gpu_abi.Header = .{
        .magic = gpu_abi.magic,
        .n = ckt.n,
        .n_batches = @intCast(nb),
        .n_blocks = n_blocks,
        .tol = tol,
        .t = 0,
        .off_batch_table = @intCast(off_table),
        .off_current_row = @intCast(off_current_row),
        .off_x = @intCast(off_x),
        .off_ws = @intCast(off_ws),
        .off_result = @intCast(off_result),
        .total_bytes = @intCast(total),
        .method = 0,
        .tran_reset = 0,
        .n_probes = @intCast(tp.probes.len),
        .n_breakpoints = @intCast(tp.breakpoints.len),
        .max_steps_chunk = 0,
        .wave_capacity = tp.wave_capacity,
        .off_probes = @intCast(off_probes),
        .off_breakpoints = @intCast(off_breakpoints),
        .off_wave = @intCast(off_wave),
        ._pad = 0,
        .t_stop = 0,
        .dt_init = 0,
        .dt_min = 0,
        .dt_max = 0,
        .chgtol = 0,
        .trtol = 0,
    };

    const table: [*]gpu_abi.BatchDesc = @ptrCast(@alignCast(stage.ptr + off_table));
    var p: usize = off_dirty;
    for (ckt.batches, 0..) |b, i| {
        table[i] = b.hooks.gpu_pack.?(b.ctx, stage[p..][0..payload_sizes[i]], @intCast(p), ckt.n);
        p += payload_sizes[i];
    }
    for (0..n) |i| stage[off_current_row + i] = @intFromBool(ckt.current_row[i]);
    if (tp.probes.len > 0)
        @memcpy(stage[off_probes..][0 .. tp.probes.len * 4], std.mem.sliceAsBytes(tp.probes));
    if (tp.breakpoints.len > 0)
        @memcpy(stage[off_breakpoints..][0 .. tp.breakpoints.len * 8], std.mem.sliceAsBytes(tp.breakpoints));
    @memcpy(stage[0..@sizeOf(gpu_abi.Header)], std.mem.asBytes(&hdr));

    return .{ .hdr = hdr, .stage = stage, .off_dirty = @intCast(off_dirty) };
}
