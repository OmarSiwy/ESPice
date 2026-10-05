//! The device LU of dev/solvers/gpu-lu.md, stage 1: a replay of
//! `SparseLu`'s refactor and both triangular solves, written once for the
//! GPU (`lu_device.zig`) and for host threads (`runHost`). Each value slot
//! receives its subtractions in the host's order and no expression is
//! contracted, so the result is bitwise `SparseLu.refactorColumns` followed
//! by `solve`.
//!
//! The refactor is sync-free: one block per pivot step, taken by a u32
//! ticket in pivot order, waiting on the done stamps of the columns it
//! reads (release stores, acquire loads). The only read-modify-writes are
//! the relaxed ticket and the fail word's max, whose result does not depend
//! on order. The solves run in one block: level by level over rows (a
//! gather per row) for the sparse head, then a column sweep over the dense
//! tail, where one row per level would leave every lane but one idle.
//! std only: the kernel root compiles this file for NVPTX and AMDGCN.

const std = @import("std");

/// Lanes per device refactor block. E2 on logic_bsim4_10k and
/// chain_bsim4_10k: 128 or 256 lanes were 1.0-1.8x slower
/// (dev/solvers/gpu-lu.md).
pub const refactor_block = 64;
/// The widest column a refactor block accumulates in shared memory (8
/// bytes a slot); wider columns work in `val`. A 2048-slot scratch (fewer
/// resident blocks) measured slower in the same E2 runs.
pub const col_max = 256;
/// Lanes of the one solve block on the device.
pub const solve_block = 256;
/// Longest solve tail: its y lives in the block's shared memory
/// (`SolveShared`, 40 KB of the 48 KB a block may declare).
pub const tail_max = 5120;
/// `Tab.flags` bit: the step has a fabricated unit pivot
/// (`SparseLu.void_col`).
pub const void_bit: u32 = 1;
/// `Tab.flags` bit: the pivot passed only the row-scaled test
/// (`SparseLu.scaled_pivot`), so the growth monitor skips it.
pub const scaled_bit: u32 = 2;
/// u32 words ahead of the done stamps in the sync buffer: the refactor
/// ticket and the fail word, `n - k` for the lowest failing pivot step k,
/// 0 when every step passed.
pub const sync_header = 2;

/// Offsets (in u32 words) of every table inside the one index buffer, plus
/// the scalars the kernels read. Passed to each kernel by value.
///
/// Values live column-contiguous in `val`: column k is `[U_k, d_k, L_k]`
/// at `coff[k]`, and the last slot (`discard`) absorbs the flops of a void
/// column's rows below its pivot.
pub const Tab = extern struct {
    n: u32,
    discard: u32,
    growth: f64,
    // Refactor.
    coff: u32,
    up: u32,
    lp: u32,
    ui: u32,
    /// Per U entry p (source column i = ui[p]): the first value slot of
    /// L[:,i] and its length.
    ul0: u32,
    ulen: u32,
    flags: u32,
    q: u32,
    col_ptr: u32,
    amap: u32,
    /// Narrow columns: `dmap[dcol[k]..dcol[k+1]]`, the destination slot of
    /// each flop, U entries in stored order.
    dcol: u32,
    dmap: u32,
    /// Wide columns (gather form): levels `wlev[k]..wlev[k+1]`, each a
    /// range of items `lev_ptr`; item i updates slot `g_slot[i]` with the
    /// contributions `g_l[c] * g_u[c]`, c in `g_cptr[i]..g_cptr[i+1]`, in
    /// the host's order. A narrow column has an empty level range.
    wlev: u32,
    lev_ptr: u32,
    g_slot: u32,
    g_cptr: u32,
    g_l: u32,
    g_u: u32,
    /// Solves: pivot steps from `t0` on are the tail, swept column by
    /// column with its y in shared memory. Tail column c (step t0 + c)
    /// reads L entries lp[t0+c].. (rows `li`, values at `t_lb[c] + e`) and
    /// U entries up[t0+c].. (rows `ui`, values at `t_ub[c] + e`, only rows
    /// at or past t0), diagonal slot `t_diag[c]`. The head runs level by
    /// level: `l_rows[l_lev[v]..l_lev[v+1]]` are the rows of forward level
    /// v (tail rows too, for their head part), `u_rows`/`u_lev` the head
    /// rows of the back solve. Row r's head L entries (k < t0, ascending)
    /// are `l_col`/`l_slot` over `l_ptr[r]..`; its U entries (k
    /// descending) `u_col`/`u_slot`.
    t0: u32,
    l_levels: u32,
    u_levels: u32,
    li: u32,
    t_lb: u32,
    t_ub: u32,
    t_diag: u32,
    l_lev: u32,
    l_rows: u32,
    l_ptr: u32,
    l_col: u32,
    l_slot: u32,
    /// perm_in[r] = the original row pivoted at step r.
    perm_in: u32,
    u_lev: u32,
    u_rows: u32,
    u_ptr: u32,
    u_col: u32,
    u_slot: u32,
    /// Length of `val`, `discard` included.
    n_val: u32,
    /// Length of the index buffer.
    n_idx: u32,

    /// u32 words in the sync buffer: header plus one done stamp per
    /// column. Zero it once per table upload.
    pub fn syncLen(t: Tab) u32 {
        return sync_header + t.n;
    }
};

