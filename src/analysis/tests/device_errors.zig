const std = @import("std");
const ir = @import("device_ir");
const t = std.testing;
extern fn testDeviceVtable() *const ir.DeviceVtable;
extern fn testTooManyInstances() *const anyopaque;

const pattern: ir.PatternView = .{
    .col_ptr = &.{ 0, 2, 4 },
    .row_idx = &.{ 0, 1, 0, 1 },
    .n = 2,
    .trash_slot = 4,
};

fn prepare(allocator: std.mem.Allocator) !ir.Batch {
    const vt = testDeviceVtable();
    const proto = try vt.proto_create(allocator).unwrap();
    defer proto.destroy(proto.ctx, allocator);
    var model: [8]u8 align(16) = undefined;
    var instance: [8]u8 align(16) = undefined;
    vt.init_model(&model);
    vt.init_instance(&instance);
    try vt.proto_add(proto.ctx, allocator, &model, &instance, &.{ 0, 1 }).unwrap();
    var pb: ir.PatternBuilder = .{};
    defer pb.deinit(allocator);
    try proto.pattern(proto.ctx, allocator, &pb).unwrap();
    return proto.finalize(proto.ctx, allocator, pattern).unwrap();
}

fn lifecycle(allocator: std.mem.Allocator) !void {
    const batch = try prepare(allocator);
    defer batch.hooks.deinit(batch.ctx, allocator);
    const instance = try batch.hooks.instantiate(batch.ctx, allocator).unwrap();
    defer instance.hooks.deinit(instance.ctx, allocator);
    const snapshot = try instance.hooks.snapshot(instance.ctx, allocator).unwrap();
    defer snapshot.hooks.deinit(snapshot.ctx, allocator);
    var params: std.ArrayList(ir.ParamRef) = .empty;
    defer params.deinit(allocator);
    try snapshot.hooks.collect_params(snapshot.ctx, allocator, &params).unwrap();
    try t.expectEqual(@as(usize, 2), params.items.len);
    var noise: std.ArrayList(ir.NoiseSource) = .empty;
    defer noise.deinit(allocator);
    try snapshot.hooks.collect_noise.?(snapshot.ctx, &.{ 0, 1 }, allocator, &noise).unwrap();
    try t.expectEqual(@as(usize, 1), noise.items.len);
    try t.expect(snapshot.hooks.recompute.?(snapshot.ctx));
}

test "separately compiled callbacks preserve allocation failures and ownership" {
    try lifecycle(t.allocator);
    try t.checkAllAllocationFailures(t.allocator, lifecycle, .{});
}

test "separately compiled statuses decode to consumer-local errors" {
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    const result = testDeviceVtable().proto_create(failing.allocator());
    try t.expectEqual(ir.DeviceStatus.out_of_memory, std.meta.activeTag(result));
    // The same spelling has compilation-local ordinals; compare both the local
    // value and name so optimizer knowledge cannot hide a foreign error number.
    const unexpected = result.unwrap() catch |err| {
        try t.expectEqual(@intFromError(error.OutOfMemory), @intFromError(err));
        try t.expectEqualStrings("OutOfMemory", @errorName(err));
        if (@sizeOf(usize) > 4) {
            const too_many: *const fn () ir.DeviceResult(ir.Batch) = @ptrCast(testTooManyInstances());
            try t.expectError(error.TooManyInstances, too_many().unwrap());
        }
        return;
    };
    _ = unexpected;
    return error.ExpectedOutOfMemory;
}

test "separately compiled topology check retains success and failure" {
    const batch = try prepare(t.allocator);
    defer batch.hooks.deinit(batch.ctx, t.allocator);
    var params: std.ArrayList(ir.ParamRef) = .empty;
    defer params.deinit(t.allocator);
    try batch.hooks.collect_params(batch.ctx, t.allocator, &params).unwrap();
    try t.expect(batch.hooks.recompute.?(batch.ctx));
    for (params.items) |param| {
        if (!std.mem.eql(u8, param.param_name, "r")) continue;
        param.set(-1);
        try t.expect(!batch.hooks.recompute.?(batch.ctx));
        param.set(1000);
        try t.expect(batch.hooks.recompute.?(batch.ctx));
        return;
    }
    return error.MissingResistance;
}
