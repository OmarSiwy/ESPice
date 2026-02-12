//! DEV-ONLY measurement harness for the sparse LU refactor kernel. Not part
//! of any build; run standalone:
//!   zig run -OReleaseFast -fllvm -mcpu=native src/solvers/dev_harness.zig -- /tmp/zplu-fba.bin [reps]
//! Input: ZP_LU_DUMP binary (magic,n,nnz,col_ptr,row_idx,q,vals) captured
//! from a real fixture run. Reports L-column run-length structure (as-stored
//! and sorted, flop-weighted) and a refactor microbench.
const std = @import("std");
const sparse_lu = @import("sparse_lu.zig");

const Lu = sparse_lu.SparseLu(f64);

// Defeat LLVM's memset loop-idiom (a splat-of-comptime-zero store loop with
// runtime trip count becomes a memset CALL — 66.6M Ir / 252,705 calls on the
// fourbitadder fixture, see docs/solvers/refactor-tape-2026-09.md): splatting
// a volatile-loaded zero keeps the variant zero loops as inline vector stores.
var opaque_zero: f64 = 0;
inline fn zedV(comptime N: usize) @Vector(N, f64) {
    return @splat(@as(*const volatile f64, &opaque_zero).*);
}

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn typedCopy(comptime E: type, gpa: std.mem.Allocator, bytes: []const u8, count: usize) ![]E {
    const out = try gpa.alloc(E, count);
    @memcpy(std.mem.sliceAsBytes(out), bytes[0 .. count * @sizeOf(E)]);
    return out;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var it = init.minimal.args.iterate();
    _ = it.skip();
    const path = it.next() orelse "/tmp/zplu-fba.bin";
    const reps: usize = if (it.next()) |r| try std.fmt.parseInt(usize, r, 10) else 2000;

    const blob = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    const hdr = std.mem.bytesToValue([3]u32, blob[0..12]);
    if (hdr[0] != 0x5A504C55) return error.BadMagic;
    const n = hdr[1];
    const nnz = hdr[2];
    var off: usize = 12;
    const col_ptr = try typedCopy(u32, gpa, blob[off..], n + 1);
    off += (n + 1) * 4;
    const row_idx = try typedCopy(u32, gpa, blob[off..], nnz);
    off += nnz * 4;
    const q = try typedCopy(u32, gpa, blob[off..], n);
    off += n * 4;
    const vals = try typedCopy(f64, gpa, blob[off..], nnz);

    var lu = try Lu.init(gpa, n, col_ptr, row_idx, q);
    try lu.factor(gpa, col_ptr, row_idx, vals, 1e-3);
    std.debug.print("n={d} nnz={d} L={d} U={d}\n", .{ n, nnz, lu.li.items.len, lu.ui.items.len });

    // sort each L column ascending by row (co-moving values) — the layout the
    // kernel plan establishes in factor(); harness applies it here.
    for (0..n) |k| {
        const lo = lu.lp[k];
        const hi = lu.lp[k + 1];
        const Ctx = struct {
            idx: []u32,
            vals: []f64,
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return ctx.idx[a] < ctx.idx[b];
            }
            pub fn swap(ctx: @This(), a: usize, b: usize) void {
                std.mem.swap(u32, &ctx.idx[a], &ctx.idx[b]);
                std.mem.swap(f64, &ctx.vals[a], &ctx.vals[b]);
            }
        };
        std.sort.pdqContext(0, hi - lo, Ctx{
            .idx = lu.li.items[lo..hi],
            .vals = lu.lx.items[lo..hi],
        });
    }

    // ---- use counts: how many times each L column is walked per refactor ----
    const use_count = try gpa.alloc(u32, n);
    @memset(use_count, 0);
    for (lu.ui.items) |i| use_count[i] += 1;
    // normalize/zero walks touch each L column once more
    for (use_count) |*u| u.* += 1;

    // ---- run-length structure, as-stored and sorted ----
    var flops_total: u64 = 0;
    var flops_in_runs_stored: u64 = 0; // flop-weighted elements covered by full W-runs
    const W = 4;
    var col_len_hist = [_]u64{0} ** 9; // 0,1,2,3,4-7,8-15,16-31,32-63,64+

    for (0..n) |k| {
        const lo = lu.lp[k];
        const hi = lu.lp[k + 1];
        const len = hi - lo;
        const uses: u64 = use_count[k];
        flops_total += uses * len;
        col_len_hist[lenBucket(len)] += 1;

        flops_in_runs_stored += uses * runCovered(u32, lu.li.items[lo..hi], W);
    }

    std.debug.print("L col len hist (0,1,2,3,4-7,8-15,16-31,32-63,64+): {any}\n", .{col_len_hist});
    std.debug.print("axpy+norm elements (flop-weighted): {d}\n", .{flops_total});
    std.debug.print("covered by {d}-runs  as-stored: {d} ({d:.1}%)  sorted: {d} ({d:.1}%)\n", .{
        W,
        flops_in_runs_stored,
        pct(flops_in_runs_stored, flops_total),
        flops_in_runs_stored,
        pct(flops_in_runs_stored, flops_total),
    });

    // ---- LOCAL-coordinate run coverage: axpy targets ranked within the
    // sorted active set of column k (U rows ++ k ++ L rows). The active set
    // removes the holes between global rows — this is the relative-index /
    // local-dense-front formulation. ----
    {
        const rankmap = try gpa.alloc(u16, n);
        const active = try gpa.alloc(u32, n);
        const locs = try gpa.alloc(u16, n);
        var ax_total: u64 = 0;
        var ax_run4: u64 = 0;
        var ax_run2: u64 = 0;
        var ax_run8: u64 = 0;
        var op_cnt = [_]u64{0} ** 4; // greedy 8/4/2/1 ops
        var m_max: u32 = 0;
        for (0..n) |k| {
            // active set: sorted U steps ++ k ++ sorted L rows
            var m: u32 = 0;
            for (lu.ui.items[lu.up[k]..lu.up[k + 1]]) |i| {
                active[m] = i;
                m += 1;
            }
            std.mem.sort(u32, active[0..m], {}, std.sort.asc(u32));
            active[m] = @intCast(k);
            m += 1;
            const lstart = m;
            for (lu.li.items[lu.lp[k]..lu.lp[k + 1]]) |r| {
                active[m] = r;
                m += 1;
            }
            std.mem.sort(u32, active[lstart..m], {}, std.sort.asc(u32));
            m_max = @max(m_max, m);
            for (active[0..m], 0..) |x, rank| rankmap[x] = @intCast(rank);

            for (lu.ui.items[lu.up[k]..lu.up[k + 1]]) |i| {
                const lo = lu.lp[i];
                const len = lu.lp[i + 1] - lo;
                for (lu.li.items[lo..][0..len], locs[0..len]) |r, *lc| lc.* = rankmap[r];
                // plan sorts L columns ascending -> rank sequence ascending
                std.mem.sort(u16, locs[0..len], {}, std.sort.asc(u16));
                ax_total += len;
                ax_run4 += runCovered(u16, locs[0..len], 4);
                ax_run2 += runCovered(u16, locs[0..len], 2);
                ax_run8 += runCovered(u16, locs[0..len], 8);
                // greedy 8/4/2/1 decomposition op counts
                var jj: usize = 0;
                while (jj < len) {
                    inline for (.{ 8, 4, 2 }, 0..) |RW, ci| {
                        if (jj + RW <= len and locs[jj + RW - 1] == locs[jj] + (RW - 1)) {
                            op_cnt[ci] += 1;
                            jj += RW;
                            break;
                        }
                    } else {
                        op_cnt[3] += 1;
                        jj += 1;
                    }
                }
            }
        }
        std.debug.print("LOCAL coords: axpy elements={d}  4-run {d} ({d:.1}%)  2-run {d} ({d:.1}%)  8-run {d} ({d:.1}%)  m_max={d}\n", .{
            ax_total, ax_run4, pct(ax_run4, ax_total), ax_run2, pct(ax_run2, ax_total), ax_run8, pct(ax_run8, ax_total), m_max,
        });
        std.debug.print("greedy 8/4/2/1 ops: {any} (total {d} ops vs {d} scalar)\n", .{
            op_cnt, op_cnt[0] + op_cnt[1] + op_cnt[2] + op_cnt[3], ax_total,
        });
    }

    // U-column length stats (axpy trip counts come from U entries too)
    const u_entries: u64 = lu.ui.items.len;
    std.debug.print("U entries={d} (axpy invocations/refactor), avg L col walked={d:.1}\n", .{
        u_entries,
        @as(f64, @floatFromInt(flops_total)) / @as(f64, @floatFromInt(u_entries + n)),
    });

    // ---- local-dense prototype: tape build + scalar + run-split variants ----
    const tape = try buildTape(gpa, &lu, col_ptr);
    std.debug.print("tape: flop={d} u16 ({d} KB) + uloc {d} + aloc {d}\n", .{
        tape.loc.len, tape.loc.len * 2 / 1024, tape.uloc.len, tape.aloc.len,
    });

    // reference factors from the existing refactor (pad excluded)
    const l_len = lu.li.items.len;
    try lu.refactor(col_ptr, vals, 1e-12);
    const lx_ref = try gpa.dupe(f64, lu.lx.items[0..l_len]);
    const ux_ref = try gpa.dupe(f64, lu.ux.items);
    const ud_ref = try gpa.dupe(f64, lu.udiag);

    const rtape = try buildRTape(gpa, &lu, tape);
    std.debug.print("rtape: ops={d} ({d} KB) cnts={d}\n", .{ rtape.ops.len, rtape.ops.len * 4 / 1024, rtape.cnts.len });
    const mtape = try buildMTape(gpa, &lu, tape);
    const rtape2 = try buildRTape2(gpa, &lu, tape);
    // pad lx so uniform 4-wide op loads can over-read the last column tail
    try lu.lx.appendNTimes(gpa, 0, 3);

    const wloc = try gpa.alloc(f64, rtape.m_pad + 8);
    inline for (.{ 1, 4 }) |WV| {
        // scramble factors so a pass can't coast on stale values
        @memset(lu.lx.items, 99.0);
        @memset(lu.ux.items, 99.0);
        try refactorLocal(WV, &lu, tape, col_ptr, vals, 1e-12, wloc);
        try expectBitEq(lu.lx.items[0..l_len], lx_ref);
        try expectBitEq(lu.ux.items, ux_ref);
        try expectBitEq(lu.udiag, ud_ref);
        std.debug.print("refactorLocal(W={d}): bit-identical to refactor\n", .{WV});
    }
    {
        @memset(lu.lx.items, 99.0);
        @memset(lu.ux.items, 99.0);
        try refactorEncoded(&lu, rtape, col_ptr, vals, 1e-12, wloc);
        try expectBitEq(lu.lx.items[0..l_len], lx_ref);
        try expectBitEq(lu.ux.items, ux_ref);
        try expectBitEq(lu.udiag, ud_ref);
        std.debug.print("refactorRTape: bit-identical to refactor\n", .{});
    }
    {
        @memset(lu.lx.items, 99.0);
        @memset(lu.ux.items, 99.0);
        try refactorEncoded(&lu, mtape, col_ptr, vals, 1e-12, wloc);
        try expectBitEq(lu.lx.items[0..l_len], lx_ref);
        try expectBitEq(lu.ux.items, ux_ref);
        try expectBitEq(lu.udiag, ud_ref);
        std.debug.print("refactorMTape: bit-identical to refactor\n", .{});
    }
    {
        @memset(lu.lx.items, 99.0);
        @memset(lu.ux.items, 99.0);
        try refactorEncoded(&lu, rtape2, col_ptr, vals, 1e-12, wloc);
        try expectBitEq(lu.lx.items[0..l_len], lx_ref);
        try expectBitEq(lu.ux.items, ux_ref);
        try expectBitEq(lu.udiag, ud_ref);
        std.debug.print("refactorRTape2: bit-identical to refactor\n", .{});
    }

    // ---- microbench: refactor reps ----
    var t0 = now();
    var sink: f64 = 0;
    for (0..reps) |_| {
        try lu.refactor(col_ptr, vals, 1e-12);
        sink += lu.udiag[0];
    }
    const t1 = now();
    std.debug.print("refactor:            {d} reps, {d} ns/rep (sink {e})\n", .{ reps, (t1 - t0) / reps, sink });

    inline for (.{ 1, 4 }) |WV| {
        t0 = now();
        for (0..reps) |_| {
            try refactorLocal(WV, &lu, tape, col_ptr, vals, 1e-12, wloc);
            sink += lu.udiag[0];
        }
        std.debug.print("refactorLocal(W={d}): {d} reps, {d} ns/rep (sink {e})\n", .{ WV, reps, (now() - t0) / reps, sink });
    }
    t0 = now();
    for (0..reps) |_| {
        try refactorEncoded(&lu, rtape, col_ptr, vals, 1e-12, wloc);
        sink += lu.udiag[0];
    }
    std.debug.print("refactorRTape:       {d} reps, {d} ns/rep (sink {e})\n", .{ reps, (now() - t0) / reps, sink });
    t0 = now();
    for (0..reps) |_| {
        try refactorEncoded(&lu, mtape, col_ptr, vals, 1e-12, wloc);
        sink += lu.udiag[0];
    }
    std.debug.print("refactorMTape:       {d} reps, {d} ns/rep (sink {e})\n", .{ reps, (now() - t0) / reps, sink });
    t0 = now();
    for (0..reps) |_| {
        try refactorEncoded(&lu, rtape2, col_ptr, vals, 1e-12, wloc);
        sink += lu.udiag[0];
    }
    std.debug.print("refactorRTape2:      {d} reps, {d} ns/rep (sink {e})\n", .{ reps, (now() - t0) / reps, sink });

    // solve microbench for context
    const b = try gpa.alloc(f64, n);
    const x = try gpa.alloc(f64, n);
    for (b, 0..) |*bi, i| bi.* = @floatFromInt(i % 7);
    t0 = now();
    for (0..reps) |_| {
        lu.solve(b, x);
        sink += x[0];
    }
    std.debug.print("solve:    {d} reps, {d} ns/rep (sink {e})\n", .{ reps, (now() - t0) / reps, sink });
}

