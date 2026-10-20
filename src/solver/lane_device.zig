//! GPU kernel root for the lane backend's model-independent kernels
//! (dev/research/plans/phase4-gpu-lanes.md G5): one thread per lane, or per
//! (entry, lane) with lanes innermost, over lane-major buffers (element i of
//! lane l of N at `i * N + l`); the LTE tape ring is lane-minor. Bodies:
//! `lane_kernels.zig`. Every kernel is exported and launched at
//! `block` threads, which HIP bakes into `globalIdX`.

const gompute = @import("gompute");
const lk = @import("lane_kernels.zig");
const P = gompute.GlobalPtr;
const B = lk.Bodies(P);
const SimState = lk.SimState;
/// `device_abi.gpu_lane_block_size`; the host asserts the two equal.
pub const block = 64;

const LaneScalars = lk.LaneScalars;
const Gate = lk.Gate;
const NewtonOpts = lk.NewtonOpts;

fn lane() u32 {
    return @intCast(gompute.globalIdX(block));
}

/// Also counts the failing lanes into `fails[0]` (zeroed by the host), which
/// the host reads to decide whether to peel this tick.
fn refactor(n_lanes: u64, t: lk.LaneTab, x: P(u32), active: P(u8), a: P(f64), lx: P(f64), ux: P(f64), udiag: P(f64), w: P(f64), fail: P(u8), fails: P(u32)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes or active[l] == 0) return;
    const bad = B.refactor(t, x, a, lx, ux, udiag, w, @intCast(n_lanes), l);
    fail[l] = @intFromBool(bad);
    if (bad) _ = @atomicRmw(u32, &fails[0], .Add, 1, .monotonic);
}

fn solveNeg(n_lanes: u64, t: lk.LaneTab, x: P(u32), active: P(u8), fail: P(u8), lx: P(f64), ux: P(f64), udiag: P(f64), rhs: P(f64), y: P(f64), dx: P(f64)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes or active[l] == 0 or fail[l] != 0) return;
    B.solveNeg(t, x, lx, ux, udiag, rhs, y, dx, @intCast(n_lanes), l);
}

/// The ground pin, then the companion rows and the combined matrix, per
/// (row or slot, lane), lanes innermost: thread t < n * N does row t / N,
/// the rest slot (t - n N) / N. Row 0 takes `rhs += x` and slot `d0` `g +=
/// 1` first, as `Circuit.groundStamp` does after the stamp. Without charge
/// A is G. Skips inactive lanes.
fn assemble(n_lanes: u64, n: u64, nnz: u64, d0: u64, charge: u64, sc: P(LaneScalars), active: P(u8), x: P(f64), rhs: P(f64), q: P(f64), ring: P(f64), perm: P(u8), n_hist: u64, i_prev: P(f64), g: P(f64), c: P(f64), a: P(f64)) callconv(gompute.kernel_callconv) void {
    const tid = gompute.globalIdX(block);
    if (tid >= (n + nnz) * n_lanes) return;
    const l: u32 = @intCast(tid % n_lanes);
    if (active[l] == 0) return;
    const s = sc[l];
    const N: usize = @intCast(n_lanes);
    const e: usize = @intCast(tid / n_lanes);
    if (e < n) {
        if (e == 0) rhs[l] += x[l];
        if (charge != 0) B.companionRow(e, @intCast(s.method), s.ag0, s.ag1, s.ag2, rhs, q, ring, perm, @intCast(n_hist), @intCast(n), i_prev, @intCast(n_lanes), l);
    } else {
        const p = e - @as(usize, @intCast(n));
        if (p == d0) g[p * N + l] += 1;
        if (charge != 0) B.combineSlot(p, s.ag0, g, c, a, @intCast(n_lanes), l) else a[p * N + l] = g[p * N + l];
    }
}

