//! Shared backend for both pipelines (`v/` Verilog, `va/` Verilog-A).
//!
//! Both backends emit Zig source that targets the same `contract` ABI, so
//! everything contract-shaped lives here exactly once: identifier legality,
//! the full dyn ABI v3 export block, and the validate footer. The pipelines
//! differ only in how they produce physics/logic — never in the ABI surface.
//!
//! Also home of `Buf(T)`: the project-wide growable pool. Structs in this
//! codebase carry no std.ArrayList — flat SoA (`std.MultiArrayList`), fixed
//! caps derived from contract limits, or a Buf.

const std = @import("std");

// ============================================================================
// Buf(T): grow-by-doubling pool. 16 bytes of header (ptr + u32 len + u32 cap)
// vs ArrayList's 24; u32 lengths because nothing here exceeds 4Gi elements.
// ============================================================================

pub fn Buf(comptime T: type) type {
    return struct {
        ptr: [*]T = undefined,
        len: u32 = 0,
        cap: u32 = 0,

        const Self = @This();

        pub const empty: Self = .{};

        pub fn slice(self: Self) []T {
            return self.ptr[0..self.len];
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            if (self.cap != 0) gpa.free(self.ptr[0..self.cap]);
            self.* = .{};
        }

        pub fn ensureTotalCapacity(self: *Self, gpa: std.mem.Allocator, want: usize) !void {
            if (want <= self.cap) return;
            var new_cap: u32 = if (self.cap == 0) 16 else self.cap;
            while (new_cap < want) new_cap *|= 2;
            const new = if (self.cap != 0)
                try gpa.realloc(self.ptr[0..self.cap], new_cap)
            else
                try gpa.alloc(T, new_cap);
            self.ptr = new.ptr;
            self.cap = new_cap;
        }

        pub fn append(self: *Self, gpa: std.mem.Allocator, item: T) !void {
            try self.ensureTotalCapacity(gpa, self.len + 1);
            self.ptr[self.len] = item;
            self.len += 1;
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            self.ptr[self.len] = item;
            self.len += 1;
        }

        pub fn appendSlice(self: *Self, gpa: std.mem.Allocator, items: []const T) !void {
            try self.ensureTotalCapacity(gpa, self.len + items.len);
            @memcpy(self.ptr[self.len..][0..items.len], items);
            self.len += @intCast(items.len);
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.ptr[self.len];
        }

        /// Shrink to exact size and hand the memory to the caller.
        pub fn toOwnedSlice(self: *Self, gpa: std.mem.Allocator) ![]T {
            if (self.cap == 0) return &.{};
            const out = try gpa.realloc(self.ptr[0..self.cap], self.len);
            self.* = .{};
            return out;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }
    };
}

// ============================================================================
// Identifier legality
// ============================================================================

pub const Error = error{InvalidName} || std.Io.Writer.Error;

pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Universal Zig identifier legality: non-empty, ident chars only, no leading
/// digit, and not a Zig keyword or primitive type. This is the part shared by
/// both pipelines — the per-pipeline set of self-declared names (which would
/// *shadow* rather than fail to parse) is checked separately by each backend,
/// since those namespaces differ (digital pins vs analog nodes/params).
pub fn validateIdent(name: []const u8) Error!void {
    if (name.len == 0) return Error.InvalidName;
    for (name, 0..) |c, idx| {
        if (!isIdentChar(c)) return Error.InvalidName;
        if (idx == 0 and std.ascii.isDigit(c)) return Error.InvalidName;
    }
    if (std.zig.Token.keywords.has(name)) return Error.InvalidName;
    if (std.zig.primitives.isPrimitive(name)) return Error.InvalidName;
}

/// Write `name` as a Zig identifier, escaping with `@"..."` when it is not a
/// plain-legal identifier (keyword, primitive, or leading digit). Source-derived
/// names (Verilog-A params/nodes like `type`) go through this so the emitted Zig
/// is always valid.
pub fn writeIdent(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    if (validateIdent(name)) {
        try w.writeAll(name);
    } else |_| {
        try w.print("@\"{s}\"", .{name});
    }
}

// ============================================================================
// Dyn ABI v3 — the single definition both generated-device shapes share.
// All Model/Instance/State access is byte-copy: the engine's buffers carry
// no alignment guarantee, so pointer casts are never emitted.
// ============================================================================

pub const AbiOptions = struct {
    /// Device has a charge function: also export zpicey_q_ad.
    has_q: bool = false,
    /// Device has a digital state machine: export state size/init/update.
    has_state: bool = false,
    /// Extra statements inserted in zpicey_init_state between initState and
    /// the write-back (e.g. pushing initial logic outputs into drive targets).
    /// Sees `m: Model`, `inst: Instance` (mutable) and `s: State` (mutable).
    state_init_extra: []const u8 = "",
};

