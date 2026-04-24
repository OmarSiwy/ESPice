//! External accuracy tests: BigOSpice vs reference simulators across ALL fixture categories.
//!
//! For every `.sp` file in `tools/fixtures/<category>/`, BigOSpice is run via the
//! library API and compared against ngspice, Xyce, and/or VACASK. A fixture PASSES
//! if BigOSpice matches ANY available reference simulator within tolerance.
//!
//! Comparison methodology:
//! - **DC OP / DC Sweep**: pointwise relative error on node voltages (0.1% tolerance)
//! - **Transient**: waveform NRMSE with interpolation (5% tolerance) — handles phase
//!   differences in oscillating circuits correctly
//! - **AC**: complex magnitude/phase comparison against ngspice rawfiles
//!
//! Run (requires `.#full` nix shell for ngspice/Xyce/VACASK on PATH):
//!     nix develop .#full --command cargo test --test test_external -- --nocapture
//!
//! The `-- --nocapture` flag disables stdout capture for realtime progress output.
//! Skips gracefully when no external simulators (ngspice/Xyce/vacask) are on PATH.
//! New fixture subdirectories are discovered automatically — no file edits needed.

#[path = "utils.rs"]
mod utils;

#[path = "sim.rs"]
mod sim;

use sim::{NgspiceRunner, RawFile, RawPlotType, Tolerance, VacaskRunner, XyceRunner};

use incspice_analysis::{
    run_ac, run_dc_op, run_dc_op_with_config, run_dc_sweep, run_nested_dc, run_noise,
    run_transient, AcConfig, AcSweepType, DcSweepConfig, NestedDcConfig, NoiseConfig,
    TransientConfig,
};
use incspice_core::Circuit;
use incspice_parser::{AnalysisKind, SpiceParser};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::NrConfig;

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};

// ── Configuration ────────────────────────────────────────────────────────────

/// Relative error threshold for DC comparison (0.1%).
const DC_REL_TOL: f64 = 1e-3;
/// Absolute error threshold for near-zero DC values.
const DC_ABS_TOL: f64 = 1e-9;
/// NRMSE threshold for transient waveform comparison (5%).
const TRAN_NRMSE_TOL: f64 = 0.05;
/// Maximum AC gain error in dB.
const AC_GAIN_DB_TOL: f64 = 0.01;
/// Maximum AC phase error in degrees.
const AC_PHASE_DEG_TOL: f64 = 0.1;
/// Maximum noise PSD error in dB (comparing V²/Hz spectra).
const NOISE_DB_TOL: f64 = 1.0;

// ── Types ────────────────────────────────────────────────────────────────────

#[derive(Debug)]
enum Outcome {
    Pass {
        simulator: String,
        max_err: f64,
        nodes_compared: usize,
        method: &'static str,
    },
    Fail {
        details: String,
    },
    /// Expected failure: both IncSpice and the reference simulator reject the fixture.
    XFail {
        details: String,
    },
    Skip {
        reason: String,
    },
}

struct CompareResult {
    all_pass: bool,
    max_err: f64,
    nodes_compared: usize,
}

/// Full BigOSpice output: DC voltages + transient waveforms from all methods tried.
struct BigospiceOutput {
    /// Final-point node voltages for DC comparison (`v(node)` → value).
    voltages: HashMap<String, f64>,
    /// Transient waveforms from each successful method (method_name, waveform).
    waveforms: Vec<(&'static str, Waveform)>,
    /// DC sweep waveforms (sweep variable as x-axis, node voltages as y-axis).
    /// Stored as `Waveform` where `times` = sweep values and `signals` = node voltages.
    dc_sweep_waveforms: Vec<Waveform>,
    /// AC small-signal response, if an `.AC` analysis was run.
    ac_waveform: Option<AcWaveform>,
    /// Noise spectral density, if a `.NOISE` analysis was run.
    noise_waveform: Option<NoiseWaveform>,
}

/// Time-series waveform data.
struct Waveform {
    times: Vec<f64>,
    /// `v(node_name)` → values at each time point.
    signals: HashMap<String, Vec<f64>>,
}

/// Frequency-domain complex waveform data.
struct AcWaveform {
    frequencies: Vec<f64>,
    /// `v(node_name)` → complex values at each frequency point.
    signals: HashMap<String, ComplexSignal>,
}

/// Complex-valued signal stored as separate real/imag columns.
struct ComplexSignal {
    real: Vec<f64>,
    imag: Vec<f64>,
}

/// Noise spectral density waveform data.
struct NoiseWaveform {
    frequencies: Vec<f64>,
    /// Total output-referred noise PSD [V²/Hz] at each frequency point.
    onoise_spectrum: Vec<f64>,
    /// Total input-referred noise PSD [V²/Hz] at each frequency point.
    inoise_spectrum: Vec<f64>,
}

struct NoiseCompareResult {
    all_pass: bool,
    max_err_db: f64,
    signals_compared: usize,
}

/// Diagnostic record for a reference simulator that was tried but did not
/// produce a passing comparison.  Collected so that when *all* simulators fail
/// we can emit a structured summary showing exactly what was attempted.
struct ReferenceResult {
    simulator: String,
    /// Process exit code (`None` when the failure happened before/after exec).
    exit_code: Option<i32>,
    /// First few lines of stderr (or comparison-mismatch details).
    stderr: String,
}

impl ReferenceResult {
    /// Build from a simulator error string of the form produced by sim.rs:
    ///   `"ngspice exit Some(1): <stderr text>"`
    fn from_run_error(simulator: &str, err: &str) -> Self {
        // Try to parse exit code from "exit Some(<N>):" or "exit None:"
        let (exit_code, stderr) = if let Some(rest) = err.strip_prefix(&format!("{simulator} exit ")) {
            if let Some(rest2) = rest.strip_prefix("Some(") {
                if let Some(paren_end) = rest2.find(')') {
                    let code = rest2[..paren_end].parse::<i32>().ok();
                    let msg = rest2[paren_end..].strip_prefix("): ").unwrap_or(&rest2[paren_end..]);
                    (code, msg.to_string())
                } else {
                    (None, rest.to_string())
                }
            } else if let Some(rest2) = rest.strip_prefix("None: ") {
                (None, rest2.to_string())
            } else {
                (None, rest.to_string())
            }
        } else {
            (None, err.to_string())
        };
        Self {
            simulator: simulator.to_string(),
            exit_code,
            stderr: Self::truncate_stderr(&stderr),
        }
    }

    /// Build from a comparison mismatch (simulator ran OK but results diverged).
    fn from_comparison(simulator: &str, detail: String) -> Self {
        Self {
            simulator: simulator.to_string(),
            exit_code: Some(0),
            stderr: detail,
        }
    }

    /// Keep at most 4 lines and 500 chars of stderr to stay readable.
    fn truncate_stderr(s: &str) -> String {
        let mut out: String = s.lines().take(4).collect::<Vec<_>>().join("\n");
        if out.len() > 500 {
            out.truncate(500);
            out.push_str("...");
        }
        out
    }

    /// Human-readable one-line summary (for the existing `tried` list).
    fn one_line(&self) -> String {
        let code_str = match self.exit_code {
            Some(c) => format!("exit {c}"),
            None => "exit ?".to_string(),
        };
        let snippet = self.stderr.lines().next().unwrap_or("").trim();
        let mut s = format!("{} ({}): {}", self.simulator, code_str, snippet);
        if s.len() > 240 {
            s.truncate(240);
            s.push_str("...");
        }
        s
    }
}

/// Format a detailed summary of all reference simulators that were tried.
/// Printed when every simulator fails, to aid debugging.
fn format_reference_failure_summary(results: &[ReferenceResult]) -> String {
    let mut buf = String::new();
    buf.push_str("Reference simulator summary (all failed):\n");
    for (i, r) in results.iter().enumerate() {
        let code_str = match r.exit_code {
            Some(c) => c.to_string(),
            None => "N/A".to_string(),
        };
        buf.push_str(&format!(
            "  [{}/{}] {} | exit_code={} | {}\n",
            i + 1,
            results.len(),
            r.simulator,
            code_str,
            r.stderr.replace('\n', "\n        "),
        ));
    }
    buf
}

struct AcCompareResult {
    all_pass: bool,
    max_gain_err_db: f64,
    max_phase_err_deg: f64,
    nodes_compared: usize,
}

/// Cached availability flags for external simulators.
struct SimAvailability {
    ngspice: Option<NgspiceRunner>,
    xyce: Option<XyceRunner>,
    vacask: Option<VacaskRunner>,
}

impl SimAvailability {
    fn detect() -> Self {
        let ng = NgspiceRunner::default();
        let xy = XyceRunner::default();
        let va = VacaskRunner::default();
        Self {
            ngspice: ng.is_available().then_some(ng),
            xyce: xy.is_available().then_some(xy),
            vacask: va.is_available().then_some(va),
        }
    }

