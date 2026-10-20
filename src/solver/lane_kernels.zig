//! Per-lane bodies of the GPU lane backend (dev/research/plans/phase4),
//! generic over the pointer type so the host runs them as the oracle tests'
//! loops and the device as one thread per lane (`lane_device.zig`):
//! `LaneLu`'s refactor and solve restated over lane-major values, the
//! Newton update, gates and finalize of `converger.newtonLanes`, the
//! transient's companion residual, assembly, predictor, LTE bound and
//! accepted-step update. Lane l of n holds element i at `i * n + l`
//! (lane-major); the LTE tape ring is lane-minor. Each body matches its
//! oracle's operation order, so a host run is bitwise the oracle.
//! std only: the kernel root compiles this file for NVPTX and AMDGCN.

const std = @import("std");

/// Offsets (u32 words) of a frozen `SparseLu` tape inside one index buffer
/// `x`, plus its scalars. Passed by value. Built by `buildTab` from the
/// lead lane's factored `SparseLu`; every lane replays it.
pub const LaneTab = extern struct {
    n: u32,
    nnz: u32,
    nnz_l: u32,
    nnz_u: u32,
    growth: f64,
    /// 1 / `direct.pivot_tol`: `LaneSolver.wideMultipliers`' bound.
    wide: f64,
    col_ptr: u32, // n + 1: A's CSC columns
    prow: u32, // nnz: A entry -> pivot position
    q: u32, // n: pivot step -> column
    pinv: u32, // n: row -> pivot step
    lp: u32, // n + 1
    li: u32, // nnz_l
    up: u32, // n + 1
    ui: u32, // nnz_u
    flags: u32, // n: bit 0 void column, bit 1 scaled pivot
};

pub const void_bit: u32 = 1;
pub const scaled_bit: u32 = 2;

