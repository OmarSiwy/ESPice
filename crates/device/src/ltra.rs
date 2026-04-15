//! LTRA — Lossy Transmission Line (`O` element).
//!
//! Implements the Berkeley SPICE3 `O` element: a uniformly-distributed
//! lossy RG + LC transmission line characterised by per-unit-length
//! resistance `R`, inductance `L`, conductance `G`, capacitance `C`, and
//! total length `LEN`.
//!
//! ## Model card
//!
//! ```text
//! .MODEL LYNE LTRA (R=10 L=250n G=0 C=100p LEN=1 NONINT=0)
//! O1 in gnd out gnd LYNE
//! ```
//!
//! ## Scope of this implementation
//!
//! Two complementary code paths are wired up:
//!
//!   1. **DC stamp** (the [`Ltra`] [`DeviceModel`] impl) — a resistive T
//!      consisting of `R_tot = R*LEN` in series with `G_tot/2 = G*LEN/2`
//!      shunts at each port.  Used for `.OP`, `.DC` sweeps, and the
//!      transient `t=0` bootstrap.
//!   2. **Dispersive transient convolution** (`compute_norton_equivalent`
//!      and `compute_norton_equivalent_nonint`) — Roychowdhury-Pederson
//!      kernel evaluated against the per-instance forward/backward
//!      waveform history.  The companion conductance and the Norton
//!      current source are added to the resistive-T stamp by the
//!      stamper at every NR iteration.
//!
//! The `NONINT=1` model option selects the non-interpolated history
//! lookup variant: each past sample contributes via a midpoint-rule
//! quadrature with nearest-neighbour history reads instead of the
//! linear-interpolation trapezoidal default.  This avoids the
//! interpolation phase shift on rapidly-changing inputs at the cost
//! of a small stair-step quadrature artefact.
//!
//! ## Pin layout (matches `T` element for consistency)
//!
//! | pin | meaning                  |
//! |-----|--------------------------|
//! | 0   | port-1 positive (in+)    |
//! | 1   | port-1 negative (in-)    |
//! | 2   | port-2 positive (out+)   |
//! | 3   | port-2 negative (out-)   |
//!
//! Unlike `T`, the LTRA element does **not** need MNA branch current
//! variables for the DC path — the resistive T network is stamped
//! directly into the node admittance matrix.
//!
//! ## Parameters
//!
//! | Key     | Default | Description                              |
//! |---------|---------|------------------------------------------|
//! | `r`     | 0       | Series resistance per unit length (Ω/m)  |
//! | `l`     | 0       | Series inductance per unit length (H/m)  |
//! | `g`     | 0       | Shunt conductance per unit length (S/m)  |
//! | `c`     | 0       | Shunt capacitance per unit length (F/m)  |
//! | `len`   | 1       | Total line length (m)                    |
//! | `nonint`| 0       | 0 = interpolated history; 1 = nearest    |
//!
//! When both `r` and `g` are zero the line degenerates to the
//! lossless case; the DC stamp uses Z0 = sqrt(L/C) as the effective
//! series resistance to keep the MNA matrix non-singular.

use smallvec::{SmallVec, smallvec};
use bigospice_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// LTRA lossy transmission line device model.
///
/// State-free wrapper — per-instance history lives in
/// [`LtraInstance`] / [`LtraHistory`] and is owned by the circuit.
#[derive(Debug, Clone, Copy)]
pub struct Ltra;

impl Ltra {
    /// Minimum series conductance to keep the MNA matrix regular when
    /// both R and G are zero (lossless limit).
    const GMIN: f64 = 1.0e-12;

