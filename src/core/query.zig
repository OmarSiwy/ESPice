//! Resolved query descriptions: the contract between the frontend, which
//! fills them from analysis cards (keywords in frontend/netlist.zig `cards`),
//! and the analysis drivers. Node and branch fields are MNA rows.
const std = @import("std");
const Tolerances = @import("numerics.zig").Tolerances;
const DeviceType = @import("root.zig").DeviceType;
const GROUND = @import("root.zig").GROUND;

/// Dense id of a query within one session.
pub const QueryId = enum(u32) { _ };
/// Sentinel `QueryId` that names no query.
pub const invalid_query: QueryId = @fromBackingInt(@intCast(std.math.maxInt(u32)));
/// Transient integration method.
pub const Method = enum { backward_euler, trapezoidal, gear_2 };
/// Re-exported so a query reads its sweep type from one place.
pub const FreqSweep = @import("numerics.zig").FreqSweep;
pub const SweepKind = @import("numerics.zig").SweepKind;

/// One `.sp` port: the node rows and branch row of its source and its
/// reference impedance in ohms. The port voltage is v(node) - v(neg).
pub const Port = struct {
    node: u32,
    branch: u32,
    z0: f64 = 50.0,
    neg: u32 = 0,
    /// The band `.hblin` reads this port in (an HSPICE P card's
    /// `hblin=[harmonic, sign]`): sign·f + harmonic·f0 for input frequency f.
    band: Band = .{},
    /// z0 is already a resistor in the circuit, in series between `node`
    /// and the source (an HSPICE P card), so the port analyses must not
    /// terminate the branch again. False for ngspice's ideal portnum source.
    series_z0: bool = false,
    /// A mixed-mode (balanced) P card's − leg, against the same `neg`
    /// reference and z0; `node`/`branch` are then its + leg. Null for a
    /// single-ended port.
    balanced: ?Leg = null,

    /// Node and branch row of one leg of a balanced port.
    pub const Leg = struct { node: u32, branch: u32 };

    /// `branch` of a port with no source branch, which `.net` drives with
    /// a current into `node`.
    pub const no_branch = std.math.maxInt(u32);

    /// `sign` is +1 or -1; the default reads the port at the input frequency.
    pub const Band = struct { harmonic: i16 = 0, sign: i8 = 1 };
};

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

/// Small-signal sweep about the operating point (`.ac`).
pub const Ac = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
};

/// Small-signal noise at one output over a sweep (`.noise`, HSPICE
/// `.acphasenoise`).
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
    /// The (n+, n-) rows of a current-source input, which drives current
    /// from n+ to n- through itself; set instead of `in_branch`.
    in_nodes: ?[2]u32 = null,
    /// Emit integrated device noise in V rms instead of the measured PSD.
    integrated: bool = false,
    /// Publish each device instance's contribution, per generator name and
    /// in total, ahead of the totals (ngspice `.noise ... pts`, HSPICE
    /// `.noise ... inter`).
    contributions: bool = false,
    /// Card names for the contribution columns. Empty falls back to
    /// `<type>#<ordinal>`.
    cards: []const CardRef = &.{},
    /// HSPICE `.sample`: also publish the output noise folded by a sampler
    /// (`onoise_sampled`); spectrum queries only.
    sample: ?NoiseSample = null,
    /// HSPICE `.acphasenoise`: the output is a phase in radians, published
    /// as phase noise `phnoise` in dBc/Hz instead of the noise curves.
    phase: bool = false,
};

/// HSPICE `.sample FS= [MAXFLD=] [BETA=]` [CR .SAMPLE]: noise sampled at
/// `fs` Hz folds every band up to `max_fold * fs` into [0, fs/2], after an
/// integrator over `beta / fs` seconds (none when `beta` is 0).
pub const NoiseSample = struct {
    fs: f64,
    max_fold: f64 = 10,
    beta: f64 = 1,
};

