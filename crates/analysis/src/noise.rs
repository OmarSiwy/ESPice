//! Small-signal noise analysis (`.NOISE`).
//!
//! Algorithm:
//! 1. Run DC operating point to get bias currents / conductances.
//! 2. Build the complex admittance matrix Y(jω) at each frequency using the
//!    same G/C Jacobians used by AC analysis.
//! 3. For each noisy device i, compute its noise current PSD S_i(f) [A²/Hz].
//! 4. For each frequency, solve `Y · v_out = e_i` where `e_i` injects a unit
//!    noise current at device i's nodes. The |V_out|² × S_i(f) term gives
//!    that device's contribution to the output noise PSD.
//! 5. Sum all contributions for total output-referred noise PSD.
//! 6. Compute input-referred PSD = output PSD / |H|² where H is the
//!    transfer function from the `input_source` to the output node.

use incspice_core::{Circuit, DeviceId, DeviceKind, SimError, SimOptions};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::linalg::{DenseVec, LinSolver, LinSolverKind, TripletMatrix};
use incspice_solver::{NrConfig, Solver, SolverConfig, stamp_circuit_gc_into};

use crate::ac::AcSweepType;

// Physical constants
const BOLTZMANN: f64 = 1.380649e-23; // J/K
const ELEM_CHARGE: f64 = 1.602176634e-19; // C
const DEFAULT_TEMP_K: f64 = 300.15; // K (27°C)

/// Configuration for a `.NOISE` analysis sweep.
#[derive(Debug, Clone)]
pub struct NoiseConfig {
    /// Sweep type: Linear, Decade, or Octave.
    pub sweep: AcSweepType,
    /// Start frequency [Hz].
    pub start: f64,
    /// Stop frequency [Hz].
    pub stop: f64,
    /// Points per decade/octave, or total points for linear sweep.
    pub npoints: usize,
    /// Output node name, e.g. `"out"`.
    pub output_node: String,
    /// Input source name (voltage source), e.g. `"V1"`.
    pub input_source: String,
}

/// Noise contribution from a single device.
#[derive(Debug, Clone)]
pub struct DeviceNoiseContribution {
    pub device_id: DeviceId,
    pub device_name: String,
    /// Output-referred noise PSD [V²/Hz] — one entry per frequency point.
    pub total_v2_per_hz: Vec<f64>,
}

/// Full result of a noise analysis.
#[derive(Debug, Clone)]
pub struct NoiseResult {
    /// Frequency points [Hz].
    pub freqs: Vec<f64>,
    /// Total output-referred noise PSD [V²/Hz].
    pub output_spectrum_v2_per_hz: Vec<f64>,
    /// Total input-referred noise PSD [V²/Hz].
    pub input_spectrum_v2_per_hz: Vec<f64>,
    /// Per-device breakdown of output-referred noise contributions.
    pub contributions: Vec<DeviceNoiseContribution>,
}

/// `Analysis`-trait wrapper for `.NOISE`.
pub struct NoiseAnalysis {
    /// Output node name (e.g. `"out"`).
    pub output_node: String,
    /// Input voltage source name (e.g. `"v1"`).
    pub input_source: String,
    /// Frequency sweep for noise computation.
    pub sweep: AcSweepType,
    /// Start frequency [Hz].
    pub fstart: f64,
    /// Stop frequency [Hz].
    pub fstop: f64,
    /// Points per decade/octave, or total linear points.
    pub npoints: usize,
}

impl crate::Analysis for NoiseAnalysis {
    fn run(
        &self,
        circuit: &mut Circuit,
        registry: &incspice_solver::device::DeviceRegistry,
        _config: &incspice_solver::newton::NrConfig,
        _cache: &mut incspice_cache::CacheManager,
        sink: &mut dyn incspice_core::StreamingSink,
    ) -> Result<(), crate::AnalysisError> {
        let cfg = NoiseConfig {
            sweep: self.sweep.clone(),
            start: self.fstart,
            stop: self.fstop,
            npoints: self.npoints,
            output_node: self.output_node.clone(),
            input_source: self.input_source.clone(),
        };
        let result = run_noise(circuit, registry, &cfg)?;
        for (i, &f) in result.freqs.iter().enumerate() {
            let out_psd = result.output_spectrum_v2_per_hz.get(i).copied().unwrap_or(0.0);
            let in_psd = result.input_spectrum_v2_per_hz.get(i).copied().unwrap_or(0.0);
            sink.emit_point(f, &[out_psd, in_psd])?;
        }
        sink.finalize()?;
        Ok(())
    }

    fn name(&self) -> &str { "noise" }
}

/// Run a noise analysis with default simulation options.
pub fn run_noise(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &NoiseConfig,
) -> Result<NoiseResult, SimError> {
    run_noise_inner(circuit, registry, cfg, None)
}

/// Run a noise analysis with explicit simulation options (e.g. from `.OPTIONS`).
pub fn run_noise_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &NoiseConfig,
    opts: &SimOptions,
) -> Result<NoiseResult, SimError> {
    run_noise_inner(circuit, registry, cfg, Some(opts))
}

// ---------------------------------------------------------------------------
// Internal implementation
// ---------------------------------------------------------------------------

