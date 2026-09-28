//! Resolved query descriptions: the contract between the frontend, which
//! fills them from analysis cards (keywords in frontend/netlist.zig `cards`),
//! and the analysis drivers. Node and branch fields are MNA rows.
const std = @import("std");
const Tolerances = @import("numerics.zig").Tolerances;
const DeviceType = @import("root.zig").DeviceType;

/// Dense id of a query within one session.
pub const QueryId = enum(u32) { _ };
/// Sentinel `QueryId` that names no query.
pub const invalid_query: QueryId = @enumFromInt(std.math.maxInt(u32));
/// Transient integration method.
pub const Method = enum { backward_euler, trapezoidal, gear_2 };
pub const FreqSweep = @import("numerics.zig").FreqSweep;
pub const SweepKind = @import("numerics.zig").SweepKind;

/// One `.sp` port: the node and branch row of its source and its reference
/// impedance in ohms.
pub const Port = struct { node: u32, branch: u32, z0: f64 = 50.0 };

/// The card name of one device instance.
pub const CardRef = struct {
    type: DeviceType,
    /// Instance index within `type`.
    index: u32,
    name: []const u8,

    /// Returns the card name of instance `index` of type `t`, if listed.
    /// Linear scan over `cards`.
    pub fn lookup(cards: []const CardRef, t: DeviceType, index: u32) ?[]const u8 {
        for (cards) |c| if (c.index == index and c.type == t) return c.name;
        return null;
    }
};

pub const Ac = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
};

pub const Noise = struct {
    tol: Tolerances = .{},
    out_node: u32,
    /// `v(a,b)` reference: the measurement is v(out_node) - v(out_neg).
    /// GROUND is the single-ended case.
    out_neg: u32 = 0,
    sweep: FreqSweep,
    /// Branch row of the `.noise v(out) SRC ...` input source. It does not
    /// drive the solve; `inoise_spectrum` refers the output noise back to
    /// it. Null emits the output-referred curve only.
    in_branch: ?u32 = null,
    /// Emit integrated device noise in V rms instead of the measured PSD.
    integrated: bool = false,
};

pub const Sp = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    /// Explicit port list. Empty means one port at the deck's drive source
    /// (`Deck.source_node`/`source_branch`).
    ports: []const Port = &.{},
};

pub const Stb = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    /// The deck's own 0 V probe source (`.stb Vprobe ...`): its two node rows
    /// and its branch row. `probe_p` is the arriving (driven) side.
    probe_p: u32,
    probe_n: u32,
    probe_branch: u32,
};

pub const Op = struct {
    tol: Tolerances = .{},
    warm_start: bool = false,
    /// This operating point starts a transient (ngspice MODETRANOP), so
    /// waveform sources evaluate at t = 0 instead of at their DC value. The
    /// engine sets it when the deck has a transient-family query.
    tran_op: bool = false,
};

pub const Dc = struct {
    tol: Tolerances = .{},
    start: f64 = 0,
    stop: f64 = 0,
    step: f64 = 1,
    /// What the inner sweep drives, named by device type and parameter so a
    /// V card, an I card and a resistor with the same index stay distinct.
    target: SweepTarget = .{ .device = .{} },
    /// Optional outer sweep (`.dc src1 ... src2 start2 stop2 incr2`, or
    /// `.dc ... temp ...`).
    target2: ?SweepTarget = null,
    start2: f64 = 0,
    stop2: f64 = 0,
    step2: f64 = 1,

    /// The device parameter, or the temperature, a `.dc` sweep drives.
    pub const SweepTarget = union(enum) {
        device: Param,
        temp,

        /// A card parameter, keyed like `ParamRef`.
        pub const Param = struct {
            /// Set by the frontend from the swept card; `unset` names no card.
            type: DeviceType = .unset,
            /// Instance index within `type`.
            index: u32 = 0,
            param_name: []const u8 = "dc",
        };
    };

    pub fn hasOuter(self: Dc) bool {
        return self.target2 != null;
    }
};

pub const Tf = struct {
    tol: Tolerances = .{},
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    /// `.tf i(Vmeasure) ...`: the output is that source's branch current.
    /// When set, `output_node` and `output_neg` are unused.
    output_branch: ?u32 = null,
    /// `.tf v(out) Iin`: the input is a current source, which has no branch
    /// row, so the excitation is a unit current into this node pair. When
    /// set, `input_branch` is unused.
    input_nodes: ?[2]u32 = null,
    /// Branch row of the input V source. Null means `Deck.source_branch`.
    input_branch: ?u32 = null,
    /// Output row; unused when `output_branch` is set.
    output_node: u32,
};

pub const Dcmatch = struct {
    tol: Tolerances = .{},
    output_node: u32,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
};

