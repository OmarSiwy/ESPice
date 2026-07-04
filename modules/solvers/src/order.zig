//! Fill-reducing ordering (stage 1, §1.4 / §2.7): BTF + per-block AMD.
//!
//! `order()` computes the column permutation `q` the LU factorization
//! consumes: Tarjan's SCC on the pattern's directed graph yields the block
//! triangular form (precondition: structurally full diagonal — the pattern
//! merge guarantees it — so the identity transversal is valid and no
//! matching step is needed); SCCs emit in reverse topological order of the
//! condensation, confining each column's pivots and fill to its own block;
//! within each block, AMD (Amestoy-Davis-Duff) orders for fill: quotient
//! graph, approximate external degrees, element absorption (incl.
//! aggressive), supervariable merging via hashing, degree buckets for O(1)
//! pivot selection.
//!
//! Plain functions over a caller workspace (§2.1): the quotient graph lives
//! in index-linked lists on a slab — no allocator, so the same code runs at
//! comptime (Path B), at runtime setup (Path A), and under the emitter (C).

const std = @import("std");

pub const Error = error{OutOfWorkspace};

/// Caller-owned bump workspace: bump-allocates u32 slices from a single
/// slab with mark/release checkpoints — no allocator, comptime-friendly.
pub const Ws = struct {
    buf: []u32,
    used: usize = 0,

    pub fn init(buf: []u32) Ws {
        return .{ .buf = buf };
    }

    pub fn alloc(w: *Ws, m: usize) Error![]u32 {
        if (w.used + m > w.buf.len) return error.OutOfWorkspace;
        const s = w.buf[w.used .. w.used + m];
        w.used += m;
        return s;
    }

    pub fn allocSet(w: *Ws, m: usize, fill: u32) Error![]u32 {
        const s = try w.alloc(m);
        @memset(s, fill);
        return s;
    }

    pub fn mark(w: *const Ws) usize {
        return w.used;
    }

    pub fn release(w: *Ws, m: usize) void {
        w.used = m;
    }
};

const NONE: u32 = std.math.maxInt(u32);

/// Generous workspace bound for `order(n, nnz)`. The quotient graph's
/// element lists grow with fill; `order` returns `OutOfWorkspace` if a
/// pathological pattern exceeds this — caller retries with a larger buffer.
pub fn wsSize(n: usize, nnz: usize) usize {
    return 48 * n + 8 * nnz + 64;
}

