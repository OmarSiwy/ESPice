//! Left-looking Gilbert-Peierls sparse LU with threshold partial pivoting,
//! a numeric refactor that replays the frozen pattern and pivot sequence,
//! and forward/transpose solves. The caller supplies the column ordering.
//! Background: docs/solvers/gilbert-peierls-lu.md, klu-pipeline.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

const NONE: u32 = std.math.maxInt(u32);

/// Sparse LU over f32 or f64. Arrays are SoA; the DFS workspace is touched
/// only by a full `factor`.
pub fn SparseLu(comptime T: type) type {
    comptime {
        std.debug.assert(T == f32 or T == f64);
    }

    return struct {
        const Self = @This();

        /// `SingularMatrix`: some column has no finite nonzero pivot and is
        /// not a structurally void unknown.
        pub const FactorError = error{ OutOfMemory, SingularMatrix };

        /// Supernode steps [first, last]. Its rows are L[:,first]'s: first
        /// the block rows of steps first+1..last (slot t-first-1), then the
        /// rest. Values are column-major, `nrows` per member step.
        const Panel = struct { first: u32, last: u32, row_off: u32, val_off: u32 };
        /// A panel opens only on an L column at least this long, and the
        /// factor switches to its supernodal loop only after one appears.
        /// Short supernodes (a complex AC entry's 2x2 real block) lose to
        /// the scalar path: 16 and 8 cost 0.5% and 13% more Ir than 32 on
        /// the 100x100 grid and the sweep_opamp AC matrix respectively.
        const panel_min_rows = 32;

        n: u32,
        /// Borrowed column ordering: pivot step k factors column q[k].
        q: []const u32,
        /// Original row -> pivot step.
        pinv: []u32,

        /// L, strictly lower with unit diagonal, CSC over pivot steps. Row
        /// indices are pivot steps once `factor` returns.
        lp: []u32,
        li: std.ArrayList(u32) = .empty,
        lx: std.ArrayList(T) = .empty,

        /// U, strictly upper, CSC over pivot steps. Each column's rows are in
        /// the topological order the triangular solve visited them, which is
        /// the order `refactor` replays.
        up: []u32,
        ui: std.ArrayList(u32) = .empty,
        ux: std.ArrayList(T) = .empty,
        udiag: []T,

        /// prow[p] = pinv[row_idx[p]]: A entry p -> its permuted row.
        prow: []u32,

        /// Pivot steps that got a fabricated unit pivot (see `voidUnknown`).
        void_col: []bool,
        /// CSC entries in a fabricated pivot's row or column. A replay is
        /// valid only while all of them stay zero.
        void_slots: std.ArrayList(u32) = .empty,

        /// Pivot steps whose diagonal passed only the row-scaled threshold
        /// test. Such a pivot sits far below its raw column max, so the
        /// refactor growth monitor skips these steps.
        scaled_pivot: []bool,
        /// Full-factor DFS scan end of L[:,s]: lp[s+1], or just past the row
        /// pivoted at step s+1 when every later entry of L[:,s] is in
        /// L[:,s+1] (that child's walk has marked them all).
        lend: []u32,
        /// Full-factor scratch: a dense copy of each supernode that starts
        /// on an L column of at least `panel_min_rows`, so a later column
        /// applies a run of its steps as vector updates. `sn_of[s]` is the
        /// panel holding step s, or NONE.
        sn_of: []u32,
        /// Row -> slot in the open panel.
        sn_slot: []u32,
        panels: std.ArrayList(Panel) = .empty,
        panel_rows: std.ArrayList(u32) = .empty,
        panel_vals: std.ArrayList(T) = .empty,

        /// Small-matrix refactor tape: one {dst, l, u} slot triple per flop,
        /// `tv[dst] -= tv[l] * tv[u]`, in refactor order. Empty above
        /// `tape_max_flops`, where `refactor` runs the column loop instead.
        tape: std.ArrayList([3]u32) = .empty,
        /// Column k's flops are tape[tape_col[k]..tape_col[k+1]].
        tape_col: []u32,
        /// A entry p -> its slot in `tv`.
        amap: []u32,
        /// L entry -> its column; built only with a tape.
        lsrc: std.ArrayList(u32) = .empty,
        /// Tape slot values: ux ++ udiag ++ lx ++ one discard slot.
        tv: std.ArrayList(T) = .empty,

        /// Dense accumulator, all-zero on entry to and exit from every public
        /// call, errors included. `factor` reads unscattered fill rows as 0,
        /// and `refactor` zeroes each slot as it consumes it rather than
        /// clearing the pattern up front.
        w: []T,
        /// Solve workspace; also panel scratch during `factor`.
        y: []T,
        /// rscale[r] = 1 / max_j |A[r][j]| (1 for an all-zero or non-finite
        /// row), by original row. Recomputed by each `factor`.
        rscale: []T,

        // DFS workspace, `factor` only.
        flag: []u32, // epoch visited marker
        topo: []u32, // finish order
        stack: []u32,
        pstack: []u32, // resume offset into each vertex's L column

        factored: bool = false,

        /// Allocates every workspace. `q` is borrowed and must outlive the
        /// SparseLu; `row_idx` is unused until `factor`.
        pub fn init(
            gpa: Allocator,
            n: u32,
            col_ptr: []const u32,
            row_idx: []const u32,
            q: []const u32,
        ) !Self {
            _ = row_idx;
            const nnz = col_ptr[n];
            // ponytail: pre-size L and U to max(nnz, 2n), typical circuit
            // fill; tune from a fill profile if first factors reallocate.
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
                .lend = &.{},
                .sn_of = &.{},
                .sn_slot = &.{},
                .tape_col = &.{},
                .amap = &.{},
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
            self.lend = try gpa.alloc(u32, n);
            self.sn_of = try gpa.alloc(u32, n);
            self.sn_slot = try gpa.alloc(u32, n);
            self.tape_col = try gpa.alloc(u32, @as(usize, n) + 1);
            self.amap = try gpa.alloc(u32, nnz);
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
            gpa.free(self.lend);
            gpa.free(self.sn_of);
            gpa.free(self.sn_slot);
            gpa.free(self.tape_col);
            gpa.free(self.amap);
            self.tape.deinit(gpa);
            self.lsrc.deinit(gpa);
            self.tv.deinit(gpa);
            self.panels.deinit(gpa);
            self.panel_rows.deinit(gpa);
            self.panel_vals.deinit(gpa);
            self.void_slots.deinit(gpa);
            inline for (.{ self.udiag, self.w, self.y, self.rscale }) |s|
                gpa.free(s);
            self.li.deinit(gpa);
            self.lx.deinit(gpa);
            self.ui.deinit(gpa);
            self.ux.deinit(gpa);
        }

        /// Full symbolic and numeric factorization. Per column: DFS reach,
        /// sparse triangular solve, threshold pivot (diagonal preferred),
        /// store L and U. Rebuilds the pattern, pivot sequence and replay
        /// tapes. On error the factorization is unusable (`factored` false).
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
            self.tv.clearRetainingCapacity();
            self.panels.clearRetainingCapacity();
            self.panel_rows.clearRetainingCapacity();
            self.panel_vals.clearRetainingCapacity();
            self.void_slots.clearRetainingCapacity();
            var has_void = false;
            self.li.clearRetainingCapacity();
            self.lx.clearRetainingCapacity();
            self.ui.clearRetainingCapacity();
            self.ux.clearRetainingCapacity();

            // Threshold pivoting compares candidates in whatever units each
            // device wrote its row in. Record 1/max|A[r,:]| so the diagonal
            // test below can retry in a scale-free metric.
            @memset(self.rscale, 0);
            for (0..n) |j| {
                for (col_ptr[j]..col_ptr[j + 1]) |p|
                    self.rscale[row_idx[p]] = @max(self.rscale[row_idx[p]], @abs(vals[p]));
            }
            for (self.rscale) |*s|
                s.* = if (s.* > 0 and std.math.isFinite(s.*)) 1 / s.* else 1;

            // Locals, not fields: a store through any slice may alias `self`,
            // and field access would reload the slice pointers per element.
            const pinv = self.pinv;
            const flag = self.flag;
            const stack = self.stack;
            const pstack = self.pstack;
            const topo = self.topo;
            const lp = self.lp;
            const w = self.w;
            const rscale = self.rscale;
            const lend = self.lend;
            // Two copies of the column loop. The plain one runs until an L
            // column reaches panel_min_rows, which typical circuit matrices
            // never do. The supernodal copy adds the lend shortcut and panels.
            var k: usize = 0;
            inline for (.{ false, true }) |sn| {
                if (sn) {
                    lp[k] = @intCast(self.li.items.len);
                    for (lend[0..k], lp[1 .. k + 1]) |*e, end| e.* = end;
                    @memset(self.sn_of, NONE);
                }
                while (k < n) : (k += 1) {
                    const c = self.q[k];
                    lp[k] = @intCast(self.li.items.len);
                    self.up[k] = @intCast(self.ui.items.len);
                    const mark: u32 = @intCast(k + 1);
                    // L may move at the reservation below; re-take it after.
                    const li = self.li.items;

                    // Reach of A[:,c] through the graph of L.
                    var nt: u32 = 0;
                    for (col_ptr[c]..col_ptr[c + 1]) |p| {
                        var r = row_idx[p];
                        if (flag[r] == mark) continue;
                        var sp: u32 = 0;
                        stack[sp] = r;
                        // An unpivoted row has no L column: the empty range [0, 0).
                        pstack[sp] = if (pinv[r] == NONE) 0 else lp[pinv[r]];
                        flag[r] = mark;
                        while (true) {
                            r = stack[sp];
                            const kc = pinv[r];
                            const end = if (kc == NONE) 0 else if (sn) lend[kc] else lp[kc + 1];
                            // Keep the cursor in a register; spill it only on descent.
                            var pos = pstack[sp];
                            var descended = false;
                            while (pos < end) {
                                const child = li[pos];
                                pos += 1;
                                if (flag[child] != mark) {
                                    pstack[sp] = pos;
                                    flag[child] = mark;
                                    sp += 1;
                                    stack[sp] = child;
                                    pstack[sp] = if (pinv[child] == NONE) 0 else lp[pinv[child]];
                                    descended = true;
                                    break;
                                }
                            }
                            if (descended) continue;
                            topo[nt] = r;
                            nt += 1;
                            if (sp == 0) break;
                            sp -= 1;
                        }
                    }

                    // The reach bounds this column's U and L entries. Reserve
                    // before the scatter so OutOfMemory leaves `w` zero.
                    try self.ui.ensureUnusedCapacity(gpa, nt);
                    try self.ux.ensureUnusedCapacity(gpa, nt);
                    try self.li.ensureUnusedCapacity(gpa, nt);
                    try self.lx.ensureUnusedCapacity(gpa, nt);
                    const lcol = self.li.items;
                    const lval = self.lx.items;

                    for (col_ptr[c]..col_ptr[c + 1]) |p| w[row_idx[p]] = vals[p];

                    // Triangular solve in reverse finish order.
                    var idx: u32 = nt;
                    while (idx > 0) {
                        idx -= 1;
                        const r = topo[idx];
                        const kc = pinv[r];
                        if (kc == NONE) continue;
                        if (sn and self.panels.items.len != 0 and self.sn_of[kc] != NONE) {
                            idx = self.panelRun(w, topo, idx, kc);
                            continue;
                        }
                        const ukr = w[r];
                        self.ui.appendAssumeCapacity(kc);
                        self.ux.appendAssumeCapacity(ukr);
                        scatterAxpy(w, lcol, lval, lp[kc], lp[kc + 1], ukr);
                    }

                    // `amax`, the raw column max, picks the off-diagonal
                    // fallback and gates singularity. `smax` is the same max
                    // under row scaling, the diagonal test's second chance: an
                    // equation decades below the rest may still own its unknown.
                    var amax: T = 0;
                    var smax: T = 0;
                    var piv: u32 = NONE;
                    for (topo[0..nt]) |r| {
                        if (pinv[r] != NONE) continue;
                        const a = @abs(w[r]);
                        if (a > amax) {
                            amax = a;
                            piv = r;
                        }
                        smax = @max(smax, a * rscale[r]);
                    }
                    if (piv == NONE or amax == 0 or !std.math.isFinite(amax)) {
                        // Usually a singular circuit, but a compact model can
                        // disable part of itself (HICUM's `V(br_sht) <+ 0` at
                        // flsh = 0, the BSIM4/BSIMSOI/HiSIM self-heating nodes),
                        // and Verilog-A cannot delete the node: its unknown keeps
                        // an all-zero row and column. That is a free variable,
                        // not a singular system. A unit pivot is sound only when
                        // row c is void too: then x_c = b_c, and a nonzero b_c
                        // fails the Newton residual gate instead of solving
                        // silently. Without this, devices/hicum2_output paid the
                        // whole continuation ladder at each of 1809 DC points.
                        if (!self.voidUnknown(col_ptr, row_idx, vals, c)) {
                            // `w` still holds this column's values; restore
                            // the all-zero invariant.
                            for (topo[0..nt]) |r| w[r] = 0;
                            return error.SingularMatrix;
                        }
                        self.void_col[k] = true;
                        has_void = true;
                        self.udiag[k] = 1;
                        pinv[c] = @intCast(k);
                        if (sn) lend[k] = lp[k]; // empty L column
                        for (topo[0..nt]) |r| w[r] = 0;
                        continue;
                    }
                    if (pinv[c] == NONE) {
                        const dmag = @abs(w[c]);
                        if (dmag >= pivot_tol * amax) {
                            piv = c;
                        } else if (dmag > 0 and dmag * rscale[c] >= pivot_tol * smax) {
                            // The diagonal is the largest entry measured against
                            // its own equation. A BSIMSOI floating body at default
                            // junction params: its KCL row is ~1e-18 S while Gmbs
                            // ~1e-4 S sits in its column on the drain row, and
                            // pivoting there makes dx_body drain-row rounding noise
                            // (observed -13.9 V). ngspice avoids it by permuting
                            // rows and columns together (Sparse 1.3 spfactor.c
                            // ExchangeRowsAndCols), which a fixed column order
                            // cannot do.
                            // ponytail: scales the pivot choice only; full row
                            // equilibration (KLU scale=2) if the arithmetic needs it.
                            piv = c;
                            self.scaled_pivot[k] = true;
                        }
                    }
                    const d = w[piv];
                    self.udiag[k] = d;
                    pinv[piv] = @intCast(k);

                    // L[:,k] is the unpivoted reach over the pivot; clear w.
                    for (topo[0..nt]) |r| {
                        if (pinv[r] == NONE) {
                            self.li.appendAssumeCapacity(r);
                            self.lx.appendAssumeCapacity(w[r] / d);
                        }
                        w[r] = 0;
                    }
                    if (!sn) {
                        if (self.li.items.len - lp[k] >= panel_min_rows) {
                            k += 1;
                            break;
                        }
                        continue;
                    }
                    lend[k] = @intCast(self.li.items.len);
                    // Short columns gain nothing from either shortcut.
                    if (k > 0 and (lp[k] - lp[k - 1] >= panel_min_rows or self.sn_of[k - 1] != NONE))
                        try self.linkStep(gpa, @intCast(k), piv, mark);
                }
            }
            self.lp[n] = @intCast(self.li.items.len);
            self.up[n] = @intCast(self.ui.items.len);

            for (self.li.items) |*r| r.* = self.pinv[r.*];
            for (row_idx[0..self.prow.len], self.prow) |r, *pr| pr.* = self.pinv[r];

            if (has_void) {
                var count: usize = 0;
                for (self.q, 0..) |c, j| {
                    for (col_ptr[c]..col_ptr[c + 1]) |p|
                        count += @intFromBool(self.void_col[j] or self.void_col[self.prow[p]]);
                }
                try self.void_slots.ensureTotalCapacityPrecise(gpa, count);
                for (self.q, 0..) |c, j| {
                    for (col_ptr[c]..col_ptr[c + 1]) |p| {
                        if (self.void_col[j] or self.void_col[self.prow[p]])
                            self.void_slots.appendAssumeCapacity(@intCast(p));
                    }
                }
            }

            try self.buildTape(gpa, col_ptr);

            // ZP_LU_STATS=1 prints n, nnz and fill per full factor. The test
            // module builds without libc, hence the guard.
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

        /// Step k just stored L[:,k] and pivoted row `piv`. Compares L[:,k-1]
        /// with it: sets lend[k-1], and grows a panel when the two columns
        /// form a supernode. A row of L[:,k] is exactly a row this column's
        /// walk reached (flag == mark) that is still unpivoted.
        fn linkStep(self: *Self, gpa: Allocator, k: u32, piv: u32, mark: u32) Allocator.Error!void {
            const s = k - 1;
            const col = self.li.items[self.lp[s]..self.lp[k]];
            var at: u32 = NONE; // piv's offset in L[:,s]
            var last_out: u32 = NONE; // last offset whose row is not in L[:,k]
            for (col, 0..) |r, i| {
                if (r == piv) {
                    at = @intCast(i);
                } else if (self.flag[r] != mark or self.pinv[r] != NONE) {
                    last_out = @intCast(i);
                }
            }
            if (at == NONE or (last_out != NONE and last_out > at)) return;
            self.lend[s] = self.lp[s] + at + 1;
            const joins = last_out == NONE and col.len == self.li.items.len - self.lp[k] + 1;
            if (joins) try self.growPanel(gpa, k, piv);
        }

        /// Step k joined step k-1's supernode; `piv` is the row it pivoted.
        /// Opens a panel at k-1 if none is open, moves `piv` to block slot
        /// k-first-1 and appends column k.
        fn growPanel(self: *Self, gpa: Allocator, k: u32, piv: u32) Allocator.Error!void {
            const lp = self.lp;
            const li = self.li.items;
            const lx = self.lx.items;
            const slot = self.sn_slot;
            if (self.sn_of[k - 1] == NONE) {
                const first = k - 1;
                const nrows = lp[k] - lp[first];
                try self.panels.ensureUnusedCapacity(gpa, 1);
                try self.panel_rows.ensureUnusedCapacity(gpa, nrows);
                try self.panel_vals.ensureUnusedCapacity(gpa, nrows);
                self.sn_of[first] = @intCast(self.panels.items.len);
                self.panels.appendAssumeCapacity(.{
                    .first = first,
                    .last = first,
                    .row_off = @intCast(self.panel_rows.items.len),
                    .val_off = @intCast(self.panel_vals.items.len),
                });
                for (li[lp[first]..lp[k]], lx[lp[first]..lp[k]], 0..) |r, v, i| {
                    slot[r] = @intCast(i);
                    self.panel_rows.appendAssumeCapacity(r);
                    self.panel_vals.appendAssumeCapacity(v);
                }
            }
            const pid = self.sn_of[k - 1];
            const pan = &self.panels.items[pid];
            const nrows = lp[pan.first + 1] - lp[pan.first];
            try self.panel_vals.ensureUnusedCapacity(gpa, nrows);
            const rows = self.panel_rows.items[pan.row_off..][0..nrows];
            const b = k - pan.first - 1; // piv's block slot
            const a = slot[piv];
            if (a != b) {
                const vals = self.panel_vals.items[pan.val_off..];
                for (0..k - pan.first) |col| std.mem.swap(T, &vals[col * nrows + a], &vals[col * nrows + b]);
                slot[rows[b]] = a;
                slot[piv] = b;
                std.mem.swap(u32, &rows[a], &rows[b]);
            }
            const dst = self.panel_vals.addManyAsSliceAssumeCapacity(nrows);
            @memset(dst, 0);
            // lp[k + 1] is not written yet: column k ends at the list's end.
            for (li[lp[k]..], lx[lp[k]..]) |r, v| dst[slot[r]] = v;
            pan.last = k;
            self.sn_of[k] = pid;
        }

        /// Applies the run of panel steps that starts at topo[idx0] (step kc)
        /// and continues while the next topo entry is the panel's next step.
        /// Returns the topo index of the run's last entry. Per row the
        /// subtractions happen in step order, so the result is bitwise the
        /// column-at-a-time loop's.
        fn panelRun(self: *Self, w: []T, topo: []const u32, idx0: u32, kc: u32) u32 {
            const pan = self.panels.items[self.sn_of[kc]];
            const nrows = self.lp[pan.first + 1] - self.lp[pan.first];
            const m = pan.last - pan.first + 1;
            const rows = self.panel_rows.items[pan.row_off..][0..nrows];
            const vals = self.panel_vals.items[pan.val_off..];
            var len: u32 = 1;
            while (kc + len <= pan.last and len <= idx0 and self.pinv[topo[idx0 - len]] == kc + len) len += 1;

            // Block rows of steps kc+1..last sit in slots b0..m-2. Copy them
            // to a dense scratch (`y` is free during factor) so the triangular
            // part runs as contiguous axpys.
            const b0 = kc - pan.first;
            const x = self.y[0 .. m - 1 - b0];
            for (x, rows[b0 .. m - 1]) |*xi, r| xi.* = w[r];
            const run0 = self.ux.items.len;
            for (0..len) |j| {
                const t: u32 = kc + @as(u32, @intCast(j));
                const ut = if (j == 0) w[topo[idx0]] else x[j - 1];
                self.ui.appendAssumeCapacity(t);
                self.ux.appendAssumeCapacity(ut);
                const col = vals[(t - pan.first) * nrows ..];
                subScaled(x[j..], col[b0 + j .. m - 1], ut);
            }
            for (x, rows[b0 .. m - 1]) |xi, r| w[r] = xi;

            const u = self.ux.items[run0..];
            const c0 = b0 * nrows;
            const W = comptime std.simd.suggestVectorLength(T) orelse 1;
            var i: u32 = m - 1;
            while (i + W <= nrows) : (i += W) panelRows(W, w, rows, vals[c0..], nrows, i, u);
            while (i < nrows) : (i += 1) panelRows(1, w, rows, vals[c0..], nrows, i, u);
            return idx0 - (len - 1);
        }

        /// x[i] -= a[i] * f, W lanes at a time. LLVM leaves the plain loop
        /// scalar (x and a may alias), so the lanes are spelled out.
        inline fn subScaled(x: []T, a: []const T, f: T) void {
            const W = comptime std.simd.suggestVectorLength(T) orelse 1;
            const V = @Vector(W, T);
            var i: usize = 0;
            while (i + W <= x.len) : (i += W) {
                const xv: V = x[i..][0..W].*;
                const av: V = a[i..][0..W].*;
                x[i..][0..W].* = xv - av * @as(V, @splat(f));
            }
            while (i < x.len) : (i += 1) x[i] -= a[i] * f;
        }

        /// w[rows[i..i+W]] -= sum over j of vals[j*nrows + i..][0..W] * u[j],
        /// subtracted one j at a time. W == 1 is the scalar oracle.
        inline fn panelRows(comptime W: usize, w: []T, rows: []const u32, vals: []const T, nrows: u32, i: u32, u: []const T) void {
            const V = @Vector(W, T);
            var acc: V = undefined;
            inline for (0..W) |l| acc[l] = w[rows[i + l]];
            for (u, 0..) |uj, j| {
                const lv: V = vals[j * nrows + i ..][0..W].*;
                acc -= lv * @as(V, @splat(uj));
            }
            inline for (0..W) |l| w[rows[i + l]] = acc[l];
        }

        /// True when unpivoted unknown `c` appears in no equation and
        /// equation `c` holds no unknown. Zero-valued structural entries count
        /// as absent: a disabled branch keeps its slots, only its values
        /// vanish. O(nnz); runs only on a failed pivot.
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

        pub const test_access = if (@import("builtin").is_test) .{
            .scatterAxpy = scatterAxpy,
            .refactorColumns = refactorColumns,
        } else {};

        /// dst[idx[p]] -= src[p] * f for p in [p0, p1): the scatter-axpy of
        /// the column replay and both `solve` substitutions.
        ///
        /// Stepped two at a time by hand because circuit columns are 1 to 3
        /// entries long (scaling/parallel_inverters_100: 205 of length 1, 200
        /// of length 2). LLVM unrolls the plain loop by 4, a body that never
        /// runs, and every call still pays its guard chain. A gather-modify-
        /// scatter has nothing to widen without AVX-512; a run-vectorized
        /// variant lost (docs/solvers/refactor-tape-2026-09.md). Pairing is
        /// bitwise the one-at-a-time loop: a column's rows are distinct.
        inline fn scatterAxpy(dst: []T, idx: []const u32, src: []const T, p0: u32, p1: u32, f: T) void {
            var p = p0;
            while (p + 1 < p1) : (p += 2) {
                dst[idx[p]] -= src[p] * f;
                dst[idx[p + 1]] -= src[p + 1] * f;
            }
            if (p < p1) dst[idx[p]] -= src[p] * f;
        }

        /// Numeric refactor: the last factor's pattern and pivot sequence,
        /// new values, no allocation. Fails when a pivot is zero or
        /// non-finite, falls below `growth_limit` times its column max, or a
        /// fabricated pivot's row or column turned nonzero; the caller then
        /// runs a full `factor`. Requires a successful `factor` first.
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
            if (self.tv.items.len != 0) return self.refactorTape(vals, growth_limit);
            return self.refactorColumns(col_ptr, vals, growth_limit);
        }

        /// Column-at-a-time replay: the path for matrices too big for a tape,
        /// and the tape's oracle.
        fn refactorColumns(
            self: *Self,
            col_ptr: []const u32,
            vals: []const T,
            growth_limit: T,
        ) error{SingularMatrix}!void {
            const li = self.li.items;
            const lx = self.lx.items;
            const ui = self.ui.items;
            const ux = self.ux.items;
            // Locals, not fields: LLVM cannot prove the `ux[p]` store
            // disjoint from `self`, and the field reloads cost 35% of this
            // kernel on scaling/parallel_inverters_100.
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
                // `w` is all-zero here (see the field doc).
                for (col_ptr[c]..col_ptr[c + 1]) |p| w[prow[p]] = vals[p];

                // Replay the triangular solve in stored topological order.
                // Zeroing w[i] right after the read is safe: only earlier
                // entries write row i, since L[r][i] != 0 puts r after i.
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

                // A scale-accepted pivot is decades below its raw column max
                // by design, so the raw monitor would reject every replay.
                // ponytail: those steps run unmonitored; a row-scaled cmax
                // needs rscale in permuted coordinates.
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

        /// Factors with at most this many flops get the flat tape, 12 bytes
        /// per flop, so it stays in L1 between Newton iterates. A larger tape
        /// streams from L2 and loses to the column loop
        /// (docs/solvers/refactor-tape-2026-09.md).
        const tape_max_flops = 2048;

        /// Records the refactor as flat slot operations. Every A entry and
        /// flop target of column k is a slot of column k's pattern (U rows,
        /// the diagonal, L rows), except below-diagonal rows of a void column,
        /// which has no L: those go to the discard slot.
        fn buildTape(self: *Self, gpa: Allocator, col_ptr: []const u32) Allocator.Error!void {
            const n = self.n;
            const lp = self.lp;
            const up = self.up;
            const li = self.li.items;
            const ui = self.ui.items;
            self.tape.clearRetainingCapacity();
            self.tv.clearRetainingCapacity();
            var flops: usize = 0;
            for (ui) |i| flops += lp[i + 1] - lp[i];
            if (flops > tape_max_flops) return;
            const nu: u32 = @intCast(ui.len);
            const lx0 = nu + n;
            const discard: u32 = lx0 + @as(u32, @intCast(li.len));
            try self.tape.ensureTotalCapacityPrecise(gpa, flops);
            try self.lsrc.resize(gpa, li.len);
            for (0..n) |k| @memset(self.lsrc.items[lp[k]..lp[k + 1]], @intCast(k));
            try self.tv.resize(gpa, discard + 1);
            const pos = self.flag; // DFS scratch is free until the next factor
            for (0..n) |k| {
                const void_k = self.void_col[k];
                for (up[k]..up[k + 1]) |p| pos[ui[p]] = @intCast(p);
                pos[k] = nu + @as(u32, @intCast(k));
                for (lp[k]..lp[k + 1]) |q| pos[li[q]] = lx0 + @as(u32, @intCast(q));
                self.tape_col[k] = @intCast(self.tape.items.len);
                for (up[k]..up[k + 1]) |p| {
                    const i = ui[p];
                    for (lp[i]..lp[i + 1]) |q| {
                        const r = li[q];
                        const dst = if (void_k and r > k) discard else pos[r];
                        self.tape.appendAssumeCapacity(.{ dst, lx0 + @as(u32, @intCast(q)), @intCast(p) });
                    }
                }
                const c = self.q[k];
                for (col_ptr[c]..col_ptr[c + 1]) |a| {
                    const r = self.prow[a];
                    self.amap[a] = if (void_k and r > k) discard else pos[r];
                }
            }
            self.tape_col[n] = @intCast(self.tape.items.len);
        }

        /// `refactor` through the tape: the column loop's operations per slot
        /// in the same order, so bitwise its result, without the dense
        /// scatter and gather. U slots are final before any flop reads them.
        fn refactorTape(self: *Self, vals: []const T, growth_limit: T) error{SingularMatrix}!void {
            const n = self.n;
            const tv = self.tv.items;
            const tape = self.tape.items;
            const tcol = self.tape_col;
            const lp = self.lp;
            const nu = self.ux.items.len;
            const lx0 = nu + n;
            fillZero(tv);
            for (self.amap, vals[0..self.amap.len]) |s, v| tv[s] = v;
            for (0..n) |k| {
                for (tape[tcol[k]..tcol[k + 1]]) |f| tv[f[0]] -= tv[f[1]] * tv[f[2]];
                const lcol = tv[lx0 + lp[k] .. lx0 + lp[k + 1]];
                if (self.void_col[k]) {
                    tv[nu + k] = 1;
                    continue;
                }
                const d = tv[nu + k];
                if (d == 0 or !std.math.isFinite(d)) return error.SingularMatrix;
                if (growth_limit > 0 and !self.scaled_pivot[k]) {
                    var cmax: T = @abs(d);
                    for (lcol) |*v| {
                        cmax = @max(cmax, @abs(v.*));
                        v.* /= d;
                    }
                    if (@abs(d) < growth_limit * cmax) return error.SingularMatrix;
                } else {
                    for (lcol) |*v| v.* /= d;
                }
            }
            copyOut(self.ux.items, tv[0..nu]);
            copyOut(self.udiag, tv[nu..lx0]);
            copyOut(self.lx.items, tv[lx0 .. lx0 + self.lx.items.len]);
        }

        // The tape buffers are a few hundred bytes, where a memset or memcpy
        // call costs more than the copy (760 Ir per memset on vacask_mul's
        // 100 slots). LLVM turns a plain loop back into that call, so the
        // lanes are spelled out and the zero is read through a volatile.
        var opaque_zero: T = 0;
        inline fn fillZero(dst: []T) void {
            const W = comptime std.simd.suggestVectorLength(T) orelse 1;
            const z: T = @as(*const volatile T, &opaque_zero).*;
            var i: usize = 0;
            while (i + W <= dst.len) : (i += W) dst[i..][0..W].* = @as(@Vector(W, T), @splat(z));
            while (i < dst.len) : (i += 1) dst[i] = z;
        }
        inline fn copyOut(dst: []T, src: []const T) void {
            const W = comptime std.simd.suggestVectorLength(T) orelse 1;
            var i: usize = 0;
            while (i + W <= dst.len) : (i += W) dst[i..][0..W].* = src[i..][0..W].*;
            while (i < dst.len) : (i += 1) dst[i] = src[i];
        }

        /// x = A^-1 b. `b` and `x` may alias.
        pub fn solve(self: *Self, b: []const T, x: []T) void {
            const li = self.li.items;
            const lx = self.lx.items;
            const ui = self.ui.items;
            const ux = self.ux.items;
            // Locals for the same aliasing reason as `refactorColumns`.
            const y = self.y;
            const lp = self.lp;
            const up = self.up;

            // y = P b
            for (b, 0..) |bi, r| y[self.pinv[r]] = bi;

            // Forward through unit-lower L.
            if (self.tv.items.len != 0) {
                // Tape matrices: one flat pass over L. Skipping a zero y[k]
                // matches the column loop, signed zeros included.
                for (li, lx, self.lsrc.items) |r, l, k| {
                    const yk = y[k];
                    if (yk != 0) y[r] -= l * yk;
                }
            } else for (0..self.n) |k| {
                const yk = y[k];
                if (yk == 0) continue;
                scatterAxpy(y, li, lx, lp[k], lp[k + 1], yk);
            }

            // Back through U.
            var k = self.n;
            while (k > 0) {
                k -= 1;
                const zk = y[k] / self.udiag[k];
                y[k] = zk;
                if (zk == 0) continue;
                scatterAxpy(y, ui, ux, up[k], up[k + 1], zk);
            }

            // x = Q^-1 z
            for (self.q, 0..) |c, j| x[c] = y[j];
        }

        /// x = A^-T b, for adjoint analyses. A = P^-1 L U Q^-1, so
        /// A^-T = P^T L^-T U^-T Q^T. `b` and `x` may alias.
        pub fn solveT(self: *Self, b: []const T, x: []T) void {
            const li = self.li.items;
            const lx = self.lx.items;
            const ui = self.ui.items;
            const ux = self.ux.items;

            for (self.q, 0..) |c, k| self.y[k] = b[c];

            // Forward through U^T, gathering.
            for (0..self.n) |k| {
                for (self.up[k]..self.up[k + 1]) |p| self.y[k] -= ux[p] * self.y[ui[p]];
                self.y[k] /= self.udiag[k];
            }

            // Back through unit-upper L^T, gathering.
            var k = self.n;
            while (k > 0) {
                k -= 1;
                for (self.lp[k]..self.lp[k + 1]) |p| self.y[k] -= lx[p] * self.y[li[p]];
            }

            for (0..self.n) |r| x[r] = self.y[self.pinv[r]];
        }
    };
}
