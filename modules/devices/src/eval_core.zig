//! Single-source device eval loop + limiting pass, shared by the CPU batch
//! (batch.zig HostSink: slot-tape scatter, prep-cache dedup) and the GPU
//! megakernel (kernel_common.zig GpuSink: atomicAdd rhs/diag scatter).
//!
//! All memory access goes through the comptime-known sink, so this body is
//! addrspace-agnostic and compiles for x86_64 and nvptx64 alike. The sink
//! surface:
//!   consts:  dedup, skip_g, skip_c, optimized_float
//!   gather:  x(gi), xBase(gi), xOld(gi), gath(id,u), rhsRow(id,ru), lim(id,u)
//!   device:  model(id), inst(id), prep(id)
//!   scatter: scatterRes(row,val), scatterJac(id,ru,cu,row,val),
//!            qActive(), scatterQ(row,qv), scatterQJac(id,ru,cu,row,val)
//!   dedup:   tryCached(id,&lx,corr) bool, store(id,&out), storeQ(id,&qo)
//!   limit:   setLim(id,u,v)
//!
//! IMPORTANT: keep this file free of runtime std usage — it is compiled into
//! the GPU stub TUs.

const contract = @import("contract");
const Value = contract.Value;

/// Evaluate instances [first..end) with stride `step` (host: contiguous
/// lane range, step 1; GPU: grid-stride, first=tid, step=g.stride).
///
/// Device limiting (`limiting`, pre-ANDed with lim availability by the
/// caller): the device is EVALUATED at its private limited state lx, but
/// Newton applies dx to the node vector, so the stamped residual must be
/// the linearization extended to the node point — i(lx) + J(lx)·(x − lx)
/// (SPICE companion correction, dioload.c `cdeq = cd − gd·vd`).
///   with_diag (outer): eval at lx, add J·corr to the residual rows.
///   residual-only (J·v FD): eval at lx + (local(x) − local(x_base)) so the
///     finite difference against the same-shifted baseline yields J(lx)·v,
///     consistent with the outer linearization.
pub fn evalRange(
    comptime D: type,
    comptime with_diag: bool,
    sink: anytype,
    first: u32,
    end: u32,
    step: u32,
    t: f64,
    limiting: bool,
) void {
    @setEvalBranchQuota(1_000_000);
    const SinkT = @typeInfo(@TypeOf(sink)).pointer.child;
    @setFloatMode(if (SinkT.optimized_float) .optimized else .strict);
    const n_u = comptime contract.nU(D);
    const has_limit = comptime @hasDecl(D, "limit");
    const S = if (with_diag) contract.Dual(n_u) else Value;
    const use_lim = if (comptime has_limit) limiting else false;

    var id: u32 = first;
    while (id < end) : (id += step) {
        // Gather the local eval point; corr = local(x) − lx (zero when not
        // limiting).
        var lx: [n_u]f64 = undefined;
        var corr: @Vector(n_u, f64) = @splat(0);
        inline for (0..n_u) |u| {
            const gi = sink.gath(id, u);
            const xg = sink.x(gi);
            lx[u] = xg;
            if (use_lim) {
                if (comptime with_diag) {
                    const l = sink.lim(id, u);
                    lx[u] = l;
                    corr[u] = xg - l;
                } else {
                    lx[u] = sink.lim(id, u) + (xg - sink.xBase(gi));
                }
            }
        }

        // Eval dedup (host prep-cache path; compiles out on the GPU): hit ⇒
        // scatter from cached result (+ per-instance companion correction).
        if (comptime SinkT.dedup) {
            if (sink.tryCached(id, &lx, corr)) continue;
        }

        var xv: [n_u]S = undefined;
        inline for (0..n_u) |u| {
            if (comptime with_diag) {
                var d: @Vector(n_u, f64) = @splat(0);
                d[u] = 1;
                xv[u] = .{ .v = lx[u], .d = d };
            } else {
                xv[u] = Value.con(lx[u]);
            }
        }

        const out = if (comptime @hasDecl(D, "evalFromPrep"))
            D.evalFromPrep(S, xv, sink.prep(id), sink.model(id), sink.inst(id), t)
        else
            D.eval(S, xv, sink.model(id), sink.inst(id), t);

        // Residual always stamps; the Jacobian only when it is not already
        // frozen in the baseline (sink.skip_g/skip_c on the host Newton path).
        inline for (0..n_u) |ru| {
            const row = sink.rhsRow(id, ru);
            var val = out[ru].v;
            if (comptime with_diag and has_limit) {
                if (use_lim) val += @reduce(.Add, out[ru].d * corr);
            }
            sink.scatterRes(row, val);
            if (comptime with_diag and !SinkT.skip_g) {
                inline for (0..n_u) |cu| sink.scatterJac(id, ru, cu, row, out[ru].d[cu]);
            }
        }
        // Cache the result for this prep group (raw, at lx — the companion
        // correction is per-instance, applied at scatter time on both paths).
        if (comptime SinkT.dedup) sink.store(id, &out);

        if (comptime @hasDecl(D, "q")) {
            if (sink.qActive()) {
                const qo = if (comptime @hasDecl(D, "qFromPrep"))
                    D.qFromPrep(S, xv, sink.prep(id), sink.model(id), sink.inst(id), t)
                else
                    D.q(S, xv, sink.model(id), sink.inst(id), t);
                inline for (0..n_u) |ru| {
                    const row = sink.rhsRow(id, ru);
                    var qv = qo[ru].v;
                    if (comptime with_diag and has_limit) {
                        if (use_lim) qv += @reduce(.Add, qo[ru].d * corr);
                    }
                    sink.scatterQ(row, qv);
                    if (comptime with_diag and !SinkT.skip_c) {
                        inline for (0..n_u) |cu| sink.scatterQJac(id, ru, cu, row, qo[ru].d[cu]);
                    }
                }
                if (comptime SinkT.dedup) sink.storeQ(id, &qo);
            }
        }
    }
}

