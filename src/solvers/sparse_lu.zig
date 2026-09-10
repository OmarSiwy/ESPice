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
const order = @import("order.zig"); // test-only: order -> LU -> solve composition

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
        w: []T, // dense accumulator (zero outside active column)
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
                // Zero the stored pattern, then scatter A[:,c] in permuted rows
                for (ui[uk0..uk1]) |i| w[i] = 0;
                for (li[lk0..lk1]) |i| w[i] = 0;
                w[k] = 0;
                for (col_ptr[c]..col_ptr[c + 1]) |p| w[prow[p]] = vals[p];

                // Replay the triangular solve in stored topological order
                for (uk0..uk1) |p| {
                    const i = ui[p];
                    const uki = w[i];
                    ux[p] = uki;
                    for (lp[i]..lp[i + 1]) |pl| w[li[pl]] -= lx[pl] * uki;
                }

                // Void slots were checked above; the fabricated pivot is valid.
                if (self.void_col[k]) {
                    udiag[k] = 1;
                    for (lk0..lk1) |p| lx[p] = 0;
                    continue;
                }
                const d = w[k];
                if (d == 0 or !std.math.isFinite(d)) return error.SingularMatrix;
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
                        const v = w[li[p]];
                        cmax = @max(cmax, @abs(v));
                        lx[p] = v / d;
                    }
                    if (@abs(d) < growth_limit * cmax) return error.SingularMatrix;
                } else {
                    for (lk0..lk1) |p| lx[p] = w[li[p]] / d;
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
                for (lp[k]..lp[k + 1]) |p| y[li[p]] -= lx[p] * yk;
            }

            // 3. U z = y' (back substitution)
            var k = self.n;
            while (k > 0) {
                k -= 1;
                const zk = y[k] / self.udiag[k];
                y[k] = zk;
                if (zk == 0) continue;
                for (up[k]..up[k + 1]) |p| y[ui[p]] -= ux[p] * zk;
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Dense-to-CSC converter for tests.
pub fn DenseCsc(comptime n: usize) type {
    return struct {
        col_ptr: [n + 1]u32,
        row_idx: [n * n]u32,
        vals: [n * n]f64,

        pub fn from(a: [n][n]f64) @This() {
            var s: @This() = undefined;
            var m: u32 = 0;
            s.col_ptr[0] = 0;
            for (0..n) |j| {
                for (0..n) |i| {
                    if (a[i][j] != 0) {
                        s.row_idx[m] = @intCast(i);
                        s.vals[m] = a[i][j];
                        m += 1;
                    }
                }
                s.col_ptr[j + 1] = m;
            }
            return s;
        }

        pub fn nnz(s: *const @This()) u32 {
            return s.col_ptr[n];
        }
    };
}

/// Dense Gaussian elimination reference solver for verification.
pub fn denseSolve(comptime n: usize, a_in: [n][n]f64, b_in: [n]f64) [n]f64 {
    var a = a_in;
    var b = b_in;
    for (0..n) |k| {
        var piv = k;
        for (k + 1..n) |i| {
            if (@abs(a[i][k]) > @abs(a[piv][k])) piv = i;
        }
        std.mem.swap([n]f64, &a[k], &a[piv]);
        std.mem.swap(f64, &b[k], &b[piv]);
        for (k + 1..n) |i| {
            const f = a[i][k] / a[k][k];
            for (k..n) |j| a[i][j] -= f * a[k][j];
            b[i] -= f * b[k];
        }
    }
    var x: [n]f64 = undefined;
    var k = n;
    while (k > 0) {
        k -= 1;
        var s = b[k];
        for (k + 1..n) |j| s -= a[k][j] * x[j];
        x[k] = s / a[k][k];
    }
    return x;
}

pub fn identity(comptime n: usize) [n]u32 {
    var q: [n]u32 = undefined;
    for (0..n) |i| q[i] = @intCast(i);
    return q;
}

pub fn checkSolve(comptime n: usize, a: [n][n]f64, b: [n]f64, lu: *SparseLu(f64)) !void {
    var x: [n]f64 = undefined;
    lu.solve(&b, &x);
    const xref = denseSolve(n, a, b);
    for (x, xref) |xi, ri| try testing.expectApproxEqRel(ri, xi, 1e-11);
}

test "2x2: factor + solve" {
    const gpa = testing.allocator;
    const a = [2][2]f64{ .{ 2, 1 }, .{ 1, 3 } };
    const csc = DenseCsc(2).from(a);
    var q = identity(2);
    var lu = try SparseLu(f64).init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

    var x: [2]f64 = undefined;
    lu.solve(&.{ 5, 7 }, &x);
    const xref = denseSolve(2, a, .{ 5, 7 });
    try testing.expectApproxEqAbs(xref[0], x[0], 1e-12);
    try testing.expectApproxEqAbs(xref[1], x[1], 1e-12);
}

test "3x3: factor + solve verified against dense reference" {
    const gpa = testing.allocator;
    const a = [3][3]f64{
        .{ 2, 1, 0 },
        .{ 1, 3, 1 },
        .{ 0, 1, 4 },
    };
    const b = [3]f64{ 1, 5, 9 };
    const csc = DenseCsc(3).from(a);
    var q = identity(3);
    var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try checkSolve(3, a, b, &lu);
}

test "order -> factor + solve: AMD permutation is valid and the solve is correct" {
    const gpa = testing.allocator;
    // Arrowhead: dense first row/col (hub at node 0), diagonal elsewhere.
    // AMD defers the hub, so q is a genuine non-identity permutation — this is
    // the composition order.zig and the LU each test only in isolation.
    const a = [4][4]f64{
        .{ 5, 1, 1, 1 },
        .{ 1, 2, 0, 0 },
        .{ 1, 0, 3, 0 },
        .{ 1, 0, 0, 4 },
    };
    const b = [4]f64{ 8, 3, 4, 5 };
    const csc = DenseCsc(4).from(a);

    var q: [4]u32 = undefined;
    var buf: [order.wsSize(4, 10)]u32 = undefined; // arrowhead nnz = 10
    var ws = order.Ws.init(&buf);
    try order.order(4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws);

    // q must be a valid permutation of 0..4.
    var seen = [_]bool{false} ** 4;
    for (q) |c| {
        try testing.expect(!seen[c]);
        seen[c] = true;
    }
    // The hub (node 0) is deferred: not factored first.
    try testing.expect(q[0] != 0);

    var lu = try SparseLu(f64).init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try checkSolve(4, a, b, &lu);
}

test "MNA structural zero diagonal: off-diagonal pivoting" {
    const gpa = testing.allocator;
    // Voltage-source branch row: zero diagonal forces off-diagonal pivoting.
    const a = [3][3]f64{
        .{ 1e-3, 0, 1 },
        .{ 0, 2e-3, -1 },
        .{ 1, -1, 0 },
    };
    const b = [3]f64{ 0, 0, 5 };
    const csc = DenseCsc(3).from(a);
    var q = identity(3);
    var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try checkSolve(3, a, b, &lu);
}

test "atto-siemens row keeps its own diagonal (BSIMSOI floating body)" {
    const gpa = testing.allocator;
    // Distilled BSIMSOI body block. Row/col 0 is the floating-body KCL row: at
    // DEFAULT junction params every coefficient in it is atto-siemens. Rows 1/2
    // are the drain/source nodes — 1 kS of contact conductance and Gmbs = 1 uS
    // of body transconductance, and that Gmbs sits in the BODY COLUMN. So the
    // body equation is 14 decades below the rest of the matrix while its column
    // carries a 1e-6 entry: the raw threshold test (|a00| >= tol*colmax) rejects
    // the body diagonal, the body column pivots on the drain row, and the body
    // equation is then reconstructed out of numbers 1e14 times its own size.
    const a = [4][4]f64{
        .{ 2.0e-20, -1.0e-20, -1.0e-20, 0.0 },
        .{ -1.0e-6, 1.0e3, -9.0e-4, 1.0e-3 },
        .{ 1.0e-6, -9.0e-4, 2.0e-3, -1.0e-3 },
        .{ 0.0, 0.0, -1.0e-3, 1.0 },
    };
    const x_true = [4]f64{ 0.03526, 0.9, 0.1, 1.1 };
    var b: [4]f64 = .{ 0, 0, 0, 0 };
    for (0..4) |i| for (0..4) |j| {
        b[i] += a[i][j] * x_true[j];
    };

    const csc = DenseCsc(4).from(a);
    var q = identity(4);
    var lu = try SparseLu(f64).init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

    // The body row must pivot its OWN column (step 0 factors column 0).
    // Without the row-scaled fallback it is pivoted LAST: pinv[0] == 3.
    try testing.expectEqual(@as(u32, 0), lu.pinv[0]);
    try testing.expect(lu.scaled_pivot[0]);

    var x: [4]f64 = undefined;
    lu.solve(&b, &x);
    // Measured: raw threshold gives x0 = 0.035260200093 (5.7e-6 relative) and
    // x2 off by 1.3e-9; the row-scaled choice is exact to 2e-15 on every
    // component. 1e-9 sits three orders clear of both.
    for (x, x_true) |xi, ref| try testing.expectApproxEqRel(ref, xi, 1e-9);

    // ...and the tape must be replayable: the raw growth monitor sees
    // |d| = 2e-20 against a column max of 1e-6 and would reject every refactor,
    // forcing a full factor per Newton iterate.
    try lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-12);
    lu.solve(&b, &x);
    for (x, x_true) |xi, ref| try testing.expectApproxEqRel(ref, xi, 1e-9);
}