pub fn emitDynAbi(w: *std.Io.Writer, opts: AbiOptions) std.Io.Writer.Error!void {
    try w.writeAll(
        \\
        \\// ============================================================================
        \\// Dyn ABI v3 (see analysis/compiled.zig DynDevice). Byte-copy access only:
        \\// the engine's buffers carry no alignment guarantee.
        \\// ============================================================================
        \\
        \\export fn zpicey_abi_version() u32 {
        \\    return 3;
        \\}
        \\
        \\export fn zpicey_n_u() usize {
        \\    return n_u;
        \\}
        \\
        \\export fn zpicey_num_ports() usize {
        \\    return num_ports;
        \\}
        \\
        \\export fn zpicey_model_size() usize {
        \\    return @sizeOf(Model);
        \\}
        \\
        \\export fn zpicey_instance_size() usize {
        \\    return @sizeOf(Instance);
        \\}
        \\
        \\export fn zpicey_init_model(p: [*]u8) void {
        \\    const m = Model{};
        \\    @memcpy(p[0..@sizeOf(Model)], std.mem.asBytes(&m));
        \\}
        \\
        \\export fn zpicey_init_instance(p: [*]u8) void {
        \\    const inst = Instance{};
        \\    @memcpy(p[0..@sizeOf(Instance)], std.mem.asBytes(&inst));
        \\}
        \\
        \\/// By-name scalar param write (float/int/bool fields; arrays and strings
        \\/// are not deck-settable). Byte-copy in and out.
        \\fn setParam(comptime T: type, p: [*]u8, name_ptr: [*]const u8, name_len: usize, value: f64) bool {
        \\    if (@typeInfo(T).@"struct".fields.len == 0) return false;
        \\    const name = name_ptr[0..name_len];
        \\    var val = std.mem.bytesToValue(T, p[0..@sizeOf(T)]);
        \\    inline for (@typeInfo(T).@"struct".fields) |f| {
        \\        if (std.mem.eql(u8, f.name, name)) {
        \\            switch (@typeInfo(f.type)) {
        \\                .float => @field(val, f.name) = @floatCast(value),
        \\                .int => @field(val, f.name) = @intFromFloat(value),
        \\                .bool => @field(val, f.name) = value != 0.0,
        \\                else => return false,
        \\            }
        \\            @memcpy(p[0..@sizeOf(T)], std.mem.asBytes(&val));
        \\            return true;
        \\        }
        \\    }
        \\    return false;
        \\}
        \\
        \\export fn zpicey_set_model_param(p: [*]u8, name: [*]const u8, len: usize, value: f64) bool {
        \\    return setParam(Model, p, name, len, value);
        \\}
        \\
        \\export fn zpicey_set_instance_param(p: [*]u8, name: [*]const u8, len: usize, value: f64) bool {
        \\    return setParam(Instance, p, name, len, value);
        \\}
        \\
        \\/// Residual + analytic Jacobian in one pass via forward-mode AD.
        \\/// out_res[n_u], out_jac[n_u*n_u] row-major (out_jac[r*n_u + c] = d res[r]/d x[c]).
        \\export fn zpicey_eval_ad(x: [*]const f64, model: [*]const u8, instance: [*]const u8, t: f64, out_res: [*]f64, out_jac: [*]f64) void {
        \\    @setEvalBranchQuota(1 + n_u * n_u * 4);
        \\    const AD = contract.Dual(n_u);
        \\    const m = std.mem.bytesToValue(Model, model[0..@sizeOf(Model)]);
        \\    const inst = std.mem.bytesToValue(Instance, instance[0..@sizeOf(Instance)]);
        \\    var xs: [n_u]AD = undefined;
        \\    inline for (0..n_u) |u| xs[u] = AD.seed(x[u], u);
        \\    const o = eval(AD, xs, &m, &inst, t);
        \\    inline for (0..n_u) |r| {
        \\        out_res[r] = o[r].v;
        \\        inline for (0..n_u) |c| out_jac[r * n_u + c] = o[r].d[c];
        \\    }
        \\}
        \\
    );

    if (opts.has_q) {
        try w.writeAll(
            \\
            \\export fn zpicey_q_ad(x: [*]const f64, model: [*]const u8, instance: [*]const u8, t: f64, out_res: [*]f64, out_jac: [*]f64) void {
            \\    @setEvalBranchQuota(1 + n_u * n_u * 4);
            \\    const AD = contract.Dual(n_u);
            \\    const m = std.mem.bytesToValue(Model, model[0..@sizeOf(Model)]);
            \\    const inst = std.mem.bytesToValue(Instance, instance[0..@sizeOf(Instance)]);
            \\    var xs: [n_u]AD = undefined;
            \\    inline for (0..n_u) |u| xs[u] = AD.seed(x[u], u);
            \\    const o = q(AD, xs, &m, &inst, t);
            \\    inline for (0..n_u) |r| {
            \\        out_res[r] = o[r].v;
            \\        inline for (0..n_u) |c| out_jac[r * n_u + c] = o[r].d[c];
            \\    }
            \\}
            \\
        );
    }

    if (opts.has_state) {
        try w.writeAll(
            \\
            \\// -- Digital state machine hooks --
            \\
            \\export fn zpicey_state_size() usize {
            \\    return @sizeOf(State);
            \\}
            \\
            \\export fn zpicey_init_state(model: [*]const u8, instance: [*]u8, state: [*]u8) void {
            \\    const m = std.mem.bytesToValue(Model, model[0..@sizeOf(Model)]);
            \\    var inst = std.mem.bytesToValue(Instance, instance[0..@sizeOf(Instance)]);
            \\    var s = initState(&m, &inst);
            \\
        );
        try w.writeAll(opts.state_init_extra);
        try w.writeAll(
            \\    @memcpy(instance[0..@sizeOf(Instance)], std.mem.asBytes(&inst));
            \\    @memcpy(state[0..@sizeOf(State)], std.mem.asBytes(&s));
            \\}
            \\
            \\/// Advance the logic one step; write drive targets into instance + bookkeeping
            \\/// into state. Returns +inf for .ok, else the requested reject time.
            \\export fn zpicey_update_state(x: [*]const f64, model: [*]const u8, instance: [*]u8, state: [*]u8) f64 {
            \\    const m = std.mem.bytesToValue(Model, model[0..@sizeOf(Model)]);
            \\    var inst = std.mem.bytesToValue(Instance, instance[0..@sizeOf(Instance)]);
            \\    var s = std.mem.bytesToValue(State, state[0..@sizeOf(State)]);
            \\    var xv: [n_u]f64 = undefined;
            \\    inline for (0..n_u) |u| xv[u] = x[u];
            \\    const r = updateState(&m, &inst, xv, &s);
            \\    @memcpy(instance[0..@sizeOf(Instance)], std.mem.asBytes(&inst));
            \\    @memcpy(state[0..@sizeOf(State)], std.mem.asBytes(&s));
            \\    return switch (r) {
            \\        .ok => std.math.inf(f64),
            \\        .request_reject_at => |tr| tr,
            \\    };
            \\}
            \\
        );
    }

    try w.writeAll(
        \\
        \\comptime {
        \\    contract.validate(Self);
        \\}
        \\
    );
}