/// The kernel bodies over the pointer type `Sy.P` (a global pointer on the
/// device, a plain one on the host), `Sy.barrier`/`Sy.pause(spins)` and the done
/// stamps' `Sy.acquire`/`Sy.release`. `sh` is
/// the block's shared scratch (a `*Shared`, in the shared address space on
/// the device); `tid`/`nt` are the lane and lane count (0 and 1 on the
/// host), `nt` at most `lanes`.
pub fn Kernels(comptime Sy: type, comptime cap: u32, comptime lanes: u32) type {
    return struct {
        const P = Sy.P;

        /// Refactor block scratch: the ticket, the poll windows' first
        /// unfinished step (two, alternating), the column max per lane, and
        /// the column's working slots (plus a discard slot) when it has at
        /// most `cap`.
        pub const Shared = struct { k: u32, first: [2]u32, red: [lanes]f64, w: [cap + 1]f64 };
        /// Solve block scratch: the tail's y.
        pub const SolveShared = struct { y: [tail_max]f64 };

        inline fn wait(p: anytype, stamp: u32) void {
            var spins: u32 = 0;
            while (Sy.acquire(p) != stamp) : (spins +%= 1) Sy.pause(spins);
        }

        inline fn takeTicket(sy: P(u32), which: u32, sh: anytype, tid: u32) u32 {
            if (tid == 0) sh.k = @atomicRmw(u32, &sy[which], .Add, 1, .monotonic);
            Sy.barrier();
            return sh.k;
        }

        /// Refactors the pivot step its ticket names: zero its slots, scatter
        /// A's column, replay the flops, test and scale the pivot, publish.
        /// Returns false once the tickets run out, so a host thread loops on
        /// it and a device block calls it once.
        pub fn refactor(t: Tab, x: P(u32), val: P(f64), a: P(f64), sy: P(u32), stamp: u32, sh: anytype, tid: u32, nt: u32) bool {
            const k = takeTicket(sy, 0, sh, tid);
            if (k >= t.n) return false;
            const width = x[t.coff + k + 1] - x[t.coff + k];
            const bad = if (width <= cap)
                column(true, &sh.w, t, x, val, a, sy, stamp, sh, tid, nt, k)
            else
                column(false, val, t, x, val, a, sy, stamp, sh, tid, nt, k);
            Sy.barrier();
            if (tid == 0) {
                if (bad) _ = @atomicRmw(u32, &sy[1], .Max, t.n - k, .monotonic);
                Sy.release(&(sy + sync_header)[k], stamp);
            }
            return true;
        }

        /// Lane 0 waits for step p0's source; lane t > 0 checks step
        /// p0 + t's once and records the first unfinished one in
        /// `sh.first[par]`. After the caller's barrier, every source that
        /// read done is visible to the whole block.
        inline fn pollWindow(t: Tab, x: P(u32), done: P(u32), stamp: u32, sh: anytype, par: u1, p0: u32, up1: u32, tid: u32) void {
            const p = p0 + tid;
            if (p >= up1) return;
            const src = &done[x[t.ui + p]];
            if (tid == 0) {
                wait(src, stamp);
            } else if (Sy.acquire(src) != stamp) {
                _ = @atomicRmw(u32, &sh.first[par], .Min, p, .monotonic);
            }
        }

        /// Column k's replay on `w`: the block's scratch (`local`, indexed
        /// from the column's first slot, discard slot last) or `val` itself.
        /// Returns whether a pivot test failed.
        inline fn column(comptime local: bool, w: anytype, t: Tab, x: P(u32), val: P(f64), a: P(f64), sy: P(u32), stamp: u32, sh: anytype, tid: u32, nt: u32, k: u32) bool {
            const done = sy + sync_header;
            const base = x[t.coff + k];
            const width = x[t.coff + k + 1] - base;
            // Column slot s lives at w[o + s]; `at` maps any value slot of
            // this column (or the discard slot) into w.
            const o: u32 = if (local) 0 else base;
            const S = struct {
                inline fn at(dst: u32, b: u32, wd: u32) u32 {
                    return if (local) @min(dst -% b, wd) else dst;
                }
            };
            // No window is open yet: every window slot says "none unfinished".
            if (tid == 0) sh.first = .{ ~@as(u32, 0), ~@as(u32, 0) };
            var s = tid;
            while (s < width) : (s += nt) w[o + s] = 0;
            Sy.barrier();
            const c = x[t.q + k];
            var e = x[t.col_ptr + c] + tid;
            while (e < x[t.col_ptr + c + 1]) : (e += nt) w[S.at(x[t.amap + e], base, width)] = a[e];

            const up0 = x[t.up + k];
            const up1 = x[t.up + k + 1];
            const w0 = x[t.wlev + k];
            const w1 = x[t.wlev + k + 1];
            if (w0 == w1) {
                // Stored U order; the L rows of one U entry are distinct. A
                // step's end barrier doubles as the next one's wait barrier.
                // Sources are polled a window at a time, one lane per step:
                // steps before `ready` need no poll of their own.
                var ready = up0;
                var par: u1 = 0;
                if (up0 < up1) pollWindow(t, x, done, stamp, sh, par, up0, up1, tid);
                Sy.barrier();
                if (up0 < up1) {
                    ready = @max(@min(sh.first[par], up0 + nt), up0 + 1);
                    par ^= 1;
                }
                var d = x[t.dcol + k];
                var p = up0;
                var l0 = if (up0 < up1) x[t.ul0 + up0] else 0;
                var len = if (up0 < up1) x[t.ulen + up0] else 0;
                while (p < up1) : (p += 1) {
                    const u = w[o + p - up0];
                    const more = p + 1 < up1;
                    const nl0 = if (more) x[t.ul0 + p + 1] else 0;
                    const nlen = if (more) x[t.ulen + p + 1] else 0;
                    // Four flops' loads go out before their stores: the
                    // destinations are distinct, but only we know that.
                    const U = 4;
                    var j = tid;
                    while (j + (U - 1) * nt < len) : (j += U * nt) {
                        var dst: [U]u32 = undefined;
                        var lv: [U]f64 = undefined;
                        var wv: [U]f64 = undefined;
                        inline for (0..U) |m| {
                            dst[m] = S.at(x[t.dmap + d + j + m * nt], base, width);
                            lv[m] = val[l0 + j + m * nt];
                        }
                        inline for (0..U) |m| wv[m] = w[dst[m]];
                        inline for (0..U) |m| w[dst[m]] = wv[m] - lv[m] * u;
                    }
                    while (j < len) : (j += nt) {
                        const dst = S.at(x[t.dmap + d + j], base, width);
                        w[dst] -= val[l0 + j] * u;
                    }
                    d += len;
                    const poll = more and p + 1 >= ready;
                    if (poll) pollWindow(t, x, done, stamp, sh, par, p + 1, up1, tid);
                    Sy.barrier();
                    if (poll) {
                        ready = @max(@min(sh.first[par], p + 1 + nt), p + 2);
                        // The other slot was last read before this barrier.
                        if (tid == 0) sh.first[par ^ 1] = ~@as(u32, 0);
                        par ^= 1;
                    }
                    l0 = nl0;
                    len = nlen;
                }
            } else {
                // Gather form: wait for every source once, then per level
                // each item runs its slot's contributions in stored order.
                var p = up0 + tid;
                while (p < up1) : (p += nt) wait(&done[x[t.ui + p]], stamp);
                Sy.barrier();
                var lev = w0;
                while (lev < w1) : (lev += 1) {
                    var it = x[t.lev_ptr + lev] + tid;
                    while (it < x[t.lev_ptr + lev + 1]) : (it += nt) {
                        const slot = S.at(x[t.g_slot + it], base, width);
                        var acc = w[slot];
                        var g = x[t.g_cptr + it];
                        const g1 = x[t.g_cptr + it + 1];
                        // Eight contributions' loads, then their chain.
                        const U = 8;
                        while (g + U <= g1) : (g += U) {
                            var lv: [U]f64 = undefined;
                            var uv: [U]f64 = undefined;
                            inline for (0..U) |m| {
                                lv[m] = val[x[t.g_l + g + m]];
                                uv[m] = w[S.at(x[t.g_u + g + m], base, width)];
                            }
                            inline for (0..U) |m| acc -= lv[m] * uv[m];
                        }
                        while (g < g1) : (g += 1) acc -= val[x[t.g_l + g]] * w[S.at(x[t.g_u + g], base, width)];
                        w[slot] = acc;
                    }
                    Sy.barrier();
                }
            }

            // The pivot tests of `refactorColumns`, in its order.
            const diag = o + up1 - up0;
            const end = o + width;
            const flags = x[t.flags + k];
            var bad = false;
            if (flags & void_bit != 0) {
                if (tid == 0) w[diag] = 1;
                var l = diag + 1 + tid;
                while (l < end) : (l += nt) w[l] = 0;
            } else {
                const dv = w[diag];
                if (dv == 0 or !std.math.isFinite(dv)) {
                    bad = true;
                } else {
                    // cmax is a max: exact in any order, NaN ignored alike.
                    var cm: f64 = @abs(dv);
                    var l = diag + 1 + tid;
                    while (l < end) : (l += nt) {
                        const v = w[l];
                        cm = @max(cm, @abs(v));
                        w[l] = v / dv;
                    }
                    if (t.growth > 0 and flags & scaled_bit == 0) {
                        // A tree over the lanes (nt is a power of two); only
                        // lane 0 reads the verdict.
                        sh.red[tid] = cm;
                        Sy.barrier();
                        var h = nt / 2;
                        while (h > 0) : (h /= 2) {
                            if (tid < h) sh.red[tid] = @max(sh.red[tid], sh.red[tid + h]);
                            Sy.barrier();
                        }
                        bad = @abs(dv) < t.growth * sh.red[0];
                    }
                }
            }
            if (local) {
                Sy.barrier();
                s = tid;
                while (s < width) : (s += nt) val[base + s] = w[s];
            }
            return bad;
        }

        /// Forward solve, the whole of it in one block: y = L^-1 P (-rhs),
        /// each row's subtractions in ascending k, skipping y[k] == 0 as
        /// `SparseLu.solve` does. `sh` is a `*SolveShared`. Does nothing
        /// when the refactor failed.
        pub fn lsolve(t: Tab, x: P(u32), val: P(f64), rhs: P(f64), y: P(f64), sy: P(u32), sh: anytype, tid: u32, nt: u32) void {
            if (sy[1] != 0) return;
            var v: u32 = 0;
            while (v < t.l_levels) : (v += 1) {
                var j = x[t.l_lev + v] + tid;
                while (j < x[t.l_lev + v + 1]) : (j += nt) {
                    const r = x[t.l_rows + j];
                    y[r] = gather(-rhs[x[t.perm_in + r]], x, val, y, t.l_col, t.l_slot, x[t.l_ptr + r], x[t.l_ptr + r + 1]);
                }
                Sy.barrier();
            }
            // The tail sweep, software-pipelined: column c's entries were
            // loaded during step c - 1, its extent during step c - 2, so a
            // step waits on shared memory and the barrier only.
            const tn = t.n - t.t0;
            stage(sh, y + t.t0, tn, tid, nt);
            var mb: Meta = if (tn > 1) metaL(t, x, 1) else .{};
            var ma: Meta = if (tn > 0) metaL(t, x, 0) else .{};
            var cur = fetch(x, val, t.li, t.t0, ma, tid, nt);
            var c: u32 = 0;
            while (c < tn) : (c += 1) {
                const mc: Meta = if (c + 2 < tn) metaL(t, x, c + 2) else .{};
                const nxt = fetch(x, val, t.li, t.t0, mb, tid, nt);
                const yc = sh.y[c];
                if (yc != 0) apply(sh, x, val, t.li, t.t0, tn, ma, cur, yc, tid, nt);
                Sy.barrier();
                ma = mb;
                mb = mc;
                cur = nxt;
            }
            var j = tid;
            while (j < tn) : (j += nt) y[t.t0 + j] = sh.y[j];
        }

        /// Back solve in one block: z = U^-1 y, each row's subtractions in
        /// descending k, and dx[q[i]] = z[i]; y ends holding z. The tail
        /// sweeps its own rows in shared memory; head rows gather their tail
        /// entries afterwards, which is still the host's descending order.
        pub fn usolve(t: Tab, x: P(u32), val: P(f64), y: P(f64), dx: P(f64), sy: P(u32), sh: anytype, tid: u32, nt: u32) void {
            if (sy[1] != 0) return;
            // Pipelined like the forward sweep; one lane divides (a strict
            // divide is dozens of instructions on a narrow unit) and
            // publishes z through shared memory.
            const tn = t.n - t.t0;
            stage(sh, y + t.t0, tn, tid, nt);
            var mb: Meta = if (tn > 1) metaU(t, x, tn - 2) else .{};
            var ma: Meta = if (tn > 0) metaU(t, x, tn - 1) else .{};
            var cur = fetch(x, val, t.ui, t.t0, ma, tid, nt);
            var d: f64 = if (tn > 0) val[ma.diag] else 0;
            var c = tn;
            while (c > 0) {
                c -= 1;
                const mc: Meta = if (c >= 2) metaU(t, x, c - 2) else .{};
                const nxt = fetch(x, val, t.ui, t.t0, mb, tid, nt);
                const dn: f64 = if (c >= 1) val[mb.diag] else 0;
                if (tid == 0) {
                    const zc = sh.y[c] / d;
                    sh.y[c] = zc;
                    dx[ma.q] = zc;
                }
                Sy.barrier();
                const z = sh.y[c];
                if (z != 0) apply(sh, x, val, t.ui, t.t0, tn, ma, cur, z, tid, nt);
                Sy.barrier();
                ma = mb;
                mb = mc;
                cur = nxt;
                d = dn;
            }
            var j = tid;
            while (j < tn) : (j += nt) y[t.t0 + j] = sh.y[j];
            Sy.barrier();
            var v: u32 = 0;
            while (v < t.u_levels) : (v += 1) {
                j = x[t.u_lev + v] + tid;
                while (j < x[t.u_lev + v + 1]) : (j += nt) {
                    const i = x[t.u_rows + j];
                    const acc = gather(y[i], x, val, y, t.u_col, t.u_slot, x[t.u_ptr + i], x[t.u_ptr + i + 1]);
                    const z = acc / val[x[t.coff + i] + x[t.up + i + 1] - x[t.up + i]];
                    y[i] = z;
                    dx[x[t.q + i]] = z;
                }
                Sy.barrier();
            }
        }

        /// Copies the tail's y into the block's scratch.
        inline fn stage(sh: anytype, ytail: P(f64), tn: u32, tid: u32, nt: u32) void {
            var j = tid;
            while (j < tn) : (j += nt) sh.y[j] = ytail[j];
            Sy.barrier();
        }

        /// A tail column's extent: entries e0..e1, values at base +% e, and
        /// for the back sweep its diagonal slot and dx index.
        const Meta = struct { e0: u32 = 0, e1: u32 = 0, base: u32 = 0, diag: u32 = 0, q: u32 = 0 };
        /// Entries per lane loaded a step ahead; any beyond wait for memory.
        const pf = 2;
        const Ent = struct { row: [pf]u32 = undefined, v: [pf]f64 = undefined };

        inline fn metaL(t: Tab, x: P(u32), c: u32) Meta {
            return .{ .e0 = x[t.lp + t.t0 + c], .e1 = x[t.lp + t.t0 + c + 1], .base = x[t.t_lb + c] };
        }

        inline fn metaU(t: Tab, x: P(u32), c: u32) Meta {
            return .{ .e0 = x[t.up + t.t0 + c], .e1 = x[t.up + t.t0 + c + 1], .base = x[t.t_ub + c], .diag = x[t.t_diag + c], .q = x[t.q + t.t0 + c] };
        }

        /// This lane's first `pf` entries of column m: rows relative to t0
        /// (a head row wraps past the tail) and values.
        inline fn fetch(x: P(u32), val: P(f64), rows: u32, t0: u32, m: Meta, tid: u32, nt: u32) Ent {
            var en: Ent = .{};
            inline for (0..pf) |i| {
                const e = m.e0 + tid + i * nt;
                if (e < m.e1) {
                    en.row[i] = x[rows + e] -% t0;
                    en.v[i] = val[m.base +% e];
                }
            }
            return en;
        }

        /// sh.y[row] -= v * f over column m's entries whose row is a tail
        /// row: the prefetched ones, then the rest.
        inline fn apply(sh: anytype, x: P(u32), val: P(f64), rows: u32, t0: u32, tn: u32, m: Meta, en: Ent, f: f64, tid: u32, nt: u32) void {
            inline for (0..pf) |i| {
                if (m.e0 + tid + i * nt < m.e1 and en.row[i] < tn) sh.y[en.row[i]] -= en.v[i] * f;
            }
            var e = m.e0 + tid + pf * nt;
            while (e < m.e1) : (e += nt) {
                const r = x[rows + e] -% t0;
                if (r < tn) sh.y[r] -= val[m.base +% e] * f;
            }
        }

        /// acc minus val[slot[e]] * y[col[e]] for e in e0..e1 in order,
        /// skipping y == 0. Eight entries' loads go out before their
        /// subtractions, so a long row waits on memory once per eight.
        inline fn gather(acc0: f64, x: P(u32), val: P(f64), y: P(f64), col: u32, slot: u32, e0: u32, e1: u32) f64 {
            const U = 8;
            var acc = acc0;
            var e = e0;
            while (e + U <= e1) : (e += U) {
                var yv: [U]f64 = undefined;
                var lv: [U]f64 = undefined;
                inline for (0..U) |u| {
                    yv[u] = y[x[col + e + u]];
                    lv[u] = val[x[slot + e + u]];
                }
                inline for (0..U) |u| acc = if (yv[u] != 0) acc - lv[u] * yv[u] else acc;
            }
            while (e < e1) : (e += 1) {
                const yk = y[x[col + e]];
                if (yk != 0) acc -= val[x[slot + e]] * yk;
            }
            return acc;
        }
    };
}

