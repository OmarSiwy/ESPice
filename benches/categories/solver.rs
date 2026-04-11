//! Solver benchmarks: Newton-Raphson, convergence helpers.

use criterion::Criterion;
use bigospice_parser::SpiceParser;
use bigospice_device::DeviceRegistry;

pub fn bench_solver(c: &mut Criterion) {
    let mut group = c.benchmark_group("solver/newton");

    let netlist = "\
* Voltage divider for Newton bench
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";

    group.bench_function("dc_op_resistor_divider", |b| {
        let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        b.iter(|| {
            bigospice_analysis::run_dc_op(&circuit, &registry).unwrap()
        });
    });

    let nonlinear = "\
* Diode — Newton convergence bench
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
";
    group.bench_function("dc_op_diode_nonlinear", |b| {
        let (circuit, _, _) = SpiceParser::parse(nonlinear).unwrap();
        let registry = DeviceRegistry::new_default();
        b.iter(|| {
            bigospice_analysis::run_dc_op(&circuit, &registry).unwrap()
        });
    });

    group.finish();
}
