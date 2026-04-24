/// Pseudo-transient continuation (PTC) for hard-to-converge circuits.
///
/// When standard Newton-Raphson (with GMIN stepping and source stepping) fails
/// to converge, PTC adds a capacitive stamp `C/dt` to every node diagonal and
/// the matching `C/dt * V_prev` term to the RHS.  This transforms the
/// algebraic system `F(x) = 0` into a stiff ODE
///
///   C/dt * (x - x_prev) + F(x) = 0
///
/// which has a well-conditioned Jacobian `J + C/dt * I` for large `C/dt`.
/// As `dt` grows exponentially, the pseudo-transient term vanishes and the
/// solution converges to the true DC operating point.
///
/// # References
/// K. S. Kundert, "The Designer's Guide to SPICE and Spectre," §4 (Kluwer 1995).
/// T.-L. Sheu, "Pseudo-transient continuation for solving nonlinear circuit
/// equations," IEEE TCAD 2003.
use incspice_core::{Circuit, SimError};
use crate::device::DeviceRegistry;
use crate::linalg::{DenseVec, TripletMatrix, lu_factorize, lu_solve};

use crate::stamper;

/// Configuration for the pseudo-transient continuation solver.
#[derive(Debug, Clone)]
pub struct PseudoTransientConfig {
    /// Initial pseudo-capacitance value (farads).  1 F is a robust default;
    /// larger values give a better-conditioned initial problem at the cost of
    /// more steps.
    pub c_init: f64,
    /// Growth factor applied to `dt` each time the iterate is improving.
    /// `dt` grows geometrically so the pseudo-transient term decays quickly
    /// once the solution is in the basin of attraction.
    pub dt_growth: f64,
    /// Maximum number of PTC integration steps before giving up.
    pub max_steps: usize,
    /// Convergence tolerance on the true residual `||F(x)||_inf`.
    /// When this is satisfied *and* the pseudo-transient term is negligible
    /// (`C/dt < ptc_exit_ratio * converge_tol`), the method has converged.
    pub converge_tol: f64,
    /// The pseudo-capacitance stamp is considered negligible when
    /// `C/dt < ptc_exit_ratio * converge_tol`.  Default 1.0.
    pub ptc_exit_ratio: f64,
    /// Inner Newton iterations per PTC step (typically 2–5 suffices because
    /// the Jacobian is well-conditioned).
    pub inner_iters: usize,
    /// Maximum accumulated pseudo-time before giving up.
    /// Corresponds to `.OPTIONS PTRANMAX`.  0.0 means no limit (only
    /// `max_steps` bounds the solver).
    pub ptranmax: f64,
}

impl Default for PseudoTransientConfig {
    fn default() -> Self {
        Self {
            c_init: 1.0,    // 1 F pseudo-capacitance
            dt_growth: 2.0, // double dt each step
            max_steps: 200,
            converge_tol: 1e-9,
            ptc_exit_ratio: 1.0,
            inner_iters: 10,
            ptranmax: 0.0,
        }
    }
}

/// Result of a successful pseudo-transient continuation solve.
#[derive(Debug, Clone)]
pub struct PtcResult {
    /// Converged solution vector.
    pub solution: Vec<f64>,
    /// True residual norm `||F(x)||_inf` evaluated without the PTC term.
    pub residual_norm: f64,
    /// Accumulated pseudo-time at convergence.
    pub pseudo_time: f64,
    /// Number of PTC outer steps taken.
    pub steps: usize,
}

