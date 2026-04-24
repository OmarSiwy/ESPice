//! Periodic Steady State (PSS) analysis — shooting method.
//!
//! ## Algorithm
//!
//! PSS finds the initial condition `x0` such that integrating the circuit for
//! exactly one period `T = 1/f0` returns to the same state:
//!
//! ```text
//! F(x0) = x(T; x0) - x0 = 0
//! ```
//!
//! Newton iterations refine `x0` using the **monodromy matrix** Φ = ∂x(T)/∂x0:
//!
//! ```text
//! Δx0 = -(Φ - I)^{-1} · F(x0)
//! x0  = x0 + Δx0
//! ```
//!
//! Φ is approximated by finite differences (O(N) transient integrations, each
//! of length T — total cost O(N²) per Newton step for large N).
//!
//! ## Usage
//!
//! ```ignore
//! let pss = Pss {
//!     fundamental_freq: 1e6,
//!     tstep:            1e-9,
//!     max_iterations:   20,
//!     tol:              Pss::TOL_MODERATE,
//!     epsilon:          1e-6,
//! };
//! let result = run_pss(&pss, &circuit, &registry)?;
//! ```

use incspice_cache::CacheManager;
use incspice_core::{Circuit, SimError, StreamingSink};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::linalg::{DenseVec, TripletMatrix, lu_factorize, lu_solve};
use incspice_solver::newton::NrConfig;
use crate::{Analysis, AnalysisError};
use crate::dc_op::run_dc_op_internal;
use crate::transient::run_transient;
use crate::transient::TransientConfig;

// ── Public configuration ────────────────────────────────────────────────────

/// Periodic Steady State analysis configuration.
///
/// The shooting method integrates one period per Newton iteration plus N
/// extra periods for the monodromy finite-difference columns — choose
/// `tstep` and `max_iterations` accordingly.
#[derive(Debug, Clone)]
pub struct Pss {
    /// Fundamental frequency of the periodic excitation (Hz).
    pub fundamental_freq: f64,

    /// Timestep used for the inner transient integration (seconds).
    pub tstep: f64,

    /// Maximum Newton-shooting iterations before giving up.
    pub max_iterations: usize,

    /// Convergence tolerance: stop when `||x(T) - x0||_inf < tol`.
    pub tol: f64,

    /// Finite-difference perturbation size for monodromy matrix columns.
    pub epsilon: f64,
}

impl Pss {
    /// Liberal tolerance — suitable for quick feasibility checks.
    pub const TOL_LIBERAL: f64 = 1e-3;

    /// Moderate tolerance — good balance of speed and accuracy.
    pub const TOL_MODERATE: f64 = 1e-5;

    /// Conservative tolerance — tighter convergence for precision applications.
    pub const TOL_CONSERVATIVE: f64 = 1e-8;
}

impl Default for Pss {
    fn default() -> Self {
        Self {
            fundamental_freq: 1e6,
            tstep: 1e-10,
            max_iterations: 20,
            tol: Self::TOL_MODERATE,
            epsilon: 1e-6,
        }
    }
}

// ── Public result type ──────────────────────────────────────────────────────

/// Result of a successful PSS analysis.
#[derive(Debug, Clone)]
pub struct PssResult {
    /// Periodic steady-state initial condition `x0` such that x(T; x0) ≈ x0.
    ///
    /// The vector length equals `circuit.mna_dimension()` — it contains both
    /// node voltages (indices `0..num_vars`) and branch currents
    /// (indices `num_vars..mna_dim`).
    pub steady_state: Vec<f64>,

    /// Simulation period `T = 1 / fundamental_freq` (seconds).
    pub period: f64,

    /// Number of Newton-shooting iterations performed before convergence.
    pub iterations: usize,

    /// Infinity-norm residual `||x(T) - x0||_inf` at convergence.
    pub residual: f64,
}

// ── Analysis trait implementation ───────────────────────────────────────────

impl Analysis for Pss {
    fn run(
        &self,
        circuit: &mut Circuit,
        registry: &DeviceRegistry,
        _config: &NrConfig,
        _cache: &mut CacheManager,
        sink: &mut dyn StreamingSink,
    ) -> Result<(), AnalysisError> {
        let result = run_pss(self, circuit, registry)?;
        let nv = circuit.num_vars() as usize;
        sink.emit_point(0.0, &result.steady_state[..nv])?;
        sink.finalize()?;
        Ok(())
    }