/// The host instance: plain pointers, a block of one lane.
pub const HostSy = struct {
    /// A plain many-item pointer: host memory has one address space.
    pub fn P(comptime T: type) type {
        return [*]T;
    }
    /// A no-op: a host block is one lane.
    pub inline fn barrier() void {}
    /// Spins briefly, then yields: on a loaded machine the thread holding
    /// the awaited column may be the one descheduled (chain_psp103_10k at
    /// load 98: 16.7 s of pure spinning became 149 s).
    pub inline fn pause(spins: u32) void {
        if (spins < 256) std.atomic.spinLoopHint() else std.Thread.yield() catch {};
    }
    /// Reads a done stamp; pairs with `release`.
    pub inline fn acquire(p: *const u32) u32 {
        return @atomicLoad(u32, p, .acquire);
    }
    /// Publishes a done stamp after the column's stores.
    pub inline fn release(p: *u32, v: u32) void {
        @atomicStore(u32, p, v, .release);
    }
};

/// Host buffers for one `runHost` call; `sync` must be zeroed once after
/// the tables are built, and `stamp` must grow by one per call.
pub const HostBufs = struct {
    idx: []const u32,
    val: []f64,
    a: []const f64,
    rhs: []const f64,
    y: []f64,
    dx: []f64,
    sync: []u32,
};

