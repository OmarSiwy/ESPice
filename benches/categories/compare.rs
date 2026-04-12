//! Head-to-head comparison benchmarks: BigOSpice vs ngspice/xyce/VACASK.
//!
//! Discovers all `.sp` fixture files across every known subdirectory under
//! `tests/fixtures/` and runs each through BigOSpice and any available
//! external simulators.
//! Set `BIGOSPICE_HAVE_SIMS=1` to enable external comparisons.
//! Override binaries via `NGSPICE_BIN`, `XYCE_BIN`, `VACASK_BIN`.

use criterion::Criterion;

// ── external simulator runners ─────────────────────────────────────────────────

fn ngspice_run(bin: &str, netlist: &str) {
    let tmp = tempfile::tempdir().unwrap();
    let sp = tmp.path().join("ckt.sp");
    let raw = tmp.path().join("out.raw");
    let ctl = tmp.path().join("run.cir");
    std::fs::write(&sp, netlist).unwrap();
    std::fs::write(
        &ctl,
        format!(
            ".include {}\n.control\nset filetype=ascii\nrun\nwrite {} all\n.endc\n",
            sp.display(),
            raw.display()
        ),
    )
    .unwrap();
    std::process::Command::new(bin)
        .arg("-b")
        .arg(&ctl)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
}

fn xyce_run(bin: &str, netlist: &str) {
    let tmp = tempfile::tempdir().unwrap();
    let sp = tmp.path().join("ckt.sp");
    std::fs::write(&sp, netlist).unwrap();
    std::process::Command::new(bin)
        .arg(&sp)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
}

fn vacask_run(bin: &str, netlist: &str) {
    let tmp = tempfile::tempdir().unwrap();
    let sp = tmp.path().join("ckt.sp");
    std::fs::write(&sp, netlist).unwrap();
    std::process::Command::new(bin)
        .arg(&sp)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap();
}

/// Run BigOSpice on a netlist string, dispatching on whatever analyses the
/// file declares (DC OP, transient, AC). Parameters are taken from the
/// parsed analysis statements, mirroring the CLI behaviour.
fn bigospice_run(netlist: &str) {
    use bigospice_analysis::{AcConfig, AcSweepType, TransientConfig};
    use bigospice_device::DeviceRegistry;
    use bigospice_parser::{AnalysisKind, SpiceParser};

    let Ok((circuit, analyses, _)) = SpiceParser::parse(netlist) else { return };
    let registry = DeviceRegistry::new_default();

    for stmt in &analyses {
        let p = |key: &str| stmt.params.iter().find(|(k, _)| k == key).map(|(_, v)| *v);
        let _ = match &stmt.kind {
            AnalysisKind::DcOp => bigospice_analysis::run_dc_op(&circuit, &registry).map(|_| ()),
            AnalysisKind::Tran => {
                let cfg = TransientConfig::new(
                    p("tstep").unwrap_or(1e-9),
                    p("tstop").unwrap_or(1e-6),
                );
                bigospice_analysis::run_transient(&mut circuit.clone(), &registry, &cfg)
                    .map(|_| ())
            }
            AnalysisKind::Ac => {
                let sweep = match p("sweep_type").unwrap_or(1.0) as u8 {
                    0 => AcSweepType::Linear,
                    2 => AcSweepType::Octave,
                    _ => AcSweepType::Decade,
                };
                let cfg = AcConfig::new(
                    p("fstart").unwrap_or(1.0),
                    p("fstop").unwrap_or(1e9),
                    p("npoints").unwrap_or(10.0) as usize,
                    sweep,
                );
                bigospice_analysis::run_ac(&circuit, &registry, &cfg).map(|_| ())
            }
            _ => continue,
        };
    }
}

fn sim_available(bin: &str, version_flag: &str) -> bool {
    std::process::Command::new(bin)
        .arg(version_flag)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok()
}

// ── bench entry ───────────────────────────────────────────────────────────────

pub fn bench_compare(c: &mut Criterion) {
    let have_sims = std::env::var("BIGOSPICE_HAVE_SIMS").is_ok();
    let ng = std::env::var("NGSPICE_BIN").unwrap_or_else(|_| "ngspice".into());
    let xyce = std::env::var("XYCE_BIN").unwrap_or_else(|_| "Xyce".into());
    let vacask = std::env::var("VACASK_BIN").unwrap_or_else(|_| "vacask".into());

    let ng_ok = have_sims && sim_available(&ng, "--version");
    let xyce_ok = have_sims && sim_available(&xyce, "-v");
    let vacask_ok = have_sims && sim_available(&vacask, "--version");

    for (name, netlist) in crate::common::discover_all_fixtures() {
        let mut group = c.benchmark_group(format!("compare/{name}"));

        group.bench_function("bigospice", |b| b.iter(|| bigospice_run(&netlist)));

        if ng_ok {
            let ng = ng.clone();
            group.bench_function("ngspice", |b| b.iter(|| ngspice_run(&ng, &netlist)));
        }
        if xyce_ok {
            let xyce = xyce.clone();
            group.bench_function("xyce", |b| b.iter(|| xyce_run(&xyce, &netlist)));
        }
        if vacask_ok {
            let vacask = vacask.clone();
            group.bench_function("vacask", |b| b.iter(|| vacask_run(&vacask, &netlist)));
        }

        group.finish();
    }

    if !ng_ok && !xyce_ok && !vacask_ok {
        eprintln!(
            "compare: no external simulators found — set BIGOSPICE_HAVE_SIMS=1 \
             and ensure ngspice/Xyce/vacask are on PATH"
        );
    }
}