/// S-parameters between ports over a sweep (`.sp`, HSPICE `.lin`, `.net`).
pub const Sp = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    /// Explicit port list. Empty means one port at the deck's drive source
    /// (`Deck.source_node`/`source_branch`).
    ports: []const Port = &.{},
    /// HSPICE `.lin` network parameters after S; null is the plain `.sp`
    /// S matrix.
    lin: ?Lin = null,
    /// HSPICE `.net`: the ports are ideal (a V card's port is a short, any
    /// other an open) and driven as such, and S comes from the measured
    /// Z against each port's z0 (RIN, ROUT). `lin` is set, without group
    /// delay or noise.
    net: bool = false,

    /// What `.lin` adds to the S matrix: Y and Z always, H for two or more
    /// ports (from the port 1-2 block), then the optional group delays and
    /// two-port noise parameters.
    pub const Lin = struct {
        /// `gdcalc=1`: the group delay of every S, Y, Z and H entry.
        group_delay: bool = false,
        /// `noisecalc=1`: NFMIN, NF, RN, YOPT and GAMMA_OPT between ports
        /// 1 and 2, the others terminated in their z0.
        noise: bool = false,
        /// `format=touchstone`: the facade also writes the result as a
        /// Touchstone file, `<file>.s<N>p` beside the deck.
        touchstone: bool = false,
        /// `filename=`; empty is the deck's file name without extension.
        file: []const u8 = "",
        /// `mixedmode2port=`: whether port 1's and port 2's mode in the
        /// two-port measurements (H, stability, noise) is its common mode
        /// (`c`) rather than its first one (`s` or `d`).
        common: [2]bool = .{ false, false },
    };
};

/// Loop gain through the deck's 0 V probe source (`.stb`).
pub const Stb = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    /// The deck's own 0 V probe source (`.stb Vprobe ...`): its two node rows
    /// and its branch row. `probe_p` is the arriving (driven) side.
    probe_p: u32,
    probe_n: u32,
    probe_branch: u32,
};

/// Loop stability by double injection (`.lstb`, VACASK `acstb`): a current
/// and a voltage injection at the probe, combined into the loop gain, the
/// forward and reverse gains and the DUT y-parameters.
pub const Lstb = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    mode: Mode = .single,
    /// The 0 V probe sources, HSPICE's orientation: `+` faces the loop's
    /// input (drv), `−` its output (fbk). `probes[1]` is read in `diff`
    /// and `comm` modes only.
    probes: [2]Probe,
    /// Publish the one-row margins plot instead of the sweep.
    margins: bool = false,
    /// VACASK's `localgnd`: the node the current injection returns to and
    /// the `+` node voltage is read against.
    local_gnd: u32 = GROUND,

    /// Node rows and branch row of one probe source.
    pub const Probe = struct { p: u32, n: u32, branch: u32 };
    /// Single-ended loop, or the differential (+1/−1) or common-mode
    /// (+1/+1) loop through a pair of probes.
    pub const Mode = enum(u8) { single, diff, comm };
};

/// One independent source of an all-source transfer (`.dcxf`, `.acxf`).
pub const XfSource = struct {
    /// Card name, for the result's column labels.
    name: []const u8,
    /// V card: its branch row. Null for an I card, whose unit current
    /// flows from `nodes[0]` through the card into `nodes[1]`.
    branch: ?u32,
    nodes: [2]u32 = .{ 0, 0 },
};

/// DC transfer from every independent source to one output (`.dcxf`).
pub const Dcxf = struct {
    tol: Tolerances = .{},
    /// Output row; unused when `output_branch` is set.
    output_node: u32,
    /// `v(a,b)` reference node; GROUND is single-ended.
    output_neg: u32 = 0,
    /// `i(Vmeasure)` output: that source's branch current.
    output_branch: ?u32 = null,
    sources: []const XfSource,
    /// Transfer functions only, from one adjoint solve; otherwise one
    /// forward solve per source also gives its input impedance.
    tf_only: bool = false,
};

/// `Dcxf` over a frequency sweep (`.acxf`).
pub const Acxf = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    output_node: u32,
    output_neg: u32 = 0,
    output_branch: ?u32 = null,
    sources: []const XfSource,
    tf_only: bool = false,
};

/// Incremental DC response to every source's AC magnitude (`.dcinc`).
pub const Dcinc = struct {
    tol: Tolerances = .{},
};

