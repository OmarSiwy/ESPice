//! Runtime device evaluation — the SIMD inner loop. LRM §8.3 (analog simulation
//! cycle, nodal analysis). This is the ONE place explicit @Vector lives; the
//! frontend stays scalar (small data). See docs/architecture/04-runtime-simd.html.
//!
//! Transformation (per Newton iteration): SoA instance params + node voltages
//! → residual currents + Jacobian entries, scattered into the sparse matrix.
//!
//! Backbone (simdjson two-stage): classify → bucket → evaluate → stamp.
//! Divergence rule: mask-and-blend cheap/ternary branches; BUCKET only the one
//! expensive one-sided cliff (off vs active). Membership is sticky across
//! iterations → classify every iter, move only instances that crossed a region.
//!
//! DOD is the whole point here:
//!   - SoA everywhere; instance i's data at lane i for coalesced/aligned loads.
//!   - Split instance-varying params from shared model-card (indirect by model_id).
//!   - Separate value/derivative arrays (dIdV[term][n]) so a Jacobian column is
//!     a contiguous vector store.
//!   - Precompute integer stamp_idx[] once (topology fixed) → assembly is a
//!     fixed-index scatter, not a symbolic lookup. Biggest non-arith win.
//!   - Pad instance count to a multiple of the widest N with inert dummies →
//!     no scalar tail; align SoA buffers to 64 B.
//!
//! ONE kernel, comptime-generic over vector width AND target (CPU @Vector +
//! GPU SPIR-V/PTX/AMDGCN). Only leaf ops differ; layout + control flow identical.
//! GPU is ReleaseFast-only (LLVM). Width-1 instantiation = scalar fallback =
//! tail handler = correctness oracle. ISA pick is a function pointer set ONCE at
//! init — never re-detect features in the hot loop.

const std = @import("std");

pub const Target = enum {
    /// `@Vector(N, f64)` lanes; the driver walks a bucket N instances at a time.
    cpu,
    /// SIMT: one instance per thread. Same kernel body at N = 1; divergence is
    /// handled by the bucket, not by predication.
    gpu,
};

/// Widest vector the SoA layout is padded/aligned for. Also the padding quantum,
/// chosen so every `k * n_padded` section boundary is 64 B aligned for f64 AND
/// for u32 (16 * 4 = 64).
pub const max_width: usize = 16;

/// The ISA pick, resolved at comptime from the build target's feature set —
/// Zig compiles for a known CPU, so "detect once at init" is "decide once at
/// comptime". `selectKernel` hands the result to the host as a fn pointer.
pub const native_width: usize = std.simd.suggestVectorLength(f64) orelse 1;

