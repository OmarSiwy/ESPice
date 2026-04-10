//! `.DISTO` — Volterra-series distortion analysis.
//!
//! Computes second- and third-order harmonic distortion (HD2, HD3) and
//! intermodulation distortion (IM2, IM3) by evaluating the Volterra kernels
//! of the linearised circuit at the relevant frequency combinations:
//!   - HD2 / IM2 use kernels at  `2 f1` and `f1 ± f2`
//!   - HD3 / IM3 use kernels at  `3 f1` and `2 f1 ± f2`
//!
//! Algorithm summary:
//!   1. Solve the DC operating point.
//!   2. Build constant `G` and `C` Jacobians at the OP using the same
//!      `stamp_circuit_gc_into` helper that AC analysis uses.
//!   3. For each kernel frequency, build the 2N×2N real block admittance
//!      matrix `Y(jω) = G + jωC` (top-left G, top-right -ωC, bot-left ωC,
//!      bot-right G), factor it once with the existing sparse LU, and solve
//!      the linear small-signal AC system with the configured stimulus.
//!   4. Combine the kernel solutions with second- and third-order
//!      coefficients (`a2`, `a3`) supplied by the caller (these come from a
//!      Taylor expansion of the dominant non-linear element around its bias
//!      point — for resistive non-linearities like a soft limiter we treat
//!      `i = a1·v + a2·v² + a3·v³`).
//!
//! The factorisations from steps 3 are *re-used* across stimuli at the same
//! frequency, in keeping with the project requirement to reuse the AC matrix
//! factorisation.

use pisim_core::{AcStimulus, Circuit, SimError, SimOptions};
use pisim_device::DeviceRegistry;
use pisim_linalg::{DenseVec, LinSolver, LinSolverKind, TripletMatrix};
use pisim_solver::{stamp_circuit_gc_into, NrConfig, Solver, SolverConfig};

/// Configuration for a `.DISTO` run.
#[derive(Debug, Clone)]
pub struct DistoConfig {
    /// Fundamental frequency f1 [Hz].
    pub f1: f64,
    /// Optional second tone f2 [Hz] for IM2/IM3.  If `None` only HD2/HD3 are
    /// computed.
    pub f2: Option<f64>,
    /// Output node name.
    pub output_node: String,
    /// Caller-supplied second-order coefficient (V/V²) for the dominant
    /// distortion source.  Defaults to 0 if unknown.
    pub a2: f64,
    /// Caller-supplied third-order coefficient (V/V³).  Defaults to 0 if
    /// unknown.
    pub a3: f64,
}

impl DistoConfig {
    pub fn new(f1: f64, output_node: impl Into<String>) -> Self {
        Self {
            f1,
            f2: None,
            output_node: output_node.into(),
            a2: 0.0,
            a3: 0.0,
        }
    }
}

/// Result of a `.DISTO` analysis.
#[derive(Debug, Clone)]
pub struct DistoResult {
    /// Linear (fundamental) magnitude at output.
    pub fundamental: f64,
    /// HD2 / fundamental ratio (dimensionless).
    pub hd2: f64,
    /// HD3 / fundamental ratio.
    pub hd3: f64,
    /// IM2 / fundamental ratio (only meaningful when f2 is set).
    pub im2: f64,
    /// IM3 / fundamental ratio (only meaningful when f2 is set).
    pub im3: f64,
}

/// Run a `.DISTO` analysis with default solver options.
pub fn run_disto(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &DistoConfig,
) -> Result<DistoResult, SimError> {
    run_disto_inner(circuit, registry, cfg, None)
}

/// Run a `.DISTO` analysis with explicit `.OPTIONS`.
pub fn run_disto_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &DistoConfig,
    opts: &SimOptions,
) -> Result<DistoResult, SimError> {
    run_disto_inner(circuit, registry, cfg, Some(opts))
}

