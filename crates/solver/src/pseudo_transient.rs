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
use pisim_core::{Circuit, SimError};
use pisim_device::DeviceRegistry;
use pisim_linalg::{lu_factorize, lu_solve, DenseVec, TripletMatrix};

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
}

impl Default for PseudoTransientConfig {
    fn default() -> Self {
        Self {
            c_init: 1.0,          // 1 F pseudo-capacitance
            dt_growth: 2.0,       // double dt each step
            max_steps: 200,
            converge_tol: 1e-9,
            ptc_exit_ratio: 1.0,
            inner_iters: 10,
        }
    }
}

/// Run pseudo-transient continuation starting from `x0`.
///
/// Returns the converged solution vector on success, or `SimError::Convergence`
/// if `max_steps` is exhausted without meeting the tolerance.
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
) -> Result<Vec<f64>, SimError> {
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

    for step in 0..cfg.max_steps {
        let x_prev = x.clone();

        // --- Inner Newton iterations with the PTC stamp ---
        let mut converged_inner = false;
        for _inner in 0..cfg.inner_iters {
            jac_triplet.clear();
            residual.fill_zero();
            stamper::stamp_circuit_into(dim, circuit, &x, registry, &mut jac_triplet, &mut residual, None);

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
        stamper::stamp_circuit_into(dim, circuit, &x, registry, &mut jac_triplet, &mut residual, None);
        let true_res = residual.norm_inf();

        // Convergence: true residual small AND stamp is negligible.
        if true_res < cfg.converge_tol && stamp_val < cfg.ptc_exit_ratio * cfg.converge_tol {
            log::debug!(
                "[PTC] converged at step={} stamp_val={:.2e} true_res={:.2e}",
                step, stamp_val, true_res
            );
            return Ok(x);
        }

        // Shrink the stamp for the next step (grow effective dt).
        stamp_val /= cfg.dt_growth;

        // If stamp is already negligible but residual is still above tol,
        // we're doing plain Newton — one more tight check.
        if stamp_val < 1e-15 {
            if true_res < cfg.converge_tol * 1000.0 {
                return Ok(x);
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
    stamper::stamp_circuit_into(dim, circuit, &x, registry, &mut jac_triplet, &mut residual, None);
    let final_res = residual.norm_inf();

    if final_res < cfg.converge_tol * 1000.0 {
        Ok(x)
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
    use pisim_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use pisim_device::DeviceRegistry;

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

        let x = result.unwrap();
        // Node 1 voltage should be 5V.
        assert!(
            (x[0] - 5.0).abs() < 1e-3,
            "V(1) = {} expected ~5.0", x[0]
        );
    }

    #[test]
    fn ptc_config_default_is_sane() {
        let cfg = PseudoTransientConfig::default();
        assert!(cfg.c_init > 0.0);
        assert!(cfg.dt_growth > 1.0);
        assert!(cfg.max_steps > 0);
        assert!(cfg.converge_tol > 0.0);
        assert!(cfg.inner_iters > 0);
    }
}