/// The DC operating point (`.op`), which most other analyses also run first.
pub const Op = struct {
    tol: Tolerances = .{},
    warm_start: bool = false,
    /// This operating point starts a transient (ngspice MODETRANOP), so
    /// waveform sources evaluate at t = 0 instead of at their DC value. The
    /// engine sets it when the deck has a transient-family query.
    tran_op: bool = false,
};

/// DC sweep of a source, a card parameter or the temperature (`.dc`), one
/// or two levels deep.
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
    /// HSPICE `LIN`/`DEC`/`OCT`/`POI` grids as explicit values. Non-empty
    /// replaces `start`/`stop`/`step` (`points2` the outer ones).
    points: []const f64 = &.{},
    points2: []const f64 = &.{},

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

    /// True for a two-level sweep, whose outer level is `target2`.
    pub fn hasOuter(self: Dc) bool {
        return self.target2 != null;
    }
};

/// DC small-signal transfer function, input and output resistance (`.tf`).
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

/// Parameter variations a mismatch or sensitivity analysis sums over, from
/// the deck's `.variation` block and `DEV`/`LOT` specs. Group g moves
/// `params[starts[g]..starts[g + 1]]` (ordinals in `Circuit.collectParams`
/// order) together, each by its own one-sigma step in `sigmas`: a
/// per-device row is one group per device, a per-model row one group over
/// every device of the model. Empty: every parameter alone at its Pelgrom
/// sigma.
pub const Variations = struct {
    /// Per group: `<card>@<param>` or `<model>@<param>`.
    labels: []const []const u8 = &.{},
    starts: []const u32 = &.{},
    params: []const u32 = &.{},
    sigmas: []const f64 = &.{},
};

/// 1-sigma spread of a DC output from device mismatch (`.dcmatch`).
pub const Dcmatch = struct {
    tol: Tolerances = .{},
    output_node: u32,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    variations: Variations = .{},
};

/// HSPICE `.acmatch`: the 1-sigma spread of an AC output over the `.ac`
/// sweep from the same variations as `Dcmatch`.
pub const Acmatch = struct {
    tol: Tolerances = .{},
    sweep: FreqSweep,
    output_node: u32,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    variations: Variations = .{},
};

/// HSPICE `.dcsens`: the DC output's change per one-sigma step of each
/// variation group.
pub const Dcsens = struct {
    tol: Tolerances = .{},
    output_node: u32,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    variations: Variations = .{},
};

/// Periodic steady state by shooting (`.pss`; autonomous with `osc_node`).
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

/// Periodic or quasi-periodic steady state by harmonic balance (`.hb`;
/// autonomous `.hbosc` with `osc_node`).
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
    /// Tones after `f0`, HSPICE `.hb TONES=f0 f1 ...` [CR .HB]; empty for
    /// one tone. Driven only.
    extra_tones: []const f64 = &.{},
    /// Harmonics kept of each of `extra_tones`, parallel to it (`n_harmonics` is
    /// f0's).
    extra_harmonics: []const u16 = &.{},
    /// HSPICE INTMODMAX: the largest |k_0| + |k_1| + ... a kept mixing
    /// product k_0·f0 + k_1·f1 + ... may have. A single tone's own
    /// harmonics are kept up to its count regardless, and every |k_i| stays
    /// within tone i's count. 0 keeps that whole box.
    intmodmax: u16 = 0,
    /// HSPICE SUBHARMS: `f0` is the card's lowest tone divided by this and
    /// `n_harmonics` its NHARMS times this, so every subharmonic step is a
    /// line. In the INTMODMAX order, `subharms` steps of f0 count as one.
    subharms: u16 = 1,
    /// Publish complex phasors X = c - j·s per line, x(t) = Re{X·e^(jωt)},
    /// instead of magnitudes: HSPICE's `.hb TONES=` form [CR .HB]. The
    /// positional `.hb f0 K` keeps magnitudes.
    phasors: bool = false,
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

