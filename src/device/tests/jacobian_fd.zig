//! Jacobian-vs-finite-difference property over every built-in model
//! (TESTING-METHODOLOGY 2.1 item 3): at random voltages each stamped G entry
//! must match a central difference of the stamped residual, and each C entry
//! one of the stamped charge. Reaches each model through its object's
//! vtable, as the builder does, so no device body compiles into this test.
const std = @import("std");
const abi = @import("device_abi");
const catalog = @import("../catalog.zig");

const points = 12;
const rtol = 1e-5;
/// Absolute floors: 1% of the default gmin, below which no Newton step moves
/// (asmhemt's 2e-12 S gate leak wanders by 2.5e-15 S with h), and 1 aF.
const g_floor = 1e-14;
const c_floor = 1e-18;
/// Models whose .va marks ngspice's Meyer-cap coefficients `vera_nodiff`:
/// their C plane is not ∂q/∂x by design, so only G is checked.
const nodiff = [_][]const u8{ "hfet1", "hfet2", "mesa", "mos1", "mos2", "mos3", "mos6", "mos9", "bsim4va" };

const Planes = struct {
    g: []f64,
    c: []f64,
    rhs: []f64,
    q: []f64,
};

/// Checks one CSC column of `jac` (stamped at x) against the Richardson
/// extrapolation of two central differences of `val`, stamped at
/// x + {h, -h, h/2, -h/2}. The two estimates' spread (truncation where the
/// model curves, rounding where its internal currents cancel) and the row
/// value's rounding widen the tolerance; at a kink inside ±h they disagree
/// and the entry is not judged. A wrong partial shows as a dual off both.
fn expectColumn(name: []const u8, col_ptr: []const u32, row_idx: []const u32, jac: []const f64, row_max: []const f64, floor: f64, val: [4][]const f64, col: usize, h: f64) !void {
    for (col_ptr[col]..col_ptr[col + 1]) |slot| {
        const r = row_idx[slot];
        const d1 = (val[0][r] - val[1][r]) / (2 * h);
        const d2 = (val[2][r] - val[3][r]) / h;
        const fd = (4 * d2 - d1) / 3;
        const ulps = 16 * std.math.floatEps(f64) * @max(@abs(val[0][r]), @abs(val[1][r])) / h;
        // A partial 1e-9 below its row's largest moves no Newton step.
        const tol = rtol * @max(@abs(jac[slot]), @abs(fd)) + @abs(d1 - d2) + ulps + 1e-9 * row_max[r] + floor;
        if (!(@abs(jac[slot] - fd) <= tol)) {
            std.debug.print("{s}: [{d}][{d}] dual {e} fd {e} (h {e}, h/2 {e})\n", .{ name, r, col, jac[slot], fd, d1, d2 });
            return error.JacobianMismatch;
        }
    }
}

