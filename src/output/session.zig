//! Delivery of plots to one output selection, in publish order. The caller
//! keeps each result alive until `publish` returns, or streams a binary raw
//! plot's rows as they are computed (`beginStream`). Plots that share one
//! file (binary and ASCII raw, `.print`) are appended to one replacement,
//! each written once, and `finish` renames it over the destination (#179).
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const types = @import("types.zig");
const dispatch = @import("write.zig");

/// One output destination and the count of plots delivered to it.
pub const Session = struct {
    /// Owns `selection.path` and the open `stream`.
    allocator: std.mem.Allocator,
    /// Fixed at `init`; the path is the session's own copy.
    selection: types.Selection,
    /// Plots delivered so far; the next one is plot number `published`.
    /// At most maxInt(u32) plots, numbered 0 through maxInt(u32) - 1.
    published: u32 = 0,
    /// `failed` after a writer error; every later call reports it.
    state: enum(u8) { ready, failed } = .ready,
    /// The plot `beginStream` opened, until `endStream` or `abortStream`.
    stream: ?*Stream = null,
    /// The replacement of a file that holds several plots, from the first
    /// plot published since the last `finish` until the next one, which
    /// renames it over the destination; until then the destination keeps its
    /// old bytes. A batch after a `finish` starts with a copy of the file.
    pending: ?*Stream = null,

    /// Plot 0 in binary raw, written while its query runs: the header with
    /// the point count left blank, then rows as they arrive; `endStream`
    /// keeps it as `pending`. Without a path the rows are counted and
    /// dropped. A `pending` replacement opened by `publish` uses only
    /// `atomic`, `file` and `buffer`.
    const Stream = struct {
        atomic: ?Io.File.Atomic,
        file: Io.File.Writer,
        discard: Io.Writer.Discarding,
        /// File offsets of the blank point count and of the first row.
        count_at: u64,
        rows_at: u64,
        complex: bool,
        buffer: [64 * 1024]u8,

        fn writer(s: *Stream) *Io.Writer {
            return if (s.atomic != null) &s.file.interface else &s.discard.writer;
        }
    };

    /// Copies `selection.path`; performs no I/O. Free with `deinit`.
    pub fn init(allocator: std.mem.Allocator, selection: types.Selection) !Session {
        return .{
            .allocator = allocator,
            .selection = .{
                .format = selection.format,
                .path = if (selection.path) |path| try allocator.dupe(u8, path) else null,
            },
        };
    }

    /// Drops an open stream and any plots not yet `finish`ed, leaving the
    /// destination as it was, and frees the path copy.
    pub fn deinit(self: *Session) void {
        self.abortStream();
        if (self.pending) |s| self.drop(s);
        if (self.selection.path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    /// Writes the next plot. For binary and ASCII raw and `.print`
    /// listings every plot goes into one file, `path`, which `finish`
    /// replaces; for every other format plot 0 replaces `path` and later
    /// ones `path.<number + 1>`, each at once. Without a path the plot is
    /// only counted. An invalid plot (`types.ValidationError`) fails
    /// before any I/O and is not counted; so does `error.TooManyPlots`
    /// past maxInt(u32) - 1 plots. A writer error is terminal
    /// (`DeliveryFailed` from then on): a partial append cannot be replayed.
    pub fn publish(self: *Session, io: std.Io, plot: types.Plot) !void {
        if (self.state == .failed) return error.DeliveryFailed;
        if (self.published == std.math.maxInt(u32)) return error.TooManyPlots;
        try types.validatePlot(self.selection.format, plot);
        if (self.selection.path) |path| self.deliver(io, path, plot) catch |err| {
            self.state = .failed;
            return err;
        };
        self.published += 1;
    }

    fn deliver(self: *Session, io: Io, path: []const u8, plot: types.Plot) !void {
        const format = self.selection.format;
        const ordinal = self.published;
        if (!dispatch.concatenates(format)) {
            if (ordinal == 0) return dispatch.write(io, path, format, plot);
            const numbered = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ path, ordinal + 1 });
            defer self.allocator.free(numbered);
            return dispatch.write(io, numbered, format, plot);
        }
        // A device or FIFO cannot be renamed over: it takes each plot as it comes.
        const s = self.pending orelse try self.open(io, path, ordinal != 0) orelse
            return dispatch.write(io, path, format, plot);
        self.pending = s;
        try dispatch.encode(&s.file.interface, format, plot);
    }

    /// A replacement for the file at `path`, holding the file's bytes when
    /// `keep`; null when `path` is a device or FIFO.
    fn open(self: *Session, io: Io, path: []const u8, keep: bool) !?*Stream {
        if (Io.Dir.cwd().statFile(io, path, .{})) |stat| {
            if (stat.kind != .file) return null;
        } else |_| {}
        const s = try self.allocator.create(Stream);
        errdefer self.allocator.destroy(s);
        s.discard = .init(&.{});
        s.count_at = 0;
        s.rows_at = 0;
        s.complex = false;
        s.atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
        errdefer s.atomic.?.deinit(io);
        s.file = s.atomic.?.file.writer(io, &s.buffer);
        if (keep) copy: {
            const old = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :copy,
                else => return err, // else: any other open failure is the caller's
            };
            defer old.close(io);
            var rbuf: [8192]u8 = undefined;
            var reader = old.reader(io, &rbuf);
            _ = try reader.interface.streamRemaining(&s.file.interface);
        }
        return s;
    }

    /// Closes `s` and deletes its replacement, if any, leaving the
    /// destination as it was.
    fn drop(self: *Session, s: *Stream) void {
        if (s.atomic) |*atomic| atomic.deinit(s.file.io);
        self.allocator.destroy(s);
    }

    /// Opens plot 0 in binary raw for rows the caller writes to the returned
    /// writer as native-endian f64s, `plot.result.data` being empty. Null when
    /// the selection cannot stream (another format, a plot already
    /// delivered, a failed session, a destination that is not a regular
    /// file); publish the whole plot then. The header leaves `No. Points:` blank, as ngspice's
    /// batch raw file does, for `endStream` to fill in. The writer is valid
    /// until `endStream`, `abortStream` or `deinit`.
    pub fn beginStream(self: *Session, io: Io, plot: types.Plot) !?*Io.Writer {
        if (self.selection.format != .binary or self.published != 0 or self.state == .failed) return null;
        assert(self.pending == null);
        try types.validatePlot(.binary, plot);
        const path = self.selection.path orelse {
            const s = try self.allocator.create(Stream);
            s.discard = .init(&.{});
            s.atomic = null;
            s.count_at = 0;
            s.rows_at = 0;
            s.complex = plot.result.is_complex;
            self.stream = s;
            return s.writer();
        };
        const s = try self.open(io, path, false) orelse return null;
        errdefer self.drop(s);
        s.complex = plot.result.is_complex;
        var header: Io.Writer.Allocating = .init(self.allocator);
        defer header.deinit();
        try @import("rawfile.zig").writeHeader(&header.writer, plot, true);
        const field = "No. Points: 0\n";
        const at = std.mem.indexOf(u8, header.written(), field).? + field.len - 2;
        const w = &s.file.interface;
        try w.writeAll(header.written()[0..at]);
        try w.splatByteAll(' ', count_width);
        try w.writeAll(header.written()[at + 1 ..]);
        s.count_at = at;
        s.rows_at = s.file.logicalPos();
        self.stream = s;
        return w;
    }

    /// Room for the point count of a streamed plot, as many digits as u64 has.
    const count_width = 20;

    /// Finishes the streamed plot: checks that `npoints` rows of
    /// `varnames` columns arrived and fills in the point count; the plots
    /// published after it append to the same replacement, which `finish`
    /// renames over the destination. Counts as one `publish`. The stream is closed whether
    /// or not it succeeds. With a path, any error (a wrong row count
    /// included, `error.DataLengthMismatch`) fails the session; without
    /// one, a wrong count is returned and the session stays usable. Asserts
    /// that a stream is open.
    pub fn endStream(self: *Session, io: Io, npoints: usize, columns: usize) !void {
        assert(self.stream != null);
        const s = self.stream.?;
        defer self.abortStream();
        const want = @as(u64, npoints) * columns * @sizeOf(f64) * @as(u64, if (s.complex) 2 else 1);
        // A pathless stream counts what it dropped (#88).
        if (s.atomic == null and s.discard.fullCount() != want) return error.DataLengthMismatch;
        if (s.atomic) |*atomic| {
            errdefer self.state = .failed;
            const w = &s.file.interface;
            try w.flush();
            if (s.file.logicalPos() - s.rows_at != want) return error.DataLengthMismatch;
            var digits: [count_width]u8 = undefined;
            try atomic.file.writePositionalAll(io, try std.fmt.bufPrint(&digits, "{d}", .{npoints}), s.count_at);
            self.stream = null;
            self.pending = s;
        }
        self.published += 1;
    }

    /// Drops the streamed plot, if any, leaving the destination as it was.
    pub fn abortStream(self: *Session) void {
        const s = self.stream orelse return;
        self.drop(s);
        self.stream = null;
    }

    /// Publishes the plots appended since the last `finish` with one rename
    /// over the destination, so a reader sees the old file or every plot.
    /// `DeliveryFailed` once delivery has failed, leaving the destination
    /// as it was; a flush or rename error fails the session the same way.
    /// Does not seal the session: queries appended later may publish more
    /// plots, and the next `finish` adds them to the file.
    pub fn finish(self: *Session, io: Io) !void {
        if (self.state == .failed) return error.DeliveryFailed;
        const s = self.pending orelse return;
        self.pending = null;
        defer self.drop(s);
        errdefer self.state = .failed;
        try s.file.interface.flush();
        try s.atomic.?.replace(io);
    }
};

