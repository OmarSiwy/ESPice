//! Canonical test devices (value-form contract: physics generic over a
//! scalar S, analytic Jacobian for free). Test-only: imported by inline
//! tests across analysis files and by tests/.
const std = @import("std");
const root = @import("analysis");

/// Limiting result for the 2-unknown test devices. `converged` is the device's
/// own verdict on whether its clamp was significant enough to require another
/// Newton iteration — see contract.LimitResult.
const Lim2 = root.devices.batch.LimitResult(2);

/// Linear resistor. F_p = g(vp-vn), F_n = -that. Declares its thermal
/// noise generator so noise tests have a source (builtin device noise).
pub const R = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const Model = struct { r: f32 = 1000 };
    pub const Instance = struct {};
    // dI_p/dV_n = -g: |.| = g, injected between nodes p and n.
    pub const noise_gens = [_]root.NoiseGen{.{ .row = 0, .col = 1, .kind = .thermal }};
    pub fn eval(comptime S: type, x: [2]S, m: *const Model, _: *const Instance, _: f64) [2]S {
        const ir = x[0].sub(x[1]).scale(1.0 / @as(f64, m.r));
        return .{ ir, ir.neg() };
    }
};

/// Constant-Jacobian resistor: exercises the baseline (has_const_jacobian)
/// path in Circuit.evalNewton — R above deliberately does not declare it.
pub const Rc = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const constant: root.devices.batch.Constant = .{ .g = true };
    pub const Model = struct { r: f32 = 1000 };
    pub const Instance = struct {};
    pub fn eval(comptime S: type, x: [2]S, m: *const Model, _: *const Instance, _: f64) [2]S {
        const ir = x[0].sub(x[1]).scale(1.0 / @as(f64, m.r));
        return .{ ir, ir.neg() };
    }
};

/// Diode with a PrepCache: exercises the eval-dedup cache (canDedup) path —
/// identical models collapse to one prep group, cache keyed on voltages.
pub const Dp = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const Model = struct { is: f32 = 1e-14 };
    pub const Instance = struct {};
    pub const PrepCache = struct { is: f64, inv_vt: f64 };
    pub fn computePrep(m: *const Model, _: *const Instance) PrepCache {
        return .{ .is = @as(f64, m.is), .inv_vt = 1.0 / 0.02585 };
    }
    pub fn evalFromPrep(comptime S: type, x: [2]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [2]S {
        const id = x[0].sub(x[1]).minC(0.9).scale(pc.inv_vt).exp().addC(-1.0).scale(pc.is);
        return .{ id, id.neg() };
    }
    pub fn limit(_: *const Model, _: *const Instance, cur: [2]f64, old: [2]f64) Lim2 {
        return D.limit(undefined, undefined, cur, old);
    }
};

/// Voltage source with branch current unknown. dc + amp*sin(2*pi*freq*t).
pub const V = struct {
    pub const U = enum(u8) { p, n, branch };
    pub const num_ports: usize = 2;
    pub const Model = struct { dc: f32 = 0, amp: f32 = 0, freq: f32 = 0 };
    pub const Instance = struct {};
    pub fn eval(comptime S: type, x: [3]S, m: *const Model, _: *const Instance, t: f64) [3]S {
        const v: f64 = @as(f64, m.dc) + @as(f64, m.amp) * @sin(2.0 * std.math.pi * @as(f64, m.freq) * t);
        return .{ x[2], x[2].neg(), x[0].sub(x[1]).addC(-v) };
    }
};

/// Independent current source, p -> n.
pub const I = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const Model = struct { dc: f32 = 0 };
    pub const Instance = struct {};
    pub fn eval(comptime S: type, _: [2]S, m: *const Model, _: *const Instance, _: f64) [2]S {
        return .{ S.con(@as(f64, m.dc)), S.con(-@as(f64, m.dc)) };
    }
};

/// Linear capacitor: q = C*(vp-vn). No resistive current.
pub const C = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const Model = struct { c: f32 = 1e-6 };
    pub const Instance = struct {};
    pub fn eval(comptime S: type, _: [2]S, _: *const Model, _: *const Instance, _: f64) [2]S {
        return .{ S.con(0), S.con(0) };
    }
    pub fn q(comptime S: type, x: [2]S, m: *const Model, _: *const Instance, _: f64) [2]S {
        const qv = x[0].sub(x[1]).scale(@as(f64, m.c));
        return .{ qv, qv.neg() };
    }
};

/// Exponential diode, p -> n. i = is*(exp(v/vt)-1), vt = 25.85mV.
/// The minC clamp keeps exp finite far from the solution; its derivative
/// goes flat past the clamp, which is exactly the damping NR wants there.
pub const D = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const Model = struct { is: f32 = 1e-14 };
    pub const Instance = struct {};
    pub fn eval(comptime S: type, x: [2]S, m: *const Model, _: *const Instance, _: f64) [2]S {
        const vt = 0.02585;
        const id = x[0].sub(x[1]).minC(0.9).scale(1.0 / vt).exp().addC(-1.0).scale(@as(f64, m.is));
        return .{ id, id.neg() };
    }
    /// pnjlim-style junction limiting: without it Newton ping-pongs between
    /// the exp wall and the off region and never converges.
    pub fn limit(_: *const Model, _: *const Instance, cur: [2]f64, old: [2]f64) Lim2 {
        const vt = 0.02585;
        const vcrit = 0.6;
        const v_old = old[0] - old[1];
        const v_in = cur[0] - cur[1];
        var v = v_in;
        if (v > vcrit and @abs(v - v_old) > 2 * vt) {
            v = if (v_old > 0) blk: {
                const arg = 1.0 + (v - v_old) / vt;
                break :blk if (arg > 0) v_old + vt * @log(arg) else vcrit;
            } else vcrit;
        }
        // pnjlim clamped: the iterate was moved, so Newton must go round again.
        return .{ .x = .{ cur[1] + v, cur[1] }, .converged = v == v_in };
    }
};

/// Linear inductor: branch unknown carries the current, q on the branch row
/// is the flux L*i. v = L di/dt in MNA form.
pub const L = struct {
    pub const U = enum(u8) { p, n, branch };
    pub const num_ports: usize = 2;
    pub const Model = struct { l: f32 = 1e-3 };
    pub const Instance = struct {};
    pub fn eval(comptime S: type, x: [3]S, _: *const Model, _: *const Instance, _: f64) [3]S {
        // KCL: branch current in/out; branch eq: -(vp-vn) + d(flux)/dt = 0
        return .{ x[2], x[2].neg(), x[0].sub(x[1]).neg() };
    }
    pub fn q(comptime S: type, x: [3]S, m: *const Model, _: *const Instance, _: f64) [3]S {
        return .{ S.con(0), S.con(0), x[2].scale(@as(f64, m.l)) };
    }
};
