use pisim_core::{AcStimulus, Circuit, SimError, SimOptions};
use pisim_device::DeviceRegistry;
use pisim_linalg::{DenseVec, LinSolver, LinSolverKind, TripletMatrix};
use pisim_solver::{stamp_circuit_gc_into, Solver, SolverConfig, NrConfig};

use crate::result::AcResult;

/// AC sweep type.
#[derive(Debug, Clone, Copy)]
pub enum AcSweepType {
    Linear,
    Decade,
    Octave,
}

/// Configuration for AC small-signal analysis.
#[derive(Debug, Clone)]
pub struct AcConfig {
    pub freq_start: f64,
    pub freq_stop: f64,
    pub num_points: usize,
    pub sweep_type: AcSweepType,
}

impl AcConfig {
    pub fn new(freq_start: f64, freq_stop: f64, num_points: usize, sweep_type: AcSweepType) -> Self {
        Self { freq_start, freq_stop, num_points, sweep_type }
    }
}

fn generate_frequencies(config: &AcConfig) -> Vec<f64> {
    match config.sweep_type {
        AcSweepType::Linear => {
            let denom = (config.num_points.max(1) - 1).max(1) as f64;
            let step = (config.freq_stop - config.freq_start) / denom;
            (0..config.num_points).map(|i| config.freq_start + i as f64 * step).collect()
        }
        AcSweepType::Decade => {
            let log_start = config.freq_start.log10();
            let log_stop = config.freq_stop.log10();
            let num_decades = log_stop - log_start;
            let total_points = (config.num_points as f64 * num_decades).ceil() as usize;
            let step = (log_stop - log_start) / total_points.max(1) as f64;
            (0..=total_points).map(|i| 10.0_f64.powf(log_start + i as f64 * step)).collect()
        }
        AcSweepType::Octave => {
            let log_start = config.freq_start.log2();
            let log_stop = config.freq_stop.log2();
            let num_octaves = log_stop - log_start;
            let total_points = (config.num_points as f64 * num_octaves).ceil() as usize;
            let step = (log_stop - log_start) / total_points.max(1) as f64;
            (0..=total_points).map(|i| 2.0_f64.powf(log_start + i as f64 * step)).collect()
        }
    }
}

/// Run an AC small-signal analysis.
///
/// Algorithm:
/// 1. Solve the DC operating point for linearization.
/// 2. Stamp the constant `G` and `C` Jacobians at the OP via
///    `stamp_circuit_gc_into`.
/// 3. For each frequency, build the 2N x 2N real block system
///    `[ G  -ωC ] [x_re] = [b_re]`
///    `[ ωC  G  ] [x_im] = [b_im]`
///    and solve via the existing real LinSolver.
/// 4. Extract magnitudes and phases per node from the complex result.
///
/// AC stimulus: until a parser-level `ac_mag` parameter is wired up, this
/// injects a unit current into the first non-ground node and documents the
/// limitation here. Resistive circuits return a flat magnitude response.
pub fn run_ac(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &AcConfig,
) -> Result<AcResult, SimError> {
    run_ac_inner(circuit, registry, config, None)
}

/// Run an AC small-signal analysis with simulation options from `.OPTIONS`.
///
/// `opts.temp` / `opts.tnom` are passed through for device linearization
/// temperature (respected by device models that accept a temperature parameter).
pub fn run_ac_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &AcConfig,
    opts: &SimOptions,
) -> Result<AcResult, SimError> {
    run_ac_inner(circuit, registry, config, Some(opts))
}