pub fn Bodies(comptime P: fn (type) type) type {
    return struct {
        /// `LaneLu.refactor` for lane l, plus `LaneSolver.wideMultipliers`:
        /// true when lane l must peel (dead or non-finite pivot, growth,
        /// a non-finite L/U entry, a wide multiplier, or a void column).
        /// `a` is A lane-major in pattern order (nnz rows); `w` is n rows of
        /// zeros on entry and on exit.
        pub fn refactor(t: LaneTab, x: P(u32), a: P(f64), lx: P(f64), ux: P(f64), udiag: P(f64), w: P(f64), n_lanes: u32, l: u32) bool {
            const N: usize = n_lanes;
            const L: usize = l;
            var bad = false;
            var nonfinite: u64 = 0;
            const inf = std.math.inf(f64);
            for (0..t.n) |k| {
                const c = x[t.q + k];
                for (x[t.col_ptr + c]..x[t.col_ptr + c + 1]) |p| w[@as(usize, x[t.prow + p]) * N + L] = a[p * N + L];
                for (x[t.up + k]..x[t.up + k + 1]) |p| {
                    const i: usize = x[t.ui + p];
                    const uki = w[i * N + L];
                    w[i * N + L] = 0;
                    ux[p * N + L] = uki;
                    nonfinite |= @as(u64, @bitCast(uki - uki));
                    for (x[t.lp + i]..x[t.lp + i + 1]) |pl| w[@as(usize, x[t.li + pl]) * N + L] -= lx[pl * N + L] * uki;
                }
                if (x[t.flags + k] & void_bit != 0) {
                    for (0..t.n) |i| w[i * N + L] = 0;
                    return true;
                }
                var d = w[k * N + L];
                w[k * N + L] = 0;
                const dead = d == 0 or !(@abs(d) < inf);
                bad = bad or dead;
                if (dead) d = 1;
                udiag[k * N + L] = d;
                if (t.growth > 0 and x[t.flags + k] & scaled_bit == 0) {
                    var cbits: i64 = @bitCast(@abs(d));
                    for (x[t.lp + k]..x[t.lp + k + 1]) |p| {
                        const r: usize = x[t.li + p];
                        const v = w[r * N + L];
                        w[r * N + L] = 0;
                        cbits = @max(cbits, @as(i64, @bitCast(@abs(v))));
                        lx[p * N + L] = v / d;
                    }
                    const cmax: f64 = @bitCast(cbits);
                    bad = bad or !(@abs(d) >= t.growth * cmax);
                } else {
                    for (x[t.lp + k]..x[t.lp + k + 1]) |p| {
                        const r: usize = x[t.li + p];
                        const lv = w[r * N + L] / d;
                        nonfinite |= @as(u64, @bitCast(lv - lv));
                        lx[p * N + L] = lv;
                        w[r * N + L] = 0;
                    }
                }
            }
            if (nonfinite != 0) return true;
            // `wideMultipliers`: an unscaled column's L entry past 1 / pivot_tol.
            var worst: u64 = 0;
            for (0..t.n) |k| {
                if (x[t.flags + k] & scaled_bit != 0) continue;
                for (x[t.lp + k]..x[t.lp + k + 1]) |p| worst = @max(worst, @as(u64, @bitCast(@abs(lx[p * N + L]))));
            }
            return bad or !(@as(f64, @bitCast(worst)) <= t.wide);
        }

        /// `LaneLu.solve` of -rhs for lane l: dx = -A_l^-1 rhs_l, bitwise
        /// `LaneSolver.factorSolveNeg`'s vector lane. `y` is n rows of
        /// scratch.
        pub fn solveNeg(t: LaneTab, x: P(u32), lx: P(f64), ux: P(f64), udiag: P(f64), rhs: P(f64), y: P(f64), dx: P(f64), n_lanes: u32, l: u32) void {
            const N: usize = n_lanes;
            const L: usize = l;
            for (0..t.n) |r| y[@as(usize, x[t.pinv + r]) * N + L] = -rhs[r * N + L];
            for (0..t.n) |k| {
                const yk = y[k * N + L];
                if (yk != 0) for (x[t.lp + k]..x[t.lp + k + 1]) |p| {
                    y[@as(usize, x[t.li + p]) * N + L] -= lx[p * N + L] * yk;
                };
            }
            var k: usize = t.n;
            while (k > 0) {
                k -= 1;
                const zk = y[k * N + L] / udiag[k * N + L];
                y[k * N + L] = zk;
                if (zk != 0) for (x[t.up + k]..x[t.up + k + 1]) |p| {
                    y[@as(usize, x[t.ui + p]) * N + L] -= ux[p * N + L] * zk;
                };
            }
            for (0..t.n) |j| dx[@as(usize, x[t.q + j]) * N + L] = y[j * N + L];
        }

        /// `converger.updateAndNorm` at W = 1 for lane l: x_old = x,
        /// x += dx, the delta score. Same operations in the same order.
        pub fn updateNorm(n: u32, x: P(f64), dx: P(f64), x_old: P(f64), current_row: P(u8), reltol: f64, abstol: f64, vntol: f64, n_lanes: u32, l: u32) f64 {
            const N: usize = n_lanes;
            const L: usize = l;
            const inf = std.math.inf(f64);
            var worst: i64 = 0;
            for (0..n) |i| {
                const xo = x[i * N + L];
                const d = dx[i * N + L];
                const xn = xo + d;
                x_old[i * N + L] = xo;
                x[i * N + L] = xn;
                const tol = reltol * @max(@abs(xn), @abs(xo)) + (if (current_row[i] != 0) abstol else vntol);
                const finite = @abs(xn) < inf and @abs(d) < inf;
                const q = @abs(d) / tol;
                const score = if (!finite) inf else if (q == q) q else 0;
                worst = @max(worst, @as(i64, @bitCast(score)));
            }
            return @bitCast(worst);
        }

        /// `plausible` for lane l: every |x_i| finite and <= limit.
        pub fn plausible(n: u32, x: P(f64), limit: f64, n_lanes: u32, l: u32) bool {
            for (0..n) |i| if (!(@abs(x[i * @as(usize, n_lanes) + l]) <= limit)) return false;
            return true;
        }

        /// `plausibleLimit` for lane l: the runaway bound read off the
        /// solve's first assembly (x, residual f, matrix values).
        pub fn plausibleLimit(n: u32, x: P(f64), f: P(f64), vals: P(f64), diag: P(u32), n_lanes: u32, l: u32) f64 {
            const N: usize = n_lanes;
            var g: f64 = 1;
            for (0..n) |i| g = @max(g, @abs(vals[@as(usize, diag[i]) * N + l]));
            var xm: u64 = 0;
            var fm: u64 = 0;
            for (0..n) |i| {
                xm = @max(xm, @as(u64, @bitCast(@abs(x[i * N + l]))));
                fm = @max(fm, @as(u64, @bitCast(@abs(f[i * N + l]))));
            }
            const scale = @min(@max(@as(f64, @bitCast(xm)), @as(f64, @bitCast(fm)) * g), 1e18);
            return if (!(1e3 * scale > x_plausible)) x_plausible else 1e3 * scale;
        }

        /// The transient companion residual and matrix of lane l at row/slot
        /// granularity: `integrator.companionAt(m, true, ...)` per row and
        /// `combineGC(ag0)` per slot. `method`: 0 BE, 1 trap, 2 gear-2.
        /// q1/q2 are the ring's logical slots 1 and 2 (`ring` physical
        /// slots via `perm`).
        pub fn companionRow(i: usize, method: u8, ag0: f64, ag1: f64, ag2: f64, rhs: P(f64), q: P(f64), ring: P(f64), perm: P(u8), n_hist: u32, n: u32, i_prev: P(f64), n_lanes: u32, l: u32) void {
            const N: usize = n_lanes;
            const L: usize = l;
            const s1: usize = perm[L * n_hist + 1];
            const s2: usize = perm[L * n_hist + 2];
            const a = q[i * N + L];
            const b = ring[(s1 * n + i) * N + L];
            const d = ag0 * (a - b);
            const base = rhs[i * N + L] + d;
            rhs[i * N + L] = switch (method) {
                1 => base - ag1 * i_prev[i * N + L],
                2 => base - ag2 * (b - ring[(s2 * n + i) * N + L]),
                else => base,
            };
        }

        /// A = G + ag0 C at slot p for lane l (`combinePlanes`'s order:
        /// g + alpha * c).
        pub fn combineSlot(p: usize, ag0: f64, g: P(f64), c: P(f64), a: P(f64), n_lanes: u32, l: u32) void {
            const i = p * @as(usize, n_lanes) + l;
            a[i] = g[i] + ag0 * c[i];
        }
    };
}