    fn any_available(&self) -> bool {
        self.ngspice.is_some() || self.xyce.is_some() || self.vacask.is_some()
    }

    fn summary(&self) -> String {
        let mut parts = Vec::new();
        if self.ngspice.is_some() {
            parts.push("ngspice");
        }
        if self.xyce.is_some() {
            parts.push("xyce");
        }
        if self.vacask.is_some() {
            parts.push("vacask");
        }
        if parts.is_empty() {
            "none".into()
        } else {
            parts.join(", ")
        }
    }
}

// ── Filesystem helpers ───────────────────────────────────────────────────────

use utils::{filtered_categories, fixtures_dir, sp_files_in};

fn glob_sp_files(dir: &Path) -> Vec<PathBuf> {
    sp_files_in(dir)
}

fn fixture_skip_reason(sp_path: &Path) -> Option<String> {
    let content = std::fs::read_to_string(sp_path).ok()?;
    let lower = content.to_ascii_lowercase();

    if lower.contains("agauss(") || lower.contains("gauss(") {
        return Some(
            "stochastic parameter functions are not pointwise-comparable to external simulators"
                .into(),
        );
    }

    // PTC (pseudo-transient continuation) is now wired through the parser/solver
    // stack via .OPTIONS PTRANMAX=<time> / PSEUDOTRANSIENT=1.

    None
}

/// Generate sweep values from start/stop/step (inclusive of stop within half-step tolerance).
fn sweep_values(start: f64, stop: f64, step: f64) -> Result<Vec<f64>, String> {
    if step == 0.0 {
        return Err("DC sweep step must be non-zero".into());
    }

    let wrong_direction = (step > 0.0 && start > stop) || (step < 0.0 && start < stop);
    if wrong_direction {
        return Err(format!(
            "DC sweep step {step} does not move from start={start} toward stop={stop}"
        ));
    }

    let mut vals = Vec::new();
    let eps = step.abs() * 1e-9;
    let ascending = step > 0.0;
    let mut v = start;
    while if ascending {
        v <= stop + eps
    } else {
        v >= stop - eps
    } {
        vals.push(v);
        v += step;
    }
    Ok(vals)
}

// ── BigOSpice runner ─────────────────────────────────────────────────────────

fn circuit_node_names(circuit: &Circuit) -> Vec<String> {
    let mut nodes: Vec<_> = circuit
        .nodes()
        .iter()
        .filter_map(|n| n.matrix_index.map(|idx| (idx, n.name.clone())))
        .collect();
    nodes.sort_by_key(|(idx, _)| *idx);
    nodes.into_iter().map(|(_, name)| name).collect()
}

/// Run BigOSpice on a netlist file. Returns DC voltages and optional transient waveform.
fn run_incspice(sp_path: &Path) -> Result<BigospiceOutput, String> {
    let (circuit, analyses, opts) =
        SpiceParser::parse_file(sp_path).map_err(|e| format!("parse: {e}"))?;

    let registry = DeviceRegistry::new_default();
    let node_names = circuit_node_names(&circuit);
    let mut voltages: HashMap<String, f64> = HashMap::new();
    let mut waveforms: Vec<(&str, Waveform)> = Vec::new();
    let mut dc_sweep_waveforms: Vec<Waveform> = Vec::new();
    let mut ac_waveform: Option<AcWaveform> = None;
    let mut noise_waveform: Option<NoiseWaveform> = None;
    let mut has_dc_op = false;
    let mut has_supported_analysis = false;
    let mut unsupported_kinds: Vec<String> = Vec::new();

    // Detect analysis directives the parser recognized but didn't emit into analyses[].
    // (.SENS, .TF, .PZ, .WCASE are tokenized but not yet emitted as AnalysisStatements.)
    if analyses.is_empty() {
        if let Ok(content) = std::fs::read_to_string(sp_path) {
            let lower = content.to_ascii_lowercase();
            for (dot, label) in [
                (".sens ", "SENS"),
                (".tf ", "TF"),
                (".pz ", "PZ"),
                (".wcase ", "WCASE"),
                (".four ", "FOUR"),
                (".fft ", "FFT"),
            ] {
                if lower.contains(dot) {
                    unsupported_kinds.push(label.to_string());
                }
            }
        }
    }

    // Build NR config from parsed options (enables PTC when ptranmax > 0).
    let nr_config = {
        let mut cfg = NrConfig::default();
        if opts.ptranmax > 0.0 {
            cfg.enable_pseudo_transient = true;
        }
        cfg
    };

    for stmt in &analyses {
        let p = |key: &str| stmt.params.iter().find(|(k, _)| k == key).map(|(_, v)| *v);

        match &stmt.kind {
            AnalysisKind::DcOp => {
                has_supported_analysis = true;
                let out = run_dc_op_with_config(&circuit, &registry, &nr_config)
                    .map_err(|e| format!("DC OP: {e}"))?;
                for (name, val) in &out.result.node_voltages {
                    voltages.insert(format!("v({})", name.to_lowercase()), *val);
                }
                for (name, val) in &out.result.branch_currents {
                    voltages.insert(format!("i({})", name.to_lowercase()), *val);
                }
                has_dc_op = true;
            }

            AnalysisKind::DcSweep => {
                has_supported_analysis = true;
                let src_name = stmt
                    .params
                    .iter()
                    .find(|(k, _)| k.starts_with("__dc_src__"))
                    .map(|(k, _)| k["__dc_src__".len()..].to_string())
                    .unwrap_or_else(|| "v1".to_string());
                let start = p("start").unwrap_or(0.0);
                let stop = p("stop").unwrap_or(1.0);
                let step = p("step").unwrap_or(0.1);

                // Check for nested inner sweep
                let src2_entry = stmt
                    .params
                    .iter()
                    .find(|(k, _)| k.starts_with("__dc_src2__"));
                if let Some((k, _)) = src2_entry {
                    let k_low = k.to_lowercase();
                    let is_temp = k_low == "__dc_src2__temp";
                    let src2_name = if is_temp {
                        "temp".to_string()
                    } else {
                        k_low["__dc_src2__".len()..].to_string()
                    };
                    let start2 = p("start2").unwrap_or(0.0);
                    let stop2 = p("stop2").unwrap_or(1.0);
                    let step2 = p("step2").unwrap_or(0.1);

                    // Build sweep value vectors
                    let inner_values = sweep_values(start, stop, step)
                        .map_err(|e| format!("DC nested sweep: {e}"))?;
                    let outer_values = sweep_values(start2, stop2, step2)
                        .map_err(|e| format!("DC nested sweep: {e}"))?;

                    // SPICE convention: src1 is inner (fast), src2 is outer (slow)
                    let outer_param = if is_temp { "temp" } else { "dc" };
                    let nested_cfg = NestedDcConfig::new(
                        &src2_name,
                        outer_param,
                        outer_values,
                        &src_name,
                        "dc",
                        inner_values,
                    );
                    let out = run_nested_dc(&circuit, &registry, &nested_cfg)
                        .map_err(|e| format!("DC nested sweep: {e}"))?;
                    // Only record sweep endpoint voltages when no .OP was run,
                    // because ngspice's rawfile parser reads the first plot
                    // (the OP) when both .OP and .DC are present.
                    if !has_dc_op {
                        if let Some(last_point) = out.points.last() {
                            for (name, val) in &last_point.node_voltages {
                                voltages.insert(format!("v({})", name.to_lowercase()), *val);
                            }
                        }
                    }
                } else {
                    let cfg = DcSweepConfig::new(&src_name, start, stop, step);
                    let out = run_dc_sweep(&circuit, &registry, &cfg)
                        .map_err(|e| format!("DC sweep: {e}"))?;
                    if !has_dc_op {
                        if let Some(last_vals) = out.node_voltages.last() {
                            for (name, val) in node_names.iter().zip(last_vals.iter()) {
                                voltages.insert(format!("v({})", name.to_lowercase()), *val);
                            }
                        }
                    }
                    // Store full sweep curve as a waveform for curve comparison.
                    // The sweep variable acts as the x-axis (like "time" in transient).
                    if out.sweep_values.len() > 1 {
                        let mut signals: HashMap<String, Vec<f64>> = HashMap::new();
                        for (ni, name) in node_names.iter().enumerate() {
                            let key = format!("v({})", name.to_lowercase());
                            let vals: Vec<f64> = out
                                .node_voltages
                                .iter()
                                .filter_map(|point| point.get(ni).copied())
                                .collect();
                            if vals.len() == out.sweep_values.len() {
                                signals.insert(key, vals);
                            }
                        }
                        if !signals.is_empty() {
                            dc_sweep_waveforms.push(Waveform {
                                times: out.sweep_values.clone(),
                                signals,
                            });
                        }
                    }
                }
            }

            AnalysisKind::Tran => {
                has_supported_analysis = true;
                let tstep = p("tstep").unwrap_or(1e-9);
                let tstop = p("tstop").unwrap_or(1e-6);
                let uic = p("uic").unwrap_or(0.0) != 0.0;

                // Try two methods: Trap-adaptive (best accuracy for oscillatory circuits),
                // then BE-adaptive (more robust for stiff circuits).
                use incspice_analysis::IntegrationMethod as IM;
                // Cap tmax at tstep*10 to prevent the adaptive stepper from
                // taking steps larger than ~1 oscillation cycle.
                let tmax = tstep * 10.0;
                let fixed_fine_tstep = tstep * 0.5;

                // Per-method wall-clock budget: 5 s per config × 6 configs = 30 s max.
                // This prevents high-step-count circuits (e.g. colpitts with 100k steps)
                // from hanging the test suite.  Each method returns a partial result when
                // the budget is exceeded rather than running indefinitely.
                let per_method_timeout = Some(15.0_f64);

                let configs: [(&str, TransientConfig); 6] = [
                    (
                        "Trap-adapt",
                        TransientConfig {
                            uic,
                            tmax: Some(tmax),
                            timeout_secs: per_method_timeout,
                            ..TransientConfig::with_adaptive(tstep, tstop, IM::Trapezoidal)
                        },
                    ),
                    (
                        "BE-adaptive",
                        TransientConfig {
                            uic,
                            tmax: Some(tmax),
                            timeout_secs: per_method_timeout,
                            ..TransientConfig::with_adaptive(tstep, tstop, IM::BackwardEuler)
                        },
                    ),
                    (
                        "Trap-fixed",
                        TransientConfig {
                            uic,
                            timeout_secs: per_method_timeout,
                            ..TransientConfig::with_method(tstep, tstop, IM::Trapezoidal)
                        },
                    ),
                    (
                        "BE-fixed",
                        TransientConfig {
                            uic,
                            timeout_secs: per_method_timeout,
                            ..TransientConfig::with_method(tstep, tstop, IM::BackwardEuler)
                        },
                    ),
                    (
                        "Trap-fixed-fine",
                        TransientConfig {
                            uic,
                            timeout_secs: per_method_timeout,
                            ..TransientConfig::with_method(fixed_fine_tstep, tstop, IM::Trapezoidal)
                        },
                    ),
                    (
                        "BE-fixed-fine",
                        TransientConfig {
                            uic,
                            timeout_secs: per_method_timeout,
                            ..TransientConfig::with_method(
                                fixed_fine_tstep,
                                tstop,
                                IM::BackwardEuler,
                            )
                        },
                    ),
                ];
                let mut any_succeeded = false;
                for (method_name, cfg) in &configs {
                    let mut c = circuit.clone();
                    if let Ok(out) = run_transient(&mut c, &registry, cfg) {
                        if !out.times.is_empty() {
                            // Use the first successful method's voltages for DC fallback
                            if !any_succeeded {
                                let last = out.times.len() - 1;
                                for (ni, name) in node_names.iter().enumerate() {
                                    if last * out.num_nodes + ni < out.node_voltages_flat.len() {
                                        let val = out.node_voltages_flat[last * out.num_nodes + ni];
                                        voltages.insert(format!("v({})", name.to_lowercase()), val);
                                    }
                                }
                            }
                            any_succeeded = true;

                            // Capture full waveform
                            let mut signals: HashMap<String, Vec<f64>> = HashMap::new();
                            for (ni, name) in node_names.iter().enumerate() {
                                let key = format!("v({})", name.to_lowercase());
                                let vals: Vec<f64> = (0..out.times.len())
                                    .filter_map(|step| {
                                        let idx = step * out.num_nodes + ni;
                                        out.node_voltages_flat.get(idx).copied()
                                    })
                                    .collect();
                                if vals.len() == out.times.len() {
                                    signals.insert(key, vals);
                                }
                            }
                            waveforms.push((
                                *method_name,
                                Waveform {
                                    times: out.times.clone(),
                                    signals,
                                },
                            ));
                        }
                    }
                }
                if !any_succeeded {
                    return Err("transient: all method/adaptive combos failed".into());
                }
            }

            AnalysisKind::Ac => {
                has_supported_analysis = true;
                // AC always linearises around the DC operating point (ngspice behaviour).
                // If no explicit .OP statement preceded this .AC, run DC OP now so that
                // `voltages` is populated and the linearisation point is well-defined.
                if voltages.is_empty() {
                    let op_out = run_dc_op(&circuit, &registry)
                        .map_err(|e| format!("DC OP (implicit for AC): {e}"))?;
                    for (name, val) in &op_out.result.node_voltages {
                        voltages.insert(format!("v({})", name.to_lowercase()), *val);
                    }
                    for (name, val) in &op_out.result.branch_currents {
                        voltages.insert(format!("i({})", name.to_lowercase()), *val);
                    }
                }
                let sweep = match p("sweep_type").unwrap_or(1.0) as u8 {
                    0 => AcSweepType::Linear,
                    2 => AcSweepType::Octave,
                    _ => AcSweepType::Decade,
                };
                let npoints = p("npoints").unwrap_or(10.0) as usize;
                let fstart = p("fstart").unwrap_or(1.0);
                let fstop = p("fstop").unwrap_or(1e6);
                let cfg = AcConfig::new(fstart, fstop, npoints, sweep);
                let out = run_ac(&circuit, &registry, &cfg).map_err(|e| format!("AC: {e}"))?;
                if !out.frequencies.is_empty() {
                    let mut signals: HashMap<String, ComplexSignal> = HashMap::new();
                    for (ni, name) in node_names.iter().enumerate() {
                        let key = format!("v({})", name.to_lowercase());
                        let real: Vec<f64> = out
                            .node_reals
                            .iter()
                            .map(|freq_vals| freq_vals.get(ni).copied().unwrap_or(0.0))
                            .collect();
                        let imag: Vec<f64> = out
                            .node_imags
                            .iter()
                            .map(|freq_vals| freq_vals.get(ni).copied().unwrap_or(0.0))
                            .collect();
                        if real.len() == out.frequencies.len()
                            && imag.len() == out.frequencies.len()
                        {
                            signals.insert(key, ComplexSignal { real, imag });
                        }
                    }
                    ac_waveform = Some(AcWaveform {
                        frequencies: out.frequencies.clone(),
                        signals,
                    });
                }
            }

            AnalysisKind::Noise => {
                has_supported_analysis = true;
                let output_node = stmt
                    .params
                    .iter()
                    .find(|(k, _)| k.starts_with("__noise_out__"))
                    .map(|(k, _)| k["__noise_out__".len()..].to_string())
                    .unwrap_or_else(|| "out".to_string());
                let input_source = stmt
                    .params
                    .iter()
                    .find(|(k, _)| k.starts_with("__noise_src__"))
                    .map(|(k, _)| k["__noise_src__".len()..].to_string())
                    .unwrap_or_else(|| "v1".to_string());
                let sweep = match p("sweep_type").unwrap_or(1.0) as u8 {
                    0 => AcSweepType::Linear,
                    2 => AcSweepType::Octave,
                    _ => AcSweepType::Decade,
                };
                let npoints = p("npoints").unwrap_or(10.0) as usize;
                let fstart = p("fstart").unwrap_or(1.0);
                let fstop = p("fstop").unwrap_or(1e6);
                let cfg = NoiseConfig {
                    sweep,
                    start: fstart,
                    stop: fstop,
                    npoints,
                    output_node,
                    input_source,
                };
                let out =
                    run_noise(&circuit, &registry, &cfg).map_err(|e| format!("NOISE: {e}"))?;
                if !out.freqs.is_empty() {
                    noise_waveform = Some(NoiseWaveform {
                        frequencies: out.freqs,
                        onoise_spectrum: out.output_spectrum_v2_per_hz,
                        inoise_spectrum: out.input_spectrum_v2_per_hz,
                    });
                }
            }

            AnalysisKind::Sp => {
                has_supported_analysis = true;
                // SP analysis: extract port info from circuit, run S-parameter sweep.
                use incspice_analysis::{run_sp, SpConfig, SpPort};
                let sweep_str = stmt
                    .params
                    .iter()
                    .find(|(k, _)| k.starts_with("__sp_sweep__"))
                    .map(|(k, _)| k["__sp_sweep__".len()..].to_string())
                    .unwrap_or_else(|| "dec".to_string());
                let npoints = p("npoints").unwrap_or(10.0) as usize;
                let fstart = p("fstart").unwrap_or(1.0);
                let fstop = p("fstop").unwrap_or(1e9);
                let sweep_type = match sweep_str.as_str() {
                    "lin" => AcSweepType::Linear,
                    "oct" => AcSweepType::Octave,
                    _ => AcSweepType::Decade,
                };

                // Extract ports from voltage sources with portnum param
                let mut port_info: Vec<(usize, SpPort, f64)> = Vec::new();
                for dev in circuit.devices() {
                    if dev.kind != incspice_core::DeviceKind::VoltageSource {
                        continue;
                    }
                    let portnum = match dev.params.get("portnum") {
                        Some(v) => v as usize,
                        None => continue,
                    };
                    let z0 = dev.params.get("z0").unwrap_or(50.0);
                    let pos_node = dev.terminals.get(0).map(|t| t.node);
                    let neg_node = dev.terminals.get(1).map(|t| t.node);
                    let pos_idx = pos_node
                        .filter(|n| !n.is_ground())
                        .map(|n| (n.0 - 1) as usize);
                    let neg_idx = neg_node
                        .filter(|n| !n.is_ground())
                        .map(|n| (n.0 - 1) as usize);
                    let port = match (pos_idx, neg_idx) {
                        (Some(p), Some(n)) => SpPort::differential(p, n),
                        (Some(p), None) => SpPort::new(p),
                        (None, Some(n)) => SpPort::new(n),
                        (None, None) => continue,
                    };
                    port_info.push((portnum, port, z0));
                }
                port_info.sort_by_key(|(pn, _, _)| *pn);
                let ports: Vec<SpPort> = port_info.iter().map(|(_, p, _)| *p).collect();
                let impedances: Vec<f64> = port_info.iter().map(|(_, _, z)| *z).collect();

                if ports.is_empty() {
                    eprintln!("    [debug] SP: no ports found in {}", sp_path.display());
                    continue;
                }

                let sp_config = SpConfig {
                    ports,
                    port_impedances: impedances,
                    freq_start: fstart,
                    freq_stop: fstop,
                    num_points: npoints,
                    sweep_type,
                };

                match run_sp(&circuit, &registry, &sp_config) {
                    Ok(result) => {
                        let n_ports = result.num_ports;
                        // Store S-parameters as complex signals
                        let mut signals: HashMap<String, ComplexSignal> = HashMap::new();
                        for i in 0..n_ports {
                            for j in 0..n_ports {
                                let key = format!("s_{}_{}", i + 1, j + 1);
                                let mut real = Vec::with_capacity(result.frequencies.len());
                                let mut imag = Vec::with_capacity(result.frequencies.len());
                                for f_idx in 0..result.frequencies.len() {
                                    let s = result.s(f_idx, i, j);
                                    real.push(s.re);
                                    imag.push(s.im);
                                }
                                signals.insert(key, ComplexSignal { real, imag });
                            }
                        }
                        // Store as an AC-like waveform for comparison
                        ac_waveform = Some(AcWaveform {
                            frequencies: result.frequencies,
                            signals,
                        });
                    }
                    Err(e) => {
                        return Err(format!("SP analysis failed: {e}"));
                    }
                }
            }

            AnalysisKind::Hb | AnalysisKind::Pss => {
                unsupported_kinds.push(format!("{:?}", stmt.kind));
                continue;
            }

            other => {
                unsupported_kinds.push(format!("{:?}", other));
                continue;
            }
        }
    }

    if voltages.is_empty()
        && waveforms.is_empty()
        && dc_sweep_waveforms.is_empty()
        && noise_waveform.is_none()
    {
        if !has_supported_analysis && !unsupported_kinds.is_empty() {
            return Err(format!(
                "UNSUPPORTED: only unsupported analysis types: {}",
                unsupported_kinds.join(", ")
            ));
        }
        return Err("no supported analysis produced results".into());
    }
    Ok(BigospiceOutput {
        voltages,
        waveforms,
        dc_sweep_waveforms,
        ac_waveform,
        noise_waveform,
    })
}

// ── Waveform math ────────────────────────────────────────────────────────────

/// Linear interpolation: given (times, values), estimate value at time `t`.
fn interpolate(times: &[f64], values: &[f64], t: f64) -> f64 {
    if times.is_empty() {
        return 0.0;
    }
    if t <= times[0] {
        return values[0];
    }
    if t >= *times.last().unwrap() {
        return *values.last().unwrap();
    }
    let idx = times.partition_point(|&x| x < t);
    if idx == 0 {
        return values[0];
    }
    let t0 = times[idx - 1];
    let t1 = times[idx];
    let v0 = values[idx - 1];
    let v1 = values[idx];
    let dt = t1 - t0;
    if dt.abs() < 1e-30 {
        return v0;
    }
    v0 + (v1 - v0) * (t - t0) / dt
}

/// Normalized Root Mean Square Error: RMSE / (max - min).
/// Returns absolute RMSE if the signal range is near-zero.
fn nrmse(predicted: &[f64], actual: &[f64]) -> f64 {
    let n = predicted.len().min(actual.len());
    if n == 0 {
        return 0.0;
    }
    let sum_sq: f64 = predicted
        .iter()
        .zip(actual.iter())
        .map(|(p, a)| (p - a).powi(2))
        .sum();
    let rmse = (sum_sq / n as f64).sqrt();
    let max_val = actual.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let min_val = actual.iter().copied().fold(f64::INFINITY, f64::min);
    let range = max_val - min_val;
    if range.abs() < 1e-12 {
        rmse // signal is constant — use absolute RMSE
    } else {
        rmse / range
    }
}

fn magnitude_db(real: f64, imag: f64) -> f64 {
    20.0 * real.hypot(imag).max(1e-30).log10()
}

fn phase_deg(real: f64, imag: f64) -> f64 {
    imag.atan2(real).to_degrees()
}

fn phase_error_deg(actual: f64, expected: f64) -> f64 {
    let wrapped = (actual - expected + 180.0).rem_euclid(360.0) - 180.0;
    wrapped.abs()
}

// ── Reference data extraction ────────────────────────────────────────────────

/// Extract last-point node voltages from ngspice RawFile (for DC comparison).
fn ngspice_voltages(raw: &RawFile) -> HashMap<String, f64> {
    if raw.data.is_empty() {
        return HashMap::new();
    }
    let last_idx = raw.data.len() - 1;
    raw.variables
        .iter()
        .enumerate()
        .map(|(vi, var)| (var.name.to_lowercase(), raw.real(last_idx, vi)))
        .collect()
}

/// Extract full waveform from ngspice RawFile (for transient comparison).
fn ngspice_waveform(raw: &RawFile) -> Option<Waveform> {
    if raw.data.len() < 2 || raw.variables.is_empty() {
        return None;
    }
    let times: Vec<f64> = (0..raw.data.len()).map(|pi| raw.real(pi, 0)).collect();
    let mut signals: HashMap<String, Vec<f64>> = HashMap::new();
    for (vi, var) in raw.variables.iter().enumerate().skip(1) {
        let name = var.name.to_lowercase();
        if name.starts_with("v(") {
            let vals: Vec<f64> = (0..raw.data.len()).map(|pi| raw.real(pi, vi)).collect();
            signals.insert(name, vals);
        }
    }
    if signals.is_empty() {
        return None;
    }
    Some(Waveform { times, signals })
}

fn ngspice_ac_waveform(raw: &RawFile) -> Option<AcWaveform> {
    if raw.data.is_empty() || raw.variables.is_empty() || raw.flags != sim::RawFlag::Complex {
        return None;
    }

    let frequencies: Vec<f64> = (0..raw.data.len()).map(|pi| raw.real(pi, 0)).collect();
    let mut signals: HashMap<String, ComplexSignal> = HashMap::new();
    for (vi, var) in raw.variables.iter().enumerate().skip(1) {
        let name = var.name.to_lowercase();
        if name.starts_with("v(") {
            let real: Vec<f64> = (0..raw.data.len()).map(|pi| raw.real(pi, vi)).collect();
            let imag: Vec<f64> = (0..raw.data.len()).map(|pi| raw.imag(pi, vi)).collect();
            signals.insert(name, ComplexSignal { real, imag });
        }
    }

    if signals.is_empty() {
        return None;
    }

    Some(AcWaveform {
        frequencies,
        signals,
    })
}

/// Convert Xyce/VACASK (name, value) pairs to `v(node)` → voltage map.
fn pairs_to_voltage_map(pairs: Vec<(String, f64)>) -> HashMap<String, f64> {
    pairs
        .into_iter()
        .map(|(name, val)| (normalise_reference_signal(&name), val))
        .collect()
}

fn normalise_reference_signal(name: &str) -> String {
    let lower = name.trim().to_ascii_lowercase();
    if lower.starts_with("v(") || lower.starts_with("i(") {
        lower
    } else {
        format!("v({lower})")
    }
}

// ── Comparison ───────────────────────────────────────────────────────────────

/// Pointwise DC voltage comparison (for DC OP and DC sweep).
fn compare_dc(
    bigs: &HashMap<String, f64>,
    reference: &HashMap<String, f64>,
) -> Option<CompareResult> {
    let shared: Vec<&String> = bigs
        .keys()
        .filter(|k| k.starts_with("v(") && reference.contains_key(*k))
        .collect();

    if shared.is_empty() {
        return None;
    }

    let mut max_err = 0.0_f64;
    let mut all_pass = true;

    for node in &shared {
        let b = bigs[*node];
        let r = reference[*node];
        let denom = r.abs().max(1e-12);
        let err = (b - r).abs() / denom;
        max_err = max_err.max(err);
        if !Tolerance::within(b, r, DC_ABS_TOL, DC_REL_TOL) {
            all_pass = false;
        }
    }

    Some(CompareResult {
        all_pass,
        max_err,
        nodes_compared: shared.len(),
    })
}

/// Detect zero-crossings of a signal around its midpoint. Returns crossing times.
fn find_zero_crossings(times: &[f64], vals: &[f64], midpoint: f64) -> Vec<f64> {
    let mut crossings = Vec::new();
    for i in 1..vals.len() {
        let a = vals[i - 1] - midpoint;
        let b = vals[i] - midpoint;
        // Rising crossing only (a < 0 && b >= 0)
        if a < 0.0 && b >= 0.0 {
            let frac = (-a) / (b - a);
            crossings.push(times[i - 1] + frac * (times[i] - times[i - 1]));
        }
    }
    crossings
}

/// Phase-aligned comparison for oscillatory waveforms.
/// Compares frequency, amplitude, and phase-aligned NRMSE on the last 2 periods.
fn compare_oscillator(
    bigs_times: &[f64],
    bigs_vals: &[f64],
    ref_times: &[f64],
    ref_vals: &[f64],
) -> Option<f64> {
    let ref_max = ref_vals.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let ref_min = ref_vals.iter().copied().fold(f64::INFINITY, f64::min);
    let midpoint = (ref_max + ref_min) / 2.0;
    let ref_amp = ref_max - ref_min;

    if ref_amp < 1e-12 {
        return None;
    }

    let ref_cross = find_zero_crossings(ref_times, ref_vals, midpoint);
    let bigs_cross = find_zero_crossings(bigs_times, bigs_vals, midpoint);

    if ref_cross.len() < 3 || bigs_cross.len() < 3 {
        return None; // Not oscillatory enough
    }

    // Average period from last few crossings
    let ref_periods: Vec<f64> = ref_cross.windows(2).map(|w| w[1] - w[0]).collect();
    let bigs_periods: Vec<f64> = bigs_cross.windows(2).map(|w| w[1] - w[0]).collect();
    let ref_period = ref_periods.iter().sum::<f64>() / ref_periods.len() as f64;
    let bigs_period = bigs_periods.iter().sum::<f64>() / bigs_periods.len() as f64;

    let freq_error = (bigs_period - ref_period).abs() / ref_period;

    // Amplitude comparison over last 2 periods
    let bigs_max = bigs_vals.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let bigs_min = bigs_vals.iter().copied().fold(f64::INFINITY, f64::min);
    let bigs_amp = bigs_max - bigs_min;
    let amp_error = (bigs_amp - ref_amp).abs() / ref_amp;

    // Phase-aligned NRMSE: align by last rising crossing, sample 2 periods
    let ref_align = *ref_cross.last().unwrap();
    let bigs_align = *bigs_cross.last().unwrap();
    let n_samples = 200;
    let mut sum_sq = 0.0;
    let mut count = 0;
    for i in 0..n_samples {
        let phase = -2.0 * ref_period + ref_period * 2.0 * (i as f64) / (n_samples as f64 - 1.0);
        let t_ref = ref_align + phase;
        let t_bigs = bigs_align + phase;
        if t_ref >= ref_times[0]
            && t_ref <= *ref_times.last().unwrap()
            && t_bigs >= bigs_times[0]
            && t_bigs <= *bigs_times.last().unwrap()
        {
            let rv = interpolate(ref_times, ref_vals, t_ref);
            let bv = interpolate(bigs_times, bigs_vals, t_bigs);
            sum_sq += (rv - bv).powi(2);
            count += 1;
        }
    }
    let aligned_nrmse = if count > 0 {
        (sum_sq / count as f64).sqrt() / ref_amp
    } else {
        1.0
    };

    Some(freq_error.max(amp_error).max(aligned_nrmse))
}

/// Waveform NRMSE comparison (for transient analysis).
/// Interpolates BigOSpice waveform to reference time points and computes NRMSE per signal.
/// For oscillatory signals, uses phase-aligned comparison to handle frequency drift.
fn compare_waveforms(bigs: &Waveform, reference: &Waveform) -> Option<CompareResult> {
    let shared: Vec<String> = bigs
        .signals
        .keys()
        .filter(|k| reference.signals.contains_key(*k))
        .cloned()
        .collect();

    if shared.is_empty() {
        return None;
    }

    // Determine the overlapping time range
    let t_start = bigs.times[0].max(reference.times[0]);
    let t_end = bigs
        .times
        .last()
        .unwrap()
        .min(*reference.times.last().unwrap());
    if t_end <= t_start {
        return None;
    }

    // Sample at N evenly-spaced time points within the overlap
    let n_samples = 200.min(reference.times.len());
    let sample_times: Vec<f64> = (0..n_samples)
        .map(|i| t_start + (t_end - t_start) * (i as f64) / (n_samples as f64 - 1.0).max(1.0))
        .collect();

    let mut max_nrmse = 0.0_f64;
    let mut all_pass = true;

    for signal in &shared {
        let bigs_vals = &bigs.signals[signal];
        let ref_vals = &reference.signals[signal];

        // Standard NRMSE comparison
        let bigs_interp: Vec<f64> = sample_times
            .iter()
            .map(|&t| interpolate(&bigs.times, bigs_vals, t))
            .collect();
        let ref_interp: Vec<f64> = sample_times
            .iter()
            .map(|&t| interpolate(&reference.times, ref_vals, t))
            .collect();

        let err_standard = nrmse(&bigs_interp, &ref_interp);

        // If standard comparison fails, try phase-aligned oscillator comparison
        let err = if err_standard > TRAN_NRMSE_TOL {
            if let Some(osc_err) =
                compare_oscillator(&bigs.times, bigs_vals, &reference.times, ref_vals)
            {
                err_standard.min(osc_err)
            } else {
                err_standard
            }
        } else {
            err_standard
        };

        max_nrmse = max_nrmse.max(err);
        if err > TRAN_NRMSE_TOL {
            all_pass = false;
        }
    }

    Some(CompareResult {
        all_pass,
        max_err: max_nrmse,
        nodes_compared: shared.len(),
    })
}

fn compare_ac_waveforms(bigs: &AcWaveform, reference: &AcWaveform) -> Option<AcCompareResult> {
    let shared: Vec<String> = bigs
        .signals
        .keys()
        .filter(|k| reference.signals.contains_key(*k))
        .cloned()
        .collect();

    if shared.is_empty() {
        return None;
    }

    let f_start = bigs.frequencies[0].max(reference.frequencies[0]);
    let f_end = bigs
        .frequencies
        .last()
        .unwrap()
        .min(*reference.frequencies.last().unwrap());
    if f_end < f_start {
        return None;
    }

    let sample_freqs: Vec<f64> = reference
        .frequencies
        .iter()
        .copied()
        .filter(|f| *f >= f_start && *f <= f_end)
        .collect();
    if sample_freqs.is_empty() {
        return None;
    }

    let mut max_gain_err_db = 0.0_f64;
    let mut max_phase_err_deg = 0.0_f64;
    let mut all_pass = true;

    for signal in &shared {
        let bigs_signal = &bigs.signals[signal];
        let ref_signal = &reference.signals[signal];

        for &freq in &sample_freqs {
            let bigs_re = interpolate(&bigs.frequencies, &bigs_signal.real, freq);
            let bigs_im = interpolate(&bigs.frequencies, &bigs_signal.imag, freq);
            let ref_re = interpolate(&reference.frequencies, &ref_signal.real, freq);
            let ref_im = interpolate(&reference.frequencies, &ref_signal.imag, freq);

            // Skip gain comparison when both magnitudes are below noise floor.
            // Comparing dB of near-zero signals amplifies numerical noise differences
            // (e.g. 1e-20 vs 1e-16 = 80 dB "error" on a signal that should be zero).
            let bigs_mag = bigs_re.hypot(bigs_im);
            let ref_mag = ref_re.hypot(ref_im);
            if bigs_mag.max(ref_mag) > 1e-9 {
                let gain_err_db =
                    (magnitude_db(bigs_re, bigs_im) - magnitude_db(ref_re, ref_im)).abs();
                max_gain_err_db = max_gain_err_db.max(gain_err_db);
                if gain_err_db > AC_GAIN_DB_TOL {
                    all_pass = false;
                }
            }

            if bigs_mag.max(ref_mag) > 1e-12 {
                let phase_err =
                    phase_error_deg(phase_deg(bigs_re, bigs_im), phase_deg(ref_re, ref_im));
                max_phase_err_deg = max_phase_err_deg.max(phase_err);
                if phase_err > AC_PHASE_DEG_TOL {
                    all_pass = false;
                }
            }
        }
    }

    Some(AcCompareResult {
        all_pass,
        max_gain_err_db,
        max_phase_err_deg,
        nodes_compared: shared.len(),
    })
}

/// Extract noise spectral density from an ngspice rawfile.
///
/// ngspice noise analysis produces a plot with `plotname` containing "noise spectrum".
/// Variables include `frequency`, `onoise_spectrum` (V/sqrt(Hz)), and `inoise_spectrum`.
/// Note: ngspice stores noise as V/sqrt(Hz), so we square to get V²/Hz for comparison.
fn ngspice_noise_waveform(raw: &RawFile) -> Option<NoiseWaveform> {
    if raw.data.is_empty() || raw.variables.is_empty() {
        return None;
    }

    let frequencies: Vec<f64> = (0..raw.data.len()).map(|pi| raw.real(pi, 0)).collect();

    // Find onoise_spectrum and inoise_spectrum variable indices.
    let mut onoise_idx = None;
    let mut inoise_idx = None;
    for (vi, var) in raw.variables.iter().enumerate() {
        let name = var.name.to_lowercase();
        if name.contains("onoise") {
            onoise_idx = Some(vi);
        }
        if name.contains("inoise") {
            inoise_idx = Some(vi);
        }
    }

    let onoise_spectrum: Vec<f64> = if let Some(vi) = onoise_idx {
        // ngspice stores V/sqrt(Hz); square it to get V²/Hz
        (0..raw.data.len())
            .map(|pi| {
                let v = raw.real(pi, vi);
                v * v
            })
            .collect()
    } else {
        return None;
    };

    let inoise_spectrum: Vec<f64> = if let Some(vi) = inoise_idx {
        (0..raw.data.len())
            .map(|pi| {
                let v = raw.real(pi, vi);
                v * v
            })
            .collect()
    } else {
        vec![0.0; raw.data.len()]
    };

    Some(NoiseWaveform {
        frequencies,
        onoise_spectrum,
        inoise_spectrum,
    })
}

/// Compare noise spectral density waveforms in dB (10*log10 for V²/Hz).
fn compare_noise_waveforms(
    bigs: &NoiseWaveform,
    reference: &NoiseWaveform,
) -> Option<NoiseCompareResult> {
    if bigs.frequencies.is_empty() || reference.frequencies.is_empty() {
        return None;
    }

    let f_start = bigs.frequencies[0].max(reference.frequencies[0]);
    let f_end = bigs
        .frequencies
        .last()
        .unwrap()
        .min(*reference.frequencies.last().unwrap());
    if f_end < f_start {
        return None;
    }

    // Sample at reference frequency points within overlap
    let sample_freqs: Vec<f64> = reference
        .frequencies
        .iter()
        .copied()
        .filter(|f| *f >= f_start && *f <= f_end)
        .collect();
    if sample_freqs.is_empty() {
        return None;
    }

    let mut max_err_db = 0.0_f64;
    let mut all_pass = true;
    let mut signals_compared = 0;

    // Compare onoise_spectrum
    for &freq in &sample_freqs {
        let bigs_val = interpolate(&bigs.frequencies, &bigs.onoise_spectrum, freq);
        let ref_val = interpolate(&reference.frequencies, &reference.onoise_spectrum, freq);
        // Both should be positive; skip if near zero
        if bigs_val.max(ref_val) < 1e-40 {
            continue;
        }
        let bigs_db = 10.0 * bigs_val.max(1e-300).log10();
        let ref_db = 10.0 * ref_val.max(1e-300).log10();
        let err_db = (bigs_db - ref_db).abs();
        max_err_db = max_err_db.max(err_db);
        if err_db > NOISE_DB_TOL {
            all_pass = false;
        }
    }
    signals_compared += 1;

    // Compare inoise_spectrum if both have it
    let bigs_has_inoise = bigs.inoise_spectrum.iter().any(|&v| v > 0.0);
    let ref_has_inoise = reference.inoise_spectrum.iter().any(|&v| v > 0.0);
    if bigs_has_inoise && ref_has_inoise {
        for &freq in &sample_freqs {
            let bigs_val = interpolate(&bigs.frequencies, &bigs.inoise_spectrum, freq);
            let ref_val = interpolate(&reference.frequencies, &reference.inoise_spectrum, freq);
            if bigs_val.max(ref_val) < 1e-40 {
                continue;
            }
            let bigs_db = 10.0 * bigs_val.max(1e-300).log10();
            let ref_db = 10.0 * ref_val.max(1e-300).log10();
            let err_db = (bigs_db - ref_db).abs();
            max_err_db = max_err_db.max(err_db);
            if err_db > NOISE_DB_TOL {
                all_pass = false;
            }
        }
        signals_compared += 1;
    }

    Some(NoiseCompareResult {
        all_pass,
        max_err_db,
        signals_compared,
    })
}

// ── Per-fixture test driver ──────────────────────────────────────────────────

fn test_fixture(sp_path: &Path, sims: &SimAvailability) -> Outcome {
    if let Some(reason) = fixture_skip_reason(sp_path) {
        return Outcome::Skip { reason };
    }

    // Step 1: Run BigOSpice
    let bigs = match run_incspice(sp_path) {
        Ok(v) => v,
        Err(e) if e.starts_with("UNSUPPORTED:") => {
            return Outcome::Skip {
                reason: e,
            };
        }
        Err(e) => {
            // If ngspice also rejects this fixture, classify as expected failure.
            if let Some(ng) = &sims.ngspice {
                if ng.run(sp_path).is_err() {
                    return Outcome::XFail {
                        details: format!("incspice: {e}"),
                    };
                }
            }
            return Outcome::Fail {
                details: format!("incspice: {e}"),
            };
        }
    };

    let mut tried: Vec<String> = Vec::new();
    let mut ref_results: Vec<ReferenceResult> = Vec::new();

    // Step 2: Try ngspice (multi-plot aware)
    if let Some(ng) = &sims.ngspice {
        match ng.run(sp_path) {
            Ok(result) => {
                let mut compared = false;

                // Iterate all plots and match by analysis type
                for plot in &result.plots {
                    let plot_type = plot.analysis_type();

                    match plot_type {
                        RawPlotType::DcSweep => {
                            if !bigs.dc_sweep_waveforms.is_empty() {
                                if let Some(ref_wf) = ngspice_waveform(plot) {
                                    let mut best: Option<(f64, usize)> = None;
                                    for bigs_wf in &bigs.dc_sweep_waveforms {
                                        if let Some(cmp) = compare_waveforms(bigs_wf, &ref_wf) {
                                            compared = true;
                                            if cmp.all_pass {
                                                return Outcome::Pass {
                                                    simulator: "ngspice".into(),
                                                    max_err: cmp.max_err,
                                                    nodes_compared: cmp.nodes_compared,
                                                    method: "DC-sweep-curve",
                                                };
                                            }
                                            let is_better = best.map_or(true, |(prev, _)| cmp.max_err < prev);
                                            if is_better {
                                                best = Some((cmp.max_err, cmp.nodes_compared));
                                            }
                                        }
                                    }
                                    if let Some((err, n)) = best {
                                        tried.push(format!(
                                            "ngspice(DC-sweep-curve): NRMSE={err:.2e} ({n} signals)"
                                        ));
                                    }
                                }
                            }
                            // Also try DC pointwise on sweep endpoint
                            if !bigs.voltages.is_empty() {
                                let ref_map = ngspice_voltages(plot);
                                if let Some(cmp) = compare_dc(&bigs.voltages, &ref_map) {
                                    compared = true;
                                    if cmp.all_pass {
                                        return Outcome::Pass {
                                            simulator: "ngspice".into(),
                                            max_err: cmp.max_err,
                                            nodes_compared: cmp.nodes_compared,
                                            method: "DC-pointwise",
                                        };
                                    }
                                    tried.push(format!(
                                        "ngspice(DC-sweep): max_err={:.2e} ({} nodes)",
                                        cmp.max_err, cmp.nodes_compared
                                    ));
                                }
                            }
                        }

                        RawPlotType::Transient => {
                            if let Some(ref_wf) = ngspice_waveform(plot) {
                                let mut best: Option<(f64, usize, &str)> = None;
                                for (method_name, bigs_wf) in &bigs.waveforms {
                                    if let Some(cmp) = compare_waveforms(bigs_wf, &ref_wf) {
                                        compared = true;
                                        if cmp.all_pass {
                                            return Outcome::Pass {
                                                simulator: "ngspice".into(),
                                                max_err: cmp.max_err,
                                                nodes_compared: cmp.nodes_compared,
                                                method: "waveform-NRMSE",
                                            };
                                        }
                                        let is_better =
                                            best.map_or(true, |(prev, _, _)| cmp.max_err < prev);
                                        if is_better {
                                            best = Some((cmp.max_err, cmp.nodes_compared, method_name));
                                        }
                                    }
                                }
                                if let Some((err, n, method)) = best {
                                    tried.push(format!(
                                        "ngspice(waveform,{method}): NRMSE={err:.2e} ({n} signals)"
                                    ));
                                }
                            }
                        }

                        RawPlotType::Noise => {
                            if let (Some(bigs_noise), Some(ref_noise)) = (
                                bigs.noise_waveform.as_ref(),
                                ngspice_noise_waveform(plot),
                            ) {
                                if let Some(cmp) = compare_noise_waveforms(bigs_noise, &ref_noise) {
                                    compared = true;
                                    if cmp.all_pass {
                                        return Outcome::Pass {
                                            simulator: "ngspice".into(),
                                            max_err: cmp.max_err_db,
                                            nodes_compared: cmp.signals_compared,
                                            method: "noise-spectrum-dB",
                                        };
                                    }
                                    tried.push(format!(
                                        "ngspice(noise): max_err_dB={:.2e} ({} signals)",
                                        cmp.max_err_db, cmp.signals_compared
                                    ));
                                }
                            }
                        }

                        RawPlotType::Ac => {
                            if let (Some(bigs_ac), Some(ref_ac)) = (
                                bigs.ac_waveform.as_ref(),
                                ngspice_ac_waveform(plot),
                            ) {
                                if let Some(cmp) = compare_ac_waveforms(bigs_ac, &ref_ac) {
                                    compared = true;
                                    if cmp.all_pass {
                                        return Outcome::Pass {
                                            simulator: "ngspice".into(),
                                            max_err: cmp.max_gain_err_db.max(cmp.max_phase_err_deg),
                                            nodes_compared: cmp.nodes_compared,
                                            method: "AC-complex",
                                        };
                                    }
                                    tried.push(format!(
                                        "ngspice(AC): max_gain_db={:.2e}, max_phase_deg={:.2e} ({} signals)",
                                        cmp.max_gain_err_db, cmp.max_phase_err_deg, cmp.nodes_compared
                                    ));
                                }
                            }
                        }

                        RawPlotType::DcOp | RawPlotType::Other => {
                            // DC OP or unknown — try pointwise DC comparison
                            if !bigs.voltages.is_empty() {
                                let ref_map = ngspice_voltages(plot);
                                if let Some(cmp) = compare_dc(&bigs.voltages, &ref_map) {
                                    compared = true;
                                    if cmp.all_pass {
                                        return Outcome::Pass {
                                            simulator: "ngspice".into(),
                                            max_err: cmp.max_err,
                                            nodes_compared: cmp.nodes_compared,
                                            method: "DC-pointwise",
                                        };
                                    }
                                    tried.push(format!(
                                        "ngspice(DC): max_err={:.2e} ({} nodes)",
                                        cmp.max_err, cmp.nodes_compared
                                    ));
                                }
                            }
                        }
                    }
                }

                if !compared {
                    let plotnames: Vec<_> = result.plots.iter().map(|p| p.plotname.as_str()).collect();
                    let detail = format!(
                        "no comparable plot/vector in [{}]",
                        plotnames.join(", ")
                    );
                    tried.push(format!("ngspice: {detail}"));
                    ref_results.push(ReferenceResult::from_comparison("ngspice", detail));
                } else {
                    // Ran OK but comparison(s) exceeded tolerance — collect
                    // the most recent tried entries for the summary.
                    let detail = tried.last().cloned().unwrap_or_default();
                    ref_results.push(ReferenceResult::from_comparison("ngspice", detail));
                }
            }
            Err(e) => {
                let rr = ReferenceResult::from_run_error("ngspice", &e);
                tried.push(rr.one_line());
                ref_results.push(rr);
            }
        }
    }

    // Step 3: Try Xyce
    if let Some(xy) = &sims.xyce {
        match run_xyce_in_tempdir(xy, sp_path) {
            Ok(pairs) => {
                let ref_map = pairs_to_voltage_map(pairs);
                match compare_dc(&bigs.voltages, &ref_map) {
                    Some(cmp) if cmp.all_pass => {
                        return Outcome::Pass {
                            simulator: "xyce".into(),
                            max_err: cmp.max_err,
                            nodes_compared: cmp.nodes_compared,
                            method: "DC-pointwise",
                        };
                    }
                    Some(cmp) => {
                        let detail = format!(
                            "max_err={:.2e} ({} nodes)",
                            cmp.max_err, cmp.nodes_compared
                        );
                        tried.push(format!("xyce: {detail}"));
                        ref_results.push(ReferenceResult::from_comparison("xyce", detail));
                    }
                    None => {
                        let detail = "no comparable DC voltage vectors".to_string();
                        tried.push(format!("xyce: {detail}"));
                        ref_results.push(ReferenceResult::from_comparison("xyce", detail));
                    }
                }
            }
            Err(e) => {
                let rr = ReferenceResult::from_run_error("xyce", &e);
                tried.push(rr.one_line());
                ref_results.push(rr);
            }
        }
    }

    // Step 4: Try VACASK
    if let Some(va) = &sims.vacask {
        match va.run(sp_path) {
            Ok(result) => {
                let ref_map = pairs_to_voltage_map(result.node_voltages);
                match compare_dc(&bigs.voltages, &ref_map) {
                    Some(cmp) if cmp.all_pass => {
                        return Outcome::Pass {
                            simulator: "vacask".into(),
                            max_err: cmp.max_err,
                            nodes_compared: cmp.nodes_compared,
                            method: "DC-pointwise",
                        };
                    }
                    Some(cmp) => {
                        let detail = format!(
                            "max_err={:.2e} ({} nodes)",
                            cmp.max_err, cmp.nodes_compared
                        );
                        tried.push(format!("vacask: {detail}"));
                        ref_results.push(ReferenceResult::from_comparison("vacask", detail));
                    }
                    None => {
                        let detail = "no comparable DC voltage vectors".to_string();
                        tried.push(format!("vacask: {detail}"));
                        ref_results.push(ReferenceResult::from_comparison("vacask", detail));
                    }
                }
            }
            Err(e) => {
                let rr = ReferenceResult::from_run_error("vacask", &e);
                tried.push(rr.one_line());
                ref_results.push(rr);
            }
        }
    }

    if tried.is_empty() {
        Outcome::Skip {
            reason: "no reference comparison available".into(),
        }
    } else {
        // Print a structured summary so that when all reference simulators
        // fail it is immediately clear which ones were tried and why each
        // one failed (exit code + stderr snippet).
        if !ref_results.is_empty() {
            eprintln!("{}", format_reference_failure_summary(&ref_results));
        }
        Outcome::Fail {
            details: tried.join("; "),
        }
    }
}

/// Run Xyce in a temp directory so `.prn` files don't pollute the fixtures tree.
fn run_xyce_in_tempdir(
    config: &XyceRunner,
    original_path: &Path,
) -> Result<Vec<(String, f64)>, String> {
    let tmp = tempfile::tempdir().map_err(|e| format!("tmpdir: {e}"))?;
    let filename = original_path.file_name().unwrap();
    let tmp_path = tmp.path().join(filename);
    std::fs::copy(original_path, &tmp_path).map_err(|e| format!("copy: {e}"))?;

    if let Some(parent) = original_path.parent() {
        if let Ok(entries) = std::fs::read_dir(parent) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.extension()
                    .is_some_and(|e| e == "lib" || e == "inc" || e == "mod")
                {
                    if let Some(name) = p.file_name() {
                        let _ = std::fs::copy(&p, tmp.path().join(name));
                    }
                }
            }
        }
    }

    config
        .run(&tmp_path)
        .map(|r| r.node_voltages)
        .map_err(|e| format!("{e}"))
}