/// Refactors on `threads` host threads (at most 64) and solves on this one
/// with the kernel bodies: bitwise `refactorColumns` plus `solve` (dx =
/// -A^-1 rhs). Returns the lowest failing pivot step, or null; the solves
/// then leave `y` and `dx` untouched. One thread is the scalar oracle: it
/// takes every ticket in order, so no wait ever spins. A thread that fails
/// to spawn leaves its tickets to the others. Fails only when the solve
/// scratch (40 KB) cannot be allocated.
pub fn runHost(t: Tab, b: HostBufs, stamp: u32, threads: u32) !?u32 {
    return runHostCap(col_max, t, b, stamp, threads);
}

/// `runHost` with the refactor's scratch capped at `cap` slots; 0 runs
/// every column in `val`, the path the device takes past `col_max`.
pub fn runHostCap(comptime cap: u32, t: Tab, b: HostBufs, stamp: u32, threads: u32) !?u32 {
    const H = Kernels(HostSy, cap, 1);
    @memset(b.sync[0..sync_header], 0);
    const x = @constCast(b.idx.ptr);
    const Worker = struct {
        fn work(tt: Tab, bb: HostBufs, st: u32) void {
            var sh: H.Shared = undefined;
            while (H.refactor(tt, @constCast(bb.idx.ptr), bb.val.ptr, @constCast(bb.a.ptr), bb.sync.ptr, st, &sh, 0, 1)) {}
        }
    };
    var pool: [63]std.Thread = undefined;
    const extra = @min(@max(threads, 1) - 1, pool.len);
    // Returning on a failed spawn would free `b` under the running threads.
    var spawned: usize = 0;
    for (pool[0..extra]) |*th| {
        th.* = std.Thread.spawn(.{}, Worker.work, .{ t, b, stamp }) catch break;
        spawned += 1;
    }
    Worker.work(t, b, stamp);
    for (pool[0..spawned]) |th| th.join();
    const ssh = try std.heap.page_allocator.create(H.SolveShared);
    defer std.heap.page_allocator.destroy(ssh);
    H.lsolve(t, x, b.val.ptr, @constCast(b.rhs.ptr), b.y.ptr, b.sync.ptr, ssh, 0, 1);
    H.usolve(t, x, b.val.ptr, b.y.ptr, b.dx.ptr, b.sync.ptr, ssh, 0, 1);
    const f = b.sync[1];
    return if (f == 0) null else t.n - f;
}