fn run_noise_inner(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &NoiseConfig,
    opts: Option<&SimOptions>,
) -> Result<NoiseResult, SimError> {
    let temp_k = opts.map(|o| o.temp).unwrap_or(DEFAULT_TEMP_K);

    // ── 1. DC operating point ────────────────────────────────────────────────
    let solver = match opts {
        Some(o) => Solver::new(SolverConfig {
            nr: NrConfig::from(o),
            ..SolverConfig::default()
        }),
        None => Solver::default(),
    };
    let dc = solver.solve(circuit, registry, None)?;
    let dc_solution = &dc.solution;

    let dim = circuit.mna_dimension();
    let num_nodes = circuit.num_vars() as usize;

    // ── 2. Build G and C Jacobians at the OP ────────────────────────────────
    let mut g_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut c_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut tmp_g = DenseVec::zeros(dim);
    let mut tmp_q = DenseVec::zeros(dim);
    stamp_circuit_gc_into(
        circuit,
        dc_solution,
        registry,
        &mut g_triplet,
        &mut c_triplet,
        &mut tmp_g,
        &mut tmp_q,
    );

    // ── 3. Resolve output node index ─────────────────────────────────────────
    let output_node_id = circuit.find_node(&cfg.output_node).ok_or_else(|| {
        SimError::Analysis(format!(
            "noise: output node '{}' not found",
            cfg.output_node
        ))
    })?;
    let out_idx = output_node_id.index() as usize;
    // Ground (index 0) has no MNA row; node matrix indices start at 1.
    // `NodeId::index()` returns the raw index; index 0 is ground.
    if out_idx == 0 {
        return Err(SimError::Analysis(
            "noise: output node cannot be ground".into(),
        ));
    }
    let out_mna = out_idx - 1; // 0-based MNA row for output node

    // ── 4. Resolve input source branch index ─────────────────────────────────
    let input_branch_mna: Option<usize> = circuit
        .devices()
        .iter()
        .find(|d| {
            d.name.to_lowercase() == cfg.input_source.to_lowercase()
                && d.kind == DeviceKind::VoltageSource
        })
        .and_then(|d| d.branch_index)
        .map(|bi| num_nodes + bi as usize);

    // ── 5. Collect per-device noise sources at OP ────────────────────────────
    let noise_sources: Vec<DeviceNoiseSource> = circuit
        .devices()
        .iter()
        .flat_map(|dev| {
            device_noise_sources(dev, dc_solution, circuit, registry, temp_k)
        })
        .collect();

    // ── 6. Sweep frequencies ─────────────────────────────────────────────────
    let freqs = generate_noise_frequencies(cfg);
    let nf = freqs.len();

    // Pre-allocate per-device contribution accumulators (SoA: one Vec per device).
    let mut contrib_v2: Vec<Vec<f64>> = noise_sources.iter().map(|_| vec![0.0_f64; nf]).collect();
    let mut output_spectrum = vec![0.0_f64; nf];
    let mut h_sq: Vec<f64> = vec![1.0_f64; nf]; // |H(f)|² for input-referral

    // Scratch buffers for 2N×2N block system (reused across freq iterations).
    let n2 = 2 * dim;
    let mut block_triplet = TripletMatrix::with_capacity(n2, n2, dim * 8);
    let mut rhs = DenseVec::zeros(n2);

    for (fi, &freq) in freqs.iter().enumerate() {
        let omega = 2.0 * std::f64::consts::PI * freq;

        // Build block admittance matrix Y(jω):
        //   top-left:    G
        //   top-right:  -ωC
        //   bot-left:    ωC
        //   bot-right:   G
        block_triplet.clear();
        g_triplet.entries().for_each(|(r, c, v)| {
            block_triplet.add(r, c, v);
            block_triplet.add(dim + r, dim + c, v);
        });
        c_triplet.entries().for_each(|(r, c, v)| {
            block_triplet.add(r, dim + c, -omega * v);
            block_triplet.add(dim + r, c, omega * v);
        });

        let csc = block_triplet.to_csc();
        let lin = LinSolver::factorize(LinSolverKind::SparseLu, &csc)
            .map_err(|_| SimError::Analysis("noise: singular admittance matrix".into()))?;

        // ── Compute |H|² (transfer from input source to output node) ─────
        if let Some(branch_row) = input_branch_mna {
            rhs.fill_zero();
            if branch_row < dim {
                rhs[branch_row] = 1.0; // unit voltage stimulus at branch equation
            }
            let h_sol = lin.solve(&rhs)?;
            let h_re = if out_mna < dim { h_sol[out_mna] } else { 0.0 };
            let h_im = if out_mna < dim {
                h_sol[dim + out_mna]
            } else {
                0.0
            };
            h_sq[fi] = h_re * h_re + h_im * h_im;
        }

        // ── Accumulate noise from each device ───────────────────────────────
        for (si, src) in noise_sources.iter().enumerate() {
            let s_i = src.psd_a2_per_hz(freq); // noise current PSD [A²/Hz]
            if s_i <= 0.0 {
                continue;
            }

            // Inject unit current at positive terminal, extract output voltage.
            rhs.fill_zero();
            if let Some(pos_mna) = src.pos_mna {
                rhs[pos_mna] = 1.0;
            }
            if let Some(neg_mna) = src.neg_mna {
                // Subtract from negative terminal (differential injection).
                rhs[neg_mna] -= 1.0;
            }

            let v_sol = lin.solve(&rhs)?;
            let v_re = if out_mna < dim { v_sol[out_mna] } else { 0.0 };
            let v_im = if out_mna < dim {
                v_sol[dim + out_mna]
            } else {
                0.0
            };
            let z_sq = v_re * v_re + v_im * v_im; // |V_out / I_in|²

            let contribution = z_sq * s_i; // [V²/Hz]
            contrib_v2[si][fi] = contribution;
            output_spectrum[fi] += contribution;
        }
    }

    // ── 7. Input-referred noise ───────────────────────────────────────────────
    let input_spectrum: Vec<f64> = output_spectrum
        .iter()
        .zip(h_sq.iter())
        .map(|(&s_out, &h2)| if h2 > 1e-300 { s_out / h2 } else { 0.0 })
        .collect();

    // ── 8. Assemble per-device contribution structs ───────────────────────────
    let contributions: Vec<DeviceNoiseContribution> = noise_sources
        .into_iter()
        .zip(contrib_v2.into_iter())
        .map(|(src, v2)| DeviceNoiseContribution {
            device_id: src.device_id,
            device_name: src.device_name,
            total_v2_per_hz: v2,
        })
        .collect();

    Ok(NoiseResult {
        freqs,
        output_spectrum_v2_per_hz: output_spectrum,
        input_spectrum_v2_per_hz: input_spectrum,
        contributions,
    })
}

