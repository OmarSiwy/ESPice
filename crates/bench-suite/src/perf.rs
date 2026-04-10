//! Wall-time performance measurement for PiSIM and (optionally) ngspice.

use serde::{Deserialize, Serialize};
use std::path::Path;
use std::time::{Duration, Instant};

use pisim_analysis::{AcConfig, AcSweepType, DcSweepConfig, TransientConfig};
use pisim_device::DeviceRegistry;
use pisim_parser::{AnalysisKind, AnalysisStatement, SpiceParser};
use pisim_test_harness::ngspice::NgspiceConfig;

use crate::accuracy::{compare_dc_op, compare_samples, AccuracyReport};
use crate::Analysis;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimingStats {
    pub min_secs: f64,
    pub median_secs: f64,
    pub max_secs: f64,
    pub n_runs: usize,
}

impl TimingStats {
    pub fn from_durations(mut durs: Vec<Duration>) -> Self {
        durs.sort();
        let n = durs.len();
        let to_s = |d: Duration| d.as_secs_f64();
        let median = if n == 0 { f64::NAN } else { to_s(durs[n / 2]) };
        Self {
            min_secs: durs.first().map(|d| to_s(*d)).unwrap_or(f64::NAN),
            median_secs: median,
            max_secs: durs.last().map(|d| to_s(*d)).unwrap_or(f64::NAN),
            n_runs: n,
        }
    }

    pub fn nan() -> Self {
        Self {
            min_secs: f64::NAN,
            median_secs: f64::NAN,
            max_secs: f64::NAN,
            n_runs: 0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PerfReport {
    pub pisim: TimingStats,
    pub ngspice: Option<TimingStats>,
    /// pisim.median / ngspice.median (>1.0 means PiSIM is slower).
    pub ratio_pisim_over_ngspice: Option<f64>,
}

/// Outcome of running PiSIM once.
pub struct PisimRun {
    pub duration: Duration,
    pub dc_op_pairs: Option<Vec<(String, f64)>>,
    pub axis: Option<Vec<f64>>,
    pub first_signal: Option<Vec<f64>>,
}

fn pget(params: &[(String, f64)], key: &str) -> Option<f64> {
    params
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(key))
        .map(|(_, v)| *v)
}

fn find_kind<'a>(
    analyses: &'a [AnalysisStatement],
    kind: AnalysisKind,
) -> Option<&'a AnalysisStatement> {
    analyses.iter().find(|a| a.kind == kind)
}

/// Find the first independent voltage source in the netlist (for fallback DC sweep src).
fn first_v_source(content: &str) -> Option<String> {
    content
        .lines()
        .map(|l| l.trim_start())
        .filter(|l| !l.is_empty() && !l.starts_with('*') && !l.starts_with('.'))
        .find_map(|l| {
            let first = l.split_ascii_whitespace().next()?;
            if first.to_ascii_lowercase().starts_with('v') {
                Some(first.to_string())
            } else {
                None
            }
        })
}

/// Run PiSIM once on the netlist with the requested analysis.
pub fn run_pisim_once(netlist_path: &Path, analysis: Analysis) -> Result<PisimRun, String> {
    let content = std::fs::read_to_string(netlist_path)
        .map_err(|e| format!("read failed: {e}"))?;
    let (mut circuit, analyses, _opts) =
        SpiceParser::parse(&content).map_err(|e| format!("parse failed: {e}"))?;
    let registry = DeviceRegistry::new_default();

    let start = Instant::now();
    let run = match analysis {
        Analysis::Dc => {
            // Prefer DC sweep if netlist defines it; else fall back to DC OP.
            if let Some(stmt) = find_kind(&analyses, AnalysisKind::DcSweep) {
                let start_v = pget(&stmt.params, "start").unwrap_or(0.0);
                let stop_v = pget(&stmt.params, "stop").unwrap_or(1.0);
                let step_v = pget(&stmt.params, "step").unwrap_or(0.1);
                let src = first_v_source(&content).unwrap_or_else(|| "V1".to_string());
                let cfg = DcSweepConfig::new(&src, start_v, stop_v, step_v);
                let res = pisim_analysis::run_dc_sweep(&circuit, &registry, &cfg)
                    .map_err(|e| format!("DC sweep failed: {e}"))?;
                let dur = start.elapsed();
                let first = res
                    .node_voltages
                    .iter()
                    .map(|row| row.first().copied().unwrap_or(0.0))
                    .collect::<Vec<f64>>();
                PisimRun {
                    duration: dur,
                    dc_op_pairs: None,
                    axis: Some(res.sweep_values.clone()),
                    first_signal: Some(first),
                }
            } else {
                let out = pisim_analysis::run_dc_op(&circuit, &registry)
                    .map_err(|e| format!("DC OP failed: {e}"))?;
                let dur = start.elapsed();
                let pairs = out
                    .result
                    .node_voltages
                    .iter()
                    .map(|(n, v)| (n.clone(), *v))
                    .chain(
                        out.result
                            .branch_currents
                            .iter()
                            .map(|(n, v)| (n.clone(), *v)),
                    )
                    .collect::<Vec<_>>();
                PisimRun {
                    duration: dur,
                    dc_op_pairs: Some(pairs),
                    axis: None,
                    first_signal: None,
                }
            }
        }
        Analysis::Tran => {
            let stmt = find_kind(&analyses, AnalysisKind::Tran)
                .ok_or_else(|| "no .tran statement in netlist".to_string())?;
            let tstep = pget(&stmt.params, "tstep").unwrap_or(1e-9);
            let tstop = pget(&stmt.params, "tstop").unwrap_or(1e-6);
            let cfg = TransientConfig::new(tstep, tstop);
            let res = pisim_analysis::run_transient(&mut circuit, &registry, &cfg)
                .map_err(|e| format!("transient failed: {e}"))?;
            let dur = start.elapsed();
            let first = res
                .node_voltages
                .iter()
                .map(|row| row.first().copied().unwrap_or(0.0))
                .collect::<Vec<f64>>();
            PisimRun {
                duration: dur,
                dc_op_pairs: None,
                axis: Some(res.times.clone()),
                first_signal: Some(first),
            }
        }
        Analysis::Ac => {
            let stmt = find_kind(&analyses, AnalysisKind::Ac)
                .ok_or_else(|| "no .ac statement in netlist".to_string())?;
            let npoints = pget(&stmt.params, "npoints").unwrap_or(10.0) as usize;
            let fstart = pget(&stmt.params, "fstart").unwrap_or(1.0);
            let fstop = pget(&stmt.params, "fstop").unwrap_or(1e6);
            let sweep_type_val = pget(&stmt.params, "sweep_type").unwrap_or(1.0);
            let sweep_type = match sweep_type_val as u8 {
                2 => AcSweepType::Octave,
                0 => AcSweepType::Linear,
                _ => AcSweepType::Decade,
            };
            let cfg = AcConfig::new(fstart, fstop, npoints, sweep_type);
            let res = pisim_analysis::run_ac(&circuit, &registry, &cfg)
                .map_err(|e| format!("AC failed: {e}"))?;
            let dur = start.elapsed();
            let first = res
                .node_magnitudes
                .iter()
                .map(|row| row.first().copied().unwrap_or(0.0))
                .collect::<Vec<f64>>();
            PisimRun {
                duration: dur,
                dc_op_pairs: None,
                axis: Some(res.frequencies.clone()),
                first_signal: Some(first),
            }
        }
    };
    Ok(run)
}