/// BTF + per-block AMD. `q[k]` = original column factored at step k.
pub fn order(n: u32, col_ptr: []const u32, row_idx: []const u32, q: []u32, ws: *Ws) Error!void {
    if (n == 0) return;
    std.debug.assert(q.len == n);
    const base = ws.mark();
    defer ws.release(base);

    // ---- iterative Tarjan SCC (edge j -> i iff A(i,j) != 0) ----
    const num = try ws.allocSet(n, NONE);
    const low = try ws.alloc(n);
    const on = try ws.allocSet(n, 0);
    const scc_stack = try ws.alloc(n);
    const frame_v = try ws.alloc(n);
    const frame_p = try ws.alloc(n);
    const emit = try ws.alloc(n); // vertices grouped by block, emission order
    const block_ptr = try ws.alloc(n + 1);
    var sp: u32 = 0;
    var fp: u32 = 0;
    var counter: u32 = 0;
    var no: u32 = 0;
    var nb: u32 = 0;
    block_ptr[0] = 0;

    for (0..n) |root| {
        if (num[root] != NONE) continue;
        num[root] = counter;
        low[root] = counter;
        counter += 1;
        scc_stack[sp] = @intCast(root);
        sp += 1;
        on[root] = 1;
        frame_v[fp] = @intCast(root);
        frame_p[fp] = col_ptr[root];
        fp += 1;
        while (fp > 0) {
            const v = frame_v[fp - 1];
            if (frame_p[fp - 1] < col_ptr[v + 1]) {
                const child = row_idx[frame_p[fp - 1]];
                frame_p[fp - 1] += 1;
                if (child == v) continue;
                if (num[child] == NONE) {
                    num[child] = counter;
                    low[child] = counter;
                    counter += 1;
                    scc_stack[sp] = child;
                    sp += 1;
                    on[child] = 1;
                    frame_v[fp] = child;
                    frame_p[fp] = col_ptr[child];
                    fp += 1;
                } else if (on[child] != 0) {
                    low[v] = @min(low[v], num[child]);
                }
                continue;
            }
            // v finished: emit its SCC if v is a root
            if (low[v] == num[v]) {
                while (true) {
                    sp -= 1;
                    const m = scc_stack[sp];
                    on[m] = 0;
                    emit[no] = m;
                    no += 1;
                    if (m == v) break;
                }
                nb += 1;
                block_ptr[nb] = no;
            }
            fp -= 1;
            if (fp > 0) {
                const pv = frame_v[fp - 1];
                low[pv] = @min(low[pv], low[v]);
            }
        }
    }

    // ---- per-block AMD; singletons pass through ----
    const blk_of = try ws.alloc(n);
    const loc = try ws.alloc(n);
    for (0..nb) |b| {
        for (block_ptr[b]..block_ptr[b + 1], 0..) |i, li| {
            blk_of[emit[i]] = @intCast(b);
            loc[emit[i]] = @intCast(li);
        }
    }
    for (0..nb) |b| {
        const lo = block_ptr[b];
        const hi = block_ptr[b + 1];
        const bs = hi - lo;
        const verts = emit[lo..hi];
        if (bs == 1) {
            q[lo] = verts[0];
            continue;
        }
        // extract the block's sub-pattern (columns restricted to in-block rows)
        const blk_mark = ws.mark();
        defer ws.release(blk_mark);
        const sub_cp = try ws.alloc(bs + 1);
        var sub_nnz: u32 = 0;
        sub_cp[0] = 0;
        for (verts, 0..) |v, j| {
            for (col_ptr[v]..col_ptr[v + 1]) |p| {
                if (blk_of[row_idx[p]] == b) sub_nnz += 1;
            }
            sub_cp[j + 1] = sub_nnz;
        }
        const sub_ri = try ws.alloc(sub_nnz);
        var w: u32 = 0;
        for (verts) |v| {
            for (col_ptr[v]..col_ptr[v + 1]) |p| {
                const r = row_idx[p];
                if (blk_of[r] == b) {
                    sub_ri[w] = loc[r];
                    w += 1;
                }
            }
        }
        const sub_q = try ws.alloc(bs);
        try amd(@intCast(bs), sub_cp, sub_ri, sub_q, ws);
        for (sub_q, 0..) |lq, i| q[lo + i] = verts[lq];
    }
}

// ============================================================================
// AMD — contiguous packed adjacency (no allocator; deterministic).
// ============================================================================

/// Doubly-linked degree buckets: head[d] -> chain of variables at degree d.
const DegLists = struct {
    head: []u32,
    next: []u32,
    prev: []u32,

    fn insert(s: *DegLists, d: u32, i: u32) void {
        s.next[i] = s.head[d];
        s.prev[i] = NONE;
        if (s.head[d] != NONE) s.prev[s.head[d]] = i;
        s.head[d] = i;
    }

    fn remove(s: *DegLists, d: u32, i: u32) void {
        if (s.prev[i] != NONE) s.next[s.prev[i]] = s.next[i] else s.head[d] = s.next[i];
        if (s.next[i] != NONE) s.prev[s.next[i]] = s.prev[i];
    }
};