fn lenBucket(len: u32) usize {
    return switch (len) {
        0, 1, 2, 3 => len,
        4...7 => 4,
        8...15 => 5,
        16...31 => 6,
        32...63 => 7,
        else => 8,
    };
}

/// Elements covered by full W-length contiguous-ascending-index runs when the
/// kernel greedily takes W-blocks (vector step iff idx[j+W-1]==idx[j]+W-1).
// ponytail: one coverage loop serves both global u32 indices and local u16 ranks.
fn runCovered(comptime I: type, idx: []const I, comptime W: I) u64 {
    var covered: u64 = 0;
    var j: usize = 0;
    while (j + W <= idx.len) {
        if (idx[j + W - 1] == idx[j] + (W - 1)) {
            covered += W;
            j += W;
        } else j += 1;
    }
    return covered;
}

// ============================================================================
// Local-dense prototype: replay in active-set-local coordinates.
// Active set of column k = sorted(U steps) ++ k ++ sorted(L rows); every
// axpy target / A-scatter row / U read lies in it (Gilbert–Peierls closure).
// All indices become u16 ranks; the L part is the lx column order itself, so
// zero = memset, normalize = contiguous vector divide.
// ============================================================================

const Tape = struct {
    loc: []u16, // flop tape: rank of each axpy target, visit order
    uloc: []u16, // per U entry: rank of ui[p] (parallel to ui)
    aloc: []u16, // per A entry: rank of prow[p], column-visit order
    m_max: u32,
};