// ── Category-level test driver ───────────────────────────────────────────────

fn run_tests(category: &str) {
    let dir = fixtures_dir().join(category);
    let sp_files = glob_sp_files(&dir);
    assert!(!sp_files.is_empty(), "no .sp files in fixtures/{category}");

    let sims = SimAvailability::detect();
    if !sims.any_available() {
        eprintln!(
            "  SKIP {category}: no reference simulators on PATH \
             (need ngspice, Xyce, or vacask)"
        );
        return;
    }
    eprintln!(
        "  {category}: {} fixtures, simulators: {}",
        sp_files.len(),
        sims.summary()
    );

    let mut passed = 0usize;
    let mut failed = 0usize;
    let mut xfailed = 0usize;
    let mut skipped = 0usize;
    let mut failure_details = Vec::new();

    for sp_file in &sp_files {
        let name = sp_file.file_stem().unwrap().to_string_lossy();
        let outcome = test_fixture(sp_file, &sims);

        match &outcome {
            Outcome::Pass {
                simulator,
                max_err,
                nodes_compared,
                method,
            } => {
                eprintln!(
                    "    PASS {name} (vs {simulator}, {method}, err={max_err:.2e}, {nodes_compared} nodes)"
                );
                passed += 1;
            }
            Outcome::XFail { details } => {
                eprintln!("    XFAIL {name}: {details}");
                xfailed += 1;
            }
            Outcome::Skip { reason } => {
                eprintln!("    SKIP {name}: {reason}");
                skipped += 1;
            }
            Outcome::Fail { details } => {
                eprintln!("    FAIL {name}: {details}");
                failed += 1;
                failure_details.push(format!("{name}: {details}"));
            }
        }
        let _ = std::io::stderr().flush();
    }

    eprintln!(
        "\n  {category}: {passed} pass, {failed} fail, {xfailed} xfail, {skipped} skip (total {})",
        sp_files.len()
    );

    if failed > 0 {
        panic!(
            "{category}: {failed}/{} fixture(s) failed:\n{}",
            sp_files.len(),
            failure_details
                .iter()
                .map(|d| format!("  - {d}"))
                .collect::<Vec<_>>()
                .join("\n")
        );
    }
}