/// Periodic noise about the shooting orbit (`.pnoise`, HSPICE `.ptdnoise`).
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
    /// HSPICE `.ptdnoise`: the noise density at this time of the period, in
    /// seconds, instead of the time average; see pnoise.zig `strobed`.
    strobe: ?f64 = null,
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
    /// The `.hb TONES=` card's other tones, as `Hb`'s fields. With any
    /// extra tone the sidebands are the HB spectrum's lines, both signs,
    /// and `n_sidebands` is unused.
    extra_tones: []const f64 = &.{},
    extra_harmonics: []const u16 = &.{},
    intmodmax: u16 = 0,
    subharms: u16 = 1,

    /// The `.hb` solve this analysis linearizes about.
    pub fn hb(self: HbLptv) Hb {
        return .{ .tol = self.tol, .f0 = self.f0, .n_harmonics = self.n_harmonics, .max_iter = self.max_iter, .hb_tol = self.hb_tol, .extra_tones = self.extra_tones, .extra_harmonics = self.extra_harmonics, .intmodmax = self.intmodmax, .subharms = self.subharms };
    }
};

/// HSPICE RF `.hblin`: frequency-translation S-parameters between the
/// deck's ports about the `.hb` orbit, each port read in its own band
/// (`Port.band`).
pub const Hblin = struct {
    tol: Tolerances = .{},
    /// HB fundamental, in Hz; 0 until the deck's `.hb` card fills it.
    f0: f64,
    n_harmonics: u16 = 8,
    /// Sidebands kept on each side of the carrier; every port's band
    /// harmonic must lie within them.
    n_sidebands: u16 = 8,
    /// Input (small-signal tone) frequency sweep.
    sweep: FreqSweep,
    max_iter: u16 = 200,
    hb_tol: f64 = 1e-9,
    ports: []const Port,
    /// `noisecalc=1`: append the port 1 to port 2 noise figure (two or
    /// more ports).
    noise: bool = false,

    /// The HB-orbit small-signal options the orbit and linearization take.
    pub fn lptv(self: Hblin) HbLptv {
        return .{ .tol = self.tol, .f0 = self.f0, .n_harmonics = self.n_harmonics, .n_sidebands = self.n_sidebands, .out_node = 0, .sweep = self.sweep, .max_iter = self.max_iter, .hb_tol = self.hb_tol };
    }
};

/// Oscillator phase noise (`.phasenoise`) about the autonomous HB solution.
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
    method: Algorithm = .nlp,
    /// HSPICE CARRIERINDEX: the harmonic, 1..n_harmonics, whose phase noise
    /// is reported.
    carrier: u16 = 1,

    /// HSPICE METHOD=0|1|2 [RF Ch.7].
    pub const Algorithm = enum(u2) {
        /// The perturbation projection vector projects every source onto
        /// the phase (Demir's method).
        nlp,
        /// Periodic noise at the carrier sideband over the carrier power:
        /// phase and amplitude noise.
        pac,
        /// `nlp` close in, `pac` from where the two first agree.
        bpn,
    };

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

/// Transient analysis (`.tran`, HSPICE `.op <time>`).
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
    /// ngspice `.options xmu`: the trapezoidal weight on the previous step's
    /// derivative (nicomcof.c). 0.5 is the plain trapezoid; below it each
    /// step damps the trapezoid's undamped ringing by xmu/(1 - xmu), down to
    /// backward Euler at 0. Range [0, 0.5].
    xmu: f64 = 0.5,
    /// Runaway guard only; `dt_min` is the real brake. A 1 s run on a 1 us
    /// grid is already 1e6 accepted points.
    max_steps: u32 = 1_000_000_000,
    /// `.tran ... uic`: no operating point runs; the starting state comes
    /// from the `.ic` cards (zero elsewhere), and the transient does the
    /// setup the operating point would have done.
    uic: bool = false,
    /// HSPICE `.op <time>`: publish only the state at `t_stop`, as an
    /// operating-point plot named for that time.
    snapshot: bool = false,
};

/// Transient noise: a transient with sampled noise sources, or the noise
/// covariance carried alongside it (`.trannoise`).
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
    /// Multiplies every source's PSD (HSPICE `SCALE`).
    scale: f64 = 1,
    /// Hz; the lowest flicker-noise frequency, 1/t_stop when null (HSPICE
    /// `FMIN`). The highest is the sampling bandwidth 1/(2 dt_max).
    f_min: ?f64 = null,
    /// HSPICE Monte Carlo index of one run of a `SAMPLES>1` card, named in
    /// the plot; 0 for a lone run.
    sample: u32 = 0,
    /// HSPICE `METHOD=SDE`: no sampled noise; the noiseless march carries
    /// the noise covariance and publishes `onoise`, the rms noise of
    /// v(out_node, out_neg).
    sde: bool = false,
    out_node: u32 = 0,
    out_neg: u32 = 0,
    /// Seconds; HSPICE `TIME=`, a time the march lands on exactly.
    t_break: ?f64 = null,
};

