//! Simulation options carried from `.OPTIONS` through the solver stack.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntegrationMethod {
    Trap,
    Gear,
    Be,
}

/// Output rawfile format — set via `.OPTIONS FILETYPE=ASCII` or
/// `.OPTIONS RAWFMT=ASCII`.  Default is binary (native-endian f64 stream)
/// which is what ngspice produces; ASCII is useful for diffing and for
/// waveform viewers that do not support the binary format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RawFmt {
    #[default]
    Binary,
    Ascii,
}

impl Default for IntegrationMethod {
    fn default() -> Self {
        IntegrationMethod::Trap
    }
}

#[derive(Debug, Clone)]
pub struct SimOptions {
    // Tolerances
    pub abstol: f64,
    pub reltol: f64,
    pub vntol: f64,
    pub chgtol: f64,
    pub pivtol: f64,
    pub pivrel: f64,
    // Solver
    pub gmin: f64,
    pub itl1: usize,
    pub itl2: usize,
    /// ITL3: lower limit on Newton iterations before timestep increase (transient).
    /// When the Newton solver converges in fewer than `itl3` iterations the
    /// timestep predictor may increase the step.  Default 4 (ngspice value).
    pub itl3: usize,
    pub itl4: usize,
    pub itl5: usize,
    /// ITL6 / SRCSTEPS: number of uniform source-stepping intervals.
    /// When > 0 the solver ramps all independent sources from 0 to nominal
    /// in `itl6` equal steps (λ = k/itl6, k = 1..itl6).  On failure the
    /// step size is halved (bisection) down to a minimum of 1 step.
    /// 0 means "use the built-in adaptive schedule" (default behaviour).
    pub itl6: usize,
    /// GMINSTEPS: number of geometric GMIN-stepping intervals.
    /// 0 means use the built-in schedule (initial=1e-2 → final=1e-12,
    /// half-decade reduction factor).  Setting a positive value overrides
    /// the number of steps while keeping the same initial/final values.
    pub gminsteps: usize,
    /// RAMPTIME: source ramp time [s] for smooth startup.
    /// When > 0 all independent sources are linearly ramped from 0 to their
    /// nominal values over `ramptime` seconds at the start of the simulation.
    /// 0.0 = disabled (default).
    pub ramptime: f64,
    /// HOMOTOPY: enable pseudo-arc-length continuation when all other
    /// convergence aids fail (or as the first method when = 1).
    /// Activated by `.OPTIONS HOMOTOPY=1`.
    pub homotopy: bool,
    /// ACCT: print accounting (CPU time, iteration counts) at end of simulation.
    pub acct: bool,
    // Integration
    pub method: IntegrationMethod,
    pub maxord: u8,
    pub trtol: f64,
    // Temperature (Kelvin)
    pub temp: f64,
    pub tnom: f64,
    // Limits
    pub vnstep: f64,
    // Output control
    /// NUMDGT: number of significant digits in output (default 4).
    pub numdgt: usize,
    /// LIMPTS: maximum number of output data points (0 = unlimited).
    pub limpts: usize,
    /// Output rawfile format (ASCII or Binary).  Controlled by
    /// `.OPTIONS FILETYPE=ASCII` / `.OPTIONS RAWFMT=ASCII`.
    pub raw_fmt: RawFmt,
    // Scaling
    /// SCALE: global element scale factor — all R, C, L values are multiplied
    /// by this before stamping into the MNA matrix.  Default 1.0.
    pub scale: f64,
    // MOSFET defaults
    /// DEFAD: default MOSFET drain diffusion area [m²].  Applied when the
    /// instance line omits the `AD` parameter.
    pub defad: f64,
    /// DEFAS: default MOSFET source diffusion area [m²].
    pub defas: f64,
    /// DEFL: default MOSFET channel length [m].
    pub defl: f64,
    /// DEFW: default MOSFET channel width [m].
    pub defw: f64,
    // Debug
    /// KEEPOPINFO: when true, the DC operating-point results are preserved in
    /// the output alongside the primary analysis results.
    pub keepopinfo: bool,
    // Linear solver selection
    /// Which linear solver to use.  Set via `.OPTIONS SOLVER=KLU` or
    /// `.LINSOL KLU`.  Defaults to the built-in sparse LU.
    pub lin_solver: LinSolverChoice,
    /// Xyce-style linear solver kind (`.OPTIONS LINSOL solver=KLU`).
    /// Mirrors `lin_solver` but uses the three-way [`LinSolverKind`] enum
    /// which also includes the `Dense` fallback option.
    pub linsol_kind: LinSolverKind,
}

/// Which linear solver backend to use.
///
/// This enum lives in `bigospice-core` (no dependency on `bigospice-linalg`) so it
/// can be carried in [`SimOptions`] and threaded through the solver stack
/// without creating a circular dependency.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LinSolverChoice {
    /// Built-in sparse LU with AMD ordering (default).
    #[default]
    SparseLu,
    /// SuiteSparse KLU — BTF + AMD + Gilbert-Peierls LU.
    Klu,
}

/// Linear solver kind — Xyce-style three-way selection used by the
/// `.OPTIONS LINSOL solver=...` category dispatch.
///
/// Complements [`LinSolverChoice`] by adding a `Dense` fallback (small
/// circuits where a direct dense LU is faster than sparse factorization).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LinSolverKind {
    /// Built-in sparse LU (default).
    #[default]
    Sparse,
    /// SuiteSparse KLU — BTF + AMD + Gilbert-Peierls LU.
    Klu,
    /// Dense LU — only practical for very small circuits (< ~200 nodes).
    Dense,
}

