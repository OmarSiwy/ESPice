//! End-to-end benchmarks: parse + simulate complete circuits.
//!
//! File-based fixtures cover real-world netlists; programmatic ladders
//! provide scaling data for the linear solver.
//!
//! Quick and medium tier fixtures always run. Full tier (large scaling
//! circuits) only runs when `BIGOSPICE_FULL_BENCH=1` is set.

use criterion::{BenchmarkId, Criterion};
use bigospice_analysis::run_dc_op;
use bigospice_device::DeviceRegistry;
use bigospice_parser::{AnalysisKind, SpiceParser};

use crate::common::{discover_fixtures_tiered, BenchTier};

pub fn bench_end_to_end(c: &mut Criterion) {
    let mut group = c.benchmark_group("end_to_end");

    // ── quick tier: small circuits, always run ──────────────────────────────────
    for (name, content) in discover_fixtures_tiered(BenchTier::Quick) {
        let Ok((circuit, analyses, _)) = SpiceParser::parse(&content) else { continue };
        let registry = DeviceRegistry::new_default();

        let has_op = analyses.iter().any(|s| matches!(s.kind, AnalysisKind::DcOp));
        if has_op {
            group.bench_function(format!("fixture/{name}"), |b| {
                b.iter(|| {
                    let (c2, _, _) = SpiceParser::parse(&content).unwrap();
                    run_dc_op(&c2, &registry).unwrap()
                })
            });
        }

        let _ = (circuit, analyses);
    }

    // ── medium tier: moderate circuits, always run with longer measurement ──────
    for (name, content) in discover_fixtures_tiered(BenchTier::Medium) {
        let Ok((circuit, analyses, _)) = SpiceParser::parse(&content) else { continue };
        let registry = DeviceRegistry::new_default();

        let has_op = analyses.iter().any(|s| matches!(s.kind, AnalysisKind::DcOp));
        if has_op {
            group.bench_function(format!("fixture/{name}"), |b| {
                b.iter(|| {
                    let (c2, _, _) = SpiceParser::parse(&content).unwrap();
                    run_dc_op(&c2, &registry).unwrap()
                })
            });
        }

        let _ = (circuit, analyses);
    }

    // ── full tier: large scaling circuits, only when BIGOSPICE_FULL_BENCH=1 ────
    if std::env::var("BIGOSPICE_FULL_BENCH").as_deref() == Ok("1") {
        for (name, content) in discover_fixtures_tiered(BenchTier::Full) {
            let Ok((circuit, analyses, _)) = SpiceParser::parse(&content) else { continue };
            let registry = DeviceRegistry::new_default();

            let has_op = analyses.iter().any(|s| matches!(s.kind, AnalysisKind::DcOp));
            if has_op {
                group.bench_function(format!("fixture/{name}"), |b| {
                    b.iter(|| {
                        let (c2, _, _) = SpiceParser::parse(&content).unwrap();
                        run_dc_op(&c2, &registry).unwrap()
                    })
                });
            }

            let _ = (circuit, analyses);
        }
    }

    // ── programmatic ladders: scaling test for the sparse solver ──────────────
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
                let registry = DeviceRegistry::new_default();
                b.iter(|| {
                    let (circuit, _, _) = SpiceParser::parse(nl).unwrap();
                    run_dc_op(&circuit, &registry).unwrap()
                });
            },
        );
    }

    group.finish();
}