// ---------------------------------------------------------------------------
// Frequency sweep generation (mirrors ac.rs)
// ---------------------------------------------------------------------------

fn generate_noise_frequencies(cfg: &NoiseConfig) -> Vec<f64> {
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
            let num_decades = log_stop - log_start;
            let total = (cfg.npoints as f64 * num_decades).ceil() as usize;
            let step = (log_stop - log_start) / total.max(1) as f64;
            (0..=total)
                .map(|i| 10.0_f64.powf(log_start + i as f64 * step))
                .collect()
        }
        AcSweepType::Octave => {
            let log_start = cfg.start.log2();
            let log_stop = cfg.stop.log2();
            let num_octaves = log_stop - log_start;
            let total = (cfg.npoints as f64 * num_octaves).ceil() as usize;
            let step = (log_stop - log_start) / total.max(1) as f64;
            (0..=total)
                .map(|i| 2.0_f64.powf(log_start + i as f64 * step))
                .collect()
        }
    }
}

// ---------------------------------------------------------------------------
// Per-device noise source descriptor
// ---------------------------------------------------------------------------

/// A noise current source descriptor for a single device.
///
/// Uses SoA-friendly flat fields rather than trait objects.
struct DeviceNoiseSource {
    device_id: DeviceId,
    device_name: String,
    /// 0-based MNA row of the positive noise injection terminal (None = ground).
    pos_mna: Option<usize>,
    /// 0-based MNA row of the negative noise injection terminal (None = ground).
    neg_mna: Option<usize>,
    /// Noise model variant.
    model: NoiseModel,
}

impl DeviceNoiseSource {
    /// Evaluate noise current PSD [A²/Hz] at frequency `f` [Hz].
    #[inline]
    fn psd_a2_per_hz(&self, f: f64) -> f64 {
        self.model.psd(f)
    }
}

/// Noise model — one variant per supported formula.
enum NoiseModel {
    /// Thermal (Johnson-Nyquist): S_i = 4kT/R  [A²/Hz]
    Thermal { four_kt_over_r: f64 },
    /// Shot: S_i = 2qI  [A²/Hz]
    Shot { two_q_i: f64 },
    /// BJT combined: S_i = 2qI_C + 2qI_B + Kf·I_B^Af / f
    BjtCombined { base_psd: f64, kf_iaf: f64 },
    /// MOSFET: S_i = (8/3)kT·gm + Kf·I_D^Af/(Cox·W·Leff·f)
    MosfetCombined { thermal_psd: f64, kf_term: f64 },
}

impl NoiseModel {
    #[inline]
    fn psd(&self, f: f64) -> f64 {
        match self {
            Self::Thermal { four_kt_over_r } => *four_kt_over_r,
            Self::Shot { two_q_i } => *two_q_i,
            Self::BjtCombined { base_psd, kf_iaf } => {
                base_psd + if f > 0.0 { kf_iaf / f } else { 0.0 }
            }
            Self::MosfetCombined {
                thermal_psd,
                kf_term,
            } => thermal_psd + if f > 0.0 { kf_term / f } else { 0.0 },
        }
    }
}

// ---------------------------------------------------------------------------
// Map a DeviceInstance to its noise source at the DC operating point
// ---------------------------------------------------------------------------

/// Convert node index to 0-based MNA row.  Returns None for ground (index 0).
#[inline]
fn node_to_mna(node_id: incspice_core::NodeId) -> Option<usize> {
    let idx = node_id.index();
    if idx == 0 { None } else { Some(idx - 1) }
}

