//! Periodic Steady-State (`.PSS`) analysis — Wave Q.2.
//!
//! Finds the periodic steady-state of circuits with periodic forcing via the
//! **shooting method**:
//!
//! 1. Start from an initial-condition vector `x₀`.
//! 2. Integrate forward one period `T = 1/fund` using the transient engine.
//! 3. Form the shooting residual `F(x₀) = x(T) − x₀`.
//! 4. Iterate with Newton-Raphson until `||F||∞ < tol`.
//!
//! The monodromy matrix (Jacobian of the shooting map) is approximated by
//! finite-differences: each column `j` is `(x(T)|x₀+ε·eⱼ − x(T)|x₀) / ε`.
//! This is O(n) transient runs per NR step — adequate for circuits up to a few
//! hundred nodes.  A future revision can plug in an analytic sensitivity
//! propagation without changing the public API.
//!
//! ## Usage
//!
//! ```no_run
//! use pisim_analysis::pss::{PssConfig, run_pss};
//! use pisim_core::Circuit;
//! use pisim_device::DeviceRegistry;
//!
//! let mut ckt = Circuit::new();
//! // ... build circuit ...
//! let reg = DeviceRegistry::new_default();
//! let cfg = PssConfig::new(1e6, 10);        // 1 MHz fundamental, 10 harmonics
//! let result = run_pss(&mut ckt, &reg, &cfg).unwrap();
//! assert!(result.converged);
//! ```
//!
//! ## SoA layout
//!
//! [`PssResult`] stores the periodic waveform in a flat row-major buffer
//! `waveforms[step * num_nodes + node]`, consistent with [`TransientResult`].

use pisim_core::{Circuit, SimError};
use pisim_device::DeviceRegistry;
use pisim_linalg::{DenseVec, LinSolver, LinSolverKind, TripletMatrix};

use crate::transient::{run_transient, IntegrationMethod, TransientConfig};
use crate::result::TransientResult;

// ---------------------------------------------------------------------------
// Public configuration
// ---------------------------------------------------------------------------

/// Error preset matching SPICE tool conventions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrPreset {
    Liberal,
    Moderate,
    Conservative,
}

impl ErrPreset {
    fn tol(self) -> f64 {
        match self {
            ErrPreset::Liberal => 1e-4,
            ErrPreset::Moderate => 1e-6,
            ErrPreset::Conservative => 1e-9,
        }
    }
}

/// Configuration for PSS analysis.
///
/// Corresponds to the `.PSS` directive:
/// ```spice
/// .PSS fund=1e6 nharm=10 errpreset=moderate
/// ```
#[derive(Debug, Clone)]
pub struct PssConfig {
    /// Fundamental frequency (Hz).  Period `T = 1 / fund`.
    pub fund: f64,
    /// Number of harmonics to resolve in the output spectrum.
    /// Controls the time-grid density: `tstep = T / (2*nharm + 1)`.
    pub nharm: usize,
    /// Convergence tolerance on the shooting residual (infinity-norm).
    pub tol: f64,
    /// Maximum Newton-Raphson shooting iterations.
    pub max_iter: usize,
    /// Finite-difference perturbation for monodromy-matrix columns.
    pub fd_eps: f64,
    /// Integration method passed to the transient engine.
    pub method: IntegrationMethod,
}

impl PssConfig {
    /// Construct with fundamental frequency and harmonic count; all other
    /// fields take sensible defaults.
    pub fn new(fund: f64, nharm: usize) -> Self {
        Self {
            fund,
            nharm,
            tol: ErrPreset::Moderate.tol(),
            max_iter: 20,
            fd_eps: 1e-6,
            method: IntegrationMethod::BackwardEuler,
        }
    }

    /// Override the error preset.
    pub fn with_errpreset(mut self, preset: ErrPreset) -> Self {
        self.tol = preset.tol();
        self
    }

    /// Number of time-domain samples per period.
    fn n_time(&self) -> usize {
        2 * self.nharm + 1
    }

    /// Timestep for the transient sub-solver.
    fn tstep(&self) -> f64 {
        1.0 / (self.fund * self.n_time() as f64)
    }

    /// Full period `T = 1 / fund`.
    fn period(&self) -> f64 {
        1.0 / self.fund
    }
}

// ---------------------------------------------------------------------------
// Public result type
// ---------------------------------------------------------------------------

