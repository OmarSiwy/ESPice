//! ProtoStore (comptime device accumulation) and DeviceBatch (frozen SoA
//! batch: AD eval hot loop + cold Hooks vtable). One batch per device TYPE.

const std = @import("std");
const root = @import("../root.zig");
const gpu_abi = @import("../gpu_abi.zig");
const ad = @import("ad.zig");
const history = @import("history.zig");
const pattern = @import("pattern.zig");

const GROUND = root.GROUND;
const Batch = root.Batch;
const Circuit = root.Circuit;
const Planes = root.Planes;
const AdScalar = ad.AdScalar;
const HistoryBuffer = history.HistoryBuffer;
const HistLookup = history.HistLookup;
const PatternBuilder = pattern.PatternBuilder;
const tapeBounds = pattern.tapeBounds;
const buildTapes = pattern.buildTapes;

fn uCount(comptime D: type) usize {
    return @typeInfo(D.U).@"enum".fields.len;
}

pub fn ProtoStore(comptime D: type) type {
    const n_u = comptime uCount(D);
    return struct {
        models: std.ArrayList(D.Model) = .empty,
        instances: std.ArrayList(D.Instance) = .empty,
        nodes: std.ArrayList([n_u]u32) = .empty,

        const Self = @This();

        pub fn addPattern(ctx: *anyopaque, gpa: std.mem.Allocator, pb: *PatternBuilder) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try pb.reserve(gpa, self.nodes.items.len * n_u * n_u);
            for (self.nodes.items) |nd| {
                for (0..n_u) |ru| for (0..n_u) |cu| {
                    if (nd[ru] != GROUND and nd[cu] != GROUND)
                        try pb.add(gpa, nd[ru], nd[cu]);
                };
            }
        }

        pub fn finalize(ctx: *anyopaque, gpa: std.mem.Allocator, ckt: *const Circuit) anyerror!Batch {
            const has_prep_cache = @hasDecl(D, "PrepCache");
            const has_q = @hasDecl(D, "q");
            const const_g = @hasDecl(D, "constant_g") and D.constant_g;
            const const_c = @hasDecl(D, "constant_c") and D.constant_c;
            const has_attempt_decl = @hasDecl(D, "attempt");
            const self: *Self = @ptrCast(@alignCast(ctx));
            const count = self.models.items.len;
            const store = try gpa.create(DeviceBatch(D));
            errdefer gpa.destroy(store);

            store.count = count;
            store.models = try self.models.toOwnedSlice(gpa);
            if (comptime has_attempt_decl) {
                store.saved_models = try gpa.alloc(D.Model, count);
                store.attempt_saved = false;
            }
            if (comptime @hasDecl(D, "limit")) {
                store.lim_x = try gpa.alloc(f64, count * n_u);
                store.lim_active = false;
            }
            store.instances = try self.instances.toOwnedSlice(gpa);

            store.gath = try gpa.alloc(u32, count * n_u);
            store.rhs_idx = try gpa.alloc(u32, count * n_u);
            store.slots = try gpa.alloc(u32, count * n_u * n_u);
            // [n_u]u32 arrays are contiguous — view them flat for the shared tape builder.
            const flat_nodes = @as([*]const u32, @ptrCast(self.nodes.items.ptr))[0 .. count * n_u];
            buildTapes(flat_nodes, n_u, ckt, store.gath, store.rhs_idx, store.slots);
            self.nodes.deinit(gpa);
            self.nodes = .empty;

            if (comptime @hasDecl(D, "State")) {
                store.states = try gpa.alloc(D.State, count);
                for (0..count) |i| store.states[i] = D.initState(&store.models[i], &store.instances[i]);
            }
            if (comptime hasHistoryDecl(D)) {
                store.history_bufs = try gpa.alloc(HistoryBuffer, count);
                for (0..count) |i|
                    store.history_bufs[i] = try HistoryBuffer.init(gpa, D.n_hist_signals, 8192);
            }

            if (comptime @hasDecl(D, "precompute")) {
                for (0..count) |i| D.precompute(&store.instances[i], &store.models[i]);
            }

            if (comptime has_prep_cache) {
                // Compute all, then dedup by byte-equal PrepCache values.
                const all = try gpa.alloc(D.PrepCache, count);
                defer gpa.free(all);
                for (0..count) |i| all[i] = D.computePrep(&store.models[i], &store.instances[i]);

                store.prep_group = try gpa.alloc(u32, count);
                // Byte-keyed hash dedup: O(count), keys point into the
                // compacted prefix of `all` (slots never overwritten once
                // inserted, n_unique only grows).
                var seen: std.StringHashMapUnmanaged(u32) = .empty;
                defer seen.deinit(gpa);
                try seen.ensureTotalCapacity(gpa, @intCast(count));
                var n_unique: u32 = 0;
                for (0..count) |i| {
                    all[n_unique] = all[i];
                    const gop = seen.getOrPutAssumeCapacity(std.mem.asBytes(&all[n_unique]));
                    if (!gop.found_existing) {
                        gop.value_ptr.* = n_unique;
                        n_unique += 1;
                    }
                    store.prep_group[i] = gop.value_ptr.*;
                }
                store.prep_cache = try gpa.alloc(D.PrepCache, n_unique);
                @memcpy(store.prep_cache, all[0..n_unique]);
            }

            if (comptime canDedup(D)) {
                const ng = store.prep_cache.len;
                // No sharing found ⇒ cache can never hit; don't pay
                // per-eval memset + per-instance hash for nothing.
                store.dedup_worth = ng * 2 <= count;
                store.n_lanes = 1;
                store.eval_cache_hash = try gpa.alloc(u64, ng);
                @memset(store.eval_cache_hash, 0);
                store.eval_cache_rhs = try gpa.alloc([n_u]f64, ng);
                store.eval_cache_jac = try gpa.alloc([n_u][n_u]f64, ng);
                if (comptime canDedupQ(D)) {
                    store.eval_cache_q_rhs = try gpa.alloc([n_u]f64, ng);
                    store.eval_cache_q_jac = try gpa.alloc([n_u][n_u]f64, ng);
                }
            }

            return .{
                .ctx = store,
                .eval = DeviceBatch(D).eval,
                .eval_newton = DeviceBatch(D).evalNewton,
                .count = @intCast(count),
                .n_u = n_u,
                .has_charge = @hasDecl(D, "q"),
                .has_const_jacobian = const_g and (!has_q or const_c),
                .thread_safe = true,
                .type_name = @typeName(D),
                .gpu_kind_id = gpu_abi.kindId(D),
                .hooks = &DeviceBatch(D).hooks,
            };
        }

        pub fn applyPerm(ctx: *anyopaque, perm: []const u32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.nodes.items) |*nd| {
                inline for (0..n_u) |u| {
                    if (nd[u] < perm.len) nd[u] = perm[nd[u]];
                }
            }
        }

        pub fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.models.deinit(gpa);
            self.instances.deinit(gpa);
            self.nodes.deinit(gpa);
            gpa.destroy(self);
        }
    };
}