/// Time PiSIM N times.  Returns timing stats and the *last* run output.
pub fn time_pisim(
    netlist: &Path,
    analysis: Analysis,
    nruns: usize,
) -> Result<(TimingStats, PisimRun), String> {
    let mut durs = Vec::with_capacity(nruns);
    let mut last: Option<PisimRun> = None;
    for _ in 0..nruns {
        let r = run_pisim_once(netlist, analysis)?;
        durs.push(r.duration);
        last = Some(r);
    }
    Ok((TimingStats::from_durations(durs), last.unwrap()))
}

/// Time ngspice N times via the test harness.
pub fn time_ngspice(
    netlist: &Path,
    nruns: usize,
) -> Result<(TimingStats, pisim_test_harness::ngspice::NgspiceResult), String> {
    let cfg = NgspiceConfig::default();
    if !cfg.is_available() {
        return Err("ngspice not available on PATH".into());
    }
    let mut durs = Vec::with_capacity(nruns);
    let mut last = None;
    for _ in 0..nruns {
        let r = cfg
            .run(netlist)
            .map_err(|e| format!("ngspice run failed: {e}"))?;
        durs.push(r.wall_time);
        last = Some(r);
    }
    Ok((TimingStats::from_durations(durs), last.unwrap()))
}

/// Run a complete head-to-head benchmark for one netlist.
pub fn run_head_to_head(
    netlist: &Path,
    analysis: Analysis,
    nruns: usize,
    with_ngspice: bool,
) -> (PerfReport, Option<AccuracyReport>, String, String) {
    let mut pisim_status = "ok".to_string();
    let mut ngspice_status = "skipped".to_string();

    let (pisim_stats, pisim_run) = match time_pisim(netlist, analysis, nruns) {
        Ok(v) => v,
        Err(e) => {
            pisim_status = format!("error: {e}");
            return (
                PerfReport {
                    pisim: TimingStats::nan(),
                    ngspice: None,
                    ratio_pisim_over_ngspice: None,
                },
                None,
                pisim_status,
                ngspice_status,
            );
        }
    };

    let (ng_stats_opt, accuracy) = if with_ngspice {
        match time_ngspice(netlist, nruns) {
            Ok((stats, ng_result)) => {
                ngspice_status = "ok".to_string();
                let acc = match analysis {
                    Analysis::Dc => {
                        if let Some(pairs) = pisim_run.dc_op_pairs.as_ref() {
                            let ng_pairs = ng_result.rawfile.as_dc_pairs();
                            Some(compare_dc_op(pairs, &ng_pairs))
                        } else if let Some(first) = pisim_run.first_signal.as_ref() {
                            let (_, _, data) = ng_result.rawfile.as_waveform();
                            let ng_first: Vec<f64> = data
                                .iter()
                                .map(|r| r.first().copied().unwrap_or(0.0))
                                .collect();
                            Some(compare_samples(first, &ng_first))
                        } else {
                            None
                        }
                    }
                    Analysis::Tran | Analysis::Ac => {
                        if let Some(first) = pisim_run.first_signal.as_ref() {
                            let (_, _, data) = ng_result.rawfile.as_waveform();
                            let ng_first: Vec<f64> = data
                                .iter()
                                .map(|r| r.first().copied().unwrap_or(0.0))
                                .collect();
                            Some(compare_samples(first, &ng_first))
                        } else {
                            None
                        }
                    }
                };
                (Some(stats), acc)
            }
            Err(e) => {
                ngspice_status = format!("error: {e}");
                (None, None)
            }
        }
    } else {
        (None, None)
    };

    let ratio = match (pisim_stats.median_secs, &ng_stats_opt) {
        (p, Some(ng)) if ng.median_secs > 0.0 && p.is_finite() => Some(p / ng.median_secs),
        _ => None,
    };

    (
        PerfReport {
            pisim: pisim_stats,
            ngspice: ng_stats_opt,
            ratio_pisim_over_ngspice: ratio,
        },
        accuracy,
        pisim_status,
        ngspice_status,
    )
}