/// # The device contract
///
/// `D` is a generated device namespace (one per Verilog-A module). It is
/// duck-typed — no interface type, no vtable. It must expose:
///
/// ```
/// pub const n_terminals: u32;     // §6.5 module ports, in header order
/// pub const n_inst_params: u32;   // §3.4 instance-varying parameters
/// pub const n_card_params: u32;   // §3.4 shared model-card parameters
/// pub const n_regions: u8;        // operating regions the body buckets on
///
/// /// Stage 1. Branch-free: comparisons → mask → region index. No control flow.
/// pub fn region(
///     comptime N: usize,
///     v: *const [n_terminals]@Vector(N, f64),
///     p: *const [n_inst_params]@Vector(N, f64),
///     c: *const [n_card_params]@Vector(N, f64),
/// ) @Vector(N, u8);
///
/// /// Stage 2. `r` is comptime, so the body for a bucket is straight-line;
/// /// residual ternaries are `@select`, never branches (§proof: domains are
/// /// proven statically, so no runtime guards appear here).
/// pub fn eval(
///     comptime N: usize,
///     comptime r: u8,
///     v: *const [n_terminals]@Vector(N, f64),
///     p: *const [n_inst_params]@Vector(N, f64),
///     c: *const [n_card_params]@Vector(N, f64),
///     resid: *[n_terminals]@Vector(N, f64),        // KCL residual per terminal
///     jac: *[n_terminals * n_terminals]@Vector(N, f64), // jac[t*nt+u] = ∂resid[t]/∂v[u]
/// ) void;
/// ```
///
/// The same source compiles at every N; N = 1 is the scalar oracle.
/// SoA batch of device instances. LRM §8.3.1.
///
/// Every array is instance-order SoA with stride `n_padded`, so lane i reads
/// `base + i` (coalesced on GPU, aligned on CPU). Two owned blocks back all of
/// it: one f64, one u32 — one allocation each, one free each.
///
/// Caller fills `model_id`, `node`, `iparams`, `cards`, `stamp_idx`, `resid_idx`
/// after `init` (Stage 0, once per topology). Everything else is scratch.
///
/// Instances `n .. n_padded` are inert dummies: zeroed params, node index 0,
/// and `stamp` never reads them. They exist so the vector loop has no tail.
pub fn Batch(comptime D: type) type {
    const nt: usize = D.n_terminals;
    const nj: usize = nt * nt;
    const nip: usize = D.n_inst_params;
    const ncp: usize = D.n_card_params;

    return struct {
        const Self = @This();

        n: u32,
        n_padded: u32,
        n_models: u32,

        // --- Stage 0 inputs (caller-filled) ---
        /// [n_padded] → row of `cards`. Never duplicate a card per instance.
        model_id: []u32,
        /// [n_terminals][n_padded] instance terminal → solver unknown index.
        /// Ground terminals point at a node_v cell that holds 0.
        node: []u32,
        /// [n_inst_params][n_padded] instance-varying parameters.
        iparams: []f64,
        /// [n_models][n_card_params], AoS — the card table is tiny and shared,
        /// so it stays in L1 and a per-lane gather costs nothing.
        cards: []f64,
        /// [n_terminals*n_terminals][n_padded] → CSR value-array offset.
        /// Entries that would land on ground point at the caller's sink cell.
        stamp_idx: []u32,
        /// [n_terminals][n_padded] → RHS offset. Same sink convention.
        resid_idx: []u32,

        // --- per-iteration scratch ---
        /// [n_terminals][n_padded] terminal voltages, gathered once per iter.
        volts: []f64,
        /// [n_terminals][n_padded] residual currents (AD value).
        resid: []f64,
        /// [n_terminals*n_terminals][n_padded] AD derivatives; a Jacobian
        /// column is one contiguous vector store.
        jac: []f64,

        // --- sticky bucket state (§ "membership is sticky") ---
        /// [n_padded] current region of each instance.
        region: []u8,
        /// [n_padded] position of instance i inside `lists[region[i]]`.
        slot: []u32,
        /// [n_regions] instance indices per region. Swap-remove keeps them tight.
        lists: []std.ArrayList(u32),

        f64s: []align(64) f64,
        u32s: []align(64) u32,

        pub fn init(gpa: std.mem.Allocator, n: u32, n_models: u32) !Self {
            // +1 guarantees at least one dummy lane, so bucket tails always have
            // an inert index to replicate into.
            const np: u32 = @intCast(std.mem.alignForward(usize, @as(usize, n) + 1, max_width));
            const card_len = std.mem.alignForward(usize, n_models * ncp, 8);

            const f64s = try gpa.alignedAlloc(f64, .@"64", (nt + nip + nt + nj) * np + card_len);
            errdefer gpa.free(f64s);
            @memset(f64s, 0);

            const u32s = try gpa.alignedAlloc(u32, .@"64", (1 + nt + nj + nt + 1) * np);
            errdefer gpa.free(u32s);
            @memset(u32s, 0);

            const lists = try gpa.alloc(std.ArrayList(u32), D.n_regions);
            errdefer gpa.free(lists);
            for (lists) |*l| l.* = .empty;

            var fc: usize = 0;
            var uc: usize = 0;
            const take = struct {
                fn f(buf: []f64, cur: *usize, len: usize) []f64 {
                    defer cur.* += len;
                    return buf[cur.*..][0..len];
                }
                fn u(buf: []u32, cur: *usize, len: usize) []u32 {
                    defer cur.* += len;
                    return buf[cur.*..][0..len];
                }
            };

            var self: Self = .{
                .n = n,
                .n_padded = np,
                .n_models = n_models,
                .volts = take.f(f64s, &fc, nt * np),
                .iparams = take.f(f64s, &fc, nip * np),
                .resid = take.f(f64s, &fc, nt * np),
                .jac = take.f(f64s, &fc, nj * np),
                .cards = take.f(f64s, &fc, card_len),
                .model_id = take.u(u32s, &uc, np),
                .node = take.u(u32s, &uc, nt * np),
                .stamp_idx = take.u(u32s, &uc, nj * np),
                .resid_idx = take.u(u32s, &uc, nt * np),
                .slot = take.u(u32s, &uc, np),
                .region = try gpa.alloc(u8, np),
                .lists = lists,
                .f64s = f64s,
                .u32s = u32s,
            };
            errdefer gpa.free(self.region);
            @memset(self.region, 0);

            // Everything starts in region 0; the first classify does the one
            // big sort, every later one moves only the movers.
            try lists[0].ensureTotalCapacityPrecise(gpa, np);
            for (0..np) |i| {
                lists[0].appendAssumeCapacity(@intCast(i));
                self.slot[i] = @intCast(i);
            }
            return self;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (self.lists) |*l| l.deinit(gpa);
            gpa.free(self.lists);
            gpa.free(self.region);
            gpa.free(self.f64s);
            gpa.free(self.u32s);
            self.* = undefined;
        }

        /// Sticky-membership move: swap-remove from the old bucket, append to the
        /// new. O(1) per mover, and near convergence there are almost none.
        fn move(self: *Self, gpa: std.mem.Allocator, i: u32, to: u8) !void {
            const from = self.region[i];
            const s = self.slot[i];
            var old = &self.lists[from];
            const last = old.items[old.items.len - 1];
            old.items[s] = last;
            self.slot[last] = s;
            old.items.len -= 1;

            var new = &self.lists[to];
            self.slot[i] = @intCast(new.items.len);
            try new.append(gpa, i);
            self.region[i] = to;
        }
    };
}