/// The delta update for every active lane: x_old = x, x += dx, the score;
/// the runaway bound at iteration 0; clears the lane's flag word for the
/// limit pass that follows. `iter` is the device iteration word.
fn update(n_lanes: u64, n: u64, opts: NewtonOpts, iter: P(u32), active: P(u8), gate: P(Gate), x: P(f64), dx: P(f64), x_old: P(f64), cur_row: P(u8), rhs: P(f64), a: P(f64), diag: P(u32), flags: P(u32)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes or active[l] == 0) return;
    if (iter[0] == 0) gate[l].limit = B.plausibleLimit(@intCast(n), x, rhs, a, diag, @intCast(n_lanes), l);
    gate[l].scaled = B.updateNorm(@intCast(n), x, dx, x_old, cur_row, opts.reltol, opts.abstol, opts.vntol, @intCast(n_lanes), l);
    flags[l] = 0;
}

/// `finalizeStep`'s gates after the limit pass, in its order: limited,
/// first iterate, delta, plausible, then the residual gate at
/// `residual_tol = inf` (the transient's setting), which refuses only a
/// NaN row. Sets `stage[l]` for the lanes the state pass must stage.
fn gates(n_lanes: u64, n: u64, iter: P(u32), active: P(u8), gate: P(Gate), x: P(f64), rhs: P(f64), flags: P(u32), stage: P(u8)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes) return;
    stage[l] = 0;
    if (active[l] == 0) return;
    var g = gate[l];
    var ok = flags[l] & 1 == 0 and iter[0] != 0 and !(g.scaled >= 1.0);
    if (ok) ok = B.plausible(@intCast(n), x, g.limit, @intCast(n_lanes), l);
    if (ok) {
        const N: usize = @intCast(n_lanes);
        for (0..@as(usize, @intCast(n))) |i| {
            const r = rhs[i * N + l];
            if (r != r) ok = false;
        }
    }
    g.bits = (g.bits & ~@as(u32, 16)) | (if (ok) @as(u32, 16) else 0);
    gate[l] = g;
    // INITFIX lanes do not stage (`stage = not(init_fix)`).
    stage[l] = @intFromBool(ok and g.bits & 2 == 0);
    if (stage[l] != 0) flags[l] = 0;
}

/// The loop exit per lane, after the state pass. Under `land_rejects`
/// (every transient) `updateStates` never reports a flip, so a lane that
/// passed leaves INITFIX or converges (x = x_old, as `newton` publishes
/// x_k); a state pass that asked for a reject or set a finite
/// `$bound_step` sets bit 5. A converged or
/// singular lane leaves `active`. Counts the lanes still active into
/// `count[0]` (zeroed by the host), and advances every active lane's
/// `$simparam("iteration")`.
fn finalize(n_lanes: u64, n: u64, iter: P(u32), active: P(u8), stage: P(u8), gate: P(Gate), flags: P(u32), fail: P(u8), x: P(f64), x_old: P(f64), sims: P(SimState), count: P(u32)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes or active[l] == 0) return;
    var g = gate[l];
    if (fail[l] != 0) {
        g.bits |= 8;
        active[l] = 0;
        gate[l] = g;
        return;
    }
    if (stage[l] != 0 and flags[l] & 6 != 0) g.bits |= 32;
    const passed = g.bits & 16 != 0;
    if (passed and g.bits & 2 != 0) {
        g.bits &= ~@as(u32, 2); // INITFIX -> INITFLOAT
    } else if (passed) {
        const N: usize = @intCast(n_lanes);
        for (0..@as(usize, @intCast(n))) |i| x[i * N + l] = x_old[i * N + l];
        g.bits |= 4;
        g.iterations = iter[0] + 1;
        active[l] = 0;
        gate[l] = g;
        return;
    }
    gate[l] = g;
    sims[l].iteration +|= 1;
    _ = @atomicRmw(u32, &count[0], .Add, 1, .monotonic);
}

/// Bumps the device iteration word once per tick.
fn tick(iter: P(u32)) callconv(gompute.kernel_callconv) void {
    if (gompute.globalIdX(block) == 0) iter[0] += 1;
}