fn buildTape(gpa: std.mem.Allocator, lu: *Lu, col_ptr: []const u32) !Tape {
    const n = lu.n;
    var flops: usize = 0;
    for (lu.ui.items) |i| flops += lu.lp[i + 1] - lu.lp[i];
    var t: Tape = .{
        .loc = try gpa.alloc(u16, flops),
        .uloc = try gpa.alloc(u16, lu.ui.items.len),
        .aloc = try gpa.alloc(u16, col_ptr[n]),
        .m_max = 0,
    };
    const rankmap = try gpa.alloc(u16, n);
    defer gpa.free(rankmap);
    const active = try gpa.alloc(u32, n);
    defer gpa.free(active);

    // NOTE: assumes L columns sorted ascending (harness sorts below before use)
    var tc: usize = 0;
    var ac: usize = 0;
    for (0..n) |k| {
        var m: u32 = 0;
        for (lu.ui.items[lu.up[k]..lu.up[k + 1]]) |i| {
            active[m] = i;
            m += 1;
        }
        std.mem.sort(u32, active[0..m], {}, std.sort.asc(u32));
        active[m] = @intCast(k);
        m += 1;
        // L part: sorted column IS the active-set order
        for (lu.li.items[lu.lp[k]..lu.lp[k + 1]]) |r| {
            active[m] = r;
            m += 1;
        }
        t.m_max = @max(t.m_max, m);
        if (m > 65535) return error.Overflow;
        for (active[0..m], 0..) |x, rank| rankmap[x] = @intCast(rank);

        for (lu.ui.items[lu.up[k]..lu.up[k + 1]], lu.up[k]..) |i, p| {
            t.uloc[p] = rankmap[i];
            for (lu.li.items[lu.lp[i]..lu.lp[i + 1]]) |r| {
                t.loc[tc] = rankmap[r];
                tc += 1;
            }
        }
        const c = lu.q[k];
        for (col_ptr[c]..col_ptr[c + 1]) |p| {
            t.aloc[ac] = rankmap[lu.prow[p]];
            ac += 1;
        }
    }
    std.debug.assert(tc == flops);
    return t;
}