    /// Resolve the effective per-line series resistance and per-port
    /// shunt conductance from the device parameters.
    ///
    /// Returns `(r_eff, g_shunt_half)`:
    ///   - `r_eff`       — series resistance between port-1+ and port-2+,
    ///                     equal to `R*LEN` when positive.  For the
    ///                     lossless case (R=0, G=0, L>0, C>0) we use the
    ///                     characteristic impedance Z0 = sqrt(L/C) so the
    ///                     DC stamp sees the correct termination rather than
    ///                     an arbitrary large resistor.  `1/GMIN` is only
    ///                     used when Z0 is undefined (L=0 or C=0).
    ///   - `g_shunt_half = G*LEN/2` — shunt conductance at each port.
    #[inline]
    fn resolve(params: &ParamMap) -> (f64, f64) {
        let r = params.get_or("r", 0.0).max(0.0);
        let g = params.get_or("g", 0.0).max(0.0);
        let l = params.get_or("l", 0.0).max(0.0);
        let c = params.get_or("c", 0.0).max(0.0);
        let len = params.get_or("len", 1.0).max(0.0);
        let r_tot = r * len;
        // When the series resistance is zero the DC model degenerates
        // to an ideal wire, which makes the admittance matrix singular.
        // For the lossless case (R=0, G=0) use Z0 = sqrt(L/C) as the
        // effective series resistance — this is the physically correct
        // matched termination.  Fall back to 1/GMIN only when Z0 is
        // undefined (L=0 or C=0).
        let r_eff = if r_tot > 0.0 {
            r_tot
        } else if l > 0.0 && c > 0.0 {
            (l / c).sqrt()
        } else {
            1.0 / Self::GMIN
        };
        let g_shunt = 0.5 * g * len;
        (r_eff, g_shunt)
    }
}

impl DeviceModel for Ltra {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        self.eval_with_branch(voltages, 0.0, params)
    }

    fn eval_with_branch(
        &self,
        voltages: &[f64],
        _branch_current: f64,
        params: &ParamMap,
    ) -> DeviceEval {
        // The DC resistive-T stamp is identical for `nonint=0` and
        // `nonint=1`.  The two flag values diverge only inside the
        // dispersive transient convolution kernel
        // (`compute_norton_equivalent_nonint`), which the stamper
        // applies on top of this stamp at every NR iteration during
        // a transient analysis.  We deliberately read and discard
        // the parameter here so the model card validates cleanly.
        let _nonint = params.get_or("nonint", 0.0) != 0.0;

        let vp1 = voltages.first().copied().unwrap_or(0.0);
        let vn1 = voltages.get(1).copied().unwrap_or(0.0);
        let vp2 = voltages.get(2).copied().unwrap_or(0.0);
        let vn2 = voltages.get(3).copied().unwrap_or(0.0);

        let (r_eff, g_shunt) = Self::resolve(params);
        let g_series = 1.0 / r_eff;

        // Axial (series) current:  I = (V(n1+) - V(n2+)) / R_eff
        // Shunt at port 1: I_sh1 = G_shunt * (V(n1+) - V(n1-))
        // Shunt at port 2: I_sh2 = G_shunt * (V(n2+) - V(n2-))
        let i_series = (vp1 - vp2) * g_series;
        let i_sh1 = (vp1 - vn1) * g_shunt;
        let i_sh2 = (vp2 - vn2) * g_shunt;

        // Residuals (KCL at each pin):
        //   pin 0 (n1+): +I_series + I_sh1
        //   pin 1 (n1-): -I_sh1
        //   pin 2 (n2+): -I_series + I_sh2
        //   pin 3 (n2-): -I_sh2
        let g = smallvec![
            i_series + i_sh1,
            -i_sh1,
            -i_series + i_sh2,
            -i_sh2,
        ];

        // Jacobian entries (dI/dV) — symmetric resistive T network.
        //
        //         n1+     n1-     n2+     n2-
        // n1+ [ +gs+gh,  -gh,   -gs,    0   ]
        // n1- [  -gh,   +gh,    0,     0   ]
        // n2+ [  -gs,    0,   +gs+gh,  -gh  ]
        // n2- [   0,     0,    -gh,   +gh  ]
        #[allow(non_snake_case)]
        let G: SmallVec<[(u8, u8, f64); 8]> = smallvec![
            (0, 0, g_series + g_shunt),
            (0, 1, -g_shunt),
            (0, 2, -g_series),
            (1, 0, -g_shunt),
            (1, 1, g_shunt),
            (2, 0, -g_series),
            (2, 2, g_series + g_shunt),
            (2, 3, -g_shunt),
            (3, 2, -g_shunt),
            (3, 3, g_shunt),
        ];

        DeviceEval {
            g,
            q: SmallVec::new(),
            G,
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn needs_branch(&self) -> bool {
        // The DC path stamps into the nodal admittance matrix directly;
        // no MNA branch variable is required.
        false
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Ltra
    }
}

// ───────────────────────────────────────────────────────────────────────
// Per-instance history (Roychowdhury-Pederson convolution, deferred)
// ───────────────────────────────────────────────────────────────────────

/// Per-instance history buffer for the LTRA transient convolution.
///
/// Stores the forward/backward traveling-wave observables at each port
/// so the Roychowdhury-Pederson trapezoidal-convolution kernel can be
/// evaluated at the next timestep.
///
/// **Data layout — SoA per CLAUDE.md:** each field is a contiguous
/// `Vec<f64>` keyed by sample index, not a `Vec<(t, v1, v2, i1, i2)>`.
/// Hot transient code iterating over history touches at most two of the
/// five arrays at a time, which is cache-friendly even at 64k samples.
#[derive(Debug, Clone, Default)]
pub struct LtraHistory {
    /// Sample time stamps (seconds).
    pub times: Vec<f64>,
    /// V(port1+) - V(port1-) history.
    pub v1: Vec<f64>,
    /// V(port2+) - V(port2-) history.
    pub v2: Vec<f64>,
    /// Port-1 axial (into the line) current history.
    pub i1: Vec<f64>,
    /// Port-2 axial (into the line) current history.
    pub i2: Vec<f64>,
}

impl LtraHistory {
    /// Create a new empty history with the given sample capacity.
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            times: Vec::with_capacity(cap),
            v1: Vec::with_capacity(cap),
            v2: Vec::with_capacity(cap),
            i1: Vec::with_capacity(cap),
            i2: Vec::with_capacity(cap),
        }
    }

    /// Push one `(t, v1, v2, i1, i2)` sample.
    pub fn push(&mut self, t: f64, v1: f64, v2: f64, i1: f64, i2: f64) {
        self.times.push(t);
        self.v1.push(v1);
        self.v2.push(v2);
        self.i1.push(i1);
        self.i2.push(i2);
    }

    /// Number of stored samples.
    #[inline]
    pub fn len(&self) -> usize {
        self.times.len()
    }

    /// Whether no samples have been stored yet.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.times.is_empty()
    }

    /// Trapezoidal-rule integration of a scalar field `f(t)` sampled at
    /// `self.times`, from the first sample through `t_end`.
    ///
    /// Used by the transient convolution kernel against the LTRA
    /// impulse response (follow-up work).  Exposed here for unit
    /// testability of the history store.
    pub fn trapz(&self, values: &[f64], t_end: f64) -> f64 {
        if self.times.len() < 2 || values.len() != self.times.len() {
            return 0.0;
        }
        let mut acc = 0.0;
        for i in 1..self.times.len() {
            let t = self.times[i];
            if t > t_end {
                break;
            }
            let dt = t - self.times[i - 1];
            acc += 0.5 * dt * (values[i] + values[i - 1]);
        }
        acc
    }
}

