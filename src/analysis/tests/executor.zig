const Worker = @import("../worker.zig").Worker;
const progress = @import("../progress.zig");
const std = @import("std");

test "worker resumes preserved stack state and runs only once" {
    const W = Worker(u64);
    const Context = struct {
        callback: progress.Callback = undefined,
        calls: u8 = 0,
        cleaned: bool = false,

        fn run(ctx: *anyopaque) !u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            defer self.cleaned = true;
            var sum: u64 = 0;
            for (1..4) |i| {
                sum += i;
                try self.callback.checkpoint(.{ .phase = .sweep, .completed = i, .total = 3 });
            }
            return sum;
        }
    };
    var ctx: Context = .{};
    var worker = W.init(std.testing.io, &ctx, Context.run, .{});
    defer worker.deinit();
    ctx.callback = worker.callback();
    try std.testing.expectEqual(@as(u8, 0), ctx.calls);
    try std.testing.expectError(error.NotStarted, worker.wait());
    for (1..4) |i| {
        const outcome = try worker.advance();
        try std.testing.expect(outcome == .progress);
        try std.testing.expectEqual(@as(u64, i), outcome.progress.completed);
        try std.testing.expect(!ctx.cleaned);
    }
    const outcome = try worker.advance();
    try std.testing.expectEqual(@as(u64, 6), outcome.complete);
    try std.testing.expect(ctx.cleaned);
    try std.testing.expectEqual(@as(u8, 1), ctx.calls);
    try std.testing.expectEqual(@as(u64, 6), (try worker.advance()).complete);
}

test "cancel wakes a parked worker and unwinds cleanup" {
    const Context = struct {
        callback: progress.Callback = undefined,
        cleaned: bool = false,

        fn run(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            defer self.cleaned = true;
            while (true) try self.callback.checkpoint(.{ .phase = .transient, .completed = 1 });
        }
    };
    var ctx: Context = .{};
    var worker = Worker(void).init(std.testing.io, &ctx, Context.run, .{});
    defer worker.deinit();
    ctx.callback = worker.callback();
    try std.testing.expect((try worker.advance()) == .progress);
    worker.cancel();
    try std.testing.expect((try worker.wait()) == .cancelled);
    try std.testing.expect(ctx.cleaned);
}

test "worker reports an analysis error after progress" {
    const Context = struct {
        callback: progress.Callback = undefined,
        cleaned: bool = false,

        fn run(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            defer self.cleaned = true;
            try self.callback.checkpoint(.{ .phase = .frequency, .completed = 32 });
            return error.FixtureFailure;
        }
    };
    var ctx: Context = .{};
    var worker = Worker(void).init(std.testing.io, &ctx, Context.run, .{});
    defer worker.deinit();
    ctx.callback = worker.callback();
    try std.testing.expect((try worker.advance()) == .progress);
    try std.testing.expectEqual(error.FixtureFailure, (try worker.advance()).failed);
    try std.testing.expect(ctx.cleaned);
}

test "independent workers enter concurrently and preserve separate state" {
    const Barrier = struct {
        io: std.Io,
        entered: std.atomic.Value(u8) = .init(0),
        both: std.Io.Event = .unset,
    };
    const Context = struct {
        callback: progress.Callback = undefined,
        barrier: *Barrier,
        value: u32,

        fn run(ctx: *anyopaque) !u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.barrier.entered.fetchAdd(1, .acq_rel) == 1)
                self.barrier.both.set(self.barrier.io);
            self.barrier.both.waitUncancelable(self.barrier.io);
            const saved = self.value;
            try self.callback.checkpoint(.{ .phase = .sweep, .completed = saved });
            return saved + 1;
        }
    };
    // This initializer disables Io's own worker pool, not cross-thread futexes.
    // C handles use it to avoid modifying their host's signal handlers.
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    var barrier: Barrier = .{ .io = io };
    var first: Context = .{ .barrier = &barrier, .value = 10 };
    var second: Context = .{ .barrier = &barrier, .value = 20 };
    var one = Worker(u32).init(io, &first, Context.run, .{});
    defer one.deinit();
    var two = Worker(u32).init(io, &second, Context.run, .{});
    defer two.deinit();
    first.callback = one.callback();
    second.callback = two.callback();
    try one.start();
    try two.start();
    try std.testing.expectEqual(@as(u64, 10), (try one.wait()).progress.completed);
    try std.testing.expectEqual(@as(u64, 20), (try two.wait()).progress.completed);
    try two.start();
    try one.start();
    try std.testing.expectEqual(@as(u32, 11), (try one.wait()).complete);
    try std.testing.expectEqual(@as(u32, 21), (try two.wait()).complete);
}

test "cancel before first resume never invokes the analysis" {
    const Context = struct {
        called: bool = false,
        fn run(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
        }
    };
    var ctx: Context = .{};
    var worker = Worker(void).init(std.testing.io, &ctx, Context.run, .{});
    defer worker.deinit();
    worker.cancel();
    try std.testing.expect((try worker.advance()) == .cancelled);
    try std.testing.expect(!ctx.called);
}

test "suppressed nonlinear checkpoints still observe cancellation" {
    const Context = struct {
        callback: progress.Callback = undefined,
        entered: std.Io.Event = .unset,
        cleaned: bool = false,

        fn run(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            defer self.cleaned = true;
            self.entered.set(std.testing.io);
            var completed: u64 = 0;
            while (true) {
                try self.callback.checkpoint(.{ .phase = .nonlinear, .completed = completed });
                completed += 1;
            }
        }
    };
    var ctx: Context = .{};
    var worker = Worker(void).init(std.testing.io, &ctx, Context.run, .{});
    defer worker.deinit();
    ctx.callback = worker.callback();
    try worker.start();
    ctx.entered.waitUncancelable(std.testing.io);
    worker.cancel();
    try std.testing.expect((try worker.wait()) == .cancelled);
    try std.testing.expect(ctx.cleaned);
    try std.testing.expect(worker.thread == null);
}

test "OP can publish nonlinear iteration progress" {
    const Context = struct {
        callback: progress.Callback = undefined,
        fn run(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.callback.checkpoint(.{ .phase = .nonlinear, .completed = 1 });
        }
    };
    var ctx: Context = .{};
    var worker = Worker(void).init(std.testing.io, &ctx, Context.run, .{
        .report_nonlinear = true,
    });
    defer worker.deinit();
    ctx.callback = worker.callback();
    const outcome = try worker.advance();
    try std.testing.expect(outcome == .progress);
    try std.testing.expectEqual(progress.Phase.nonlinear, outcome.progress.phase);
    try std.testing.expect((try worker.advance()) == .complete);
}

test "timed worker excludes paused time when cancelled" {
    const Context = struct {
        callback: progress.Callback = undefined,
        fn run(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.callback.checkpoint(.{
                .phase = .transient,
                .completed = 1,
                .simulation_time = 1e-6,
                .step_size = 1e-6,
                .next_step = 2e-6,
                .accepted = 1,
            });
        }
    };
    var ctx: Context = .{};
    var worker = Worker(void).init(std.testing.io, &ctx, Context.run, .{ .timing_query = @enumFromInt(0) });
    defer worker.deinit();
    ctx.callback = worker.callback();
    const outcome = try worker.advance();
    try std.testing.expectEqual(@as(f64, 2e-6), outcome.progress.next_step.?);
    try std.testing.expectEqual(null, worker.timed_from);
    const active = worker.active_ns;
    worker.cancel();
    try std.testing.expect((try worker.wait()) == .cancelled);
    try std.testing.expectEqual(active, worker.active_ns);
}
