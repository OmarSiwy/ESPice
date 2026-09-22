//! Cooperative worker control; independent of circuit and solver state.
const std = @import("std");
const requests = @import("requests");
const progress = @import("progress.zig");

pub const Options = struct {
    stack_size: usize = 512 * 1024 * 1024,
    /// OP can expose Newton iterations; other queries publish outer boundaries.
    report_nonlinear: bool = false,
    timing_query: ?requests.QueryId = null,
};

// ponytail: retain one thread stack per started query; use explicit phase
// storage if retained stacks become the limiting resource.
pub fn Worker(comptime Product: type) type {
    return struct {
        io: std.Io,
        ctx: *anyopaque,
        run: *const fn (*anyopaque) anyerror!Product,
        options: Options,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        thread: ?std.Thread = null,
        state: State = .created,
        cancel_requested: std.atomic.Value(bool) = .init(false),
        timed_from: ?std.Io.Timestamp = null,
        active_ns: i96 = 0,

        const Self = @This();
        const State = union(enum(u8)) {
            created,
            running,
            paused: progress.Event,
            finished: anyerror!Product,
        };

        pub const Outcome = union(enum(u8)) {
            progress: progress.Event,
            complete: Product,
            failed: anyerror,
            cancelled,
        };

        pub fn init(io: std.Io, ctx: *anyopaque, execute_fn: *const fn (*anyopaque) anyerror!Product, options: Options) Self {
            return .{ .io = io, .ctx = ctx, .run = execute_fn, .options = options };
        }

        pub fn callback(self: *Self) progress.Callback {
            return .{ .ctx = self, .yield_fn = checkpoint };
        }

        /// Start one quantum without waiting, so the coordinator can start a batch.
        /// A failed thread spawn leaves the query unstarted and retryable.
        pub fn start(self: *Self) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            switch (self.state) {
                .created => {
                    self.state = .running;
                    self.thread = std.Thread.spawn(.{ .stack_size = self.options.stack_size }, main, .{self}) catch |err| {
                        self.state = .created;
                        return err;
                    };
                },
                .paused => {
                    self.state = .running;
                    self.changed.broadcast(self.io);
                },
                .running => return error.AlreadyRunning,
                .finished => {},
            }
        }

        /// Wait for the quantum started by start(), or read an existing terminal result.
        pub fn wait(self: *Self) !Outcome {
            const outcome = try self.waitOutcome();
            if (outcome != .progress) if (self.thread) |thread| {
                thread.join();
                self.thread = null;
            };
            return outcome;
        }

        fn waitOutcome(self: *Self) !Outcome {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (true) switch (self.state) {
                .created => return error.NotStarted,
                .running => self.changed.waitUncancelable(self.io, &self.mutex),
                .paused => |event| {
                    if (self.cancel_requested.load(.monotonic)) {
                        self.changed.waitUncancelable(self.io, &self.mutex);
                    } else return .{ .progress = event };
                },
                .finished => |result| {
                    const value = result catch |err| return if (err == error.QueryCancelled)
                        .cancelled
                    else
                        .{ .failed = err };
                    return .{ .complete = value };
                },
            };
        }

        pub fn advance(self: *Self) !Outcome {
            try self.start();
            return self.wait();
        }

        /// Request cancellation. A running query observes it at its next checkpoint.
        pub fn cancel(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.state == .finished) return;
            self.cancel_requested.store(true, .monotonic);
            if (self.state == .created) self.state = .{ .finished = error.QueryCancelled };
            self.changed.broadcast(self.io);
        }

        /// Joins before releasing the controller; run's defers finish before return.
        pub fn deinit(self: *Self) void {
            self.cancel();
            if (self.thread) |thread| thread.join();
        }

        fn checkpoint(ctx: *anyopaque, event: progress.Event) error{QueryCancelled}!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Suppressed inner iterations only poll cancellation; scheduler
            // state is touched at the outer query boundary under the mutex.
            if (event.phase == .nonlinear and !self.options.report_nonlinear) {
                if (self.cancel_requested.load(.monotonic)) return error.QueryCancelled;
                return;
            }
            if (self.options.timing_query) |id| {
                const elapsed = self.timeQuantum();
                if (event.simulation_time) |t| {
                    std.debug.print("timing: query {d} {s} attempt={d} accepted={?d} t={e:.6}s dt={?e:.6}s next_dt={?e:.6}s: {d:.6}ms\n", .{
                        @intFromEnum(id), @tagName(event.phase), event.completed, event.accepted, t, event.step_size, event.next_step, milliseconds(elapsed),
                    });
                } else {
                    std.debug.print("timing: query {d} {s} checkpoint={d}/{d}: {d:.6}ms\n", .{
                        @intFromEnum(id), @tagName(event.phase), event.completed, event.total, milliseconds(elapsed),
                    });
                }
            }
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.cancel_requested.load(.monotonic)) return error.QueryCancelled;

            self.state = .{ .paused = event };
            self.changed.broadcast(self.io);
            while (self.state == .paused and !self.cancel_requested.load(.monotonic))
                self.changed.waitUncancelable(self.io, &self.mutex);
            if (self.cancel_requested.load(.monotonic)) return error.QueryCancelled;
            if (self.options.timing_query != null) self.timed_from = std.Io.Timestamp.now(self.io, .awake);
        }

        fn timeQuantum(self: *Self) i96 {
            const before = self.timed_from orelse return 0;
            const elapsed = before.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds;
            self.timed_from = null;
            self.active_ns += elapsed;
            return elapsed;
        }

        fn main(self: *Self) void {
            if (self.options.timing_query != null) self.timed_from = std.Io.Timestamp.now(self.io, .awake);
            const result = self.run(self.ctx);
            if (self.options.timing_query) |id| {
                const tail = self.timeQuantum();
                const status = if (result) |_| "complete" else |err| @errorName(err);
                std.debug.print("timing: query {d} {s}: final={d:.6}ms active_total={d:.6}ms\n", .{
                    @intFromEnum(id), status, milliseconds(tail), milliseconds(self.active_ns),
                });
            }
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.state = .{ .finished = if (self.cancel_requested.load(.monotonic)) error.QueryCancelled else result };
            self.changed.broadcast(self.io);
        }
    };
}

fn milliseconds(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