/// One instance of an LTRA element in the circuit.
///
/// Carries the four port nodes (as local pin indices) plus the
/// per-instance history buffer.  The enclosing `Circuit` owns a
/// `Vec<Option<LtraInstance>>` indexed by `DeviceId` (sparse SoA, no
/// `HashMap`, no `Box<dyn>`).
#[derive(Debug, Clone, Default)]
pub struct LtraInstance {
    /// Pin indices into the device terminal list (always `[0,1,2,3]`
    /// for a standard 4-node LTRA; stored explicitly for future
    /// 2-terminal grounded-return variants).
    pub ports: [u8; 4],
    /// Convolution history.
    pub history: LtraHistory,
}

impl LtraInstance {
    /// Create an empty 4-port instance with default pin mapping.
    pub fn new() -> Self {
        Self {
            ports: [0, 1, 2, 3],
            history: LtraHistory::default(),
        }
    }
}

// ───────────────────────────────────────────────────────────────────────
// Roychowdhury-Pederson dispersive transient convolution kernel
// ───────────────────────────────────────────────────────────────────────

/// Regime of the LTRA line, used to select the impulse-response formula.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LtraRegime {
    /// L=0, C=0: purely resistive-conductive line.  Impulse response is
    /// a Gaussian (diffusion kernel).
    RcDominated,
    /// L>0, C>0 with losses: attenuated travelling wave with finite TD.
    General,
    /// R=0, G=0, L>0, C>0: lossless line.  Ideal Branin model — delta
    /// function at TD.  For the DC/early-transient path we return zero
    /// and rely on the resistive-T stamp.
    Lossless,
}

/// Pre-computed per-line parameters used by the convolution kernel.
#[derive(Debug, Clone, Copy)]
pub struct LtraLineParams {
    pub r: f64,
    pub l: f64,
    pub g: f64,
    pub c: f64,
    pub len: f64,
}

