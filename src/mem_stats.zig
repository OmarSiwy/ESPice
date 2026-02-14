//! `ZP_MEM_STATS=1` — where the bytes went, by phase and by device batch.
//!
//! Neither of the usual tools can see this program. massif hooks malloc, and
//! every large allocation here goes through an arena over `smp_allocator`,
//! which mmaps; and Release builds ship no symbols, because
//! `-Ddebug-info=true` SEGVs the Zig 0.16 compiler (docs/perf/
//! remaining-2026-09-10.md). So the accounting lives in the code, on the same
//! one-shot-`getenv` rule as `ZP_LU_STATS` / `ZP_TRAN_STATS` / `ZP_OPDBG`:
//! `enabled()` is read once, and when it is false `track()` hands the child
//! allocator straight back, so an unset environment costs nothing per
//! allocation and one predictable branch per phase boundary.
//!
//! Reading the table:
//!
//!   req   bytes ASKED FOR under this label, cumulative, never decremented.
//!         On an arena this is the honest footprint: `ArenaAllocator.free`
//!         and shrink-`resize` are silent no-ops for anything but the most
//!         recent allocation, so every abandoned ArrayList capacity is still
//!         resident. `req` is what RSS actually paid.
//!   live  req minus what was handed back. Meaningful for `smp_allocator`
//!         and misleadingly small for an arena — see above.
//!   peak  high-water mark of `live`.
//!   n     the count the caller says this row scales with (instances, nodes,
//!         frequency points), so `req/n` is comparable across deck sizes.
//!
//! ponytail: one tracked child allocator and a single global current label —
//! both arenas share `init.gpa`, and setup is single-threaded. A second
//! tracked allocator, or a label pushed from a worker thread, needs a
//! per-instance context and an atomic label; neither is needed yet.

const std = @import("std");
const builtin = @import("builtin");

/// Rows are interned by name; 64 covers every phase plus one per device type
/// a deck can instantiate. Overflow lands in row 0 rather than truncating the
/// report silently.
const cap = 64;

var names: [cap][]const u8 = blk: {
    var a: [cap][]const u8 = @splat("");
    a[0] = "(unlabelled)";
    break :blk a;
};
var req: [cap]u64 = @splat(0);
var live: [cap]i64 = @splat(0);
var peak: [cap]i64 = @splat(0);
var scale: [cap]u64 = @splat(0);
var n_rows: u32 = 1;
var cur: u32 = 0;

var on_cache: ?bool = null;

/// Read once: `getenv` is a linear scan of `environ`, and this is asked on
/// every phase boundary.
pub fn enabled() bool {
    if (on_cache) |v| return v;
    const v = if (comptime builtin.link_libc) std.c.getenv("ZP_MEM_STATS") != null else false;
    on_cache = v;
    return v;
}

/// Intern a label. The pointer test first: every caller passes either a
/// string literal or `@typeName(D)`, both of which have one stable address —
/// the same identity trick `Builder.protoStore` uses to find a proto.
pub fn row(name: []const u8) u32 {
    for (names[0..n_rows], 0..) |n, i| {
        if (n.ptr == name.ptr or std.mem.eql(u8, n, name)) return @intCast(i);
    }
    if (n_rows == cap) return 0;
    const id = n_rows;
    names[id] = name;
    n_rows += 1;
    return id;
}

/// Attribute every allocation until the matching `leave` to `name`. Returns
/// the label that was current, which is what `leave` takes: labels nest, so a
/// device batch inside circuit setup restores "setup" rather than row 0.
pub fn enter(name: []const u8) u32 {
    if (!enabled()) return 0;
    const prev = cur;
    cur = row(name);
    return prev;
}

pub fn leave(prev: u32) void {
    if (!enabled()) return;
    cur = prev;
}

/// The element count this row is proportional to. `req/n` is the number that
/// travels between deck sizes; the raw byte total is not.
pub fn scaleBy(name: []const u8, n: u64) void {
    if (!enabled()) return;
    scale[row(name)] = n;
}

/// Record bytes this module cannot see through an allocator — a mapping, a
/// GPU buffer, a slice handed over from another owner.
pub fn note(name: []const u8, bytes: u64) void {
    if (!enabled()) return;
    const id = row(name);
    req[id] += bytes;
    live[id] += @intCast(bytes);
    peak[id] = @max(peak[id], live[id]);
}

// ---------------------------------------------------------------------------
// The tracking allocator
// ---------------------------------------------------------------------------

/// Wrapped children live here rather than on the caller's stack: the returned
/// `Allocator` carries `&children[i]` as its context, so it stays valid for
/// the whole process. Four covers the parse arena, the sim arena, the results
/// arena and one spare.
var children: [4]std.mem.Allocator = undefined;
var n_children: u32 = 0;

const vtable: std.mem.Allocator.VTable = .{
    .alloc = allocFn,
    .resize = resizeFn,
    .remap = remapFn,
    .free = freeFn,
};