fn checkModel(gpa: std.mem.Allocator, name: []const u8, vt: *const abi.DeviceVtable, rand: std.Random) !void {
    const mblob = try gpa.alignedAlloc(u8, .@"16", vt.model_size);
    const iblob = try gpa.alignedAlloc(u8, .@"16", vt.instance_size);
    vt.init_model(mblob.ptr);
    if (vt.derive) |derive| derive(mblob.ptr);
    vt.init_instance(iblob.ptr);
    // Unknowns 0..n, collapsed internals aliased as the builder does.
    const nodes = try gpa.alloc(u32, vt.n_u);
    const alias = try gpa.alloc(i32, vt.n_u);
    @memset(alias, -1);
    if (vt.collapse) |collapse| collapse(mblob.ptr, iblob.ptr, alias.ptr);
    var n: u32 = 0;
    for (nodes, alias, 0..) |*node, a, u| {
        node.* = if (u >= vt.num_ports and a >= 0) nodes[@intCast(a)] else blk: {
            n += 1;
            break :blk n - 1;
        };
    }

    const proto = try vt.proto_create(gpa).unwrap();
    defer proto.destroy(proto.ctx, gpa);
    try vt.proto_add(proto.ctx, gpa, mblob.ptr, iblob.ptr, nodes.ptr).unwrap();
    var pb: abi.PatternBuilder = .{};
    for (0..n) |i| try pb.add(gpa, @intCast(i), @intCast(i));
    try proto.pattern(proto.ctx, gpa, &pb).unwrap();
    var col_ptr: []u32 = undefined;
    var row_idx: []u32 = undefined;
    const nnz = try pb.toCsc(gpa, gpa, n, &col_ptr, &row_idx);
    const template = try proto.finalize(proto.ctx, gpa, .{ .col_ptr = col_ptr, .row_idx = row_idx, .n = n, .trash_slot = nnz }).unwrap();
    defer template.hooks.deinit(template.ctx, gpa);
    const batch = try template.hooks.instantiate(template.ctx, gpa).unwrap();
    defer batch.hooks.deinit(batch.ctx, gpa);
    // A static DC solve past its first iterate: no `analog initial` rerun.
    batch.hooks.set_sim_state(batch.ctx, .{ .kind = .dc, .analog_initial = false, .iteration = 2 });

    // planes[0] at x, planes[1..5] at the four steps.
    var planes: [5]Planes = undefined;
    for (&planes) |*p| p.* = .{
        .g = try gpa.alloc(f64, nnz + 1),
        .c = try gpa.alloc(f64, nnz + 1),
        .rhs = try gpa.alloc(f64, n + 1),
        .q = try gpa.alloc(f64, n + 1),
    };
    const x = try gpa.alloc(f64, n);
    const g_max = try gpa.alloc(f64, n);
    const c_max = try gpa.alloc(f64, n);

    var checked: usize = 0;
    for (0..points) |_| {
        // ±2 V (or A on a branch row): forward and reverse bias, every region.
        for (x) |*v| v.* = rand.float(f64) * 4 - 2;
        evalAt(batch, planes[0], x);
        const p0 = planes[0];
        if (!allFinite(p0.g) or !allFinite(p0.rhs) or !allFinite(p0.c) or !allFinite(p0.q)) continue;
        @memset(g_max, 0);
        @memset(c_max, 0);
        for (row_idx, p0.g[0..nnz], p0.c[0..nnz]) |r, g, c| {
            g_max[r] = @max(g_max[r], @abs(g));
            c_max[r] = @max(c_max[r], @abs(c));
        }
        for (0..n) |col| {
            const x0 = x[col];
            // Large on purpose: below ~1e-4 V the rounding of cancelling
            // internal currents swamps the difference (psp103, mextram).
            const h = 1e-3 * @max(1.0, @abs(x0));
            for ([_]f64{ h, -h, h / 2, -h / 2 }, planes[1..]) |step, p| {
                x[col] = x0 + step;
                evalAt(batch, p, x);
            }
            x[col] = x0;
            const p = planes[1..];
            try expectColumn(name, col_ptr, row_idx, p0.g, g_max, g_floor, .{ p[0].rhs, p[1].rhs, p[2].rhs, p[3].rhs }, col, h);
            for (nodiff) |m| {
                if (std.mem.eql(u8, m, name)) break;
            } else try expectColumn(name, col_ptr, row_idx, p0.c, c_max, c_floor, .{ p[0].q, p[1].q, p[2].q, p[3].q }, col, h);
        }
        checked += 1;
    }
    if (checked == 0) {
        std.debug.print("{s}: no finite point\n", .{name});
        return error.NoFinitePoint;
    }
}

/// Stamps every plane at x from +0.0.
fn evalAt(batch: abi.Batch, p: Planes, x: []const f64) void {
    for ([_][]f64{ p.g, p.c, p.rhs, p.q }) |s| @memset(s, 0);
    batch.eval(batch.ctx, &.{ .g_vals = p.g, .c_vals = p.c, .rhs = p.rhs, .q_vec = p.q }, 0, 1, x, 0);
}

fn allFinite(xs: []const f64) bool {
    for (xs) |v| if (!std.math.isFinite(v)) return false;
    return true;
}

test "device jacobian == finite difference, every built-in model" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x3ac0b1);
    var failures: usize = 0;
    inline for (catalog.catalog) |e| {
        const vt = catalog.vtable(e.name);
        // A `$systf` device needs a VPI application bound first. Every model
        // reports before the test fails.
        if (vt.systf_calls.len == 0) checkModel(arena.allocator(), e.name, vt, prng.random()) catch |err| {
            if (err != error.JacobianMismatch and err != error.NoFinitePoint) return err;
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