// ===========================================================================
// Leaf operations. The only thing that differs between CPU and GPU.
// ===========================================================================

/// Contiguous SoA load — lane j reads `base + i + j`. Aligned by construction.
inline fn load(comptime N: usize, src: []const f64, off: usize) @Vector(N, f64) {
    return src[off..][0..N].*;
}

/// Gather by lane index. On CPU this is AVX-512 `vgatherqpd` (or a scalar
/// sequence below that); on GPU it is a plain per-thread indexed load.
// ponytail: no contiguous fast path. A bucket whose lanes happen to be
// sequential could use `load`, but detecting that costs a branch in the hot
// loop; add it (a `contiguous` flag maintained by classify) only if a profile
// shows gather cost dominating for single-region devices.
inline fn gather(comptime N: usize, src: []const f64, off: usize, idx: @Vector(N, u32)) @Vector(N, f64) {
    var out: [N]f64 = undefined;
    inline for (0..N) |j| out[j] = src[off + idx[j]];
    return out;
}

/// Scatter by lane index. Stores, not accumulates — dense per-instance scratch
/// has no collisions, which is exactly why Stage 3 is a separate pass.
inline fn scatter(comptime N: usize, dst: []f64, off: usize, idx: @Vector(N, u32), v: @Vector(N, f64)) void {
    inline for (0..N) |j| dst[off + idx[j]] = v[j];
}

