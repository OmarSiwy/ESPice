//! Source waveform types and evaluation.
//!
//! Each waveform variant corresponds to a standard SPICE source waveform.
//! Parameters are encoded in the device `ParamMap` using the convention:
//!
//! | Waveform kind  | `waveform_kind` | Param prefix    |
//! |---------------|-----------------|-----------------|
//! | DC            | 0 (or absent)   | `dc`            |
//! | PULSE         | 1               | `pulse_`        |
//! | SIN           | 2               | `sin_`          |
//! | PWL           | 3               | `pwl_`          |
//! | EXP           | 4               | `exp_`          |
//! | SFFM          | 5               | `sffm_`         |
//! | PWL FILE      | 6               | `pwlfile_path_` |
//! | AM            | 7               | `am_`           |
//! | TRNOISE       | 8               | `trnoise_`      |
//! | TRRANDOM      | 9               | `trrandom_`     |
//! | PWL REPEAT    | 10              | `pwl_` + `pwl_r`|
//!
//! The formulas follow SPICE3F5 / ngspice conventions exactly.

use incspice_core::ParamMap;

/// A source waveform — DC, PULSE, SIN, PWL, EXP, SFFM, AM, TRNOISE, TRRANDOM, or PWL REPEAT.
///
/// `Copy` is not derived because `Pwl` / `PwlRepeat` contain a `Vec`. All other variants
/// are `Clone + Copy`-equivalent on the values but the enum itself is `Clone` only.
#[derive(Debug, Clone)]
pub enum Waveform {
    /// Constant DC value.
    Dc(f64),

    /// Piecewise-rectangular pulse waveform.
    ///
    /// - `v1` — initial/off value
    /// - `v2` — on value
    /// - `td` — delay time (s); default 0
    /// - `tr` — rise time (s); default tstep
    /// - `tf` — fall time (s); default tstep
    /// - `pw` — pulse width (s); default tstop
    /// - `per` — period (s); default tstop
    Pulse {
        v1: f64,
        v2: f64,
        td: f64,
        tr: f64,
        tf: f64,
        pw: f64,
        per: f64,
    },

    /// Damped sinusoid.
    ///
    /// - `vo` — DC offset
    /// - `va` — amplitude
    /// - `freq` — frequency (Hz); default 1/tstop
    /// - `td` — delay (s); default 0
    /// - `theta` — damping factor (1/s); default 0
    Sin {
        vo: f64,
        va: f64,
        freq: f64,
        td: f64,
        theta: f64,
    },

    /// Piecewise-linear waveform.
    ///
    /// Pairs of `(time, value)` in ascending time order.
    /// Outside the defined range the waveform holds the nearest endpoint.
    Pwl(Vec<(f64, f64)>),

    /// Piecewise-linear waveform loaded from an external CSV file.
    ///
    /// The CSV must have two columns: time (s) and value, one row per point.
    /// Points are loaded lazily on first call to `evaluate_at`.
    PwlFile {
        /// Path to the CSV file (absolute or relative to the netlist directory).
        path: String,
    },

    /// Double-exponential transient waveform.
    ///
    /// - `v1` — initial value
    /// - `v2` — pulsed value
    /// - `td1` — rise delay (s); default 0
    /// - `tau1` — rise time constant (s); default tstep
    /// - `td2` — fall delay (s); default td1 + tstep
    /// - `tau2` — fall time constant (s); default tstep
    Exp {
        v1: f64,
        v2: f64,
        td1: f64,
        tau1: f64,
        td2: f64,
        tau2: f64,
    },

    /// Single-frequency FM waveform.
    ///
    /// - `vo` — DC offset
    /// - `va` — amplitude
    /// - `fc` — carrier frequency (Hz)
    /// - `mdi` — modulation index
    /// - `fs` — signal frequency (Hz)
    Sffm {
        vo: f64,
        va: f64,
        fc: f64,
        mdi: f64,
        fs: f64,
    },

    /// Amplitude-modulated waveform.
    ///
    /// `V(t) = (vo + va * sin(2π * fc * t)) * sin(2π * freq * t)`
    ///
    /// - `vo`   — DC offset (carrier offset)
    /// - `va`   — carrier amplitude
    /// - `fc`   — modulating frequency (Hz)
    /// - `freq` — carrier frequency (Hz)
    /// - `td`   — delay (s); default 0
    Am {
        vo: f64,
        va: f64,
        fc: f64,
        freq: f64,
        td: f64,
    },

    /// Transient noise source (white noise + optional 1/f component).
    ///
    /// - `na`     — white-noise RMS amplitude
    /// - `nt`     — internal time step for noise sampling (s)
    /// - `nalpha` — 1/f noise exponent (currently unused; reserved)
    /// - `namp`   — 1/f noise amplitude (currently unused; reserved)
    /// - `td`     — delay before noise starts (s); default 0
    ///
    /// White noise is generated with a deterministic xorshift64 seeded
    /// from the quantised time index, so repeated calls at the same `t`
    /// return the same value.
    Trnoise {
        na: f64,
        nt: f64,
        nalpha: f64,
        namp: f64,
        td: f64,
    },

    /// Random waveform — changes value every `tstep` seconds.
    ///
    /// - `kind`  — distribution: 1=Uniform, 2=Gaussian, 3=Exponential, 4=Poisson
    /// - `tstep` — time between value updates (s)
    /// - `td`    — start delay (s); default 0
    /// - `param` — distribution parameter (range/sigma/mean/lambda)
    /// - `mean`  — mean / offset added after sampling
    ///
    /// Values are generated deterministically from the step index using
    /// xorshift64; the same step always returns the same value.
    Trrandom {
        kind: u32,
        tstep: f64,
        td: f64,
        param: f64,
        mean: f64,
    },

    /// Piecewise-linear waveform with periodic repeat (R= flag).
    ///
    /// After the last defined point the waveform repeats.  The period is
    /// `last_time - repeat_offset`; at time `t` the effective time used
    /// for interpolation is `((t - repeat_offset) % period) + repeat_offset`.
    ///
    /// - `pts`           — `(time, value)` pairs in ascending order
    /// - `repeat_offset` — start of the repeating window (s)
    PwlRepeat {
        pts: Vec<(f64, f64)>,
        repeat_offset: f64,
    },
}