// ponytail: contiguous packed adj replaces slab linked-lists -> sequential scan.
// Ceiling: ea[] fragmentation under pathological fill. Upgrade: compaction pass.
pub fn amd(n: u32, col_ptr: []const u32, row_idx: []const u32, q: []u32, ws: *Ws) Error!void {
    if (n == 0) return;
    const base = ws.mark();
    defer ws.release(base);

    const nnz = col_ptr[n];

    // va[]: variable adjacency (init region) + element member lists Le (tail region).
    // ea[]: per-variable element-adjacency; bump-allocated, relocates on growth.
    const va = try ws.alloc(4 * @as(usize, nnz) + 4 * @as(usize, n) + 16);
    const va_pe = try ws.alloc(n);
    const va_len = try ws.alloc(n);

    const ea = try ws.alloc(8 * @as(usize, n) + @as(usize, nnz));
    const ea_pe = try ws.alloc(n);
    const ea_len = try ws.allocSet(n, 0);
    const ea_lim = try ws.alloc(n);

    const nv = try ws.allocSet(n, 1);
    const elem_alive = try ws.allocSet(n, 0);
    const esize = try ws.alloc(n);
    const deg = try ws.alloc(n);
    const w_buf = try ws.alloc(n);
    const mark = try ws.allocSet(n, 0);
    const wmark = try ws.allocSet(n, 0);
    const hkey = try ws.alloc(n);
    const hhead = try ws.allocSet(n, NONE);
    const hnext = try ws.alloc(n);
    const mlink = try ws.allocSet(n, NONE);
    const lp = try ws.alloc(n);
    const touched = try ws.alloc(n);
    const hbuckets = try ws.alloc(n);
    var dl = DegLists{
        .head = try ws.allocSet(n + 1, NONE),
        .next = try ws.alloc(n),
        .prev = try ws.alloc(n),
    };
    var era: u32 = 0;
    var erw: u32 = 0;

    // ---- symmetrized variable adjacency (contiguous in va[]) ----
    @memset(deg, 0);
    for (0..n) |j| {
        for (col_ptr[j]..col_ptr[j + 1]) |pi| {
            const r = row_idx[pi];
            if (r == j) continue;
            deg[j] += 1;
            deg[r] += 1;
        }
    }
    var va_free: usize = 0;
    for (0..n) |i| {
        va_pe[i] = @intCast(va_free);
        va_free += deg[i];
    }
    @memset(deg, 0);
    for (0..n) |j| {
        for (col_ptr[j]..col_ptr[j + 1]) |pi| {
            const r = row_idx[pi];
            if (r == j) continue;
            va[va_pe[j] + deg[j]] = r;
            deg[j] += 1;
            va[va_pe[r] + deg[r]] = @intCast(j);
            deg[r] += 1;
        }
    }
    for (0..n) |i| va_len[i] = deg[i];

    // dedup
    for (0..n) |i| {
        era += 1;
        var wp: u32 = 0;
        const s = va_pe[i];
        for (0..va_len[i]) |ki| {
            const v = va[s + ki];
            if (mark[v] != era) {
                mark[v] = era;
                va[s + wp] = v;
                wp += 1;
            }
        }
        va_len[i] = wp;
    }

    // ---- dense row detection: defer rows denser than 10·√n ----
    var isq: u32 = 0;
    while (@as(u64, isq + 1) * @as(u64, isq + 1) <= n) isq += 1;
    const dense_thresh: u32 = @max(@as(u32, 16), 10 * isq);
    var ndense: u32 = 0;
    for (0..n) |i| {
        if (va_len[i] >= dense_thresh) ndense += 1;
    }
    const dense_start = n - ndense;
    {
        var di: u32 = 0;
        for (0..n) |i| {
            if (va_len[i] >= dense_thresh) {
                nv[i] = 0;
                lp[dense_start + di] = @intCast(i);
                di += 1;
            }
        }
    }
    if (ndense > 0) {
        for (0..n) |i| {
            if (nv[i] == 0) continue;
            var wp: u32 = 0;
            const s = va_pe[i];
            for (0..va_len[i]) |ki| {
                const v = va[s + ki];
                if (nv[v] != 0) {
                    va[s + wp] = v;
                    wp += 1;
                }
            }
            va_len[i] = wp;
        }
    }

    // element adjacency: 4 initial slots each
    var ea_free: usize = 0;
    for (0..n) |i| {
        ea_pe[i] = @intCast(ea_free);
        ea_lim[i] = 4;
        ea_free += 4;
    }

    for (0..n) |i| {
        if (nv[i] == 0) continue;
        deg[i] = va_len[i];
        dl.insert(deg[i], @intCast(i));
    }

    const n_amd: u32 = n - ndense;
    var mindeg: u32 = 0;
    var k: u32 = 0;

    while (k < n_amd) {
        while (dl.head[mindeg] == NONE) mindeg += 1;
        const p = dl.head[mindeg];
        dl.remove(deg[p], p);

        // ---- form Lp = (A_p ∪ ⋃ Le, e ∈ E_p) \ {p} ----
        era += 1;
        mark[p] = era;
        var nlp: u32 = 0;

        for (va[va_pe[p]..][0..va_len[p]]) |v| {
            if (nv[v] != 0 and mark[v] != era) {
                mark[v] = era;
                lp[nlp] = v;
                nlp += 1;
            }
        }
        for (ea[ea_pe[p]..][0..ea_len[p]]) |e| {
            if (elem_alive[e] == 0) continue;
            for (va[va_pe[e]..][0..va_len[e]]) |v| {
                if (nv[v] != 0 and mark[v] != era) {
                    mark[v] = era;
                    lp[nlp] = v;
                    nlp += 1;
                }
            }
            elem_alive[e] = 0;
        }

        const nvpiv = nv[p];
        nv[p] = 0;
        elem_alive[p] = 1;

        // store Le(p) in va[] tail
        if (va_free + nlp > va.len) return error.OutOfWorkspace;
        va_pe[p] = @intCast(va_free);
        va_len[p] = nlp;
        @memcpy(va[va_free..][0..nlp], lp[0..nlp]);
        va_free += nlp;

        var lpsize: u32 = 0;
        for (lp[0..nlp]) |i| lpsize += nv[i];
        esize[p] = lpsize;

        for (lp[0..nlp]) |i| dl.remove(deg[i], i);

        // ---- w[e] = |Le \ Lp| bound ----
        erw += 1;
        var ntouched: u32 = 0;
        for (lp[0..nlp]) |i| {
            for (ea[ea_pe[i]..][0..ea_len[i]]) |e| {
                if (elem_alive[e] == 0) continue;
                if (wmark[e] != erw) {
                    wmark[e] = erw;
                    w_buf[e] = esize[e];
                    touched[ntouched] = e;
                    ntouched += 1;
                }
                w_buf[e] -= @min(w_buf[e], nv[i]);
            }
        }
        for (touched[0..ntouched]) |e| {
            if (w_buf[e] == 0) elem_alive[e] = 0;
        }

        // ---- per-member pruning + approximate external degree ----
        for (lp[0..nlp]) |i| {
            // E_i := live(E_i) ∪ {p}
            var esum: u32 = 0;
            var ewp: u32 = 0;
            for (ea[ea_pe[i]..][0..ea_len[i]]) |e| {
                if (elem_alive[e] != 0 and e != p) {
                    ea[ea_pe[i] + ewp] = e;
                    ewp += 1;
                    esum += w_buf[e];
                }
            }
            if (ewp < ea_lim[i]) {
                ea[ea_pe[i] + ewp] = p;
                ea_len[i] = ewp + 1;
            } else {
                const nc: u32 = (ewp + 1) * 2;
                if (ea_free + nc > ea.len) return error.OutOfWorkspace;
                @memcpy(ea[ea_free..][0..ewp], ea[ea_pe[i]..][0..ewp]);
                ea[ea_free + ewp] = p;
                ea_pe[i] = @intCast(ea_free);
                ea_lim[i] = nc;
                ea_len[i] = ewp + 1;
                ea_free += nc;
            }

            // A_i := A_i \ (Lp ∪ dead)
            var asum: u32 = 0;
            var vwp: u32 = 0;
            for (va[va_pe[i]..][0..va_len[i]]) |v| {
                if (nv[v] != 0 and mark[v] != era) {
                    va[va_pe[i] + vwp] = v;
                    vwp += 1;
                    asum += nv[v];
                }
            }
            va_len[i] = vwp;

            const cap: u32 = n_amd - k - nvpiv;
            deg[i] = @min(asum + (lpsize - nv[i]) + esum, cap);
        }

        // ---- supervariable detection ----
        var nhb: u32 = 0;
        for (lp[0..nlp]) |i| {
            if (nv[i] == 0) continue;
            var h: u32 = 0;
            for (va[va_pe[i]..][0..va_len[i]]) |v| h +%= v;
            for (ea[ea_pe[i]..][0..ea_len[i]]) |v| h +%= v;
            hkey[i] = h;
            const b = h % n;
            if (hhead[b] == NONE) {
                hbuckets[nhb] = b;
                nhb += 1;
            }
            hnext[i] = hhead[b];
            hhead[b] = i;
        }
        for (hbuckets[0..nhb]) |b| {
            var i = hhead[b];
            while (i != NONE) : (i = hnext[i]) {
                if (nv[i] == 0) continue;
                var j = hnext[i];
                while (j != NONE) : (j = hnext[j]) {
                    if (nv[j] == 0 or hkey[j] != hkey[i]) continue;
                    if (!sameAdjPacked(va, va_pe, va_len, ea, ea_pe, ea_len, mark, &era, i, j)) continue;
                    deg[i] -= @min(deg[i], nv[j]);
                    nv[i] += nv[j];
                    nv[j] = 0;
                    var tail = j;
                    while (mlink[tail] != NONE) tail = mlink[tail];
                    mlink[tail] = mlink[i];
                    mlink[i] = j;
                }
            }
            hhead[b] = NONE;
        }

        for (lp[0..nlp]) |i| {
            if (nv[i] == 0) continue;
            dl.insert(deg[i], i);
            if (deg[i] < mindeg) mindeg = deg[i];
        }

        q[k] = p;
        k += 1;
        var mb = mlink[p];
        while (mb != NONE) : (mb = mlink[mb]) {
            q[k] = mb;
            k += 1;
        }
    }

    // ---- append dense rows at end ----
    @memcpy(q[k..][0..ndense], lp[dense_start..][0..ndense]);
}