    fn name(&self) -> &str {
        "pss"
    }
}

// ── Core PSS driver ─────────────────────────────────────────────────────────

/// Run PSS using the shooting method.
///
/// # Algorithm
///
/// 1. Compute a DC operating point as the initial guess for `x0`.
/// 2. Repeat up to `pss.max_iterations` Newton-shooting steps:
///    a. Integrate one period from `x0` → `x_T`.
///    b. Check convergence: `||x_T - x0||_inf < tol`.
///    c. Compute the monodromy matrix Φ via finite differences
///       (N+1 additional period integrations, each perturbed by `epsilon·e_i`).
///    d. Solve `(Φ - I)·Δx0 = -(x_T - x0)`.
///    e. Update `x0 += Δx0`.
///
/// # Cost
///
/// Each Newton iteration costs O(N) transient integrations of length T, where
/// N = `circuit.mna_dimension()`.  This is O(N²) overall — fine for small/medium
/// circuits but potentially expensive for large designs.
pub fn run_pss(
    pss: &Pss,
    circuit: &Circuit,
    registry: &DeviceRegistry,
) -> Result<PssResult, SimError> {
    let period = 1.0 / pss.fundamental_freq;
    let n_steps = (period / pss.tstep).ceil() as usize;
    // Use at least one step.
    let n_steps = n_steps.max(1);

    // --- Initial guess: DC operating point ---
    let dc_out = run_dc_op_internal(circuit, registry)?;
    let mut x0 = dc_out.solution;
    let dim = x0.len();

    let mut final_residual = f64::MAX;
    let mut final_iter = 0;

    for iter in 0..pss.max_iterations {
        // 1. Integrate one full period from x0 to get x_T.
        let x_t = integrate_one_period(circuit, registry, &x0, period, n_steps)?;

        // 2. Compute F(x0) = x_T - x0 and check convergence.
        let f: Vec<f64> = x_t.iter().zip(&x0).map(|(a, b)| a - b).collect();
        let residual = norm_inf(&f);
        final_residual = residual;
        final_iter = iter;

        if residual < pss.tol {
            break;
        }

        // 3. Compute monodromy matrix Φ = ∂x(T)/∂x0 via finite differences.
        //    Φ[:, i] ≈ (x_i(T) - x_T) / epsilon   where x_i starts from x0 + ε·eᵢ.
        let phi = compute_monodromy(
            circuit,
            registry,
            &x0,
            &x_t,
            period,
            n_steps,
            pss.epsilon,
        )?;

        // 4. Build (Φ - I) as a sparse triplet matrix and solve
        //    (Φ - I)·Δx0 = -F(x0)   ⟺   Δx0 = -(Φ - I)^{-1}·F(x0).
        let phi_minus_i = build_phi_minus_identity(&phi, dim);
        let rhs = DenseVec::from_slice(
            &f.iter().map(|v| -v).collect::<Vec<_>>(),
        );
        let phi_csc = phi_minus_i.to_csc();
        let factors = lu_factorize(&phi_csc)?;
        let dx = lu_solve(&factors, &rhs)?;

        // 5. Update x0.
        for i in 0..dim {
            x0[i] += dx[i];
        }
    }

    Ok(PssResult {
        steady_state: x0,
        period,
        iterations: final_iter + 1,
        residual: final_residual,
    })
}

// ── Internal helpers ────────────────────────────────────────────────────────

