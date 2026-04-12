//! Cache and incremental simulation benchmarks.

use criterion::Criterion;
use bigospice_parser::SpiceParser;
use bigospice_device::DeviceRegistry;

pub fn bench_cache(c: &mut Criterion) {
    let mut group = c.benchmark_group("cache");

    let netlist = crate::common::load_fixture("voltage_divider");

    // Warm-start: run twice, second should reuse cached solution
    group.bench_function("dc_op_warm_start", |b| {
        let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        // First run populates cache
        let _ = bigospice_analysis::run_dc_op(&circuit, &registry).unwrap();
        b.iter(|| bigospice_analysis::run_dc_op(&circuit, &registry).unwrap());
    });

    // Incremental: alternate between two resistance values
    group.bench_function("dc_op_incremental_param_change", |b| {
        let (mut circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        let mut toggle = false;
        b.iter(|| {
            let r = if toggle { 1e3 } else { 1.1e3 };
            circuit.set_device_param("r1", "resistance", r);
            toggle = !toggle;
            bigospice_analysis::run_dc_op(&circuit, &registry).unwrap()
        });
    });

    group.finish();
}