impl Waveform {
    /// Build a `Waveform` from a device parameter map.
    ///
    /// Dispatches on `waveform_kind`:
    /// - 0 (or missing) → `Dc`
    /// - 1 → `Pulse`
    /// - 2 → `Sin`
    /// - 3 → `Pwl`
    /// - 4 → `Exp`
    /// - 5 → `Sffm`
    pub fn from_params(params: &ParamMap) -> Self {
        let kind = params.get_or("waveform_kind", 0.0) as u32;
        match kind {
            1 => Self::Pulse {
                v1: params.get_or("pulse_v1", 0.0),
                v2: params.get_or("pulse_v2", 0.0),
                td: params.get_or("pulse_td", 0.0),
                tr: params.get_or("pulse_tr", 1e-12),
                tf: params.get_or("pulse_tf", 1e-12),
                pw: params.get_or("pulse_pw", f64::INFINITY),
                per: params.get_or("pulse_per", f64::INFINITY),
            },
            2 => Self::Sin {
                vo: params.get_or("sin_vo", 0.0),
                va: params.get_or("sin_va", 0.0),
                freq: params.get_or("sin_freq", 1.0),
                td: params.get_or("sin_td", 0.0),
                theta: params.get_or("sin_theta", 0.0),
            },
            3 => {
                // PWL points are stored as pwl_t0, pwl_v0, pwl_t1, pwl_v1, ...
                // The count is in pwl_count.
                let n = params.get_or("pwl_count", 0.0) as usize;
                let mut pts = Vec::with_capacity(n);
                for i in 0..n {
                    let t_key = format!("pwl_t{i}");
                    let v_key = format!("pwl_v{i}");
                    let t = params.get_or(&t_key, 0.0);
                    let v = params.get_or(&v_key, 0.0);
                    pts.push((t, v));
                }
                Self::Pwl(pts)
            }
            4 => Self::Exp {
                v1: params.get_or("exp_v1", 0.0),
                v2: params.get_or("exp_v2", 0.0),
                td1: params.get_or("exp_td1", 0.0),
                tau1: params.get_or("exp_tau1", 1e-12),
                td2: params.get_or("exp_td2", 1e-12),
                tau2: params.get_or("exp_tau2", 1e-12),
            },
            5 => Self::Sffm {
                vo: params.get_or("sffm_vo", 0.0),
                va: params.get_or("sffm_va", 0.0),
                fc: params.get_or("sffm_fc", 1.0),
                mdi: params.get_or("sffm_mdi", 0.0),
                fs: params.get_or("sffm_fs", 1.0),
            },
            6 => {
                // PWL FILE — path stored in a synthetic "pwlfile_path" param
                // by encoding the string as individual bytes.  The parser uses
                // `pwlfile_path_len` + `pwlfile_path_N` keys so the path survives
                // the f64 param map.  Reconstructed here.
                let len = params.get_or("pwlfile_path_len", 0.0) as usize;
                let path: String = (0..len)
                    .map(|i| {
                        let key = format!("pwlfile_path_{i}");
                        params.get_or(&key, 0.0) as u8 as char
                    })
                    .collect();
                Self::PwlFile { path }
            }
            7 => Self::Am {
                vo: params.get_or("am_vo", 0.0),
                va: params.get_or("am_va", 0.0),
                fc: params.get_or("am_fc", 1.0),
                freq: params.get_or("am_freq", 1.0),
                td: params.get_or("am_td", 0.0),
            },
            8 => Self::Trnoise {
                na: params.get_or("trnoise_na", 0.0),
                nt: params.get_or("trnoise_nt", 1e-9),
                nalpha: params.get_or("trnoise_nalpha", 0.0),
                namp: params.get_or("trnoise_namp", 0.0),
                td: params.get_or("trnoise_td", 0.0),
            },
            9 => Self::Trrandom {
                kind: params.get_or("trrandom_kind", 1.0) as u32,
                tstep: params.get_or("trrandom_tstep", 1e-9),
                td: params.get_or("trrandom_td", 0.0),
                param: params.get_or("trrandom_param", 1.0),
                mean: params.get_or("trrandom_mean", 0.0),
            },
            10 => {
                // PWL REPEAT — same point storage as kind 3 plus pwl_r offset.
                let n = params.get_or("pwl_count", 0.0) as usize;
                let pts = (0..n)
                    .map(|i| {
                        let t = params.get_or(&format!("pwl_t{i}"), 0.0);
                        let v = params.get_or(&format!("pwl_v{i}"), 0.0);
                        (t, v)
                    })
                    .collect();
                Self::PwlRepeat {
                    pts,
                    repeat_offset: params.get_or("pwl_r", 0.0),
                }
            }
            _ => Self::Dc(params.get_or("dc", 0.0)),
        }
    }

