//! Jacobian certificate for every built-in model: one instance of each
//! catalog device, stamped by `Circuit.eval` (each batch's DeviceBatch.eval
//! through its own object's vtable) → dense G = ∂f/∂x and C = ∂q/∂x, each
//! checked against a central difference of the residual f and charge q.

const std = @import("std");
const t = std.testing;
const Builder = @import("builder").Builder;
const Library = @import("device").Library;
const models = @import("models");
const types = @import("../types.zig");

/// Unknowns of the widest model plus ground; the dense scratch bound.
const n_max = 64;

/// Central-difference step. Truncation error h²|f'''|/6 against |f'|: at a
/// junction's thermal voltage that is h²/(6 Vt²) ≈ 2.5e-10. Roundoff ε|f|/h
/// stays below 1e-9 of |f'| while |f/f'| is under 4 V.
const h = 1e-6;
/// An entry passes when |J - FD| <= rtol (|J| + max_k |J_ik|): relative to
/// the entry and to its row's largest partial, since a central difference
/// resolves a tiny partial only to the row's roundoff. 1e-5 sits above the
/// f32 Jacobian lanes' 6e-8 and the FD error, and below any wrong partial,
/// which misses by O(1).
const rtol = 1e-5;

/// Models whose C is by design not ∂q/∂x, so only G is checked. Each
/// stamps `C * ddt(V)` with the capacitance under `vera_nodiff`, as ngspice
/// integrates capgs/capgd as coefficients on the voltage increment
/// (hfetload.c, hfet2load.c, mesaload.c:341-370; the comment at each
/// model's `ddt` sites). Their q is then not the integral of C: measured
/// |C - FD| / scale up to 0.71.
const c_not_dq = std.StaticStringMap(void).initComptime(.{ .{"hfet1"}, .{"hfet2"}, .{"mesa"} });

/// Port bias by position: drain/collector, gate/base, source/emitter, bulk.
/// Off any region boundary for the default model cards (VTO 0..0.7, PN
/// junctions forward at 0.7 V); the remaining ports get small offsets,
/// cycling past the seventh (bsource_q has ten ports).
const port_bias = [_]f64{ 0.9137, 0.7213, 0.0, -0.0731, 0.0517, 0.1129, -0.0373 };

fn portBias(k: usize) f64 {
    return port_bias[k % port_bias.len];
}

/// The bias of unknown `name`: a port by position; an internal node
/// (`di`, `si`, `bx`, ...) 1 mV per internal rank above the port its name
/// starts with, else 0.0313; a branch flow at 1 mA. The offset keeps two
/// internal nodes of one port apart: Mextram 505 switches its epilayer
/// expression at |V(c1,c2)| < 1e-5 Vt (evaluate.inc:120), a branch a zero
/// difference would sit on.
fn bias(comptime D: type, u: usize, name: []const u8) f64 {
    const ports = @typeInfo(D.U).@"enum".field_names[0..D.num_ports];
    if (u < D.num_ports) return portBias(u);
    if (std.mem.startsWith(u8, name, "flow")) return 1e-3;
    for (ports, 0..) |p, k| {
        if (std.ascii.toLower(p[0]) == std.ascii.toLower(name[0])) return portBias(k) + 1e-3 * @as(f64, @floatFromInt(u - D.num_ports + 1));
    }
    return 0.0313;
}

/// `bad` counts the entries past `rtol`, NaN included: `@max` drops a NaN,
/// so `worst` alone would pass one.
const Report = struct { worst: f64, entries: u32, bad: u32 };