pub const Pss = struct {
    tol: Tolerances = .{},
    /// Seconds.
    period: f64,
    max_shooting_iter: u16 = 50,
    shooting_tol: f64 = 1e-7,
    /// Perturbation of the finite-difference monodromy Jacobian.
    fd_epsilon: f64 = 1e-7,
    max_newton_iter: u16 = 50,
    newton_tol: f64 = 1e-9,
    /// Fixed trapezoidal steps per period; the waveform has n_samples + 1 rows.
    n_samples: u32 = 256,
    /// GMRES restart depth; used only on the Krylov path for large circuits.
    gmres_restart: u32 = 30,
    gmres_max_restarts: u32 = 10,
    /// Relative tolerance of the inner GMRES solve.
    gmres_tol: f64 = 1e-3,
    /// Oscillator node row of an autonomous solve (`.snosc`). The period is
    /// then an unknown and `period` only its first guess, and this node's
    /// value at t = 0 is pinned as the phase condition. GROUND means a
    /// driven circuit with a known period.
    osc_node: u32 = 0,
    /// Guess periods an autonomous solve integrates from the kicked DC
    /// point before it measures the period, so the oscillator has settled
    /// onto its limit cycle (HSPICE's TRINIT, counted in periods).
    osc_settle_periods: u16 = 30,
};

pub const Hb = struct {
    tol: Tolerances = .{},
    /// Fundamental, in Hz.
    f0: f64,
    n_harmonics: u16 = 8,
    max_iter: u16 = 200,
    hb_tol: f64 = 1e-9,
    /// Oscillator node row of an autonomous solve (`.hbosc`): f0 is then an
    /// unknown seeded from the oscillator's shooting orbit, and this node's
    /// fundamental is held a pure cosine as the phase condition. GROUND
    /// means a driven circuit with a known f0.
    osc_node: u32 = 0,
};

/// Periodic AC (`.pac`) and periodic transfer function (`.pxf`) options.
pub const Pac = struct {
    tol: Tolerances = .{},
    /// LO (pump) frequency in Hz: the fundamental periodicity.
    f_lo: f64,
    /// Output row: PAC's probe, PXF's injection point.
    out_node: u32,
    /// LO harmonics kept: sidebands span `-n_harmonics..n_harmonics`.
    n_harmonics: u16 = 3,
    /// Input frequency sweep.
    sweep: FreqSweep,
    /// Time samples per LO period. Must be a power of two and at least
    /// 2 * (2 * n_harmonics + 1).
    n_time_samples: u16 = 64,
    pss_newton_tol: f64 = 1e-9,
    pss_max_newton_iter: u16 = 50,
};

pub const Pnoise = struct {
    tol: Tolerances = .{},
    out_node: u32,
    /// `v(a,b)` reference: the measurement is v(out_node) - v(out_neg).
    /// GROUND is the single-ended case.
    out_neg: u32 = 0,
    sweep: FreqSweep,
    /// Hz.
    f_fundamental: f64,
    /// Time samples per period, rounded up to a power of two of at least
    /// 2 * (2 * n_sidebands + 1).
    pss_n_samples: u32 = 64,
    pss_shoot_tol: f64 = 1e-6,
    pss_shoot_max_iter: u16 = 50,
    pss_newton_max_iter: u16 = 50,
    pss_newton_tol: f64 = 1e-9,
    /// Sidebands kept on each side of the carrier.
    n_sidebands: u16 = 7,
};

/// Small-signal analyses about the harmonic-balance solution: `.hbac`
/// (periodic AC), `.hbxf` (periodic transfer function) and `.hbnoise`
/// (periodic noise) run the `.pac`, `.pxf` and `.pnoise` sweeps on the
/// `.hb` orbit instead of the shooting one.
pub const HbLptv = struct {
    tol: Tolerances = .{},
    /// HB fundamental, in Hz.
    f0: f64,
    /// HB harmonics kept.
    n_harmonics: u16 = 8,
    /// Sidebands kept on each side of the carrier in the conversion matrix.
    n_sidebands: u16 = 8,
    /// Output row: `.hbac`'s probe, `.hbxf`'s injection point, `.hbnoise`'s
    /// measured node.
    out_node: u32,
    /// `.hbnoise v(a,b)` reference node; GROUND is single-ended.
    out_neg: u32 = 0,
    /// Input (offset) frequency sweep.
    sweep: FreqSweep,
    max_iter: u16 = 200,
    hb_tol: f64 = 1e-9,

    /// The `.hb` solve this analysis linearizes about.
    pub fn hb(self: HbLptv) Hb {
        return .{ .tol = self.tol, .f0 = self.f0, .n_harmonics = self.n_harmonics, .max_iter = self.max_iter, .hb_tol = self.hb_tol };
    }
};