    /// Returns the next discontinuity or transition time after `t`.
    pub fn next_event_time(&self, t: f64) -> Option<f64> {
        match self {
            &Self::Pulse { td, tr, tf, pw, per, .. } => {
                if per <= 0.0 || !per.is_finite() {
                    // Non-periodic: events at td, td+tr, td+tr+pw, td+tr+pw+tf
                    let events = [td, td + tr, td + tr + pw, td + tr + pw + tf];
                    events.iter().copied().filter(|&e| e > t + 1e-18).reduce(f64::min)
                } else {
                    // Periodic: find next event in current or next period
                    let n_periods = ((t - td) / per).floor().max(0.0);
                    let offsets = [0.0, tr, tr + pw, tr + pw + tf];
                    let mut best = f64::MAX;
                    for base_n in [n_periods, n_periods + 1.0] {
                        let base = td + base_n * per;
                        for &off in &offsets {
                            let evt = base + off;
                            if evt > t + 1e-18 && evt < best {
                                best = evt;
                            }
                        }
                    }
                    if best < f64::MAX { Some(best) } else { None }
                }
            }
            Self::Pwl(pairs) => {
                pairs.iter().map(|&(tp, _)| tp).find(|&tp| tp > t + 1e-18)
            }
            // SIN: zero crossings at t = td + n/(2*freq) for integer n.
            &Self::Sin { freq, td, .. } => {
                if freq <= 0.0 || !freq.is_finite() {
                    return None;
                }
                let half_period = 0.5 / freq;
                let t_rel = t - td;
                if t_rel < -1e-18 {
                    // Haven't reached delay yet; next event is the start.
                    return Some(td);
                }
                let n = (t_rel / half_period).ceil() as u64;
                // Guard: if ceil landed exactly on t, advance by one.
                let evt = td + n as f64 * half_period;
                if evt > t + 1e-18 {
                    Some(evt)
                } else {
                    Some(td + (n + 1) as f64 * half_period)
                }
            }
            // EXP: transition starts at td1 and td2.
            &Self::Exp { td1, td2, .. } => {
                let mut best: Option<f64> = None;
                for &evt in &[td1, td2] {
                    if evt > t + 1e-18 {
                        best = Some(best.map_or(evt, |b: f64| b.min(evt)));
                    }
                }
                best
            }
            // SFFM: carrier zero crossings at t = n/fc for integer n.
            &Self::Sffm { fc, .. } => {
                if fc <= 0.0 || !fc.is_finite() {
                    return None;
                }
                let carrier_period = 1.0 / fc;
                let n = (t / carrier_period).ceil() as u64;
                let evt = n as f64 * carrier_period;
                if evt > t + 1e-18 {
                    Some(evt)
                } else {
                    Some((n + 1) as f64 * carrier_period)
                }
            }
            _ => None, // DC, AM, TRNOISE, TRRANDOM, PwlFile — no breakpoints
        }
    }