// ============================================================================
// Tests
// ============================================================================

test "validateIdent rejects keywords, primitives and bad names" {
    try std.testing.expectError(Error.InvalidName, validateIdent(""));
    try std.testing.expectError(Error.InvalidName, validateIdent("1a"));
    try std.testing.expectError(Error.InvalidName, validateIdent("a-b"));
    try std.testing.expectError(Error.InvalidName, validateIdent("var"));
    try std.testing.expectError(Error.InvalidName, validateIdent("u64"));
    // Analog names that a device may legitimately use as nodes/params.
    try validateIdent("t");
    try validateIdent("q");
    try validateIdent("clk_in");
    try validateIdent("Vth0");
}

test "Buf append/grow/toOwnedSlice" {
    const gpa = std.testing.allocator;
    var b: Buf(u32) = .empty;
    defer b.deinit(gpa);
    for (0..100) |i| try b.append(gpa, @intCast(i));
    try std.testing.expectEqual(@as(u32, 100), b.len);
    try std.testing.expectEqual(@as(u32, 42), b.slice()[42]);
    const owned = try b.toOwnedSlice(gpa);
    defer gpa.free(owned);
    try std.testing.expectEqual(@as(usize, 100), owned.len);
    try std.testing.expectEqual(@as(u32, 0), b.len);
}

test "emitDynAbi contains full export surface" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer aw.deinit();
    try emitDynAbi(&aw.writer, .{ .has_q = true, .has_state = true });
    const out = try aw.toOwnedSlice();
    defer std.testing.allocator.free(out);
    for ([_][]const u8{
        "zpicey_abi_version",   "zpicey_n_u",           "zpicey_num_ports",
        "zpicey_model_size",    "zpicey_instance_size", "zpicey_init_model",
        "zpicey_init_instance", "zpicey_set_model_param", "zpicey_set_instance_param",
        "zpicey_eval_ad",       "zpicey_q_ad",          "zpicey_state_size",
        "zpicey_init_state",    "zpicey_update_state",  "contract.validate(Self)",
        "AD.seed",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, out, needle) != null);
    }
    // Alignment-unsafe pointer casts must never appear in the ABI block.
    try std.testing.expect(std.mem.indexOf(u8, out, "@alignCast") == null);
}
