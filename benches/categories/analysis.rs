//! Analysis benchmarks: DC sweep, transient, AC.

use criterion::Criterion;
use bigospice_parser::SpiceParser;
use bigospice_device::DeviceRegistry;
use bigospice_analysis::{AcConfig, AcSweepType, DcSweepConfig, TransientConfig};

pub fn bench_analysis(c: &mut Criterion) {
    let mut group = c.benchmark_group("analysis");

    // DC OP
    let dc_netlist = "\
* DC OP bench
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    group.bench_function("dc_op_divider", |b| {
        let (circuit, _, _) = SpiceParser::parse(dc_netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        b.iter(|| bigospice_analysis::run_dc_op(&circuit, &registry).unwrap());
    });

    // DC Sweep
    group.bench_function("dc_sweep_10pts", |b| {
        let (circuit, _, _) = SpiceParser::parse(dc_netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        let cfg = DcSweepConfig::new("V1", 0.0, 5.0, 0.5);
        b.iter(|| bigospice_analysis::run_dc_sweep(&circuit, &registry, &cfg).unwrap());
    });

    // Transient
    let tran_netlist = "\
* Transient bench
V1 1 0 DC 5
R1 1 0 1k
.TRAN 1n 100n
.END
";
    group.bench_function("transient_resistive_100ns", |b| {
        let (mut circuit, _, _) = SpiceParser::parse(tran_netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        let cfg = TransientConfig::new(1e-9, 100e-9);
        b.iter(|| bigospice_analysis::run_transient(&mut circuit, &registry, &cfg).unwrap());
    });

    // AC
    let ac_netlist = "\
* AC bench
V1 1 0 DC 1 AC 1
R1 1 2 1k
R2 2 0 1k
.AC DEC 10 1 1G
.END
";
    group.bench_function("ac_decade_10pts_1_to_1G", |b| {
        let (circuit, _, _) = SpiceParser::parse(ac_netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        let cfg = AcConfig::new(1.0, 1e9, 10, AcSweepType::Decade);
        b.iter(|| bigospice_analysis::run_ac(&circuit, &registry, &cfg).unwrap());
    });

    group.finish();
}
