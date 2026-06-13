//! Everything a deck says besides its topology: probes, sources, options,
//! queries and the bindings later directives resolve against.
const requests = @import("query.zig");
const numerics = @import("numerics.zig");

/// A resolved `.ic` value; all of them apply together when a query starts
/// with UIC.
pub const Ic = struct { node: u32, value: f64 };

/// A device parameter value that replaces the DC one in AC-family analyses
/// (a resistor's `ac=`). Stored by identity; each analysis clone resolves
/// its own parameter pointer.
pub const AcOverride = struct {
    type: @import("root.zig").DeviceType,
    /// Instance index within `type`.
    index: u32,
    param_name: []const u8,
    value: f64,
};

/// Circuit variants over one topology: `.step` and `.data` points, `.alter`
/// runs and Monte Carlo trials. Variant `v` writes `values[i]` to parameter
/// `refs[i]` (an index into the circuit's `collectParams` list) for every
/// `i` in `starts[v]..starts[v + 1]`, then runs at `temp_c[v]` when that is
/// set. A query runs variant `Tolerances.variant`; the rows are SoA and
/// `starts` has one entry more than `labels`.
pub const Variants = struct {
    /// Plot-name suffix without parentheses: `p=1.5`, `alter=2`, `monte=3`.
    labels: []const []const u8 = &.{},
    /// Circuit temperature in °C, or null for the deck's.
    temp_c: []const ?f64 = &.{},
    /// The variant's value of the first swept name (the trial number for
    /// Monte Carlo), the sweep axis of a lane query.
    axis: []const f64 = &.{},
    starts: []const u32 = &.{},
    refs: []const u32 = &.{},
    values: []const f64 = &.{},

    /// Number of variants (rows).
    pub fn count(self: Variants) u32 {
        return @intCast(self.labels.len);
    }

    /// The parameter writes of variant `v`: `.{ refs, values }`.
    pub fn writes(self: Variants, v: u32) struct { []const u32, []const f64 } {
        const lo = self.starts[v];
        const hi = self.starts[v + 1];
        return .{ self.refs[lo..hi], self.values[lo..hi] };
    }
};

/// Source bindings kept from construction so later analysis directives can
/// name sources and ports. All rows are post-permutation.
pub const QueryBindings = struct {
    /// V card names, parallel to `v_branches`, `v_pos`, `v_neg`, `v_distof1`.
    v_names: []const []const u8,
    /// I card names, parallel to `i_pos` and `i_neg`.
    i_names: []const []const u8,
    /// MNA branch row of each V card.
    v_branches: []const u32,
    /// Node rows of each V card: `+` then `-`.
    v_pos: []const u32,
    v_neg: []const u32,
    /// Node rows of each I card. An I source has no branch row.
    i_pos: []const u32,
    i_neg: []const u32,
    /// `DISTOF1 <mag> <phase>` of each V card.
    v_distof1: []const [2]f64,
    ports: []const requests.Port,
};

/// The prepared deck. Session-owned; every slice lives in the arena that
/// built the circuit.
pub const Deck = struct {
    /// MNA rows to publish, parallel to `probe_labels`.
    probes: []const u32,
    probe_labels: []const []const u8,
    /// Node and branch row of the drive source that analyses default to.
    source_node: u32,
    source_branch: u32,
    /// Row of the last net the deck introduces: the output of cards that
    /// name none (`.pac`, `.pxf`, `.disto`). Not the last probe, whose place
    /// the BBD permutation moves.
    output_node: u32,
    /// AC excitation: n real rows, then n imaginary rows.
    ac_drive: []const f64,
    title: []const u8,
    n_devices: u32,
    ic: []const Ic,
    /// `.nodeset` guesses: where the operating point's first solve holds
    /// each node.
    nodeset: []const Ic = &.{},
    /// `.options` tolerances every query starts from.
    deck_tol: numerics.Tolerances,
    /// `.temp` or `.options temp`, in °C, when given.
    deck_temp: ?f64,
    /// `.options method`, when given.
    deck_method: ?requests.Method,
    queries: []const requests.Query,
    bindings: QueryBindings,
    /// Card name of every device instance, for result labels.
    cards: []const requests.CardRef,
    ac_overrides: []const AcOverride,
    /// `.meas` cards, in deck order, evaluated over finished results.
    measures: []const Measure = &.{},
    variants: Variants = .{},
};

