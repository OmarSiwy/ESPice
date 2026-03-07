//! Cooperative analysis checkpoints. This leaf owns no circuit or solver state.

pub const Phase = enum(u8) {
    prepare,
    nonlinear,
    dc,
    frequency,
    transient,
    periodic,
    harmonic,
    sweep,
    postprocess,
};

/// Work within the current phase invocation; a restarted solve may reset it.
/// Zero total means unknown. Long runs can exceed u32 work units.
pub const Event = struct {
    phase: Phase,
    completed: u64,
    total: u64 = 0,
    /// Transient boundary: reached time, completed attempt, and next step.
    simulation_time: ?f64 = null,
    step_size: ?f64 = null,
    next_step: ?f64 = null,
    accepted: ?u32 = null,
};

/// Called only by the analysis's owning worker, after a resumable boundary.
pub const Callback = struct {
    ctx: *anyopaque,
    yield_fn: *const fn (*anyopaque, Event) error{QueryCancelled}!void,

    pub fn checkpoint(self: Callback, event: Event) error{QueryCancelled}!void {
        return self.yield_fn(self.ctx, event);
    }
};