// ---------------------------------------------------------------------------
// Tables, built on the host from a factored SparseLu.

const SparseLu = @import("sparse_lu.zig").SparseLu;

/// The refactor kernel body on host threads: one pivot epoch's tables and
/// buffers.
const HostFactor = struct {
    const Self = @This();
    const H = Kernels(HostSy, col_max, 1);

    /// `SparseLu.pattern_epoch` the tables were built from.
    epoch: u32,
    tb: Tables,
    val: []f64,
    sync: []u32,
    stamp: u32 = 0,

    /// Builds the tables for `lu`'s current factor (4 bytes per flop).
    /// Caller owns the result; free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, lu: *const SparseLu, col_ptr: []const u32, growth: f64) !Self {
        var tb = try build(gpa, lu, col_ptr, growth, .{});
        errdefer tb.deinit(gpa);
        const val = try gpa.alloc(f64, tb.tab.n_val);
        errdefer gpa.free(val);
        const sync = try gpa.alloc(u32, tb.tab.syncLen());
        @memset(sync, 0);
        return .{ .epoch = lu.pattern_epoch, .tb = tb, .val = val, .sync = sync };
    }

    /// Frees the tables and buffers; `self` is undefined afterwards.
    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.tb.deinit(gpa);
        gpa.free(self.val);
        gpa.free(self.sync);
        self.* = undefined;
    }

    /// Refactors `a` (A's values in CSC order) on the caller plus
    /// `threads - 1` tasks of `io` (none when null). False when a pivot
    /// test fails; the factors are then unusable.
    pub fn refactor(self: *Self, a: []const f64, io: ?std.Io, threads: u32) bool {
        const W = struct {
            fn work(t: Tab, x: [*]u32, val: [*]f64, av: [*]f64, sy: [*]u32, stamp: u32) void {
                var sh: H.Shared = undefined;
                while (H.refactor(t, x, val, av, sy, stamp, &sh, 0, 1)) {}
            }
        };
        self.stamp +%= 1;
        @memset(self.sync[0..sync_header], 0);
        const args = .{ self.tb.tab, self.tb.idx.ptr, self.val.ptr, @constCast(a.ptr), self.sync.ptr, self.stamp };
        var futures: [15]std.Io.Future(void) = undefined;
        const extra = if (io != null) @min(@max(threads, 1) - 1, futures.len) else 0;
        for (futures[0..extra]) |*f| f.* = io.?.async(W.work, args);
        @call(.auto, W.work, args);
        for (futures[0..extra]) |*f| f.await(io.?);
        return self.sync[1] == 0;
    }
};

/// The refactor kernel body as a multicore host refactor (dev/solvers/
/// gpu-lu.md option 3). Its factors are bitwise `SparseLu.refactor`'s, so
/// callers may pick it by speed.
pub const HostRefactor = struct {
    f: HostFactor,

    /// Builds the tables for `lu`'s current factor (4 bytes per flop).
    /// Caller owns the result; free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, lu: *const SparseLu, col_ptr: []const u32, growth: f64) !HostRefactor {
        return .{ .f = try .init(gpa, lu, col_ptr, growth) };
    }

    /// Frees the tables and buffers; `lu` stays the caller's.
    pub fn deinit(self: *HostRefactor, gpa: std.mem.Allocator) void {
        self.f.deinit(gpa);
    }

    /// `lu.refactor(col_ptr, vals, growth)` on the caller plus
    /// `threads - 1` tasks of `io`, then the factors copied into `lu`.
    /// Fails exactly when `refactor` would, and `lu`'s factors are then
    /// unusable, as after a failed `refactor`. Asserts that `lu` is factored
    /// on the epoch the tables were built from.
    pub fn run(self: *HostRefactor, lu: *SparseLu, vals: []const f64, io: std.Io, threads: u32) error{SingularMatrix}!void {
        std.debug.assert(lu.factored and lu.pattern_epoch == self.f.epoch);
        for (lu.void_slots.items) |p| {
            if (vals[p] != 0) return error.SingularMatrix;
        }
        if (!self.f.refactor(vals, io, threads)) return error.SingularMatrix;
        const t = self.f.tb.tab;
        const x = self.f.tb.idx;
        const val = self.f.val;
        for (0..t.n) |k| {
            const base = x[t.coff + k];
            const nuk = lu.up[k + 1] - lu.up[k];
            const nlk = lu.lp[k + 1] - lu.lp[k];
            @memcpy(lu.ux.items[lu.up[k]..][0..nuk], val[base..][0..nuk]);
            lu.udiag[k] = val[base + nuk];
            @memcpy(lu.lx.items[lu.lp[k]..][0..nlk], val[base + nuk + 1 ..][0..nlk]);
        }
    }
};