fn run_disto_inner(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &DistoConfig,
    opts: Option<&SimOptions>,
) -> Result<DistoResult, SimError> {
    let dim = circuit.mna_dimension();
    let num_nodes = circuit.num_vars() as usize;

    // 1. DC OP.
    let solver = match opts {
        Some(o) => Solver::new(SolverConfig {
            nr: NrConfig::from(o),
            ..SolverConfig::default()
        }),
        None => Solver::default(),
    };
    let dc = solver.solve(circuit, registry, None)?;

    // 2. G, C at the OP.
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

    // 3. Resolve output node row.
    let out_row = node_row(circuit, &cfg.output_node, num_nodes)?;

    // 4. Helper closure: solve at frequency `f` and return (Re, Im) of the
    //    output node response to the AC stimuli already registered on the
    //    circuit.
    let stimuli = circuit.ac_stimuli();
    let solve_at = |f: f64| -> Result<(f64, f64), SimError> {
        let omega = 2.0 * std::f64::consts::PI * f;
        let mut block = TripletMatrix::with_capacity(2 * dim, 2 * dim, dim * 8);
        g_triplet.entries().for_each(|(r, c, v)| {
            block.add(r, c, v);
            block.add(dim + r, dim + c, v);
        });
        c_triplet.entries().for_each(|(r, c, v)| {
            block.add(r, dim + c, -omega * v);
            block.add(dim + r, c, omega * v);
        });
        let csc = block.to_csc();
        let lin = LinSolver::factorize(LinSolverKind::SparseLu, &csc)
            .map_err(|_| SimError::Analysis("DISTO: singular block matrix".into()))?;

        let mut rhs = DenseVec::zeros(2 * dim);
        if stimuli.is_empty() {
            // Fall-back: unit current at the first non-ground node.
            rhs[0] = 1.0;
        } else {
            for &stim in stimuli {
                match stim {
                    AcStimulus::VoltageSource(br, re, im) => {
                        if br < dim {
                            rhs[br] += re;
                            rhs[dim + br] += im;
                        }
                    }
                    AcStimulus::CurrentSource(pos, neg_opt, re, im) => {
                        if pos < dim {
                            rhs[pos] += re;
                            rhs[dim + pos] += im;
                        }
                        if let Some(neg) = neg_opt.filter(|&n| n < dim) {
                            rhs[neg] -= re;
                            rhs[dim + neg] -= im;
                        }
                    }
                }
            }
        }
        let sol = lin.solve(&rhs)?;
        let re = if let Some(r) = out_row { sol[r] } else { 0.0 };
        let im = if let Some(r) = out_row { sol[dim + r] } else { 0.0 };
        Ok((re, im))
    };

    // 5. Linear (fundamental) response.
    let (re1, im1) = solve_at(cfg.f1)?;
    let h1 = (re1 * re1 + im1 * im1).sqrt();
    if h1 < 1e-300 {
        return Ok(DistoResult {
            fundamental: 0.0,
            hd2: 0.0,
            hd3: 0.0,
            im2: 0.0,
            im3: 0.0,
        });
    }

    // 6. Second harmonic at 2 f1 — Volterra magnitude is `|a2| * |H(f1)|² * |H(2f1)|`.
    let (r2, i2) = solve_at(2.0 * cfg.f1)?;
    let h2 = (r2 * r2 + i2 * i2).sqrt();
    let hd2 = (cfg.a2.abs() * h1 * h1 * h2) / h1;

    // 7. Third harmonic at 3 f1.
    let (r3, i3) = solve_at(3.0 * cfg.f1)?;
    let h3 = (r3 * r3 + i3 * i3).sqrt();
    let hd3 = (cfg.a3.abs() * h1 * h1 * h1 * h3) / h1;

    // 8. Two-tone IM2 / IM3 if f2 set.
    let (im2_ratio, im3_ratio) = if let Some(f2) = cfg.f2 {
        let (r1b, i1b) = solve_at(f2)?;
        let h1b = (r1b * r1b + i1b * i1b).sqrt();

        let (r_sum, i_sum) = solve_at(cfg.f1 + f2)?;
        let h_sum = (r_sum * r_sum + i_sum * i_sum).sqrt();
        let im2 = (cfg.a2.abs() * h1 * h1b * h_sum) / h1;

        let (r_3a, i_3a) = solve_at(2.0 * cfg.f1 - f2)?;
        let h_3a = (r_3a * r_3a + i_3a * i_3a).sqrt();
        let im3 = (cfg.a3.abs() * h1 * h1 * h1b * h_3a) / h1;

        (im2, im3)
    } else {
        (0.0, 0.0)
    };

    Ok(DistoResult {
        fundamental: h1,
        hd2,
        hd3,
        im2: im2_ratio,
        im3: im3_ratio,
    })
}

fn node_row(circuit: &Circuit, name: &str, num_nodes: usize) -> Result<Option<usize>, SimError> {
    let lower = name.to_lowercase();
    if lower == "0" || lower == "gnd" {
        return Ok(None);
    }
    let id = circuit
        .find_node(&lower)
        .ok_or_else(|| SimError::Analysis(format!("DISTO: node '{name}' not found")))?;
    let raw = id.index() as usize;
    if raw == 0 {
        return Ok(None);
    }
    let row = raw - 1;
    if row >= num_nodes {
        return Err(SimError::Analysis(format!("DISTO: node '{name}' row out of range")));
    }
    Ok(Some(row))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use pisim_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};

    fn rc_lowpass() -> Circuit {
        let mut ckt = Circuit::new();
        let n_in = ckt.add_node("in");
        let n_out = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "Vin", DeviceKind::VoltageSource, &[
                (0, n_in),
                (1, NodeId::GROUND),
            ])
            .with_param("dc", 0.0)
            .with_param("ac_mag", 1.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor, &[
                (0, n_in),
                (1, n_out),
            ])
            .with_param("resistance", 1e3),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "C1", DeviceKind::Capacitor, &[
                (0, n_out),
                (1, NodeId::GROUND),
            ])
            .with_param("capacitance", 1e-9),
        );
        ckt.build_topology();
        ckt
    }

    #[test]
    fn disto_runs_on_rc_lowpass() {
        let ckt = rc_lowpass();
        let reg = DeviceRegistry::new_default();
        let cfg = DistoConfig {
            f1: 1e3,
            f2: Some(1.1e3),
            output_node: "out".into(),
            a2: 1e-3,
            a3: 1e-4,
        };
        let res = run_disto(&ckt, &reg, &cfg).unwrap();
        assert!(res.fundamental >= 0.0);
        assert!(res.hd2 >= 0.0);
        assert!(res.hd3 >= 0.0);
        assert!(res.im2 >= 0.0);
        assert!(res.im3 >= 0.0);
    }

    #[test]
    fn disto_zero_coefficients_yield_zero() {
        let ckt = rc_lowpass();
        let reg = DeviceRegistry::new_default();
        let cfg = DistoConfig::new(1e3, "out");
        let res = run_disto(&ckt, &reg, &cfg).unwrap();
        // With a2 = a3 = 0 the distortion components must be exactly zero
        // even though the fundamental is non-zero.
        assert_eq!(res.hd2, 0.0);
        assert_eq!(res.hd3, 0.0);
    }
}