/// Local-dense replay. WV=1 is the scalar oracle; WV>1 takes a WV-wide step
/// on contiguous rank runs (one compare per step on the ascending tape).
fn refactorLocal(
    comptime WV: usize,
    lu: *Lu,
    t: Tape,
    col_ptr: []const u32,
    vals: []const f64,
    growth_limit: f64,
    wloc: []f64,
) error{SingularMatrix}!void {
    const lx = lu.lx.items;
    const ui = lu.ui.items;
    const ux = lu.ux.items;
    const V = @Vector(WV, f64);

    var tc: usize = 0;
    var ac: usize = 0;
    for (0..lu.n) |k| {
        const c = lu.q[k];
        const nu = lu.up[k + 1] - lu.up[k];
        const nl = lu.lp[k + 1] - lu.lp[k];
        const m = nu + 1 + nl;
        {
            const zed = zedV(4);
            var z: usize = 0;
            while (z < m) : (z += 4) wloc[z..][0..4].* = zed;
        }
        for (col_ptr[c]..col_ptr[c + 1]) |p| {
            wloc[t.aloc[ac]] = vals[p];
            ac += 1;
        }

        for (lu.up[k]..lu.up[k + 1]) |p| {
            const i = ui[p];
            const uki = wloc[t.uloc[p]];
            ux[p] = uki;
            const len = lu.lp[i + 1] - lu.lp[i];
            const xs = lx[lu.lp[i]..][0..len];
            const loc = t.loc[tc..][0..len];
            tc += len;
            const fv: V = @splat(uki);
            var j: usize = 0;
            while (j + WV <= len) {
                const r = loc[j];
                if (WV == 1 or loc[j + WV - 1] == r + WV - 1) {
                    const wv: V = wloc[r..][0..WV].*;
                    const xv: V = xs[j..][0..WV].*;
                    wloc[r..][0..WV].* = wv - xv * fv;
                    j += WV;
                } else {
                    wloc[loc[j]] -= xs[j] * uki;
                    j += 1;
                }
            }
            while (j < len) : (j += 1) wloc[loc[j]] -= xs[j] * uki;
        }

        const d = wloc[nu];
        if (d == 0 or !std.math.isFinite(d)) return error.SingularMatrix;
        lu.udiag[k] = d;

        // normalize: contiguous tail of wloc -> lx column
        const src = wloc[nu + 1 .. m];
        const dst = lx[lu.lp[k]..][0..nl];
        if (growth_limit > 0) {
            var cmax: f64 = @abs(d);
            for (src, dst) |v, *o| {
                cmax = @max(cmax, @abs(v));
                o.* = v / d;
            }
            if (@abs(d) < growth_limit * cmax) return error.SingularMatrix;
        } else {
            for (src, dst) |v, *o| o.* = v / d;
        }
    }
}

