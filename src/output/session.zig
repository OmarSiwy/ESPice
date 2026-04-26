//! Ordered, idempotent delivery of whole plots to one output selection. The
//! caller numbers plots with consecutive ordinals, independent of query ids,
//! and keeps each result alive until `publish` acknowledges it.
//! ponytail: whole plots only; add chunked delivery when a writer can frame it.
const std = @import("std");
const types = @import("types.zig");
const dispatch = @import("write.zig");

/// One output destination and the count of plots delivered to it.
pub const Session = struct {
    allocator: std.mem.Allocator,
    selection: types.Selection,
    /// Plots delivered so far, which is also the next expected ordinal.
    /// At most maxInt(u32) plots, numbered 0 through maxInt(u32) - 1.
    published: u32 = 0,
    /// `failed` after a writer error; every later call reports it.
    state: enum(u8) { ready, failed } = .ready,

    /// Copies `selection.path`; performs no I/O.
    pub fn init(allocator: std.mem.Allocator, selection: types.Selection) !Session {
        return .{
            .allocator = allocator,
            .selection = .{
                .format = selection.format,
                .path = if (selection.path) |path| try allocator.dupe(u8, path) else null,
            },
        };
    }

    pub fn deinit(self: *Session) void {
        if (self.selection.path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    /// Writes plot `ordinal`. Ordinal 0 writes `path`; later ones append to it
    /// for binary raw and go to `path.<ordinal + 1>` for every other format.
    /// An already acknowledged ordinal is a no-op. A gap (`OutOfOrder`) or an
    /// invalid plot fails before any I/O. A writer error is terminal
    /// (`DeliveryFailed` from then on): a partial append cannot be replayed.
    pub fn publish(self: *Session, io: std.Io, ordinal: u32, plot: types.Plot) !void {
        if (self.state == .failed) return error.DeliveryFailed;
        if (ordinal < self.published) return;
        if (ordinal != self.published) return error.OutOfOrder;
        if (self.published == std.math.maxInt(u32)) return error.TooManyPlots;
        try types.validatePlot(self.selection.format, plot);

        if (self.selection.path) |path| {
            const numbered = if (ordinal != 0 and self.selection.format != .binary)
                try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ path, ordinal + 1 })
            else
                null;
            defer if (numbered) |p| self.allocator.free(p);
            const written = if (self.selection.format == .binary and ordinal != 0)
                dispatch.append(io, path, plot)
            else
                dispatch.write(io, numbered orelse path, self.selection.format, plot);
            written catch |err| {
                self.state = .failed;
                return err;
            };
        }
        self.published += 1;
    }

    /// Reports whether delivery has failed. Does not seal the session: every
    /// `publish` already closed its file, and queries appended later may
    /// publish more plots.
    pub fn finish(self: Session) error{DeliveryFailed}!void {
        if (self.state == .failed) return error.DeliveryFailed;
    }
};

test "session: finish and repeated publication preserve binary append order" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/plots.raw", .{tmp.sub_path});
    defer a.free(path);
    var session = try Session.init(a, .{ .path = path });
    defer session.deinit();
    const first: types.Plot = .{
        .title = "session",
        .result = .{
            .plotname = "first",
            .varnames = &.{"v(out)"},
            .is_complex = false,
            .npoints = 1,
            .data = &.{1},
        },
    };
    try session.publish(io, 0, first);
    try session.finish();
    const initial = try tmp.dir.readFileAlloc(io, "plots.raw", a, .unlimited);
    defer a.free(initial);
    try session.publish(io, 0, first);
    var second = first;
    second.result.plotname = "second";
    try session.publish(io, 1, second);
    try session.finish();
    const complete = try tmp.dir.readFileAlloc(io, "plots.raw", a, .unlimited);
    defer a.free(complete);
    try std.testing.expect(std.mem.startsWith(u8, complete, initial));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, complete, "Title: session\n"));
    try std.testing.expect(std.mem.indexOf(u8, complete[initial.len..], "Plotname: second\n") != null);
}

test "session: owned destination, numbered files and order validation" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/plots.csv", .{tmp.sub_path});
    defer a.free(path);
    var session = try Session.init(a, .{ .format = .csv, .path = path });
    defer session.deinit();
    @memset(path, 'x');
    const plot: types.Plot = .{
        .title = "csv",
        .result = .{
            .plotname = "op",
            .varnames = &.{"v(out)"},
            .is_complex = false,
            .npoints = 1,
            .data = &.{1},
        },
    };
    try std.testing.expectError(error.OutOfOrder, session.publish(io, 1, plot));
    try session.publish(io, 0, plot);
    try session.finish();
    try session.publish(io, 1, plot);
    try session.finish();
    const first = try tmp.dir.readFileAlloc(io, "plots.csv", a, .unlimited);
    defer a.free(first);
    const second = try tmp.dir.readFileAlloc(io, "plots.csv.2", a, .unlimited);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "session: validation preserves destination and permits a corrected publication" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/plot.s1p", .{tmp.sub_path});
    defer a.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "plot.s1p", .data = "existing" });
    var session = try Session.init(a, .{ .format = .touchstone, .path = path });
    defer session.deinit();
    var plot: types.Plot = .{
        .title = "s1p",
        .result = .{
            .plotname = "sp",
            .varnames = &.{ "frequency", "S(2,2)" },
            .is_complex = true,
            .npoints = 1,
            .data = &.{ 1e9, 0, 1, 0 },
        },
    };
    try std.testing.expectError(error.NotSParameterData, session.publish(io, 0, plot));
    const old = try tmp.dir.readFileAlloc(io, "plot.s1p", a, .unlimited);
    defer a.free(old);
    try std.testing.expectEqualStrings("existing", old);
    plot.result.varnames = &.{ "frequency", "S(1,1)" };
    try session.publish(io, 0, plot);
    try session.finish();
}

test "session: writer failure is terminal and does not acknowledge output" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/missing/plot.raw", .{tmp.sub_path});
    defer a.free(path);
    var session = try Session.init(a, .{ .path = path });
    defer session.deinit();
    const plot: types.Plot = .{
        .title = "bad path",
        .result = .{
            .plotname = "op",
            .varnames = &.{"v(out)"},
            .is_complex = false,
            .npoints = 1,
            .data = &.{1},
        },
    };
    try std.testing.expectError(error.FileNotFound, session.publish(io, 0, plot));
    try std.testing.expectEqual(@as(u32, 0), session.published);
    try std.testing.expectError(error.DeliveryFailed, session.publish(io, 0, plot));
    try std.testing.expectError(error.DeliveryFailed, session.finish());
}
