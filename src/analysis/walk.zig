//! Host walks over a batch slice: each runs one device hook over every
//! batch in order. `Circuit` walks all of its batches; the GPU context walks
//! the ones it keeps on the host, or all of them after a fault.
const device_ir = @import("device").abi;

const Batch = device_ir.Batch;
const StateCtlOp = device_ir.StateCtlOp;

/// `applyLimits` over `batches` on the host.
pub fn limitBatches(batches: []const Batch, x: []f64, x_old: []const f64) bool {
    var any_limited = false;
    for (batches) |b| if (b.hooks.apply_limits) |f| {
        if (f(b.ctx, x, x_old)) any_limited = true;
    };
    return any_limited;
}

/// `seedJunctions` over `batches` on the host.
pub fn seedBatches(batches: []const Batch, x: []f64) void {
    for (batches) |b| if (b.hooks.seed) |f| f(b.ctx, x);
}

/// `clearLimits` over `batches` on the host.
pub fn clearLimitBatches(batches: []const Batch) void {
    for (batches) |b| if (b.hooks.clear_limits) |f| f(b.ctx);
}

/// `updateStates`' device walk over `batches`: the earliest reject time,
/// or null. Stages state for the next `stateCtl`.
pub fn updateBatches(batches: []const Batch, x: []const f64) ?f64 {
    return minReject(batches, "update_state", x);
}

/// `stateCtl` over `batches` on the host.
pub fn stateCtlBatches(batches: []const Batch, sop: StateCtlOp) bool {
    var dirty = false;
    for (batches) |b| if (b.hooks.state_ctl) |f| {
        if (f(b.ctx, sop)) dirty = true;
    };
    return dirty;
}

/// Earliest step-reject time any batch's `hook` returns, or null.
pub fn minReject(batches: []const Batch, comptime hook: []const u8, x: []const f64) ?f64 {
    var min_reject: ?f64 = null;
    for (batches) |b| {
        if (@field(b.hooks, hook)) |f| if (f(b.ctx, x)) |tr| {
            min_reject = if (min_reject) |cur| @min(cur, tr) else tr;
        };
    }
    return min_reject;
}
