//! Standalone sparse LU kernel: left-looking Gilbert–Peierls factorization
//! with threshold partial pivoting, numeric refactorization on a frozen
//! pattern, forward/back substitution, and transpose solve.
//!
//! This is a pure computation module — no ordering, no BTF, no higher-level
//! solver facade. The column permutation `q` is supplied by the caller.
//!
//! Algorithm reference: gilbert-peierls-lu.md, klu-pipeline.md
//!
//! Data layout: SoA with hot/cold split. Iteration-hot arrays (lp/up/udiag,
//! li/lx, ui/ux, w, pinv, q) are contiguous; DFS workspace (flag/topo/
//! stack/pstack) is cold (touched only during full factor). prow is cold
//! (touched only during refactor scatter).

const std = @import("std");
const Allocator = std.mem.Allocator;

const NONE: u32 = std.math.maxInt(u32);

pub fn SparseLu(comptime T: type) type {
    comptime {
        std.debug.assert(T == f32 or T == f64);
    }

    return struct {
        const Self = @This();

        pub const FactorError = error{ OutOfMemory, SingularMatrix };

        // ---- dimensions ----
        n: u32,

        // ---- permutations (length n) ----
        q: []const u32, // column ordering: pivot step k factors column q[k] — NOT owned
        pinv: []u32, // original row → pivot step

        // ---- L (strictly lower, unit diagonal) — CSC over pivot steps ----
        // Row indices are in PERMUTED coordinates after factor().
        lp: []u32, // column pointers, length n+1
        li: std.ArrayList(u32) = .empty, // row indices (permuted)
        lx: std.ArrayList(T) = .empty, // values

        // ---- U (strictly upper) — CSC over pivot steps ----
        // Row indices stored in the topological solve order so refactor replays.
        up: []u32, // column pointers, length n+1
        ui: std.ArrayList(u32) = .empty, // row indices (pivot-step coords)
        ux: std.ArrayList(T) = .empty, // values
        udiag: []T, // diagonal of U, length n

        // ---- refactor scatter tape (length nnz(A)) ----
        // prow[p] = pinv[row_idx[p]]: maps A's structural entries to permuted rows.
        prow: []u32,

        /// Pivot steps that factored a STRUCTURALLY VOID unknown — see
        /// `voidUnknown`. `refactor` must replay the fabricated unit pivot
        /// instead of reading a zero out of `w` and reporting singularity.
        void_col: []bool,
        // CSC entries touching a fabricated pivot's row or column. Reuse is
        // valid only while these stay zero; parameter changes can activate them.
        void_slots: std.ArrayList(u32) = .empty,

        /// Pivot steps whose diagonal was accepted only by the ROW-SCALED
        /// threshold test. Such a pivot is legitimately orders below its own
        /// column max, so `refactor`'s raw growth monitor would reject every
        /// replay of the tape — it is skipped for these steps.
        scaled_pivot: []bool,

        // ---- hot workspace (length n each) ----
        /// Dense accumulator. INVARIANT: all-zero on entry to and exit from
        /// every public entry point, error returns included. `factor` needs it
        /// (a fill row it never scatters must read 0), and `refactor` needs it
        /// because it dropped the per-column zero-the-pattern prologue: each
        /// column zeroes its own slots as it consumes them instead.
        w: []T,
        y: []T, // solve workspace
        /// Implicit row scaling for the pivot test: rscale[r] = 1/max_j|A[r][j]|
        /// (1 for an all-zero or non-finite row). Indexed by ORIGINAL row,
        /// recomputed once per full `factor`; `refactor` never reads it.
        rscale: []T,

        // ---- cold workspace (length n each, used only in factor) ----
        flag: []u32, // epoch-based DFS visited marker
        topo: []u32, // topological finish order
        stack: []u32, // DFS vertex stack
        pstack: []u32, // DFS position stack (resume offset into L adjacency)

        factored: bool = false,

        /// Allocate all workspace. `q` is the caller's column permutation
        /// (borrowed, not copied — must outlive the SparseLu).
        pub fn init(
            gpa: Allocator,
            n: u32,
            col_ptr: []const u32,
            row_idx: []const u32,
            q: []const u32,
        ) !Self {
            _ = row_idx;
            const nnz = col_ptr[n];
            // ponytail: pre-size L/U to ~2x nnz — typical circuit fill; avoids
            // ArrayList growth during first factor. Upgrade: profile and tune.
            const est_lu: usize = @max(nnz, 2 * @as(usize, n));

            var self = Self{
                .n = n,
                .q = q,
                .pinv = &.{},
                .lp = &.{},
                .up = &.{},
                .udiag = &.{},
                .prow = &.{},
                .void_col = &.{},
                .scaled_pivot = &.{},
                .w = &.{},
                .y = &.{},
                .rscale = &.{},
                .flag = &.{},
                .topo = &.{},
                .stack = &.{},
                .pstack = &.{},
            };
            errdefer self.deinit(gpa);
            self.pinv = try gpa.alloc(u32, n);
            self.lp = try gpa.alloc(u32, @as(usize, n) + 1);
            self.up = try gpa.alloc(u32, @as(usize, n) + 1);
            self.udiag = try gpa.alloc(T, n);
            self.prow = try gpa.alloc(u32, nnz);
            self.void_col = try gpa.alloc(bool, n);
            self.scaled_pivot = try gpa.alloc(bool, n);
            self.w = try gpa.alloc(T, n);
            self.y = try gpa.alloc(T, n);
            self.rscale = try gpa.alloc(T, n);
            self.flag = try gpa.alloc(u32, n);
            self.topo = try gpa.alloc(u32, n);
            self.stack = try gpa.alloc(u32, n);
            self.pstack = try gpa.alloc(u32, n);
            try self.li.ensureTotalCapacity(gpa, est_lu);
            try self.lx.ensureTotalCapacity(gpa, est_lu);
            try self.ui.ensureTotalCapacity(gpa, est_lu);
            try self.ux.ensureTotalCapacity(gpa, est_lu);
            @memset(self.w, 0);
            return self;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            inline for (.{ self.pinv, self.lp, self.up, self.prow, self.flag, self.topo, self.stack, self.pstack }) |s|
                gpa.free(s);
            gpa.free(self.void_col);
            gpa.free(self.scaled_pivot);
            self.void_slots.deinit(gpa);
            inline for (.{ self.udiag, self.w, self.y, self.rscale }) |s|
                gpa.free(s);
            self.li.deinit(gpa);
            self.lx.deinit(gpa);
            self.ui.deinit(gpa);
            self.ux.deinit(gpa);
        }

        // ====================================================================
        // factor: full symbolic + numeric factorization with threshold pivoting
        // ====================================================================

        /// Full factorization: DFS reach → sparse triangular solve → threshold
        /// partial pivoting → store L/U columns. Builds the sparsity pattern,
        /// pivot sequence, and refactor scatter tape (prow).
        pub fn factor(
            self: *Self,
            gpa: Allocator,
            col_ptr: []const u32,
            row_idx: []const u32,
            vals: []const T,
            pivot_tol: T,
        ) FactorError!void {
            const n = self.n;
            self.factored = false;
            @memset(self.pinv, NONE);
            @memset(self.flag, 0);
            @memset(self.void_col, false);
            @memset(self.scaled_pivot, false);
            self.void_slots.clearRetainingCapacity();
            var has_void = false;
            self.li.clearRetainingCapacity();
            self.lx.clearRetainingCapacity();
            self.ui.clearRetainingCapacity();
            self.ux.clearRetainingCapacity();

            // ---- implicit row scaling for the pivot test ----
            // Threshold PARTIAL pivoting compares candidates in whatever units
            // each device wrote its KCL row in, so the choice is not invariant
            // under row scaling. One O(nnz) pass records 1/max|A[r,:]| so the
            // diagonal test below can be retried in the scale-free metric.
            // Runs only on a FULL factor; `refactor` never pays for it.
            @memset(self.rscale, 0); // running row max, inverted in place below
            for (0..n) |j| {
                for (col_ptr[j]..col_ptr[j + 1]) |p|
                    self.rscale[row_idx[p]] = @max(self.rscale[row_idx[p]], @abs(vals[p]));
            }
            for (self.rscale) |*s|
                s.* = if (s.* > 0 and std.math.isFinite(s.*)) 1 / s.* else 1;

            for (0..n) |k| {
                const c = self.q[k];
                self.lp[k] = @intCast(self.li.items.len);
                self.up[k] = @intCast(self.ui.items.len);
                const mark: u32 = @intCast(k + 1);

                // ---- symbolic: DFS reach from pattern of A[:,c] through G(L) ----
                var nt: u32 = 0;
                for (col_ptr[c]..col_ptr[c + 1]) |p| {
                    var r = row_idx[p];
                    if (self.flag[r] == mark) continue;
                    var sp: u32 = 0;
                    self.stack[sp] = r;
                    self.pstack[sp] = if (self.pinv[r] == NONE) NONE else self.lp[self.pinv[r]];
                    self.flag[r] = mark;
                    while (true) {
                        r = self.stack[sp];
                        const kc = self.pinv[r];
                        const end = if (kc == NONE) NONE else self.lp[kc + 1];
                        var descended = false;
                        while (self.pstack[sp] != NONE and self.pstack[sp] < end) {
                            const child = self.li.items[self.pstack[sp]];
                            self.pstack[sp] += 1;
                            if (self.flag[child] != mark) {
                                self.flag[child] = mark;
                                sp += 1;
                                self.stack[sp] = child;
                                self.pstack[sp] = if (self.pinv[child] == NONE) NONE else self.lp[self.pinv[child]];
                                descended = true;
                                break;
                            }
                        }
                        if (descended) continue;
                        self.topo[nt] = r;
                        nt += 1;
                        if (sp == 0) break;
                        sp -= 1;
                    }
                }

                // ---- scatter A[:,c] into dense workspace ----
                for (col_ptr[c]..col_ptr[c + 1]) |p| self.w[row_idx[p]] = vals[p];

                // ---- sparse triangular solve in reverse finish (topo) order ----
                var idx: u32 = nt;
                while (idx > 0) {
                    idx -= 1;
                    const r = self.topo[idx];
                    const kc = self.pinv[r];
                    if (kc == NONE) continue;
                    const ukr = self.w[r];
                    // ponytail: ArrayList already returns only OutOfMemory.
                    try self.ui.append(gpa, kc);
                    try self.ux.append(gpa, ukr);
                    for (self.lp[kc]..self.lp[kc + 1]) |lp| {
                        self.w[self.li.items[lp]] -= self.lx.items[lp] * ukr;
                    }
                }

                // ---- threshold partial pivoting, diagonal preferred ----
                // Two magnitudes per candidate. `amax` is the raw column max:
                // it picks the off-diagonal fallback and gates singularity,
                // exactly as before. `smax` is the same max taken in the
                // implicit row scaling — that is what the diagonal test falls
                // back to, so an equation living decades below the rest of the
                // matrix is still allowed to own its own unknown.
                var amax: T = 0;
                var smax: T = 0;
                var piv: u32 = NONE;
                for (self.topo[0..nt]) |r| {
                    if (self.pinv[r] != NONE) continue;
                    const a = @abs(self.w[r]);
                    if (a > amax) {
                        amax = a;
                        piv = r;
                    }
                    smax = @max(smax, a * self.rscale[r]);
                }
                if (piv == NONE or amax == 0 or !std.math.isFinite(amax)) {
                    // A column with no nonzero unpivoted candidate is normally
                    // a singular circuit — but not always. A compact model can
                    // STRUCTURALLY DISABLE part of itself (HICUM's thermal tie
                    // `V(br_sht) <+ 0` when flsh = 0, BSIM4/BSIMSOI/HiSIM do the
                    // same for their self-heating nodes), and Verilog-A cannot
                    // delete a node: the branch-flow unknown survives with an
                    // all-zero row AND an all-zero column. Unknown x_c then
                    // appears in no equation at all, which is not a singular
                    // system, it is a system with one free variable — and the
                    // ground row this simulator already pins with a unit
                    // diagonal is the same situation.
                    //
                    // Fabricating A[c][c] = 1 is sound ONLY when row c is void
                    // too, i.e. equation c reads 0 = b_c; then the unit pivot
                    // means x_c = b_c, and a b_c that is not zero cannot pass
                    // the Newton residual gate, so an inconsistent system still
                    // reports as unconverged rather than silently solving.
                    // `voidUnknown` costs O(nnz) and only runs on this path.
                    //
                    // Before this, devices/hicum2_output failed the plain
                    // Newton factor at EVERY one of its 1809 DC points and paid
                    // the whole gmin + source-stepping continuation ladder for
                    // each: 68772 Newton iterations against ngspice's ~5000,
                    // 0.93 s against 0.02 s.
                    if (!self.voidUnknown(col_ptr, row_idx, vals, c)) return error.SingularMatrix;
                    self.void_col[k] = true;
                    has_void = true;
                    self.udiag[k] = 1;
                    self.pinv[c] = @intCast(k);
                    for (self.topo[0..nt]) |r| self.w[r] = 0;
                    continue;
                }
                if (self.pinv[c] == NONE) {
                    const dmag = @abs(self.w[c]);
                    if (dmag >= pivot_tol * amax) {
                        piv = c;
                    } else if (dmag > 0 and dmag * self.rscale[c] >= pivot_tol * smax) {
                        // The raw test rejected a diagonal that is the biggest
                        // entry of the column MEASURED AGAINST ITS OWN EQUATION.
                        // A BSIMSOI floating body at default junction params is
                        // exactly this: every entry of the body KCL row is
                        // ~1e-18 S while Gmbs ~1e-4 S sits in the same COLUMN on
                        // the drain row. Eliminating the body column through the
                        // drain row rebuilds the body equation out of numbers
                        // 1e14 times its own size and dx_body becomes drain-row
                        // rounding noise divided by Gmbs (observed: -13.9 V).
                        // ngspice dodges this by DEFERRING the pair — Sparse 1.3
                        // permutes rows and columns together (spfactor.c
                        // ExchangeRowsAndCols), which a fixed BTF+AMD column
                        // order cannot do. See docs/spice-audit-2026-09.md.
                        // ponytail: implicit scaling of the CHOICE only; the
                        // upgrade is full row equilibration (KLU Common->scale=2)
                        // if a fixture ever needs the arithmetic scaled too.
                        piv = c;
                        self.scaled_pivot[k] = true;
                    }
                }
                const d = self.w[piv];
                self.udiag[k] = d;
                self.pinv[piv] = @intCast(k);

                // ---- store L[:,k] (scaled unpivoted candidates), clear w ----
                for (self.topo[0..nt]) |r| {
                    if (self.pinv[r] == NONE) {
                        try self.li.append(gpa, r);
                        try self.lx.append(gpa, self.w[r] / d);
                    }
                    self.w[r] = 0;
                }
            }
            self.lp[n] = @intCast(self.li.items.len);
            self.up[n] = @intCast(self.ui.items.len);

            // L row indices: original → permuted coordinates
            for (self.li.items) |*r| r.* = self.pinv[r.*];

            // Build refactor scatter tape: prow[p] = pinv[row_idx[p]]
            for (row_idx[0..self.prow.len], self.prow) |r, *pr| pr.* = self.pinv[r];

            if (has_void) {
                var count: usize = 0;
                for (self.q, 0..) |c, k| {
                    for (col_ptr[c]..col_ptr[c + 1]) |p|
                        count += @intFromBool(self.void_col[k] or self.void_col[self.prow[p]]);
                }
                try self.void_slots.ensureTotalCapacityPrecise(gpa, count);
                for (self.q, 0..) |c, k| {
                    for (col_ptr[c]..col_ptr[c + 1]) |p| {
                        if (self.void_col[k] or self.void_col[self.prow[p]])
                            self.void_slots.appendAssumeCapacity(@intCast(p));
                    }
                }
            }

            // ZP_LU_STATS: one line per full factor — n, input nnz, fill.
            // link_libc guard: the solvers test module builds without libc,
            // same idiom as direct.zig's ESPICE_NO_BBD.
            if (comptime @import("builtin").link_libc) if (std.c.getenv("ZP_LU_STATS") != null) {
                std.debug.print("lu-stats: n={d} nnz={d} L={d} U={d} fill={d:.1}x\n", .{
                    n,                 col_ptr[n],
                    self.li.items.len, self.ui.items.len,
                    @as(f64, @floatFromInt(self.li.items.len + self.ui.items.len)) /
                        @as(f64, @floatFromInt(col_ptr[n])),
                });
            };

            if (comptime @import("builtin").link_libc) if (std.c.getenv("ZP_LU_HIST") != null) {
                var h = [_]u64{0} ** 17;
                var tot: u64 = 0;
                for (self.ui.items) |i| {
                    const len = self.lp[i + 1] - self.lp[i];
                    tot += len;
                    h[@min(len, 16)] += 1;
                }
                std.debug.print("lu-hist: n={d} U={d} axpy_elems={d} mean={d:.3} hist(0..15,16+)={any}\n", .{
                    n,                                                                                  self.ui.items.len, tot,
                    @as(f64, @floatFromInt(tot)) / @as(f64, @floatFromInt(@max(self.ui.items.len, 1))), h,
                });
            };

            self.factored = true;
        }

        /// Does unknown `c` appear in NO equation and does equation `c` contain
        /// no unknown? Both halves are required: a zero COLUMN alone says x_c is
        /// free, but fabricating A[c][c] = 1 would corrupt equation c unless
        /// that row is empty too. Structural entries carrying a zero value
        /// count as absent — the host's pattern is the per-device dense block,
        /// so a disabled branch keeps its slots and only its values vanish.
        fn voidUnknown(
            self: *const Self,
            col_ptr: []const u32,
            row_idx: []const u32,
            vals: []const T,
            c: u32,
        ) bool {
            if (self.pinv[c] != NONE) return false;
            for (col_ptr[c]..col_ptr[c + 1]) |p| {
                if (vals[p] != 0) return false;
            }
            for (0..self.n) |j| {
                if (j == c) continue;
                for (col_ptr[j]..col_ptr[j + 1]) |p| {
                    if (row_idx[p] == c and vals[p] != 0) return false;
                }
            }
            return true;
        }

        /// `dst[idx[p]] -= src[p] * f` for p in [p0, p1) — the one scatter-axpy
        /// behind refactor's replay and both of `solve`'s substitutions.
        ///
        /// Stepped two at a time BY HAND because the trip count is a sparse
        /// matrix column length, and circuit columns are tiny: measured over a
        /// whole run, `scaling/parallel_inverters_100` is 205x length 1 and
        /// 200x length 2, `devices/mos6_inverter` 47/32/72 at lengths 1/2/3 —
        /// nothing longer, ever. LLVM runtime-unrolls the plain loop by 4, so
        /// the 4-wide body it built never executes and every call still pays
        /// the guard chain: 31 Ir per call for ~1.5 elements of work.
        ///
        /// Not vectorized: the scatter is a gather-modify-scatter, and without
        /// AVX-512 there is nothing to widen (see refactor-tape-2026-09.md,
        /// where a run-vectorized variant lost even in the hot microbench).
        /// Pairing is bit-identical regardless: a column's row indices are
        /// distinct, so the two updates hit different slots.
        pub const test_access = if (@import("builtin").is_test) .{ .scatterAxpy = scatterAxpy } else {};

        inline fn scatterAxpy(dst: []T, idx: []const u32, src: []const T, p0: u32, p1: u32, f: T) void {
            var p = p0;
            while (p + 1 < p1) : (p += 2) {
                dst[idx[p]] -= src[p] * f;
                dst[idx[p + 1]] -= src[p + 1] * f;
            }
            if (p < p1) dst[idx[p]] -= src[p] * f;
        }

        // ====================================================================
        // refactor: numeric-only replay on frozen pattern + pivot sequence
        // ====================================================================

        /// Numeric refactorization: same sparsity pattern, same pivot sequence,
        /// new values. Zero allocation. Fails on pivot collapse or growth
        /// exceeding `growth_limit` (caller should fall back to full factor).
        pub fn refactor(
            self: *Self,
            col_ptr: []const u32,
            vals: []const T,
            growth_limit: T,
        ) error{SingularMatrix}!void {
            std.debug.assert(self.factored);
            for (self.void_slots.items) |p| {
                if (vals[p] != 0) return error.SingularMatrix;
            }
            const li = self.li.items;
            const lx = self.lx.items;
            const ui = self.ui.items;
            const ux = self.ux.items;
            // Same hoist as the four above, for the fields the loop bodies
            // index. Not style: `ux[p] = uki` is an f64 store that LLVM cannot
            // prove disjoint from `self.w`, so every U-entry reloaded `self.w`
            // and `self.lp` from the struct — two loads inside the 23-
            // instruction preamble that already dominates this kernel (measured
            // 35% of refactor on scaling/parallel_inverters_100, where U has
            // 405 entries and the inner axpy averages under one iteration).
            // A local slice is loop-invariant by construction, so the reloads
            // go. Identical operations in identical order — no FP change.
            const w = self.w;
            const lp = self.lp;
            const up = self.up;
            const prow = self.prow;
            const udiag = self.udiag;

            for (0..self.n) |k| {
                const c = self.q[k];
                const uk0 = up[k];
                const uk1 = up[k + 1];
                const lk0 = lp[k];
                const lk1 = lp[k + 1];
                // `w` is all-zero here (see the field doc), so the stored
                // pattern needs no zero prologue — scatter A[:,c] straight in.
                for (col_ptr[c]..col_ptr[c + 1]) |p| w[prow[p]] = vals[p];

                // Replay the triangular solve in stored topological order.
                // `w[i] = 0` right after the read is safe and is what pays for
                // dropping the prologue: a U row is written only by EARLIER
                // entries of this column. An entry writes rows of L[:,i], and
                // L[r][i] != 0 is the edge i -> r that put r after i in the
                // topological order — so nothing later can touch w[i].
                for (uk0..uk1) |p| {
                    const i = ui[p];
                    const uki = w[i];
                    w[i] = 0;
                    ux[p] = uki;
                    scatterAxpy(w, li, lx, lp[i], lp[i + 1], uki);
                }

                // Void slots were checked above; the fabricated pivot is valid.
                if (self.void_col[k]) {
                    udiag[k] = 1;
                    for (lk0..lk1) |p| {
                        lx[p] = 0;
                        w[li[p]] = 0;
                    }
                    w[k] = 0;
                    continue;
                }
                const d = w[k];
                w[k] = 0;
                if (d == 0 or !std.math.isFinite(d)) {
                    for (lk0..lk1) |p| w[li[p]] = 0;
                    return error.SingularMatrix;
                }
                udiag[k] = d;

                // The growth monitor compares |d| against the RAW column max,
                // which is meaningless for a scale-accepted pivot: that pivot
                // was chosen precisely because its equation lives decades below
                // the column. Leaving it armed would reject every replay of a
                // BSIMSOI tape (|d| ~ 1e-18 vs cmax ~ 1e-4) and force a full
                // factor per Newton iterate.
                // ponytail: those steps run unmonitored; the upgrade is a
                // row-scaled cmax, which needs rscale in permuted coordinates.
                if (growth_limit > 0 and !self.scaled_pivot[k]) {
                    var cmax: T = @abs(d);
                    for (lk0..lk1) |p| {
                        const r = li[p];
                        const v = w[r];
                        w[r] = 0;
                        cmax = @max(cmax, @abs(v));
                        lx[p] = v / d;
                    }
                    if (@abs(d) < growth_limit * cmax) return error.SingularMatrix;
                } else {
                    for (lk0..lk1) |p| {
                        const r = li[p];
                        lx[p] = w[r] / d;
                        w[r] = 0;
                    }
                }
            }
        }

        // ====================================================================
        // solve: P → L → U → Q permuted substitution
        // ====================================================================

        /// Solve Ax = b. `b` and `x` may alias (in-place).
        pub fn solve(self: *Self, b: []const T, x: []T) void {
            const li = self.li.items;
            const lx = self.lx.items;
            const ui = self.ui.items;
            const ux = self.ux.items;
            // Same reason as `refactor`: `y[...] -= ...` is an f64 store LLVM
            // cannot prove disjoint from `self.lp`/`self.up`, so the column
            // bounds were re-fetched through `self` on every substitution step.
            const y = self.y;
            const lp = self.lp;
            const up = self.up;

            // 1. y = P b (permute rows by pinv)
            for (b, 0..) |bi, r| y[self.pinv[r]] = bi;

            // 2. L y' = y (forward substitution, L is unit lower triangular)
            for (0..self.n) |k| {
                const yk = y[k];
                if (yk == 0) continue;
                scatterAxpy(y, li, lx, lp[k], lp[k + 1], yk);
            }

            // 3. U z = y' (back substitution)
            var k = self.n;
            while (k > 0) {
                k -= 1;
                const zk = y[k] / self.udiag[k];
                y[k] = zk;
                if (zk == 0) continue;
                scatterAxpy(y, ui, ux, up[k], up[k + 1], zk);
            }

            // 4. x = Q^{-1} z (un-permute columns)
            for (self.q, 0..) |c, j| x[c] = y[j];
        }

        // ====================================================================
        // solveT: Q^T → U^{-T} → L^{-T} → P^{-1} transpose solve
        // ====================================================================

        /// Solve A^T x = b. Used by adjoint analyses (noise, sens).
        /// A = P^{-1} L U Q^{-1}, so A^{-T} = Q L^{-T} U^{-T} P.
        ///   1. z = Q^T b   (column permutation)
        ///   2. U^{-T} z    (forward sub on U^T, lower triangular)
        ///   3. L^{-T} z    (back sub on L^T, unit upper triangular)
        ///   4. x = P^{-1} z
        pub fn solveT(self: *Self, b: []const T, x: []T) void {
            const li = self.li.items;
            const lx = self.lx.items;
            const ui = self.ui.items;
            const ux = self.ux.items;

            // 1. z = Q^T b: pivot-step k gets b[q[k]]
            for (self.q, 0..) |c, k| self.y[k] = b[c];

            // 2. U^{-T} z: U^T is lower triangular, gather-mode forward sub.
            for (0..self.n) |k| {
                for (self.up[k]..self.up[k + 1]) |p| self.y[k] -= ux[p] * self.y[ui[p]];
                self.y[k] /= self.udiag[k];
            }

            // 3. L^{-T} z: L^T is unit upper triangular, gather-mode back sub.
            var k = self.n;
            while (k > 0) {
                k -= 1;
                for (self.lp[k]..self.lp[k + 1]) |p| self.y[k] -= lx[p] * self.y[li[p]];
            }

            // 4. P^{-1} z: pinv[r] = step that pivoted row r → x[r] = z[pinv[r]]
            for (0..self.n) |r| x[r] = self.y[self.pinv[r]];
        }
    };
}
