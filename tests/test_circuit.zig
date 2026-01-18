//! Synthetic circuit builder for analysis tests. Wraps batch.freeze() +
//! testdev devices so any test can construct a real Circuit without the
//! engine's parser/builder pipeline.
const std = @import("std");
const root = @import("analysis");
const batch = @import("analysis").problem;
const testdev = @import("testdev.zig");

const Circuit = root.Circuit;
const Proto = batch.Proto;

pub const Desc = struct {
    resistors: []const struct { p: u32, n: u32, r: f32 = 1000 } = &.{},
    vsources: []const struct { p: u32, n: u32, dc: f32 = 0, amp: f32 = 0, freq: f32 = 0 } = &.{},
    isources: []const struct { p: u32, n: u32, dc: f32 = 0 } = &.{},
    capacitors: []const struct { p: u32, n: u32, c: f32 = 1e-6 } = &.{},
    diodes: []const struct { p: u32, n: u32, is: f32 = 1e-14 } = &.{},
    inductors: []const struct { p: u32, n: u32, l: f32 = 1e-3 } = &.{},
};

pub fn build(gpa: std.mem.Allocator, desc: Desc) !Circuit {
    var n: u32 = 1; // node 0 is ground
    for (desc.resistors) |d| n = @max(n, @max(d.p, d.n) + 1);
    for (desc.vsources) |d| n = @max(n, @max(d.p, d.n) + 1);
    for (desc.isources) |d| n = @max(n, @max(d.p, d.n) + 1);
    for (desc.capacitors) |d| n = @max(n, @max(d.p, d.n) + 1);
    for (desc.diodes) |d| n = @max(n, @max(d.p, d.n) + 1);
    for (desc.inductors) |d| n = @max(n, @max(d.p, d.n) + 1);

    // Vsources and inductors add branch unknowns
    const n_branches = desc.vsources.len + desc.inductors.len;
    const total_n = n + @as(u32, @intCast(n_branches));

    var protos: std.ArrayList(Proto) = .empty;
    defer protos.deinit(gpa);

    if (desc.resistors.len > 0) {
        const store = try gpa.create(batch.ProtoStore(testdev.R));
        store.* = .{};
        for (desc.resistors) |d| {
            try store.models.append(gpa, .{ .r = d.r });
            try store.instances.append(gpa, .{});
            try store.nodes.append(gpa, .{ d.p, d.n });
        }
        try protos.append(gpa, .{
            .ctx = store,
            .type_name = @typeName(testdev.R),
            .pattern = batch.ProtoStore(testdev.R).addPattern,
            .finalize = batch.ProtoStore(testdev.R).finalize,
            .destroy = batch.ProtoStore(testdev.R).destroy,
            .apply_perm = batch.ProtoStore(testdev.R).applyPerm,
        });
    }

    if (desc.vsources.len > 0) {
        const store = try gpa.create(batch.ProtoStore(testdev.V));
        store.* = .{};
        var br: u32 = n;
        for (desc.vsources) |d| {
            try store.models.append(gpa, .{ .dc = d.dc, .amp = d.amp, .freq = d.freq });
            try store.instances.append(gpa, .{});
            try store.nodes.append(gpa, .{ d.p, d.n, br });
            br += 1;
        }
        try protos.append(gpa, .{
            .ctx = store,
            .type_name = @typeName(testdev.V),
            .pattern = batch.ProtoStore(testdev.V).addPattern,
            .finalize = batch.ProtoStore(testdev.V).finalize,
            .destroy = batch.ProtoStore(testdev.V).destroy,
            .apply_perm = batch.ProtoStore(testdev.V).applyPerm,
        });
    }

    if (desc.isources.len > 0) {
        const store = try gpa.create(batch.ProtoStore(testdev.I));
        store.* = .{};
        for (desc.isources) |d| {
            try store.models.append(gpa, .{ .dc = d.dc });
            try store.instances.append(gpa, .{});
            try store.nodes.append(gpa, .{ d.p, d.n });
        }
        try protos.append(gpa, .{
            .ctx = store,
            .type_name = @typeName(testdev.I),
            .pattern = batch.ProtoStore(testdev.I).addPattern,
            .finalize = batch.ProtoStore(testdev.I).finalize,
            .destroy = batch.ProtoStore(testdev.I).destroy,
            .apply_perm = batch.ProtoStore(testdev.I).applyPerm,
        });
    }

    if (desc.capacitors.len > 0) {
        const store = try gpa.create(batch.ProtoStore(testdev.C));
        store.* = .{};
        for (desc.capacitors) |d| {
            try store.models.append(gpa, .{ .c = d.c });
            try store.instances.append(gpa, .{});
            try store.nodes.append(gpa, .{ d.p, d.n });
        }
        try protos.append(gpa, .{
            .ctx = store,
            .type_name = @typeName(testdev.C),
            .pattern = batch.ProtoStore(testdev.C).addPattern,
            .finalize = batch.ProtoStore(testdev.C).finalize,
            .destroy = batch.ProtoStore(testdev.C).destroy,
            .apply_perm = batch.ProtoStore(testdev.C).applyPerm,
        });
    }

    if (desc.diodes.len > 0) {
        const store = try gpa.create(batch.ProtoStore(testdev.D));
        store.* = .{};
        for (desc.diodes) |d| {
            try store.models.append(gpa, .{ .is = d.is });
            try store.instances.append(gpa, .{});
            try store.nodes.append(gpa, .{ d.p, d.n });
        }
        try protos.append(gpa, .{
            .ctx = store,
            .type_name = @typeName(testdev.D),
            .pattern = batch.ProtoStore(testdev.D).addPattern,
            .finalize = batch.ProtoStore(testdev.D).finalize,
            .destroy = batch.ProtoStore(testdev.D).destroy,
            .apply_perm = batch.ProtoStore(testdev.D).applyPerm,
        });
    }

    if (desc.inductors.len > 0) {
        const store = try gpa.create(batch.ProtoStore(testdev.L));
        store.* = .{};
        var br: u32 = n + @as(u32, @intCast(desc.vsources.len));
        for (desc.inductors) |d| {
            try store.models.append(gpa, .{ .l = d.l });
            try store.instances.append(gpa, .{});
            try store.nodes.append(gpa, .{ d.p, d.n, br });
            br += 1;
        }
        try protos.append(gpa, .{
            .ctx = store,
            .type_name = @typeName(testdev.L),
            .pattern = batch.ProtoStore(testdev.L).addPattern,
            .finalize = batch.ProtoStore(testdev.L).finalize,
            .destroy = batch.ProtoStore(testdev.L).destroy,
            .apply_perm = batch.ProtoStore(testdev.L).applyPerm,
        });
    }

    // Flat intern table: node 0 = "0", node i = "n{i}". Build the labels,
    // flatten into bytes+offs, free the temporaries (freeze owns the table).
    const labels = try gpa.alloc([]const u8, total_n);
    defer gpa.free(labels);
    labels[0] = try gpa.dupe(u8, "0");
    for (1..total_n) |i| labels[i] = try std.fmt.allocPrint(gpa, "n{d}", .{i});
    defer for (labels) |l| gpa.free(l);

    var total: usize = 0;
    for (labels) |l| total += l.len;
    const intern_bytes = try gpa.alloc(u8, total);
    const intern_offs = try gpa.alloc(u32, total_n + 1);
    var off: u32 = 0;
    for (labels, 0..) |l, i| {
        intern_offs[i] = off;
        @memcpy(intern_bytes[off..][0..l.len], l);
        off += @intCast(l.len);
    }
    intern_offs[total_n] = off;

    return batch.freeze(gpa, total_n, intern_bytes, intern_offs, protos.items, null);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const op = root.op;

test "test_circuit: resistor divider OP" {
    var ckt = try build(testing.allocator, .{
        .vsources = &.{.{ .p = 1, .n = 0, .dc = 10.0 }},
        .resistors = &.{
            .{ .p = 1, .n = 2, .r = 1000 },
            .{ .p = 2, .n = 0, .r = 1000 },
        },
    });
    defer ckt.deinit();

    const x = try testing.allocator.alloc(f64, ckt.n);
    defer testing.allocator.free(x);
    const result = try op.solve(&ckt, x, .{});
    try testing.expect(result.converged);
    try testing.expectApproxEqAbs(@as(f64, 5.0), x[2], 1e-6);
}

// The memo keys on x_op's POINTER, and x_op is one stable arena slice — so a
// direct eval at a different x must clear it, or the next linearize(x_op)
// false-hits on planes that hold someone else's operating point. disto,
// matex, qpss, pss, pnoise, pac, pxf and tran_noise all eval directly.
test "LinCache: a direct eval at another x invalidates the memo" {
    var ckt = try build(testing.allocator, .{
        .vsources = &.{.{ .p = 1, .n = 0, .dc = 10.0 }},
        .resistors = &.{
            .{ .p = 1, .n = 2, .r = 1000 },
            .{ .p = 2, .n = 0, .r = 1000 },
        },
    });
    defer ckt.deinit();

    const x_op = try testing.allocator.alloc(f64, ckt.n + 1);
    defer testing.allocator.free(x_op);
    @memset(x_op, 0);

    ckt.linearize(x_op);
    try testing.expect(ckt.lin.valid);

    const x_other = try testing.allocator.alloc(f64, ckt.n + 1);
    defer testing.allocator.free(x_other);
    @memset(x_other, 1.0);
    ckt.eval(x_other, 0);
    try testing.expect(!ckt.lin.valid);

    // Same pointer as the first call: must re-evaluate, not hit the memo.
    ckt.linearize(x_op);
    try testing.expect(ckt.lin.valid);
}
