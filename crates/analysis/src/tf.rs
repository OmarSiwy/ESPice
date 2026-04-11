//! `.TF` — small-signal DC transfer function analysis.
//!
//! Algorithm:
//! 1. Solve the DC operating point (linearisation point).
//! 2. Build the resistive Jacobian `G` at the OP via `stamp_circuit_gc_into`
//!    (the same Jacobian AC analysis uses, evaluated at ω = 0).
//! 3. Factor `G` once.
//! 4. Compute three quantities by injecting unit stimuli:
//!    - **Gain `dV(out)/dV(in)`**: inject a unit voltage at the input source
//!      branch row; read the output node voltage from the resulting solution.
//!    - **Input impedance `Zin = dV(in)/dI(in)`**: with the input source
//!      replaced by an open / unit current injection, read V(in_pos) - V(in_neg).
//!      For a voltage-source input we use the branch-row trick: solve for
//!      `dx/dV_in` and report 1 / (dI(branch) / dV_in) = 1 / (G^{-1}[branch,branch]).
//!    - **Output impedance `Zout`**: inject a unit current between the
//!      designated output nodes (out, ref) and read the resulting voltage.
//!
//! Output is a single `TfResult` struct holding the three scalar values.
//!
//! Limitations:
//!   - The input source must be a `VoltageSource` whose branch index is known.
//!   - The output `ref` node defaults to ground (`0`).
//!   - Only the resistive (DC) Jacobian is used; reactive elements drop out at ω = 0.

use bigospice_core::{Circuit, DeviceKind, SimError, SimOptions};
use bigospice_device::DeviceRegistry;
use bigospice_linalg::{DenseVec, LinSolver, LinSolverKind, TripletMatrix};
use bigospice_solver::{stamp_circuit_gc_into, NrConfig, Solver, SolverConfig};

/// Configuration for a `.TF` analysis.
#[derive(Debug, Clone)]
pub struct TfConfig {
    /// Output node name (e.g. `"out"`).
    pub output_node: String,
    /// Optional output reference node — defaults to ground.
    pub output_ref: Option<String>,
    /// Input source name — must be a voltage source (e.g. `"Vin"`).
    pub input_source: String,
}

impl TfConfig {
    pub fn new(output_node: impl Into<String>, input_source: impl Into<String>) -> Self {
        Self {
            output_node: output_node.into(),
            output_ref: None,
            input_source: input_source.into(),
        }
    }
}

/// Result of a `.TF` analysis.
#[derive(Debug, Clone)]
pub struct TfResult {
    /// dV(out) / dV(in) — small-signal voltage gain.
    pub gain: f64,
    /// Input resistance looking into the input source [Ω].
    pub input_impedance: f64,
    /// Output resistance looking into the output node pair [Ω].
    pub output_impedance: f64,
}

/// Run a `.TF` analysis with default solver options.
pub fn run_tf(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &TfConfig,
) -> Result<TfResult, SimError> {
    run_tf_inner(circuit, registry, cfg, None)
}

/// Run a `.TF` analysis with explicit `.OPTIONS`.
pub fn run_tf_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &TfConfig,
    opts: &SimOptions,
) -> Result<TfResult, SimError> {
    run_tf_inner(circuit, registry, cfg, Some(opts))
}