/// Flop-latency units per barrier (plus the done wait) in the per-column
/// cost that picks the gather form: a U entry of the stored-order form
/// costs `step_cost + ceil(len / lanes)`, a gather level `level_cost` plus
/// its longest contribution chain. ponytail: fixed guesses; fit them from
/// E2's per-column timings if the choice matters.
const step_cost = 4;
const level_cost = 2;
/// Columns with fewer U entries skip the gather analysis.
const gather_min_u = 32;

/// Overrides of `build`'s own choices, for tests and E2 calibration.
pub const Options = struct {
    /// The solves' tail cut t0.
    tail: ?u32 = null,
    /// False keeps every column in stored order.
    gather: bool = true,
};

/// The device tables of one pivot epoch.
pub const Tables = struct {
    tab: Tab,
    /// Every u32 table, at the offsets in `tab`. Owned; free with `deinit`.
    idx: []u32,

    /// Frees `idx`; `self` is undefined afterwards.
    pub fn deinit(self: *Tables, gpa: std.mem.Allocator) void {
        gpa.free(self.idx);
        self.* = undefined;
    }
};

/// Builds the tables for `lu`'s current factor. O(F + nnz(L+U)) time; the
/// narrow columns' `dmap` is 4 bytes per flop. Asserts a successful
/// `factor` and a tail of at most `tail_max` steps. `OutOfMemory` also
/// means the tables passed u32 offsets. Caller owns the result; free with
/// `Tables.deinit`. A later `factor` of `lu` (new `pattern_epoch`) makes
/// them stale.
pub fn build(gpa: std.mem.Allocator, lu: *const SparseLu, col_ptr: []const u32, growth: f64, opt: Options) !Tables {
    const lanes = refactor_block;
    std.debug.assert(lu.factored);
    const n = lu.n;
    const lp = lu.lp;
    const up = lu.up;
    const li = lu.li.items;
    const ui = lu.ui.items;
    const nu: u32 = @intCast(ui.len);
    const nnz = col_ptr[n];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    const coff = try ar.alloc(u32, n + 1);
    for (0..n + 1) |k| coff[k] = up[k] + lp[k] + @as(u32, @intCast(k));
    const n_val = coff[n] + 1;
    const discard = coff[n];

    const ul0 = try ar.alloc(u32, nu);
    const ulen = try ar.alloc(u32, nu);
    for (ui, ul0, ulen) |i, *l0, *ln| {
        l0.* = coff[i] + up[i + 1] - up[i] + 1;
        ln.* = lp[i + 1] - lp[i];
    }
    const flags = try ar.alloc(u32, n);
    for (flags, 0..) |*f, k| f.* = (if (lu.void_col[k]) void_bit else 0) | (if (lu.scaled_pivot[k]) scaled_bit else 0);

    // Row -> slot of the current column, as in `buildTape`.
    const pos = try ar.alloc(u32, n);
    const amap = try ar.alloc(u32, nnz);
    const dcol = try ar.alloc(u32, n + 1);
    const wlev = try ar.alloc(u32, n + 1);
    var dmap: std.ArrayList(u32) = .empty;
    var lev_ptr: std.ArrayList(u32) = .empty;
    try lev_ptr.append(ar, 0);
    var g_slot: std.ArrayList(u32) = .empty;
    var g_cptr: std.ArrayList(u32) = .empty;
    try g_cptr.append(ar, 0);
    var g_l: std.ArrayList(u32) = .empty;
    var g_u: std.ArrayList(u32) = .empty;
    // Gather scratch, per column slot (relative to coff[k]).
    const lvl = try ar.alloc(u32, n_val);
    const cnt = try ar.alloc(u32, n_val);
    for (0..n) |kk| {
        const k: u32 = @intCast(kk);
        const void_k = lu.void_col[k];
        const base = coff[k];
        const nuk = up[k + 1] - up[k];
        for (up[k]..up[k + 1]) |p| pos[ui[p]] = base + @as(u32, @intCast(p)) - up[k];
        pos[k] = base + nuk;
        for (lp[k]..lp[k + 1]) |q| pos[li[q]] = base + nuk + 1 + @as(u32, @intCast(q)) - lp[k];
        const c = lu.q[k];
        for (col_ptr[c]..col_ptr[c + 1]) |e| {
            const r = lu.prow[e];
            amap[e] = if (void_k and r > k) discard else pos[r];
        }
        dcol[k] = @intCast(dmap.items.len);
        wlev[k] = @intCast(lev_ptr.items.len - 1);

        var col_flops: u64 = 0;
        var pseq: u64 = 0;
        for (up[k]..up[k + 1]) |p| {
            const len = lp[ui[p] + 1] - lp[ui[p]];
            col_flops += len;
            pseq += step_cost + (len + lanes - 1) / lanes;
        }

        const gathered = opt.gather and nuk >= gather_min_u and try gatherColumn(ar, lu, k, base, coff[k + 1] - base, pos, lvl, cnt, pseq, &lev_ptr, &g_slot, &g_cptr, &g_l, &g_u);
        if (!gathered) {
            try dmap.ensureUnusedCapacity(ar, std.math.cast(usize, col_flops) orelse return error.OutOfMemory);
            for (up[k]..up[k + 1]) |p| {
                const i = ui[p];
                for (lp[i]..lp[i + 1]) |q| {
                    const r = li[q];
                    dmap.appendAssumeCapacity(if (void_k and r > k) discard else pos[r]);
                }
            }
        }
    }
    dcol[n] = @intCast(dmap.items.len);
    wlev[n] = @intCast(lev_ptr.items.len - 1);

    // Solve row lists: L by rows with k ascending, U by rows with k
    // descending (the host's per-row orders).
    const perm_in = try ar.alloc(u32, n);
    for (lu.pinv, 0..) |r, o| perm_in[r] = @intCast(o);
    const u_ptr = try ar.alloc(u32, n + 1);
    const u_col = try ar.alloc(u32, nu);
    const u_slot = try ar.alloc(u32, nu);
    @memset(u_ptr, 0);
    for (ui) |i| u_ptr[i + 1] += 1;
    for (0..n) |i| u_ptr[i + 1] += u_ptr[i];
    @memset(pos, 0);
    var kd = n;
    while (kd > 0) {
        kd -= 1;
        for (up[kd]..up[kd + 1]) |p| {
            const i = ui[p];
            const at = u_ptr[i] + pos[i];
            pos[i] += 1;
            u_col[at] = kd;
            u_slot[at] = coff[kd] + @as(u32, @intCast(p - up[kd]));
        }
    }

    // The tail cut: the cheapest of t0 = n, n - 16, n - 32, ..., down to
    // n - tail_max.
    const level = try ar.alloc(u32, n);
    const len = try ar.alloc(u32, n);
    const scratch = try ar.alloc(u32, 2 * @as(usize, n) + 2);
    var t0 = n;
    if (opt.tail) |cut| t0 = cut else {
        var best = solveCost(lu, n, level, len, scratch);
        var m: u32 = 16;
        while (m <= @min(n, tail_max)) : (m *= 2) {
            const c = solveCost(lu, n - m, level, len, scratch);
            if (c < best) {
                best = c;
                t0 = n - m;
            }
        }
    }
    std.debug.assert(n - t0 <= tail_max);
    const l_levels = headLevels(lu, t0, false, level, len);
    const l_sched = try bucket(ar, level[0..n], l_levels);
    const u_levels = headLevels(lu, t0, true, level, len);
    const u_sched = try bucket(ar, level[0..t0], u_levels);
    // L rows keep their head entries only (k < t0); the sweep does the rest.
    const nl_head = lp[t0];
    const l_ptr = try ar.alloc(u32, n + 1);
    const l_col = try ar.alloc(u32, nl_head);
    const l_slot = try ar.alloc(u32, nl_head);
    @memset(l_ptr, 0);
    for (li[0..nl_head]) |r| l_ptr[r + 1] += 1;
    for (0..n) |r| l_ptr[r + 1] += l_ptr[r];
    @memset(pos, 0);
    for (0..t0) |k| for (lp[k]..lp[k + 1]) |q| {
        const r = li[q];
        const at = l_ptr[r] + pos[r];
        pos[r] += 1;
        l_col[at] = @intCast(k);
        l_slot[at] = coff[k] + up[k + 1] - up[k] + 1 + @as(u32, @intCast(q - lp[k]));
    };
    const tn = n - t0;
    const t_lb = try ar.alloc(u32, tn);
    const t_ub = try ar.alloc(u32, tn);
    const t_diag = try ar.alloc(u32, tn);
    for (t0..n, 0..) |k, c| {
        const nuk = up[k + 1] - up[k];
        t_diag[c] = coff[k] + nuk;
        t_lb[c] = (coff[k] + nuk + 1) -% lp[k];
        t_ub[c] = coff[k] -% up[k];
    }

    // Concatenate, each table at the Tab field of its name.
    const parts = .{
        .{ "coff", coff },           .{ "up", up },                 .{ "lp", lp },
        .{ "ui", ui },               .{ "ul0", ul0 },               .{ "ulen", ulen },
        .{ "flags", flags },         .{ "q", lu.q },                .{ "col_ptr", col_ptr[0 .. n + 1] },
        .{ "amap", amap },           .{ "dcol", dcol },             .{ "dmap", dmap.items },
        .{ "wlev", wlev },           .{ "lev_ptr", lev_ptr.items }, .{ "g_slot", g_slot.items },
        .{ "g_cptr", g_cptr.items }, .{ "g_l", g_l.items },         .{ "g_u", g_u.items },
        .{ "li", li },               .{ "t_lb", t_lb },             .{ "t_ub", t_ub },
        .{ "t_diag", t_diag },       .{ "l_lev", l_sched.lev },     .{ "l_rows", l_sched.rows },
        .{ "l_ptr", l_ptr },         .{ "l_col", l_col },           .{ "l_slot", l_slot },
        .{ "perm_in", perm_in },     .{ "u_lev", u_sched.lev },     .{ "u_rows", u_sched.rows },
        .{ "u_ptr", u_ptr },         .{ "u_col", u_col },           .{ "u_slot", u_slot },
    };
    var tab: Tab = undefined;
    tab.n = n;
    tab.discard = discard;
    tab.growth = growth;
    tab.t0 = t0;
    tab.l_levels = l_levels;
    tab.u_levels = u_levels;
    tab.n_val = n_val;
    var total: usize = 0;
    inline for (parts) |part| {
        @field(tab, part[0]) = std.math.cast(u32, total) orelse return error.OutOfMemory;
        total += part[1].len;
    }
    tab.n_idx = std.math.cast(u32, total) orelse return error.OutOfMemory;
    const idx = try gpa.alloc(u32, total);
    inline for (parts) |part| @memcpy(idx[@field(tab, part[0])..][0..part[1].len], part[1]);
    return .{ .idx = idx, .tab = tab };
}

