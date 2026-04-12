//! Solver benchmarks: Newton-Raphson convergence on linear and nonlinear circuits.

use criterion::Criterion;
use bigospice_parser::SpiceParser;
use bigospice_device::DeviceRegistry;

pub fn bench_solver(c: &mut Criterion) {
    let mut group = c.benchmark_group("solver/newton");

    // Linear: voltage divider from fixture
    group.bench_function("dc_op_resistor_divider", |b| {
        let netlist = crate::common::load_fixture("voltage_divider");
        let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        b.iter(|| bigospice_analysis::run_dc_op(&circuit, &registry).unwrap());
    });

    // Nonlinear: diode clamp — tests Newton-Raphson convergence with junction limiting
    let diode_netlist = "\
* Diode — Newton convergence bench
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
";
    group.bench_function("dc_op_diode_nonlinear", |b| {
        let (circuit, _, _) = SpiceParser::parse(diode_netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        b.iter(|| bigospice_analysis::run_dc_op(&circuit, &registry).unwrap());
    });

    group.finish();
}