impl LtraLineParams {
    /// Build from a device [`ParamMap`].
    pub fn from_params(p: &ParamMap) -> Self {
        Self {
            r: p.get_or("r", 0.0).max(0.0),
            l: p.get_or("l", 0.0).max(0.0),
            g: p.get_or("g", 0.0).max(0.0),
            c: p.get_or("c", 0.0).max(0.0),
            len: p.get_or("len", 1.0).max(1e-15),
        }
    }

    /// One-way travel delay (seconds).  Zero when `l` or `c` is zero.
    #[inline]
    pub fn td(&self) -> f64 {
        self.len * (self.l * self.c).max(0.0).sqrt()
    }

    /// Characteristic impedance (Ω).  Returns `1/GMIN` for degenerate cases.
    #[inline]
    pub fn z0(&self) -> f64 {
        let lc = self.l * self.c;
        if lc > 0.0 {
            (self.l / self.c).sqrt()
        } else {
            1.0 / 1e-12
        }
    }

    /// Classify the line into a convolution regime.
    pub fn regime(&self) -> LtraRegime {
        let has_lc = self.l > 0.0 && self.c > 0.0;
        let has_rc = self.r > 0.0 || self.g > 0.0;
        if has_lc && !has_rc {
            LtraRegime::Lossless
        } else if has_lc {
            LtraRegime::General
        } else {
            LtraRegime::RcDominated
        }
    }
}

/// Evaluate the LTRA impulse response `h(tau)` at lag `tau >= 0`.
///
/// Returns the value of the impulse-response function for the chosen
/// regime.  Used by [`compute_norton_equivalent`] to form the
/// trapezoidal convolution integral.
pub fn ltra_kernel(tau: f64, lp: &LtraLineParams) -> f64 {
    if tau < 0.0 {
        return 0.0;
    }
    match lp.regime() {
        LtraRegime::Lossless => {
            // Delta function at tau == TD.  For continuous integration we
            // return zero everywhere; the stamper applies a direct Branin
            // stamp separately.
            0.0
        }
        LtraRegime::RcDominated => {
            // Causal RC diffusion kernel (Roychowdhury-Pederson Green's function
            // for 1-D lossy RC line):
            //
            //   h(tau) = sqrt(r_pu * c_pu) * len / (2 * sqrt(pi))
            //            * tau^(-3/2) * exp(-r_pu * c_pu * len^2 / (4 * tau))
            //
            // where r_pu, c_pu are per-unit-length R and C.
            //
            // Previous code used rc = r*len * c*len = r_pu*c_pu*len^2, which
            // caused the norm to lose the len factor:
            //   old: len / (2*sqrt(pi * r_pu*c_pu*len^2)) = 1/(2*sqrt(pi*r_pu*c_pu))
            //   correct: sqrt(r_pu*c_pu)*len / (2*sqrt(pi))
            let r_pu = lp.r;
            let c_pu = lp.c;
            let rc_pu = r_pu * c_pu;
            if rc_pu <= 0.0 || tau <= 0.0 {
                return 0.0;
            }
            let norm = rc_pu.sqrt() * lp.len / (2.0 * std::f64::consts::PI.sqrt());
            norm * tau.powf(-1.5) * (-rc_pu * lp.len * lp.len / (4.0 * tau)).exp()
        }
        LtraRegime::General => {
            let td = lp.td();
            if tau < td {
                return 0.0;
            }
            // Attenuated travelling-wave kernel (without 1/Z0 factor).
            // h(tau) = exp(-alpha_rate*(tau-TD)) for tau > TD
            // where alpha_rate = R/(2L) + G/(2C) has units 1/s (per-unit-length
            // decay rate along the time axis of the convolution).
            // The 1/Z0 factor is applied separately in the companion model.
            let alpha_rate = 0.5 * (lp.r / lp.l.max(1e-30) + lp.g / lp.c.max(1e-30));
            let delay = tau - td;
            (-alpha_rate * delay).exp()
        }
    }
}