fn device_noise_sources(
    dev: &incspice_core::DeviceInstance,
    dc_solution: &[f64],
    _circuit: &Circuit,
    registry: &DeviceRegistry,
    temp_k: f64,
) -> Vec<DeviceNoiseSource> {
    match dev.kind {
        // ── Resistor thermal noise: S_i = 4kT/R ──────────────────────────────
        DeviceKind::Resistor => {
            let r = dev.params.get("resistance").unwrap_or(1e3);
            if r <= 0.0 {
                return vec![];
            }
            let (pos_node, neg_node) = match (dev.node(0), dev.node(1)) {
                (Some(p), Some(n)) => (p, n),
                _ => return vec![],
            };
            vec![DeviceNoiseSource {
                device_id: dev.id,
                device_name: dev.name.clone(),
                pos_mna: node_to_mna(pos_node),
                neg_mna: node_to_mna(neg_node),
                model: NoiseModel::Thermal {
                    four_kt_over_r: 4.0 * BOLTZMANN * temp_k / r,
                },
            }]
        }

        // ── Diode shot noise: S_i = 2qI_d ────────────────────────────────────
        DeviceKind::Diode => {
            let (anode, cathode) = match (dev.node(0), dev.node(1)) {
                (Some(a), Some(c)) => (a, c),
                _ => return vec![],
            };
            let v_a = node_voltage(anode, dc_solution);
            let v_k = node_voltage(cathode, dc_solution);
            let v_d = v_a - v_k;
            let is = dev.params.get("is").unwrap_or(1e-14);
            let n = dev.params.get("n").unwrap_or(1.0);
            let vt = BOLTZMANN * temp_k / ELEM_CHARGE;
            let i_d = is * ((v_d / (n * vt)).exp() - 1.0);
            let i_d_abs = i_d.abs();
            vec![DeviceNoiseSource {
                device_id: dev.id,
                device_name: dev.name.clone(),
                pos_mna: node_to_mna(anode),
                neg_mna: node_to_mna(cathode),
                model: NoiseModel::Shot {
                    two_q_i: 2.0 * ELEM_CHARGE * i_d_abs,
                },
            }]
        }

        // ── BJT noise ─────────────────────────────────────────────────────────
        // Separate noise sources at correct terminal pairs:
        //   1. Collector shot noise: 2qIc between collector-emitter
        //   2. Base shot noise + 1/f: 2qIb + Kf*Ib^Af/f between base-emitter
        //   3. Base resistance thermal noise: 4kT/Rb between base-emitter
        //      (approximation: rb noise is between external and internal base,
        //       but without internal base node, inject at base-emitter)
        //   4. Collector resistance thermal noise: 4kT/Rc between collector-emitter
        //   5. Emitter resistance thermal noise: 4kT/Re between emitter (and ground/emitter)
        DeviceKind::BjtNpn | DeviceKind::BjtPnp => {
            let (collector, base, emitter) = match (dev.node(0), dev.node(1), dev.node(2)) {
                (Some(c), Some(b), Some(e)) => (c, b, e),
                _ => return vec![],
            };

            let v_c = node_voltage(collector, dc_solution);
            let v_b = node_voltage(base, dc_solution);
            let v_e = node_voltage(emitter, dc_solution);

            // Use actual DC OP currents from device evaluation instead of
            // simplified Ebers-Moll.  The BJT eval returns terminal currents
            // in g[0] = Ic, g[1] = Ib, g[2] = Ie.
            let voltages = [v_c, v_b, v_e];
            let (i_c, i_b) = if let Some(model) = registry.get(dev.kind) {
                let ev = model.eval(&voltages, &dev.params);
                (ev.g[0].abs(), ev.g[1].abs())
            } else {
                // Fallback: simplified Ebers-Moll (should not happen).
                let is = dev.params.get("is").unwrap_or(1e-16);
                let bf = dev.params.get("bf").unwrap_or(100.0);
                let vt = BOLTZMANN * temp_k / ELEM_CHARGE;
                let is_pnp = dev.kind == DeviceKind::BjtPnp;
                let (v_be, v_bc) = if is_pnp {
                    (v_e - v_b, v_c - v_b)
                } else {
                    (v_b - v_e, v_b - v_c)
                };
                let ic = (is * (v_be / vt).exp() - is * (v_bc / vt).exp()).abs();
                (ic, ic / bf)
            };

            let kf = dev.params.get("kf").unwrap_or(0.0);
            let af = dev.params.get("af").unwrap_or(1.0);
            let rb = dev.params.get("rb").unwrap_or(0.0);
            let rc = dev.params.get("rc").unwrap_or(0.0);
            let re = dev.params.get("re").unwrap_or(0.0);

            let col_mna = node_to_mna(collector);
            let bas_mna = node_to_mna(base);
            let emi_mna = node_to_mna(emitter);

            let mut sources = Vec::with_capacity(4);

            // 1. Collector shot noise: 2*q*Ic between C-E
            if i_c > 0.0 {
                sources.push(DeviceNoiseSource {
                    device_id: dev.id,
                    device_name: format!("{}_ic", dev.name),
                    pos_mna: col_mna,
                    neg_mna: emi_mna,
                    model: NoiseModel::Shot {
                        two_q_i: 2.0 * ELEM_CHARGE * i_c,
                    },
                });
            }

            // 2. Base shot noise + 1/f noise: between B-E
            {
                let base_shot = 2.0 * ELEM_CHARGE * i_b;
                let kf_iaf = kf * i_b.powf(af);
                if base_shot > 0.0 || kf_iaf > 0.0 {
                    sources.push(DeviceNoiseSource {
                        device_id: dev.id,
                        device_name: format!("{}_ib", dev.name),
                        pos_mna: bas_mna,
                        neg_mna: emi_mna,
                        model: NoiseModel::BjtCombined {
                            base_psd: base_shot,
                            kf_iaf,
                        },
                    });
                }
            }

            // 3. Base resistance thermal noise: 4kT/Rb between B-E
            if rb > 0.0 {
                sources.push(DeviceNoiseSource {
                    device_id: dev.id,
                    device_name: format!("{}_rb", dev.name),
                    pos_mna: bas_mna,
                    neg_mna: emi_mna,
                    model: NoiseModel::Thermal {
                        four_kt_over_r: 4.0 * BOLTZMANN * temp_k / rb,
                    },
                });
            }

            // 4. Collector resistance thermal noise: 4kT/Rc between C-E
            if rc > 0.0 {
                sources.push(DeviceNoiseSource {
                    device_id: dev.id,
                    device_name: format!("{}_rc", dev.name),
                    pos_mna: col_mna,
                    neg_mna: emi_mna,
                    model: NoiseModel::Thermal {
                        four_kt_over_r: 4.0 * BOLTZMANN * temp_k / rc,
                    },
                });
            }

            // 5. Emitter resistance thermal noise: 4kT/Re between E and ground
            //    (approximation — in ngspice it's between internal and external emitter)
            if re > 0.0 {
                sources.push(DeviceNoiseSource {
                    device_id: dev.id,
                    device_name: format!("{}_re", dev.name),
                    pos_mna: emi_mna,
                    neg_mna: None, // ground approximation
                    model: NoiseModel::Thermal {
                        four_kt_over_r: 4.0 * BOLTZMANN * temp_k / re,
                    },
                });
            }

            sources
        }

        // ── MOSFET noise ─────────────────────────────────────────────────────
        // S_i = (8/3)kT*gm + Kf * I_D^Af / (Cox_per_area * W * Leff * f)
        DeviceKind::MosfetN | DeviceKind::MosfetP => {
            let (drain, gate, source) = match (dev.node(0), dev.node(1), dev.node(2)) {
                (Some(d), Some(g), Some(s)) => (d, g, s),
                _ => return vec![],
            };

            let v_d = node_voltage(drain, dc_solution);
            let v_g = node_voltage(gate, dc_solution);
            let v_s = node_voltage(source, dc_solution);
            // MOSFET has 4 terminals: D=0, G=1, S=2, B=3
            let v_b = dev.node(3).map(|n| node_voltage(n, dc_solution)).unwrap_or(0.0);

            let w = dev.params.get("w").unwrap_or(1e-6);
            let l = dev.params.get("l").unwrap_or(100e-9);
            let ld = dev.params.get("ld").unwrap_or(0.0);
            let leff = (l - 2.0 * ld).max(1e-9);
            let kf = dev.params.get("kf").unwrap_or(0.0);
            let af = dev.params.get("af").unwrap_or(1.0);

            // Cox per unit area [F/m²].  Prefer explicit `cox` param, then
            // derive from `tox`, then fall back to ngspice default tox=1e-7.
            const EPSOX: f64 = 3.453e-11; // eps_SiO2 [F/m]
            let cox_per_area = if let Some(c) = dev.params.get("cox") {
                c
            } else {
                let tox = dev.params.get("tox").unwrap_or(1e-7).max(1e-12);
                EPSOX / tox
            };

            // Use actual DC OP gm and Id from device evaluation instead of
            // recomputing from simplified equations.  The MOSFET eval returns
            // g[0] = Id (drain current) and Jacobian entry G(0,1) = gm
            // (dId/dVgs).
            let voltages = [v_d, v_g, v_s, v_b];
            let (i_d, gm) = if let Some(model) = registry.get(dev.kind) {
                let ev = model.eval(&voltages, &dev.params);
                let id = ev.g[0].abs();
                // Extract gm = dId/dVgs from Jacobian: entry (row=0, col=1).
                let gm_val = ev.G.iter()
                    .find(|(r, c, _)| *r == 0 && *c == 1)
                    .map(|(_, _, v)| v.abs())
                    .unwrap_or(0.0);
                (id, gm_val)
            } else {
                // Fallback: simplified computation (should not happen).
                let is_pmos = dev.kind == DeviceKind::MosfetP
                    || dev.params.get("pmos").unwrap_or(0.0) != 0.0;
                let orient: f64 = if is_pmos { -1.0 } else { 1.0 };
                let v_gs = orient * (v_g - v_s);
                let v_ds = orient * (v_d - v_s);
                let kp = dev.params.get("kp").unwrap_or(120e-6);
                let vth0 = dev.params.get("vto")
                    .or_else(|| dev.params.get("vth0"))
                    .unwrap_or(0.5)
                    .abs();
                let v_ov = v_gs - vth0;
                let gm_val = if v_ov > 0.0 { (kp * (w / leff) * v_ov).max(0.0) } else { 0.0 };
                let id = if v_ov > 0.0 && v_ds >= v_ov {
                    0.5 * kp * (w / leff) * v_ov * v_ov
                } else if v_ov > 0.0 {
                    kp * (w / leff) * (v_ov * v_ds - 0.5 * v_ds * v_ds)
                } else {
                    0.0
                };
                (id, gm_val)
            };

            let thermal_psd = (8.0 / 3.0) * BOLTZMANN * temp_k * gm;
            // Kf * I_D^Af / (Cox_per_area * W * Leff * f) — the 1/f prefactor.
            let cox_l2 = cox_per_area * w * leff;
            let kf_term = if cox_l2 > 0.0 {
                kf * i_d.abs().powf(af) / cox_l2
            } else {
                0.0
            };

            vec![DeviceNoiseSource {
                device_id: dev.id,
                device_name: dev.name.clone(),
                pos_mna: node_to_mna(drain),
                neg_mna: node_to_mna(source),
                model: NoiseModel::MosfetCombined {
                    thermal_psd,
                    kf_term,
                },
            }]
        }

        // ── JFET noise ──────────────────────────────────────────────────────
        // Matching ngspice jfetnoi.c:100-128:
        //   1. Channel thermal noise: S_id = 4kT * (2/3) * |gm| * m
        //   2. Flicker noise: Kf * |Id/m|^Af * m / f
        //   3. RD thermal noise: 4kT * m / RD  (between external/internal drain)
        //   4. RS thermal noise: 4kT * m / RS  (between external/internal source)
        //
        // Since our JFET model has no separate internal nodes, RD/RS noise
        // sources would inject between the same node pair (zero contribution).
        // We include them only when RD/RS > 0, injecting between the external
        // terminal and ground as an approximation (matches BJT RE handling).
        DeviceKind::JfetN | DeviceKind::JfetP => {
            let (drain, gate, source) = match (dev.node(0), dev.node(1), dev.node(2)) {
                (Some(d), Some(g), Some(s)) => (d, g, s),
                _ => return vec![],
            };

            let v_d = node_voltage(drain, dc_solution);
            let v_g = node_voltage(gate, dc_solution);
            let v_s = node_voltage(source, dc_solution);

            let m = dev.params.get("m").unwrap_or(1.0).max(1e-30);
            let kf = dev.params.get("kf").unwrap_or(0.0);
            let af = dev.params.get("af").unwrap_or(1.0);
            let rd = dev.params.get("rd").unwrap_or(0.0);
            let rs = dev.params.get("rs").unwrap_or(0.0);

            // Use actual DC OP gm and Id from device evaluation.
            // JFET eval: g[0] = Id (drain current), Jacobian G(0,1) = gm = dId/dVgs.
            let voltages = [v_d, v_g, v_s];
            let (i_d, gm) = if let Some(model) = registry.get(dev.kind) {
                let ev = model.eval(&voltages, &dev.params);
                let id = ev.g[0].abs();
                let gm_val = ev.G.iter()
                    .find(|(r, c, _)| *r == 0 && *c == 1)
                    .map(|(_, _, v)| v.abs())
                    .unwrap_or(0.0);
                (id, gm_val)
            } else {
                (0.0, 0.0)
            };

            let drn_mna = node_to_mna(drain);
            let src_mna = node_to_mna(source);

            let mut sources = Vec::with_capacity(3);

            // 1+2. Channel thermal + flicker noise between drain-source
            let thermal_psd = 4.0 * BOLTZMANN * temp_k * (2.0 / 3.0) * gm * m;
            let kf_term = kf * (i_d / m).abs().powf(af) * m;
            if thermal_psd > 0.0 || kf_term > 0.0 {
                sources.push(DeviceNoiseSource {
                    device_id: dev.id,
                    device_name: format!("{}_id", dev.name),
                    pos_mna: drn_mna,
                    neg_mna: src_mna,
                    model: NoiseModel::MosfetCombined {
                        thermal_psd,
                        kf_term,
                    },
                });
            }

            // 3. RD thermal noise: 4kT * m / RD
            if rd > 0.0 {
                sources.push(DeviceNoiseSource {
                    device_id: dev.id,
                    device_name: format!("{}_rd", dev.name),
                    pos_mna: drn_mna,
                    neg_mna: None, // external-to-internal drain; approximate as drain-ground
                    model: NoiseModel::Thermal {
                        four_kt_over_r: 4.0 * BOLTZMANN * temp_k * m / rd,
                    },
                });
            }

            // 4. RS thermal noise: 4kT * m / RS
            if rs > 0.0 {
                sources.push(DeviceNoiseSource {
                    device_id: dev.id,
                    device_name: format!("{}_rs", dev.name),
                    pos_mna: src_mna,
                    neg_mna: None, // external-to-internal source; approximate as source-ground
                    model: NoiseModel::Thermal {
                        four_kt_over_r: 4.0 * BOLTZMANN * temp_k * m / rs,
                    },
                });
            }

            sources
        }

        // All other device kinds are noiseless in this model.
        _ => vec![],
    }
}

