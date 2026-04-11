//! Parser benchmarks: tokenizer, netlist parse throughput.

use criterion::{BenchmarkId, Criterion};
use bigospice_parser::SpiceParser;

pub fn bench_parser(c: &mut Criterion) {
    let mut group = c.benchmark_group("parser");

    let simple = "\
* Simple divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    group.bench_function("simple_divider", |b| {
        b.iter(|| SpiceParser::parse(simple).unwrap());
    });

    // Scale test: ladder with N resistors
    for &n in &[10usize, 100, 500] {
        let mut netlist = format!("* {n}-node ladder\nV1 1 0 DC 1\n");
        for i in 1..=n {
            netlist.push_str(&format!("R{i} {i} {} 1k\n", i + 1));
        }
        netlist.push_str(&format!("R{} {} 0 1k\n.OP\n.END\n", n + 1, n + 1));

        group.bench_with_input(BenchmarkId::new("resistor_ladder", n), &netlist, |b, nl| {
            b.iter(|| SpiceParser::parse(nl).unwrap());
        });
    }

    group.finish();
}