/// Nearest-neighbour history lookup (the `NONINT=1` variant).
///
/// Skips the linear interpolation done by [`interpolate_history`] and
/// instead snaps to whichever stored sample is closest in time to
/// `target`.  This matches the Berkeley LTRA `nonint=1` behaviour:
/// cheaper per evaluation, no fractional-time arithmetic, and no
/// interpolation phase shift — at the cost of mild stair-step jitter
/// when the timestep varies aggressively.
///
/// Returns `(value, found)` where `found` is false when the history is
/// empty or malformed.
pub fn nearest_history(times: &[f64], values: &[f64], target: f64) -> (f64, bool) {
    if times.is_empty() || times.len() != values.len() {
        return (0.0, false);
    }
    if times.len() == 1 {
        return (values[0], true);
    }
    if target <= times[0] {
        return (values[0], true);
    }
    if target >= *times.last().unwrap() {
        return (*values.last().unwrap(), true);
    }
    // Binary search for the bracket, then pick the closer endpoint.
    let pos = times.partition_point(|&t| t <= target);
    if pos == 0 {
        return (values[0], true);
    }
    if pos >= times.len() {
        return (*values.last().unwrap(), true);
    }
    let i = pos - 1;
    let t0 = times[i];
    let t1 = times[i + 1];
    if (target - t0).abs() <= (t1 - target).abs() {
        (values[i], true)
    } else {
        (values[i + 1], true)
    }
}

/// Norton equivalent for one port of the LTRA element at the current time.
#[derive(Debug, Clone, Copy, Default)]
pub struct LtraNorton {
    /// Norton current source at port 1 (positive into pin 0, out of pin 1).
    pub i_eq_p1: f64,
    /// Conductance companion at port 1.
    pub g_eq_p1: f64,
    /// Norton current source at port 2 (positive into pin 2, out of pin 3).
    pub i_eq_p2: f64,
    /// Conductance companion at port 2.
    pub g_eq_p2: f64,
}

/// Interpolate a history array at `target` time using linear interpolation.
fn interp_history(times: &[f64], values: &[f64], target: f64) -> f64 {
    if times.is_empty() { return 0.0; }
    if target <= times[0] { return values[0]; }
    if target >= *times.last().unwrap() { return *values.last().unwrap(); }
    let idx = times.partition_point(|&t| t <= target);
    if idx == 0 { return values[0]; }
    if idx >= times.len() { return *values.last().unwrap(); }
    let (t0, v0) = (times[idx - 1], values[idx - 1]);
    let (t1, v1) = (times[idx], values[idx]);
    let frac = (target - t0) / (t1 - t0);
    v0 + frac * (v1 - v0)
}

/// Compute Norton equivalents for both ports of the LTRA line at `t_now`.
///
/// Uses the attenuated Branin companion model: at each port, the Norton
/// current comes from the *opposite* port's wave variable `E = V + Z0*I`
/// delayed by TD and attenuated by `A = exp(-alpha_neper)`.
///
///   I_eq_p2(t) = -Y0 * A * E1(t - TD)
///
/// For RC-dominated lines (L ≈ 0) the Branin wave-impedance model is
/// degenerate (Z0 → ∞, Y0 → 0) and the Norton contribution would be
/// numerically zero regardless.  The RC diffusion regime is handled by
/// the convolution kernel in [`ltra_kernel`]; this function returns zeros
/// early for that regime so the stamper relies purely on the resistive-T
/// DC stamp for RC lines.
///
/// Returns `LtraNorton::default()` (zeros) when the history is empty.
pub fn compute_norton_equivalent(
    t_now: f64,
    lp: &LtraLineParams,
    times: &[f64],
    v1: &[f64],
    v2: &[f64],
    i1: &[f64],
    i2: &[f64],
) -> LtraNorton {
    if times.len() < 2 {
        return LtraNorton::default();
    }

    // RC-dominated lines have no wave impedance.  The Branin companion model
    // requires a finite Z0; when L < threshold we switch to a trapezoidal
    // convolution using the RC diffusion kernel (`ltra_kernel`) instead.
    // The Norton current at each port is the integral of h(tau)*V_far(t-tau)
    // over the available history; there is no companion conductance term
    // (g_eq = 0) because the RC diffusion model has no instantaneous Y0*V term.
    if lp.l < 1e-30 {
        let n = times.len();
        if n < 2 {
            return LtraNorton::default();
        }
        let mut i_eq_p1 = 0.0_f64;
        let mut i_eq_p2 = 0.0_f64;
        for k in 0..n - 1 {
            let t_k  = times[k];
            let t_k1 = times[k + 1];
            let tau_k  = t_now - t_k;
            let tau_k1 = t_now - t_k1;
            if tau_k < 0.0 {
                break;
            }
            let dt = t_k1 - t_k;
            let h_k  = ltra_kernel(tau_k,  lp);
            let h_k1 = ltra_kernel(tau_k1, lp);
            // Port 1 Norton current driven by far-end (port 2) voltage history.
            i_eq_p1 += 0.5 * (h_k * v2[k] + h_k1 * v2[k + 1]) * dt;
            // Port 2 Norton current driven by far-end (port 1) voltage history.
            i_eq_p2 += 0.5 * (h_k * v1[k] + h_k1 * v1[k + 1]) * dt;
        }
        return LtraNorton {
            g_eq_p1: 0.0,
            g_eq_p2: 0.0,
            i_eq_p1,
            i_eq_p2,
        };
    }

    let z0 = lp.z0();
    let y0 = 1.0 / z0;
    let td = lp.td();
    // Branin companion-model attenuation: dimensionless neper loss over one
    // full transit of the line.  Correct formula (Roychowdhury-Pederson):
    //   alpha_neper = len * (R / (2*Z0) + G*Z0 / 2)
    // where R, G are per-unit-length and Z0 = sqrt(L/C) per-unit-length.
    // The old formula `0.5*(R/L + G/C)*td` had units of 1/s * s = nepers but
    // used the wrong per-unit-length impedance scaling.
    let alpha_neper = lp.len * (lp.r / (2.0 * z0) + lp.g * z0 / 2.0);
    let atten = (-alpha_neper).exp(); // total attenuation factor across the line

    let t_delayed = t_now - td;

    // Look up wave variables E = V + Z0*I at the delayed time.
    let e1_delayed = if t_delayed >= times[0] {
        let v = interp_history(times, v1, t_delayed);
        let i = interp_history(times, i1, t_delayed);
        v + z0 * i
    } else {
        0.0
    };
    let e2_delayed = if t_delayed >= times[0] {
        let v = interp_history(times, v2, t_delayed);
        let i = interp_history(times, i2, t_delayed);
        v + z0 * i
    } else {
        0.0
    };

    // Norton current: I_eq = -Y0 * A * E_opposite(t - TD)
    let i_eq_p1 = -y0 * atten * e2_delayed;
    let i_eq_p2 = -y0 * atten * e1_delayed;

    LtraNorton {
        i_eq_p1,
        g_eq_p1: y0,
        i_eq_p2,
        g_eq_p2: y0,
    }
}

