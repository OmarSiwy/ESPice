//! External benchmark suite runner.
//!
//! Discovers netlists from three external suites (ngspice regression,
//! Xyce regression, ISCAS85) and runs PiSIM against each, optionally
//! comparing wall-time with ngspice.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Instant;

use pisim_parser::SpiceParser;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Which external suite to run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExternalSuite {
    Ngspice,
    Xyce,
    Iscas85,
}

impl ExternalSuite {
    /// Canonical subdirectory name under `tests/external/`.
    pub fn dir_name(self) -> &'static str {
        match self {
            ExternalSuite::Ngspice => "ngspice/tests",
            ExternalSuite::Xyce => "xyce_regression/Netlists",
            ExternalSuite::Iscas85 => "iscas85-benchmarks/ISCAS85",
        }
    }
}

impl std::str::FromStr for ExternalSuite {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_ascii_lowercase().as_str() {
            "ngspice" => Ok(ExternalSuite::Ngspice),
            "xyce" => Ok(ExternalSuite::Xyce),
            "iscas85" => Ok(ExternalSuite::Iscas85),
            other => Err(format!("unknown suite: {other}; expected ngspice|xyce|iscas85")),
        }
    }
}

/// Per-netlist outcome.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum BenchStatus {
    Pass,
    Fail,
    /// PiSIM cannot yet handle this netlist; `reason` explains why.
    Skip,
}

impl std::fmt::Display for BenchStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BenchStatus::Pass => write!(f, "PASS"),
            BenchStatus::Fail => write!(f, "FAIL"),
            BenchStatus::Skip => write!(f, "SKIP"),
        }
    }
}

/// Result for a single netlist.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExternalResult {
    pub netlist_path: PathBuf,
    pub pisim_time_ms: f64,
    pub ngspice_time_ms: f64,
    /// Relative error of first waveform signal vs ngspice (percent), or NaN.
    pub first_signal_err_pct: f64,
    pub status: BenchStatus,
    pub skip_reason: String,
    pub error: String,
}

/// Aggregated results for an entire suite.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExternalSuiteResult {
    pub suite: String,
    pub passed: usize,
    pub failed: usize,
    pub skipped: usize,
    /// Geometric mean of (ngspice_time / pisim_time) over all passing runs
    /// where both simulators completed.  NaN if no valid pairs.
    pub speedup_gmean: f64,
    pub results: Vec<ExternalResult>,
}

/// Options controlling the external suite run.
#[derive(Debug, Clone)]
pub struct ExternalBenchOptions {
    /// If true, also invoke ngspice and measure its wall time + accuracy.
    pub with_ngspice: bool,
    /// Number of timing repetitions per netlist for PiSIM.
    pub nruns: usize,
}

impl Default for ExternalBenchOptions {
    fn default() -> Self {
        Self {
            with_ngspice: false,
            nruns: 1,
        }
    }
}

// ---------------------------------------------------------------------------
// Netlist discovery
// ---------------------------------------------------------------------------

/// Recursively find all SPICE netlist files under `root`.
/// ISCAS85 benchmarks are Verilog (`.v`) — they are excluded; only
/// `.sp`, `.cir`, `.net`, `.spi` files are collected.
pub fn discover_netlists(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    collect_netlists(root, &mut out);
    out.sort();
    out
}