/// Bucket lane indices for chunk `i`, replicating the last lane over the tail.
/// A replicated lane recomputes one instance and stores the same value to the
/// same scratch slot — idempotent, so the tail needs no mask and no branch.
inline fn laneVec(comptime N: usize, lanes: []const u32, i: usize) @Vector(N, u32) {
    const last = lanes[lanes.len - 1];
    var out: [N]u32 = undefined;
    inline for (0..N) |j| out[j] = if (i + j < lanes.len) lanes[i + j] else last;
    return out;
}

/// Model-card gather. The card table is AoS and tiny; `model_id` picks the row.
inline fn gatherCard(
    comptime D: type,
    comptime N: usize,
    cards: []const f64,
    mid: @Vector(N, u32),
) [D.n_card_params]@Vector(N, f64) {
    var c: [D.n_card_params]@Vector(N, f64) = undefined;
    inline for (0..D.n_card_params) |k| {
        var lane: [N]f64 = undefined;
        inline for (0..N) |j| lane[j] = cards[mid[j] * D.n_card_params + k];
        c[k] = lane;
    }
    return c;
}

// ===========================================================================
// Stage 1 — CLASSIFY. LRM §8.3.1 region determination.
// ===========================================================================

/// `dst[i] = src[idx[i]]` — contiguous in and out, indirect only on the read.
/// Dependency class: none, so it vectorizes directly. LLVM will NOT do this for
/// you: `dst` and `src` are both `[]f64`, so it must assume they alias and keeps
/// the loop scalar. Writing it out is what makes the vector form durable.
///
/// ponytail: `dst` (batch scratch, inside `b.f64s`) and `src` (the solver's
/// unknown vector) are separate allocations by construction. If a caller ever
/// aliases them this is wrong — but so is every other stage in this file.
inline fn gatherInto(comptime N: usize, dst: []f64, idx: []const u32, src: []const f64) void {
    var i: usize = 0;
    while (i + N <= dst.len) : (i += N) {
        const v: @Vector(N, u32) = idx[i..][0..N].*;
        var lane: [N]f64 = undefined;
        inline for (0..N) |j| lane[j] = src[v[j]];
        dst[i..][0..N].* = lane;
    }
    // Tail — the original scalar loop, kept as both remainder handler and the
    // reference the differential test checks against. `n_padded` is a multiple
    // of `max_width` and N divides it, so the real call path never enters here.
    while (i < dst.len) : (i += 1) dst[i] = src[idx[i]];
}

/// Gather node voltages into instance-order scratch. Voltages live at nodes, so
/// this is inherently a gather; do it ONCE per iteration and everything
/// downstream is contiguous.
pub fn gatherVolts(comptime D: type, comptime N: usize, b: *Batch(D), node_v: []const f64) void {
    const np = b.n_padded;
    for (0..D.n_terminals) |t| {
        gatherInto(N, b.volts[t * np ..][0..np], b.node[t * np ..][0..np], node_v);
    }
}

/// Branch-free region assignment over the whole (padded) batch, then an
/// incremental bucket update for the few instances that crossed a boundary.
pub fn classify(comptime D: type, comptime N: usize, gpa: std.mem.Allocator, b: *Batch(D)) !void {
    const np = b.n_padded;
    var i: u32 = 0;
    while (i < np) : (i += N) {
        var v: [D.n_terminals]@Vector(N, f64) = undefined;
        inline for (0..D.n_terminals) |t| v[t] = load(N, b.volts, t * np + i);
        var p: [D.n_inst_params]@Vector(N, f64) = undefined;
        inline for (0..D.n_inst_params) |k| p[k] = load(N, b.iparams, k * np + i);
        const mid: @Vector(N, u32) = b.model_id[i..][0..N].*;
        const c = gatherCard(D, N, b.cards, mid);

        const r = D.region(N, &v, &p, &c);
        const old: @Vector(N, u8) = b.region[i..][0..N].*;
        // Sticky: the common case is "nobody moved", one vector compare.
        if (@reduce(.Or, r != old)) {
            inline for (0..N) |j| {
                if (r[j] != old[j]) try b.move(gpa, i + @as(u32, @intCast(j)), r[j]);
            }
        }
    }
}