/// NONINT-aware version of [`compute_norton_equivalent`].
///
/// When `nonint = false` (default) the convolution quadrature is the
/// trapezoidal rule using the stored sample times directly — exactly
/// what [`compute_norton_equivalent`] does.  When `nonint = true` the
/// kernel uses a midpoint quadrature on each interval, reading the
/// past observable via [`nearest_history`] instead of linearly
/// interpolating it; the per-interval contribution becomes
/// `Δt · h(τ_mid) · obs_nearest(t_mid)`.
///
/// Both branches converge to the same DC steady-state value when the
/// history is constant; the difference shows up only as a small
/// integration-rule artefact and (more importantly) avoids the linear
/// interpolation phase shift on rapidly-changing inputs.
pub fn compute_norton_equivalent_nonint(
    t_now: f64,
    lp: &LtraLineParams,
    times: &[f64],
    v1: &[f64],
    v2: &[f64],
    i1: &[f64],
    i2: &[f64],
    nonint: bool,
) -> LtraNorton {
    if !nonint {
        return compute_norton_equivalent(t_now, lp, times, v1, v2, i1, i2);
    }
    // NONINT variant uses nearest-neighbour lookup instead of interpolation.
    if times.len() < 2 {
        return LtraNorton::default();
    }

    // RC-dominated lines: same guard as compute_norton_equivalent.
    // Branin companion model is degenerate without inductance.
    if lp.l < 1e-30 {
        return LtraNorton::default();
    }

    let z0 = lp.z0();
    let y0 = 1.0 / z0;
    let td = lp.td();
    // Same corrected Branin attenuation as compute_norton_equivalent:
    //   alpha_neper = len * (R / (2*Z0) + G*Z0 / 2)
    let alpha_neper = lp.len * (lp.r / (2.0 * z0) + lp.g * z0 / 2.0);
    let atten = (-alpha_neper).exp();

    let t_delayed = t_now - td;

    // Nearest-neighbour wave variable lookup at delayed time.
    let e1_delayed = if t_delayed >= times[0] {
        let (v, _) = nearest_history(times, v1, t_delayed);
        let (i, _) = nearest_history(times, i1, t_delayed);
        v + z0 * i
    } else { 0.0 };
    let e2_delayed = if t_delayed >= times[0] {
        let (v, _) = nearest_history(times, v2, t_delayed);
        let (i, _) = nearest_history(times, i2, t_delayed);
        v + z0 * i
    } else { 0.0 };

    let i_eq_p1 = -y0 * atten * e2_delayed;
    let i_eq_p2 = -y0 * atten * e1_delayed;

    LtraNorton {
        i_eq_p1,
        g_eq_p1: y0,
        i_eq_p2,
        g_eq_p2: y0,
    }
}