// ============================================================================
// Run-encoded tape: greedy 8/4/2/1 run decomposition per walk, done at build.
// No data-dependent branch in the replay: per walk four fixed trip counts.
// op = loc | (joff << 16); within a walk classes are reordered (distinct
// targets -> bit-identical).
// ============================================================================

// Encoded tapes own their operation arrays and borrow uloc/aloc from Tape.
const RTape = struct {
    ops: []u32,
    cnts: []u16, // 4 per walk: n8, n4, n2, n1
    uloc: []u16,
    aloc: []u16,
    m_pad: u32, // m_max rounded up for the over-zeroing loop
};

fn buildRTape(gpa: std.mem.Allocator, lu: *Lu, tape: Tape) !RTape {
    var ops: std.ArrayList(u32) = .empty;
    var cnts: std.ArrayList(u16) = .empty;
    const locs = try gpa.alloc(u16, lu.n);
    defer gpa.free(locs);

    var tc: usize = 0;
    for (lu.ui.items) |i| {
        const len = lu.lp[i + 1] - lu.lp[i];
        @memcpy(locs[0..len], tape.loc[tc..][0..len]);
        tc += len;
        // greedy decomposition, emitted per class
        var nc = [_]u16{0} ** 4;
        inline for (.{ 8, 4, 2, 1 }, 0..) |RW, ci| {
            var j: usize = 0;
            while (j + RW <= len) {
                if (taken(locs[0..len], j)) {
                    j += 1;
                    continue;
                }
                if (RW == 1 or locs[j + RW - 1] == locs[j] + (RW - 1)) {
                    // check none of the RW elements already taken (they
                    // can't be: greedy left-to-right per class, marks below)
                    try ops.append(gpa, @as(u32, locs[j]) | (@as(u32, @intCast(j)) << 16));
                    nc[ci] += 1;
                    mark(locs[0..len], j, RW);
                    j += RW;
                } else j += 1;
            }
        }
        try cnts.appendSlice(gpa, &nc);
    }
    return .{
        .ops = ops.items,
        .cnts = cnts.items,
        .uloc = tape.uloc,
        .aloc = tape.aloc,
        .m_pad = (tape.m_max + 7) & ~@as(u32, 7),
    };
}