test "refactor: same pattern, new values" {
    const gpa = testing.allocator;
    var a = [4][4]f64{
        .{ 4, 1, 0, 0 },
        .{ 1, 5, 2, 0 },
        .{ 0, 2, 6, 3 },
        .{ 0, 0, 3, 7 },
    };
    var csc = DenseCsc(4).from(a);
    var q = identity(4);
    var lu = try SparseLu(f64).init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try checkSolve(4, a, .{ 1, 2, 3, 4 }, &lu);

    // Perturb values on the same pattern, refactor only
    a[1][1] = 9;
    a[2][3] = 1;
    csc = DenseCsc(4).from(a);
    try lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-12);
    try checkSolve(4, a, .{ 4, 3, 2, 1 }, &lu);
}

test "singular matrix detection" {
    const gpa = testing.allocator;
    const a = [2][2]f64{ .{ 1, 1 }, .{ 1, 1 } };
    const csc = DenseCsc(2).from(a);
    var q = identity(2);
    var lu = try SparseLu(f64).init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try testing.expectError(
        error.SingularMatrix,
        lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3),
    );
}

test "structurally void unknown gets a unit pivot, not SingularMatrix" {
    const gpa = testing.allocator;
    // Row/col 1 is entirely zero — a compact model's disabled branch-flow
    // unknown (HICUM `V(br_sht) <+ 0` at flsh = 0). The remaining 2x2 system
    // [[2,1],[1,3]] x = [5,7] has the solution (8/5, 9/5); x1 must come back 0.
    // DenseCsc drops exact zeros, so build the pattern by hand: the host always
    // forces the diagonal, and the per-device dense block leaves row/col 1
    // structurally present with zero values.
    const col_ptr = [4]u32{ 0, 3, 6, 9 };
    const row_idx = [9]u32{ 0, 1, 2, 0, 1, 2, 0, 1, 2 };
    const vals = [9]f64{ 2, 0, 1, 0, 0, 0, 1, 0, 3 };
    var q = identity(3);
    var lu = try SparseLu(f64).init(gpa, 3, &col_ptr, &row_idx, &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &col_ptr, &row_idx, &vals, 1e-3);
    try testing.expect(lu.void_col[1]);

    var x: [3]f64 = undefined;
    lu.solve(&[3]f64{ 5, 0, 7 }, &x);
    try testing.expectApproxEqAbs(@as(f64, 8.0 / 5.0), x[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), x[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 9.0 / 5.0), x[2], 1e-12);

    // refactor must replay the fabricated pivot, not rediscover a zero and fail.
    const vals2 = [9]f64{ 4, 0, 1, 0, 0, 0, 1, 0, 5 };
    try lu.refactor(&col_ptr, &vals2, 0);
    lu.solve(&[3]f64{ 5, 0, 7 }, &x);
    try testing.expectApproxEqAbs(@as(f64, 18.0 / 19.0), x[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), x[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 23.0 / 19.0), x[2], 1e-12);
}