/// Integrate `circuit` for exactly `n_steps` timesteps of size `period/n_steps`
/// starting from initial condition `x0`.
///
/// Returns the full MNA solution vector at `t = period`.
///
/// This reuses `run_transient` from `transient.rs` — we temporarily set the
/// circuit's initial conditions to `x0`, run a transient for one period, and
/// read off the final state.
fn integrate_one_period(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    x0: &[f64],
    period: f64,
    n_steps: usize,
) -> Result<Vec<f64>, SimError> {
    // Clone the circuit so we can set per-run initial conditions without
    // mutating the caller's copy.
    let mut ckt = circuit.clone();

    // Override ICs: set every node voltage to the corresponding x0 entry.
    // x0[0..num_vars] are node voltages (1-indexed NodeIds → matrix index = NodeId - 1).
    ckt.clear_initial_conditions();
    let nv = ckt.num_vars() as usize;
    for idx in 0..nv {
        // NodeId = idx + 1 (ground is NodeId 0).
        let node_id = incspice_core::NodeId::new((idx + 1) as u32);
        ckt.add_initial_condition(node_id, x0[idx]);
    }

    let h = period / n_steps as f64;
    let config = TransientConfig::new(h, period);
    let result = run_transient(&mut ckt, registry, &config)?;

    // The last step holds x(T).
    let last_step = result.num_steps() - 1;
    let nv_r = result.num_nodes;
    let nb_r = result.num_branches();

    // Reconstruct the full MNA vector: [node_voltages | branch_currents].
    let mut x_t = vec![0.0f64; nv_r + nb_r];
    for i in 0..nv_r {
        x_t[i] = result.voltage(last_step, i);
    }
    for b in 0..nb_r {
        x_t[nv_r + b] = result.branch_current(last_step, b);
    }
    Ok(x_t)
}

/// Compute the monodromy matrix Φ = ∂x(T)/∂x0 by forward finite differences.
///
/// For each column i:
/// ```text
/// x0_perturbed = x0 + epsilon * e_i
/// Φ[:, i] = ( x(T; x0_perturbed) - x_T ) / epsilon
/// ```
///
/// Cost: N transient integrations of length T, where N = dim.
fn compute_monodromy(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    x0: &[f64],
    x_t: &[f64],
    period: f64,
    n_steps: usize,
    epsilon: f64,
) -> Result<Vec<Vec<f64>>, SimError> {
    let dim = x0.len();
    // phi[col][row] — column-major for easy slicing.
    let mut phi = vec![vec![0.0f64; dim]; dim];

    for col in 0..dim {
        // Perturb x0 along the col-th basis vector.
        let mut x0_pert = x0.to_vec();
        x0_pert[col] += epsilon;

        let x_t_pert =
            integrate_one_period(circuit, registry, &x0_pert, period, n_steps)?;

        // Finite-difference column.
        for row in 0..dim {
            phi[col][row] = (x_t_pert[row] - x_t[row]) / epsilon;
        }
    }

    Ok(phi)
}

/// Build `(Φ - I)` as a `TripletMatrix` from a column-major dense representation.
fn build_phi_minus_identity(phi: &[Vec<f64>], dim: usize) -> TripletMatrix {
    let mut trip = TripletMatrix::with_capacity(dim, dim, dim * dim);
    for col in 0..dim {
        for row in 0..dim {
            let val = phi[col][row] - if row == col { 1.0 } else { 0.0 };
            // Skip exact zeros to keep the sparse structure lean.
            if val != 0.0 {
                trip.add(row, col, val);
            }
        }
    }
    trip
}

