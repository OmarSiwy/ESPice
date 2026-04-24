//! AC analysis — streaming per-frequency.

use incspice_cache::CacheManager;
use incspice_core::{Circuit, DeviceKind, SimError, SimOptions, StreamingSink};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::newton::NrConfig;
use incspice_solver::linalg::{DenseVec, LinSolver, LinSolverKind, TripletMatrix};
use incspice_solver::{Solver, SolverConfig, stamp_circuit_gc_into};
use crate::{Analysis, AnalysisError};
use crate::result::AcResult;

/// Frequency-sweep type for AC and related analyses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcSweepType {
    /// Linearly spaced frequencies.
    Linear,
    /// Logarithmically spaced, `npoints` per decade.
    Decade,
    /// Logarithmically spaced, `npoints` per octave.
    Octave,
}

/// Configuration for a standalone AC sweep.
#[derive(Debug, Clone)]
pub struct AcConfig {
    pub start: f64,
    pub stop: f64,
    pub npoints: usize,
    pub sweep: AcSweepType,
}

impl AcConfig {
    pub fn new(start: f64, stop: f64, npoints: usize, sweep: AcSweepType) -> Self {
        Self { start, stop, npoints, sweep }
    }
}

pub struct Ac {
    pub frequencies: Vec<f64>,
}

/// Patch G matrix for resistors with `ac=` parameter override.
///
/// Replaces DC conductance with AC conductance for resistors that specify
/// an `ac` parameter (different impedance for AC analysis).
fn patch_ac_resistors(circuit: &Circuit, g_triplet: &mut TripletMatrix) {
    for dev in circuit.devices() {
        if dev.kind == DeviceKind::Resistor {
            if let Some(ac_r) = dev.params.get("ac") {
                let dc_r = dev.params.get_or("resistance", 1e3).max(1e-12);
                let dc_g = 1.0 / dc_r;
                let ac_g = 1.0 / ac_r.max(1e-12);
                let delta = ac_g - dc_g;
                if delta.abs() < 1e-30 {
                    continue;
                }
                let n1 = if dev.terminals[0].node.is_ground() {
                    None
                } else {
                    Some((dev.terminals[0].node.0 - 1) as usize)
                };
                let n2 = if dev.terminals[1].node.is_ground() {
                    None
                } else {
                    Some((dev.terminals[1].node.0 - 1) as usize)
                };
                if let Some(r1) = n1 {
                    g_triplet.add(r1, r1, delta);
                }
                if let Some(r2) = n2 {
                    g_triplet.add(r2, r2, delta);
                }
                if let (Some(r1), Some(r2)) = (n1, n2) {
                    g_triplet.add(r1, r2, -delta);
                    g_triplet.add(r2, r1, -delta);
                }
            }
        }
    }
}

/// Solve for AC magnitudes at a single frequency given pre-built G and C Jacobians.
///
/// `g_triplet` and `c_triplet` are the conductance and capacitance stamp matrices
/// built at the DC operating point. Returns a magnitude vector of length `num_nodes`.
fn ac_solve_one_freq(
    circuit: &Circuit,
    g_triplet: &TripletMatrix,
    c_triplet: &TripletMatrix,
    dim: usize,
    num_nodes: usize,
    freq: f64,
) -> Result<Vec<f64>, incspice_core::SimError> {
    let omega = 2.0 * std::f64::consts::PI * freq;
    let n2 = 2 * dim;

    let mut block_triplet = TripletMatrix::with_capacity(n2, n2, dim * 8);
    g_triplet.entries().for_each(|(r, c, v)| {
        block_triplet.add(r, c, v);
        block_triplet.add(dim + r, dim + c, v);
    });
    c_triplet.entries().for_each(|(r, c, v)| {
        block_triplet.add(r, dim + c, -omega * v);
        block_triplet.add(dim + r, c, omega * v);
    });

    let mut rhs = DenseVec::zeros(n2);
    let stimuli = circuit.ac_stimuli();
    if stimuli.is_empty() {
        if dim > 0 { rhs[0] = 1.0; }
    } else {
        for stim in stimuli {
            match stim {
                incspice_core::AcStimulus::VoltageSource(br, re, im) => {
                    if *br < dim { rhs[*br] += re; rhs[dim + br] += im; }
                }
                incspice_core::AcStimulus::CurrentSource(pos, neg_opt, re, im) => {
                    if *pos < dim { rhs[*pos] += re; rhs[dim + pos] += im; }
                    if let Some(neg) = neg_opt.filter(|&n| n < dim) {
                        rhs[neg] -= re; rhs[dim + neg] -= im;
                    }
                }
            }
        }
    }

    let csc = block_triplet.to_csc();
    let lin = LinSolver::factorize(LinSolverKind::SparseLu, &csc)
        .map_err(|_| incspice_core::SimError::Analysis("AC: singular admittance matrix".into()))?;
    let sol = lin.solve(&rhs)?;

    let mags = (0..num_nodes)
        .map(|i| {
            let re = sol[i];
            let im = sol[dim + i];
            (re * re + im * im).sqrt()
        })
        .collect();
    Ok(mags)
}