test "session: finish and later publication preserve raw append order" {
    for ([_]types.Format{ .binary, .ascii }) |format| {
        const io = std.testing.io;
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/plots.raw", .{tmp.sub_path});
        defer a.free(path);
        var session = try Session.init(a, .{ .format = format, .path = path });
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
        try session.publish(io, first);
        try session.finish(io);
        const initial = try tmp.dir.readFileAlloc(io, "plots.raw", a, .unlimited);
        defer a.free(initial);
        var second = first;
        second.result.plotname = "second";
        try session.publish(io, second);
        try session.finish(io);
        const complete = try tmp.dir.readFileAlloc(io, "plots.raw", a, .unlimited);
        defer a.free(complete);
        try std.testing.expect(std.mem.startsWith(u8, complete, initial));
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, complete, "Title: session\n"));
        try std.testing.expect(std.mem.indexOf(u8, complete[initial.len..], "Plotname: second\n") != null);
    }
}

test "session: appended plots are each written once and published at finish (#179)" {
    for ([_]types.Format{ .binary, .ascii, .print }) |format| {
        const io = std.testing.io;
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/sweep.raw", .{tmp.sub_path});
        defer a.free(path);
        try tmp.dir.writeFile(io, .{ .sub_path = "sweep.raw", .data = "old" });
        // The oracle: each plot encoded alone, back to back.
        var want: Io.Writer.Allocating = .init(a);
        defer want.deinit();
        var session = try Session.init(a, .{ .format = format, .path = path });
        defer session.deinit();
        for ([_][]const u8{ "step 1", "step 2", "step 3" }, 0..) |name, k| {
            const value: [1]f64 = .{@floatFromInt(k)};
            const plot: types.Plot = .{ .title = "sweep", .result = .{
                .plotname = name,
                .varnames = &.{"v(out)"},
                .is_complex = false,
                .npoints = 1,
                .data = &value,
            } };
            try session.publish(io, plot);
            try dispatch.encode(&want.writer, format, plot);
            const during = try tmp.dir.readFileAlloc(io, "sweep.raw", a, .unlimited);
            defer a.free(during);
            try std.testing.expectEqualStrings("old", during);
        }
        try session.finish(io);
        const got = try tmp.dir.readFileAlloc(io, "sweep.raw", a, .unlimited);
        defer a.free(got);
        try std.testing.expectEqualStrings(want.written(), got);
    }
}