fn sameAdjPacked(
    va: []const u32,
    va_pe: []const u32,
    va_len: []const u32,
    ea: []const u32,
    ea_pe: []const u32,
    ea_len: []const u32,
    mark: []u32,
    era: *u32,
    i: u32,
    j: u32,
) bool {
    if (va_len[i] != va_len[j] or ea_len[i] != ea_len[j]) return false;
    era.* += 1;
    const m = era.*;
    for (va[va_pe[i]..][0..va_len[i]]) |v| mark[v] = m;
    for (va[va_pe[j]..][0..va_len[j]]) |v| {
        if (mark[v] != m or v == i) return false;
    }
    era.* += 1;
    const me = era.*;
    for (ea[ea_pe[i]..][0..ea_len[i]]) |v| mark[v] = me;
    for (ea[ea_pe[j]..][0..ea_len[j]]) |v| {
        if (mark[v] != me) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn DenseCsc(comptime n: usize) type {
    return struct {
        col_ptr: [n + 1]u32,
        row_idx: [n * n]u32,
        fn from(a: [n][n]u1) @This() {
            var s: @This() = undefined;
            var m: u32 = 0;
            s.col_ptr[0] = 0;
            for (0..n) |j| {
                for (0..n) |i| {
                    if (a[i][j] != 0) {
                        s.row_idx[m] = @intCast(i);
                        m += 1;
                    }
                }
                s.col_ptr[j + 1] = m;
            }
            return s;
        }
        fn nnz(s: *const @This()) u32 {
            return s.col_ptr[n];
        }
    };
}

fn expectPermutation(q: []const u32, n: u32) !void {
    var seen: [64]bool = @splat(false);
    for (q) |c| {
        try testing.expect(c < n);
        try testing.expect(!seen[c]);
        seen[c] = true;
    }
}

// 5x5 star: hub 0 coupled to every leaf. Min degree must defer the hub to
// the end (eliminating it first fills the whole matrix).
const star = [5][5]u1{
    .{ 1, 1, 1, 1, 1 },
    .{ 1, 1, 0, 0, 0 },
    .{ 1, 0, 1, 0, 0 },
    .{ 1, 0, 0, 1, 0 },
    .{ 1, 0, 0, 0, 1 },
};

test "amd: star defers the hub until its degree collapses" {
    const csc = DenseCsc(5).from(star);
    var buf: [2048]u32 = undefined;
    var ws = Ws.init(&buf);
    var q: [5]u32 = undefined;
    try order(5, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws);
    try expectPermutation(&q, 5);
    // hub may not pivot before its degree collapses to a zero-fill tie:
    // never before the second-to-last position
    try testing.expect(q[3] == 0 or q[4] == 0);
}

// A = [B1 C; 0 B2] over {0,1} and {2,3}: edges within each pair both ways,
// C couples column 2 into row 0 only. Condensation: {2,3} -> {0,1}, so the
// sink block {0,1} must be factored first.
const btf_case = [4][4]u1{
    .{ 1, 1, 1, 0 },
    .{ 1, 1, 0, 0 },
    .{ 0, 0, 1, 1 },
    .{ 0, 0, 1, 1 },
};

test "btf: sink block factored first" {
    const csc = DenseCsc(4).from(btf_case);
    var buf: [2048]u32 = undefined;
    var ws = Ws.init(&buf);
    var q: [4]u32 = undefined;
    try order(4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws);
    try expectPermutation(&q, 4);
    try testing.expect(q[0] < 2 and q[1] < 2);
    try testing.expect(q[2] >= 2 and q[3] >= 2);
}

// Star with indistinguishable leaves exercises supervariable merging; a
// chain exercises degree updates; diagonal-only exercises singleton blocks.
test "amd: supervariables, chain, diagonal-only" {
    {
        const csc = DenseCsc(5).from(star);
        var buf: [2048]u32 = undefined;
        var ws = Ws.init(&buf);
        var q: [5]u32 = undefined;
        try amd(5, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws);
        try expectPermutation(&q, 5);
        try testing.expect(q[3] == 0 or q[4] == 0);
    }
    {
        // tridiagonal chain of 6
        var a: [6][6]u1 = @splat(@splat(0));
        for (0..6) |i| {
            a[i][i] = 1;
            if (i + 1 < 6) {
                a[i][i + 1] = 1;
                a[i + 1][i] = 1;
            }
        }
        const csc = DenseCsc(6).from(a);
        var buf: [4096]u32 = undefined;
        var ws = Ws.init(&buf);
        var q: [6]u32 = undefined;
        try amd(6, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws);
        try expectPermutation(&q, 6);
    }
    {
        // diagonal-only: 3 singleton blocks, identity-ish order
        var a: [3][3]u1 = @splat(@splat(0));
        for (0..3) |i| a[i][i] = 1;
        const csc = DenseCsc(3).from(a);
        var buf: [1024]u32 = undefined;
        var ws = Ws.init(&buf);
        var q: [3]u32 = undefined;
        try order(3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws);
        try expectPermutation(&q, 3);
    }
}

test "order: deterministic — two runs byte-identical" {
    const csc = DenseCsc(5).from(star);
    var buf: [2048]u32 = undefined;
    var q1: [5]u32 = undefined;
    var q2: [5]u32 = undefined;
    var ws1 = Ws.init(&buf);
    try order(5, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q1, &ws1);
    var ws2 = Ws.init(&buf);
    try order(5, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q2, &ws2);
    try testing.expectEqualSlices(u32, &q1, &q2);
}

test "order: comptime consumer ≡ heap consumer, byte-compared" {
    @setEvalBranchQuota(200_000);
    const ct = comptime blk: {
        const csc = DenseCsc(4).from(btf_case);
        var buf: [2048]u32 = undefined;
        var ws = Ws.init(&buf);
        var q: [4]u32 = undefined;
        order(4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws) catch unreachable;
        break :blk q;
    };
    const csc = DenseCsc(4).from(btf_case);
    const buf = try testing.allocator.alloc(u32, wsSize(4, csc.nnz()));
    defer testing.allocator.free(buf);
    var ws = Ws.init(buf);
    var q: [4]u32 = undefined;
    try order(4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws);
    try testing.expectEqualSlices(u32, &ct, &q);
}

test "bump, checkpoint, exhaustion" {
    var buf: [8]u32 = undefined;
    var ws = Ws.init(&buf);
    const a = try ws.alloc(4);
    a[0] = 7;
    const m = ws.mark();
    _ = try ws.allocSet(3, 0);
    try std.testing.expectError(error.OutOfWorkspace, ws.alloc(2));
    ws.release(m);
    _ = try ws.alloc(4);
    try std.testing.expectEqual(@as(u32, 7), buf[0]);
}
