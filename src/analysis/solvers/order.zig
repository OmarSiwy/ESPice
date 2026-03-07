//! Fill-reducing column ordering: BTF (Tarjan SCC) + per-block AMD.
//!
//! `order()` produces the column permutation `q` consumed by LU factorization:
//! iterative Tarjan SCC decomposes the pattern into irreducible diagonal blocks
//! (precondition: structurally full diagonal — pattern merge guarantees it —
//! so the identity transversal is valid and no matching step is needed); SCCs
//! emit in reverse topological order of the condensation; within each non-
//! singleton block, AMD (Amestoy–Davis–Duff approximate minimum degree) orders
//! columns for fill reduction: quotient graph, approximate external degrees,
//! aggressive element absorption, supervariable merging via hash buckets,
//! doubly-linked degree lists for O(1) pivot selection, dense-row deferral.
//!
//! Everything lives in a single caller-provided u32 slab (`Ws`): no allocator,
//! so the identical code runs at comptime (Path B), runtime setup (Path A),
//! and under the C emitter. SoA layout throughout: parallel arrays indexed by
//! vertex u32 — sequential scan, cache-friendly, no pointer chasing between
//! solver objects.

const std = @import("std");

pub const Error = error{OutOfWorkspace};

const NONE: u32 = std.math.maxInt(u32);

// ============================================================================
// Ws — bump workspace
// ============================================================================

/// Caller-owned bump workspace: allocates u32 slices from a contiguous slab
/// with mark/release checkpoints. No allocator — comptime-friendly.
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

// ============================================================================
// wsSize — workspace bound
// ============================================================================

/// Conservative workspace bound for `order(n, nnz)` or `amd(n, nnz)`.
/// The quotient graph's element lists grow with fill; `order`/`amd` return
/// `OutOfWorkspace` if a pathological pattern exceeds this.
pub fn wsSize(n: usize, nnz: usize) usize {
    return 48 * n + 8 * nnz + 64;
}

// ============================================================================
// BTF + per-block AMD
// ============================================================================

/// BTF + per-block AMD. `q[k]` = original column factored at step k.
///
/// Precondition: structurally full diagonal (pattern merge guarantees it).
/// The directed graph has edge j→i iff A(i,j)≠0, i≠j. Tarjan SCC finds
/// irreducible blocks; SCCs emit in reverse topological order (sink block
/// first = factored first). Singletons pass through; non-trivial blocks
/// get AMD-ordered.
pub fn order(n: u32, col_ptr: []const u32, row_idx: []const u32, q: []u32, ws: *Ws) Error!void {
    if (n == 0) return;
    std.debug.assert(q.len == n);
    const base = ws.mark();
    defer ws.release(base);

    // ---- Tarjan SCC arrays (SoA: one array per field) ----
    const num = try ws.allocSet(n, NONE); // DFS numbering
    const low = try ws.alloc(n); // low-link values
    const on = try ws.allocSet(n, 0); // on SCC stack?
    const scc_stack = try ws.alloc(n); // Tarjan stack
    const frame_v = try ws.alloc(n); // DFS frame: vertex
    const frame_p = try ws.alloc(n); // DFS frame: edge pointer
    const emit = try ws.alloc(n); // vertices grouped by block
    const block_ptr = try ws.alloc(n + 1); // block boundaries in emit[]

    var sp: u32 = 0; // SCC stack pointer
    var fp: u32 = 0; // frame stack pointer
    var counter: u32 = 0; // DFS counter
    var no: u32 = 0; // emission cursor
    var nb: u32 = 0; // block count
    block_ptr[0] = 0;

    // ---- iterative Tarjan: edge j → row_idx[p] for p in col_ptr[j..j+1] ----
    for (0..n) |root| {
        if (num[root] != NONE) continue;
        // Visit root
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
                if (child == v) continue; // skip self-loop
                if (num[child] == NONE) {
                    // Tree edge: visit child
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
                    // Back/cross edge to vertex on stack
                    low[v] = @min(low[v], num[child]);
                }
                continue;
            }
            // v finished: check if SCC root
            if (low[v] == num[v]) {
                // Pop SCC stack down to v — this is one block
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
            // Pop frame; propagate low-link to parent
            fp -= 1;
            if (fp > 0) {
                low[frame_v[fp - 1]] = @min(low[frame_v[fp - 1]], low[v]);
            }
        }
    }

    // ---- per-block AMD; singletons pass through ----
    // Build vertex→block and vertex→local-index maps for sub-pattern extraction
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

        // Extract the block's sub-pattern: columns of verts, rows restricted to block
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
// AMD — Approximate Minimum Degree
// ============================================================================