test "refactor rejects activation of a fabricated pivot's row or column" {
    const gpa = testing.allocator;
    const col_ptr = [_]u32{ 0, 2, 4 };
    const row_idx = [_]u32{ 0, 1, 0, 1 };
    const updates = [_][4]f64{
        .{ 2, 0, 0, 4 }, // diagonal activates: solution must use 4, not unit pivot
        .{ 2, 1, 0, 0 }, // row alone activates: still singular
        .{ 2, 0, 1, 0 }, // column alone activates: still singular
        .{ 2, 1, 1, 0 }, // off-diagonal coupling activates: must re-pivot
    };
    for ([_][2]u32{ .{ 0, 1 }, .{ 1, 0 } }) |q| {
        var lu = try SparseLu(f64).init(gpa, 2, &col_ptr, &row_idx, &q);
        defer lu.deinit(gpa);
        var fresh = try SparseLu(f64).init(gpa, 2, &col_ptr, &row_idx, &q);
        defer fresh.deinit(gpa);
        for (updates) |vals| {
            try lu.factor(gpa, &col_ptr, &row_idx, &.{ 2, 0, 0, 0 }, 1e-3);
            try testing.expectError(error.SingularMatrix, lu.refactor(&col_ptr, &vals, 1e-12));
            fresh.factor(gpa, &col_ptr, &row_idx, &vals, 1e-3) catch |err| {
                try testing.expectError(err, lu.factor(gpa, &col_ptr, &row_idx, &vals, 1e-3));
                continue;
            };
            try lu.factor(gpa, &col_ptr, &row_idx, &vals, 1e-3);
            try testing.expectEqual(@as(usize, 0), lu.void_slots.items.len);
            var actual: [2]f64 = undefined;
            var expected: [2]f64 = undefined;
            lu.solve(&.{ 2, 4 }, &actual);
            fresh.solve(&.{ 2, 4 }, &expected);
            for (actual, expected) |v, ref| try testing.expectApproxEqAbs(ref, v, 1e-12);
        }
    }
}

