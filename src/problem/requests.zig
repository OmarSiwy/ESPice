//! Resolved query descriptions. No parser, driver, or solver imports.
const std = @import("std");
const Tolerances = @import("numerics").Tolerances;
const ir = @import("device_ir");
pub const QueryId = enum(u32) { _ };
pub const invalid_query: QueryId = @enumFromInt(std.math.maxInt(u32));
pub const Method = enum { backward_euler, trapezoidal, gear_2 };
pub const FreqSweep = @import("numerics").FreqSweep;
pub const SweepKind = @import("numerics").SweepKind;
pub const Port = struct { node: u32, branch: u32, z0: f64 = 50.0 };
pub const CardRef = struct {
    type_name: []const u8,
    index: u32,
    name: []const u8,
    pub fn lookup(cards: []const CardRef, ref: ir.ParamRef) ?[]const u8 {
        for (cards) |c| if (c.index == ref.index and std.mem.eql(u8, c.type_name, ref.device_type)) return c.name;
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
    /// `v(a,b)`: the measurement is v(out_node) − v(out_neg). GROUND is the
    /// single-ended case and costs nothing — the adjoint rhs is e_pos − e_neg
    /// and e_GROUND is not stamped.
    out_neg: u32 = 0,
    sweep: FreqSweep,
    /// MNA branch row of the `.noise v(out) SRC ...` input source. It does
    /// not drive the solve — it is what `inoise_spectrum` refers the measured
    /// noise back to. null emits the output-referred curve only.
    in_branch: ?u32 = null,
    /// Emit integrated device noise in V rms instead of the measured PSD.
    integrated: bool = false,
};

pub const Sp = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    /// Explicit port list. Empty means one port at the drive source
    /// (ctx.source_node / ctx.source_branch) when running via the contract.
    ports: []const Port = &.{},
};

pub const Stb = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    /// The deck's own 0 V probe source (`.stb Vprobe ...`): its two node rows
    /// and its MNA branch row. `probe_p` is the arriving (driven) side.
    probe_p: u32,
    probe_n: u32,
    probe_branch: u32,
};

pub const Op = struct {
    tol: Tolerances = .{},
    warm_start: bool = false,
    /// ngspice's TRANOP/DCOP split: the operating point that STARTS a
    /// transient runs in the LRM "ic" phase (analysis("tran") also true),
    /// so waveform sources evaluate at t = 0 instead of their DC value.
    /// The engine sets this when the deck contains a transient-family job.
    tran_op: bool = false,
};

pub const Dc = struct {
    tol: Tolerances = .{},
    start: f64 = 0,
    stop: f64 = 0,
    step: f64 = 1,
    /// What the inner sweep drives. A bare batch-local index aliased a V card
    /// with an I card of the same ordinal — which is why a deck holding both
    /// had to be rejected outright — and could not name a resistor at all.
    /// The device type and parameter travel with the index instead.
    target: SweepTarget = .{},
    /// ngspice's optional second sweep variable — the OUTER loop
    /// (`.dc src1 ... src2 start2 stop2 incr2`), or `.dc ... temp ...`.
    target2: ?SweepTarget = null,
    start2: f64 = 0,
    stop2: f64 = 0,
    step2: f64 = 1,

    pub const SweepTarget = struct {
        /// Device type name as `ParamRef.device_type` spells it.
        type_name: []const u8 = "vsource",
        /// Batch-local instance index within that type.
        index: u32 = 0,
        param_name: []const u8 = "dc",
        /// `.dc ... temp ...` sweeps the circuit temperature; the three
        /// fields above are then unused.
        is_temp: bool = false,
    };

    pub fn hasOuter(self: Dc) bool {
        return self.target2 != null;
    }
};