/// trial = cur + xfact (cur - prev), per (row, lane), for the lanes in the
/// round (`sc[l].flags & 1`); x_old = cur for the predictor's limit pass.
fn predict(n_lanes: u64, n: u64, sc: P(LaneScalars), cur: P(f64), prev: P(f64), x: P(f64), x_old: P(f64)) callconv(gompute.kernel_callconv) void {
    const tid = gompute.globalIdX(block);
    if (tid >= n * n_lanes) return;
    const l: usize = @intCast(tid % n_lanes);
    if (sc[l].flags & 1 == 0) return;
    const i: usize = @intCast(tid);
    const c = cur[i];
    x[i] = c + sc[l].xfact * (c - prev[i]);
    x_old[i] = c;
}

/// The step's LTE bounds per round lane, from its tape ring (lane-minor:
/// lane l's slot k at `(l * n_hist + k) * n_qt`): `out[l] = { del at the
/// step's method, del of the order-2 promotion probe (order-1 lanes) }`.
fn lte(n_lanes: u64, sc: P(LaneScalars), ring_qt: P(f64), perm_qt: P(u8), ip_qt: P(f64), n_hist: u64, n_qt: u64, lte_in: P(lk.LteIn), out: P([2]f64)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes) return;
    const s = sc[l];
    if (s.flags & 1 == 0) return;
    const nh: usize = @intCast(n_hist);
    const m: usize = @intCast(n_qt);
    const L: usize = l;
    var q: [4]P(f64) = undefined;
    inline for (0..4) |k| q[k] = ring_qt + (L * nh + perm_qt[L * nh + k]) * m;
    const ip = ip_qt + L * m;
    const method: u8 = @intCast(s.method);
    const c = lte_in[l];
    const del = lk.stepBound(method, method, q[0], q[1], q[2], q[3], ip, m, c);
    const del2 = if (method == 0) lk.stepBound(@intCast((s.flags >> 4) & 3), method, q[0], q[1], q[2], q[3], ip, m, c) else del;
    out[l] = .{ del, del2 };
}

/// An accepted step per (row or tape entry, lane), lanes innermost, for
/// the lanes with `accept[l]`: rows `prev <- cur`, `cur <- x`, the q plane
/// into the row ring's logical slot 0, and `advanceCurrent` (`ip = ag0 (q0
/// - q1) - history`) over rows and over the tape. The slots are the
/// pre-rotation ones in `sc[l].sq`/`sqt`; the host has rotated the
/// permutations for the next step already.
fn accept(n_lanes: u64, n: u64, n_qt: u64, n_hist: u64, charge: u64, sc: P(LaneScalars), mask: P(u8), x: P(f64), cur: P(f64), prev: P(f64), q: P(f64), ring: P(f64), ip: P(f64), ring_qt: P(f64), ip_qt: P(f64)) callconv(gompute.kernel_callconv) void {
    const tid = gompute.globalIdX(block);
    if (tid >= (n + n_qt) * n_lanes) return;
    const l: usize = @intCast(tid % n_lanes);
    if (mask[l] == 0) return;
    const s = sc[l];
    const N: usize = @intCast(n_lanes);
    const e: usize = @intCast(tid / n_lanes);
    const nn: usize = @intCast(n);
    if (e < nn) {
        const i = e * N + l;
        prev[i] = cur[i];
        cur[i] = x[i];
        if (charge == 0) return;
        const q0 = q[i];
        ring[(@as(usize, s.sq[0]) * nn + e) * N + l] = q0;
        const q1 = ring[(@as(usize, s.sq[1]) * nn + e) * N + l];
        const q2 = ring[(@as(usize, s.sq[2]) * nn + e) * N + l];
        ip[i] = advance(s, q0, q1, q2, ip[i]);
    } else {
        const j = e - nn;
        const m: usize = @intCast(n_qt);
        const base = l * @as(usize, @intCast(n_hist));
        const q0 = ring_qt[(base + s.sqt[0]) * m + j];
        const q1 = ring_qt[(base + s.sqt[1]) * m + j];
        const q2 = ring_qt[(base + s.sqt[2]) * m + j];
        ip_qt[l * m + j] = advance(s, q0, q1, q2, ip_qt[l * m + j]);
    }
}