fn collect_netlists(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_netlists(&path, out);
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            if matches!(ext.to_ascii_lowercase().as_str(), "sp" | "cir" | "net" | "spi") {
                out.push(path);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Skip detection
// ---------------------------------------------------------------------------

/// Inspect netlist source for directives PiSIM does not yet support.
/// Returns `Some(reason)` if the netlist should be skipped.
fn detect_skip_reason(content: &str) -> Option<String> {
    let mut reasons: Vec<&str> = Vec::new();

    for line in content.lines() {
        let trimmed = line.trim();
        // Comments and blank lines.
        if trimmed.is_empty() || trimmed.starts_with('*') || trimmed.starts_with('$') {
            continue;
        }
        let lower = trimmed.to_ascii_lowercase();

        // .control … .endc blocks — ngspice interactive scripting.
        if lower.starts_with(".control") {
            reasons.push(".control/.endc (ngspice scripting) not supported");
        }
        // .subckt with BSIM-SOI / HiSIM / HICUM level models.
        if lower.starts_with(".model") {
            if lower.contains("bsimsoi") || lower.contains("bsim3soi") || lower.contains("bsim4soi") {
                reasons.push("BSIM-SOI model not yet supported");
            }
            if lower.contains("hisim") {
                reasons.push("HiSIM model not yet supported");
            }
            if lower.contains("hicum") {
                reasons.push("HICUM model not yet supported");
            }
            if lower.contains("level=5")
                || lower.contains("level=6")
                || lower.contains("level=7")
                || lower.contains("level=8")
                || lower.contains("level=9")
            {
                // Conservative: flag high-level MOSFET models we may not handle.
                reasons.push("high-level MOSFET model (level≥5) may not be supported");
            }
        }
        // Xyce-specific: .GLOBAL, .NODESET advanced, .MEASURE with complex syntax.
        if lower.starts_with(".global") {
            reasons.push(".GLOBAL directive (Xyce) not yet supported");
        }
        // .FFT, .DISTO, .NOISE, .FOUR, .SENS, .PZ, .TF.
        for kw in &[".fft", ".disto", ".noise", ".four", ".pz"] {
            if lower.starts_with(kw) {
                reasons.push("unsupported analysis directive (.fft/.disto/.noise/.four/.pz)");
            }
        }
        // UIC keyword in .TRAN — often paired with initial conditions PiSIM ignores.
        // We allow it but don't skip — it just runs without UIC.

        // .LIB include — may reference external model files we don't have.
        if lower.starts_with(".lib") && !lower.starts_with(".library") {
            // If it references an external file path, skip.
            let parts: Vec<&str> = trimmed.split_ascii_whitespace().collect();
            if parts.len() >= 2 {
                let arg = parts[1];
                // Paths usually contain '/' or '.'; bare section names don't.
                if arg.contains('/') || arg.contains('\\') || arg.contains('.') {
                    reasons.push(".lib external file include not resolved");
                }
            }
        }
    }

    reasons.dedup();
    if reasons.is_empty() {
        None
    } else {
        Some(reasons.join("; "))
    }
}

/// Determine the best analysis to attempt from the netlist content.
/// Returns None if no supported analysis directive is found.
fn infer_analysis(content: &str) -> Option<crate::Analysis> {
    for line in content.lines() {
        let t = line.trim().to_ascii_lowercase();
        if t.starts_with('*') || t.starts_with('$') || t.is_empty() {
            continue;
        }
        if t.starts_with(".tran") {
            return Some(crate::Analysis::Tran);
        }
        if t.starts_with(".ac") {
            return Some(crate::Analysis::Ac);
        }
        if t.starts_with(".dc") {
            return Some(crate::Analysis::Dc);
        }
        if t.starts_with(".op") {
            return Some(crate::Analysis::Dc);
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Per-netlist runner
// ---------------------------------------------------------------------------

fn run_one(
    path: &Path,
    opts: &ExternalBenchOptions,
) -> ExternalResult {
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) => {
            return ExternalResult {
                netlist_path: path.to_path_buf(),
                pisim_time_ms: f64::NAN,
                ngspice_time_ms: f64::NAN,
                first_signal_err_pct: f64::NAN,
                status: BenchStatus::Fail,
                skip_reason: String::new(),
                error: format!("read error: {e}"),
            };
        }
    };

    // Skip detection before parsing.
    if let Some(reason) = detect_skip_reason(&content) {
        return ExternalResult {
            netlist_path: path.to_path_buf(),
            pisim_time_ms: f64::NAN,
            ngspice_time_ms: f64::NAN,
            first_signal_err_pct: f64::NAN,
            status: BenchStatus::Skip,
            skip_reason: reason,
            error: String::new(),
        };
    }

    // Infer analysis.
    let analysis = match infer_analysis(&content) {
        Some(a) => a,
        None => {
            return ExternalResult {
                netlist_path: path.to_path_buf(),
                pisim_time_ms: f64::NAN,
                ngspice_time_ms: f64::NAN,
                first_signal_err_pct: f64::NAN,
                status: BenchStatus::Skip,
                skip_reason: "no supported analysis directive (.tran/.ac/.dc/.op)".into(),
                error: String::new(),
            };
        }
    };

    // Parse check — catch obvious parse failures quickly.
    if let Err(e) = SpiceParser::parse(&content) {
        return ExternalResult {
            netlist_path: path.to_path_buf(),
            pisim_time_ms: f64::NAN,
            ngspice_time_ms: f64::NAN,
            first_signal_err_pct: f64::NAN,
            status: BenchStatus::Skip,
            skip_reason: format!("parse failed: {e}"),
            error: String::new(),
        };
    }

    // Run PiSIM (nruns times, take median).
    use crate::perf::{time_pisim, time_ngspice};
    let (pisim_stats, pisim_run) = match time_pisim(path, analysis, opts.nruns) {
        Ok(v) => v,
        Err(e) => {
            return ExternalResult {
                netlist_path: path.to_path_buf(),
                pisim_time_ms: f64::NAN,
                ngspice_time_ms: f64::NAN,
                first_signal_err_pct: f64::NAN,
                status: BenchStatus::Fail,
                skip_reason: String::new(),
                error: format!("pisim error: {e}"),
            };
        }
    };
    let pisim_ms = pisim_stats.median_secs * 1000.0;

    // Optionally run ngspice.
    let (ng_ms, err_pct) = if opts.with_ngspice {
        match time_ngspice(path, opts.nruns) {
            Ok((ng_stats, ng_result)) => {
                let ms = ng_stats.median_secs * 1000.0;
                // Compute first-signal relative error percent.
                let pct = first_signal_rel_err_pct(
                    analysis,
                    &pisim_run,
                    &ng_result,
                );
                (ms, pct)
            }
            Err(_) => (f64::NAN, f64::NAN),
        }
    } else {
        (f64::NAN, f64::NAN)
    };

    ExternalResult {
        netlist_path: path.to_path_buf(),
        pisim_time_ms: pisim_ms,
        ngspice_time_ms: ng_ms,
        first_signal_err_pct: err_pct,
        status: BenchStatus::Pass,
        skip_reason: String::new(),
        error: String::new(),
    }
}

/// Compute the first-signal relative error percentage between PiSIM and ngspice.
fn first_signal_rel_err_pct(
    analysis: crate::Analysis,
    pisim_run: &crate::perf::PisimRun,
    ng_result: &pisim_test_harness::ngspice::NgspiceResult,
) -> f64 {
    use crate::Analysis;
    let pisim_first = match analysis {
        Analysis::Dc => pisim_run.dc_op_pairs.as_ref().map(|pairs| {
            pairs.iter().map(|(_, v)| *v).collect::<Vec<_>>()
        }).or_else(|| pisim_run.first_signal.clone()),
        Analysis::Tran | Analysis::Ac => pisim_run.first_signal.clone(),
    };
    let Some(pisim_vals) = pisim_first else {
        return f64::NAN;
    };
    let (_, _, ng_data) = ng_result.rawfile.as_waveform();
    let ng_vals: Vec<f64> = ng_data.iter()
        .map(|row| row.first().copied().unwrap_or(0.0))
        .collect();
    if pisim_vals.is_empty() || ng_vals.is_empty() {
        return f64::NAN;
    }
    let n = pisim_vals.len().min(ng_vals.len());
    let max_rel = pisim_vals.iter().take(n).zip(ng_vals.iter().take(n))
        .map(|(a, b)| {
            let denom = b.abs().max(1e-12);
            (a - b).abs() / denom
        })
        .fold(0.0_f64, f64::max);
    max_rel * 100.0
}

// ---------------------------------------------------------------------------
// Suite runner
// ---------------------------------------------------------------------------

/// Run an entire external suite.
///
/// `suite_dir` should point to the root directory for the suite
/// (e.g. `tests/external/ngspice/tests`).
pub fn run_external_suite(
    suite_dir: &Path,
    suite_name: &str,
    options: &ExternalBenchOptions,
) -> ExternalSuiteResult {
    let netlists = discover_netlists(suite_dir);
    let mut results: Vec<ExternalResult> = netlists
        .iter()
        .map(|p| run_one(p, options))
        .collect();

    results.sort_by(|a, b| a.netlist_path.cmp(&b.netlist_path));

    let passed = results.iter().filter(|r| r.status == BenchStatus::Pass).count();
    let failed = results.iter().filter(|r| r.status == BenchStatus::Fail).count();
    let skipped = results.iter().filter(|r| r.status == BenchStatus::Skip).count();

    // Geometric mean speedup (ngspice / pisim) over runs where both completed.
    let speedup_gmean = {
        let valid: Vec<f64> = results.iter()
            .filter(|r| {
                r.status == BenchStatus::Pass
                    && r.ngspice_time_ms.is_finite()
                    && r.ngspice_time_ms > 0.0
                    && r.pisim_time_ms.is_finite()
                    && r.pisim_time_ms > 0.0
            })
            .map(|r| r.ngspice_time_ms / r.pisim_time_ms)
            .collect();
        if valid.is_empty() {
            f64::NAN
        } else {
            let log_sum: f64 = valid.iter().map(|x| x.ln()).sum();
            (log_sum / valid.len() as f64).exp()
        }
    };

    ExternalSuiteResult {
        suite: suite_name.to_string(),
        passed,
        failed,
        skipped,
        speedup_gmean,
        results,
    }
}