fn run_ac_inner(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &AcConfig,
    opts: Option<&SimOptions>,
) -> Result<AcResult, SimError> {
    let num_nodes = circuit.num_vars() as usize;
    let dim = circuit.mna_dimension();

    // --- DC operating point for linearization ---
    let solver = match opts {
        Some(o) => Solver::new(SolverConfig { nr: NrConfig::from(o), ..SolverConfig::default() }),
        None => Solver::default(),
    };
    let dc = solver.solve(circuit, registry, None)?;

    // --- Build constant G and C at the OP ---
    let mut g_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut c_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut tmp_residual_g = DenseVec::zeros(dim);
    let mut tmp_residual_q = DenseVec::zeros(dim);
    stamp_circuit_gc_into(
        circuit,
        &dc.solution,
        registry,
        &mut g_triplet,
        &mut c_triplet,
        &mut tmp_residual_g,
        &mut tmp_residual_q,
    );

    // --- AC stimulus ---
    // Use the AcStimulus list populated by the parser from AC-bearing V/I sources.
    // For V-source AC: inject at the branch equation row (KVL row).
    // For I-source AC: inject into the node KCL rows.
    // Fall back to unit current at node 0 when no stimuli are registered (legacy
    // behaviour for netlists without parsed AC sources).
    let stimuli = circuit.ac_stimuli();

    let frequencies = generate_frequencies(config);
    let mut node_magnitudes: Vec<Vec<f64>> = Vec::with_capacity(frequencies.len());
    let mut node_phases: Vec<Vec<f64>> = Vec::with_capacity(frequencies.len());
    let mut node_reals: Vec<Vec<f64>> = Vec::with_capacity(frequencies.len());
    let mut node_imags: Vec<Vec<f64>> = Vec::with_capacity(frequencies.len());

    // Pre-allocated scratch for the per-frequency 2N x 2N block system.
    let n2 = 2 * dim;
    let mut block_triplet = TripletMatrix::with_capacity(n2, n2, dim * 8);
    let mut rhs = DenseVec::zeros(n2);

    for &freq in &frequencies {
        let omega = 2.0 * std::f64::consts::PI * freq;

        // Build the block matrix:
        //   rows/cols [0..dim) = real part
        //   rows/cols [dim..2dim) = imag part
        // Top-left: G, top-right: -omega*C
        // Bot-left: omega*C, bot-right: G
        block_triplet.clear();
        g_triplet.entries().for_each(|(r, c, v)| {
            block_triplet.add(r, c, v);
            block_triplet.add(dim + r, dim + c, v);
        });
        c_triplet.entries().for_each(|(r, c, v)| {
            block_triplet.add(r, dim + c, -omega * v);
            block_triplet.add(dim + r, c, omega * v);
        });

        // Build RHS from registered AC stimuli.
        rhs.fill_zero();
        if stimuli.is_empty() {
            // Legacy fallback: unit current at node 0.
            rhs[0] = 1.0;
        } else {
            for &stim in stimuli {
                match stim {
                    AcStimulus::VoltageSource(br, re, im) => {
                        if br < dim {
                            rhs[br] = re;
                            rhs[dim + br] = im;
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

        let csc = block_triplet.to_csc();
        let lin = LinSolver::factorize(LinSolverKind::SparseLu, &csc)
            .map_err(|_| SimError::Analysis("AC: singular block matrix".into()))?;
        let sol = lin.solve(&rhs)?;

        // Extract magnitudes, phases, reals, and imags for the node-voltage entries only.
        let mut mags = Vec::with_capacity(num_nodes);
        let mut phs = Vec::with_capacity(num_nodes);
        let mut res = Vec::with_capacity(num_nodes);
        let mut ims = Vec::with_capacity(num_nodes);
        for i in 0..num_nodes {
            let re = sol[i];
            let im = sol[dim + i];
            mags.push((re * re + im * im).sqrt());
            phs.push(im.atan2(re));
            res.push(re);
            ims.push(im);
        }
        node_magnitudes.push(mags);
        node_phases.push(phs);
        node_reals.push(res);
        node_imags.push(ims);
    }

    Ok(AcResult { frequencies, node_magnitudes, node_phases, node_reals, node_imags })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frequency_generation_linear() {
        let config = AcConfig::new(1.0, 100.0, 10, AcSweepType::Linear);
        let freqs = generate_frequencies(&config);
        assert_eq!(freqs.len(), 10);
        assert!((freqs[0] - 1.0).abs() < 1e-10);
        assert!((freqs[9] - 100.0).abs() < 1e-10);
    }

    #[test]
    fn frequency_generation_decade() {
        let config = AcConfig::new(1.0, 1e6, 10, AcSweepType::Decade);
        let freqs = generate_frequencies(&config);
        assert!(freqs.len() > 10);
        assert!((freqs[0] - 1.0).abs() < 1e-10);
    }
}