/// Envelope-following transient: carrier periods integrated in full, the
/// envelope stepped across them (`.envelope`).
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
    /// Rows `first..first + count` of `Deck.variants` to solve instead of
    /// perturbing primary values (`.dc DATA=`, `.dc MONTE=`): one lane
    /// each, warm-started from the lane before.
    variants: VariantRange = .{},
    /// First column of a variant ensemble; `axis_values` fills it.
    axis: []const u8 = "run",
    /// Publish a variant ensemble as a DC sweep rather than Monte Carlo.
    dc_plot: bool = false,

    /// Rows `first..first + count` of `Deck.variants`; none when `count` is 0.
    pub const VariantRange = struct { first: u32 = 0, count: u32 = 0 };
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

/// DC sensitivity of one output to every device parameter (`.sens`).
pub const Sens = struct {
    tol: Tolerances = .{},
    output_node: u32,
    /// `v(a,b)` reference node for the output; GROUND is single-ended.
    output_neg: u32 = 0,
    /// Card names for the result columns, so they match ngspice's. Empty
    /// falls back to `<type>#<ordinal>`.
    cards: []const CardRef = &.{},
};

/// Poles and zeros of the linearized circuit (`.pz`).
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

    /// Which roots the card asks for.
    pub const Want = enum(u2) { poles, zeros, both };
};

/// Fourier coefficients of one transient output (`.four`).
pub const Four = struct {
    tol: Tolerances = .{},
    /// Hz.
    f_fundamental: f64,
    n_harmonics: u16 = 9,
    output_node: u32 = 0,
    /// Transient window to analyze. Null means 5 fundamental periods at
    /// 200 points per period.
    tran_opts: ?Tran = null,
    /// The output as written (`v(b)`) when the card named several: it goes
    /// into the plot name so the plots stay apart. Empty for one output.
    label: []const u8 = "",

    /// Size of the fixed harmonic table the extractor returns by value.
    pub const max_harmonics = 64;
};

/// Small-signal distortion at one or two drive frequencies (`.disto`).
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
    /// The card's `f2overf1`: F2 = f2_ratio·f_start, held for the whole
    /// sweep as ngspice does (distoan.c:143). 0 means one tone.
    f2_ratio: f64 = 0,
    /// Branch row of the V card carrying `DISTOF2`, the F2 drive, and its
    /// `<mag> [<phase deg>]` (ngspice cktdisto.c:107-117).
    drive2_branch: u32 = 0,
    ac2_magnitude: f64 = 1.0,
    ac2_phase: f64 = 0.0,
    /// Which of the card's plots this query publishes. The frontend fans
    /// one `.disto` card out into all of them.
    plot: Plot = .summary,

    /// `second` and `third` are the harmonic solution vectors ngspice
    /// prints for one tone; with F2, ngspice prints the intermodulation
    /// vectors at f1+f2, f1-f2 and 2f1-f2 instead. `summary` is a 4-column
    /// digest at one node.
    pub const Plot = enum(u8) { summary, second, third, f1pf2, f1mf2, twof1mf2 };
};