/// `converger.x_plausible`, the runaway floor. Kept equal by a host test.
pub const x_plausible = 1e9;

/// The LTE inputs of one step, per lane (uploaded with `LaneScalars`).
pub const LteIn = extern struct { dt: f64, dt1: f64, dt2: f64, reltol: f64, abstol: f64, chgtol: f64, trtol: f64, ag0: f64, ag1: f64, ag2: f64 };

/// `integrator.stepBound(w, method, cur_method, ...)` for one lane over its
/// contiguous history: `q[k]` is logical slot k (length `len`), methods as
/// in `companionRow`. NaN as `stepBound`. Order 1 or 2 only.
pub fn stepBound(method: u8, cur_method: u8, q0: []const f64, q1: []const f64, q2: []const f64, q3: []const f64, ip: []const f64, c: LteIn) f64 {
    const coeff: f64 = switch (method) {
        0 => 0.5,
        1 => 0.08333333333,
        else => 0.2222222222,
    };
    const sum01 = c.dt + c.dt1;
    const sum12 = c.dt1 + c.dt2;
    const sum012 = c.dt + (c.dt1 + c.dt2);
    var vmin = std.math.inf(f64);
    var poison: f64 = 0;
    for (q0, q1, q2, q3, ip) |qc, qp, qp2, qp3, i_p| {
        const i_new = switch (cur_method) {
            1 => c.ag0 * (qc - qp) - c.ag1 * i_p,
            2 => c.ag0 * (qc - qp) - c.ag2 * (qp - qp2),
            else => c.ag0 * (qc - qp),
        };
        const volttol = c.abstol + c.reltol * @max(@abs(i_new), @abs(i_p));
        const chargetol = c.reltol * @max(@max(@abs(qc), @abs(qp)), c.chgtol) / c.dt;
        const tol = @max(volttol, chargetol);
        poison += (qc - qc) + (qp - qp) + (qp2 - qp2) + (i_p - i_p);
        const f12 = (qp - qp2) / c.dt1;
        var dd = ((qc - qp) / c.dt - f12) / sum01;
        if (method != 0) {
            poison += qp3 - qp3;
            const f123 = (f12 - (qp2 - qp3) / c.dt2) / sum12;
            dd = (dd - f123) / sum012;
        }
        const del = c.trtol * tol / @max(c.abstol, coeff * @abs(dd));
        poison += if (del == del) 0 else del;
        vmin = @min(vmin, del);
    }
    if (std.math.isNan(poison)) return std.math.nan(f64);
    return if (method == 0) vmin else @sqrt(vmin);
}