    /// Evaluate the waveform at time `t` (seconds).
    ///
    /// All formulas follow SPICE3F5 / ngspice conventions.
    #[inline]
    pub fn evaluate_at(&self, t: f64) -> f64 {
        match self {
            // ----------------------------------------------------------------
            // DC — trivially constant
            // ----------------------------------------------------------------
            &Self::Dc(v) => v,

            // ----------------------------------------------------------------
            // PULSE
            //
            // Within each period:
            //   [0,       td)      → v1
            //   [td,      td+tr)   → linear ramp v1 → v2
            //   [td+tr,   td+tr+pw) → v2
            //   [td+tr+pw, td+tr+pw+tf) → linear ramp v2 → v1
            //   [td+tr+pw+tf, per) → v1
            // ----------------------------------------------------------------
            &Self::Pulse {
                v1,
                v2,
                td,
                tr,
                tf,
                pw,
                per,
            } => {
                if t < td {
                    return v1;
                }
                // Time within the repeating cycle after the initial delay.
                let t_rel = if per.is_finite() && per > 0.0 {
                    (t - td) % per
                } else {
                    t - td
                };

                if t_rel < tr {
                    // Rising edge
                    v1 + (v2 - v1) * (t_rel / tr)
                } else if t_rel < tr + pw {
                    // Flat top
                    v2
                } else if t_rel < tr + pw + tf {
                    // Falling edge
                    v2 + (v1 - v2) * ((t_rel - tr - pw) / tf)
                } else {
                    // Flat bottom (back to v1 for the rest of the period)
                    v1
                }
            }

            // ----------------------------------------------------------------
            // SIN
            //
            // SPICE3 formula:
            //   t < td:  vo + va * sin(2π * freq * 0)  = vo
            //   t >= td: vo + va * sin(2π * freq * (t - td)) * exp(-theta * (t - td))
            // ----------------------------------------------------------------
            &Self::Sin {
                vo,
                va,
                freq,
                td,
                theta,
            } => {
                if t < td {
                    vo
                } else {
                    let t_eff = t - td;
                    let angle = core::f64::consts::TAU * freq * t_eff;
                    let damping = if theta == 0.0 {
                        1.0
                    } else {
                        (-theta * t_eff).exp()
                    };
                    vo + va * angle.sin() * damping
                }
            }

            // ----------------------------------------------------------------
            // PWL — piecewise linear interpolation
            // ----------------------------------------------------------------
            Self::Pwl(pts) => {
                if pts.is_empty() {
                    return 0.0;
                }
                if t <= pts[0].0 {
                    return pts[0].1;
                }
                if t >= pts[pts.len() - 1].0 {
                    return pts[pts.len() - 1].1;
                }
                // Binary search for the segment containing t.
                let idx = pts.partition_point(|&(pt, _)| pt <= t);
                // idx is the first point strictly after t → segment [idx-1, idx]
                let (t0, v0) = pts[idx - 1];
                let (t1, v1) = pts[idx];
                let frac = (t - t0) / (t1 - t0);
                v0 + (v1 - v0) * frac
            }

            // ----------------------------------------------------------------
            // EXP
            //
            // SPICE3 formula:
            //   t < td1:           v1
            //   td1 <= t < td2:    v1 + (v2-v1) * (1 - exp(-(t-td1)/tau1))
            //   t >= td2:          v1 + (v2-v1) * (1 - exp(-(t-td1)/tau1))
            //                         + (v1-v2) * (1 - exp(-(t-td2)/tau2))
            // ----------------------------------------------------------------
            &Self::Exp {
                v1,
                v2,
                td1,
                tau1,
                td2,
                tau2,
            } => {
                if t < td1 {
                    v1
                } else if t < td2 {
                    v1 + (v2 - v1) * (1.0 - (-(t - td1) / tau1).exp())
                } else {
                    v1 + (v2 - v1) * (1.0 - (-(t - td1) / tau1).exp())
                        + (v1 - v2) * (1.0 - (-(t - td2) / tau2).exp())
                }
            }

            // ----------------------------------------------------------------
            // SFFM
            //
            // vo + va * sin(2π*fc*t + mdi * sin(2π*fs*t))
            // ----------------------------------------------------------------
            &Self::Sffm {
                vo,
                va,
                fc,
                mdi,
                fs,
            } => {
                let inner = core::f64::consts::TAU * fs * t;
                let outer = core::f64::consts::TAU * fc * t + mdi * inner.sin();
                vo + va * outer.sin()
            }

            // ----------------------------------------------------------------
            // PWL FILE — load CSV on first evaluation, then interpolate
            // ----------------------------------------------------------------
            Self::PwlFile { path } => {
                // Load CSV points (two-column: time, value).
                let pts = Self::load_pwl_csv(path);
                if pts.is_empty() {
                    return 0.0;
                }
                if t <= pts[0].0 {
                    return pts[0].1;
                }
                if t >= pts[pts.len() - 1].0 {
                    return pts[pts.len() - 1].1;
                }
                let idx = pts.partition_point(|&(pt, _)| pt <= t);
                let (t0, v0) = pts[idx - 1];
                let (t1, v1) = pts[idx];
                let frac = (t - t0) / (t1 - t0);
                v0 + (v1 - v0) * frac
            }

            // ----------------------------------------------------------------
            // AM — amplitude modulation
            //
            // V(t) = (vo + va * sin(2π * fc * t_eff)) * sin(2π * freq * t_eff)
            // ----------------------------------------------------------------
            &Self::Am {
                vo,
                va,
                fc,
                freq,
                td,
            } => {
                if t < td {
                    return 0.0;
                }
                let t_eff = t - td;
                let modulator = vo + va * (core::f64::consts::TAU * fc * t_eff).sin();
                let carrier = (core::f64::consts::TAU * freq * t_eff).sin();
                modulator * carrier
            }

            // ----------------------------------------------------------------
            // TRNOISE — white noise sampled every `nt` seconds
            //
            // The noise value is constant within each `nt`-wide slot.
            // Slots are numbered by floor((t - td) / nt); each slot gets a
            // deterministic xorshift64 sample converted to a Gaussian via the
            // Box–Muller transform (u1, u2 drawn from the same seed).
            // Before `td` the output is 0.
            // ----------------------------------------------------------------
            &Self::Trnoise { na, nt, td, .. } => {
                if t < td || na == 0.0 || nt <= 0.0 {
                    return 0.0;
                }
                let slot = ((t - td) / nt) as u64;
                // Box–Muller: need two uniform samples from this slot.
                let u1 = xorshift64_unit(slot.wrapping_mul(2).wrapping_add(1));
                let u2 = xorshift64_unit(slot.wrapping_mul(2).wrapping_add(2));
                // Clamp u1 away from 0 to avoid log(0).
                let u1 = u1.max(f64::EPSILON);
                let gaussian = (-2.0 * u1.ln()).sqrt() * (core::f64::consts::TAU * u2).cos();
                na * gaussian
            }

            // ----------------------------------------------------------------
            // TRRANDOM — piecewise-constant random waveform
            //
            // The value is held constant for `tstep` seconds then updated.
            // Distributions (ngspice convention):
            //   1 = Uniform(-param/2 .. param/2) + mean
            //   2 = Gaussian(sigma=param) + mean
            //   3 = Exponential(mean=param) + mean
            //   4 = Poisson(lambda=param) + mean  (approximated via Gaussian)
            // ----------------------------------------------------------------
            &Self::Trrandom {
                kind,
                tstep,
                td,
                param,
                mean,
            } => {
                if t < td || tstep <= 0.0 {
                    return mean;
                }
                let step = ((t - td) / tstep) as u64;
                let u1 = xorshift64_unit(step.wrapping_mul(2).wrapping_add(1));
                let u2 = xorshift64_unit(step.wrapping_mul(2).wrapping_add(2));
                let sample = match kind {
                    1 => (u1 - 0.5) * param,
                    2 => {
                        // Gaussian via Box–Muller
                        let u1c = u1.max(f64::EPSILON);
                        (-2.0 * u1c.ln()).sqrt() * (core::f64::consts::TAU * u2).cos() * param
                    }
                    3 => {
                        // Exponential: -mean * ln(u)
                        let u1c = u1.max(f64::EPSILON);
                        -param * u1c.ln()
                    }
                    4 => {
                        // Poisson approximated as Gaussian(mu=lambda, sigma=sqrt(lambda))
                        let u1c = u1.max(f64::EPSILON);
                        let g = (-2.0 * u1c.ln()).sqrt() * (core::f64::consts::TAU * u2).cos();
                        param + g * param.sqrt()
                    }
                    _ => 0.0,
                };
                mean + sample
            }

            // ----------------------------------------------------------------
            // PWL REPEAT — piecewise linear with periodic repeat
            //
            // After the last defined point the waveform repeats.
            // period = last_t - repeat_offset
            // t_eff  = ((t - repeat_offset) % period) + repeat_offset  for t > last_t
            // ----------------------------------------------------------------
            Self::PwlRepeat { pts, repeat_offset } => {
                if pts.is_empty() {
                    return 0.0;
                }
                let last_t = pts[pts.len() - 1].0;
                // Map t into the defined [pts[0].0, last_t] window.
                let t_eff = if t > last_t {
                    let period = last_t - *repeat_offset;
                    if period <= 0.0 {
                        return pts[pts.len() - 1].1;
                    }
                    ((t - repeat_offset) % period) + repeat_offset
                } else {
                    t
                };
                // Now interpolate exactly like Pwl.
                if t_eff <= pts[0].0 {
                    return pts[0].1;
                }
                if t_eff >= last_t {
                    return pts[pts.len() - 1].1;
                }
                let idx = pts.partition_point(|&(pt, _)| pt <= t_eff);
                let (t0, v0) = pts[idx - 1];
                let (t1, v1) = pts[idx];
                let frac = (t_eff - t0) / (t1 - t0);
                v0 + (v1 - v0) * frac
            }
        }
    }