fn hasHistoryDecl(comptime D: type) bool {
    return @hasDecl(D, "histInject");
}

fn canDedup(comptime D: type) bool {
    return @hasDecl(D, "PrepCache") and !@hasDecl(D, "State") and !hasHistoryDecl(D);
}

fn canDedupQ(comptime D: type) bool {
    return canDedup(D) and @hasDecl(D, "q");
}

pub fn DeviceBatch(comptime D: type) type {
    const n_u = comptime uCount(D);
    const S = AdScalar(n_u);
    const has_q = @hasDecl(D, "q");
    const has_state = @hasDecl(D, "State");
    const has_hist = hasHistoryDecl(D);
    const has_prep_cache = @hasDecl(D, "PrepCache");
    const const_g = @hasDecl(D, "constant_g") and D.constant_g;
    const const_c = @hasDecl(D, "constant_c") and D.constant_c;
    const can_dedup = canDedup(D);
    const can_dedup_q = canDedupQ(D);

    const has_attempt = @hasDecl(D, "attempt");
    const has_limit = @hasDecl(D, "limit");

    return struct {
        count: usize,
        models: []D.Model,
        saved_models: if (has_attempt) []D.Model else void,
        /// True while saved_models holds the pre-continuation models.
        attempt_saved: if (has_attempt) bool else void,
        /// SPICE-style private limiting state: the per-instance local x the
        /// device EVALUATES at (pnjlim/fetlim/limvds applied), decoupled
        /// from the solver's node vector. ngspice keeps vd/vgs/... in
        /// CKTstate0 for exactly this; node-writeback limiting cannot work
        /// once zero-R primes are collapsed onto shared/driven nodes.
        lim_x: if (has_limit) []f64 else void,
        lim_active: if (has_limit) bool else void,
        instances: []D.Instance,
        states: if (has_state) []D.State else void,
        history_bufs: if (has_hist) []HistoryBuffer else void,
        /// [id*n_u + u] -> x index (ground stays 0; x[0] == 0 invariant)
        gath: []u32,
        /// [id*n_u + u] -> rhs/q_vec row (ground -> n, the trash row)
        rhs_idx: []u32,
        /// [(id*n_u + ru)*n_u + cu] -> plane slot (ground -> trash slot)
        slots: []u32,
        prep_cache: if (has_prep_cache) []D.PrepCache else void,
        // ponytail: dedup index — prep_cache is compact (unique entries only),
        // prep_group maps device id → prep_cache slot. Identity map when no dups found.
        prep_group: if (has_prep_cache) []u32 else void,

        // Lane-major dedup caches, [lane*ng + group]; ng = prep_cache.len.
        // Sized for n_lanes lanes; grown by setLanes (par.zig init).
        /// finalize found real prep sharing (ng*2 <= count); false ⇒ cache
        /// can't hit, dedup machinery skipped entirely at eval time.
        dedup_worth: if (can_dedup) bool else void,
        n_lanes: if (can_dedup) u32 else void,
        eval_cache_hash: if (can_dedup) []u64 else void,
        eval_cache_rhs: if (can_dedup) [][n_u]f64 else void,
        eval_cache_jac: if (can_dedup) [][n_u][n_u]f64 else void,
        eval_cache_q_rhs: if (can_dedup_q) [][n_u]f64 else void,
        eval_cache_q_jac: if (can_dedup_q) [][n_u][n_u]f64 else void,

        const Self = @This();

        /// Cold vtable — one static instance per device type, shared by every
        /// batch of that type. finalize() hands out &hooks.
        pub const hooks: root.Hooks = .{
            .set_lanes = if (can_dedup) setLanes else null,
            .scatter_bounds = scatterBounds,
            .apply_limits = if (has_limit) applyLimits else null,
            .clear_limits = if (has_limit) clearLimits else null,
            .seed = if (@hasDecl(D, "seed")) seedFn else null,
            .mark_current_rows = if (@hasDecl(D, "u_kinds")) markCurrentRows else null,
            .update_state = if (@hasDecl(D, "updateState")) updateState else null,
            .set_temp = if (@hasField(D.Instance, "temp")) setTemp else null,
            .record_history = if (has_hist) recordHistory else null,
            .inject_history = if (has_hist) injectHistory else null,
            .min_delay = if (has_hist) minDelay else null,
            .next_breakpoint = if (@hasDecl(D, "nextBreakpoint")) nextBreakpointFn else null,
            .collect_params = collectParams,
            .collect_noise = if (@hasDecl(D, "noise_gens")) collectNoise else null,
            .recompute = if (@hasDecl(D, "precompute") or has_prep_cache) recomputePrecomputed else null,
            .apply_attempt = if (has_attempt) applyAttempt else null,
            .restore_models = if (has_attempt) restoreAttempt else null,
            .gpu_pack_size = if (gpu_ok) gpuPackSize else null,
            .gpu_pack = if (gpu_ok) gpuPack else null,
            .deinit = destroy,
        };

        /// Full eval: stamps G, C, rhs, q_vec. Used for baseline and non-constant devices.
        fn eval(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64) void {
            evalInner(ctx, pl, lane, first, last, x, t, false);
        }

        /// Newton eval: skips G/C stamps for constant-Jacobian devices (already in baseline).
        fn evalNewton(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64) void {
            evalInner(ctx, pl, lane, first, last, x, t, true);
        }

        fn scatterBounds(ctx: *anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return tapeBounds(self.slots[first * n_u * n_u .. last * n_u * n_u], self.rhs_idx[first * n_u .. last * n_u], trash_slot, trash_row);
        }

        /// Grow the per-lane dedup caches (lane-major, [lane*ng + group]).
        fn setLanes(ctx: *anyopaque, gpa: std.mem.Allocator, n_lanes: u32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (n_lanes <= self.n_lanes) return;
            const ng = self.prep_cache.len;
            self.eval_cache_hash = try gpa.realloc(self.eval_cache_hash, ng * n_lanes);
            self.eval_cache_rhs = try gpa.realloc(self.eval_cache_rhs, ng * n_lanes);
            self.eval_cache_jac = try gpa.realloc(self.eval_cache_jac, ng * n_lanes);
            if (comptime can_dedup_q) {
                self.eval_cache_q_rhs = try gpa.realloc(self.eval_cache_q_rhs, ng * n_lanes);
                self.eval_cache_q_jac = try gpa.realloc(self.eval_cache_q_jac, ng * n_lanes);
            }
            @memset(self.eval_cache_hash, 0);
            self.n_lanes = n_lanes;
        }

        fn hashVoltages(lx: *const [n_u]f64) u64 {
            var h: u64 = 0x517cc1b727220a95;
            inline for (0..n_u) |u| {
                const v: f32 = @floatCast(lx[u]);
                h ^= @as(u64, @as(u32, @bitCast(v)));
                h *%= 0x9e3779b97f4a7c15;
            }
            return h | 1; // ensure non-zero so 0 = empty
        }

        /// The local x a device evaluates at: the private limited state
        /// while a Newton solve is limiting, the gathered node vector
        /// otherwise. `limiting` is the loop-invariant lim_active snapshot.
        inline fn evalX(self: *Self, x: []const f64, id: usize, limiting: bool) [n_u]f64 {
            if (comptime has_limit) {
                if (limiting) return self.lim_x[id * n_u ..][0..n_u].*;
            }
            return self.localX(x, id);
        }

        /// Companion-correction term J·(x_node − lx) for one residual row.
        /// Comptime-zero for devices without limiting — their scatter is a
        /// plain add, no vector multiply.
        inline fn corrDot(jrow: @Vector(n_u, f64), corr: @Vector(n_u, f64)) f64 {
            return if (comptime has_limit) @reduce(.Add, jrow * corr) else 0.0;
        }

        fn evalInner(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64, comptime skip_const: bool) void {
            @setFloatMode(.optimized);
            @setEvalBranchQuota(10_000);
            const self: *Self = @ptrCast(@alignCast(ctx));

            const skip_g = comptime (skip_const and const_g);
            const skip_c = comptime (skip_const and const_c);

            // Dedup engages on ranges of >= 4 instances, and only when
            // finalize found real prep sharing (dedup_worth).
            const dedup_on = if (comptime can_dedup) self.dedup_worth and last - first >= 4 else false;
            // Lane's cache segment: [lane*ng + group].
            const lane_off: usize = if (comptime can_dedup) @as(usize, lane) * self.prep_cache.len else 0;

            // Reset this lane's cache at start of each full-eval pass.
            if (comptime can_dedup) {
                if (dedup_on) @memset(self.eval_cache_hash[lane_off..][0..self.prep_cache.len], 0);
            }

            // Loop-invariant limiting snapshot: one field read, not one per
            // instance. Comptime-false for devices without a limit decl.
            const limiting = if (comptime has_limit) self.lim_active else false;

            for (first..last) |id| {
                const lx = self.evalX(x, id, limiting);
                // SPICE companion correction: the device is EVALUATED at its
                // limited state lx, but Newton applies dx to the node vector.
                // The stamped residual must be the linearization extended to
                // the node point: i(lx) + J·(x_node − lx) — dioload.c's
                // `cdeq = cd − gd·vd` in local form. corr = 0 when limiting
                // is inactive (lx == gathered x).
                var corr: @Vector(n_u, f64) = @splat(0);
                if (comptime has_limit) {
                    if (limiting) {
                        const xn = self.localX(x, id);
                        inline for (0..n_u) |u| corr[u] = xn[u] - lx[u];
                    }
                }
                // Eval dedup: check if this prep group already has a cached result
                // for the same terminal voltages (the ACTUAL eval input —
                // limited state included, so instances with equal node
                // voltages but different limiting histories never alias).
                // group/h computed once, reused by the miss-path store below.
                const group: usize = if (comptime can_dedup) lane_off + self.prep_group[id] else 0;
                const h: u64 = if (comptime can_dedup) (if (dedup_on) hashVoltages(&lx) else 0) else 0;
                if (comptime can_dedup and !skip_g and !skip_c) {
                    if (dedup_on) {
                        if (self.eval_cache_hash[group] == h) {
                            // Cache hit — scatter from cached result
                            // (+ per-instance companion correction).
                            const cr = &self.eval_cache_rhs[group];
                            const cj = &self.eval_cache_jac[group];
                            inline for (0..n_u) |ru| {
                                const cjv: @Vector(n_u, f64) = cj[ru];
                                pl.rhs[self.rhs_idx[id * n_u + ru]] += cr[ru] + corrDot(cjv, corr);
                                inline for (0..n_u) |cu|
                                    pl.g_vals[self.slots[(id * n_u + ru) * n_u + cu]] += cj[ru][cu];
                            }
                            if (comptime can_dedup_q) {
                                const cqr = &self.eval_cache_q_rhs[group];
                                const cqj = &self.eval_cache_q_jac[group];
                                inline for (0..n_u) |ru| {
                                    const cqjv: @Vector(n_u, f64) = cqj[ru];
                                    pl.q_vec[self.rhs_idx[id * n_u + ru]] += cqr[ru] + corrDot(cqjv, corr);
                                    inline for (0..n_u) |cu|
                                        pl.c_vals[self.slots[(id * n_u + ru) * n_u + cu]] += cqj[ru][cu];
                                }
                            }
                            continue;
                        }
                    }
                }

                var xd: [n_u]S = undefined;
                inline for (0..n_u) |u| {
                    var d: @Vector(n_u, f64) = @splat(0);
                    d[u] = 1;
                    xd[u] = .{ .v = lx[u], .d = d };
                }

                const pc_ptr = if (comptime has_prep_cache) &self.prep_cache[self.prep_group[id]] else undefined;

                // Residual always stamps; the Jacobian only when it is not
                // already frozen in the baseline (skip_const + constant_*).
                const out = if (comptime @hasDecl(D, "evalFromPrep"))
                    D.evalFromPrep(S, xd, pc_ptr, &self.models[id], &self.instances[id], t)
                else
                    D.eval(S, xd, &self.models[id], &self.instances[id], t);
                inline for (0..n_u) |ru| {
                    pl.rhs[self.rhs_idx[id * n_u + ru]] += out[ru].v + corrDot(out[ru].d, corr);
                    if (comptime !skip_g) {
                        inline for (0..n_u) |cu|
                            pl.g_vals[self.slots[(id * n_u + ru) * n_u + cu]] += out[ru].d[cu];
                    }
                }
                // Cache the result for this prep group (raw, at lx — the
                // companion correction is per-instance and applied at
                // scatter time on both hit and miss paths).
                if (comptime can_dedup and !skip_g) {
                    if (dedup_on) {
                        self.eval_cache_hash[group] = h;
                        inline for (0..n_u) |ru| {
                            self.eval_cache_rhs[group][ru] = out[ru].v;
                            inline for (0..n_u) |cu|
                                self.eval_cache_jac[group][ru][cu] = out[ru].d[cu];
                        }
                    }
                }

                if (comptime has_q) {
                    const qo = if (comptime @hasDecl(D, "qFromPrep"))
                        D.qFromPrep(S, xd, pc_ptr, &self.models[id], &self.instances[id], t)
                    else
                        D.q(S, xd, &self.models[id], &self.instances[id], t);
                    inline for (0..n_u) |ru| {
                        pl.q_vec[self.rhs_idx[id * n_u + ru]] += qo[ru].v + corrDot(qo[ru].d, corr);
                        if (comptime !skip_c) {
                            inline for (0..n_u) |cu|
                                pl.c_vals[self.slots[(id * n_u + ru) * n_u + cu]] += qo[ru].d[cu];
                        }
                    }
                    if (comptime can_dedup_q and !skip_c) {
                        if (dedup_on) {
                            inline for (0..n_u) |ru| {
                                self.eval_cache_q_rhs[group][ru] = qo[ru].v;
                                inline for (0..n_u) |cu|
                                    self.eval_cache_q_jac[group][ru][cu] = qo[ru].d[cu];
                            }
                        }
                    }
                }
            }
        }

        fn localX(self: *Self, x: []const f64, id: usize) [n_u]f64 {
            var out: [n_u]f64 = undefined;
            inline for (0..n_u) |u| out[u] = x[self.gath[id * n_u + u]];
            return out;
        }

        /// SPICE MODEINITJCT: scatter device junction seeds into a cold x.
        /// Per-unknown ?f64 — null leaves externally driven terminals alone.
        fn seedFn(ctx: *anyopaque, x: []f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                const sv = D.seed(&self.models[id], &self.instances[id]);
                inline for (0..n_u) |u| if (sv[u]) |v| {
                    const node = self.gath[id * n_u + u];
                    if (node != GROUND) x[node] = v;
                };
            }
        }

        /// Mark unknowns whose kind is not .voltage (MNA branch currents).
        fn markCurrentRows(ctx: *anyopaque, mask: []bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                inline for (0..n_u) |u| {
                    if (comptime D.u_kinds[u] != .voltage) {
                        const node = self.gath[id * n_u + u];
                        if (node != GROUND) mask[node] = true;
                    }
                }
            }
        }

        /// SPICE-style limiting: compute each instance's limited local x and
        /// store it as PRIVATE state (lim_x) consumed by the next eval. The
        /// solver's node vector is never written — writing driven/shared
        /// nodes fights sources and other devices on the same net. The
        /// "previous" voltages passed to D.limit are the ones the device
        /// actually evaluated at last iteration (ngspice keeps vd/vgs/…
        /// in CKTstate0 for exactly this).
        fn applyLimits(ctx: *anyopaque, x: []f64, x_old: []const f64) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var any_limited = false;
            for (0..self.count) |id| {
                const cur = self.localX(x, id);
                const old: [n_u]f64 = if (self.lim_active)
                    self.lim_x[id * n_u ..][0..n_u].*
                else
                    self.localX(x_old, id);
                const limited = D.limit(&self.models[id], &self.instances[id], cur, old);
                inline for (0..n_u) |u| {
                    if (limited[u] != cur[u]) any_limited = true;
                    self.lim_x[id * n_u + u] = limited[u];
                }
            }
            self.lim_active = true;
            return any_limited;
        }

        /// End-of-solve: evals go back to reading the node vector.
        fn clearLimits(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.lim_active = false;
        }

        fn updateState(ctx: *anyopaque, x: []const f64) ?f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var min_reject: ?f64 = null;
            for (0..self.count) |id| {
                const lx = self.localX(x, id);
                switch (D.updateState(&self.models[id], &self.instances[id], lx, &self.states[id])) {
                    .ok => {},
                    .request_reject_at => |tr| {
                        min_reject = if (min_reject) |cur| @min(cur, tr) else tr;
                    },
                }
            }
            return min_reject;
        }

        fn setTemp(ctx: *anyopaque, temp_c: f32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.instances) |*inst| {
                // ponytail: infer K vs degC from default — >200 means Kelvin
                const default_temp = @field(D.Instance{}, "temp");
                inst.temp = if (default_temp > 200) temp_c + 273.15 else temp_c;
            }
            self.reprep();
        }

        fn applyAttempt(ctx: *anyopaque, lambda: f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Save the TRUE models exactly once per continuation; every
            // lambda derives from them. Re-saving on each call compounds
            // the scaling (dc·λ₁·λ₂·…) — after λ=0 every later step AND
            // the restore ran with sources at zero, and Newton then
            // "converged" to the all-zero solution of that wrong circuit.
            if (!self.attempt_saved) {
                @memcpy(self.saved_models, self.models);
                self.attempt_saved = true;
            }
            for (self.models, self.saved_models) |*m, s| m.* = D.attempt(s, lambda);
            self.reprep();
        }

        fn restoreAttempt(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (!self.attempt_saved) return;
            self.attempt_saved = false;
            @memcpy(self.models, self.saved_models);
            self.reprep();
        }

        fn recomputePrecomputed(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.reprep();
        }

        /// Re-derive everything downstream of a model/instance change.
        fn reprep(self: *Self) void {
            if (comptime @hasDecl(D, "precompute")) {
                for (self.instances, self.models) |*inst, *mdl| D.precompute(inst, mdl);
            }
            if (comptime has_prep_cache) {
                // Groups are numbered in first-occurrence order (finalize's
                // dedup assigns new ids as it walks the devices), so one
                // O(count) pass meets each group's representative first.
                var next: u32 = 0;
                for (self.prep_group, 0..) |g, i| {
                    if (g == next) {
                        self.prep_cache[next] = D.computePrep(&self.models[i], &self.instances[i]);
                        next += 1;
                    }
                }
            }
        }

        fn recordHistory(ctx: *anyopaque, x: []const f64, t: f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                const signals = D.gatherHistSignals(self.localX(x, id));
                self.history_bufs[id].record(t, &signals);
            }
        }

        fn injectHistory(ctx: *anyopaque, t: f64, rhs: []f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                // Concrete HistLookup value so devices can take `lookup: anytype`
                // (they cannot name this module's types).
                const adds = D.histInject(&self.models[id], HistLookup{ .buf = &self.history_bufs[id] }, t);
                inline for (0..n_u) |u| rhs[self.rhs_idx[id * n_u + u]] += adds[u];
            }
        }

        fn minDelay(ctx: *anyopaque) f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var min_td = std.math.inf(f64);
            for (self.models) |*m| {
                for (D.delays(m)) |d| min_td = @min(min_td, d);
            }
            return min_td;
        }

        fn nextBreakpointFn(ctx: *anyopaque, t: f64) ?f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var best: f64 = std.math.inf(f64);
            for (self.models) |*m| {
                if (D.nextBreakpoint(m, t)) |bp| best = @min(best, bp);
            }
            return if (best == std.math.inf(f64)) null else best;
        }

        fn collectParams(ctx: *anyopaque, gpa: std.mem.Allocator, list: *std.ArrayList(root.ParamRef)) anyerror!void {
            @setEvalBranchQuota(100_000);
            const self: *Self = @ptrCast(@alignCast(ctx));
            try appendParams(D.Instance, self.instances, true, gpa, list);
            try appendParams(D.Model, self.models, false, gpa, list);
        }

        /// Shared Instance/Model walk. Primary = mc_param match when the
        /// device declares one, else the first instance param field.
        fn appendParams(comptime T: type, items: anytype, comptime is_instance: bool, gpa: std.mem.Allocator, list: *std.ArrayList(root.ParamRef)) anyerror!void {
            const type_name = comptime blk: {
                const full = @typeName(D);
                const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse break :blk full;
                break :blk full[dot + 1 ..];
            };
            comptime var field_idx: usize = 0;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime paramField(T, field)) {
                    const primary = comptime if (@hasDecl(D, "mc_param"))
                        std.mem.eql(u8, field.name, D.mc_param)
                    else
                        is_instance and field_idx == 0;
                    for (items, 0..) |*it, idx| {
                        try list.append(gpa, .{
                            .ptr = &@field(it, field.name),
                            .device_type = type_name,
                            .param_name = field.name,
                            .index = @intCast(idx),
                            .is_instance = is_instance,
                            .primary = primary,
                        });
                    }
                    field_idx += 1;
                }
            }
        }

        /// f32 scalar with a non-sentinel default = a real, perturbable parameter.
        fn paramField(comptime T: type, comptime field: std.builtin.Type.StructField) bool {
            if (field.type != f32) return false;
            const dflt = @field(T{}, field.name);
            return dflt > -1e30 and dflt < 1e30;
        }

        /// Noise conductance straight off the analytic Jacobian at x_op.
        /// Devices declare their generators as comptime `noise_gens` metadata
        /// (builtin noise) — this reads the conductance for each generator
        /// from the AD pass, so noise analyses never re-derive it.
        fn collectNoise(ctx: *anyopaque, x: []const f64, gpa: std.mem.Allocator, list: *std.ArrayList(root.NoiseSource)) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                var xd: [n_u]S = undefined;
                inline for (0..n_u) |u| {
                    var d: @Vector(n_u, f64) = @splat(0);
                    d[u] = 1;
                    xd[u] = .{ .v = x[self.gath[id * n_u + u]], .d = d };
                }
                const out = D.eval(S, xd, &self.models[id], &self.instances[id], 0);
                inline for (D.noise_gens) |gen| {
                    switch (gen.kind) {
                        .thermal => {
                            const g = @abs(out[gen.row].d[gen.col]);
                            if (g > 0) try list.append(gpa, .{
                                .node_p = self.gath[id * n_u + gen.row],
                                .node_n = self.gath[id * n_u + gen.col],
                                .conductance = g,
                            });
                        },
                        // ponytail: shot/flicker need branch current + KF/AF;
                        // add a device noisePsd hook when greenlit.
                        .shot, .flicker => {},
                    }
                }
            }
        }

        // -- GPU packing: serialize this batch's SoA tapes + params into the
        // problem blob. Layout assumption: D.Model/D.Instance byte layouts
        // match between x86_64 and nvptx64 (both LP64, natural alignment) —
        // the same assumption GpuEvalKernel's models/instances params make.
        // Kernel compiles every device type; only state/history (CPU-side
        // integration) disqualifies a batch.
        const gpu_ok = !has_state and !has_hist;

        fn gpuPackSize(ctx: *anyopaque) usize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const c = self.count;
            const a8 = gpu_abi.alignUp;
            var sz: usize = a8(c * n_u * 4, 8) * 2; // gath + rhs_idx
            sz += a8(c * @sizeOf(D.Model), 8) + a8(c * @sizeOf(D.Instance), 8);
            if (comptime has_prep_cache)
                sz += a8(self.prep_cache.len * @sizeOf(D.PrepCache), 8) + a8(c * 4, 8);
            return sz;
        }

        fn gpuPack(ctx: *anyopaque, dest: []u8, base_off: u32, n: u32) gpu_abi.BatchDesc {
            _ = n;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const c = self.count;
            var desc: gpu_abi.BatchDesc = .{
                .kind_id = gpu_abi.kindId(D),
                .count = @intCast(c),
                .n_u = n_u,
                .has_q = @intFromBool(has_q),
                .off_gath = 0,
                .off_rhs_idx = 0,
                .off_models = 0,
                .off_instances = 0,
                .off_prep_cache = 0,
                .off_prep_group = 0,
            };
            var off: usize = 0;
            desc.off_gath = put(dest, &off, base_off, std.mem.sliceAsBytes(self.gath));
            desc.off_rhs_idx = put(dest, &off, base_off, std.mem.sliceAsBytes(self.rhs_idx));
            desc.off_models = put(dest, &off, base_off, std.mem.sliceAsBytes(self.models));
            desc.off_instances = put(dest, &off, base_off, std.mem.sliceAsBytes(self.instances));
            if (comptime has_prep_cache) {
                desc.off_prep_cache = put(dest, &off, base_off, std.mem.sliceAsBytes(self.prep_cache));
                desc.off_prep_group = put(dest, &off, base_off, std.mem.sliceAsBytes(self.prep_group));
            }
            return desc;
        }

        fn put(dest: []u8, off: *usize, base_off: u32, bytes: []const u8) u32 {
            const at = off.*;
            @memcpy(dest[at..][0..bytes.len], bytes);
            off.* = gpu_abi.alignUp(at + bytes.len, 8);
            return base_off + @as(u32, @intCast(at));
        }

        fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            gpa.free(self.models);
            if (comptime has_attempt) gpa.free(self.saved_models);
            if (comptime has_limit) gpa.free(self.lim_x);
            gpa.free(self.instances);
            if (comptime has_prep_cache) {
                gpa.free(self.prep_cache);
                gpa.free(self.prep_group);
            }
            if (comptime has_state) gpa.free(self.states);
            if (comptime has_hist) {
                for (self.history_bufs) |buf| {
                    gpa.free(buf.times);
                    gpa.free(buf.values);
                }
                gpa.free(self.history_bufs);
            }
            if (comptime can_dedup) {
                gpa.free(self.eval_cache_hash);
                gpa.free(self.eval_cache_rhs);
                gpa.free(self.eval_cache_jac);
                if (comptime can_dedup_q) {
                    gpa.free(self.eval_cache_q_rhs);
                    gpa.free(self.eval_cache_q_jac);
                }
            }
            gpa.free(self.gath);
            gpa.free(self.rhs_idx);
            gpa.free(self.slots);
            gpa.destroy(self);
        }
    };
}