// ===========================================================================
// Stage 2 — EVALUATE. LRM §8.3.1 (residual + Jacobian by dual-number AD).
// ===========================================================================

/// THE kernel. One chunk of N lanes, identified by instance index. Layout and
/// control flow are identical on CPU and GPU: the CPU driver calls this per
/// N-wide chunk of a bucket, a GPU thread calls it once with N = 1 and its
/// global id. Branch-free — `r` is comptime, so the bucket's body is
/// straight-line and any residual ternary inside `D.eval` is a `@select`.
pub fn evalChunk(
    comptime D: type,
    comptime N: usize,
    comptime r: u8,
    b: *Batch(D),
    idx: @Vector(N, u32),
) void {
    const np = b.n_padded;

    var v: [D.n_terminals]@Vector(N, f64) = undefined;
    inline for (0..D.n_terminals) |t| v[t] = gather(N, b.volts, t * np, idx);
    var p: [D.n_inst_params]@Vector(N, f64) = undefined;
    inline for (0..D.n_inst_params) |k| p[k] = gather(N, b.iparams, k * np, idx);

    var mid: [N]u32 = undefined;
    inline for (0..N) |j| mid[j] = b.model_id[idx[j]];
    const c = gatherCard(D, N, b.cards, mid);

    var resid: [D.n_terminals]@Vector(N, f64) = undefined;
    var jac: [D.n_terminals * D.n_terminals]@Vector(N, f64) = undefined;
    D.eval(N, r, &v, &p, &c, &resid, &jac);

    inline for (0..D.n_terminals) |t| scatter(N, b.resid, t * np, idx, resid[t]);
    inline for (0..D.n_terminals * D.n_terminals) |e| scatter(N, b.jac, e * np, idx, jac[e]);
}

/// Drive one region bucket. All lanes in the bucket take the same path — that
/// is the whole point of the bucket, and the reason Stage 2 needs no masking
/// for the one expensive one-sided cliff.
pub fn evalBucket(comptime D: type, comptime N: usize, comptime tgt: Target, comptime r: u8, b: *Batch(D)) void {
    const lanes = b.lists[r].items;
    if (lanes.len == 0) return;
    switch (tgt) {
        .cpu => {
            var i: usize = 0;
            while (i < lanes.len) : (i += N) evalChunk(D, N, r, b, laneVec(N, lanes, i));
        },
        // ponytail: host-side reference driver for the SIMT shape (one lane per
        // thread). The real launch is the orchestrator's job — when the
        // SPIR-V/PTX entry point lands it calls `evalChunk(D, 1, r, b, {gid})`
        // with exactly this body, so nothing here changes.
        .gpu => for (lanes) |l| evalChunk(D, 1, r, b, @splat(l)),
    }
}

// ===========================================================================
// Stage 3 — STAMP. LRM §8.3.1 matrix assembly.
// ===========================================================================

