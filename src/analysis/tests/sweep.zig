const DcmatchTests = struct {
    const impl = @import("../dc/dcmatch.zig");
    const pelgromSigma = impl.test_access.pelgromSigma;
    const root = @import("../types.zig");
    const std = @import("std");

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------

    test "pelgromSigma — real coefficients" {
        const ref = root.ParamRef{
            .ptr = undefined,
            .device_type = "nmos",
            .param_name = "vth0",
            .index = 0,
            .is_instance = false,
            .primary = false,
            .pelgrom_ap = 4e-3, // 4 mV·um
            .area_wl = 1e-12, // 1 um^2
        };
        const sigma = pelgromSigma(ref);
        // sigma = 4e-3 / sqrt(1e-12) = 4e-3 / 1e-6 = 4000
        try std.testing.expectApproxEqRel(sigma, 4e3, 1e-12);
    }

    test "pelgromSigma — unit fallback when pelgrom_ap is zero" {
        const ref = root.ParamRef{
            .ptr = undefined,
            .device_type = "nmos",
            .param_name = "vth0",
            .index = 0,
            .is_instance = false,
            .primary = false,
            .pelgrom_ap = 0,
            .area_wl = 1e-12,
        };
        try std.testing.expectEqual(pelgromSigma(ref), 1.0);
    }

    test "pelgromSigma — unit fallback when area_wl is zero" {
        const ref = root.ParamRef{
            .ptr = undefined,
            .device_type = "nmos",
            .param_name = "vth0",
            .index = 0,
            .is_instance = false,
            .primary = false,
            .pelgrom_ap = 4e-3,
            .area_wl = 0,
        };
        try std.testing.expectEqual(pelgromSigma(ref), 1.0);
    }

    test "pelgromSigma — both zero gives unit fallback" {
        const ref = root.ParamRef{
            .ptr = undefined,
            .device_type = "nmos",
            .param_name = "vth0",
            .index = 0,
            .is_instance = false,
            .primary = false,
        };
        try std.testing.expectEqual(pelgromSigma(ref), 1.0);
    }
};

const SensTests = struct {
    const impl = @import("../sweep/sens.zig");
    const W = impl.test_access.W;
    const adjointFd = impl.test_access.adjointFd;
    const copySimd = impl.test_access.copySimd;
    const std = @import("std");

    // ---------------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------------

    const testing = std.testing;

    /// Scalar oracle for adjointFd: the materialize-then-dot form it replaced,
    /// with the same lane fold (W == 1 degenerates to this loop exactly).
    fn adjointFdOracle(lambda: []const f64, pert: []const f64, nom: []const f64, inv_delta: f64) f64 {
        var dfdp: [64]f64 = undefined;
        for (0..lambda.len) |i| dfdp[i] = (pert[i] - nom[i]) * inv_delta;
        const V = @Vector(W, f64);
        var acc: V = @splat(0.0);
        var i: usize = 0;
        while (i + W <= lambda.len) : (i += W) {
            const av: V = lambda[i..][0..W].*;
            const bv: V = dfdp[i..][0..W].*;
            acc += av * bv;
        }
        const arr: [W]f64 = acc;
        var s: f64 = 0;
        for (arr) |v| s += v;
        while (i < lambda.len) : (i += 1) s += lambda[i] * dfdp[i];
        return s;
    }

    test "adjointFd: matches the materialize-then-dot oracle bit for bit" {
        var prng = std.Random.DefaultPrng.init(0xfeed);
        const rng = prng.random();
        var lambda: [64]f64 = undefined;
        var pert: [64]f64 = undefined;
        var nom: [64]f64 = undefined;
        for (0..64) |i| {
            lambda[i] = rng.floatNorm(f64);
            nom[i] = rng.floatNorm(f64);
            pert[i] = nom[i] + 1e-7 * rng.floatNorm(f64);
        }
        // every length across the vector boundary, plus the empty and tail cases
        for (0..65) |n| {
            const inv_delta = 1.0 / 1e-7;
            try testing.expectEqual(
                adjointFdOracle(lambda[0..n], pert[0..n], nom[0..n], inv_delta),
                adjointFd(lambda[0..n], pert[0..n], nom[0..n], inv_delta),
            );
        }
    }

    test "adjointFd: known value" {
        // dF/dp = (pert - nom) / delta = (2,4,6)/2 = (1,2,3); λ·dF/dp = 4+10+18 = 32
        const lambda = [_]f64{ 4.0, 5.0, 6.0 };
        const nom = [_]f64{ 0.0, 0.0, 0.0 };
        const pert = [_]f64{ 2.0, 4.0, 6.0 };
        try testing.expectApproxEqAbs(@as(f64, 32.0), adjointFd(&lambda, &pert, &nom, 0.5), 1e-15);
    }

    test "copySimd: round-trip" {
        var dst: [5]f64 = undefined;
        const src = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
        copySimd(&dst, &src);
        for (dst, src) |d, s| try testing.expectEqual(s, d);
    }
};

const TempSweepTests = struct {
    const impl = @import("../sweep/temp_sweep.zig");
    const numPoints = impl.numPoints;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    test "temp_sweep: numPoints calculation" {
        try testing.expectEqual(@as(u32, 166), numPoints(.{
            .t_start = -40.0,
            .t_stop = 125.0,
            .t_step = 1.0,
        }));
        try testing.expectEqual(@as(u32, 34), numPoints(.{
            .t_start = -40.0,
            .t_stop = 125.0,
            .t_step = 5.0,
        }));
        try testing.expectEqual(@as(u32, 1), numPoints(.{
            .t_start = 27.0,
            .t_stop = 27.0,
            .t_step = 1.0,
        }));
    }
};

test {
    _ = DcmatchTests;
    _ = SensTests;
    _ = TempSweepTests;
}