// ---------------------------------------------------------------------------
// Reliability/Aging (.ROL) configuration — W.4
// ---------------------------------------------------------------------------

/// Configuration for a `.ROL` reliability/aging analysis.
///
/// Lives in `bigospice-core` so the parser can populate it without depending on
/// `bigospice-analysis`.  The analysis crate re-exports this type.
#[derive(Debug, Clone)]
pub struct RolConfig {
    /// Operating lifetime [s].  Default: 3.15e9 s (≈ 100 years).
    pub lifetime: f64,
    /// Junction temperature [K].  Default: 358.15 K (85 °C).
    pub temp: f64,
    /// Enable electromigration (EM) analysis.
    pub em_enabled: bool,
    /// Enable NBTI analysis (pMOS Vth shift).
    pub nbti_enabled: bool,
    /// Enable HCI analysis (nMOS Id degradation, stub).
    pub hci_enabled: bool,
}

impl Default for RolConfig {
    fn default() -> Self {
        Self {
            lifetime: 3.15e9,
            temp: 358.15,
            em_enabled: true,
            nbti_enabled: true,
            hci_enabled: false,
        }
    }
}

impl Default for SimOptions {
    fn default() -> Self {
        Self {
            abstol: 1e-12,
            reltol: 1e-3,
            vntol: 1e-6,
            chgtol: 1e-14,
            pivtol: 1e-13,
            pivrel: 1e-3,
            gmin: 1e-12,
            itl1: 100,
            itl2: 50,
            itl3: 4,
            itl4: 10,
            itl5: 5000,
            itl6: 0,
            gminsteps: 0,
            ramptime: 0.0,
            homotopy: false,
            acct: false,
            method: IntegrationMethod::Trap,
            maxord: 2,
            trtol: 7.0,
            temp: 300.15,
            tnom: 300.15,
            vnstep: 5.0,
            numdgt: 4,
            limpts: 0,
            raw_fmt: RawFmt::Binary,
            scale: 1.0,
            defad: 0.0,
            defas: 0.0,
            defl: 100e-9,
            defw: 1e-6,
            keepopinfo: false,
            lin_solver: LinSolverChoice::SparseLu,
            linsol_kind: LinSolverKind::Sparse,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_values_match_ngspice() {
        let opts = SimOptions::default();
        assert_eq!(opts.abstol, 1e-12);
        assert_eq!(opts.reltol, 1e-3);
        assert_eq!(opts.vntol, 1e-6);
        assert_eq!(opts.chgtol, 1e-14);
        assert_eq!(opts.pivtol, 1e-13);
        assert_eq!(opts.pivrel, 1e-3);
        assert_eq!(opts.gmin, 1e-12);
        assert_eq!(opts.itl1, 100);
        assert_eq!(opts.itl2, 50);
        assert_eq!(opts.itl3, 4);
        assert_eq!(opts.itl4, 10);
        assert_eq!(opts.itl5, 5000);
        assert_eq!(opts.itl6, 0);
        assert_eq!(opts.gminsteps, 0);
        assert_eq!(opts.ramptime, 0.0);
        assert!(!opts.homotopy);
        assert!(!opts.acct);
        assert_eq!(opts.maxord, 2);
        assert_eq!(opts.trtol, 7.0);
        assert_eq!(opts.temp, 300.15);
        assert_eq!(opts.tnom, 300.15);
        assert_eq!(opts.vnstep, 5.0);
        assert_eq!(opts.numdgt, 4);
        assert_eq!(opts.limpts, 0);
        assert_eq!(opts.scale, 1.0);
        assert_eq!(opts.defad, 0.0);
        assert_eq!(opts.defas, 0.0);
        assert_eq!(opts.defl, 100e-9);
        assert_eq!(opts.defw, 1e-6);
        assert!(!opts.keepopinfo);
    }

    #[test]
    fn clone_works() {
        let opts = SimOptions::default();
        let cloned = opts.clone();
        assert_eq!(cloned.abstol, opts.abstol);
        assert_eq!(cloned.reltol, opts.reltol);
        assert_eq!(cloned.gmin, opts.gmin);
    }

    #[test]
    fn integration_method_default_is_trap() {
        assert_eq!(IntegrationMethod::default(), IntegrationMethod::Trap);
        let opts = SimOptions::default();
        assert_eq!(opts.method, IntegrationMethod::Trap);
    }

    #[test]
    fn new_fields_have_correct_defaults() {
        let opts = SimOptions::default();
        assert_eq!(opts.itl3, 4);
        assert_eq!(opts.ramptime, 0.0);
        assert!(!opts.acct);
        assert_eq!(opts.numdgt, 4);
        assert_eq!(opts.limpts, 0);
        assert_eq!(opts.raw_fmt, RawFmt::Binary);
        assert_eq!(opts.scale, 1.0);
        assert_eq!(opts.defad, 0.0);
        assert_eq!(opts.defas, 0.0);
        assert_eq!(opts.defl, 100e-9);
        assert_eq!(opts.defw, 1e-6);
        assert!(!opts.keepopinfo);
    }
}