// ── Test entry point ─────────────────────────────────────────────────────────

#[test]
#[ignore] // Run explicitly with `--ignored`; per-category tests below cover everything.
fn all_categories() {
    let cats = filtered_categories();
    assert!(
        !cats.is_empty(),
        "no fixture categories selected by INCSPICE_EXTERNAL_CATEGORIES/INCSPICE_EXTERNAL_EXCLUDE"
    );
    let mut failed_cats: Vec<String> = Vec::new();

    for cat in cats {
        eprintln!("\n── {cat} ──");
        let _ = std::io::stderr().flush();
        let c = cat.clone();
        if std::panic::catch_unwind(move || run_tests(&c)).is_err() {
            eprintln!("  CATEGORY FAIL {cat}");
            let _ = std::io::stderr().flush();
            failed_cats.push(cat);
        } else {
            eprintln!("  CATEGORY PASS {cat}");
            let _ = std::io::stderr().flush();
        }
    }

    if !failed_cats.is_empty() {
        panic!("failed categories: {}", failed_cats.join(", "));
    }
}

macro_rules! category_tests {
    ($($name:ident => $category:literal),+ $(,)?) => {
        $(
            #[test]
            fn $name() {
                run_tests($category);
            }
        )+
    };
}

category_tests! {
    category_adversarial => "adversarial",
    category_analog => "analog",
    category_analyses => "analyses",
    category_basic => "basic",
    category_bjt => "bjt",
    category_convergence => "convergence",
    category_dc_sweep => "dc_sweep",
    category_devices => "devices",
    category_digital => "digital",
    category_fourier => "fourier",
    category_medium => "medium",
    category_mosfet => "mosfet",
    category_ngspice => "ngspice",
    category_noise => "noise",
    category_parser => "parser",
    category_power => "power",
    category_quick => "quick",
    category_scaling => "scaling",
    category_sensitivity => "sensitivity",
    category_tline => "tline",
    category_xyce => "xyce",
}