impl Analysis for Ac {
    fn run(&self, circuit: &mut Circuit, registry: &DeviceRegistry, config: &NrConfig, cache: &mut CacheManager, sink: &mut dyn StreamingSink) -> Result<(), AnalysisError> {
        let dim = circuit.mna_dimension();
        let num_nodes = circuit.num_vars() as usize;
        let dc = incspice_solver::solve(circuit, registry, config, cache)?;

        // Build G and C Jacobians at the DC operating point.
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
        patch_ac_resistors(circuit, &mut g_triplet);

        for &freq in &self.frequencies {
            let mags = ac_solve_one_freq(circuit, &g_triplet, &c_triplet, dim, num_nodes, freq)?;
            sink.emit_point(freq, &mags)?;
        }

        sink.finalize()?;
        Ok(())
    }
    fn name(&self) -> &str { "ac" }
}

/// Run an AC sweep with default solver options. Returns an `AcResult`.
pub fn run_ac(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &AcConfig,
) -> Result<AcResult, SimError> {
    run_ac_inner(circuit, registry, cfg, None)
}

/// Run an AC sweep with explicit `.OPTIONS`. Returns an `AcResult`.
pub fn run_ac_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &AcConfig,
    opts: &SimOptions,
) -> Result<AcResult, SimError> {
    run_ac_inner(circuit, registry, cfg, Some(opts))
}

fn run_ac_inner(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &AcConfig,
    opts: Option<&SimOptions>,
) -> Result<AcResult, SimError> {
    let dim = circuit.mna_dimension();
    let num_nodes = circuit.num_vars() as usize;

    // DC operating point.
    let solver = match opts {
        Some(o) => Solver::new(SolverConfig {
            nr: NrConfig::from(o),
            ..SolverConfig::default()
        }),
        None => Solver::default(),
    };
    let dc = solver.solve(circuit, registry, None)?;

    // Build G and C Jacobians at the OP.
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
    patch_ac_resistors(circuit, &mut g_triplet);

    let freqs = generate_ac_frequencies(cfg);
    let nf = freqs.len();

    let mut node_magnitudes = Vec::with_capacity(nf);
    let mut node_phases = Vec::with_capacity(nf);
    let mut node_reals = Vec::with_capacity(nf);
    let mut node_imags = Vec::with_capacity(nf);

    let nb = circuit.num_branches() as usize;
    let branch_names: Vec<String> = circuit
        .devices()
        .iter()
        .filter_map(|dev| dev.branch_index.map(|_| dev.name.clone()))
        .collect();
    let mut all_branch_reals = Vec::with_capacity(nf);
    let mut all_branch_imags = Vec::with_capacity(nf);

    let n2 = 2 * dim;
    let mut block_triplet = TripletMatrix::with_capacity(n2, n2, dim * 8);
    let mut rhs = DenseVec::zeros(n2);

    for &freq in &freqs {
        let omega = 2.0 * std::f64::consts::PI * freq;

        block_triplet.clear();
        g_triplet.entries().for_each(|(r, c, v)| {
            block_triplet.add(r, c, v);
            block_triplet.add(dim + r, dim + c, v);
        });
        c_triplet.entries().for_each(|(r, c, v)| {
            block_triplet.add(r, dim + c, -omega * v);
            block_triplet.add(dim + r, c, omega * v);
        });

        // Build RHS from AC stimuli.
        rhs.fill_zero();
        let stimuli = circuit.ac_stimuli();
        if stimuli.is_empty() {
            if dim > 0 { rhs[0] = 1.0; }
        } else {
            for stim in stimuli {
                match stim {
                    incspice_core::AcStimulus::VoltageSource(br, re, im) => {
                        if *br < dim { rhs[*br] += re; rhs[dim + br] += im; }
                    }
                    incspice_core::AcStimulus::CurrentSource(pos, neg_opt, re, im) => {
                        if *pos < dim { rhs[*pos] += re; rhs[dim + pos] += im; }
                        if let Some(neg) = neg_opt.filter(|&n| n < dim) {
                            rhs[neg] -= re; rhs[dim + neg] -= im;
                        }
                    }
                }
            }
        }

        let csc = block_triplet.to_csc();
        let lin = LinSolver::factorize(LinSolverKind::SparseLu, &csc)
            .map_err(|_| SimError::Analysis("AC: singular admittance matrix".into()))?;
        let sol = lin.solve(&rhs)?;

        let mut mags = Vec::with_capacity(num_nodes);
        let mut phases = Vec::with_capacity(num_nodes);
        let mut reals = Vec::with_capacity(num_nodes);
        let mut imags_v = Vec::with_capacity(num_nodes);
        for i in 0..num_nodes {
            let re = sol[i];
            let im = sol[dim + i];
            mags.push((re * re + im * im).sqrt());
            phases.push(im.atan2(re));
            reals.push(re);
            imags_v.push(im);
        }
        node_magnitudes.push(mags);
        node_phases.push(phases);
        node_reals.push(reals);
        node_imags.push(imags_v);

        // Extract branch currents from solution vector.
        let mut br_reals = Vec::with_capacity(nb);
        let mut br_imags = Vec::with_capacity(nb);
        for bi in 0..nb {
            let idx = num_nodes + bi;
            let re = sol[idx];
            let im = sol[dim + idx];
            br_reals.push(re);
            br_imags.push(im);
        }
        all_branch_reals.push(br_reals);
        all_branch_imags.push(br_imags);
    }

    Ok(AcResult {
        frequencies: freqs,
        node_magnitudes,
        node_phases,
        node_reals,
        node_imags,
        branch_names,
        branch_reals: all_branch_reals,
        branch_imags: all_branch_imags,
    })
}