/// What a `.meas` card computes, after ngspice com_measure2.c, plus the
/// HSPICE forms: `param` (an expression over other results) and the `err`
/// relative-error family [CR .MEASURE (Error Function)], and the FFT
/// figures THD, SNR, SNDR, ENOB and SFDR [CR .MEASURE FFT].
pub const MeasureFunc = enum(u8) { trig_targ, find, when, avg, min, max, min_at, max_at, pp, rms, integ, deriv, param, err, err1, err2, err3, thd, snr, sndr, enob, sfdr };

/// One postfix op of a `PARAM=` measure: a constant, the result of the
/// `measure`-th card, or an arithmetic operator.
pub const MeasureOp = union(enum) { num: f64, measure: u32, neg, add, sub, mul, div, pow };

/// Event count not given (ngspice MEASURE_DEFAULT).
pub const measure_unset: i32 = -1;
/// `RISE=LAST` and friends (ngspice MEASURE_LAST_TRANSITION).
pub const measure_last: i32 = -2;
/// `AT` not given.
pub const measure_no_at: f64 = 1e99;

/// One clause of a `.meas` card: ngspice's `struct measure`, with its
/// defaults. For `.meas dc`, `from`/`to` default to -1e99/1e99.
pub const MeasureClause = struct {
    /// Result variable name as the result labels it (`v(out)`).
    vec: []const u8 = "",
    /// Right side of `WHEN vec=vec2`; empty when the level is `val`.
    vec2: []const u8 = "",
    /// How an AC value is read: `m`, `p`, `r`, `i`, `d` from `vm(..)` and
    /// the like, 0 for the real part.
    vectype: u8 = 0,
    val: f64 = 0,
    rise: i32 = measure_unset,
    fall: i32 = measure_unset,
    cross: i32 = measure_unset,
    td: f64 = 0,
    from: f64 = 0,
    to: f64 = 0,
    at: f64 = measure_no_at,
    /// ERR family: the smallest |meas_var| used as a denominator, and the
    /// |meas_var| band outside which a point is skipped (HSPICE defaults).
    minval: f64 = 1e-12,
    ymin: f64 = 1e-15,
    ymax: f64 = 1e15,
    /// FFT figures: the highest harmonic counted as distortion (0: every
    /// one in the spectrum), and the bins either side of the fundamental
    /// counted as signal. MINFREQ and MAXFREQ are `from` and `to`.
    nbharm: u32 = 0,
    binsiz: u32 = 0,
    /// HSPICE optimization target (`GOAL=`) and the weight of its error.
    goal: ?f64 = null,
    weight: f64 = 1,
};

/// A parsed `.meas` card.
pub const Measure = struct {
    /// `tran`, `ac`, `dc` or `fft`: the results it is evaluated over.
    analysis: requests.Kind,
    name: []const u8,
    func: MeasureFunc,
    /// TRIG, FIND's vector, WHEN's condition, or the vector a window
    /// function (AVG, MIN, RMS, ...) reads.
    first: MeasureClause,
    /// TARG, or FIND's WHEN clause.
    second: MeasureClause = .{},
    /// The expression of a `param` card.
    expr: []const MeasureOp = &.{},

    /// The card's optimization error for result `value`, HSPICE's
    /// WEIGHT * (result - GOAL) / max(|GOAL|, MINVAL), from the clause that
    /// carries `GOAL=`; null for a card without one.
    pub fn goalError(m: Measure, value: f64) ?f64 {
        const c = if (m.first.goal != null) m.first else if (m.second.goal != null) m.second else return null;
        const goal = c.goal.?;
        return c.weight * (value - goal) / @max(@abs(goal), c.minval);
    }
};