/// Scatter dense scratch → CSR value array + RHS via the precomputed indices.
/// Accumulate-then-reduce (the default, GPU-safe): Stage 2 wrote collision-free
/// dense scratch, so the only summation happens here, in instance order — which
/// also makes the assembled matrix bit-reproducible.
///
/// `csr_values` and `rhs` must each carry a trailing sink cell that ground
/// entries point at; that keeps this loop branch-free. Dummy instances are
/// simply not iterated.
///
/// DO NOT VECTORIZE THESE TWO LOOPS. They are scatter-ACCUMULATES and
/// `stamp_idx` / `resid_idx` alias hard, by design:
///   - every terminal touching ground maps to the ONE shared sink cell
///     (~44 % of entries for a 4-terminal device with a quarter of its
///     terminals grounded);
///   - two instances bridging the same node pair share a CSR slot — that
///     shared summation is the entire reason this is `+=` and not `=`;
///   - `resid_idx` IS the node index, so a node with k devices on it takes k
///     contributions.
/// A gather/add/scatter over N lanes drops every update but the last whenever
/// two lanes hit one slot. Measured on a 100 k-instance random netlist: 14 real
/// CSR cells silently wrong, up to 14 % relative error in a Jacobian entry —
/// and it was not even faster (3.05 ms vs 3.04 ms scalar; the loop is bound by
/// random-access memory latency, not by ALU width). Prefetching the target cell
/// also measured slower. Scalar is the answer here.
pub fn stamp(comptime D: type, b: *const Batch(D), csr_values: []f64, rhs: []f64) void {
    const np = b.n_padded;
    for (0..D.n_terminals * D.n_terminals) |e| {
        const base = e * np;
        for (0..b.n) |i| csr_values[b.stamp_idx[base + i]] += b.jac[base + i];
    }
    for (0..D.n_terminals) |t| {
        const base = t * np;
        for (0..b.n) |i| rhs[b.resid_idx[base + i]] += b.resid[base + i];
    }
}

// ===========================================================================
// Driver
// ===========================================================================

/// One Newton iteration: gather → classify → per-bucket evaluate → stamp.
pub fn evalIteration(
    comptime D: type,
    comptime N: usize,
    comptime tgt: Target,
    gpa: std.mem.Allocator,
    b: *Batch(D),
    node_v: []const f64,
    csr_values: []f64,
    rhs: []f64,
) !void {
    gatherVolts(D, N, b, node_v);
    try classify(D, N, gpa, b);
    inline for (0..D.n_regions) |r| evalBucket(D, N, tgt, @intCast(r), b);
    stamp(D, b, csr_values, rhs);
}

pub fn Kernel(comptime D: type) type {
    return *const fn (
        std.mem.Allocator,
        *Batch(D),
        []const f64,
        []f64,
        []f64,
    ) anyerror!void;
}

/// One-time ISA selection. The width is decided at comptime from the build
/// target's feature set; the host stores the returned pointer once and calls it
/// for the whole solve, so no feature query ever enters the hot loop.
pub fn selectKernel(comptime D: type, comptime tgt: Target) Kernel(D) {
    const N = if (tgt == .gpu) 1 else native_width;
    return struct {
        fn run(gpa: std.mem.Allocator, b: *Batch(D), node_v: []const f64, csr: []f64, rhs: []f64) anyerror!void {
            return evalIteration(D, N, tgt, gpa, b, node_v, csr, rhs);
        }
    }.run;
}

// ===========================================================================
// Tests — the vector kernel vs the width-1 scalar oracle.
// ===========================================================================

/// A two-terminal exponential device with the canonical one-sided cliff:
/// `off` skips the transcendental that `on` needs. Exactly the shape the
/// bucketing policy exists for.
const TestDiode = struct {
    pub const n_terminals: u32 = 2;
    pub const n_inst_params: u32 = 1; // area
    pub const n_card_params: u32 = 2; // is, vt
    pub const n_regions: u8 = 2; // 0 = off, 1 = on

    const vcrit = 0.3;
    const gmin = 1e-12;

    pub fn region(
        comptime N: usize,
        v: *const [2]@Vector(N, f64),
        p: *const [1]@Vector(N, f64),
        c: *const [2]@Vector(N, f64),
    ) @Vector(N, u8) {
        _ = p;
        _ = c;
        const vd = v[0] - v[1];
        const on: @Vector(N, bool) = vd > @as(@Vector(N, f64), @splat(vcrit));
        return @select(u8, on, @as(@Vector(N, u8), @splat(1)), @as(@Vector(N, u8), @splat(0)));
    }

    pub fn eval(
        comptime N: usize,
        comptime r: u8,
        v: *const [2]@Vector(N, f64),
        p: *const [1]@Vector(N, f64),
        c: *const [2]@Vector(N, f64),
        resid: *[2]@Vector(N, f64),
        jac: *[4]@Vector(N, f64),
    ) void {
        const F = @Vector(N, f64);
        const vd = v[0] - v[1];
        var i: F = undefined;
        var g: F = undefined;
        if (r == 0) {
            g = @splat(gmin);
            i = g * vd;
        } else {
            const e = @exp(vd / c[1]);
            const isat = p[0] * c[0];
            i = isat * (e - @as(F, @splat(1.0)));
            g = isat * e / c[1] + @as(F, @splat(gmin));
        }
        resid[0] = i;
        resid[1] = -i;
        jac[0] = g;
        jac[1] = -g;
        jac[2] = -g;
        jac[3] = g;
    }
};