test "a genuinely singular matrix is still rejected" {
    const gpa = testing.allocator;
    // Duplicate columns: the second column's reach holds no unpivoted row, but
    // its values are NOT zero — voidUnknown must refuse to rescue it.
    const a = [2][2]f64{ .{ 1, 1 }, .{ 1, 1 } };
    const csc = DenseCsc(2).from(a);
    var q = identity(2);
    var lu = try SparseLu(f64).init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try testing.expectError(
        error.SingularMatrix,
        lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3),
    );
}

test "solveT: transpose solve matches A^T dense reference" {
    const gpa = testing.allocator;
    const a = [3][3]f64{
        .{ 1e-3, 0, 1 },
        .{ 0, 2e-3, -1 },
        .{ 1, -1, 0 },
    };
    const b = [3]f64{ 1, 2, 3 };
    const csc = DenseCsc(3).from(a);
    var q = identity(3);
    var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

    // Reference: A^T dense solve
    var at: [3][3]f64 = undefined;
    for (0..3) |i| for (0..3) |j| {
        at[i][j] = a[j][i];
    };
    const xref = denseSolve(3, at, b);
    var x: [3]f64 = undefined;
    lu.solveT(&b, &x);
    for (x, xref) |xi, ri| try testing.expectApproxEqRel(ri, xi, 1e-11);
}

