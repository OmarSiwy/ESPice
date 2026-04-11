//! Head-to-head comparison benchmarks: BigOSpice vs ngspice/xyce/VACASK.
//!
//! Measures wall-time for BigOSpice and each available external simulator
//! on the same circuits. Use `BIGOSPICE_HAVE_SIMS=1` to opt-in.
//! Individual simulators can be overridden via NGSPICE_BIN, XYCE_BIN, VACASK_BIN.

use criterion::Criterion;

// ── circuit corpus ────────────────────────────────────────────────────────────

const DIVIDER_DC: &str = "\
* Voltage divider — DC OP
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";

const RC_CHAIN_DC: &str = "\
* Three-resistor chain — DC OP
V1 1 0 DC 10
R1 1 2 1k
R2 2 3 1k
R3 3 0 1k
.OP
.END
";

const RC_TRAN: &str = "\
* RC transient — 1 µs rise
V1 1 0 PULSE(0 5 0 1n 1n 500n 1u)
R1 1 2 1k
C1 2 0 1n
.TRAN 10n 2u
.END
";

const RLC_AC: &str = "\
* RLC bandpass — AC sweep 1 kHz–10 MHz
V1 1 0 AC 1
R1 1 2 100
L1 2 3 1u
C1 3 0 1n
R2 3 0 1k
.AC DEC 20 1k 10MEG
.END
";

const RC_LADDER_100: &str = "\
* RC ladder 100 nodes
V1 1 0 DC 1
R1 1 2 1k
C1 2 0 1n
R2 2 3 1k
C2 3 0 1n
R3 3 4 1k
C3 4 0 1n
R4 4 5 1k
C4 5 0 1n
R5 5 6 1k
C5 6 0 1n
R6 6 7 1k
C6 7 0 1n
R7 7 8 1k
C7 8 0 1n
R8 8 9 1k
C8 9 0 1n
R9 9 10 1k
C9 10 0 1n
R10 10 0 1k
.OP
.END
";

// ── helpers ───────────────────────────────────────────────────────────────────

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

fn bigospice_dc(netlist: &str) {
    use bigospice_device::DeviceRegistry;
    use bigospice_parser::SpiceParser;
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let registry = DeviceRegistry::new_default();
    let _ = bigospice_analysis::run_dc_op(&circuit, &registry);
}

fn bigospice_tran(netlist: &str) {
    use bigospice_analysis::{IntegrationMethod, TransientConfig};
    use bigospice_device::DeviceRegistry;
    use bigospice_parser::SpiceParser;
    let (mut circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let registry = DeviceRegistry::new_default();
    let cfg = TransientConfig {
        tstep: 10e-9,
        tstop: 2e-6,
        method: IntegrationMethod::BackwardEuler,
        uic: false,
        adaptive: false,
        tmax: None,
        checkpoint_interval: 0,
    };
    let _ = bigospice_analysis::run_transient(&mut circuit, &registry, &cfg);
}

fn bigospice_ac(netlist: &str) {
    use bigospice_analysis::{AcConfig, AcSweepType};
    use bigospice_device::DeviceRegistry;
    use bigospice_parser::SpiceParser;
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let registry = DeviceRegistry::new_default();
    let cfg = AcConfig {
        freq_start: 1e3,
        freq_stop: 10e6,
        num_points: 20,
        sweep_type: AcSweepType::Decade,
    };
    let _ = bigospice_analysis::run_ac(&circuit, &registry, &cfg);
}

// ── bench entry ───────────────────────────────────────────────────────────────

pub fn bench_compare(c: &mut Criterion) {
    let have_sims = std::env::var("BIGOSPICE_HAVE_SIMS").is_ok();
    let ng = std::env::var("NGSPICE_BIN").unwrap_or_else(|_| "ngspice".into());
    let xyce = std::env::var("XYCE_BIN").unwrap_or_else(|_| "Xyce".into());
    let vacask = std::env::var("VACASK_BIN").unwrap_or_else(|_| "vacask".into());

    let ng_ok = have_sims
        && std::process::Command::new(&ng)
            .arg("--version")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok();

    let xyce_ok = have_sims
        && std::process::Command::new(&xyce)
            .arg("-v")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok();

    let vacask_ok = have_sims
        && std::process::Command::new(&vacask)
            .arg("--version")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok();

    // ── corpus ────────────────────────────────────────────────────────────────

    let corpus: &[(&str, &str, fn(&str))] = &[
        ("dc/divider",       DIVIDER_DC,    bigospice_dc),
        ("dc/rc_chain",      RC_CHAIN_DC,   bigospice_dc),
        ("dc/rc_ladder_100", RC_LADDER_100, bigospice_dc),
        ("tran/rc",          RC_TRAN,       bigospice_tran),
        ("ac/rlc_bandpass",  RLC_AC,        bigospice_ac),
    ];

    for (name, netlist, bos_fn) in corpus {
        let group_name = format!("compare/{name}");
        let mut group = c.benchmark_group(&group_name);

        group.bench_function("bigospice", |b| b.iter(|| bos_fn(netlist)));

        if ng_ok {
            let ng = ng.clone();
            group.bench_function("ngspice", |b| b.iter(|| ngspice_run(&ng, netlist)));
        }

        if xyce_ok {
            let xyce = xyce.clone();
            group.bench_function("xyce", |b| b.iter(|| xyce_run(&xyce, netlist)));
        }

        if vacask_ok {
            let vacask = vacask.clone();
            group.bench_function("vacask", |b| b.iter(|| vacask_run(&vacask, netlist)));
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