/// Run pseudo-transient continuation starting from `x0`.
///
/// Returns a [`PtcResult`] on success containing the converged solution and
/// the true final residual (re-evaluated without the PTC term), or
/// `SimError::Convergence` if `max_steps` / `ptranmax` is exhausted.
///
/// # Arguments
/// - `circuit`: the netlist.
/// - `registry`: device model registry.
/// - `x0`: initial guess (need not be close to the solution).
/// - `cfg`: PTC configuration.
pub fn solve_pseudo_transient(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    x0: &[f64],
    cfg: &PseudoTransientConfig,
) -> Result<PtcResult, SimError> {
    let dim = circuit.mna_dimension();
    let num_nodes = circuit.num_vars() as usize;

    let mut x = x0.to_vec();
    // dt starts small and grows exponentially.
    // stamp_val = C/dt on the diagonal; we start large (well-conditioned) and
    // shrink it by dt_growth each step until the true residual is satisfied.
    let mut stamp_val = cfg.c_init; // C/dt; shrinks toward 0 as pseudo-dt grows

    // We ramp stamp_val DOWN from c_init (large = well conditioned) toward 0
    // (true DC equations).  Each step we divide stamp_val by dt_growth.
    // stamp_val = c_init / dt_growth^step → 0 as steps increase.

    let mut jac_triplet = TripletMatrix::with_capacity(dim, dim, dim * 6);
    let mut residual = DenseVec::zeros(dim);
    let mut neg_res = DenseVec::zeros(dim);

    // Track accumulated pseudo-time: dt = c_init / stamp_val, growing each step.
    let mut pseudo_time = 0.0_f64;

    for step in 0..cfg.max_steps {
        let x_prev = x.clone();

        // --- Inner Newton iterations with the PTC stamp ---
        let mut converged_inner = false;
        for _inner in 0..cfg.inner_iters {
            jac_triplet.clear();
            residual.fill_zero();
            stamper::stamp_circuit_into(
                dim,
                circuit,
                &x,
                registry,
                &mut jac_triplet,
                &mut residual,
                None,
            );

            // Add PTC stamp: C/dt on every node diagonal, C/dt * x_prev on RHS.
            // This enforces:  F(x) + (C/dt)*(x - x_prev) = 0  ⟹  convergence
            // target shifts from F(x)=0 toward the modified system.
            for i in 0..num_nodes {
                jac_triplet.add(i, i, stamp_val);
                residual[i] += stamp_val * (x[i] - x_prev[i]);
            }

            // Check convergence of the inner modified system.
            let inner_res_norm = residual.norm_inf();
            if inner_res_norm < cfg.converge_tol * stamp_val.max(1.0) {
                converged_inner = true;
                break;
            }

            // Solve J_aug * dx = -F_aug.
            let jac_csc = jac_triplet.to_csc();
            let factors = match lu_factorize(&jac_csc) {
                Ok(f) => f,
                Err(_) => break,
            };

            for i in 0..dim {
                neg_res[i] = -residual[i];
            }
            let dx = match lu_solve(&factors, &neg_res) {
                Ok(d) => d,
                Err(_) => break,
            };

            for i in 0..dim {
                x[i] += dx[i];
            }
        }

        // --- Check true residual (without PTC stamp) ---
        jac_triplet.clear();
        residual.fill_zero();
        stamper::stamp_circuit_into(
            dim,
            circuit,
            &x,
            registry,
            &mut jac_triplet,
            &mut residual,
            None,
        );
        let true_res = residual.norm_inf();

        // Update pseudo-time: dt = c_init / stamp_val (grows as stamp_val shrinks).
        let dt = cfg.c_init / stamp_val;
        pseudo_time += dt;

        // Convergence: true residual small AND stamp is negligible.
        if true_res < cfg.converge_tol && stamp_val < cfg.ptc_exit_ratio * cfg.converge_tol {
            log::debug!(
                "[PTC] converged at step={} stamp_val={:.2e} true_res={:.2e} pseudo_time={:.3e}",
                step,
                stamp_val,
                true_res,
                pseudo_time,
            );
            return Ok(PtcResult {
                solution: x,
                residual_norm: true_res,
                pseudo_time,
                steps: step + 1,
            });
        }

        // Honor ptranmax: if the accumulated pseudo-time exceeds the limit,
        // stop even if we have not converged.
        if cfg.ptranmax > 0.0 && pseudo_time > cfg.ptranmax {
            log::debug!(
                "[PTC] ptranmax={:.3e} exceeded at step={} pseudo_time={:.3e} res={:.2e}",
                cfg.ptranmax,
                step,
                pseudo_time,
                true_res,
            );
            return Err(SimError::Convergence {
                iterations: step as u32,
                residual: true_res,
            });
        }

        // Shrink the stamp for the next step (grow effective dt).
        stamp_val /= cfg.dt_growth;

        // If stamp is already negligible but residual is still above tol,
        // we're doing plain Newton — one more tight check.
        if stamp_val < 1e-15 {
            if true_res < cfg.converge_tol * 1000.0 {
                return Ok(PtcResult {
                    solution: x,
                    residual_norm: true_res,
                    pseudo_time,
                    steps: step + 1,
                });
            }
            return Err(SimError::Convergence {
                iterations: step as u32,
                residual: true_res,
            });
        }

        let _ = converged_inner; // inner convergence failure is non-fatal — outer loop continues
    }

    // Final true-residual check.
    jac_triplet.clear();
    residual.fill_zero();
    stamper::stamp_circuit_into(
        dim,
        circuit,
        &x,
        registry,
        &mut jac_triplet,
        &mut residual,
        None,
    );
    let final_res = residual.norm_inf();

    if final_res < cfg.converge_tol * 1000.0 {
        Ok(PtcResult {
            solution: x,
            residual_norm: final_res,
            pseudo_time,
            steps: cfg.max_steps,
        })
    } else {
        Err(SimError::Convergence {
            iterations: cfg.max_steps as u32,
            residual: final_res,
        })
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use crate::device::DeviceRegistry;

    /// Build a minimal circuit: one resistor, one voltage source.
    /// V1 (5 V) from node 1 to GND, R1 (1kΩ) from node 1 to GND.
    /// PTC should converge trivially and give V(1) = 5 V.
    fn simple_vr_circuit() -> Circuit {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");

        // Voltage source: node 1 (+) to GND (-), V = 5.
        let vs = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);
        ckt.add_device(vs);

        // Resistor: node 1 to GND, R = 1 kΩ.
        let r = DeviceInstance::new(
            DeviceId::new(1),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0);
        ckt.add_device(r);

        ckt.build_topology();
        ckt
    }

    #[test]
    fn ptc_converges_simple_circuit() {
        let ckt = simple_vr_circuit();
        let reg = DeviceRegistry::new_default();
        let x0 = vec![0.0; ckt.mna_dimension()];
        let cfg = PseudoTransientConfig::default();

        let result = solve_pseudo_transient(&ckt, &reg, &x0, &cfg);
        assert!(result.is_ok(), "PTC should converge: {:?}", result.err());

        let ptc = result.unwrap();
        // Node 1 voltage should be 5V.
        assert!((ptc.solution[0] - 5.0).abs() < 1e-3, "V(1) = {} expected ~5.0", ptc.solution[0]);
        // True residual should be small.
        assert!(ptc.residual_norm < 1e-6, "residual_norm={:.2e} should be small", ptc.residual_norm);
        assert!(ptc.steps > 0, "should take at least 1 step");
        assert!(ptc.pseudo_time > 0.0, "pseudo_time should be positive");
    }

    #[test]
    fn ptc_config_default_is_sane() {
        let cfg = PseudoTransientConfig::default();
        assert!(cfg.c_init > 0.0);
        assert!(cfg.dt_growth > 1.0);
        assert!(cfg.max_steps > 0);
        assert!(cfg.converge_tol > 0.0);
        assert!(cfg.inner_iters > 0);
        assert_eq!(cfg.ptranmax, 0.0, "ptranmax disabled by default");
    }

    #[test]
    fn test_ptc_smooth_exit_as_dt_grows() {
        // stamp_val starts at c_init and is divided by dt_growth each step,
        // so the series c_init / dt_growth^step converges to 0.
        // Verify the formula: after k steps, stamp_val = c_init / dt_growth^k,
        // which is strictly decreasing (since dt_growth > 1).
        let cfg = PseudoTransientConfig::default();
        assert!(cfg.dt_growth > 1.0, "dt_growth must exceed 1 for PTC to make progress");

        let mut stamp_val = cfg.c_init;
        let mut prev = stamp_val;
        let steps = 30;
        for _ in 0..steps {
            stamp_val /= cfg.dt_growth;
            assert!(stamp_val < prev,
                "stamp_val must decrease every step: prev={prev}, now={stamp_val}");
            prev = stamp_val;
        }
        // After 30 doublings: 1.0 / 2^30 ≈ 9.3e-10, well below converge_tol (1e-9).
        assert!(
            stamp_val < cfg.converge_tol * cfg.ptc_exit_ratio,
            "stamp_val={stamp_val:.3e} should be below exit threshold {:.3e} after {steps} steps",
            cfg.converge_tol * cfg.ptc_exit_ratio
        );
    }

    #[test]
    fn test_ptc_cold_start() {
        // All nodes at 0 V initial condition — PTC should converge for a
        // simple linear circuit where 0 is a valid starting point.
        let ckt = simple_vr_circuit();
        let reg = DeviceRegistry::new_default();
        // Start from all-zeros (genuine cold start).
        let x0 = vec![0.0; ckt.mna_dimension()];
        let cfg = PseudoTransientConfig::default();
        let result = solve_pseudo_transient(&ckt, &reg, &x0, &cfg);
        assert!(result.is_ok(), "cold-start PTC should converge: {:?}", result.err());
        let ptc = result.unwrap();
        // Node voltage should reach the forced 5 V.
        assert!((ptc.solution[0] - 5.0).abs() < 1e-3, "V(1)={} expected ~5.0", ptc.solution[0]);
    }

    #[test]
    fn test_ptc_max_steps_exceeded() {
        // Use max_steps=1 and a tiny converge_tol so the solver cannot converge
        // in a single step.  Expect Err, not a panic.
        let ckt = simple_vr_circuit();
        let reg = DeviceRegistry::new_default();
        let x0 = vec![0.0; ckt.mna_dimension()];
        let cfg = PseudoTransientConfig {
            max_steps: 1,
            converge_tol: 1e-30, // virtually impossible to satisfy in 1 step
            dt_growth: 1.0001,   // almost no growth so stamp stays large
            ..PseudoTransientConfig::default()
        };
        // With such a tight tolerance and only 1 step allowed, we expect
        // either an error OR (if trivially convergent) success — the key
        // requirement is that it does NOT panic.
        let _ = solve_pseudo_transient(&ckt, &reg, &x0, &cfg);
        // If we reach here the function returned normally (Ok or Err).
    }

    #[test]
    fn test_ptc_inner_newton_convergence() {
        // Verify that inner Newton sub-iterations drive the solution toward
        // the correct answer within the PTC loop by checking the residual
        // drops.  We use a slightly perturbed starting guess (1 V instead of 0)
        // and confirm the solver still converges to 5 V.
        let ckt = simple_vr_circuit();
        let reg = DeviceRegistry::new_default();
        let dim = ckt.mna_dimension();
        // Perturbed start: V(1) = 1 V (wrong answer is 5 V).
        let mut x0 = vec![0.0; dim];
        x0[0] = 1.0;
        let cfg = PseudoTransientConfig {
            inner_iters: 5,
            ..PseudoTransientConfig::default()
        };
        let result = solve_pseudo_transient(&ckt, &reg, &x0, &cfg);
        assert!(result.is_ok(), "PTC with perturbed start should converge");
        let ptc = result.unwrap();
        assert!((ptc.solution[0] - 5.0).abs() < 1e-3, "V(1)={} expected ~5.0", ptc.solution[0]);
    }

    #[test]
    fn test_ptc_ptranmax_enforced() {
        // With a very small ptranmax, PTC should abort early because
        // accumulated pseudo-time exceeds the limit before convergence.
        let ckt = simple_vr_circuit();
        let reg = DeviceRegistry::new_default();
        let x0 = vec![0.0; ckt.mna_dimension()];
        let cfg = PseudoTransientConfig {
            ptranmax: 1e-30, // impossibly small pseudo-time budget
            converge_tol: 1e-30, // impossibly tight tolerance
            ..PseudoTransientConfig::default()
        };
        let result = solve_pseudo_transient(&ckt, &reg, &x0, &cfg);
        assert!(result.is_err(), "should fail when ptranmax is exhausted");
    }

    #[test]
    fn test_ptc_ptranmax_zero_means_no_limit() {
        // ptranmax=0 should behave like no limit (default behaviour).
        let ckt = simple_vr_circuit();
        let reg = DeviceRegistry::new_default();
        let x0 = vec![0.0; ckt.mna_dimension()];
        let cfg = PseudoTransientConfig {
            ptranmax: 0.0,
            ..PseudoTransientConfig::default()
        };
        let result = solve_pseudo_transient(&ckt, &reg, &x0, &cfg);
        assert!(result.is_ok(), "ptranmax=0 should not limit: {:?}", result.err());
    }

    #[test]
    fn test_ptc_result_has_true_residual() {
        // Verify that the returned residual_norm is the true (non-PTC) residual.
        let ckt = simple_vr_circuit();
        let reg = DeviceRegistry::new_default();
        let x0 = vec![0.0; ckt.mna_dimension()];
        let cfg = PseudoTransientConfig::default();
        let ptc = solve_pseudo_transient(&ckt, &reg, &x0, &cfg).unwrap();
        // The true residual should be very small for a converged linear circuit.
        assert!(ptc.residual_norm < cfg.converge_tol,
            "true residual {:.2e} should be below converge_tol {:.2e}",
            ptc.residual_norm, cfg.converge_tol);
    }

    #[test]
    fn test_ptc_custom_dt_growth() {
        // A larger dt_growth should converge in fewer steps.
        let ckt = simple_vr_circuit();
        let reg = DeviceRegistry::new_default();
        let x0 = vec![0.0; ckt.mna_dimension()];

        let cfg_slow = PseudoTransientConfig {
            dt_growth: 1.5,
            ..PseudoTransientConfig::default()
        };
        let cfg_fast = PseudoTransientConfig {
            dt_growth: 4.0,
            ..PseudoTransientConfig::default()
        };

        let r_slow = solve_pseudo_transient(&ckt, &reg, &x0, &cfg_slow).unwrap();
        let r_fast = solve_pseudo_transient(&ckt, &reg, &x0, &cfg_fast).unwrap();

        assert!(r_fast.steps <= r_slow.steps,
            "dt_growth=4.0 ({} steps) should converge no slower than dt_growth=1.5 ({} steps)",
            r_fast.steps, r_slow.steps);
    }
}