// taken/mark: greedy classes must not overlap. Tag taken elements by setting
// the high bit (locs are ranks < 32768 here; m <= 65535 checked, but ranks
// used in runs are < m_max ~ few hundred).
fn taken(locs: []u16, j: usize) bool {
    return locs[j] & 0x8000 != 0;
}
fn mark(locs: []u16, j: usize, w: usize) void {
    for (locs[j..][0..w]) |*l| l.* |= 0x8000;
}

fn refactorEncoded(
    lu: *Lu,
    t: anytype,
    col_ptr: []const u32,
    vals: []const f64,
    growth_limit: f64,
    wloc: []f64,
) error{SingularMatrix}!void {
    const lx = lu.lx.items;
    const ux = lu.ux.items;
    const V4 = @Vector(4, f64);

    var oc: usize = 0;
    var cc: if (@TypeOf(t) == RTape) usize else void = if (@TypeOf(t) == RTape) 0 else {};
    var ac: usize = 0;
    for (0..lu.n) |k| {
        const c = lu.q[k];
        const nu = lu.up[k + 1] - lu.up[k];
        const nl = lu.lp[k + 1] - lu.lp[k];
        const m = nu + 1 + nl;
        // Over-zeroing is safe: wloc includes m_pad + 8 entries.
        {
            const zed: V4 = zedV(4);
            var z: usize = 0;
            while (z < m) : (z += 4) wloc[z..][0..4].* = zed;
        }
        for (col_ptr[c]..col_ptr[c + 1]) |p| {
            wloc[t.aloc[ac]] = vals[p];
            ac += 1;
        }

        for (lu.up[k]..lu.up[k + 1]) |p| {
            const i = lu.ui.items[p];
            const uki = wloc[t.uloc[p]];
            ux[p] = uki;
            const xs = lx[lu.lp[i]..];
            if (comptime @TypeOf(t) == RTape) {
                const n8 = t.cnts[cc];
                const n4 = t.cnts[cc + 1];
                const n2 = t.cnts[cc + 2];
                const n1 = t.cnts[cc + 3];
                cc += 4;
                const fv4: V4 = @splat(uki);
                for (0..n8) |_| {
                    const op = t.ops[oc];
                    oc += 1;
                    const loc = op & 0xFFFF;
                    const j = op >> 16;
                    const w0: V4 = wloc[loc..][0..4].*;
                    const w1: V4 = wloc[loc + 4 ..][0..4].*;
                    const x0: V4 = xs[j..][0..4].*;
                    const x1: V4 = xs[j + 4 ..][0..4].*;
                    wloc[loc..][0..4].* = w0 - x0 * fv4;
                    wloc[loc + 4 ..][0..4].* = w1 - x1 * fv4;
                }
                for (0..n4) |_| {
                    const op = t.ops[oc];
                    oc += 1;
                    const loc = op & 0xFFFF;
                    const j = op >> 16;
                    const wv: V4 = wloc[loc..][0..4].*;
                    const xv: V4 = xs[j..][0..4].*;
                    wloc[loc..][0..4].* = wv - xv * fv4;
                }
                for (0..n2) |_| {
                    const op = t.ops[oc];
                    oc += 1;
                    const loc = op & 0xFFFF;
                    const j = op >> 16;
                    const wv: @Vector(2, f64) = wloc[loc..][0..2].*;
                    const xv: @Vector(2, f64) = xs[j..][0..2].*;
                    wloc[loc..][0..2].* = wv - xv * @as(@Vector(2, f64), @splat(uki));
                }
                for (0..n1) |_| {
                    const op = t.ops[oc];
                    oc += 1;
                    const loc = op & 0xFFFF;
                    const j = op >> 16;
                    wloc[loc] -= xs[j] * uki;
                }
            } else if (comptime @TypeOf(t) == RTape2) {
                const V2 = @Vector(2, f64);
                const cw = t.cnts[p];
                const n4: usize = @intCast(cw & 0xFFFF);
                const n2: usize = @intCast((cw >> 16) & 0xFFFF);
                const n1: usize = @intCast(cw >> 32);
                const fv4: V4 = @splat(uki);
                for (0..n4) |_| {
                    const op = t.ops[oc];
                    oc += 1;
                    const loc = op & 0xFFFF;
                    const j = op >> 16;
                    const wv: V4 = wloc[loc..][0..4].*;
                    const xv: V4 = xs[j..][0..4].*;
                    wloc[loc..][0..4].* = wv - xv * fv4;
                }
                const fv2: V2 = @splat(uki);
                for (0..n2) |_| {
                    const op = t.ops[oc];
                    oc += 1;
                    const loc = op & 0xFFFF;
                    const j = op >> 16;
                    const wv: V2 = wloc[loc..][0..2].*;
                    const xv: V2 = xs[j..][0..2].*;
                    wloc[loc..][0..2].* = wv - xv * fv2;
                }
                var s: usize = 0;
                while (s + 2 <= n1) : (s += 2) {
                    const opa = t.ops[oc];
                    const opb = t.ops[oc + 1];
                    oc += 2;
                    const la = opa & 0xFFFF;
                    const ja = opa >> 16;
                    const lb = opb & 0xFFFF;
                    const jb = opb >> 16;
                    const va = wloc[la] - xs[ja] * uki;
                    const vb = wloc[lb] - xs[jb] * uki;
                    wloc[la] = va;
                    wloc[lb] = vb;
                }
                if (s < n1) {
                    const op = t.ops[oc];
                    oc += 1;
                    wloc[op & 0xFFFF] -= xs[op >> 16] * uki;
                }
            } else {
                const iota: @Vector(4, u32) = .{ 0, 1, 2, 3 };
                const nop = t.nops[p];
                const fv4: V4 = @splat(uki);
                for (0..nop) |_| {
                    const op = t.ops[oc];
                    oc += 1;
                    const loc = op & 0xFFFF;
                    const j = (op >> 16) & 0x3FFF;
                    const len = (op >> 30) + 1;
                    const wv: V4 = wloc[loc..][0..4].*;
                    const xv: V4 = xs[j..][0..4].*;
                    const upd = wv - xv * fv4;
                    const mask = iota < @as(@Vector(4, u32), @splat(len));
                    wloc[loc..][0..4].* = @select(f64, mask, upd, wv);
                }
            }
        }

        const d = wloc[nu];
        if (d == 0 or !std.math.isFinite(d)) return error.SingularMatrix;
        lu.udiag[k] = d;

        const src = wloc[nu + 1 ..][0..nl];
        const dst = lx[lu.lp[k]..][0..nl];
        if (growth_limit > 0) {
            const dv: V4 = @splat(d);
            var cmaxv: V4 = @splat(@abs(d));
            var cmax: f64 = @abs(d);
            var j: usize = 0;
            while (j + 4 <= nl) : (j += 4) {
                const wv: V4 = src[j..][0..4].*;
                cmaxv = @max(cmaxv, @abs(wv));
                dst[j..][0..4].* = wv / dv;
            }
            while (j < nl) : (j += 1) {
                const v = src[j];
                cmax = @max(cmax, @abs(v));
                dst[j] = v / d;
            }
            cmax = @max(cmax, @reduce(.Max, cmaxv));
            if (@abs(d) < growth_limit * cmax) return error.SingularMatrix;
        } else {
            var j: usize = 0;
            const dv: V4 = @splat(d);
            while (j + 4 <= nl) : (j += 4) dst[j..][0..4].* = @as(V4, src[j..][0..4].*) / dv;
            while (j < nl) : (j += 1) dst[j] = src[j] / d;
        }
    }
}