/// Read the DC node voltage for a given NodeId from the solution vector.
/// Ground (index 0) is always 0 V.
#[inline]
fn node_voltage(node: incspice_core::NodeId, solution: &[f64]) -> f64 {
    let idx = node.index();
    if idx == 0 {
        0.0
    } else {
        solution.get(idx - 1).copied().unwrap_or(0.0)
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ── Formula verification tests ──────────────────────────────────────────

    #[test]
    fn thermal_noise_formula() {
        // R = 1 kΩ at T = 300.15 K → S_i = 4kT/R = 4 * 1.380649e-23 * 300.15 / 1000
        let r = 1000.0_f64;
        let t = 300.15_f64;
        let expected = 4.0 * BOLTZMANN * t / r;
        let model = NoiseModel::Thermal {
            four_kt_over_r: 4.0 * BOLTZMANN * t / r,
        };
        let got = model.psd(1000.0); // freq doesn't matter for thermal
        let rel_err = (got - expected).abs() / expected;
        assert!(rel_err < 1e-10, "thermal formula rel_err={rel_err}");
        // Numerical value: 4 * 1.380649e-23 * 300.15 / 1000 ≈ 1.657e-23 A²/Hz
        assert!(
            expected > 1.6e-23 && expected < 1.72e-23,
            "thermal S_i = {expected} out of expected range"
        );
    }

    #[test]
    fn shot_noise_formula() {
        // I_d = 1 mA → S_i = 2 * q * I = 2 * 1.602e-19 * 1e-3 ≈ 3.204e-22
        let i = 1e-3_f64;
        let expected = 2.0 * ELEM_CHARGE * i;
        let model = NoiseModel::Shot { two_q_i: expected };
        let got = model.psd(1e6); // shot noise is white
        assert!((got - expected).abs() / expected < 1e-10);
        assert!(
            expected > 3.0e-22 && expected < 3.5e-22,
            "shot S_i = {expected}"
        );
    }

    #[test]
    fn flicker_noise_bjt_formula() {
        // BJT with I_B = 1µA, Kf = 1e-14, Af = 1
        // Base PSD = 2*q*I_B = 2 * 1.602e-19 * 1e-6 = 3.204e-25
        // At f=1 kHz: kf/I_B^Af / f = 1e-14 * 1e-6 / 1e3 = 1e-23
        let i_b = 1e-6_f64;
        let kf = 1e-14_f64;
        let af = 1.0_f64;
        let base_psd = 2.0 * ELEM_CHARGE * i_b;
        let kf_iaf = kf * i_b.powf(af);
        let model = NoiseModel::BjtCombined { base_psd, kf_iaf };
        let f = 1000.0_f64;
        let got = model.psd(f);
        let expected = base_psd + kf_iaf / f;
        let rel_err = (got - expected).abs() / expected;
        assert!(rel_err < 1e-10, "bjt flicker rel_err={rel_err}");
    }

    #[test]
    fn flicker_noise_mosfet_formula() {
        // MOSFET: thermal + 1/f
        // gm = 1e-3, T = 300 K, Kf*I_D^Af / Cox*L² = 1e-30
        let gm = 1e-3_f64;
        let t = 300.0_f64;
        let kf_term = 1e-30_f64;
        let thermal_psd = (8.0 / 3.0) * BOLTZMANN * t * gm;
        let model = NoiseModel::MosfetCombined {
            thermal_psd,
            kf_term,
        };
        let f = 1e6_f64;
        let got = model.psd(f);
        let expected = thermal_psd + kf_term / f;
        let rel_err = (got - expected).abs() / expected;
        assert!(rel_err < 1e-10, "mosfet combined rel_err={rel_err}");
    }

    // ── Frequency generation test ───────────────────────────────────────────

    #[test]
    fn noise_freq_generation_decade() {
        let cfg = NoiseConfig {
            sweep: AcSweepType::Decade,
            start: 1.0,
            stop: 1e6,
            npoints: 10,
            output_node: "out".into(),
            input_source: "V1".into(),
        };
        let freqs = generate_noise_frequencies(&cfg);
        assert!(freqs.len() > 10);
        assert!((freqs[0] - 1.0).abs() < 1e-9, "first freq = {}", freqs[0]);
    }

    #[test]
    fn node_voltage_ground_is_zero() {
        let sol = vec![1.0, 2.0, 3.0];
        assert_eq!(node_voltage(incspice_core::NodeId::GROUND, &sol), 0.0);
    }

    #[test]
    fn node_to_mna_ground_is_none() {
        assert_eq!(node_to_mna(incspice_core::NodeId::GROUND), None);
    }

    #[test]
    fn node_to_mna_nonground_is_some() {
        use incspice_core::NodeId;
        // NodeId(1) → MNA row 0
        let node = NodeId(1);
        assert_eq!(node_to_mna(node), Some(0));
        // NodeId(5) → MNA row 4
        let node5 = NodeId(5);
        assert_eq!(node_to_mna(node5), Some(4));
    }

    #[test]
    fn node_voltage_nonground() {
        let sol = vec![1.0, 2.0, 3.0];
        // NodeId(1) → sol[0] = 1.0
        assert!((node_voltage(incspice_core::NodeId(1), &sol) - 1.0).abs() < 1e-15);
        // NodeId(3) → sol[2] = 3.0
        assert!((node_voltage(incspice_core::NodeId(3), &sol) - 3.0).abs() < 1e-15);
    }

    #[test]
    fn thermal_noise_is_frequency_independent() {
        let model = NoiseModel::Thermal { four_kt_over_r: 1e-20 };
        let s_at_1k  = model.psd(1e3);
        let s_at_1m  = model.psd(1e6);
        let s_at_1g  = model.psd(1e9);
        assert!((s_at_1k - s_at_1m).abs() < 1e-30, "thermal noise should be white");
        assert!((s_at_1k - s_at_1g).abs() < 1e-30, "thermal noise should be white");
    }

    #[test]
    fn shot_noise_is_white() {
        let model = NoiseModel::Shot { two_q_i: 3.204e-22 };
        let s1 = model.psd(1e3);
        let s2 = model.psd(1e9);
        assert!((s1 - s2).abs() < 1e-30, "shot noise should be white");
    }

    #[test]
    fn bjt_noise_decreases_with_frequency() {
        // BjtCombined with nonzero kf_iaf → 1/f component dominant at low freq
        let model = NoiseModel::BjtCombined { base_psd: 1e-24, kf_iaf: 1e-20 };
        let s_low  = model.psd(10.0);
        let s_high = model.psd(1e8);
        assert!(s_low > s_high, "BJT noise with 1/f term should decrease with frequency");
    }

    #[test]
    fn mosfet_noise_decreases_with_frequency() {
        let model = NoiseModel::MosfetCombined { thermal_psd: 1e-24, kf_term: 1e-20 };
        let s_low  = model.psd(10.0);
        let s_high = model.psd(1e8);
        assert!(s_low > s_high, "MOSFET noise with 1/f term should decrease");
    }

    #[test]
    fn noise_freq_generation_linear() {
        let cfg = NoiseConfig {
            sweep: AcSweepType::Linear,
            start: 100.0,
            stop: 1000.0,
            npoints: 5,
            output_node: "out".into(),
            input_source: "V1".into(),
        };
        let freqs = generate_noise_frequencies(&cfg);
        assert_eq!(freqs.len(), 5);
        assert!((freqs[0] - 100.0).abs() < 1e-9);
        assert!((freqs[4] - 1000.0).abs() < 1e-9);
    }

    #[test]
    fn noise_freq_generation_octave() {
        let cfg = NoiseConfig {
            sweep: AcSweepType::Octave,
            start: 100.0,
            stop: 800.0,
            npoints: 3,
            output_node: "out".into(),
            input_source: "V1".into(),
        };
        let freqs = generate_noise_frequencies(&cfg);
        assert!(!freqs.is_empty());
        assert!((freqs[0] - 100.0).abs() < 1.0, "first={}", freqs[0]);
        assert!((*freqs.last().unwrap() - 800.0).abs() < 10.0, "last={}", freqs.last().unwrap());
    }

    #[test]
    fn bjt_noise_zero_kf_equals_base() {
        let base_psd = 1e-22;
        let model = NoiseModel::BjtCombined { base_psd, kf_iaf: 0.0 };
        let s = model.psd(1e3);
        assert!((s - base_psd).abs() < 1e-30, "with kf=0 BJT noise should equal base");
    }

    #[test]
    fn mosfet_flicker_noise_integration() {
        // Parse and run noise on the mosfet_flicker test circuit
        use incspice_solver::device::DeviceRegistry;
        let netlist = r#"MOSFET flicker noise test
VDD vdd 0 DC 3.3
VIN g 0 DC 1.5 AC 1
RD vdd out 5k
M1 out g 0 0 NMOD W=10u L=1u
.MODEL NMOD NMOS (VTO=0.7 KP=110u KF=1e-25 AF=1)
.NOISE V(out) VIN DEC 5 1 1MEG
.END
"#;
        let parsed = incspice_parser::SpiceParser::parse_bytes(netlist.as_bytes())
            .expect("parse failed");
        let circuit = parsed.0;
        let registry = DeviceRegistry::default();

        // Verify that KF made it into the device params
        let m1 = circuit.find_device("m1").expect("M1 not found");
        let kf_val = m1.params.get("kf");
        eprintln!("M1 kf = {:?}", kf_val);
        eprintln!("M1 af = {:?}", m1.params.get("af"));
        eprintln!("M1 w  = {:?}", m1.params.get("w"));
        eprintln!("M1 l  = {:?}", m1.params.get("l"));
        eprintln!("M1 kp = {:?}", m1.params.get("kp"));
        eprintln!("M1 vto= {:?}", m1.params.get("vto"));
        assert!(kf_val.is_some(), "KF should be present in MOSFET params");
        assert!((kf_val.unwrap() - 1e-25).abs() < 1e-30, "KF should be 1e-25, got {:?}", kf_val);

        let cfg = NoiseConfig {
            sweep: AcSweepType::Decade,
            start: 1.0,
            stop: 1e6,
            npoints: 5,
            output_node: "out".into(),
            input_source: "VIN".into(),
        };
        let result = run_noise(&circuit, &registry, &cfg).expect("noise analysis failed");

        // At f=1Hz, flicker noise should dominate
        let psd_1hz = result.output_spectrum_v2_per_hz[0];
        let psd_1mhz = result.output_spectrum_v2_per_hz.last().copied().unwrap();
        eprintln!("Output PSD at 1Hz   = {:.4e} V²/Hz", psd_1hz);
        eprintln!("Output PSD at 1MHz  = {:.4e} V²/Hz", psd_1mhz);
        eprintln!("Ratio (1Hz/1MHz)    = {:.2}", psd_1hz / psd_1mhz);

        // Flicker noise should make low-freq noise much larger
        assert!(psd_1hz > psd_1mhz * 10.0,
            "Flicker noise should make 1Hz PSD >> 1MHz PSD. Got 1Hz={:.4e}, 1MHz={:.4e}",
            psd_1hz, psd_1mhz);
    }

    #[test]
    fn jfet_channel_thermal_noise_formula() {
        // JFET channel thermal: S_id = 4kT * (2/3) * gm * m = (8/3)*kT*gm*m
        // With gm = 2e-3, T = 300.15 K, m = 1:
        let gm = 2e-3_f64;
        let t = 300.15_f64;
        let m = 1.0_f64;
        let thermal_psd = 4.0 * BOLTZMANN * t * (2.0 / 3.0) * gm * m;
        // This equals (8/3)*kT*gm*m
        let expected = (8.0 / 3.0) * BOLTZMANN * t * gm * m;
        assert!((thermal_psd - expected).abs() < 1e-30,
            "JFET thermal formula: {thermal_psd} vs {expected}");
        // The MosfetCombined model should return thermal_psd at any frequency
        let model = NoiseModel::MosfetCombined { thermal_psd, kf_term: 0.0 };
        let got = model.psd(1e3);
        assert!((got - thermal_psd).abs() < 1e-30);
    }

    #[test]
    fn jfet_flicker_noise_formula() {
        // JFET flicker: Kf * |Id/m|^Af * m / f
        // With Kf=1e-18, Id=2e-3, Af=1, m=1, f=1kHz:
        let kf = 1e-18_f64;
        let id = 2e-3_f64;
        let af = 1.0_f64;
        let m = 1.0_f64;
        let f = 1e3_f64;
        let kf_term = kf * (id / m).abs().powf(af) * m;
        let expected_psd = kf_term / f;
        let model = NoiseModel::MosfetCombined { thermal_psd: 0.0, kf_term };
        let got = model.psd(f);
        assert!((got - expected_psd).abs() / expected_psd < 1e-10,
            "JFET flicker: got={got:.4e} expected={expected_psd:.4e}");
    }

    #[test]
    fn jfet_noise_integration() {
        // Parse and run noise on a JFET common-source amplifier
        use incspice_solver::device::DeviceRegistry;
        let netlist = r#"JFET noise test
VDD vdd 0 DC 12
VIN g 0 DC 0 AC 1
RD vdd out 2k
J1 out g 0 JMOD
.MODEL JMOD NJF (VTO=-2 BETA=1e-3 KF=1e-18 AF=1)
.NOISE V(out) VIN DEC 5 1 1MEG
.END
"#;
        let parsed = incspice_parser::SpiceParser::parse_bytes(netlist.as_bytes())
            .expect("parse failed");
        let circuit = parsed.0;
        let registry = DeviceRegistry::default();

        let cfg = NoiseConfig {
            sweep: AcSweepType::Decade,
            start: 1.0,
            stop: 1e6,
            npoints: 5,
            output_node: "out".into(),
            input_source: "VIN".into(),
        };
        let result = run_noise(&circuit, &registry, &cfg).expect("noise analysis failed");

        // Verify we got noise output
        assert!(!result.freqs.is_empty(), "should have frequency points");
        assert!(!result.output_spectrum_v2_per_hz.is_empty(), "should have output PSD");

        // With KF > 0, low-frequency noise should exceed high-frequency noise
        let psd_low = result.output_spectrum_v2_per_hz[0];
        let psd_high = *result.output_spectrum_v2_per_hz.last().unwrap();
        eprintln!("JFET Output PSD at ~1Hz  = {:.4e} V²/Hz", psd_low);
        eprintln!("JFET Output PSD at ~1MHz = {:.4e} V²/Hz", psd_high);

        // All PSDs should be positive
        for (i, &psd) in result.output_spectrum_v2_per_hz.iter().enumerate() {
            assert!(psd >= 0.0, "PSD at index {i} should be >= 0, got {psd}");
        }

        // Flicker noise should make low-freq noise larger than high-freq
        assert!(psd_low > psd_high,
            "JFET 1/f noise should make low-freq PSD > high-freq PSD. \
             Got low={:.4e}, high={:.4e}", psd_low, psd_high);

        // Verify JFET-specific contributions exist in the breakdown
        let jfet_contribs: Vec<_> = result.contributions.iter()
            .filter(|c| c.device_name.starts_with("j1"))
            .collect();
        assert!(!jfet_contribs.is_empty(),
            "Should have JFET noise contributions. All: {:?}",
            result.contributions.iter().map(|c| &c.device_name).collect::<Vec<_>>());
    }
}