/// VerA's `contract.SimState` (24 bytes, extern), restated so this file
/// stays std only; `gpu_lanes.zig` asserts the two layouts equal.
pub const SimState = extern struct {
    t: f64 = 0,
    dt: f64 = 0,
    kind: u8 = 0,
    initial_step: bool = false,
    final_step: bool = false,
    analog_initial: bool = true,
    iteration: u32 = 1,
};

/// The `LaneTab` of a factored sparse LU `lu` (`SparseLu`'s fields) over the
/// CSC column pointers `col_ptr`, its index arrays concatenated into one
/// buffer the caller owns. `growth` is the solver's refactor growth limit,
/// `pivot_tol` `direct.pivot_tol`.
pub fn buildTab(gpa: std.mem.Allocator, lu: anytype, col_ptr: []const u32, growth: f64, pivot_tol: f64) !struct { idx: []u32, tab: LaneTab } {
    const n = lu.n;
    const nnz = col_ptr[n];
    const nl: u32 = @intCast(lu.li.items.len);
    const nu: u32 = @intCast(lu.ui.items.len);
    var t: LaneTab = .{ .n = n, .nnz = nnz, .nnz_l = nl, .nnz_u = nu, .growth = growth, .wide = 1 / pivot_tol, .col_ptr = 0, .prow = 0, .q = 0, .pinv = 0, .lp = 0, .li = 0, .up = 0, .ui = 0, .flags = 0 };
    const parts = [_]struct { *u32, []const u32 }{
        .{ &t.col_ptr, col_ptr[0 .. n + 1] }, .{ &t.prow, lu.prow[0..nnz] }, .{ &t.q, lu.q[0..n] },
        .{ &t.pinv, lu.pinv[0..n] },          .{ &t.lp, lu.lp[0 .. n + 1] }, .{ &t.li, lu.li.items },
        .{ &t.up, lu.up[0 .. n + 1] },         .{ &t.ui, lu.ui.items },
    };
    var len: usize = n;
    for (parts) |p| len += p[1].len;
    const idx = try gpa.alloc(u32, len);
    var at: u32 = 0;
    for (parts) |p| {
        p[0].* = at;
        @memcpy(idx[at..][0..p[1].len], p[1]);
        at += @intCast(p[1].len);
    }
    t.flags = at;
    for (idx[at..][0..n], lu.void_col[0..n], lu.scaled_pivot[0..n]) |*f, v, s|
        f.* = (if (v) void_bit else 0) | (if (s) scaled_bit else 0);
    return .{ .idx = idx, .tab = t };
}

/// `Bodies`' pointer type on the host: a plain many-item pointer.
pub fn HostP(comptime T: type) type {
    return [*]T;
}

const testing = std.testing;