test "determinism: two factorizations byte-identical" {
    const gpa = testing.allocator;
    const a = [3][3]f64{
        .{ 2, 1, 0 },
        .{ 1, 3, 1 },
        .{ 0, 1, 4 },
    };
    const csc = DenseCsc(3).from(a);
    var q = identity(3);
    var lu1 = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu1.deinit(gpa);
    var lu2 = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu2.deinit(gpa);
    try lu1.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try lu2.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try testing.expectEqualSlices(f64, lu1.lx.items, lu2.lx.items);
    try testing.expectEqualSlices(f64, lu1.ux.items, lu2.ux.items);
    try testing.expectEqualSlices(f64, lu1.udiag, lu2.udiag);
    try testing.expectEqualSlices(u32, lu1.li.items, lu2.li.items);
    try testing.expectEqualSlices(u32, lu1.ui.items, lu2.ui.items);
}

test "pivot growth monitor detection" {
    const gpa = testing.allocator;
    // Factor a well-conditioned matrix, then refactor with values that
    // cause extreme pivot decay — the growth monitor should catch it.
    var a = [3][3]f64{
        .{ 10, 1, 0 },
        .{ 1, 10, 1 },
        .{ 0, 1, 10 },
    };
    var csc = DenseCsc(3).from(a);
    var q = identity(3);
    var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

    // Make the diagonal nearly zero while off-diagonals stay large:
    // the frozen pivot at position (0,0) will collapse.
    a[0][0] = 1e-20;
    a[1][1] = 1e-20;
    a[2][2] = 1e-20;
    csc = DenseCsc(3).from(a);
    // With a tight growth limit the decay should be detected
    try testing.expectError(
        error.SingularMatrix,
        lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-6),
    );
}

test "solve and solveT in-place (b aliases x)" {
    const gpa = testing.allocator;
    const a = [2][2]f64{ .{ 3, 1 }, .{ 1, 2 } };
    const csc = DenseCsc(2).from(a);
    var q = identity(2);
    var lu = try SparseLu(f64).init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

    const b = [2]f64{ 7, 5 };
    const xref = denseSolve(2, a, b);

    // In-place solve: x and b point to the same memory
    var x = b;
    lu.solve(&x, &x);
    try testing.expectApproxEqAbs(xref[0], x[0], 1e-12);
    try testing.expectApproxEqAbs(xref[1], x[1], 1e-12);
}

test "refactor then solve gives correct answer" {
    // Ensure the full round-trip: factor → refactor → solve works, not just
    // that refactor doesn't error.
    const gpa = testing.allocator;
    var a = [3][3]f64{
        .{ 5, 1, 0 },
        .{ 1, 5, 1 },
        .{ 0, 1, 5 },
    };
    var csc = DenseCsc(3).from(a);
    var q = identity(3);
    var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

    // New values, same pattern
    a[0][0] = 8;
    a[1][0] = 2;
    a[2][2] = 9;
    csc = DenseCsc(3).from(a);
    try lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 0);

    const b = [3]f64{ 10, 20, 30 };
    try checkSolve(3, a, b, &lu);
}

test "f32 instantiation compiles and solves" {
    const gpa = testing.allocator;
    const Lu32 = SparseLu(f32);
    const a = [2][2]f64{ .{ 4, 1 }, .{ 1, 3 } };
    const csc = DenseCsc(2).from(a);
    // Convert vals to f32
    var vals32: [4]f32 = undefined;
    for (csc.vals[0..csc.nnz()], 0..) |v, i| vals32[i] = @floatCast(v);
    var q = identity(2);
    var lu = try Lu32.init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], vals32[0..csc.nnz()], 1e-3);

    var x: [2]f32 = undefined;
    lu.solve(&[2]f32{ 9, 7 }, &x);
    // [4 1; 1 3]x = [9;7] → x = [20/11, 19/11]
    try testing.expectApproxEqAbs(@as(f32, 20.0 / 11.0), x[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 19.0 / 11.0), x[1], 1e-5);
}

test "SparseLu construction releases storage on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var lu = try SparseLu(f64).init(gpa, 3, &.{ 0, 3, 6, 9 }, &.{ 0, 1, 2, 0, 1, 2, 0, 1, 2 }, &.{ 0, 1, 2 });
            defer lu.deinit(gpa);
        }
    }.run, .{});
}