pub const Tf = struct {
    tol: Tolerances = .{},
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    /// `.tf i(Vmeasure) ...`: the output is that source's BRANCH current, not
    /// a node voltage. Set ⇒ `output_node`/`output_neg` are unused.
    output_branch: ?u32 = null,
    /// `.tf v(out) Iin`: the input is a current source, which has no branch
    /// row — the excitation is a unit current into its node pair instead.
    /// Set ⇒ `input_branch` is unused.
    input_nodes: ?[2]u32 = null,
    /// Branch-current unknown of the input vsource (its row is v_p - v_n - V = 0).
    /// null -> ctx.source_branch (the first source's branch).
    input_branch: ?u32 = null,
    /// null -> the last probe node.
    output_node: ?u32 = null,
};

pub const Dcmatch = struct {
    tol: Tolerances = .{},
    /// null -> the last probe node.
    output_node: ?u32 = null,
};

pub const Pss = struct {
    tol: Tolerances = .{},
    period: f64,
    max_shooting_iter: u16 = 50,
    shooting_tol: f64 = 1e-7,
    fd_epsilon: f64 = 1e-7,
    max_newton_iter: u16 = 50,
    newton_tol: f64 = 1e-9,
    /// Fixed trapezoidal steps per period; the waveform has n_samples+1 rows.
    n_samples: u32 = 256,
    /// GMRES restart depth for Krylov path (n >= krylov_threshold).
    gmres_restart: u32 = 30,
    /// Maximum GMRES outer restarts.
    gmres_max_restarts: u32 = 10,
    /// GMRES relative tolerance for the inner linear solve.
    gmres_tol: f64 = 1e-3,
};

pub const Hb = struct {
    tol: Tolerances = .{},
    f0: f64,
    n_harmonics: u16 = 8,
    max_iter: u16 = 200,
    hb_tol: f64 = 1e-9,
};

pub const Pac = struct {
    tol: Tolerances = .{},
    /// LO (pump) frequency — the fundamental periodicity.
    f_lo: f64,
    /// Number of LO harmonics to include: sidebands span [-n_harmonics..+n_harmonics].
    n_harmonics: u16 = 3,
    /// Input frequency sweep.
    sweep: FreqSweep,
    /// Number of time samples per LO period (must be power of 2, >= 2*(2*n_harmonics+1)).
    n_time_samples: u16 = 64,
    /// PSS shooting parameters.
    pss_periods: u16 = 20,
    pss_newton_tol: f64 = 1e-9,
    pss_max_newton_iter: u16 = 50,
};

pub const Pnoise = struct {
    tol: Tolerances = .{},
    out_node: u32,
    sweep: FreqSweep,
    f_fundamental: f64,
    pss_n_samples: u32 = 64,
    pss_shoot_tol: f64 = 1e-6,
    pss_shoot_max_iter: u16 = 50,
    pss_newton_max_iter: u16 = 50,
    pss_newton_tol: f64 = 1e-9,
    n_sidebands: u16 = 7,
};

pub const Qpss = struct {
    tol: Tolerances = .{},
    f1: f64,
    f2: f64,
    k1: u16 = 5,
    k2: u16 = 5,
    max_newton: u16 = 50,
    hb_tol: f64 = 1e-9,
    /// GMRES restart depth (per Newton step)
    gmres_restart: u16 = 30,
    /// Max GMRES restarts per Newton step
    gmres_max_restarts: u16 = 10,
    /// GMRES relative tolerance
    gmres_tol: f64 = 1e-3,
    /// Source excitation magnitude (cosine current at f1 into source_node)
    source_mag: f64 = 1.0,
};