fn run_tf_inner(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &TfConfig,
    opts: Option<&SimOptions>,
) -> Result<TfResult, SimError> {
    let dim = circuit.mna_dimension();
    let num_nodes = circuit.num_vars() as usize;

    // 1. Solve DC OP (linearisation point).
    let solver = match opts {
        Some(o) => Solver::new(SolverConfig {
            nr: NrConfig::from(o),
            ..SolverConfig::default()
        }),
        None => Solver::default(),
    };
    let dc = solver.solve(circuit, registry, None)?;

    // 2. Build G at the OP (we discard C — DC TF is at ω = 0).
    let mut g_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut c_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut tmp_g = DenseVec::zeros(dim);
    let mut tmp_q = DenseVec::zeros(dim);
    stamp_circuit_gc_into(
        circuit,
        &dc.solution,
        registry,
        &mut g_triplet,
        &mut c_triplet,
        &mut tmp_g,
        &mut tmp_q,
    );

    // 3. Factorise G once.
    let g_csc = g_triplet.to_csc();
    let lin = LinSolver::factorize(LinSolverKind::SparseLu, &g_csc)
        .map_err(|_| SimError::Analysis("TF: singular Jacobian at OP".into()))?;

    // 4. Resolve output node row (1-based NodeId index → 0-based MNA row).
    let out_row = resolve_node_row(circuit, &cfg.output_node, num_nodes)?;
    let ref_row = match &cfg.output_ref {
        Some(name) => resolve_node_row_or_ground(circuit, name, num_nodes)?,
        None => None,
    };

    // 5. Resolve input source branch row.
    let input_dev = circuit
        .find_device(&cfg.input_source)
        .ok_or_else(|| SimError::Analysis(format!("TF: input source '{}' not found", cfg.input_source)))?;
    if input_dev.kind != DeviceKind::VoltageSource {
        return Err(SimError::Analysis(format!(
            "TF: input source '{}' must be a voltage source",
            cfg.input_source
        )));
    }
    let in_branch = input_dev
        .branch_index
        .ok_or_else(|| SimError::Analysis("TF: input source has no branch row".into()))?
        as usize;
    let in_branch_row = num_nodes + in_branch;

    // 6. Compute gain by RHS = +1 in the input branch row.
    //    The branch equation row reads `V(pos) - V(neg) - V_in = 0`, so RHS = +1
    //    yields the linear sensitivity dx/dV_in across all unknowns.
    let mut rhs = DenseVec::zeros(dim);
    rhs[in_branch_row] = 1.0;
    let sol = lin.solve(&rhs)?;

    let v_out = read_row(&sol, out_row);
    let v_ref = read_row(&sol, ref_row);
    let gain = v_out - v_ref;

    // 7. Input impedance: dI(branch)/dV_in for the same RHS.
    //    The branch current dI(branch) is sol[branch_row]. By dual-source
    //    arguments, Zin = dV_in / dI_in = 1 / dI/dV.
    //    For a voltage-source-driven port the current entering V+ is
    //    -I_branch (sign convention of the MNA branch row), so we negate.
    let i_branch_sens = sol[in_branch_row];
    let input_impedance = if i_branch_sens.abs() > 1e-30 {
        -1.0 / i_branch_sens
    } else {
        f64::INFINITY
    };

    // 8. Output impedance: turn off the input source (RHS = 0 at branch row),
    //    inject a unit current at the output node pair, read the resulting
    //    voltage.  Since the input branch row in the MNA system already
    //    enforces V(in+) - V(in-) = V_in_dc, *zeroing* RHS at the branch row
    //    holds the input source short — i.e. the input source is grounded.
    rhs.fill_zero();
    if let Some(r) = out_row {
        rhs[r] += 1.0;
    }
    if let Some(r) = ref_row {
        rhs[r] -= 1.0;
    }
    let sol_z = lin.solve(&rhs)?;
    let v_out_z = read_row(&sol_z, out_row);
    let v_ref_z = read_row(&sol_z, ref_row);
    let output_impedance = v_out_z - v_ref_z;

    Ok(TfResult {
        gain,
        input_impedance,
        output_impedance,
    })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

#[inline]
fn read_row(sol: &DenseVec, row: Option<usize>) -> f64 {
    match row {
        Some(r) if r < sol.len() => sol[r],
        _ => 0.0,
    }
}

fn resolve_node_row(circuit: &Circuit, name: &str, num_nodes: usize) -> Result<Option<usize>, SimError> {
    let lower = name.to_lowercase();
    if lower == "0" || lower == "gnd" {
        return Ok(None);
    }
    let id = circuit
        .find_node(&lower)
        .ok_or_else(|| SimError::Analysis(format!("TF: node '{name}' not found")))?;
    let raw = id.index() as usize;
    if raw == 0 {
        return Ok(None);
    }
    let row = raw - 1;
    if row >= num_nodes {
        return Err(SimError::Analysis(format!("TF: node '{name}' row {row} out of range")));
    }
    Ok(Some(row))
}

fn resolve_node_row_or_ground(
    circuit: &Circuit,
    name: &str,
    num_nodes: usize,
) -> Result<Option<usize>, SimError> {
    resolve_node_row(circuit, name, num_nodes)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};

    fn voltage_divider(r1: f64, r2: f64, vin: f64) -> Circuit {
        let mut ckt = Circuit::new();
        let n_in = ckt.add_node("in");
        let n_out = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "Vin", DeviceKind::VoltageSource, &[
                (0, n_in),
                (1, NodeId::GROUND),
            ])
            .with_param("dc", vin),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor, &[
                (0, n_in),
                (1, n_out),
            ])
            .with_param("resistance", r1),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R2", DeviceKind::Resistor, &[
                (0, n_out),
                (1, NodeId::GROUND),
            ])
            .with_param("resistance", r2),
        );
        ckt.build_topology();
        ckt
    }

    #[test]
    fn tf_voltage_divider_gain() {
        // Vout/Vin = R2/(R1+R2)
        let ckt = voltage_divider(1e3, 2e3, 5.0);
        let reg = DeviceRegistry::new_default();
        let cfg = TfConfig::new("out", "Vin");
        let res = run_tf(&ckt, &reg, &cfg).unwrap();
        let expected = 2e3 / 3e3;
        assert!((res.gain - expected).abs() < 1e-6, "gain={} expected {}", res.gain, expected);
    }

    #[test]
    fn tf_voltage_divider_zout() {
        // R_out = R1 || R2 with Vin shorted: 1k || 2k = 666.67Ω
        let ckt = voltage_divider(1e3, 2e3, 5.0);
        let reg = DeviceRegistry::new_default();
        let cfg = TfConfig::new("out", "Vin");
        let res = run_tf(&ckt, &reg, &cfg).unwrap();
        let expected = (1e3 * 2e3) / (1e3 + 2e3);
        assert!(
            (res.output_impedance - expected).abs() < 1e-3,
            "Zout={} expected {}",
            res.output_impedance,
            expected
        );
    }

    #[test]
    fn tf_voltage_divider_zin() {
        // R_in = R1 + R2 (the resistor chain seen by Vin)
        let ckt = voltage_divider(1e3, 2e3, 5.0);
        let reg = DeviceRegistry::new_default();
        let cfg = TfConfig::new("out", "Vin");
        let res = run_tf(&ckt, &reg, &cfg).unwrap();
        let expected = 3e3;
        assert!(
            (res.input_impedance - expected).abs() < 1e-3,
            "Zin={} expected {}",
            res.input_impedance,
            expected
        );
    }
}