/// Solve-cost units (one dependent load or flop on the device) per head
/// level (a barrier and the index loads before the first y load) and per
/// tail column (a barrier and one load). ponytail: fixed guesses, like the
/// gather costs above; fit them from E2 if the cut matters.
const head_level_cost = 4;
const tail_step_cost = 3;

/// Levels of the head schedule for tail cut t0 into `level` (rows below
/// t0 for U, all rows for L, whose tail rows run their head part) and the
/// head entries per row into `len`. Returns the level count.
fn headLevels(lu: *const SparseLu, t0: u32, comptime upper: bool, level: []u32, len: []u32) u32 {
    const rows: u32 = if (upper) t0 else lu.n;
    @memset(level[0..rows], 0);
    @memset(len[0..rows], 0);
    var levels: u32 = @intFromBool(rows > 0);
    if (upper) {
        var k = t0;
        while (k > 0) {
            k -= 1;
            for (lu.ui.items[lu.up[k]..lu.up[k + 1]]) |i| {
                level[i] = @max(level[i], level[k] + 1);
                len[i] += 1;
                levels = @max(levels, level[i] + 1);
            }
        }
    } else for (0..t0) |k| for (lu.li.items[lu.lp[k]..lu.lp[k + 1]]) |r| {
        level[r] = @max(level[r], level[k] + 1);
        len[r] += 1;
        levels = @max(levels, level[r] + 1);
    };
    return levels;
}