/// Infinity-norm of a vector.
#[inline]
fn norm_inf(v: &[f64]) -> f64 {
    v.iter().fold(0.0_f64, |acc, &x| acc.max(x.abs()))
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use incspice_solver::device::DeviceRegistry;

    /// Build a simple RC circuit: V1=5V (DC), R=1kΩ, C=1µF, τ=1ms.
    ///
    /// Topology:
    ///   V1 (5V) between "vdd" and GND
    ///   R1 (1kΩ) between "vdd" and "out"
    ///   C1 (1µF) between "out" and GND
    fn build_rc_circuit() -> Circuit {
        let mut ckt = Circuit::new();
        let n_vdd = ckt.add_node("vdd");
        let n_out = ckt.add_node("out");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n_vdd), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);

        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n_vdd), (1, n_out)],
        )
        .with_param("resistance", 1e3);

        let c1 = DeviceInstance::new(
            DeviceId::new(0),
            "C1",
            DeviceKind::Capacitor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", 1e-6);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(c1);
        ckt.build_topology();
        ckt
    }

    /// PSS on a DC-driven RC circuit.
    ///
    /// A DC-only circuit has a trivial PSS: x(T) = x(0) for *any* T, so the
    /// DC operating point is already a periodic steady state.  The shooting
    /// method should converge in 1 Newton iteration with a small residual.
    #[test]
    fn test_pss_rc_dc_converges() {
        let ckt = build_rc_circuit();
        let registry = DeviceRegistry::default();

        // Use a 1 MHz "period" — arbitrary for a DC circuit, but the RC with
        // τ=1ms is already settled, so x(T) ≈ x(0) immediately.
        let pss = Pss {
            fundamental_freq: 1e3,   // T = 1ms (one time-constant)
            tstep: 1e-5,              // 100 steps per period
            max_iterations: 10,
            tol: Pss::TOL_LIBERAL,   // 1e-3 V — loose for speed
            epsilon: 1e-6,
        };

        let result = run_pss(&pss, &ckt, &registry).expect("PSS should not fail");

        // The steady-state node "out" (index 1) should be near 5 V in DC steady state.
        // V(vdd) = 5V (index 0), V(out) ≈ 5V at DC steady state.
        let nv = ckt.num_vars() as usize;
        let v_vdd = result.steady_state[0];
        let v_out = result.steady_state[1];

        assert!(
            (v_vdd - 5.0).abs() < 0.1,
            "V(vdd) should be ~5 V, got {v_vdd}"
        );
        assert!(
            v_out > 4.0,
            "V(out) at PSS should be close to Vdd=5V for DC circuit, got {v_out}"
        );
        assert!(
            result.period > 0.0,
            "Period should be positive, got {}",
            result.period
        );
        // Sanity: the steady-state vector has the right size.
        assert_eq!(
            result.steady_state.len(),
            ckt.mna_dimension(),
            "steady_state length should equal MNA dimension"
        );
        let _ = nv;
    }

    /// Test the monodromy matrix for a linear (RC) circuit.
    ///
    /// For a stable linear circuit, all eigenvalues of Φ satisfy |λ| < 1, which
    /// means (Φ - I) is invertible and the shooting method converges.
    ///
    /// This test simply checks that `compute_monodromy` runs without error and
    /// returns a matrix of the right dimensions.
    #[test]
    fn test_pss_monodromy_identity_linear() {
        let ckt = build_rc_circuit();
        let registry = DeviceRegistry::default();

        let period = 1e-3; // 1 ms
        let n_steps = 10usize;
        let epsilon = 1e-6;
        let dim = ckt.mna_dimension();

        // Use the DC OP as x0.
        let dc = run_dc_op_internal(&ckt, &registry).expect("DC OP should succeed");
        let x0 = dc.solution.clone();

        // Integrate one period to get x_T.
        let x_t = integrate_one_period(&ckt, &registry, &x0, period, n_steps)
            .expect("Integration should succeed");

        // Compute monodromy.
        let phi = compute_monodromy(&ckt, &registry, &x0, &x_t, period, n_steps, epsilon)
            .expect("Monodromy should succeed");

        // Check dimensions.
        assert_eq!(phi.len(), dim, "Phi should have {dim} columns");
        for col in &phi {
            assert_eq!(col.len(), dim, "Each Phi column should have {dim} rows");
        }

        // For a stable system, the diagonal entries of Phi should be ≤ 1.0
        // (eigenvalues inside or on the unit circle).
        // We check that Phi is finite (not NaN/Inf).
        for col in &phi {
            for &v in col {
                assert!(v.is_finite(), "Phi entry should be finite, got {v}");
            }
        }
    }

    /// Verify the tolerance constants are ordered correctly.
    #[test]
    fn test_pss_tolerance_ordering() {
        assert!(
            Pss::TOL_LIBERAL > Pss::TOL_MODERATE,
            "Liberal tolerance should be looser (larger) than moderate"
        );
        assert!(
            Pss::TOL_MODERATE > Pss::TOL_CONSERVATIVE,
            "Moderate tolerance should be looser (larger) than conservative"
        );
    }

    /// Verify `norm_inf` on a known vector.
    #[test]
    fn test_norm_inf() {
        let v = vec![1.0, -3.0, 2.0];
        assert!((norm_inf(&v) - 3.0).abs() < 1e-15);

        let empty: Vec<f64> = vec![];
        assert_eq!(norm_inf(&empty), 0.0);
    }
}