/// Identity when the environment variable is unset — the one branch that
/// keeps this off the hot path entirely.
pub fn track(c: std.mem.Allocator) std.mem.Allocator {
    if (!enabled() or n_children == children.len) return c;
    const i = n_children;
    children[i] = c;
    n_children += 1;
    return .{ .ptr = @ptrCast(&children[i]), .vtable = &vtable };
}

fn add(id: u32, delta: i64) void {
    if (delta > 0) req[id] += @intCast(delta);
    live[id] += delta;
    peak[id] = @max(peak[id], live[id]);
}

fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const c: *std.mem.Allocator = @ptrCast(@alignCast(ctx));
    const p = c.rawAlloc(len, alignment, ra) orelse return null;
    add(cur, @intCast(len));
    return p;
}

fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    const c: *std.mem.Allocator = @ptrCast(@alignCast(ctx));
    if (!c.rawResize(memory, alignment, new_len, ra)) return false;
    add(cur, @as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len)));
    return true;
}

fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const c: *std.mem.Allocator = @ptrCast(@alignCast(ctx));
    const p = c.rawRemap(memory, alignment, new_len, ra) orelse return null;
    add(cur, @as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len)));
    return p;
}

fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const c: *std.mem.Allocator = @ptrCast(@alignCast(ctx));
    c.rawFree(memory, alignment, ra);
    live[cur] -= @intCast(memory.len);
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

/// Peak resident set, from /proc/self/status. Anchors the table to the number
/// the benchmark runner reports; a table that does not add up to VmHWM is
/// missing a row, not proving one.
fn vmHwmKb() u64 {
    if (comptime !builtin.link_libc) return 0;
    var buf: [4096]u8 = undefined;
    // libc directly: `enabled()` already requires it, and 0.16's `std.fs`
    // needs an `std.Io` this module has no business holding.
    const fd = std.c.open("/proc/self/status", .{ .ACCMODE = .RDONLY });
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const got = std.c.read(fd, &buf, buf.len);
    if (got <= 0) return 0;
    const n: usize = @intCast(got);
    var it = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VmHWM:")) continue;
        // Tab AND space: /proc/self/status separates the key from the value
        // with a tab and pads the value with spaces.
        var f_it = std.mem.tokenizeAny(u8, line[6..], " \t");
        const num = f_it.next() orelse return 0;
        return std.fmt.parseInt(u64, num, 10) catch 0;
    }
    return 0;
}

pub fn report() void {
    if (!enabled()) return;
    std.debug.print(
        "[mem] {s: <28}{s: >12}{s: >12}{s: >12}{s: >12}{s: >10}\n",
        .{ "label", "req MB", "live MB", "peak MB", "n", "req B/n" },
    );
    var total_req: u64 = 0;
    for (0..n_rows) |i| {
        total_req += req[i];
        if (req[i] == 0) continue;
        const per: f64 = if (scale[i] != 0)
            @as(f64, @floatFromInt(req[i])) / @as(f64, @floatFromInt(scale[i]))
        else
            0;
        std.debug.print("[mem] {s: <28}{d: >12.2}{d: >12.2}{d: >12.2}{d: >12}{d: >10.0}\n", .{
            names[i],
            mb(@intCast(req[i])),
            mb(live[i]),
            mb(peak[i]),
            scale[i],
            per,
        });
    }
    std.debug.print("[mem] {s: <28}{d: >12.2}{s: >12}{s: >12}   VmHWM {d:.2} MB\n", .{
        "TOTAL tracked",
        mb(@intCast(total_req)),
        "",
        "",
        @as(f64, @floatFromInt(vmHwmKb())) / 1024.0,
    });
}

fn mb(bytes: i64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

test "labels intern once and account to the current row" {
    // Force the gate on without touching the environment; `enabled()` caches
    // and the rest of the suite must not start counting.
    on_cache = true;
    defer {
        on_cache = null;
        n_rows = 1;
        cur = 0;
        n_children = 0;
        req = @splat(0);
        live = @splat(0);
        peak = @splat(0);
        scale = @splat(0);
    }

    const a = track(std.testing.allocator);
    const prev = enter("A");
    const p = try a.alloc(u8, 1000);
    const q = enter("B");
    const r = try a.alloc(u8, 3000);
    leave(q);
    a.free(p);
    leave(prev);
    a.free(r);

    try std.testing.expectEqual(@as(u32, 3), n_rows); // (unlabelled), A, B
    try std.testing.expectEqual(@as(u64, 1000), req[row("A")]);
    try std.testing.expectEqual(@as(u64, 3000), req[row("B")]);
    try std.testing.expectEqual(@as(i64, 1000), peak[row("A")]);
    // Freed under "A" after `leave(q)`, so A nets to zero and B keeps its 3000
    // until the free that lands back in row 0. That skew is the documented
    // ceiling of a single global label.
    try std.testing.expectEqual(@as(i64, 0), live[row("A")]);
}