/// Estimated span of both solves for tail cut t0: per head level its
/// barrier, its longest row and its rows over the lanes; per tail column
/// its step and its entries over the lanes.
fn solveCost(lu: *const SparseLu, t0: u32, level: []u32, len: []u32, scratch: []u32) u64 {
    const lanes = solve_block;
    var cost: u64 = 0;
    inline for (.{ false, true }) |upper| {
        const levels = headLevels(lu, t0, upper, level, len);
        const width = scratch[0..levels];
        const chain = scratch[levels..][0..levels];
        @memset(width, 0);
        @memset(chain, 0);
        const rows: u32 = if (upper) t0 else lu.n;
        for (level[0..rows], len[0..rows]) |v, l| {
            width[v] += 1;
            chain[v] = @max(chain[v], l);
        }
        for (width, chain) |w, c| cost += head_level_cost + c + (w + lanes - 1) / lanes;
        for (t0..lu.n) |k| {
            const cnt = if (upper) lu.up[k + 1] - lu.up[k] else lu.lp[k + 1] - lu.lp[k];
            cost += tail_step_cost + (cnt + lanes - 1) / lanes;
        }
    }
    return cost;
}

/// Rows grouped by level: `rows[lev[v]..lev[v+1]]` is level v.
fn bucket(ar: std.mem.Allocator, level: []const u32, levels: u32) !struct { rows: []u32, lev: []u32 } {
    const lev = try ar.alloc(u32, levels + 1);
    @memset(lev, 0);
    for (level) |v| lev[v + 1] += 1;
    for (0..levels) |v| lev[v + 1] += lev[v];
    const rows = try ar.alloc(u32, level.len);
    const cur = try ar.dupe(u32, lev[0..levels]);
    for (level, 0..) |v, r| {
        rows[cur[v]] = @intCast(r);
        cur[v] += 1;
    }
    return .{ .rows = rows, .lev = lev };
}

/// Builds column k's gather form when its span estimate beats the stored
/// order's (`pseq`); returns false, appending nothing, otherwise. A slot's
/// level is one past the deepest U slot it reads; slots with no
/// contribution and a void column's flops below the pivot are left out.
fn gatherColumn(
    ar: std.mem.Allocator,
    lu: *const SparseLu,
    k: u32,
    base: u32,
    width: u32,
    pos: []const u32,
    lvl: []u32,
    cnt: []u32,
    pseq: u64,
    lev_ptr: *std.ArrayList(u32),
    g_slot: *std.ArrayList(u32),
    g_cptr: *std.ArrayList(u32),
    g_l: *std.ArrayList(u32),
    g_u: *std.ArrayList(u32),
) !bool {
    const up = lu.up;
    const lp = lu.lp;
    const li = lu.li.items;
    const ui = lu.ui.items;
    const void_k = lu.void_col[k];
    const L = lvl[0..width];
    const C = cnt[0..width];
    @memset(L, 0);
    @memset(C, 0);
    const lstart = struct {
        fn f(l: *const SparseLu, i: u32) u32 {
            return l.up[i] + l.lp[i] + i + l.up[i + 1] - l.up[i] + 1;
        }
    }.f;
    // Levels and chain lengths, in stored U order.
    var depth: u32 = 0;
    for (up[k]..up[k + 1]) |p| {
        const i = ui[p];
        const lu_p = L[@as(u32, @intCast(p)) - up[k]];
        for (lp[i]..lp[i + 1]) |q| {
            const r = li[q];
            if (void_k and r > k) continue;
            const s = pos[r] - base;
            L[s] = @max(L[s], lu_p + 1);
            C[s] += 1;
            depth = @max(depth, L[s]);
        }
    }
    // Per level: the longest chain.
    const chain = try ar.alloc(u32, depth + 1);
    defer ar.free(chain);
    @memset(chain, 0);
    const per = try ar.alloc(u32, depth + 2);
    defer ar.free(per);
    @memset(per, 0);
    for (L, C) |l, cn| if (cn > 0) {
        chain[l] = @max(chain[l], cn);
        per[l + 1] += 1;
    };
    var gcost: u64 = level_cost;
    for (chain[1..]) |ch| gcost += level_cost + ch;
    // depth 0: every flop hits the discard slot; the stored-order form
    // (whose dmap must cover them) is as cheap.
    if (depth == 0 or gcost >= pseq) return false;

    // Items grouped by level (1..depth); contributions per item in stored
    // U order. `per` becomes each level's item cursor, C each item's.
    for (1..depth + 1) |l| per[l + 1] += per[l];
    const item0: u32 = @intCast(g_slot.items.len);
    const n_items = per[depth + 1];
    const slot_item = try ar.alloc(u32, width);
    defer ar.free(slot_item);
    try g_slot.resize(ar, item0 + n_items);
    for (L, C, 0..) |l, cn, s| if (cn > 0) {
        const it = per[l];
        per[l] += 1;
        slot_item[s] = it;
        g_slot.items[item0 + it] = base + @as(u32, @intCast(s));
    };
    // Levels' item ranges: per[l] now ends level l, i.e. starts level l+1.
    for (1..depth + 1) |l| try lev_ptr.append(ar, item0 + per[l]);
    // Contribution offsets per item.
    const c0: u32 = @intCast(g_l.items.len);
    const cptr0 = g_cptr.items.len - 1; // g_cptr[item0] exists
    try g_cptr.resize(ar, cptr0 + 1 + n_items);
    const cp = g_cptr.items[cptr0..];
    for (L, C, 0..) |_, cn, s| if (cn > 0) {
        cp[slot_item[s] + 1] = cn;
    };
    cp[0] = c0;
    for (0..n_items) |it| cp[it + 1] += cp[it];
    try g_l.resize(ar, cp[n_items]);
    try g_u.resize(ar, cp[n_items]);
    @memset(C, 0);
    for (up[k]..up[k + 1]) |p| {
        const i = ui[p];
        const l0 = lstart(lu, i);
        for (lp[i]..lp[i + 1]) |q| {
            const r = li[q];
            if (void_k and r > k) continue;
            const s = pos[r] - base;
            const at = cp[slot_item[s]] + C[s];
            C[s] += 1;
            g_l.items[at] = l0 + @as(u32, @intCast(q - lp[i]));
            g_u.items[at] = base + @as(u32, @intCast(p)) - up[k];
        }
    }
    return true;
}
