//! Synthetic circuit builder for analysis tests. Wraps batch.freeze() +
//! testdev devices so any test can construct a real Circuit without the
//! engine's parser/builder pipeline.
const std = @import("std");
const root = @import("analysis");
const batch = @import("analysis").problem;
const testdev = @import("testdev.zig");

const Circuit = root.Circuit;
const Proto = batch.Proto;

fn protoFor(comptime D: type, store: *batch.ProtoStore(D)) Proto {
    return .{
        .ctx = store,
        .type_name = @typeName(D),
        .pattern = batch.ProtoStore(D).addPattern,
        .finalize = batch.ProtoStore(D).finalize,
        .destroy = batch.ProtoStore(D).destroy,
        .apply_perm = batch.ProtoStore(D).applyPerm,
    };
}

pub fn build(gpa: std.mem.Allocator) !Circuit {
    var protos: std.ArrayList(Proto) = .empty;
    defer protos.deinit(gpa);

    const resistors = try gpa.create(batch.ProtoStore(testdev.R));
    resistors.* = .{};
    for ([_][2]u32{ .{ 1, 2 }, .{ 2, 0 } }) |nodes| {
        try resistors.models.append(gpa, .{ .r = 1000 });
        try resistors.instances.append(gpa, .{});
        try resistors.nodes.append(gpa, nodes);
    }
    try protos.append(gpa, protoFor(testdev.R, resistors));

    const source = try gpa.create(batch.ProtoStore(testdev.V));
    source.* = .{};
    try source.models.append(gpa, .{ .dc = 10.0 });
    try source.instances.append(gpa, .{});
    try source.nodes.append(gpa, .{ 1, 0, 3 });
    try protos.append(gpa, protoFor(testdev.V, source));

    // Node 0 is ground; n3 is the source branch. Freeze owns both slices.
    const intern_bytes = try gpa.dupe(u8, "0n1n2n3");
    const intern_offs = try gpa.dupe(u32, &.{ 0, 1, 3, 5, 7 });
    return batch.freeze(gpa, 4, intern_bytes, intern_offs, protos.items, null);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const op = root.op;

test "test_circuit: resistor divider OP" {
    var ckt = try build(testing.allocator);
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
    var ckt = try build(testing.allocator);
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