test "lane_kernels refactor and solveNeg over N lanes are bitwise LaneLu(W)'s lanes, and fail exactly where it fails or a multiplier runs wide" {
    const gpa = testing.allocator;
    const direct = @import("direct.zig");
    const SparseLu = @import("sparse_lu.zig").SparseLu;
    const LaneLu = @import("lane_lu.zig").LaneLu;
    const W = 4;
    const V = @Vector(W, f64);
    const B = Bodies(HostP);
    var prng = std.Random.DefaultPrng.init(0x1a7e51);
    const r = prng.random();
    var good: usize = 0;
    var failed: usize = 0;
    for (0..64) |trial| {
        const n: u32 = @intCast(2 + trial % 20);
        const sys = try SparseLu.test_access.TestSystem.init(gpa, r, n, 0.3);
        defer sys.deinit(gpa);
        const nnz = sys.vals.len;
        var lead = try direct.Solver.init(gpa, n, sys.col_ptr, sys.row_idx, null, .{});
        defer lead.deinit();
        lead.factor(sys.vals, .{}) catch continue;
        const lu = lead.sparse() orelse continue;
        var ll = try LaneLu(W).init(gpa, lu);
        defer ll.deinit(gpa);
        const built = try buildTab(gpa, lu, sys.col_ptr, lead.params.refactor_growth_limit, direct.pivot_tol);
        defer gpa.free(built.idx);
        const t = built.tab;
        // Lane-major values: lane l scales, redraws an entry or zeroes a column.
        const vals = try gpa.alloc(V, nnz);
        defer gpa.free(vals);
        const rhs = try gpa.alloc(V, n);
        defer gpa.free(rhs);
        const x_ll = try gpa.alloc(V, n);
        defer gpa.free(x_ll);
        const arr: [][W]f64 = @ptrCast(vals);
        for (arr, sys.vals) |*v, a| v.* = @splat(a);
        for (0..W) |l| switch (r.uintLessThan(u8, 6)) {
            0 => arr[r.uintLessThan(usize, nnz)][l] = 4 * r.float(f64) - 2,
            1 => {
                const c = r.uintLessThan(usize, n);
                for (sys.col_ptr[c]..sys.col_ptr[c + 1]) |p| arr[p][l] = 0;
            },
            else => for (arr, sys.vals) |*v, a| {
                v[l] = a * (0.95 + 0.1 * r.float(f64));
            },
        };
        for (rhs) |*v| {
            var a: [W]f64 = undefined;
            for (&a) |*e| e.* = 2 * r.float(f64) - 1;
            v.* = a;
        }
        var bad = ll.refactor(LaneLu(W).Plane{ .col_ptr = sys.col_ptr, .vals = vals }, lead.params.refactor_growth_limit);
        // LaneSolver.wideMultipliers.
        var worst: @Vector(W, u64) = @splat(0);
        for (0..n) |k| {
            if (lu.scaled_pivot[k]) continue;
            for (ll.lx[lu.lp[k]..lu.lp[k + 1]]) |e| worst = @max(worst, @as(@Vector(W, u64), @bitCast(@abs(e))));
        }
        const wide: [W]bool = !(@as(V, @bitCast(worst)) <= @as(V, @splat(1 / direct.pivot_tol)));
        for (wide, 0..) |w_, l| bad |= @as(u64, @intFromBool(w_)) << @intCast(l);
        for (x_ll, rhs) |*d, b| d.* = -b;
        ll.solve(x_ll, x_ll);

        // The same lanes through the per-lane bodies.
        const N = W;
        const a_f: [*]f64 = @ptrCast(vals.ptr);
        const lx = try gpa.alloc(f64, @max(t.nnz_l, 1) * N);
        defer gpa.free(lx);
        const ux = try gpa.alloc(f64, @max(t.nnz_u, 1) * N);
        defer gpa.free(ux);
        const scratch = try gpa.alloc(f64, 4 * n * N);
        defer gpa.free(scratch);
        @memset(scratch, 0);
        const udiag = scratch[0 .. n * N];
        const w = scratch[n * N ..][0 .. n * N];
        const y = scratch[2 * n * N ..][0 .. n * N];
        const dx = scratch[3 * n * N ..][0 .. n * N];
        const rhs_f: [*]f64 = @ptrCast(rhs.ptr);
        for (0..W) |l| {
            const fail = B.refactor(t, built.idx.ptr, a_f, lx.ptr, ux.ptr, udiag.ptr, w.ptr, N, @intCast(l));
            try testing.expectEqual((bad >> @intCast(l)) & 1 != 0, fail);
            for (w) |e| try testing.expectEqual(@as(f64, 0), e);
            if (fail) {
                failed += 1;
                continue;
            }
            good += 1;
            B.solveNeg(t, built.idx.ptr, lx.ptr, ux.ptr, udiag.ptr, rhs_f, y.ptr, dx.ptr, N, @intCast(l));
            for (0..n) |i| {
                const lanes_i: [W]f64 = x_ll[i];
                try testing.expectEqual(@as(u64, @bitCast(lanes_i[l])), @as(u64, @bitCast(dx[i * N + l])));
            }
        }
    }
    try testing.expect(good > 0 and failed > 0);
}