    /// Load piecewise-linear points from a two-column CSV file.
    // (helper is a free fn below — see `xorshift64_unit`)
    ///
    /// Each row must be `time,value` (whitespace or comma separated).
    /// Lines starting with `#` are treated as comments and skipped.
    /// Returns an empty Vec on any I/O or parse error.
    pub fn load_pwl_csv(path: &str) -> Vec<(f64, f64)> {
        let content = match std::fs::read_to_string(path) {
            Ok(c) => c,
            Err(_) => return Vec::new(),
        };
        content
            .lines()
            .filter(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'))
            .filter_map(|line| {
                // Accept comma or whitespace as separator.
                let mut parts = line
                    .split(|c: char| c == ',' || c.is_ascii_whitespace())
                    .filter(|s| !s.is_empty());
                let t: f64 = parts.next()?.parse().ok()?;
                let v: f64 = parts.next()?.parse().ok()?;
                Some((t, v))
            })
            .collect()
    }
}

/// Deterministic xorshift64 PRNG — returns a value in (0, 1).
///
/// `seed` must be non-zero; we guarantee that by OR-ing bit 0.
#[inline]
fn xorshift64_unit(seed: u64) -> f64 {
    let mut x = seed | 1; // ensure non-zero
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    // Map to (0, 1) by dividing by 2^64 − 1.
    x as f64 / u64::MAX as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // PULSE tests
    // -----------------------------------------------------------------------

    #[test]
    fn pulse_before_delay() {
        // PULSE(v1=0 v2=5 td=1u tr=100n tf=100n pw=500n per=1u)
        // At t < td the value must be v1.
        let w = Waveform::Pulse {
            v1: 0.0,
            v2: 5.0,
            td: 1e-6,
            tr: 100e-9,
            tf: 100e-9,
            pw: 500e-9,
            per: 1e-6,
        };
        assert!((w.evaluate_at(0.0)).abs() < 1e-15, "at t=0 before delay");
        assert!(
            (w.evaluate_at(500e-9)).abs() < 1e-15,
            "at t=500n before delay"
        );
    }

    #[test]
    fn pulse_at_top() {
        // Once we are past td + tr the value should be v2.
        let w = Waveform::Pulse {
            v1: 0.0,
            v2: 5.0,
            td: 1e-6,
            tr: 100e-9,
            tf: 100e-9,
            pw: 500e-9,
            per: 2e-6,
        };
        let t_top = 1e-6 + 100e-9 + 50e-9; // td + tr + half_pw
        assert!(
            (w.evaluate_at(t_top) - 5.0).abs() < 1e-10,
            "should be v2 at flat top"
        );
    }

    #[test]
    fn pulse_midpoint_of_rise() {
        // At the midpoint of the rising edge the value should be halfway.
        let w = Waveform::Pulse {
            v1: 0.0,
            v2: 5.0,
            td: 1e-6,
            tr: 100e-9,
            tf: 100e-9,
            pw: 500e-9,
            per: 2e-6,
        };
        let t_mid_rise = 1e-6 + 50e-9; // td + tr/2
        let v = w.evaluate_at(t_mid_rise);
        assert!(
            (v - 2.5).abs() < 1e-10,
            "midpoint of rise should be 2.5 V, got {v}"
        );
    }

    #[test]
    fn pulse_midpoint_of_fall() {
        // Halfway through the falling edge the value should be halfway between v2 and v1.
        let w = Waveform::Pulse {
            v1: 0.0,
            v2: 5.0,
            td: 1e-6,
            tr: 100e-9,
            tf: 100e-9,
            pw: 500e-9,
            per: 2e-6,
        };
        let t_mid_fall = 1e-6 + 100e-9 + 500e-9 + 50e-9; // td + tr + pw + tf/2
        let v = w.evaluate_at(t_mid_fall);
        assert!(
            (v - 2.5).abs() < 1e-10,
            "midpoint of fall should be 2.5 V, got {v}"
        );
    }

    #[test]
    fn pulse_back_to_bottom() {
        // After a full cycle (past td + per) the pattern repeats and we should be at v1.
        let w = Waveform::Pulse {
            v1: 0.0,
            v2: 5.0,
            td: 1e-6,
            tr: 100e-9,
            tf: 100e-9,
            pw: 500e-9,
            per: 1e-6,
        };
        // Second period starts at td + per = 2 µs; at 2 µs + 10 ns we're in the
        // flat-bottom region of the second period (since tr=100n, the first 100ns
        // are the rising edge, but we're only 10 ns in — still in the pre-rise
        // flat region relative to the cycle).
        // Actually at t_rel = 10n < tr=100n, we're on the rising edge.
        // Test at t_rel = 800n > tr+pw+tf = 700n → flat bottom.
        let t_flat_bottom = 1e-6 + 1e-6 + 800e-9; // td + per + 800n
        let v = w.evaluate_at(t_flat_bottom);
        assert!(
            v.abs() < 1e-10,
            "flat bottom of 2nd period should be 0 V, got {v}"
        );
    }

    #[test]
    fn pulse_periodic_top_second_cycle() {
        // In the second cycle the pulse should also be high at the flat top.
        let w = Waveform::Pulse {
            v1: 0.0,
            v2: 5.0,
            td: 1e-6,
            tr: 100e-9,
            tf: 100e-9,
            pw: 500e-9,
            per: 1e-6,
        };
        // 2nd period: t_rel from (td + per) runs from 0 to per.
        // Flat top starts at tr=100n; at t_rel=200n we're in the middle of it.
        let t = 1e-6 + 1e-6 + 200e-9;
        let v = w.evaluate_at(t);
        assert!(
            (v - 5.0).abs() < 1e-10,
            "2nd cycle flat top should be 5V, got {v}"
        );
    }

    // -----------------------------------------------------------------------
    // SIN tests
    // -----------------------------------------------------------------------

    #[test]
    fn sin_at_zero_time() {
        // vo=0, va=1, freq=1k, td=0, theta=0.
        // sin(0) = 0, so result = 0.
        let w = Waveform::Sin {
            vo: 0.0,
            va: 1.0,
            freq: 1e3,
            td: 0.0,
            theta: 0.0,
        };
        assert!(w.evaluate_at(0.0).abs() < 1e-15, "sin at t=0 should be 0");
    }

    #[test]
    fn sin_at_quarter_period() {
        // At t = 1/(4*freq) = 250µs the sine is at its peak: vo + va.
        let freq = 1e3;
        let w = Waveform::Sin {
            vo: 0.0,
            va: 1.0,
            freq,
            td: 0.0,
            theta: 0.0,
        };
        let t_quarter = 1.0 / (4.0 * freq);
        let v = w.evaluate_at(t_quarter);
        assert!(
            (v - 1.0).abs() < 1e-10,
            "sin at quarter period should be 1.0, got {v}"
        );
    }

    #[test]
    fn sin_dc_offset() {
        // vo=2, va=1, at t=0 the result should be vo.
        let w = Waveform::Sin {
            vo: 2.0,
            va: 1.0,
            freq: 1e3,
            td: 0.0,
            theta: 0.0,
        };
        assert!((w.evaluate_at(0.0) - 2.0).abs() < 1e-15);
    }

    #[test]
    fn sin_before_delay_returns_vo() {
        let w = Waveform::Sin {
            vo: 3.0,
            va: 5.0,
            freq: 1e6,
            td: 1e-6,
            theta: 0.0,
        };
        // At t = 0.5µs < td = 1µs the result must be vo.
        assert!((w.evaluate_at(0.5e-6) - 3.0).abs() < 1e-15);
    }

    #[test]
    fn sin_at_one_full_period() {
        // After one full period the undamped sine returns to zero.
        let freq = 1e3;
        let w = Waveform::Sin {
            vo: 0.0,
            va: 1.0,
            freq,
            td: 0.0,
            theta: 0.0,
        };
        let t_full = 1.0 / freq;
        let v = w.evaluate_at(t_full);
        assert!(v.abs() < 1e-10, "sin at full period should be ~0, got {v}");
    }

    // -----------------------------------------------------------------------
    // PWL tests
    // -----------------------------------------------------------------------

    #[test]
    fn pwl_interpolation() {
        // (0, 0) → (1, 10): at t=0.5 value should be 5.0.
        let w = Waveform::Pwl(vec![(0.0, 0.0), (1.0, 10.0)]);
        assert!((w.evaluate_at(0.5) - 5.0).abs() < 1e-10);
    }

    #[test]
    fn pwl_before_first_point() {
        let w = Waveform::Pwl(vec![(1.0, 2.0), (2.0, 4.0)]);
        // Before the first point, hold the first value.
        assert!((w.evaluate_at(0.0) - 2.0).abs() < 1e-15);
    }

    #[test]
    fn pwl_after_last_point() {
        let w = Waveform::Pwl(vec![(0.0, 0.0), (1.0, 5.0)]);
        // After the last point, hold the last value.
        assert!((w.evaluate_at(10.0) - 5.0).abs() < 1e-15);
    }

    #[test]
    fn pwl_three_segments() {
        // (0,0), (1,1), (2,0): triangle wave.
        let w = Waveform::Pwl(vec![(0.0, 0.0), (1.0, 1.0), (2.0, 0.0)]);
        assert!((w.evaluate_at(0.5) - 0.5).abs() < 1e-10);
        assert!((w.evaluate_at(1.0) - 1.0).abs() < 1e-10);
        assert!((w.evaluate_at(1.5) - 0.5).abs() < 1e-10);
    }

    #[test]
    fn pwl_exact_knot() {
        let w = Waveform::Pwl(vec![(0.0, 0.0), (1.0, 5.0), (2.0, 3.0)]);
        assert!(
            (w.evaluate_at(1.0) - 5.0).abs() < 1e-10,
            "value at knot t=1"
        );
    }

    // -----------------------------------------------------------------------
    // EXP tests
    // -----------------------------------------------------------------------

    #[test]
    fn exp_before_rise_delay() {
        let w = Waveform::Exp {
            v1: 0.0,
            v2: 1.0,
            td1: 1e-6,
            tau1: 0.5e-6,
            td2: 2e-6,
            tau2: 0.5e-6,
        };
        assert!((w.evaluate_at(0.5e-6)).abs() < 1e-15);
    }

    #[test]
    fn exp_asymptotes_to_v2() {
        // After many tau1 time constants the signal should be close to v2.
        let w = Waveform::Exp {
            v1: 0.0,
            v2: 5.0,
            td1: 0.0,
            tau1: 1e-6,
            td2: 100e-6,
            tau2: 1e-6,
        };
        let v = w.evaluate_at(10e-6); // 10 tau1 after td1, before td2
        assert!(
            (v - 5.0).abs() < 0.001,
            "should be near v2=5 at 10*tau1, got {v}"
        );
    }

    // -----------------------------------------------------------------------
    // SFFM test
    // -----------------------------------------------------------------------

    #[test]
    fn sffm_at_zero() {
        // At t=0: inner = 0, outer = 0, result = vo + va * sin(0) = vo.
        let w = Waveform::Sffm {
            vo: 1.0,
            va: 2.0,
            fc: 1e6,
            mdi: 5.0,
            fs: 1e3,
        };
        assert!((w.evaluate_at(0.0) - 1.0).abs() < 1e-15);
    }

    // -----------------------------------------------------------------------
    // from_params round-trip tests
    // -----------------------------------------------------------------------

    #[test]
    fn from_params_dc_default() {
        let p = ParamMap::new();
        let w = Waveform::from_params(&p);
        assert!((w.evaluate_at(0.0)).abs() < 1e-15);
        assert!((w.evaluate_at(1.0)).abs() < 1e-15);
    }

    #[test]
    fn from_params_dc_explicit() {
        let mut p = ParamMap::new();
        p.set("dc", 3.3);
        let w = Waveform::from_params(&p);
        assert!((w.evaluate_at(0.0) - 3.3).abs() < 1e-15);
    }

    #[test]
    fn from_params_pulse_at_t0_before_delay() {
        let mut p = ParamMap::new();
        p.set("waveform_kind", 1.0);
        p.set("pulse_v1", 0.0);
        p.set("pulse_v2", 5.0);
        p.set("pulse_td", 1e-6);
        p.set("pulse_tr", 1e-9);
        p.set("pulse_tf", 1e-9);
        p.set("pulse_pw", 10e-6);
        p.set("pulse_per", 20e-6);
        let w = Waveform::from_params(&p);
        assert!(
            w.evaluate_at(0.0).abs() < 1e-15,
            "PULSE before td should be v1=0"
        );
    }

    #[test]
    fn from_params_sin_at_t0() {
        let mut p = ParamMap::new();
        p.set("waveform_kind", 2.0);
        p.set("sin_vo", 0.0);
        p.set("sin_va", 1.0);
        p.set("sin_freq", 1000.0);
        p.set("sin_td", 0.0);
        p.set("sin_theta", 0.0);
        let w = Waveform::from_params(&p);
        assert!(w.evaluate_at(0.0).abs() < 1e-15, "SIN at t=0 should be 0");
    }

    #[test]
    fn from_params_pwl() {
        let mut p = ParamMap::new();
        p.set("waveform_kind", 3.0);
        p.set("pwl_count", 2.0);
        p.set("pwl_t0", 0.0);
        p.set("pwl_v0", 0.0);
        p.set("pwl_t1", 1e-6);
        p.set("pwl_v1", 5.0);
        let w = Waveform::from_params(&p);
        // At midpoint t=0.5µs, value should be 2.5 V.
        let v = w.evaluate_at(0.5e-6);
        assert!(
            (v - 2.5).abs() < 1e-10,
            "PWL midpoint should be 2.5V, got {v}"
        );
    }

    // -----------------------------------------------------------------------
    // AM tests
    // -----------------------------------------------------------------------

    #[test]
    fn am_before_delay_returns_zero() {
        let w = Waveform::Am {
            vo: 1.0,
            va: 1.0,
            fc: 1e3,
            freq: 1e6,
            td: 1e-6,
        };
        assert!(
            w.evaluate_at(0.5e-6).abs() < 1e-15,
            "AM before td must be 0"
        );
    }

    #[test]
    fn am_at_carrier_zero_crossing() {
        // When freq * t_eff is a full integer, sin(2π*freq*t_eff)=0 so output is 0.
        let freq = 1e6;
        let w = Waveform::Am {
            vo: 0.5,
            va: 1.0,
            fc: 1e3,
            freq,
            td: 0.0,
        };
        let t_full = 1.0 / freq; // one full carrier period → sin = 0
        assert!(
            w.evaluate_at(t_full).abs() < 1e-9,
            "AM at full carrier period should be 0"
        );
    }

    #[test]
    fn am_peak_modulator_and_carrier() {
        // At t = 1/(4*freq): carrier peak → sin = 1
        // fc << freq so modulator ≈ (vo + va * sin(2π*fc*t)) ≈ vo (small fc*t)
        // Result ≈ vo at t = 0 (both at zero crossing)
        let freq = 1e6;
        let fc = 1e3;
        let vo = 2.0;
        let va = 1.0;
        let w = Waveform::Am {
            vo,
            va,
            fc,
            freq,
            td: 0.0,
        };
        // At t=0: carrier = sin(0) = 0 → output = 0 regardless of modulator
        assert!(w.evaluate_at(0.0).abs() < 1e-15, "AM at t=0 must be 0");
    }

    // -----------------------------------------------------------------------
    // TRNOISE tests
    // -----------------------------------------------------------------------

    #[test]
    fn trnoise_before_delay_is_zero() {
        let w = Waveform::Trnoise {
            na: 1.0,
            nt: 1e-9,
            nalpha: 0.0,
            namp: 0.0,
            td: 1e-6,
        };
        assert!(
            w.evaluate_at(0.0).abs() < 1e-15,
            "TRNOISE before td must be 0"
        );
    }

    #[test]
    fn trnoise_zero_amplitude_is_zero() {
        let w = Waveform::Trnoise {
            na: 0.0,
            nt: 1e-9,
            nalpha: 0.0,
            namp: 0.0,
            td: 0.0,
        };
        assert!(w.evaluate_at(1e-9).abs() < 1e-15, "TRNOISE na=0 must be 0");
    }

    #[test]
    fn trnoise_same_slot_is_deterministic() {
        let w = Waveform::Trnoise {
            na: 1.0,
            nt: 1e-9,
            nalpha: 0.0,
            namp: 0.0,
            td: 0.0,
        };
        // Two times within the same nt slot must return the same value.
        let v1 = w.evaluate_at(0.1e-9);
        let v2 = w.evaluate_at(0.9e-9);
        assert!((v1 - v2).abs() < 1e-15, "same slot: {v1} vs {v2}");
    }

    #[test]
    fn trnoise_different_slots_usually_differ() {
        let w = Waveform::Trnoise {
            na: 1.0,
            nt: 1e-9,
            nalpha: 0.0,
            namp: 0.0,
            td: 0.0,
        };
        let v1 = w.evaluate_at(0.5e-9); // slot 0
        let v2 = w.evaluate_at(1.5e-9); // slot 1
        // Two different slots should (almost certainly) give different values.
        assert!(
            (v1 - v2).abs() > 1e-10,
            "different slots should give different values"
        );
    }

    // -----------------------------------------------------------------------
    // TRRANDOM tests
    // -----------------------------------------------------------------------

    #[test]
    fn trrandom_before_delay_returns_mean() {
        let w = Waveform::Trrandom {
            kind: 1,
            tstep: 1e-6,
            td: 1e-6,
            param: 1.0,
            mean: 3.0,
        };
        assert!(
            (w.evaluate_at(0.0) - 3.0).abs() < 1e-15,
            "before td must return mean"
        );
    }

    #[test]
    fn trrandom_uniform_same_step_deterministic() {
        let w = Waveform::Trrandom {
            kind: 1,
            tstep: 1e-6,
            td: 0.0,
            param: 2.0,
            mean: 0.0,
        };
        let v1 = w.evaluate_at(0.1e-6);
        let v2 = w.evaluate_at(0.9e-6);
        assert!((v1 - v2).abs() < 1e-15, "same step must be deterministic");
    }

    #[test]
    fn trrandom_uniform_in_range() {
        let param = 2.0; // range
        let mean = 5.0;
        let w = Waveform::Trrandom {
            kind: 1,
            tstep: 1e-9,
            td: 0.0,
            param,
            mean,
        };
        for i in 0..20u64 {
            let t = (i as f64 + 0.5) * 1e-9;
            let v = w.evaluate_at(t);
            assert!(
                v >= mean - param / 2.0 - 1e-12 && v <= mean + param / 2.0 + 1e-12,
                "uniform out of range at step {i}: {v}"
            );
        }
    }

    #[test]
    fn trrandom_gaussian_different_steps_differ() {
        let w = Waveform::Trrandom {
            kind: 2,
            tstep: 1e-6,
            td: 0.0,
            param: 1.0,
            mean: 0.0,
        };
        let v1 = w.evaluate_at(0.5e-6); // step 0
        let v2 = w.evaluate_at(1.5e-6); // step 1
        assert!((v1 - v2).abs() > 1e-10, "different steps should differ");
    }

    #[test]
    fn trrandom_exponential_positive() {
        // Exponential distribution is always positive (before adding mean=0).
        let w = Waveform::Trrandom {
            kind: 3,
            tstep: 1e-9,
            td: 0.0,
            param: 1.0,
            mean: 0.0,
        };
        for i in 0..20u64 {
            let t = (i as f64 + 0.5) * 1e-9;
            let v = w.evaluate_at(t);
            assert!(
                v >= 0.0,
                "exponential sample must be non-negative, got {v} at step {i}"
            );
        }
    }

    // -----------------------------------------------------------------------
    // PWL REPEAT tests
    // -----------------------------------------------------------------------

    #[test]
    fn pwl_repeat_within_defined_range() {
        // Triangle: (0,0) (1,1) (2,0), repeat_offset=0
        let w = Waveform::PwlRepeat {
            pts: vec![(0.0, 0.0), (1.0, 1.0), (2.0, 0.0)],
            repeat_offset: 0.0,
        };
        assert!((w.evaluate_at(0.5) - 0.5).abs() < 1e-10);
        assert!((w.evaluate_at(1.0) - 1.0).abs() < 1e-10);
        assert!((w.evaluate_at(1.5) - 0.5).abs() < 1e-10);
    }

    #[test]
    fn pwl_repeat_wraps_after_last_point() {
        // Triangle: (0,0) (1,1) (2,0), period = 2 - 0 = 2
        // At t=2.5: t_eff = ((2.5 - 0) % 2) + 0 = 0.5 → value = 0.5
        let w = Waveform::PwlRepeat {
            pts: vec![(0.0, 0.0), (1.0, 1.0), (2.0, 0.0)],
            repeat_offset: 0.0,
        };
        let v = w.evaluate_at(2.5);
        assert!(
            (v - 0.5).abs() < 1e-10,
            "t=2.5 should wrap to 0.5 → value 0.5, got {v}"
        );
    }

    #[test]
    fn pwl_repeat_second_full_period() {
        // At t=3.0: t_eff = ((3.0 - 0) % 2) + 0 = 1.0 → value = 1.0 (peak)
        let w = Waveform::PwlRepeat {
            pts: vec![(0.0, 0.0), (1.0, 1.0), (2.0, 0.0)],
            repeat_offset: 0.0,
        };
        let v = w.evaluate_at(3.0);
        assert!(
            (v - 1.0).abs() < 1e-10,
            "t=3.0 should map to peak t=1.0 → 1.0, got {v}"
        );
    }

    #[test]
    fn pwl_repeat_nonzero_offset() {
        // Points: (1,0) (2,5) (3,0), repeat_offset=1.0, period = 3-1 = 2
        // At t=4.0: t_eff = ((4.0 - 1.0) % 2.0) + 1.0 = (3.0 % 2.0) + 1.0 = 1.0 + 1.0 = 2.0
        // → interpolation at t=2.0 → value = 5.0
        let w = Waveform::PwlRepeat {
            pts: vec![(1.0, 0.0), (2.0, 5.0), (3.0, 0.0)],
            repeat_offset: 1.0,
        };
        let v = w.evaluate_at(4.0);
        assert!(
            (v - 5.0).abs() < 1e-10,
            "t=4.0 should map to peak at t=2.0 → 5.0, got {v}"
        );
    }

    #[test]
    fn from_params_am() {
        let mut p = ParamMap::new();
        p.set("waveform_kind", 7.0);
        p.set("am_vo", 0.0);
        p.set("am_va", 1.0);
        p.set("am_fc", 1e3);
        p.set("am_freq", 1e6);
        p.set("am_td", 0.0);
        let w = Waveform::from_params(&p);
        // At t=0 the carrier sin(0)=0 → output=0.
        assert!(
            w.evaluate_at(0.0).abs() < 1e-15,
            "AM from_params at t=0 should be 0"
        );
    }

    #[test]
    fn from_params_trnoise() {
        let mut p = ParamMap::new();
        p.set("waveform_kind", 8.0);
        p.set("trnoise_na", 1.0);
        p.set("trnoise_nt", 1e-9);
        p.set("trnoise_nalpha", 0.0);
        p.set("trnoise_namp", 0.0);
        p.set("trnoise_td", 0.0);
        let w = Waveform::from_params(&p);
        // Determinism check: same t twice.
        let v1 = w.evaluate_at(0.5e-9);
        let v2 = w.evaluate_at(0.5e-9);
        assert!((v1 - v2).abs() < 1e-15, "TRNOISE should be deterministic");
    }

    #[test]
    fn from_params_trrandom() {
        let mut p = ParamMap::new();
        p.set("waveform_kind", 9.0);
        p.set("trrandom_kind", 1.0);
        p.set("trrandom_tstep", 1e-6);
        p.set("trrandom_td", 0.0);
        p.set("trrandom_param", 2.0);
        p.set("trrandom_mean", 0.0);
        let w = Waveform::from_params(&p);
        // Value should be in [-1, 1] (uniform ±param/2).
        let v = w.evaluate_at(0.5e-6);
        assert!(
            v.abs() <= 1.0 + 1e-12,
            "TRRANDOM uniform sample out of range: {v}"
        );
    }

    #[test]
    fn from_params_pwl_repeat() {
        let mut p = ParamMap::new();
        p.set("waveform_kind", 10.0);
        p.set("pwl_count", 3.0);
        p.set("pwl_t0", 0.0);
        p.set("pwl_v0", 0.0);
        p.set("pwl_t1", 1.0);
        p.set("pwl_v1", 1.0);
        p.set("pwl_t2", 2.0);
        p.set("pwl_v2", 0.0);
        p.set("pwl_r", 0.0);
        let w = Waveform::from_params(&p);
        // At t=2.5 should wrap to 0.5 → value 0.5.
        let v = w.evaluate_at(2.5);
        assert!(
            (v - 0.5).abs() < 1e-10,
            "PWL REPEAT from_params wrap: got {v}"
        );
    }
}