test "session: plots never finished leave the previous file intact (#179)" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/plots.raw", .{tmp.sub_path});
    defer a.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "plots.raw", .data = "previous run" });
    const plot: types.Plot = .{ .title = "t", .result = .{ .plotname = "op", .varnames = &.{"v(out)"}, .is_complex = false, .npoints = 1, .data = &.{1} } };
    {
        var session = try Session.init(a, .{ .path = path });
        defer session.deinit();
        try session.publish(io, plot);
        try session.publish(io, plot);
    }
    const kept = try tmp.dir.readFileAlloc(io, "plots.raw", a, .unlimited);
    defer a.free(kept);
    try std.testing.expectEqualStrings("previous run", kept);
    // A device takes each plot in place; there is nothing to rename.
    var device = try Session.init(a, .{ .path = "/dev/null" });
    defer device.deinit();
    try device.publish(io, plot);
    try device.publish(io, plot);
    try std.testing.expectEqual(null, device.pending);
    try device.finish(io);
}

test "session: owned destination and numbered files" {
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
    try session.publish(io, plot);
    try session.finish(io);
    try session.publish(io, plot);
    try session.finish(io);
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
    try std.testing.expectError(error.NotSParameterData, session.publish(io, plot));
    const old = try tmp.dir.readFileAlloc(io, "plot.s1p", a, .unlimited);
    defer a.free(old);
    try std.testing.expectEqualStrings("existing", old);
    plot.result.varnames = &.{ "frequency", "S(1,1)" };
    try session.publish(io, plot);
    try session.finish(io);
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
    try std.testing.expectError(error.FileNotFound, session.publish(io, plot));
    try std.testing.expectEqual(@as(u32, 0), session.published);
    try std.testing.expectError(error.DeliveryFailed, session.publish(io, plot));
    try std.testing.expectError(error.DeliveryFailed, session.finish(io));
}

