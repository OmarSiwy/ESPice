//! Parser benchmarks: tokenizer and netlist parse throughput.
//!
//! File-based fixtures measure real-world parse performance; programmatic
//! ladders give a scaling curve across netlist sizes.

use criterion::{BenchmarkId, Criterion};
use bigospice_parser::SpiceParser;

pub fn bench_parser(c: &mut Criterion) {
    let mut group = c.benchmark_group("parser");

    // ── fixture files ──────────────────────────────────────────────────────────
    for (name, content) in crate::common::discover_fixtures() {
        group.bench_with_input(
            BenchmarkId::new("fixture", &name),
            &content,
            |b, s| b.iter(|| SpiceParser::parse(s).unwrap()),
        );
    }

    // ── programmatic scaling: N-node resistor ladders ──────────────────────────
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
