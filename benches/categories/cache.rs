//! Cache and incremental simulation benchmarks.

use criterion::Criterion;
use bigospice_parser::SpiceParser;
use bigospice_device::DeviceRegistry;

pub fn bench_cache(c: &mut Criterion) {
    let mut group = c.benchmark_group("cache");

    let netlist = "\
* Cache bench
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";

    // Warm-start: run twice, second should reuse cached solution
    group.bench_function("dc_op_warm_start", |b| {
        let (mut circuit, _, _) = SpiceParser::parse(netlist).unwrap();
        let registry = DeviceRegistry::new_default();
        // First run to populate cache
        let _first = bigospice_analysis::run_dc_op(&circuit, &registry).unwrap();
        b.iter(|| {
            bigospice_analysis::run_dc_op(&circuit, &registry).unwrap()
        });
    });

    // Incremental: change a parameter value between runs
    group.bench_function("dc_op_incremental_param_change", |b| {
        let (mut circuit, _, _) = SpiceParser::parse(netlist).unwrap();
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