pub fn generate_ac_frequencies(cfg: &AcConfig) -> Vec<f64> {
    match cfg.sweep {
        AcSweepType::Linear => {
            let n = cfg.npoints.max(1);
            let denom = (n - 1).max(1) as f64;
            let step = (cfg.stop - cfg.start) / denom;
            (0..n).map(|i| cfg.start + i as f64 * step).collect()
        }
        AcSweepType::Decade => {
            let log_start = cfg.start.log10();
            let log_stop = cfg.stop.log10();
            let num_decades = (log_stop - log_start).abs();
            let total = (cfg.npoints as f64 * num_decades).ceil() as usize;
            let step = (log_stop - log_start) / total.max(1) as f64;
            (0..=total).map(|i| 10.0_f64.powf(log_start + i as f64 * step)).collect()
        }
        AcSweepType::Octave => {
            let log_start = cfg.start.log2();
            let log_stop = cfg.stop.log2();
            let num_octaves = (log_stop - log_start).abs();
            let total = (cfg.npoints as f64 * num_octaves).ceil() as usize;
            let step = (log_stop - log_start) / total.max(1) as f64;
            (0..=total).map(|i| 2.0_f64.powf(log_start + i as f64 * step)).collect()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_cache::CacheManager;
    use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId, SimError};
    use incspice_solver::device::DeviceRegistry;
    use incspice_solver::newton::NrConfig;

    /// Build a simple RC low-pass filter driven by a 1 A current source.
    ///
    /// Topology: I1 (1 A AC) from GND into node "out", R1 (1 kΩ) from "out" to GND,
    /// C1 (1 µF) from "out" to GND.  No branch variables, so `dim == num_nodes == 1`.
    /// The AC stimulus is registered explicitly as a CurrentSource injection.
    fn rc_circuit() -> Circuit {
        let mut ckt = Circuit::new();
        let n_out = ckt.add_node("out");

        // Current source: 1 A AC injected into "out"
        let i1 = DeviceInstance::new(
            DeviceId::new(0),
            "I1",
            DeviceKind::CurrentSource,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("dc", 0.0);

        // Resistor 1 kΩ between "out" and GND
        let r1 = DeviceInstance::new(
            DeviceId::new(1),
            "R1",
            DeviceKind::Resistor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1_000.0);

        // Capacitor 1 µF between "out" and GND
        let c1 = DeviceInstance::new(
            DeviceId::new(2),
            "C1",
            DeviceKind::Capacitor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", 1e-6);

        ckt.add_device(i1);
        ckt.add_device(r1);
        ckt.add_device(c1);
        ckt.build_topology();

        // Register the AC stimulus: 1 A real into node 0 ("out")
        ckt.add_ac_stimulus(incspice_core::AcStimulus::CurrentSource(0, None, 1.0, 0.0));
        ckt
    }

    /// The streaming path must produce non-zero magnitudes for a real RC circuit.
    #[test]
    fn test_ac_streaming_magnitudes_nonzero() {
        let mut ckt = rc_circuit();
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new();

        // Three frequency points spanning the RC corner (f_c = 1/(2π·RC) ≈ 159 Hz).
        let ac = Ac { frequencies: vec![10.0, 159.15, 10_000.0] };

        // Collecting sink — stores every emitted point.
        struct CollectSink { pub points: Vec<(f64, Vec<f64>)> }
        impl StreamingSink for CollectSink {
            fn emit_point(&mut self, sv: f64, vals: &[f64]) -> Result<(), SimError> {
                self.points.push((sv, vals.to_vec()));
                Ok(())
            }
            fn finalize(&mut self) -> Result<(), SimError> { Ok(()) }
        }

        let mut sink = CollectSink { points: Vec::new() };
        ac.run(&mut ckt, &registry, &config, &mut cache, &mut sink)
            .expect("AC streaming path should not fail");

        assert_eq!(sink.points.len(), 3, "expected one point per frequency");

        for (freq, mags) in &sink.points {
            let any_nonzero = mags.iter().any(|&m| m > 1e-12);
            assert!(
                any_nonzero,
                "all magnitudes are zero at freq={freq} Hz — streaming path still emits stub zeros"
            );
        }

        // At low frequency (10 Hz, well below corner ~159 Hz) the impedance is
        // dominated by R: |Z| ≈ R = 1 kΩ.  At high frequency (10 kHz) the capacitor
        // shunts the output so |Z| << R.  Verify roll-off direction.
        let mag_low  = sink.points[0].1[0]; // node "out" at 10 Hz
        let mag_high = sink.points[2].1[0]; // node "out" at 10 kHz
        assert!(
            mag_low > mag_high,
            "expected low-freq magnitude ({mag_low:.4}) > high-freq magnitude ({mag_high:.4})"
        );
    }

    /// Streaming path magnitudes must agree with `run_ac_inner` (standalone path).
    #[test]
    fn test_ac_streaming_matches_standalone() {
        let mut ckt = rc_circuit();
        let registry = DeviceRegistry::new_default();
        let config = NrConfig::default();
        let mut cache = CacheManager::new();

        let freqs = vec![100.0, 1_000.0, 10_000.0];
        let ac = Ac { frequencies: freqs.clone() };

        struct CollectSink { pub points: Vec<(f64, Vec<f64>)> }
        impl StreamingSink for CollectSink {
            fn emit_point(&mut self, sv: f64, vals: &[f64]) -> Result<(), SimError> {
                self.points.push((sv, vals.to_vec()));
                Ok(())
            }
            fn finalize(&mut self) -> Result<(), SimError> { Ok(()) }
        }

        let mut sink = CollectSink { points: Vec::new() };
        ac.run(&mut ckt, &registry, &config, &mut cache, &mut sink)
            .expect("streaming run should succeed");

        // Use linear sweep with exactly 3 points matching `freqs`: 100, 1000, 10000.
        // Linear with npoints=3 over [100, 10000] would give [100, 5050, 10000], which
        // doesn't match. Instead use Decade sweep or run standalone at the same exact
        // frequencies by constructing a custom AcConfig with npoints matching.
        // Simplest: run `run_ac` at the same freqs via a single-frequency AcConfig
        // for each point, then collect.
        let standalone_mags_all: Vec<Vec<f64>> = freqs.iter().map(|&f| {
            let cfg = AcConfig::new(f, f, 1, AcSweepType::Linear);
            run_ac(&ckt, &registry, &cfg).expect("standalone run should succeed")
                .node_magnitudes.into_iter().next().expect("at least one freq point")
        }).collect();
        let standalone = standalone_mags_all;

        // Verify at least one node has a non-zero magnitude in the standalone result.
        let standalone_nonzero = standalone.iter()
            .any(|mags_at_freq| mags_at_freq.iter().any(|&m| m > 1e-12));
        assert!(standalone_nonzero, "standalone run also produced all-zero magnitudes");

        // For each frequency the magnitudes from both paths must agree to < 0.1%.
        for (fi, &freq) in freqs.iter().enumerate() {
            let stream_mags = &sink.points[fi].1;
            let standalone_mags = &standalone[fi];
            for (ni, (&sm, &stm)) in stream_mags.iter().zip(standalone_mags.iter()).enumerate() {
                let diff = (sm - stm).abs();
                let tol = 1e-3 * stm.max(1e-15);
                assert!(
                    diff < tol,
                    "node {ni} at {freq} Hz: streaming={sm:.6e} standalone={stm:.6e} diff={diff:.2e}"
                );
            }
        }
    }

    /// Build a voltage-source driven RC low-pass filter.
    ///
    /// Topology: V1 (AC=1) from `in` to GND, R1 (1 kΩ) from `in` to `out`,
    /// C1 (1 nF) from `out` to GND.
    ///
    /// f_3dB = 1/(2π·R·C) = 1/(2π·1000·1e-9) ≈ 159.15 kHz
    fn rc_vsource_circuit() -> Circuit {
        let mut ckt = Circuit::new();
        let n_in  = ckt.add_node("in");
        let n_out = ckt.add_node("out");

        // Voltage source V1: AC=1, from `in` to GND
        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n_in), (1, NodeId::GROUND)],
        )
        .with_param("dc", 0.0);

        // Resistor R1: 1 kΩ from `in` to `out`
        let r1 = DeviceInstance::new(
            DeviceId::new(1),
            "R1",
            DeviceKind::Resistor,
            &[(0, n_in), (1, n_out)],
        )
        .with_param("resistance", 1_000.0);

        // Capacitor C1: 1 nF from `out` to GND
        let c1 = DeviceInstance::new(
            DeviceId::new(2),
            "C1",
            DeviceKind::Capacitor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", 1e-9);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(c1);
        ckt.build_topology();

        // V1 is a voltage source: branch_index = 0, branch_row = num_vars + 0 = 2.
        // Stimulus: AC phasor of magnitude 1.0 at phase 0.
        let num_vars = ckt.num_vars() as usize;
        let branch_row = num_vars; // V1 branch_index = 0
        ckt.add_ac_stimulus(incspice_core::AcStimulus::VoltageSource(branch_row, 1.0, 0.0));
        ckt
    }

    /// At the -3 dB frequency of an RC low-pass, the output magnitude must be
    /// 0.707 ± 5% of the input.
    #[test]
    fn test_ac_rc_lowpass_3db_frequency() {
        let ckt = rc_vsource_circuit();
        let registry = DeviceRegistry::new_default();

        // R=1k, C=1n → f_3dB = 1/(2π·1e-3) ≈ 159_154.9 Hz
        let f_3db = 1.0 / (2.0 * std::f64::consts::PI * 1_000.0 * 1e-9);
        let cfg = AcConfig::new(f_3db, f_3db, 1, AcSweepType::Linear);
        let out = run_ac(&ckt, &registry, &cfg).expect("AC should succeed");

        // Node index for `out` = 1 (second real node after `in`=0)
        let out_node_idx = 1;
        let re = out.node_reals[0][out_node_idx];
        let im = out.node_imags[0][out_node_idx];
        let mag = re.hypot(im);

        assert!(
            (mag - std::f64::consts::FRAC_1_SQRT_2).abs() < 0.05,
            "At f_3dB={f_3db:.1} Hz, expected |V(out)|≈0.707 but got {mag:.4}"
        );
    }

    /// At DC (very low frequency), the RC low-pass output ≈ 1.0.
    /// At high frequency (100× f_3dB), the output must be well attenuated.
    #[test]
    fn test_ac_rc_lowpass_rolloff() {
        let ckt = rc_vsource_circuit();
        let registry = DeviceRegistry::new_default();

        let f_3db = 1.0 / (2.0 * std::f64::consts::PI * 1_000.0 * 1e-9);

        // Low-frequency: well below f_3dB → magnitude near 1.0
        let cfg_low = AcConfig::new(f_3db * 0.01, f_3db * 0.01, 1, AcSweepType::Linear);
        let out_low = run_ac(&ckt, &registry, &cfg_low).expect("AC low-freq");
        let re_l = out_low.node_reals[0][1];
        let im_l = out_low.node_imags[0][1];
        let mag_low = re_l.hypot(im_l);
        assert!(
            mag_low > 0.99,
            "Low-freq magnitude should be near 1.0, got {mag_low:.4}"
        );

        // High-frequency: 100× f_3dB → |H| ≈ 1/100 = 0.01
        let cfg_high = AcConfig::new(f_3db * 100.0, f_3db * 100.0, 1, AcSweepType::Linear);
        let out_high = run_ac(&ckt, &registry, &cfg_high).expect("AC high-freq");
        let re_h = out_high.node_reals[0][1];
        let im_h = out_high.node_imags[0][1];
        let mag_high = re_h.hypot(im_h);
        assert!(
            mag_high < 0.015,
            "High-freq magnitude should be well below 0.015, got {mag_high:.4}"
        );
    }

    /// RLC bandpass: at resonance the parallel LC load has high impedance
    /// so V(out) approaches V(in).  Topology:
    ///   V1 (AC=1) from `in` to GND → R1 (50Ω) → `out` || L1 (1µH) || C1 (1nF)
    ///   f0 = 1/(2π√(LC)) ≈ 5.033 MHz
    #[test]
    fn test_ac_rlc_resonance() {
        let mut ckt = Circuit::new();
        let n_in  = ckt.add_node("in");
        let n_out = ckt.add_node("out");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n_in), (1, NodeId::GROUND)],
        )
        .with_param("dc", 0.0);

        let r1 = DeviceInstance::new(
            DeviceId::new(1),
            "R1",
            DeviceKind::Resistor,
            &[(0, n_in), (1, n_out)],
        )
        .with_param("resistance", 50.0);

        let l1 = DeviceInstance::new(
            DeviceId::new(2),
            "L1",
            DeviceKind::Inductor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("inductance", 1e-6);

        let c1 = DeviceInstance::new(
            DeviceId::new(3),
            "C1",
            DeviceKind::Capacitor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", 1e-9);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(l1);
        ckt.add_device(c1);
        ckt.build_topology();

        // V1 branch_index=0, L1 branch_index=1.
        // V1 branch_row = num_vars + 0 = 2.
        let num_vars = ckt.num_vars() as usize;
        ckt.add_ac_stimulus(incspice_core::AcStimulus::VoltageSource(num_vars, 1.0, 0.0));

        let registry = DeviceRegistry::new_default();
        let l = 1e-6_f64;
        let c = 1e-9_f64;
        let f0 = 1.0 / (2.0 * std::f64::consts::PI * (l * c).sqrt());

        let cfg = AcConfig::new(f0, f0, 1, AcSweepType::Linear);
        let out = run_ac(&ckt, &registry, &cfg).expect("RLC AC solve");

        // out node is index 1
        let re = out.node_reals[0][1];
        let im = out.node_imags[0][1];
        let mag = re.hypot(im);

        // At resonance, Z_LC → ∞ (ideal).  With R=50Ω, Z_LC is large but finite
        // due to pure-reactance cancellation.  |V(out)/V(in)| approaches 1.0.
        // We check that the magnitude is high (> 0.5) — indicative of resonance.
        assert!(
            mag > 0.5,
            "At RLC resonance f0={f0:.0} Hz, expected |V(out)| >> 0.5, got {mag:.4}"
        );
    }

    #[test]
    fn test_ac_config_new_stores_fields() {
        let cfg = AcConfig::new(100.0, 1e6, 50, AcSweepType::Decade);
        assert!((cfg.start - 100.0).abs() < 1e-12);
        assert!((cfg.stop - 1e6).abs() < 1e-12);
        assert_eq!(cfg.npoints, 50);
        assert_eq!(cfg.sweep, AcSweepType::Decade);
    }

    #[test]
    fn test_generate_frequencies_linear_npoints() {
        let cfg = AcConfig::new(100.0, 1000.0, 5, AcSweepType::Linear);
        let freqs = generate_ac_frequencies(&cfg);
        assert_eq!(freqs.len(), 5);
        assert!((freqs[0] - 100.0).abs() < 1e-9);
        assert!((freqs[4] - 1000.0).abs() < 1e-9);
    }

    #[test]
    fn test_generate_frequencies_linear_monotone() {
        let cfg = AcConfig::new(1.0, 100.0, 10, AcSweepType::Linear);
        let freqs = generate_ac_frequencies(&cfg);
        for i in 1..freqs.len() {
            assert!(freqs[i] > freqs[i-1], "not monotone at i={i}");
        }
    }

    #[test]
    fn test_generate_frequencies_decade_covers_range() {
        let cfg = AcConfig::new(10.0, 10_000.0, 5, AcSweepType::Decade);
        let freqs = generate_ac_frequencies(&cfg);
        assert!(!freqs.is_empty());
        assert!((freqs[0] - 10.0).abs() < 1e-6, "first freq={}", freqs[0]);
        let last = *freqs.last().unwrap();
        assert!((last - 10_000.0).abs() < 1.0, "last freq={last}");
    }

    #[test]
    fn test_generate_frequencies_octave_covers_range() {
        let cfg = AcConfig::new(100.0, 3200.0, 3, AcSweepType::Octave);
        let freqs = generate_ac_frequencies(&cfg);
        assert!(!freqs.is_empty());
        assert!((freqs[0] - 100.0).abs() < 1.0, "first freq={}", freqs[0]);
        let last = *freqs.last().unwrap();
        assert!((last - 3200.0).abs() < 50.0, "last freq={last}");
    }

    #[test]
    fn test_ac_result_phases_between_neg_pi_and_pi() {
        let ckt = rc_vsource_circuit();
        let registry = DeviceRegistry::new_default();
        let f_3db = 1.0 / (2.0 * std::f64::consts::PI * 1_000.0 * 1e-9);
        let cfg = AcConfig::new(f_3db * 0.1, f_3db * 10.0, 5, AcSweepType::Linear);
        let result = run_ac(&ckt, &registry, &cfg).unwrap();

        for (fi, phases) in result.node_phases.iter().enumerate() {
            for (ni, &phase) in phases.iter().enumerate() {
                assert!(
                    phase >= -std::f64::consts::PI - 1e-9 && phase <= std::f64::consts::PI + 1e-9,
                    "phase[{fi}][{ni}]={phase} out of [-π, π]"
                );
            }
        }
    }

    #[test]
    fn test_ac_magnitude_equals_sqrt_real2_plus_imag2() {
        let ckt = rc_vsource_circuit();
        let registry = DeviceRegistry::new_default();
        let cfg = AcConfig::new(1e3, 1e6, 5, AcSweepType::Linear);
        let result = run_ac(&ckt, &registry, &cfg).unwrap();

        for fi in 0..result.frequencies.len() {
            for ni in 0..result.node_magnitudes[fi].len() {
                let re = result.node_reals[fi][ni];
                let im = result.node_imags[fi][ni];
                let expected = re.hypot(im);
                let got = result.node_magnitudes[fi][ni];
                assert!((got - expected).abs() < 1e-12,
                    "mag[{fi}][{ni}]={got} != sqrt(re²+im²)={expected}");
            }
        }
    }

    #[test]
    fn test_ac_frequency_count_matches_config() {
        let ckt = rc_circuit();
        let registry = DeviceRegistry::new_default();
        let cfg = AcConfig::new(10.0, 10_000.0, 7, AcSweepType::Linear);
        let result = run_ac(&ckt, &registry, &cfg).unwrap();
        assert_eq!(result.frequencies.len(), result.node_magnitudes.len());
        assert_eq!(result.frequencies.len(), result.node_phases.len());
    }

    #[test]
    fn test_ac_frequencies_are_positive() {
        let ckt = rc_circuit();
        let registry = DeviceRegistry::new_default();
        let cfg = AcConfig::new(1.0, 1e6, 10, AcSweepType::Decade);
        let result = run_ac(&ckt, &registry, &cfg).unwrap();
        for &f in &result.frequencies {
            assert!(f > 0.0, "frequency {f} is not positive");
        }
    }

    #[test]
    fn test_ac_magnitudes_nonnegative() {
        let ckt = rc_circuit();
        let registry = DeviceRegistry::new_default();
        let cfg = AcConfig::new(1.0, 1e6, 5, AcSweepType::Decade);
        let result = run_ac(&ckt, &registry, &cfg).unwrap();
        for (fi, mags) in result.node_magnitudes.iter().enumerate() {
            for (ni, &m) in mags.iter().enumerate() {
                assert!(m >= 0.0, "mag[{fi}][{ni}]={m} is negative");
            }
        }
    }

    // ── C matrix completeness audit ─────────────────────────────────────────
    //
    // For every reactive device type, verify that its `eval()` produces a
    // non-empty C Jacobian when capacitance parameters are provided.
    // This catches regressions where a device computes charges (q vector)
    // but forgets to emit the corresponding C = dQ/dV entries, which would
    // make the AC small-signal C matrix incomplete.

    use incspice_solver::device::{
        Bjt, Capacitor, DeviceEval, DeviceModel, Diode, Inductor, JfetLevel1,
        Mesfet, MosfetLevel1,
    };
    use incspice_core::ParamMap;

    /// Helper: sum absolute values of C entries for a given (row, col) pair.
    fn c_abs_sum(eval: &DeviceEval, row: u8, col: u8) -> f64 {
        eval.C
            .iter()
            .filter(|(r, c, _)| *r == row && *c == col)
            .map(|(_, _, v)| v.abs())
            .sum()
    }

    /// Capacitor must produce 4 C entries (symmetric 2x2 stamp).
    #[test]
    fn c_matrix_audit_capacitor() {
        let c = Capacitor;
        let mut p = ParamMap::new();
        p.set("capacitance", 1e-9);
        let eval = c.eval(&[1.0, 0.0], &p);
        assert_eq!(eval.C.len(), 4, "capacitor should stamp 4 C entries");
        assert!(c_abs_sum(&eval, 0, 0) > 0.0, "C[0,0] must be non-zero");
    }

    /// Inductor must produce C entries (branch inductance stamp).
    #[test]
    fn c_matrix_audit_inductor() {
        let l = Inductor;
        let mut p = ParamMap::new();
        p.set("inductance", 1e-6);
        let eval = l.eval_with_branch(&[1.0, 0.0], 0.001, &p);
        assert!(!eval.C.is_empty(), "inductor should stamp C entries (branch inductance)");
    }

    /// Diode must produce C entries when CJ0 > 0 or TT > 0.
    #[test]
    fn c_matrix_audit_diode_junction_cap() {
        let d = Diode;
        let mut p = ParamMap::new();
        p.set("is", 1e-14);
        p.set("cj0", 1e-12); // junction capacitance
        let eval = d.eval(&[0.5, 0.0], &p);
        assert!(!eval.C.is_empty(), "diode with CJ0 should stamp C entries");
        assert!(c_abs_sum(&eval, 0, 0) > 0.0, "diode C[0,0] must be non-zero");
    }

    #[test]
    fn c_matrix_audit_diode_diffusion_cap() {
        let d = Diode;
        let mut p = ParamMap::new();
        p.set("is", 1e-14);
        p.set("tt", 1e-9); // transit time → diffusion capacitance
        let eval = d.eval(&[0.6, 0.0], &p);
        assert!(!eval.C.is_empty(), "diode with TT should stamp C entries (diffusion cap)");
    }

    /// BJT (Gummel-Poon) must produce C entries for CJE, CJC, CJS, and TF.
    #[test]
    fn c_matrix_audit_bjt_cje() {
        let q = Bjt::npn();
        let mut p = ParamMap::new();
        p.set("is", 1e-16);
        p.set("bf", 100.0);
        p.set("cje", 5e-13); // BE junction cap
        let eval = q.eval(&[5.0, 0.7, 0.0], &p);
        assert!(!eval.C.is_empty(), "BJT with CJE should stamp C entries");
        // CJE stamps between base(1) and emitter(2)
        assert!(c_abs_sum(&eval, 1, 2) > 0.0, "BJT CJE: C[1,2] must be non-zero");
        assert!(c_abs_sum(&eval, 2, 1) > 0.0, "BJT CJE: C[2,1] must be non-zero");
    }

    #[test]
    fn c_matrix_audit_bjt_cjc() {
        let q = Bjt::npn();
        let mut p = ParamMap::new();
        p.set("is", 1e-16);
        p.set("bf", 100.0);
        p.set("cjc", 2e-13); // BC junction cap
        let eval = q.eval(&[5.0, 0.7, 0.0], &p);
        assert!(!eval.C.is_empty(), "BJT with CJC should stamp C entries");
        // CJC stamps between base(1) and collector(0)
        assert!(c_abs_sum(&eval, 1, 0) > 0.0, "BJT CJC: C[1,0] must be non-zero");
        assert!(c_abs_sum(&eval, 0, 1) > 0.0, "BJT CJC: C[0,1] must be non-zero");
    }

    #[test]
    fn c_matrix_audit_bjt_cjs() {
        let q = Bjt::npn();
        let mut p = ParamMap::new();
        p.set("is", 1e-16);
        p.set("bf", 100.0);
        p.set("cjs", 1e-13); // collector-substrate cap
        let eval = q.eval(&[5.0, 0.7, 0.0], &p);
        assert!(!eval.C.is_empty(), "BJT with CJS should stamp C entries");
        // CJS stamps at collector(0) to ground
        assert!(c_abs_sum(&eval, 0, 0) > 0.0, "BJT CJS: C[0,0] must be non-zero");
    }

    #[test]
    fn c_matrix_audit_bjt_diffusion_tf() {
        let q = Bjt::npn();
        let mut p = ParamMap::new();
        p.set("is", 1e-16);
        p.set("bf", 100.0);
        p.set("tf", 1e-10); // forward transit time
        let eval = q.eval(&[5.0, 0.7, 0.0], &p);
        assert!(!eval.C.is_empty(), "BJT with TF should stamp C entries (diffusion charge)");
        // TF diffusion charge stamps between base(1) and emitter(2)
        assert!(c_abs_sum(&eval, 1, 1) > 0.0, "BJT TF: C[1,1] must be non-zero");
    }

    /// MOSFET Level 1 must produce C entries for gate and body junction caps.
    #[test]
    fn c_matrix_audit_mosfet_gate_cap() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 2e-5);
        p.set("vto", 0.7);
        p.set("tox", 1e-8); // thin oxide → non-trivial Cox
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        let eval = m.eval(&[3.0, 2.0, 0.0, 0.0], &p);
        assert!(!eval.C.is_empty(), "MOSFET with tox should stamp gate C entries");
        // Gate(1) should have non-zero self-capacitance
        assert!(c_abs_sum(&eval, 1, 1) > 0.0, "MOSFET gate capacitance C[1,1] must be non-zero");
    }

    #[test]
    fn c_matrix_audit_mosfet_body_junction() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 2e-5);
        p.set("vto", 0.7);
        p.set("cbd", 1e-13); // drain-body junction cap
        p.set("cbs", 1e-13); // source-body junction cap
        let eval = m.eval(&[3.0, 2.0, 0.0, 0.0], &p);
        assert!(!eval.C.is_empty(), "MOSFET with CBD/CBS should stamp body junction C entries");
        // Bulk(3) should have non-zero self-capacitance from junction caps
        assert!(c_abs_sum(&eval, 3, 3) > 0.0, "MOSFET bulk junction capacitance C[3,3] must be non-zero");
    }

    /// JFET must produce C entries when CGS/CGD are set.
    #[test]
    fn c_matrix_audit_jfet() {
        let j = JfetLevel1;
        let mut p = ParamMap::new();
        p.set("vto", -2.0);
        p.set("beta", 1e-3);
        p.set("is", 1e-14);
        p.set("cgs", 2e-12);
        p.set("cgd", 1e-12);
        let eval = j.eval(&[5.0, 0.0, 0.0], &p);
        assert!(!eval.C.is_empty(), "JFET with CGS/CGD should stamp C entries");
        assert!(c_abs_sum(&eval, 1, 1) > 0.0, "JFET gate capacitance C[1,1] must be non-zero");
    }

    /// MESFET must produce C entries when CGS/CGD are set.
    #[test]
    fn c_matrix_audit_mesfet() {
        let m = Mesfet::nmos();
        let mut p = ParamMap::new();
        p.set("beta", 1e-3);
        p.set("vth", -0.8);
        p.set("alpha", 2.0);
        p.set("is_gate", 1e-14);
        p.set("cgs", 2e-12);
        p.set("cgd", 1e-12);
        let eval = m.eval(&[3.0, 0.0, 0.0], &p);
        assert!(!eval.C.is_empty(), "MESFET with CGS/CGD should stamp C entries");
        assert!(c_abs_sum(&eval, 0, 0) > 0.0, "MESFET CGD: C[0,0] must be non-zero");
        assert!(c_abs_sum(&eval, 1, 1) > 0.0, "MESFET gate capacitance C[1,1] must be non-zero");
        assert!(c_abs_sum(&eval, 2, 2) > 0.0, "MESFET CGS: C[2,2] must be non-zero");
    }

    /// Verify that stamp_circuit_gc_into produces a non-empty C matrix for
    /// a circuit containing reactive devices.
    #[test]
    fn c_matrix_audit_stamp_gc_nonempty() {
        let ckt = rc_circuit(); // has a capacitor
        let registry = DeviceRegistry::new_default();
        let dim = ckt.mna_dimension();

        // Solve DC operating point first.
        let dc = incspice_solver::Solver::default()
            .solve(&ckt, &registry, None)
            .expect("DC OP should succeed");

        let mut g_triplet = incspice_solver::TripletMatrix::with_capacity(dim, dim, dim * 4);
        let mut c_triplet = incspice_solver::TripletMatrix::with_capacity(dim, dim, dim * 4);
        let mut tmp_g = incspice_solver::DenseVec::zeros(dim);
        let mut tmp_q = incspice_solver::DenseVec::zeros(dim);

        stamp_circuit_gc_into(
            &ckt,
            &dc.solution,
            &registry,
            &mut g_triplet,
            &mut c_triplet,
            &mut tmp_g,
            &mut tmp_q,
        );

        // G matrix must be non-empty (at least the resistor stamps).
        assert!(
            g_triplet.nnz() > 0,
            "G matrix should be non-empty for RC circuit"
        );

        // C matrix must be non-empty (the capacitor stamps).
        assert!(
            c_triplet.nnz() > 0,
            "C matrix should be non-empty for RC circuit with capacitor"
        );
    }

}