test "lane_kernels updateNorm and plausibleLimit at one lane are bitwise converger's W = 1 forms" {
    const converger = @import("converger.zig");
    const B = Bodies(HostP);
    try testing.expectEqual(converger.x_plausible, x_plausible);
    var prng = std.Random.DefaultPrng.init(0x1a7e52);
    const r = prng.random();
    const N = 3;
    const n = 40;
    const special = [_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), -0.0, 0.0, 1e300, -1e-300 };
    for (0..50) |_| {
        var x: [n * N]f64 = undefined;
        var dx: [n * N]f64 = undefined;
        var xo: [n * N]f64 = undefined;
        var f: [n * N]f64 = undefined;
        var vals: [n * N]f64 = undefined;
        var cur: [n]u8 = undefined;
        var cur_b: [n]bool = undefined;
        var diag: [n]u32 = undefined;
        for (&x, &dx, &f, &vals) |*a, *b, *c, *d| {
            a.* = if (r.uintLessThan(u8, 20) == 0) special[r.uintLessThan(usize, special.len)] else 10 * r.float(f64) - 5;
            b.* = if (r.uintLessThan(u8, 20) == 0) special[r.uintLessThan(usize, special.len)] else r.float(f64) - 0.5;
            c.* = 1e3 * r.float(f64) - 500;
            d.* = 1e4 * r.float(f64);
        }
        for (&cur, &cur_b, &diag, 0..) |*c, *cb, *d, i| {
            cb.* = r.boolean();
            c.* = @intFromBool(cb.*);
            d.* = @intCast((i * 7) % n);
        }
        for (0..N) |l| {
            var xl: [n]f64 = undefined;
            var dl: [n]f64 = undefined;
            var ol: [n]f64 = undefined;
            var fl: [n]f64 = undefined;
            var vl: [n]f64 = undefined;
            for (0..n) |i| {
                xl[i] = x[i * N + l];
                dl[i] = dx[i * N + l];
                fl[i] = f[i * N + l];
                vl[i] = vals[i * N + l];
            }
            const Sys = struct { n: u32, diag_slots: []const u32 };
            const want_lim = converger.plausibleLimit(Sys{ .n = n, .diag_slots = &diag }, @as([]const f64, &xl), @as([]const f64, &fl), @as([]const f64, &vl));
            const got_lim = B.plausibleLimit(n, &x, &f, &vals, &diag, N, @intCast(l));
            try testing.expectEqual(@as(u64, @bitCast(want_lim)), @as(u64, @bitCast(got_lim)));
            const want = converger.updateAndNorm(1, &xl, &dl, &ol, &cur_b, 1e-3, 1e-12, 1e-6, true);
            const got = B.updateNorm(n, &x, &dx, &xo, &cur, 1e-3, 1e-12, 1e-6, N, @intCast(l));
            try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
            for (0..n) |i| {
                try testing.expectEqual(@as(u64, @bitCast(xl[i])), @as(u64, @bitCast(x[i * N + l])));
                try testing.expectEqual(@as(u64, @bitCast(ol[i])), @as(u64, @bitCast(xo[i * N + l])));
            }
            try testing.expectEqual(B.plausible(n, &x, got_lim, N, @intCast(l)), blk: {
                for (xl) |e| if (!(@abs(e) <= got_lim)) break :blk false;
                break :blk true;
            });
        }
    }
}