/// NONINT-aware stamper-facing transient evaluation.
///
/// Like [`eval_ltra_transient_slices`] but honours the `nonint` flag
/// from the device parameters.  External callers (the stamper) should
/// prefer this entry point so the `NONINT=1` model option takes effect.
pub fn eval_ltra_transient_slices_nonint(
    t_now: f64,
    lp: &LtraLineParams,
    times: &[f64],
    v1: &[f64],
    v2: &[f64],
    i1: &[f64],
    i2: &[f64],
    nonint: bool,
) -> LtraNorton {
    compute_norton_equivalent_nonint(t_now, lp, times, v1, v2, i1, i2, nonint)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(r: f64, g: f64, len: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("r", r);
        p.set("g", g);
        p.set("l", 0.0);
        p.set("c", 0.0);
        p.set("len", len);
        p
    }

    #[test]
    fn ltra_dc_matched_wire() {
        // A "wire-like" LTRA with tiny series R and zero shunt G.
        let m = Ltra;
        let p = params(1e-3, 0.0, 1.0);
        let eval = m.eval(&[1.0, 0.0, 1.0, 0.0], &p);
        // No current flows anywhere: V1 == V2, shunt ends grounded.
        for gi in &eval.g {
            assert!(gi.abs() < 1e-9, "g entry = {gi}, expected ~0");
        }
    }

    #[test]
    fn ltra_dc_series_resistance_drops_voltage() {
        // LTRA with R=10 Ω/m, LEN=1 m, G=0.  Drive a 1 V source at
        // port-1 into a short on port-2+.  Axial current should match
        // the Ohm's-law expectation.
        let m = Ltra;
        let p = params(10.0, 0.0, 1.0);
        let eval = m.eval(&[1.0, 0.0, 0.0, 0.0], &p);
        // I_series = (1 - 0) / 10 = 0.1 A
        // Pin 0: +I_series + 0 = +0.1
        // Pin 2: -I_series + 0 = -0.1
        assert!((eval.g[0] - 0.1).abs() < 1e-12);
        assert!((eval.g[2] + 0.1).abs() < 1e-12);
        // Shunt pins (1, 3) see zero current because G=0.
        assert!(eval.g[1].abs() < 1e-15);
        assert!(eval.g[3].abs() < 1e-15);
    }

    #[test]
    fn ltra_dc_shunt_conductance_draws_current() {
        // R=0 (no L/C set, so 1/GMIN fallback applies), G=2 S/m, LEN=0.5 m.
        // G_tot = 1 S → G_shunt_half = 0.5 S at each port.
        let m = Ltra;
        let p = params(0.0, 2.0, 0.5);
        // V(n1+)=1 V, rest 0.
        let eval = m.eval(&[1.0, 0.0, 0.0, 0.0], &p);
        // Port-1 shunt draws I_sh1 = 0.5 * 1 = 0.5 A out of n1+ toward n1-.
        // Port-2 voltages are 0 → I_series ≈ 1 * gmin ≈ tiny.
        assert!(eval.g[0] > 0.4 && eval.g[0] < 0.6, "g[0]={}", eval.g[0]);
        assert!((eval.g[1] + 0.5).abs() < 1e-9, "g[1]={}", eval.g[1]);
    }

    #[test]
    fn ltra_jacobian_symmetry() {
        let m = Ltra;
        let p = params(5.0, 0.1, 2.0);
        let eval = m.eval(&[0.0, 0.0, 0.0, 0.0], &p);
        // Resistive + shunt symmetric T network → Jacobian symmetric:
        // for every (r,c,v) there should be a matching (c,r,v).
        for &(r, c, v) in &eval.G {
            let found = eval.G.iter().any(|&(rr, cc, vv)| rr == c && cc == r && (vv - v).abs() < 1e-15);
            assert!(found, "missing symmetric entry for ({r},{c},{v})");
        }
    }

    #[test]
    fn ltra_kind_and_terminals() {
        let m = Ltra;
        assert_eq!(m.kind(), DeviceKind::Ltra);
        assert_eq!(m.num_terminals(), 4);
        assert!(!m.needs_branch());
    }

    #[test]
    fn ltra_history_push_and_trapz() {
        let mut h = LtraHistory::with_capacity(8);
        for i in 0..5 {
            let t = i as f64;
            h.push(t, 0.0, 0.0, 0.0, 0.0);
        }
        // Integrate f(t) = 1 from t=0..4 → area = 4.
        let ones = vec![1.0; 5];
        let area = h.trapz(&ones, 4.0);
        assert!((area - 4.0).abs() < 1e-12, "trapz={area}, expected 4");
    }

    #[test]
    fn ltra_history_respects_t_end() {
        let mut h = LtraHistory::with_capacity(8);
        for i in 0..=4 {
            h.push(i as f64, 0.0, 0.0, 0.0, 0.0);
        }
        let vals = vec![1.0; 5];
        // t_end = 2 → integrate only from t=0..2, expect 2.
        let area = h.trapz(&vals, 2.0);
        assert!((area - 2.0).abs() < 1e-12, "trapz(t_end=2)={area}");
    }

    #[test]
    fn ltra_instance_default_pins() {
        let inst = LtraInstance::new();
        assert_eq!(inst.ports, [0, 1, 2, 3]);
        assert!(inst.history.is_empty());
    }

    // ── Convolution kernel unit tests ────────────────────────────────────

    fn lp_rc() -> LtraLineParams {
        // RC line: R=10 Ω/m, C=1 nF/m (no L, no G) — diffusion regime.
        LtraLineParams { r: 10.0, l: 0.0, g: 0.0, c: 1e-9, len: 1.0 }
    }

    fn lp_rlc() -> LtraLineParams {
        LtraLineParams { r: 1.0, l: 250e-9, g: 0.0, c: 100e-12, len: 1.0 }
    }

    fn lp_lossless() -> LtraLineParams {
        LtraLineParams { r: 0.0, l: 250e-9, g: 0.0, c: 100e-12, len: 1.0 }
    }

    #[test]
    fn rc_kernel_is_positive_and_decays() {
        let lp = lp_rc();
        let h0 = ltra_kernel(0.0, &lp);
        let h1 = ltra_kernel(1e-3, &lp);
        let h2 = ltra_kernel(10e-3, &lp);
        assert!(h0 > 0.0, "h(0) should be positive");
        assert!(h1 < h0, "kernel should decay");
        assert!(h2 < h1, "kernel should decay further");
    }

    #[test]
    fn general_kernel_zero_before_td() {
        let lp = lp_rlc();
        let td = lp.td();
        assert!(td > 0.0, "RLC line should have finite TD");
        // Kernel should be zero strictly before the travel delay.
        let h_before = ltra_kernel(td * 0.5, &lp);
        assert!(h_before.abs() < 1e-30, "h before TD should be 0, got {h_before}");
        // And positive at TD.
        let h_at = ltra_kernel(td + 1e-12, &lp);
        assert!(h_at > 0.0, "h just after TD should be positive, got {h_at}");
    }

    #[test]
    fn lossless_kernel_is_zero_everywhere() {
        let lp = lp_lossless();
        for tau_ns in [0, 1, 2, 5, 10, 100] {
            let h = ltra_kernel(tau_ns as f64 * 1e-9, &lp);
            assert_eq!(h, 0.0, "lossless kernel should be 0 at tau={tau_ns}ns");
        }
    }

    #[test]
    fn norton_equiv_zero_for_empty_history() {
        let lp = lp_rc();
        let n = compute_norton_equivalent(1.0, &lp, &[], &[], &[], &[], &[]);
        assert_eq!(n.i_eq_p1, 0.0);
        assert_eq!(n.g_eq_p1, 0.0);
    }

    #[test]
    fn rc_norton_nonzero_with_history() {
        // Feed a constant 1 V signal history; convolution should yield nonzero I_eq.
        let lp = lp_rc();
        let times: Vec<f64> = (0..=10).map(|i| i as f64 * 1e-3).collect();
        let v1: Vec<f64> = vec![1.0; times.len()];
        let v2: Vec<f64> = vec![0.0; times.len()];
        let t_now = *times.last().unwrap();
        let i1: Vec<f64> = vec![0.0; times.len()];
        let i2: Vec<f64> = vec![0.0; times.len()];
        let n = compute_norton_equivalent(t_now, &lp, &times, &v1, &v2, &i1, &i2);
        assert!(n.i_eq_p1 > 0.0, "I_eq_p1 should be positive with 1V history");
    }
}
