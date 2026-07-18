//! Cooperative analysis checkpoints: the event an analysis reports and the
//! callback that may park or cancel it. Owns no circuit or solver state.

/// The analysis stage an `Event` reports from. Only `.nonlinear` is
/// filtered: workers park on it only under `Options.report_nonlinear`.
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

/// Progress within the current phase invocation; a restarted solve may reset
/// it. `total == 0` means unknown. u64 because long runs pass 2^32 units.
pub const Event = struct {
    phase: Phase,
    completed: u64,
    total: u64 = 0,
    /// Transient only: time reached, the step just taken and the next one (s),
    /// and the accepted-point count.
    simulation_time: ?f64 = null,
    step_size: ?f64 = null,
    next_step: ?f64 = null,
    accepted: ?u32 = null,
};

/// Called by the analysis's own worker thread at a resumable boundary.
pub const Callback = struct {
    ctx: *anyopaque,
    yield_fn: *const fn (*anyopaque, Event) error{QueryCancelled}!void,

    /// Reports `event` and may block until resumed. Fails when the query was
    /// cancelled; the analysis must unwind.
    pub fn checkpoint(self: Callback, event: Event) error{QueryCancelled}!void {
        return self.yield_fn(self.ctx, event);
    }
};