pub const Tran = struct {
    tol: Tolerances = .{},
    t_stop: f64,
    dt_init: f64 = 1e-9,
    dt_min: f64 = 1e-18,
    /// ngspice tstart: OUTPUT suppression only. The integration still starts
    /// at t = 0 with the same history, so a deck that relies on settling
    /// before the printed window keeps it; only the recorded points before
    /// `t_start` are dropped. The driver lands one step exactly on it so the
    /// first printed point is at `t_start`, as ngspice's breakpoint does.
    t_start: f64 = 0,
    /// ngspice tmax: default is t_stop/50; an explicit value replaces it.
    dt_max: ?f64 = null,
    method: Method = .trapezoidal,
    // Runaway guard only — a healthy 1 us-grid second is 1e6 accepted points
    // (vacask/rc hit the old 1e6 wall at t = 0.994 s and reported
    // TimestepTooSmall on a perfectly marching transient). dt_min is the
    // real brake; this only stops a stuck loop.
    max_steps: u32 = 1_000_000_000,
    /// `.tran ... uic`: no operating point ran, so the starting `x` came from
    /// the `.ic` cards (zero elsewhere) rather than from `op.solve`. The
    /// transient then owes the setup op.solve normally performs — the
    /// `initial_step` latch and the static state the charge seeding reads.
    uic: bool = false,
    /// Invoked after each accepted step (envelope/pnoise/pac build on this).
    step_fn: ?*const fn (ctx: ?*anyopaque, t: f64, x: []const f64) void = null,
    step_ctx: ?*anyopaque = null,
};

pub const TranNoise = struct {
    tol: Tolerances = .{},
    t_stop: f64,
    dt_init: f64 = 1e-9,
    dt_min: f64 = 1e-18,
    dt_max: f64 = 1e-3,
    // Runaway guard only — a healthy 1 us-grid second is 1e6 accepted points
    // (vacask/rc hit the old 1e6 wall at t = 0.994 s and reported
    // TimestepTooSmall on a perfectly marching transient). dt_min is the
    // real brake; this only stops a stuck loop.
    max_steps: u32 = 1_000_000_000,
    seed: u64 = 0xDEAD_BEEF_CAFE_1234,
};

pub const Envelope = struct {
    tol: Tolerances = .{},
    /// Carrier period (1 / f_carrier).
    t_carrier: f64,
    /// Total simulation time (covers the full modulation envelope).
    t_stop: f64,
    carrier_steps_per_period: u32 = 64,
    /// Number of carrier periods per outer envelope step. 1 = sample every period.
    periods_per_outer_step: u32 = 1,
    /// Maximum total outer (envelope) steps before giving up.
    max_outer_steps: u32 = 1_000_000,
    /// Envelope rate-of-change tolerance for adaptive outer stepping.
    /// If the relative change in envelope between two outer steps exceeds this,
    /// the outer step is halved.
    envelope_reltol: f64 = 0.05,
    /// Minimum outer step expressed as a multiple of T_carrier.
    min_periods_per_step: u32 = 1,
    /// Maximum outer step expressed as a multiple of T_carrier.
    max_periods_per_step: u32 = 16,
};

pub const Matex = struct {
    tol: Tolerances = .{},
    t_stop: f64,
    /// Krylov posterior tolerance (role of reltol on the exponential).
    krylov_tol: f64 = 1e-10,
    /// Maximum Krylov subspace dimension before declaring failure.
    m_max: u32 = 80,
    /// R-MATEX shift parameter γ — order of intended timestep, insensitive.
    gamma: ?f64 = null,
    /// Output resolution cap — maximum h between recorded points.
    h_output_cap: ?f64 = null,
    /// Maximum recorded points (controls initial waveform allocation).
    max_points: u32 = 1 << 22,
};

pub const Mc = struct {
    tol: Tolerances = .{},
    n_trials: u16 = 100,
    /// Seed for the PRNG (deterministic).
    seed: u64 = 42,
    /// Relative tolerance applied to every primary instance value in run().
    variation: f64 = 0.05,
    /// DC solver options forwarded to each trial's solve.
    dc_options: Dc = .{},
};

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
    /// null → the last probe node.
    output_node: ?u32 = null,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    /// Instance-ordinal → card name, so a column can name the card ngspice
    /// names. Empty falls back to `<type>#<ordinal>`, which is what every
    /// column read like before this table existed.
    cards: []const CardRef = &.{},
};