// ── MOSFET model self-tests (no external simulator required) ─────────���───────

#[test]
fn reference_signal_normalization_preserves_wrapped_voltage_and_current() {
    let map = pairs_to_voltage_map(vec![
        ("out".to_string(), 1.0),
        ("V(in)".to_string(), 2.0),
        ("I(VDD)".to_string(), 3.0),
    ]);

    assert_eq!(map.get("v(out)"), Some(&1.0));
    assert_eq!(map.get("v(in)"), Some(&2.0));
    assert_eq!(map.get("i(vdd)"), Some(&3.0));
    assert!(!map.contains_key("v(v(in))"));
    assert!(!map.contains_key("v(i(vdd))"));
}

/// Verify that a CMOS inverter DC OP gives the correct output voltage.
///
/// With VIN=0V the PMOS is on (Vgs_p = 0-3.3 = -3.3V, well below Vtp=-0.7V)
/// and the NMOS is off (Vgs_n = 0V < Vtn=0.7V), so VOUT should be very close
/// to VDD (≥ 3.2V). Before the PMOS polarity fix, `pmos=1.0` was never
/// injected into the device params, so the PMOS was evaluated as NMOS —
/// producing a completely wrong operating point.
#[test]
fn mosfet_pmos_flag_injected_cmos_inverter_dc_op() {
    let netlist = r#"CMOS inverter VIN=0 DC OP test
VDD vdd 0 DC 3.3
VIN in 0 DC 0
M2 out in vdd vdd PMOD W=20u L=1u
M1 out in 0 0 NMOD W=10u L=1u
.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05)
.OP
.END
"#;
    let (circuit, _, _) = SpiceParser::parse_bytes(netlist.as_bytes()).expect("parse failed");

    // Confirm pmos=1.0 is present in M2's params after model merge.
    let m2 = circuit.find_device("m2").expect("M2 not found");
    let pmos_flag = m2.params.get("pmos");
    assert!(
        pmos_flag.is_some() && (pmos_flag.unwrap() - 1.0).abs() < 1e-9,
        "PMOS device must have pmos=1.0 in params after model merge, got {:?}",
        pmos_flag
    );

    let registry = DeviceRegistry::new_default();
    let out = run_dc_op(&circuit, &registry).expect("DC OP failed");

    let out_v = out
        .result
        .node_voltages
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case("out"))
        .map(|(_, v)| *v)
        .expect("output node 'out' not found in DC OP result");

    // PMOS on, NMOS off → VOUT must be close to VDD.
    assert!(
        out_v >= 3.1,
        "CMOS inverter with VIN=0: VOUT={:.4}V, expected ≥3.1V (PMOS on, NMOS off). \
         Check that pmos=1.0 is injected into PMOS device params during model merge.",
        out_v
    );
}

