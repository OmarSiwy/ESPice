//! Accuracy comparison benchmarks: error vs ngspice reference.
//!
//! These benchmarks measure accuracy (not wall time) and are informational.

use criterion::Criterion;

pub fn bench_accuracy(c: &mut Criterion) {
    let mut group = c.benchmark_group("accuracy");

    // Measure how far BigOSpice V(2) is from the analytic answer for a divider
    group.bench_function("dc_op_divider_accuracy", |b| {
        use bigospice_parser::SpiceParser;
        use bigospice_device::DeviceRegistry;
        let netlist = "* Divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n";
        let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        b.iter(|| {
            let result = bigospice_analysis::run_dc_op(&circuit, &registry).unwrap();
            let v2 = result.result.node_voltages.iter()
                .find(|(n, _)| n == "2")
                .map(|(_, v)| *v)
                .unwrap_or(0.0);
            // Return the absolute error from analytic answer (2.5V)
            (v2 - 2.5_f64).abs()
        });
    });

    group.finish();
}