/// Checks D's G and C against central differences at the bias point;
/// returns the worst |J - FD| / (|J| + row max) seen and the failures.
fn checkModel(comptime D: type, lib: *const Library, check_c: bool) !Report {
    const name = comptime @import("device").modelName(D).?;
    const field_names = @typeInfo(D.U).@"enum".field_names;
    const n_u = field_names.len;
    var b = try Builder.init(t.allocator, lib);
    var nodes: [D.num_ports]u32 = undefined;
    for (&nodes) |*nd| nd.* = try b.addNode();
    var model: D.Model = .{};
    if (lib.vtable(comptime Library.builtin(name)).derive) |derive| derive(@ptrCast(&model));
    try b.addDevice(D, "", &model, &.{}, nodes);
    var prepared = try b.compile();
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    const n: usize = ckt.n;
    try t.expect(n <= n_max);

    // Rows past the ports are the internal unknowns in D.U order, unless
    // collapsed; label every row by the name of the unknown it carries.
    var x: [n_max]f64 = @splat(0);
    for (1..n) |row| x[row] = 0.0313;
    for (0..D.num_ports) |k| x[nodes[k]] = portBias(k);
    {
        var row: usize = 1 + D.num_ports;
        inline for (D.num_ports..n_u) |u| {
            if (row < n) {
                x[row] = bias(D, u, field_names[u]);
                row += 1;
            }
        }
    }

    var g: [n_max * n_max]f64 = undefined;
    var c: [n_max * n_max]f64 = undefined;
    ckt.eval(x[0..n], 0);
    ckt.denseG(&g);
    ckt.denseC(&c);
    var f_hi: [n_max]f64 = undefined;
    var f_lo: [n_max]f64 = undefined;
    var q_hi: [n_max]f64 = undefined;
    var q_lo: [n_max]f64 = undefined;
    var fd_g: [n_max * n_max]f64 = undefined;
    var fd_c: [n_max * n_max]f64 = undefined;
    for (0..n) |j| {
        const xj = x[j];
        x[j] = xj + h;
        ckt.eval(x[0..n], 0);
        @memcpy(f_hi[0..n], ckt.rhs[0..n]);
        @memcpy(q_hi[0..n], ckt.q_vec[0..n]);
        x[j] = xj - h;
        ckt.eval(x[0..n], 0);
        @memcpy(f_lo[0..n], ckt.rhs[0..n]);
        @memcpy(q_lo[0..n], ckt.q_vec[0..n]);
        x[j] = xj;
        for (0..n) |i| {
            fd_g[i * n + j] = (f_hi[i] - f_lo[i]) / (2 * h);
            fd_c[i * n + j] = if (ckt.has_charge) (q_hi[i] - q_lo[i]) / (2 * h) else 0;
        }
    }

    var report: Report = .{ .worst = 0, .entries = 0, .bad = 0 };
    const jacs = [_]*const [n_max * n_max]f64{ &g, &c };
    const fds = [_]*const [n_max * n_max]f64{ &fd_g, &fd_c };
    const planes: usize = if (check_c) 2 else 1;
    for (jacs[0..planes], fds[0..planes]) |jac, fd| {
        for (0..n) |i| {
            var row_max: f64 = 0;
            for (0..n) |k| row_max = @max(row_max, @abs(jac[i * n + k]), @abs(fd[i * n + k]));
            for (0..n) |j| {
                const d = jac[i * n + j];
                const err = @abs(d - fd[i * n + j]);
                const scale = @abs(d) + row_max;
                if (scale == 0) continue;
                report.entries += 1;
                const rel = err / scale;
                if (!(rel <= rtol)) {
                    std.debug.print("{s}: row {d} col {d}: J {e} FD {e}\n", .{ name, i, j, d, fd[i * n + j] });
                    report.bad += 1;
                }
                report.worst = @max(report.worst, rel);
            }
        }
    }
    return report;
}

test "every built-in model's Jacobian matches a central difference at a smooth bias" {
    @setEvalBranchQuota(100_000);
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var failed: u32 = 0;
    inline for (@typeInfo(models).@"struct".decl_names) |name| {
        const report = try checkModel(@field(models, name), &lib, comptime !c_not_dq.has(name));
        // A model that stamps nothing checks nothing.
        try t.expect(report.entries > 0);
        if (report.bad != 0) failed += 1;
    }
    try t.expectEqual(@as(u32, 0), failed);
}