/// Verify NMOS-only diode-connected circuit DC OP.
///
/// A diode-connected NMOS (gate tied to drain) with a drain resistor to VDD
/// should produce a drain voltage in the range (Vth, VDD) — meaning the
/// transistor conducts some current and the voltage divides between the
/// resistor and the MOSFET.
#[test]
fn mosfet_nmos_diode_connected_dc_op() {
    let netlist = r#"NMOS diode-connected DC OP test
VDD vdd 0 DC 3.3
R1 vdd drain 1k
M1 drain drain 0 0 NMOD W=10u L=1u
.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.OP
.END
"#;
    let (circuit, _, _) = SpiceParser::parse_bytes(netlist.as_bytes()).expect("parse failed");
    let registry = DeviceRegistry::new_default();
    let out = run_dc_op(&circuit, &registry).expect("DC OP failed");

    let drain_v = out
        .result
        .node_voltages
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case("drain"))
        .map(|(_, v)| *v)
        .expect("drain node not found in DC OP result");

    // Drain voltage must be above Vth (device is on) and below VDD (resistor drops voltage).
    assert!(
        drain_v > 0.7 && drain_v < 3.3,
        "NMOS diode-connected: drain={:.4}V, expected between 0.7V and 3.3V",
        drain_v
    );
}