pub const Pz = struct {
    tol: Tolerances = .{},
    qr_max_iter: u32 = 1000,
    qr_tol: f64 = 1e-12,
    /// `.pz in+ in− out+ out− vol|cur pol|zer|pz`. The output side of the
    /// transfer, as MNA rows. A bare `.pz` leaves both at GROUND and asks for
    /// the circuit's own poles, which is all a deck written before the ports
    /// existed ever meant.
    out_pos: u32 = 0,
    out_neg: u32 = 0,
    /// Where the input drive enters the matrix. `vol` drives a voltage source,
    /// so the column is that card's BRANCH row; GROUND selects the `cur` form
    /// below, a current injected at the input node pair. Same convention as
    /// `Disto.drive_branch`.
    drive_branch: u32 = 0,
    in_pos: u32 = 0,
    in_neg: u32 = 0,
    /// `pol` asks for poles, `zer` for zeros, `pz` for both.
    want_poles: bool = true,
    want_zeros: bool = false,
};

pub const Four = struct {
    tol: Tolerances = .{},
    f_fundamental: f64,
    n_harmonics: u16 = 9,
    output_node: u32 = 0,
    /// Transient window to analyze; defaults to 5 fundamental periods at
    /// 200 points/period (the old engine reused a queued .tran here).
    tran_opts: ?Tran = null,

    /// Size of the harmonic table the extractor carries. A `Spectrum` is
    /// returned by value, so the table is fixed and this is its ceiling.
    pub const max_harmonics = 64;
};

pub const Disto = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    /// MNA BRANCH row of the V card carrying `DISTOF1`. ngspice cktdisto.c:115
    /// puts a voltage source's F1 drive there and nowhere else; a NODE row is
    /// wrong, because that node is pinned by the source's own branch equation
    /// and the first-order solve comes back with V1(out) = 0 — which is what
    /// left hd2/v1_mag/v2_mag identically zero on every `.disto` deck.
    /// GROUND selects the current-source form below.
    drive_branch: u32 = 0,
    /// Current-source form, ngspice cktdisto.c:151-158: the drive is a current
    /// INTO `ac_source_node`, so that row takes −0.5·mag. GROUND means "the
    /// drive source branch" (ctx.source_branch) when running via the contract.
    ac_source_node: u32 = 0,
    /// `DISTOF1 <mag> [<phase deg>]` off the card (ngspice vsrcpar.c:180-193).
    ac_magnitude: f64 = 1.0,
    ac_phase: f64 = 0.0,
    /// Output node; GROUND means "the last probe" when running via the contract.
    output_node: u32 = 0,
    fd_eps: f64 = 1e-6,
    /// Which of the card's three plots this query publishes. ngspice prints
    /// the two harmonic SOLUTION VECTORS; `summary` is espice's own 4-column
    /// digest at one node. prepare.zig fans one `.disto` card out into all
    /// three, the way it already fans `.noise` out into two.
    plot: Plot = .summary,

    pub const Plot = enum(u8) { summary, second, third };
};
pub const Kind = enum(u8) { ac, dc, dcmatch, disto, envelope, four, hb, matex, mc, noise, op, pac, pnoise, pss, pxf, pz, qpss, sens, sp, stb, temp, tf, tran, tran_noise };
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
};

pub const Keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "ac", .ac },
    .{ "dc", .dc },
    .{ "dcmatch", .dcmatch },
    .{ "disto", .disto },
    .{ "envelope", .envelope },
    .{ "envlp", .envelope },
    .{ "four", .four },
    .{ "hb", .hb },
    .{ "matex", .matex },
    .{ "mc", .mc },
    .{ "montecarlo", .mc },
    .{ "noise", .noise },
    .{ "op", .op },
    .{ "pac", .pac },
    .{ "pnoise", .pnoise },
    .{ "pss", .pss },
    .{ "pxf", .pxf },
    .{ "pz", .pz },
    .{ "qpss", .qpss },
    .{ "sens", .sens },
    .{ "sp", .sp },
    .{ "stb", .stb },
    .{ "temp", .temp },
    .{ "tf", .tf },
    .{ "tran", .tran },
    .{ "trannoise", .tran_noise },
    .{ "tran_noise", .tran_noise },
});