/// HSPICE `.fft` [CR .FFT]: the windowed spectrum of one transient output.
pub const Fft = struct {
    tol: Tolerances = .{},
    /// The deck's transient, run to at least `stop`.
    tran: Tran,
    out_pos: u32,
    /// `v(a,b)` reference; GROUND is single-ended.
    out_neg: u32 = 0,
    /// Window on the waveform, seconds.
    start: f64,
    stop: f64,
    /// Uniform samples in [start, stop); a power of two.
    np: u32 = 1024,
    window: Window = .rect,
    /// GAUSS and KAISER shape parameter.
    alfa: f64 = 3,
    /// FORMAT=NORM: magnitudes relative to the largest non-DC bin.
    normalized: bool = true,
    /// The output as written, which names the plot (`v(out)`).
    label: []const u8,

    /// HSPICE's eight windows, named as the card spells them [SA Ch.15 Table 56].
    pub const Window = enum(u8) { rect, bart, hann, hamm, black, harris, gauss, kaiser };
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
    lstb,
    acxf,
    dcxf,
    dcinc,
    fft,
    acmatch,
    dcsens,
    hblin,

    /// Runs off a transient operating point (ngspice MODETRANOP) and starts
    /// its devices in `.ic` rather than `.dc` state.
    pub fn transient(kind: Kind) bool {
        return switch (kind) {
            .tran, .four, .fft, .tran_noise, .envelope, .pss, .qpss, .pnoise, .pac, .pxf => true,
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
    lstb: Lstb,
    acxf: Acxf,
    dcxf: Dcxf,
    dcinc: Dcinc,
    fft: Fft,
    acmatch: Acmatch,
    dcsens: Dcsens,
    hblin: Hblin,
};

test "CardRef.lookup keys on type and index together" {
    const t = std.testing;
    const r: DeviceType = @fromBackingInt(0);
    const c: DeviceType = @fromBackingInt(1);
    const cards = [_]CardRef{ .{ .type = r, .index = 0, .name = "r1" }, .{ .type = c, .index = 0, .name = "c1" } };
    try t.expectEqualStrings("c1", CardRef.lookup(&cards, c, 0).?);
    try t.expectEqualStrings("r1", CardRef.lookup(&cards, r, 0).?);
    try t.expectEqual(null, CardRef.lookup(&cards, r, 1));
    try t.expectEqual(null, CardRef.lookup(&.{}, r, 0));
}

test "the HB-orbit views carry the fields their solve reads" {
    const t = std.testing;
    const tones = [_]f64{1.1e9};
    const harmonics = [_]u16{2};
    const sweep: FreqSweep = .{ .f_start = 1, .f_stop = 10 };
    const l: HbLptv = .{ .tol = .{ .reltol = 1e-4 }, .f0 = 1e9, .n_harmonics = 5, .out_node = 3, .sweep = sweep, .max_iter = 7, .hb_tol = 1e-6, .extra_tones = &tones, .extra_harmonics = &harmonics, .intmodmax = 4, .subharms = 2 };
    const h = l.hb();
    try t.expectEqual(@as(f64, 1e-4), h.tol.reltol);
    try t.expectEqual(@as(f64, 1e9), h.f0);
    try t.expectEqual(@as(u16, 5), h.n_harmonics);
    try t.expectEqual(@as(u16, 7), h.max_iter);
    try t.expectEqual(@as(f64, 1e-6), h.hb_tol);
    try t.expectEqual(@as(usize, 1), h.extra_tones.len);
    try t.expectEqual(@as(usize, 1), h.extra_harmonics.len);
    try t.expectEqual(@as(u16, 4), h.intmodmax);
    try t.expectEqual(@as(u16, 2), h.subharms);
    try t.expectEqual(GROUND, h.osc_node);
    const lin: Hblin = .{ .tol = .{ .reltol = 1e-5 }, .f0 = 2e9, .n_harmonics = 6, .n_sidebands = 3, .sweep = sweep, .max_iter = 9, .hb_tol = 1e-7, .ports = &.{} };
    const lp = lin.lptv();
    try t.expectEqual(@as(f64, 1e-5), lp.tol.reltol);
    try t.expectEqual(@as(f64, 2e9), lp.f0);
    try t.expectEqual(@as(u16, 6), lp.n_harmonics);
    try t.expectEqual(@as(u16, 3), lp.n_sidebands);
    try t.expectEqual(@as(u16, 9), lp.max_iter);
    try t.expectEqual(@as(f64, 1e-7), lp.hb_tol);
    const pn: PhaseNoise = .{ .f0 = 5e6, .osc_node = 4, .sweep = sweep, .n_harmonics = 3 };
    try t.expectEqual(@as(u32, 4), pn.hb().osc_node);
    try t.expectEqual(@as(u16, 3), pn.hb().n_harmonics);
}