test "session: a streamed plot matches the whole-plot encoding but for the padded count" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/stream.raw", .{tmp.sub_path});
    defer a.free(path);
    const rows = [_]f64{ 0, 1.5, 1e-9, 2.5 };
    var plot: types.Plot = .{ .title = "t", .result = .{
        .plotname = "Transient Analysis",
        .varnames = &.{ "time", "v(out)" },
        .is_complex = false,
        .npoints = 0,
        .data = &.{},
    } };
    var session = try Session.init(a, .{ .path = path });
    defer session.deinit();
    const w = (try session.beginStream(io, plot)).?;
    try w.writeAll(std.mem.sliceAsBytes(&rows));
    try std.testing.expectError(error.DataLengthMismatch, session.endStream(io, 3, 2));
    try std.testing.expectError(error.DeliveryFailed, session.publish(io, plot));

    var again = try Session.init(a, .{ .path = path });
    defer again.deinit();
    try (try again.beginStream(io, plot)).?.writeAll(std.mem.sliceAsBytes(&rows));
    try again.endStream(io, 2, 2);
    try std.testing.expectEqual(@as(u32, 1), again.published);
    try again.finish(io);
    const streamed = try tmp.dir.readFileAlloc(io, "stream.raw", a, .unlimited);
    defer a.free(streamed);
    plot.result.npoints = 2;
    plot.result.data = &rows;
    var whole: Io.Writer.Allocating = .init(a);
    defer whole.deinit();
    try @import("rawfile.zig").encode(&whole.writer, plot);
    const field = "No. Points: 2";
    const at = std.mem.indexOf(u8, streamed, field).? + field.len;
    try std.testing.expectEqualStrings(whole.written()[0..at], streamed[0..at]);
    try std.testing.expectEqualStrings(&@as([Session.count_width - 1]u8, @splat(' ')), streamed[at..][0 .. Session.count_width - 1]);
    try std.testing.expectEqualSlices(u8, whole.written()[at..], streamed[at + Session.count_width - 1 ..]);
}

test "session: without a path plots are counted, not written" {
    var session = try Session.init(std.testing.allocator, .{ .format = .csv });
    defer session.deinit();
    const plot: types.Plot = .{ .title = "t", .result = .{ .plotname = "op", .varnames = &.{"v(out)"}, .is_complex = false, .npoints = 1, .data = &.{1} } };
    try session.publish(std.testing.io, plot);
    try session.publish(std.testing.io, plot);
    try std.testing.expectEqual(@as(u32, 2), session.published);
    try std.testing.expectEqual(null, try session.beginStream(std.testing.io, plot));
    session.published = std.math.maxInt(u32);
    try std.testing.expectError(error.TooManyPlots, session.publish(std.testing.io, plot));
}

test "session: a stream without a path drops its rows and counts one plot" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    const plot: types.Plot = .{ .title = "t", .result = .{ .plotname = "Transient Analysis", .varnames = &.{ "time", "v(out)" }, .is_complex = false, .npoints = 0, .data = &.{} } };
    const w = (try session.beginStream(std.testing.io, plot)).?;
    try w.writeAll(std.mem.sliceAsBytes(&[_]f64{ 0, 1 }));
    try session.endStream(std.testing.io, 1, 2);
    try std.testing.expectEqual(@as(u32, 1), session.published);
    try std.testing.expectEqual(null, session.stream);
    try std.testing.expectEqual(null, try session.beginStream(std.testing.io, plot));
}

test "session: a stream without a path checks its row count too" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    const plot: types.Plot = .{ .title = "t", .result = .{ .plotname = "Transient Analysis", .varnames = &.{ "time", "v(out)" }, .is_complex = false, .npoints = 0, .data = &.{} } };
    const w = (try session.beginStream(std.testing.io, plot)).?;
    try w.writeAll(std.mem.sliceAsBytes(&[_]f64{ 0, 1, 2 }));
    try std.testing.expectError(error.DataLengthMismatch, session.endStream(std.testing.io, 2, 2));
    try std.testing.expectEqual(@as(u32, 0), session.published);
    try std.testing.expectEqual(null, session.stream);
}

test "session: an aborted stream leaves the destination as it was" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/plot.raw", .{tmp.sub_path});
    defer a.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "plot.raw", .data = "existing" });
    var session = try Session.init(a, .{ .path = path });
    defer session.deinit();
    const plot: types.Plot = .{ .title = "t", .result = .{ .plotname = "Transient Analysis", .varnames = &.{"time"}, .is_complex = false, .npoints = 0, .data = &.{} } };
    try (try session.beginStream(io, plot)).?.writeAll(std.mem.sliceAsBytes(&[_]f64{1}));
    session.abortStream();
    try std.testing.expectEqual(@as(u32, 0), session.published);
    const old = try tmp.dir.readFileAlloc(io, "plot.raw", a, .unlimited);
    defer a.free(old);
    try std.testing.expectEqualStrings("existing", old);
}