/// SPICE-style limiting pass over instances [first..end) stride `step`:
/// cur = local(x); old = lim (once engaged) else local(x_old);
/// lim = D.limit(cur, old). Returns 1.0 if any FLAGGED component was limited
/// (thread-local partial on the GPU; caller reduces / converts to bool).
pub fn limitRange(
    comptime D: type,
    sink: anytype,
    first: u32,
    end: u32,
    step: u32,
    lim_active: bool,
) f64 {
    const n_u = comptime contract.nU(D);
    var flag: f64 = 0;
    var id: u32 = first;
    while (id < end) : (id += step) {
        var cur: [n_u]f64 = undefined;
        var old: [n_u]f64 = undefined;
        inline for (0..n_u) |u| {
            const gi = sink.gath(id, u);
            cur[u] = sink.x(gi);
            old[u] = if (lim_active) sink.lim(id, u) else sink.xOld(gi);
        }
        const lm = D.limit(sink.model(id), sink.inst(id), cur, old);
        inline for (0..n_u) |u| {
            // ngspice: only pnjlim sets icheck (junction limiting forces
            // another Newton iteration); fetlim/limvds adjust the eval point
            // without vetoing convergence — counting them locks Newton in a
            // 2-cycle whenever vds straddles 0 and the mode branch
            // alternates. Devices declare which unknowns carry junction
            // limiting (limit_flag_unknowns).
            const flags: bool = comptime blk: {
                if (!@hasDecl(D, "limit_flag_unknowns")) break :blk true;
                for (D.limit_flag_unknowns) |fu| {
                    if (@intFromEnum(fu) == u) break :blk true;
                }
                break :blk false;
            };
            if (flags and lm[u] != cur[u]) flag = 1;
            sink.setLim(id, u, lm[u]);
        }
    }
    return flag;
}