/// The stateful-charge re-read of an accepted step per (row or tape entry,
/// lane), for the lanes with `mask[l]`, after the eval at cur and the tape
/// kernel into the tape's logical slot 0: `rebaseCurrent` (`ip += ag0 (q -
/// q1)`) and q into the row ring's logical slot 1, then the same over the
/// tape. Post-rotation slots: rows' logical 1 is `sq[0]`; the tape's
/// logical 0 is `sqt[3]` and logical 1 `sqt[0]`.
fn rebase(n_lanes: u64, n: u64, n_qt: u64, n_hist: u64, sc: P(LaneScalars), mask: P(u8), q: P(f64), ring: P(f64), ip: P(f64), ring_qt: P(f64), ip_qt: P(f64)) callconv(gompute.kernel_callconv) void {
    const tid = gompute.globalIdX(block);
    if (tid >= (n + n_qt) * n_lanes) return;
    const l: usize = @intCast(tid % n_lanes);
    if (mask[l] == 0) return;
    const s = sc[l];
    const N: usize = @intCast(n_lanes);
    const e: usize = @intCast(tid / n_lanes);
    const nn: usize = @intCast(n);
    if (e < nn) {
        const i = e * N + l;
        const r1 = (@as(usize, s.sq[0]) * nn + e) * N + l;
        ip[i] += s.ag0 * (q[i] - ring[r1]);
        ring[r1] = q[i];
    } else {
        const j = e - nn;
        const m: usize = @intCast(n_qt);
        const base = l * @as(usize, @intCast(n_hist));
        ip_qt[l * m + j] += s.ag0 * (ring_qt[(base + s.sqt[3]) * m + j] - ring_qt[(base + s.sqt[0]) * m + j]);
    }
}

/// `integrator.companionAt(m, false, ...)` at one element.
inline fn advance(s: LaneScalars, q0: f64, q1: f64, q2: f64, i_prev: f64) f64 {
    const d = s.ag0 * (q0 - q1);
    return switch (s.method) {
        1 => d - s.ag1 * i_prev,
        2 => d - s.ag2 * (q1 - q2),
        else => d,
    };
}

/// `out[l * n_probes + k] = x[probes[k]]` of lane l, for the lanes in the
/// round.
fn gather(n_lanes: u64, sc: P(LaneScalars), x: P(f64), probes: P(u32), n_probes: u64, out: P(f64)) callconv(gompute.kernel_callconv) void {
    const tid = gompute.globalIdX(block);
    if (tid >= n_probes * n_lanes) return;
    const l: usize = @intCast(tid % n_lanes);
    if (sc[l].flags & 1 == 0) return;
    const k: usize = @intCast(tid / n_lanes);
    out[l * @as(usize, @intCast(n_probes)) + k] = x[@as(usize, probes[k]) * @as(usize, @intCast(n_lanes)) + l];
}

comptime {
    if (gompute.is_device) {
        gompute.exportRaw("arp_lane_refactor", &refactor);
        gompute.exportRaw("arp_lane_solve", &solveNeg);
        gompute.exportRaw("arp_lane_assemble", &assemble);
        gompute.exportRaw("arp_lane_update", &update);
        gompute.exportRaw("arp_lane_gates", &gates);
        gompute.exportRaw("arp_lane_finalize", &finalize);
        gompute.exportRaw("arp_lane_tick", &tick);
        gompute.exportRaw("arp_lane_predict", &predict);
        gompute.exportRaw("arp_lane_lte", &lte);
        gompute.exportRaw("arp_lane_accept", &accept);
        gompute.exportRaw("arp_lane_rebase", &rebase);
        gompute.exportRaw("arp_lane_gather", &gather);
    }
}
