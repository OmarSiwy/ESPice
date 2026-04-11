//! End-to-end benchmarks: parse + simulate complete circuits.

use criterion::{BenchmarkId, Criterion};

pub fn bench_end_to_end(c: &mut Criterion) {
    let mut group = c.benchmark_group("end_to_end");

    // Small circuit: 2-node divider (parse + DC OP)
    group.bench_function("small_divider_parse_and_op", |b| {
        use bigospice_parser::SpiceParser;
        use bigospice_device::DeviceRegistry;
        let netlist = "* Divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n";
        let registry = DeviceRegistry::new_default();
        b.iter(|| {
            let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
            bigospice_analysis::run_dc_op(&circuit, &registry).unwrap()
        });
    });

    // Ladder circuits: varying size
    for &n in &[10usize, 100] {
        let mut netlist = format!("* {n}-resistor ladder\nV1 1 0 DC 1\n");
        for i in 1..=n {
            netlist.push_str(&format!("R{i} {i} {} 1k\n", i + 1));
        }
        netlist.push_str(&format!("R_end {} 0 1k\n.OP\n.END\n", n + 1));

        group.bench_with_input(
            BenchmarkId::new("resistor_ladder_dc_op", n),
            &netlist,
            |b, nl| {
                use bigospice_parser::SpiceParser;
                use bigospice_device::DeviceRegistry;
                let registry = DeviceRegistry::new_default();
                b.iter(|| {
                    let (circuit, _, _) = SpiceParser::parse(nl).unwrap();
                    bigospice_analysis::run_dc_op(&circuit, &registry).unwrap()
                });
            },
        );
    }

    group.finish();
}
