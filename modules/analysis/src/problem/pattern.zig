//! Sparsity pattern (dedup (row,col) → sorted CSC) and the gather/scatter
//! tapes precomputed from it. Compile-time only; eval reads tapes.

const std = @import("std");
const root = @import("../root.zig");

const GROUND = root.GROUND;
const Circuit = root.Circuit;

// ---------------------------------------------------------------------------
// Pattern builder: dedup (row,col) set -> sorted CSC. Compile-time only.
// ---------------------------------------------------------------------------
pub const PatternBuilder = struct {
    // Duplicates allowed during accumulation; toCsc() sorts and dedups once.
    // Appending to a flat list is far cheaper than per-entry hash-set puts.
    keys: std.ArrayList(u64) = .empty,

    fn key(row: u32, col: u32) u64 {
        return (@as(u64, col) << 32) | row; // col-major sort order
    }

    pub fn add(self: *PatternBuilder, gpa: std.mem.Allocator, row: u32, col: u32) !void {
        try self.keys.append(gpa, key(row, col));
    }

    /// Reserve for a known number of upcoming add() calls.
    pub fn reserve(self: *PatternBuilder, gpa: std.mem.Allocator, extra: usize) !void {
        try self.keys.ensureUnusedCapacity(gpa, extra);
    }

    pub fn deinit(self: *PatternBuilder, gpa: std.mem.Allocator) void {
        self.keys.deinit(gpa);
    }

    /// LSD radix sort (16-bit digits): O(n) on the bounded (col,row) keys,
    /// several times faster than comparison sort at netlist scale.
    fn radixSort(gpa: std.mem.Allocator, sort_keys: []u64) !void {
        if (sort_keys.len < 64) {
            std.mem.sortUnstable(u64, sort_keys, {}, std.sort.asc(u64));
            return;
        }
        var max_key: u64 = 0;
        for (sort_keys) |k| max_key = @max(max_key, k);

        const tmp = try gpa.alloc(u64, sort_keys.len);
        defer gpa.free(tmp);
        const counts = try gpa.alloc(u32, 1 << 16);
        defer gpa.free(counts);

        var src: []u64 = sort_keys;
        var dst: []u64 = tmp;
        var shift: u6 = 0;
        while (true) {
            @memset(counts, 0);
            for (src) |k| counts[@as(u16, @truncate(k >> shift))] += 1;
            var sum: u32 = 0;
            for (counts) |*c| {
                const c0 = c.*;
                c.* = sum;
                sum += c0;
            }
            for (src) |k| {
                const d: u16 = @truncate(k >> shift);
                dst[counts[d]] = k;
                counts[d] += 1;
            }
            const t = src;
            src = dst;
            dst = t;
            if (shift >= 48 or (max_key >> shift) >> 16 == 0) break;
            shift += 16;
        }
        if (src.ptr != sort_keys.ptr) @memcpy(sort_keys, src);
    }

    pub fn toCsc(self: *PatternBuilder, gpa: std.mem.Allocator, n: u32, col_ptr_out: *[]u32, row_idx_out: *[]u32) !u32 {
        const all = self.keys.items;
        try radixSort(gpa, all);
        // In-place dedup of the sorted keys.
        var m: usize = 0;
        for (all) |k| {
            if (m == 0 or all[m - 1] != k) {
                all[m] = k;
                m += 1;
            }
        }
        const nnz: u32 = @intCast(m);

        const col_ptr = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(col_ptr);
        const row_idx = try gpa.alloc(u32, nnz);
        @memset(col_ptr, 0);
        for (all[0..m], 0..) |k, p| {
            row_idx[p] = @truncate(k);
            col_ptr[(k >> 32) + 1] += 1;
        }
        for (0..n) |j| col_ptr[j + 1] += col_ptr[j];
        col_ptr_out.* = col_ptr;
        row_idx_out.* = row_idx;
        return nnz;
    }
};

/// Scatter window over precomputed tapes: min/max slot and rhs row touched,
/// trash slot / trash row (ground writes) excluded. Shared by the comptime
/// and dyn batches — pure index math on the same tape layout.
pub fn tapeBounds(slots: []const u32, rhs_idx: []const u32, trash_slot: u32, trash_row: u32) [4]u32 {
    var slot_lo: u32 = std.math.maxInt(u32);
    var slot_hi: u32 = 0;
    var row_lo: u32 = std.math.maxInt(u32);
    var row_hi: u32 = 0;
    for (slots) |s| {
        if (s == trash_slot) continue;
        slot_lo = @min(slot_lo, s);
        slot_hi = @max(slot_hi, s + 1);
    }
    for (rhs_idx) |r| {
        if (r == trash_row) continue;
        row_lo = @min(row_lo, r);
        row_hi = @max(row_hi, r + 1);
    }
    if (slot_lo > slot_hi) slot_lo = slot_hi;
    if (row_lo > row_hi) row_lo = row_hi;
    return .{ slot_lo, slot_hi, row_lo, row_hi };
}

/// Precompute the gather/scatter tapes for one batch from its flat node
/// list ([id * n_u + u] layout). Ground rows/cols land in the trash slot.
pub fn buildTapes(nodes: []const u32, n_u: usize, ckt: *const Circuit, gath: []u32, rhs_idx: []u32, slots: []u32) void {
    const count = nodes.len / n_u;
    for (0..count) |id| {
        const nd = nodes[id * n_u ..][0..n_u];
        for (nd, 0..) |node, u| {
            gath[id * n_u + u] = node;
            rhs_idx[id * n_u + u] = if (node == GROUND) ckt.n else node;
        }
        for (nd, 0..) |r, ru| for (nd, 0..) |c, cu| {
            slots[(id * n_u + ru) * n_u + cu] =
                if (r == GROUND or c == GROUND) ckt.trash_slot else ckt.findSlot(r, c).?;
        };
    }
}