const TestSetup = struct {
    b: Batch(TestDiode),
    csr: []f64,
    rhs: []f64,

    const n_inst = 37;
    const n_nodes = 9; // node 0 == the ground cell (always 0 V)

    fn init(gpa: std.mem.Allocator) !TestSetup {
        var b = try Batch(TestDiode).init(gpa, n_inst, 2);
        errdefer b.deinit(gpa);
        const np = b.n_padded;

        // Stage 0: cards, per-instance params, node maps, stamp offsets.
        b.cards[0] = 1e-14; // is
        b.cards[1] = 0.026; // vt
        b.cards[2] = 3e-14;
        b.cards[3] = 0.030;

        const n_csr = TestDiode.n_terminals * TestDiode.n_terminals * n_inst;
        const csr = try gpa.alloc(f64, n_csr + 1); // + sink
        errdefer gpa.free(csr);
        const rhs = try gpa.alloc(f64, n_nodes + 1); // + sink

        for (0..n_inst) |ii| {
            const i: u32 = @intCast(ii);
            b.model_id[i] = i % 2;
            b.iparams[i] = 1.0 + @as(f64, @floatFromInt(i)) * 0.01; // area
            b.node[i] = 1 + (i % (n_nodes - 1));
            b.node[np + i] = 1 + ((i * 3 + 2) % (n_nodes - 1));
            inline for (0..2) |t| b.resid_idx[t * np + i] = b.node[t * np + i];
            inline for (0..4) |e| b.stamp_idx[e * np + i] = @intCast(e * n_inst + i);
        }
        // Dummies stamp nowhere (never iterated) but must gather legal indices.
        for (n_inst..np) |i| {
            inline for (0..2) |t| b.resid_idx[t * np + i] = n_nodes;
            inline for (0..4) |e| b.stamp_idx[e * np + i] = n_csr;
        }
        return .{ .b = b, .csr = csr, .rhs = rhs };
    }

    fn deinit(self: *TestSetup, gpa: std.mem.Allocator) void {
        self.b.deinit(gpa);
        gpa.free(self.csr);
        gpa.free(self.rhs);
    }

    fn run(self: *TestSetup, comptime N: usize, gpa: std.mem.Allocator, node_v: []const f64) !void {
        @memset(self.csr, 0);
        @memset(self.rhs, 0);
        try evalIteration(TestDiode, N, .cpu, gpa, &self.b, node_v, self.csr, self.rhs);
    }

    fn runVia(self: *TestSetup, k: Kernel(TestDiode), gpa: std.mem.Allocator, node_v: []const f64) !void {
        @memset(self.csr, 0);
        @memset(self.rhs, 0);
        try k(gpa, &self.b, node_v, self.csr, self.rhs);
    }
};