/// Verify PMOS-only diode-connected circuit DC OP.
///
/// A diode-connected PMOS (gate tied to drain) with a source at VDD and a
/// drain load resistor to ground. With VTO=-0.7V the device conducts when
/// Vgs < -0.7V, i.e. Vdrain < VDD - 0.7V.  The drain voltage should settle
/// well above 0V and below VDD.
#[test]
fn mosfet_pmos_diode_connected_dc_op() {
    let netlist = r#"PMOS diode-connected DC OP test
VDD vdd 0 DC 3.3
R1 drain 0 1k
M1 drain drain vdd vdd PMOD W=20u L=1u
.MODEL PMOD PMOS (VTO=-0.7 KP=50u GAMMA=0.4 PHI=0.65 LAMBDA=0.05)
.OP
.END
"#;
    let (circuit, _, _) = SpiceParser::parse_bytes(netlist.as_bytes()).expect("parse failed");

    let m1 = circuit.find_device("m1").expect("M1 not found");
    let pmos_flag = m1.params.get("pmos");
    assert!(
        pmos_flag.is_some() && (pmos_flag.unwrap() - 1.0).abs() < 1e-9,
        "diode-connected PMOS must have pmos=1.0 in params, got {:?}",
        pmos_flag
    );

    let registry = DeviceRegistry::new_default();
    let out = run_dc_op(&circuit, &registry).expect("DC OP failed");

    let drain_v = out
        .result
        .node_voltages
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case("drain"))
        .map(|(_, v)| *v)
        .expect("drain node not found in DC OP result");

    // PMOS conducts: drain voltage should be > 0 and < VDD-|Vtp| ≈ 2.6V.
    assert!(
        drain_v > 0.1 && drain_v < 3.3,
        "PMOS diode-connected: drain={:.4}V, expected between 0.1V and 3.3V",
        drain_v
    );
}
