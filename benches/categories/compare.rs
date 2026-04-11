//! Head-to-head comparison benchmarks: BigOSpice vs ngspice wall time.

use criterion::Criterion;
use std::path::Path;

pub fn bench_compare(c: &mut Criterion) {
    // Only run if ngspice is available
    let ngspice_bin = std::env::var("NGSPICE_BIN").unwrap_or_else(|_| "ngspice".into());
    let ng_available = std::process::Command::new(&ngspice_bin)
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok();

    if !ng_available {
        eprintln!("bench_compare: ngspice not available — skipping head-to-head benchmarks");
        return;
    }

    let mut group = c.benchmark_group("compare/ngspice");

    let netlist_str = "\
* Voltage divider comparison
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";

    // BigOSpice side
    group.bench_function("bigospice_dc_op_divider", |b| {
        use bigospice_parser::SpiceParser;
        use bigospice_device::DeviceRegistry;
        let (circuit, _, _) = SpiceParser::parse(netlist_str).unwrap();
        let registry = DeviceRegistry::new_default();
        b.iter(|| bigospice_analysis::run_dc_op(&circuit, &registry).unwrap());
    });

    // ngspice side — write netlist to temp file, invoke subprocess each iteration
    group.bench_function("ngspice_dc_op_divider", |b| {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("divider.sp");
        std::fs::write(&path, netlist_str).unwrap();
        let raw_out = tmp.path().join("output.raw");
        let wrapper = tmp.path().join("wrapper.cir");
        std::fs::write(
            &wrapper,
            format!(
                ".include {}\n.control\nset filetype=ascii\nrun\nwrite {} all\n.endc\n",
                path.display(), raw_out.display(),
            ),
        ).unwrap();
        b.iter(|| {
            std::process::Command::new(&ngspice_bin)
                .arg("-b")
                .arg(&wrapper)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .unwrap()
        });
    });

    group.finish();

    // ── VACASK comparison ─────────────────────────────────────────────────────
    let vacask_bin = std::env::var("VACASK_BIN").unwrap_or_else(|_| "vacask".into());
    let va_available = std::process::Command::new(&vacask_bin)
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok();

    if va_available {
        let mut group = c.benchmark_group("compare/vacask");
        group.bench_function("bigospice_dc_op_divider", |b| {
            use bigospice_parser::SpiceParser;
            use bigospice_device::DeviceRegistry;
            let (circuit, _, _) = SpiceParser::parse(netlist_str).unwrap();
            let registry = DeviceRegistry::new_default();
            b.iter(|| bigospice_analysis::run_dc_op(&circuit, &registry).unwrap());
        });
        group.bench_function("vacask_dc_op_divider", |b| {
            let tmp = tempfile::tempdir().unwrap();
            let path = tmp.path().join("divider.sp");
            std::fs::write(&path, netlist_str).unwrap();
            b.iter(|| {
                std::process::Command::new(&vacask_bin)
                    .arg(&path)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status()
                    .unwrap()
            });
        });
        group.finish();
    } else {
        eprintln!("bench_compare: vacask not available — skipping vacask comparison");
    }

    // ── Xyce comparison ───────────────────────────────────────────────────────
    let xyce_bin = std::env::var("XYCE_BIN").unwrap_or_else(|_| "Xyce".into());
    let xyce_available = std::process::Command::new(&xyce_bin)
        .arg("-v")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok();

    if xyce_available {
        let mut group = c.benchmark_group("compare/xyce");
        group.bench_function("bigospice_dc_op_divider", |b| {
            use bigospice_parser::SpiceParser;
            use bigospice_device::DeviceRegistry;
            let (circuit, _, _) = SpiceParser::parse(netlist_str).unwrap();
            let registry = DeviceRegistry::new_default();
            b.iter(|| bigospice_analysis::run_dc_op(&circuit, &registry).unwrap());
        });
        group.bench_function("xyce_dc_op_divider", |b| {
            let tmp = tempfile::tempdir().unwrap();
            let path = tmp.path().join("divider.sp");
            std::fs::write(&path, netlist_str).unwrap();
            b.iter(|| {
                std::process::Command::new(&xyce_bin)
                    .arg(&path)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status()
                    .unwrap()
            });
        });
        group.finish();
    } else {
        eprintln!("bench_compare: Xyce not available — skipping Xyce comparison");
    }
}