// ============================================================================
// Masked uniform tape: every op is a <=4-wide run, op = loc:16 | j:14 | (len-1):2.
// One loop per walk. Store via load-blend-store: lanes beyond len are written
// back with their just-loaded values (single-threaded => memory unchanged).
// Over-reads go into wloc pad / lx pad (never used).
// ============================================================================

const MTape = struct {
    ops: []u32,
    nops: []u16, // per walk
    uloc: []u16,
    aloc: []u16,
};

fn buildMTape(gpa: std.mem.Allocator, lu: *Lu, tape: Tape) !MTape {
    var ops: std.ArrayList(u32) = .empty;
    var nops: std.ArrayList(u16) = .empty;

    var tc: usize = 0;
    for (lu.ui.items) |i| {
        const len = lu.lp[i + 1] - lu.lp[i];
        if (len > 16383) return error.Overflow;
        const locs = tape.loc[tc..][0..len];
        tc += len;
        // greedy left-to-right <=4 runs
        var cnt: u16 = 0;
        var j: usize = 0;
        while (j < len) {
            var rl: u32 = 1;
            while (rl < 4 and j + rl < len and locs[j + rl] == locs[j] + rl) rl += 1;
            try ops.append(gpa, @as(u32, locs[j]) | (@as(u32, @intCast(j)) << 16) | ((rl - 1) << 30));
            cnt += 1;
            j += rl;
        }
        try nops.append(gpa, cnt);
    }
    std.debug.print("mtape: ops={d} ({d} KB)\n", .{ ops.items.len, ops.items.len * 4 / 1024 });
    return .{
        .ops = ops.items,
        .nops = nops.items,
        .uloc = tape.uloc,
        .aloc = tape.aloc,
    };
}