/// Oscillator phase noise (`.phasenoise`): the perturbation projection
/// vector of the autonomous HB solution (Demir's method, HSPICE METHOD=0)
/// projects every white noise source onto the oscillator's phase.
pub const PhaseNoise = struct {
    tol: Tolerances = .{},
    /// Oscillation frequency guess, in Hz.
    f0: f64,
    /// HB harmonics kept.
    n_harmonics: u16 = 8,
    /// Oscillator phase node (`Hb.osc_node`); never GROUND.
    osc_node: u32,
    /// Offset-from-carrier sweep.
    sweep: FreqSweep,
    max_iter: u16 = 200,
    hb_tol: f64 = 1e-9,

    /// The autonomous `.hb` solve the phase noise is computed about.
    pub fn hb(self: PhaseNoise) Hb {
        return .{ .tol = self.tol, .f0 = self.f0, .n_harmonics = self.n_harmonics, .max_iter = self.max_iter, .hb_tol = self.hb_tol, .osc_node = self.osc_node };
    }
};

/// Two-tone quasi-periodic steady state.
pub const Qpss = struct {
    tol: Tolerances = .{},
    /// The two fundamentals, in Hz.
    f1: f64,
    f2: f64,
    /// Harmonics kept of `f1` and `f2`.
    k1: u16 = 5,
    k2: u16 = 5,
    max_newton: u16 = 50,
    hb_tol: f64 = 1e-9,
    /// GMRES restart depth per Newton step.
    gmres_restart: u16 = 30,
    gmres_max_restarts: u16 = 10,
    gmres_tol: f64 = 1e-3,
};

pub const Tran = struct {
    tol: Tolerances = .{},
    /// Seconds, like every time field below.
    t_stop: f64,
    dt_init: f64 = 1e-9,
    dt_min: f64 = 1e-18,
    /// ngspice tstart: output suppression only. Integration still starts at
    /// t = 0 with the same history; points before `t_start` are dropped, and
    /// one step lands exactly on it, as ngspice's breakpoint does.
    t_start: f64 = 0,
    /// ngspice tmax. Null means t_stop / 50.
    dt_max: ?f64 = null,
    method: Method = .trapezoidal,
    /// Runaway guard only; `dt_min` is the real brake. A 1 s run on a 1 us
    /// grid is already 1e6 accepted points.
    max_steps: u32 = 1_000_000_000,
    /// `.tran ... uic`: no operating point runs; the starting state comes
    /// from the `.ic` cards (zero elsewhere), and the transient does the
    /// setup the operating point would have done.
    uic: bool = false,
};

pub const TranNoise = struct {
    tol: Tolerances = .{},
    /// Seconds, like every time field below.
    t_stop: f64,
    dt_init: f64 = 1e-9,
    dt_min: f64 = 1e-18,
    dt_max: f64 = 1e-3,
    /// Runaway guard only, as in `Tran.max_steps`.
    max_steps: u32 = 1_000_000_000,
    /// Noise generator seed; the same seed reproduces the same run.
    seed: u64 = 0xDEAD_BEEF_CAFE_1234,
};

pub const Envelope = struct {
    tol: Tolerances = .{},
    /// Carrier period (1 / f_carrier), in seconds.
    t_carrier: f64,
    /// Total simulated time, in seconds.
    t_stop: f64,
    carrier_steps_per_period: u32 = 64,
    /// Carrier periods per outer envelope step; 1 samples every period.
    periods_per_outer_step: u32 = 1,
    /// Outer steps allowed before giving up.
    max_outer_steps: u32 = 1_000_000,
    /// The outer step halves when the envelope changes by more than this
    /// fraction between two outer steps.
    envelope_reltol: f64 = 0.05,
    /// Outer step bounds, in carrier periods.
    min_periods_per_step: u32 = 1,
    max_periods_per_step: u32 = 16,
};

/// Matrix-exponential transient (MATEX).
pub const Matex = struct {
    tol: Tolerances = .{},
    /// Seconds.
    t_stop: f64,
    /// Krylov posterior tolerance, the exponential's counterpart of reltol.
    krylov_tol: f64 = 1e-10,
    /// Largest Krylov subspace before the step fails.
    m_max: u32 = 80,
    /// R-MATEX shift γ, on the order of the intended step; results are
    /// insensitive to it. Null means t_stop / 1000.
    gamma: ?f64 = null,
    /// Largest step between recorded points. Null means t_stop / 200.
    h_output_cap: ?f64 = null,
    /// Recorded-point ceiling; sizes the initial waveform allocation.
    max_points: u32 = 1 << 22,
};

/// Monte Carlo over the DC solution.
pub const Mc = struct {
    tol: Tolerances = .{},
    n_trials: u16 = 100,
    /// PRNG seed; the same seed reproduces the same trials.
    seed: u64 = 42,
    /// Relative spread applied to every primary instance value.
    variation: f64 = 0.05,
    /// Options for each trial's DC solve.
    dc_options: Dc = .{},
};