/// Result of a PSS analysis.
#[derive(Debug, Clone)]
pub struct PssResult {
    /// Whether the Newton loop converged within `max_iter`.
    pub converged: bool,
    /// Number of outer Newton iterations consumed.
    pub iterations: usize,
    /// Shooting-residual infinity-norm at the final iterate.
    pub final_residual: f64,
    /// Time grid over one period: `n_time` evenly spaced points in `[0, T)`.
    pub times: Vec<f64>,
    /// Periodic waveform — flat row-major: `waveforms[step * num_nodes + node]`.
    pub waveforms: Vec<f64>,
    /// Number of node-voltage unknowns (width of `waveforms`).
    pub num_nodes: usize,
}

impl PssResult {
    /// Access the periodic steady-state voltage at timestep `step`, node `node`.
    #[inline]
    pub fn voltage(&self, step: usize, node: usize) -> f64 {
        self.waveforms[step * self.num_nodes + node]
    }

    /// Number of time samples per period.
    #[inline]
    pub fn num_steps(&self) -> usize {
        self.times.len()
    }
}

// ---------------------------------------------------------------------------
// Core shooting-method engine
// ---------------------------------------------------------------------------

/// Run a PSS analysis using the shooting method.
///
/// The circuit is mutated during the transient sub-solves but restored to its
/// initial state (via the immutable `config`) before each solve.
pub fn run_pss(
    circuit: &mut Circuit,
    registry: &DeviceRegistry,
    config: &PssConfig,
) -> Result<PssResult, SimError> {
    if config.fund <= 0.0 {
        return Err(SimError::Analysis("PSS: fund must be positive".into()));
    }
    if config.nharm == 0 {
        return Err(SimError::Analysis("PSS: nharm must be >= 1".into()));
    }

    let num_nodes = circuit.num_vars() as usize;
    let n_state = circuit.mna_dimension(); // full MNA size (nodes + branches)
    let period = config.period();
    let tstep = config.tstep();

    // Transient sub-solve config: one full period, starting from UIC.
    let tran_cfg = TransientConfig {
        tstep,
        tstop: period,
        method: config.method,
        uic: true,
    };

    // Initial x₀: start from the DC operating point.
    // We call the solver once to warm-start the shooting.
    use pisim_solver::{Solver, SolverConfig, NrConfig};
    let solver = Solver::default();
    let dc = solver.solve(circuit, registry, None)?;
    let mut x0: Vec<f64> = dc.solution.clone();
    // Pad / truncate to n_state if the DC result has a different length.
    x0.resize(n_state, 0.0);

    let mut iter = 0usize;
    let mut converged = false;
    let mut final_residual = f64::INFINITY;

    loop {
        if iter >= config.max_iter {
            break;
        }
        iter += 1;

        // ── (a) Shoot: integrate one period from x₀ ─────────────────────
        inject_ic(circuit, &x0, num_nodes);
        let tran = run_transient(circuit, registry, &tran_cfg)?;
        let x_t = extract_final_state(&tran, n_state);

        // ── (b) Shooting residual F = x(T) − x₀ ─────────────────────────
        let mut f_vec: Vec<f64> = x_t.iter().zip(x0.iter()).map(|(xt, x)| xt - x).collect();

        final_residual = f_vec.iter().map(|v| v.abs()).fold(0.0_f64, f64::max);
        if final_residual < config.tol {
            converged = true;
            break;
        }

        // ── (c) Monodromy matrix Φ = ∂x(T)/∂x₀ via finite differences ──
        // Each column j: shoot with x₀ + ε·eⱼ, compute (x(T)ʲ − x(T)) / ε.
        let eps = config.fd_eps;
        let mut mono = TripletMatrix::with_capacity(n_state, n_state, n_state * 4);
        // Diagonal entries will be overwritten; initialise as identity − I
        // correction is applied after FD columns are accumulated.

        for j in 0..n_state {
            let mut x0_pert = x0.clone();
            x0_pert[j] += eps;
            inject_ic(circuit, &x0_pert, num_nodes);
            let tran_j = run_transient(circuit, registry, &tran_cfg)?;
            let x_tj = extract_final_state(&tran_j, n_state);

            for i in 0..n_state {
                let phi_ij = (x_tj[i] - x_t[i]) / eps;
                // Store Φ[i,j]; after full construction we form J = Φ − I.
                mono.add(i, j, phi_ij);
            }
        }

        // J = Φ − I  (Jacobian of the shooting residual F = x(T) − x₀)
        for k in 0..n_state {
            mono.add(k, k, -1.0);
        }

        // ── (d) Solve J · Δx₀ = −F ─────────────────────────────────────
        let mut neg_f = DenseVec::zeros(n_state);
        for (dst, &v) in neg_f.as_mut_slice().iter_mut().zip(f_vec.iter()) {
            *dst = -v;
        }

        let csc = mono.to_csc();
        let lin = LinSolver::factorize(LinSolverKind::SparseLu, &csc)
            .map_err(|_| SimError::Analysis("PSS: singular monodromy matrix".into()))?;
        let dx0 = lin.solve(&neg_f)?;

        // ── (e) Update x₀ ────────────────────────────────────────────────
        for (x, &dx) in x0.iter_mut().zip(dx0.as_slice().iter()) {
            *x += dx;
        }
    }

    // Final accepted waveform: shoot one more time from the converged x₀.
    inject_ic(circuit, &x0, num_nodes);
    let final_tran = run_transient(circuit, registry, &tran_cfg)?;

    let times = final_tran.times.clone();
    let n_steps = times.len();
    // Build the waveform flat buffer from the transient result.
    let waveforms: Vec<f64> = (0..n_steps)
        .flat_map(|step| (0..num_nodes).map(move |nd| final_tran.voltage(step, nd)))
        .collect();

    Ok(PssResult {
        converged,
        iterations: iter,
        final_residual,
        times,
        waveforms,
        num_nodes,
    })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Overwrite the `.IC` initial conditions on the circuit from a state vector.
///
/// Only the first `num_nodes` entries are node voltages; branch current rows
/// (beyond `num_nodes`) are ignored because the transient solver re-derives
/// them from Kirchhoff.
fn inject_ic(circuit: &mut Circuit, x0: &[f64], num_nodes: usize) {
    circuit.clear_initial_conditions();
    for (nd, node) in circuit.nodes().iter().enumerate().take(num_nodes) {
        if let Some(idx) = node.matrix_index {
            let v = x0.get(idx as usize).copied().unwrap_or(0.0);
            circuit.set_initial_condition(node.id, v);
        } else if nd < x0.len() {
            circuit.set_initial_condition(node.id, x0[nd]);
        }
    }
}

/// Extract the final (last timestep) state vector from a transient result,
/// padded/truncated to `n_state` entries.
fn extract_final_state(tran: &TransientResult, n_state: usize) -> Vec<f64> {
    let last = tran.num_steps().saturating_sub(1);
    let mut out = Vec::with_capacity(n_state);
    for nd in 0..n_state.min(tran.num_nodes) {
        out.push(tran.voltage(last, nd));
    }
    out.resize(n_state, 0.0);
    out
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use pisim_core::{DeviceId, DeviceInstance, DeviceKind, NodeId};
    use pisim_device::DeviceRegistry;

    /// Very simple test: PSS of a purely resistive circuit driven by a DC
    /// source — the steady state is just the DC OP, so x(T) = x₀ = DC
    /// solution and the shooting residual should already be zero (or very
    /// small) on the very first iterate.
    #[test]
    fn pss_resistor_dc_converges_immediately() {
        let mut ckt = pisim_core::Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "V1",
                DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)],
            )
            .with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)],
            )
            .with_param("resistance", 1000.0),
        );
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let cfg = PssConfig::new(1e6, 4);
        let result = run_pss(&mut ckt, &reg, &cfg).unwrap();

        assert!(result.converged, "PSS did not converge");
        assert!(result.final_residual < 1e-4,
            "residual = {}", result.final_residual);
        // The steady-state voltage on node 1 must be ~5 V.
        for step in 0..result.num_steps() {
            let v = result.voltage(step, 0);
            assert!((v - 5.0).abs() < 0.1, "step {step}: V(1) = {v}");
        }
    }

    #[test]
    fn pss_config_defaults() {
        let cfg = PssConfig::new(1e6, 10);
        assert_eq!(cfg.fund, 1e6);
        assert_eq!(cfg.nharm, 10);
        assert!(cfg.tol > 0.0);
        assert!(cfg.max_iter > 0);
        // tstep = T / (2*nharm + 1) = 1e-6 / 21
        let expected_tstep = 1e-6 / 21.0;
        assert!((cfg.tstep() - expected_tstep).abs() < 1e-20);
    }

    #[test]
    fn pss_errpreset_override() {
        let cfg = PssConfig::new(1e6, 5).with_errpreset(ErrPreset::Conservative);
        assert!((cfg.tol - 1e-9).abs() < 1e-20);
    }
}