/// Doubly-linked degree buckets: head[d] → chain of variables with degree d.
/// O(1) insert/remove; mindeg scan amortized O(n) since min degree is
/// non-decreasing in practice.
const DegLists = struct {
    head: []u32, // head[d] = first variable at degree d, or NONE
    next: []u32, // next[i] = next variable in same bucket
    prev: []u32, // prev[i] = previous variable in same bucket

    fn insert(s: *DegLists, d: u32, i: u32) void {
        s.next[i] = s.head[d];
        s.prev[i] = NONE;
        if (s.head[d] != NONE) s.prev[s.head[d]] = i;
        s.head[d] = i;
    }

    fn remove(s: *DegLists, d: u32, i: u32) void {
        if (s.prev[i] != NONE)
            s.next[s.prev[i]] = s.next[i]
        else
            s.head[d] = s.next[i];
        if (s.next[i] != NONE)
            s.prev[s.next[i]] = s.prev[i];
    }
};

// ponytail: contiguous packed adj in va[] replaces slab linked-lists → sequential scan.
// Ceiling: ea[] fragmentation under pathological fill; upgrade: compaction pass or
// adaptive slab sizing.

/// Standalone AMD ordering. `q[k]` = original column at elimination step k.
///
/// Quotient-graph based: approximate external degrees (w[e] one-scan trick),
/// aggressive element absorption, supervariable merge via hash buckets,
/// doubly-linked degree lists, dense-row deferral (threshold: max(16, 10√n)).
/// All workspace from caller's `Ws` bump slab — no allocator.
pub fn amd(n: u32, col_ptr: []const u32, row_idx: []const u32, q: []u32, ws: *Ws) Error!void {
    if (n == 0) return;
    const base = ws.mark();
    defer ws.release(base);

    const nnz = col_ptr[n];

    // ---- SoA workspace arrays ----
    // Variable adjacency: packed contiguous spans in va[]
    const va = try ws.alloc(4 * @as(usize, nnz) + 4 * @as(usize, n) + 16);
    const va_pe = try ws.alloc(n); // va_pe[i]: start of i's VA span in va[]
    const va_len = try ws.alloc(n); // va_len[i]: length of i's VA span

    // Element adjacency: per-variable, bump-allocated with 2x growth
    const ea = try ws.alloc(8 * @as(usize, n) + @as(usize, nnz));
    const ea_pe = try ws.alloc(n); // ea_pe[i]: start of i's EA span in ea[]
    const ea_len = try ws.allocSet(n, 0); // ea_len[i]: length of i's EA span
    const ea_lim = try ws.alloc(n); // ea_lim[i]: capacity of i's EA span

    // Per-variable scalars
    const nv = try ws.allocSet(n, 1); // supervariable count (0 = dead/absorbed)
    const elem_alive = try ws.allocSet(n, 0); // 1 = live element
    const esize = try ws.alloc(n); // esize[e] = Σnv over Le members
    const deg = try ws.alloc(n); // approximate external degree
    const w_buf = try ws.alloc(n); // w_buf[e] = |Le \ Lp| bound (per pivot step)

    // Epoch-based marking — avoids memset-clearing between steps
    const mark_arr = try ws.allocSet(n, 0);
    const wmark_arr = try ws.allocSet(n, 0);
    var era: u32 = 0; // epoch for mark_arr
    var erw: u32 = 0; // epoch for wmark_arr

    // Supervariable hashing
    const hkey = try ws.alloc(n);
    const hhead = try ws.allocSet(n, NONE);
    const hnext = try ws.alloc(n);
    const hbuckets = try ws.alloc(n); // active bucket indices for cleanup

    // Supervariable merge chains
    const mlink = try ws.allocSet(n, NONE);

    // Scratch: Lp members, touched elements
    const lp_buf = try ws.alloc(n);
    const touched = try ws.alloc(n);

    // Degree buckets
    var dl = DegLists{
        .head = try ws.allocSet(n + 1, NONE),
        .next = try ws.alloc(n),
        .prev = try ws.alloc(n),
    };

    // ==== Phase 1: build symmetrized variable adjacency (contiguous in va[]) ====
    // Count degrees first (two passes: count then scatter)
    @memset(deg, 0);
    for (0..n) |j| {
        for (col_ptr[j]..col_ptr[j + 1]) |pi| {
            const r = row_idx[pi];
            if (r == j) continue;
            deg[j] += 1;
            deg[r] += 1;
        }
    }
    // Assign contiguous spans
    var va_free: usize = 0;
    for (0..n) |i| {
        va_pe[i] = @intCast(va_free);
        va_free += deg[i];
    }
    // Scatter edges (both directions for symmetrization)
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
    // ponytail: both workspace slices have length n; reuse the bulk copy primitive.
    @memcpy(va_len, deg);

    // Dedup (epoch-mark each neighbor, compact in-place)
    for (0..n) |i| {
        era += 1;
        var wp: u32 = 0;
        const s = va_pe[i];
        for (0..va_len[i]) |ki| {
            const v = va[s + ki];
            if (mark_arr[v] != era) {
                mark_arr[v] = era;
                va[s + wp] = v;
                wp += 1;
            }
        }
        va_len[i] = wp;
    }

    // ==== Phase 2: dense-row deferral (threshold: max(16, 10·⌊√n⌋)) ====
    // ponytail: stdlib integer sqrt preserves the exact floor without a counting loop.
    const isq: u32 = std.math.sqrt(n);
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
                nv[i] = 0; // mark dead — excluded from quotient graph
                lp_buf[dense_start + di] = @intCast(i);
                di += 1;
            }
        }
    }
    // Remove dead (dense) vertices from all adjacency lists
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

    // Initialize element adjacency: 4 slots each (grows 2x on overflow)
    var ea_free: usize = 0;
    for (0..n) |i| {
        ea_pe[i] = @intCast(ea_free);
        ea_lim[i] = 4;
        ea_free += 4;
    }

    // Insert live variables into degree buckets
    for (0..n) |i| {
        if (nv[i] == 0) continue;
        deg[i] = va_len[i];
        dl.insert(deg[i], @intCast(i));
    }

    // ==== Phase 3: main elimination loop ====
    const n_amd: u32 = n - ndense;
    var mindeg: u32 = 0;
    var k: u32 = 0;

    while (k < n_amd) {
        // Find minimum-degree pivot
        while (dl.head[mindeg] == NONE) mindeg += 1;
        const p = dl.head[mindeg];
        dl.remove(deg[p], p);

        // ---- Form Lp = (A_p ∪ ⋃{Le : e ∈ E_p}) \ {p} ----
        // Epoch mark to deduplicate union
        era += 1;
        mark_arr[p] = era;
        var nlp: u32 = 0;

        // Direct variable neighbors of p
        for (va[va_pe[p]..][0..va_len[p]]) |v| {
            if (nv[v] != 0 and mark_arr[v] != era) {
                mark_arr[v] = era;
                lp_buf[nlp] = v;
                nlp += 1;
            }
        }
        // Members of elements adjacent to p
        for (ea[ea_pe[p]..][0..ea_len[p]]) |e| {
            if (elem_alive[e] == 0) continue;
            for (va[va_pe[e]..][0..va_len[e]]) |v| {
                if (nv[v] != 0 and mark_arr[v] != era) {
                    mark_arr[v] = era;
                    lp_buf[nlp] = v;
                    nlp += 1;
                }
            }
            // Kill absorbed elements (their members ⊆ Lp ∪ {p})
            elem_alive[e] = 0;
        }

        // p becomes element: nv[p]=0, elem_alive[p]=1
        const nvpiv = nv[p];
        nv[p] = 0;
        elem_alive[p] = 1;

        // Store Le(p) = Lp in va[] tail (element member list)
        if (va_free + nlp > va.len) return error.OutOfWorkspace;
        va_pe[p] = @intCast(va_free);
        va_len[p] = nlp;
        @memcpy(va[va_free..][0..nlp], lp_buf[0..nlp]);
        va_free += nlp;

        // Weighted size of Lp
        var lpsize: u32 = 0;
        for (lp_buf[0..nlp]) |i| lpsize += nv[i];
        esize[p] = lpsize;

        // Remove Lp members from degree buckets (they'll be reinserted)
        for (lp_buf[0..nlp]) |i| dl.remove(deg[i], i);

        // ---- w[e] = |Le \ Lp| upper bound (one scan of Lp's element adj) ----
        erw += 1;
        var ntouched: u32 = 0;
        for (lp_buf[0..nlp]) |i| {
            for (ea[ea_pe[i]..][0..ea_len[i]]) |e| {
                if (elem_alive[e] == 0) continue;
                if (wmark_arr[e] != erw) {
                    wmark_arr[e] = erw;
                    w_buf[e] = esize[e];
                    touched[ntouched] = e;
                    ntouched += 1;
                }
                w_buf[e] -= @min(w_buf[e], nv[i]);
            }
        }
        // Aggressive absorption: kill elements fully absorbed into p
        for (touched[0..ntouched]) |e| {
            if (w_buf[e] == 0) elem_alive[e] = 0;
        }
        // ---- Per-member: prune adjacency, compute approximate degree ----
        for (lp_buf[0..nlp]) |i| {
            // E_i := live(E_i) ∪ {p}, with esum = Σ w[e] for degree bound
            var esum: u32 = 0;
            var ewp: u32 = 0;
            for (ea[ea_pe[i]..][0..ea_len[i]]) |e| {
                if (elem_alive[e] != 0 and e != p) {
                    ea[ea_pe[i] + ewp] = e;
                    ewp += 1;
                    esum += w_buf[e];
                }
            }
            // Append p to element adjacency (relocate if full)
            if (ewp < ea_lim[i]) {
                ea[ea_pe[i] + ewp] = p;
            } else {
                const nc: u32 = (ewp + 1) * 2;
                if (ea_free + nc > ea.len) return error.OutOfWorkspace;
                @memcpy(ea[ea_free..][0..ewp], ea[ea_pe[i]..][0..ewp]);
                ea[ea_free + ewp] = p;
                ea_pe[i] = @intCast(ea_free);
                ea_lim[i] = nc;
                ea_free += nc;
            }
            ea_len[i] = ewp + 1;

            // A_i := A_i \ (Lp ∪ dead), with asum = Σ nv for degree bound
            var asum: u32 = 0;
            var vwp: u32 = 0;
            for (va[va_pe[i]..][0..va_len[i]]) |v| {
                if (nv[v] != 0 and mark_arr[v] != era) {
                    va[va_pe[i] + vwp] = v;
                    vwp += 1;
                    asum += nv[v];
                }
            }
            va_len[i] = vwp;

            // Approximate external degree = min(asum + |Lp_weighted \ nv_i| + esum, cap)
            const cap: u32 = n_amd - k - nvpiv;
            deg[i] = @min(asum + (lpsize - nv[i]) + esum, cap);
        }

        // ---- Supervariable detection: hash + compare within buckets ----
        var nhb: u32 = 0;
        for (lp_buf[0..nlp]) |i| {
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
                    if (!sameAdj(va, va_pe, va_len, ea, ea_pe, ea_len, mark_arr, &era, i, j))
                        continue;
                    // Merge j into i
                    deg[i] -= @min(deg[i], nv[j]);
                    nv[i] += nv[j];
                    nv[j] = 0;
                    // Append j's merge chain to i's
                    var tail = j;
                    while (mlink[tail] != NONE) tail = mlink[tail];
                    mlink[tail] = mlink[i];
                    mlink[i] = j;
                }
            }
            hhead[b] = NONE; // reset bucket head for next pivot step
        }

        // Reinsert live Lp members into degree buckets
        for (lp_buf[0..nlp]) |i| {
            if (nv[i] == 0) continue;
            dl.insert(deg[i], i);
            if (deg[i] < mindeg) mindeg = deg[i];
        }

        // Emit pivot p and its merge chain (mass elimination)
        q[k] = p;
        k += 1;
        var mb = mlink[p];
        while (mb != NONE) : (mb = mlink[mb]) {
            q[k] = mb;
            k += 1;
        }
    }

    // ==== Phase 4: append deferred dense rows ====
    @memcpy(q[k..][0..ndense], lp_buf[dense_start..][0..ndense]);
}

/// Compare variable and element adjacency of two vertices for supervariable
/// detection. Uses epoch-mark to avoid set sorting. Returns true iff
/// A_i = A_j and E_i = E_j (exact set equality — not closed adjacency,
/// because Lp members have been pruned from both sides already).
fn sameAdj(
    va: []const u32,
    va_pe: []const u32,
    va_len: []const u32,
    ea: []const u32,
    ea_pe: []const u32,
    ea_len: []const u32,
    mark_buf: []u32,
    era: *u32,
    i: u32,
    j: u32,
) bool {
    // Fast reject on size mismatch
    if (va_len[i] != va_len[j] or ea_len[i] != ea_len[j]) return false;
    inline for (.{ va, ea }, .{ va_pe, ea_pe }, .{ va_len, ea_len }) |adj, pos, len| {
        era.* += 1;
        const m = era.*;
        for (adj[pos[i]..][0..len[i]]) |v| mark_buf[v] = m;
        for (adj[pos[j]..][0..len[j]]) |v| {
            if (mark_buf[v] != m) return false;
        }
    }
    return true;
}
