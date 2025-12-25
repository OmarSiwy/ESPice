const std = @import("std");

pub const Netlist = struct {
    title: []const u8,
    devices: DeviceList,
    models: []const Model,
    directives: []const Directive,
    params: []const Kv,
    foreign: []const Foreign,
    generated_devices: []const GeneratedDevice = &.{},
};

pub const Device = struct {
    name: []const u8,
    nodes: []const []const u8,
    positional: []const Value,
    kv: []const Kv,
    subckt_type: u16 = 0,
    subckt_instance: u32 = 0,

    pub fn letter(d: *const Device) u8 {
        return std.ascii.toLower(d.name[0]);
    }
};

pub const SubcktType = struct {
    name: []const u8,
    n_ports: u16,
    n_internal_nodes: u16,
    device_count: u16,
};

/// Full SoA device storage: each field in its own contiguous column, sorted by
/// letter with bucket offsets for zero-branch batch dispatch.
pub const DeviceList = struct {
    len_: usize = 0,
    /// name[0] lowercased — hot discriminant column, SIMD-scannable
    letters: []const u8 = &.{},
    names: []const []const u8 = &.{},
    nodes: []const []const []const u8 = &.{},
    positional: []const []const Value = &.{},
    kv: []const []const Kv = &.{},
    subckt_types_col: []const u16 = &.{},
    subckt_instances_col: []const u32 = &.{},
    /// bucket_starts[c - 'a'] = first index with letter c; [26] = len sentinel
    bucket_starts: [27]u32 = [_]u32{0} ** 27,
    subckt_types: []const SubcktType = &.{},

    pub inline fn len(self: DeviceList) usize {
        return self.len_;
    }

    pub inline fn get(self: DeviceList, i: usize) Device {
        return .{
            .name = self.names[i],
            .nodes = self.nodes[i],
            .positional = self.positional[i],
            .kv = self.kv[i],
            .subckt_type = if (self.subckt_types_col.len > i) self.subckt_types_col[i] else 0,
            .subckt_instance = if (self.subckt_instances_col.len > i) self.subckt_instances_col[i] else 0,
        };
    }

    /// Pre-sliced view of a single letter bucket — all columns narrowed to the
    /// same range for sequential multi-stream iteration.
    pub const Bucket = struct {
        names: []const []const u8,
        nodes: []const []const []const u8,
        positional: []const []const Value,
        kv: []const []const Kv,
        subckt_types_col: []const u16,
        subckt_instances_col: []const u32,

        pub inline fn size(self: Bucket) usize {
            return self.names.len;
        }

        pub inline fn get(self: Bucket, i: usize) Device {
            return .{
                .name = self.names[i],
                .nodes = self.nodes[i],
                .positional = self.positional[i],
                .kv = self.kv[i],
                .subckt_type = if (self.subckt_types_col.len > i) self.subckt_types_col[i] else 0,
                .subckt_instance = if (self.subckt_instances_col.len > i) self.subckt_instances_col[i] else 0,
            };
        }
    };

    pub inline fn bucket(self: DeviceList, c: u8) Bucket {
        const idx = c -% 'a';
        if (idx >= 26) return .{ .names = &.{}, .nodes = &.{}, .positional = &.{}, .kv = &.{}, .subckt_types_col = &.{}, .subckt_instances_col = &.{} };
        const lo = self.bucket_starts[idx];
        const hi = self.bucket_starts[idx + 1];
        return .{
            .names = self.names[lo..hi],
            .nodes = self.nodes[lo..hi],
            .positional = self.positional[lo..hi],
            .kv = self.kv[lo..hi],
            .subckt_types_col = if (self.subckt_types_col.len >= hi) self.subckt_types_col[lo..hi] else &.{},
            .subckt_instances_col = if (self.subckt_instances_col.len >= hi) self.subckt_instances_col[lo..hi] else &.{},
        };
    }

    /// Build from an unsorted device slice: radix-sort by letter, O(N).
    pub fn fromUnsorted(arena: std.mem.Allocator, src: []const Device) error{OutOfMemory}!DeviceList {
        const n = src.len;
        if (n == 0) return .{};

        // Count per-letter
        var counts: [26]u32 = [_]u32{0} ** 26;
        for (src) |d| {
            const idx = d.letter() -% 'a';
            if (idx < 26) counts[idx] += 1;
        }

        // Prefix sum → bucket starts
        var starts: [27]u32 = undefined;
        starts[0] = 0;
        for (0..26) |i| starts[i + 1] = starts[i] + counts[i];

        // Scatter into column arrays
        const letters_col = try arena.alloc(u8, n);
        const names_col = try arena.alloc([]const u8, n);
        const nodes_col = try arena.alloc([]const []const u8, n);
        const pos_col = try arena.alloc([]const Value, n);
        const kv_col = try arena.alloc([]const Kv, n);
        const stype_col = try arena.alloc(u16, n);
        const sinst_col = try arena.alloc(u32, n);

        var write_pos: [26]u32 = starts[0..26].*;
        for (src) |d| {
            const idx = d.letter() -% 'a';
            if (idx < 26) {
                const pos = write_pos[idx];
                letters_col[pos] = idx + 'a';
                names_col[pos] = d.name;
                nodes_col[pos] = d.nodes;
                pos_col[pos] = d.positional;
                kv_col[pos] = d.kv;
                stype_col[pos] = d.subckt_type;
                sinst_col[pos] = d.subckt_instance;
                write_pos[idx] += 1;
            }
        }

        return .{
            .len_ = n,
            .letters = letters_col,
            .names = names_col,
            .nodes = nodes_col,
            .positional = pos_col,
            .kv = kv_col,
            .subckt_types_col = stype_col,
            .subckt_instances_col = sinst_col,
            .bucket_starts = starts,
        };
    }
};

pub const Model = struct {
    name: []const u8,
    kind: []const u8,
    kv: []const Kv,
};

pub const Directive = struct {
    kind: []const u8,
    args: []const Value,
};

pub const Kv = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    num: f64,
    name: []const u8,
    expr: *const Expr,
    group: Group,
};

pub const Group = struct {
    name: []const u8,
    args: []const Value,
};

pub const Expr = union(enum) {
    num: f64,
    ident: []const u8,
    call: Call,
    unop: Un,
    binop: Bin,

    pub const Call = struct { name: []const u8, args: []const *const Expr };
    pub const Un = struct { op: u8, a: *const Expr };
    pub const Bin = struct { op: u8, a: *const Expr, b: *const Expr };
};

pub const Foreign = struct {
    kind: ForeignKind,
    path: []const u8,
};

pub const ForeignKind = enum { osdi_include, pre_osdi, verilog_a, verilog };

pub const GeneratedDevice = struct {
    language: enum { verilog_a, verilog },
    source_path: []const u8,
    name: []const u8,
    ports: []const []const u8,
    params: []const []const u8,
    zig_source: []const u8,
};