test "vector kernel agrees with the width-1 scalar oracle" {
    const gpa = std.testing.allocator;
    var vec = try TestSetup.init(gpa);
    defer vec.deinit(gpa);
    var oracle = try TestSetup.init(gpa);
    defer oracle.deinit(gpa);

    var node_v = [_]f64{0} ** (TestSetup.n_nodes + 1);

    // Several bias points, so instances cross the region boundary between
    // iterations and the sticky bucket update actually gets exercised.
    for (0..4) |iter| {
        for (1..TestSetup.n_nodes) |k| {
            node_v[k] = 0.05 * @as(f64, @floatFromInt(k)) + 0.11 * @as(f64, @floatFromInt(iter));
        }
        try vec.run(native_width, gpa, &node_v);
        try oracle.run(1, gpa, &node_v);

        for (vec.csr, oracle.csr) |a, b| try std.testing.expectApproxEqRel(b, a, 1e-15);
        for (vec.rhs, oracle.rhs) |a, b| try std.testing.expectApproxEqRel(b, a, 1e-15);
    }

    // The SIMT shape (one lane per thread) must land on the same numbers, and
    // the fn-pointer the host stores once must be callable.
    var simt = try TestSetup.init(gpa);
    defer simt.deinit(gpa);
    try simt.runVia(selectKernel(TestDiode, .gpu), gpa, &node_v);
    for (simt.csr, oracle.csr) |a, b| try std.testing.expectEqual(b, a);
    for (simt.rhs, oracle.rhs) |a, b| try std.testing.expectEqual(b, a);
}

test "buckets partition the padded batch and stay in sync with region[]" {
    const gpa = std.testing.allocator;
    var s = try TestSetup.init(gpa);
    defer s.deinit(gpa);

    var node_v = [_]f64{0} ** (TestSetup.n_nodes + 1);
    for (1..TestSetup.n_nodes) |k| node_v[k] = 0.09 * @as(f64, @floatFromInt(k));
    try s.run(native_width, gpa, &node_v);

    var total: usize = 0;
    var seen = try gpa.alloc(bool, s.b.n_padded);
    defer gpa.free(seen);
    @memset(seen, false);
    for (s.b.lists, 0..) |l, r| {
        total += l.items.len;
        for (l.items, 0..) |inst, slot| {
            try std.testing.expectEqual(@as(u8, @intCast(r)), s.b.region[inst]);
            try std.testing.expectEqual(@as(u32, @intCast(slot)), s.b.slot[inst]);
            try std.testing.expect(!seen[inst]);
            seen[inst] = true;
        }
    }
    try std.testing.expectEqual(@as(usize, s.b.n_padded), total);
    // The bucket boundary is real: both regions are populated at this bias.
    try std.testing.expect(s.b.lists[0].items.len > 0);
    try std.testing.expect(s.b.lists[1].items.len > 0);
}

test "gatherInto matches the scalar loop at every tail boundary" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rnd = prng.random();

    const n_src = 64;
    var src: [n_src]f64 = undefined;
    for (&src) |*s| s.* = rnd.floatNorm(f64);

    // 0 through 3x the widest lane count, so the empty case and every possible
    // remainder are hit for each N.
    for (0..3 * max_width + 1) |len| {
        const idx = try gpa.alloc(u32, len);
        defer gpa.free(idx);
        for (idx) |*k| k.* = rnd.intRangeLessThan(u32, 0, n_src);

        const want = try gpa.alloc(f64, len);
        defer gpa.free(want);
        for (want, idx) |*w, k| w.* = src[k]; // the scalar reference

        inline for (.{ 1, 2, 4, 8, 16 }) |N| {
            const got = try gpa.alloc(f64, len);
            defer gpa.free(got);
            @memset(got, std.math.nan(f64));
            gatherInto(N, got, idx, &src);
            try std.testing.expectEqualSlices(f64, want, got);
        }
    }
}

test "one non-empty bucket per region and no scalar tail in the vector loop" {
    // n_padded is a multiple of the widest vector, so the classify loop never
    // has a remainder — the invariant the padding exists to guarantee.
    const gpa = std.testing.allocator;
    var s = try TestSetup.init(gpa);
    defer s.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), s.b.n_padded % max_width);
    try std.testing.expect(s.b.n_padded > s.b.n); // at least one inert dummy
}