// RTape2: 3 classes (4/2/1; 8s emitted as two 4s at build), counts packed as
// one u64 (n4 | n2<<16 | n1<<32) loaded once per walk, scalar loop unrolled x2.
const RTape2 = struct {
    ops: []u32, // loc:16 | joff:16, per walk grouped [4s][2s][1s]
    cnts: []u64, // per walk
    uloc: []u16,
    aloc: []u16,
};

fn buildRTape2(gpa: std.mem.Allocator, lu: *Lu, tape: Tape) !RTape2 {
    var ops: std.ArrayList(u32) = .empty;
    var cnts: std.ArrayList(u64) = .empty;

    var tc: usize = 0;
    for (lu.ui.items) |i| {
        const len = lu.lp[i + 1] - lu.lp[i];
        const locs = tape.loc[tc..][0..len];
        tc += len;
        // greedy left-to-right maximal runs, capped at 4 (8-runs -> 2 ops)
        var n4: u64 = 0;
        var stash2: [64]u32 = undefined; // per-walk 2s then 1s, appended after 4s
        var stash1: [64]u32 = undefined;
        var s2: usize = 0;
        var s1: usize = 0;
        var j: usize = 0;
        while (j < len) {
            var rl: usize = 1;
            while (rl < 4 and j + rl < len and locs[j + rl] == locs[j] + rl) rl += 1;
            if (s1 >= 63 or s2 >= 63) return error.Overflow;
            const op = @as(u32, locs[j]) | (@as(u32, @intCast(j)) << 16);
            switch (rl) {
                4 => {
                    try ops.append(gpa, op);
                    n4 += 1;
                },
                3 => { // 3 = 2 + 1
                    stash2[s2] = op;
                    s2 += 1;
                    stash1[s1] = @as(u32, locs[j] + 2) | (@as(u32, @intCast(j + 2)) << 16);
                    s1 += 1;
                },
                2 => {
                    stash2[s2] = op;
                    s2 += 1;
                },
                else => {
                    stash1[s1] = op;
                    s1 += 1;
                },
            }
            j += rl;
        }
        try ops.appendSlice(gpa, stash2[0..s2]);
        try ops.appendSlice(gpa, stash1[0..s1]);
        try cnts.append(gpa, n4 | (@as(u64, s2) << 16) | (@as(u64, s1) << 32));
    }
    std.debug.print("rtape2: ops={d} ({d} KB)\n", .{ ops.items.len, ops.items.len * 4 / 1024 });
    return .{
        .ops = ops.items,
        .cnts = cnts.items,
        .uloc = tape.uloc,
        .aloc = tape.aloc,
    };
}

fn expectBitEq(a: []const f64, b: []const f64) !void {
    if (a.len != b.len) return error.TestExpectedEqual;
    for (a, b, 0..) |x, y, i| {
        if (@as(u64, @bitCast(x)) != @as(u64, @bitCast(y))) {
            std.debug.print("bit mismatch at {d}: {e} vs {e}\n", .{ i, x, y });
            return error.TestExpectedEqual;
        }
    }
}

fn pct(a: u64, b: u64) f64 {
    return 100.0 * @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(@max(b, 1)));
}
