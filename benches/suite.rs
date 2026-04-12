//! BigOSpice benchmark suite entry point.
//!
//! All Criterion benchmarks are organized into category modules and wired
//! here. Run with:
//!   cargo bench --bench suite
//!   cargo bench --bench suite -- linalg   # run only linalg category

#[path = "common/mod.rs"]
mod common;

#[path = "categories/linalg.rs"]
mod linalg;

#[path = "categories/solver.rs"]
mod solver;

#[path = "categories/device.rs"]
mod device;

#[path = "categories/analysis.rs"]
mod analysis;

#[path = "categories/parser.rs"]
mod parser;

#[path = "categories/cache.rs"]
mod cache;

#[path = "categories/compare.rs"]
mod compare;

#[path = "categories/accuracy.rs"]
mod accuracy;

#[path = "categories/end_to_end.rs"]
mod end_to_end;

use criterion::{criterion_group, criterion_main};

criterion_group!(
    benches,
    linalg::bench_linalg,
    solver::bench_solver,
    device::bench_device,
    analysis::bench_analysis,
    parser::bench_parser,
    cache::bench_cache,
    compare::bench_compare,
    accuracy::bench_accuracy,
    end_to_end::bench_end_to_end,
);
criterion_main!(benches);