/// DC solution over a temperature sweep, in °C.
pub const Temp = struct {
    tol: Tolerances = .{},
    t_start: f64 = -40.0,
    t_stop: f64 = 125.0,
    t_step: f64 = 1.0,
    t_nom: f64 = 27.0,
    dc_options: Dc = .{},
};

pub const Sens = struct {
    tol: Tolerances = .{},
    output_node: u32,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    /// Card names for the result columns, so they match ngspice's. Empty
    /// falls back to `<type>#<ordinal>`.
    cards: []const CardRef = &.{},
};

pub const Pz = struct {
    tol: Tolerances = .{},
    qr_max_iter: u32 = 1000,
    qr_tol: f64 = 1e-12,
    /// Output side of `.pz in+ in- out+ out- vol|cur pol|zer|pz`. A bare
    /// `.pz` leaves both at GROUND and asks for the circuit's own poles.
    out_pos: u32 = 0,
    out_neg: u32 = 0,
    /// Where the input drive enters. `vol` drives a voltage source, so this
    /// is its branch row; GROUND selects `cur`, a current injected at
    /// `in_pos`/`in_neg`. Same convention as `Disto.drive_branch`.
    drive_branch: u32 = 0,
    in_pos: u32 = 0,
    in_neg: u32 = 0,
    /// The card's `pol`, `zer` or `pz`.
    want: Want = .poles,

    pub const Want = enum(u2) { poles, zeros, both };
};

pub const Four = struct {
    tol: Tolerances = .{},
    /// Hz.
    f_fundamental: f64,
    n_harmonics: u16 = 9,
    output_node: u32 = 0,
    /// Transient window to analyze. Null means 5 fundamental periods at
    /// 200 points per period.
    tran_opts: ?Tran = null,

    /// Size of the fixed harmonic table the extractor returns by value.
    pub const max_harmonics = 64;
};

pub const Disto = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    /// Branch row of the V card carrying `DISTOF1`, where ngspice puts a
    /// voltage source's F1 drive (cktdisto.c:115). A node row would be
    /// pinned by the source's own branch equation and give V1(out) = 0.
    /// GROUND selects the current-source form below.
    drive_branch: u32 = 0,
    /// Current-source form (ngspice cktdisto.c:151-158): the drive is a
    /// current into this row, which takes -0.5·mag. GROUND means the drive
    /// source (`Deck.source_branch`).
    ac_source_node: u32 = 0,
    /// `DISTOF1 <mag> [<phase deg>]` off the card (ngspice vsrcpar.c:180-193).
    ac_magnitude: f64 = 1.0,
    ac_phase: f64 = 0.0,
    /// Row the summary plot measures. The frontend passes
    /// `Deck.output_node`, since the card names none.
    output_node: u32,
    fd_eps: f64 = 1e-6,
    /// Which of the card's three plots this query publishes. The frontend
    /// fans one `.disto` card out into all three.
    plot: Plot = .summary,

    /// `second` and `third` are the harmonic solution vectors ngspice
    /// prints; `summary` is a 4-column digest at one node.
    pub const Plot = enum(u8) { summary, second, third };
};

/// Tag of `Query`: one per analysis.
pub const Kind = enum(u8) {
    ac,
    dc,
    dcmatch,
    disto,
    envelope,
    four,
    hb,
    matex,
    mc,
    noise,
    op,
    pac,
    pnoise,
    pss,
    pxf,
    pz,
    qpss,
    sens,
    sp,
    stb,
    temp,
    tf,
    tran,
    tran_noise,
    // Appended after the alphabetical block: the tag values are the C ABI
    // (include/espice.h).
    hbac,
    hbnoise,
    hbxf,
    phasenoise,

    /// Runs off a transient operating point (ngspice MODETRANOP) and starts
    /// its devices in `.ic` rather than `.dc` state.
    pub fn transient(kind: Kind) bool {
        return switch (kind) {
            .tran, .four, .tran_noise, .envelope, .pss, .qpss, .pnoise, .pac, .pxf => true,
            else => false,
        };
    }
};

/// One resolved analysis request.
pub const Query = union(Kind) {
    ac: Ac,
    dc: Dc,
    dcmatch: Dcmatch,
    disto: Disto,
    envelope: Envelope,
    four: Four,
    hb: Hb,
    matex: Matex,
    mc: Mc,
    noise: Noise,
    op: Op,
    pac: Pac,
    pnoise: Pnoise,
    pss: Pss,
    pxf: Pac,
    pz: Pz,
    qpss: Qpss,
    sens: Sens,
    sp: Sp,
    stb: Stb,
    temp: Temp,
    tf: Tf,
    tran: Tran,
    tran_noise: TranNoise,
    hbac: HbLptv,
    hbnoise: HbLptv,
    hbxf: HbLptv,
    phasenoise: PhaseNoise,
};
