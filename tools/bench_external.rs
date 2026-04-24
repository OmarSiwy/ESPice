//! Speed benchmarks: BigOSpice vs ngspice / Xyce / VACASK.
//!
//! Measures wall-clock time to simulate every `.sp` file in each fixture
//! category. No correctness checking — pure throughput only.
//!
//! Run (always compiles in release):
//!     cargo bench --bench bench_external
//!
//! Run one category:
//!     cargo bench --bench bench_external -- basic
//!
//! Run one simulator across all categories:
//!     cargo bench --bench bench_external -- ngspice

#[path = "utils.rs"]
mod utils;

#[path = "sim.rs"]
mod sim;

use sim::{NgspiceRunner, VacaskRunner, XyceRunner};

use incspice_analysis::{
    AcConfig, AcSweepType, DcSweepConfig, TransientConfig, run_ac, run_dc_op, run_dc_sweep,
    run_transient,
};
use incspice_solver::device::DeviceRegistry;
use incspice_parser::{AnalysisKind, SpiceParser};

use criterion::{BenchmarkId, Criterion, Throughput, black_box, criterion_group, criterion_main};
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

// ── Paths ────────────────────────────────────────────────────────────────────

use utils::{glob_categories, sp_files};

// ── Simulator availability ───────────────────────────────────────────────────

struct Sims {
    ngspice: Option<NgspiceRunner>,
    xyce: Option<XyceRunner>,
    vacask: Option<VacaskRunner>,
}

impl Sims {
    fn detect() -> Self {
        let ng = NgspiceRunner::default();
        let xy = XyceRunner::default();
        let va = VacaskRunner::default();
        Self {
            ngspice: ng.is_available().then_some(ng),
            xyce: xy.is_available().then_some(xy),
            vacask: va.is_available().then_some(va),
        }
    }
}

// ── BigOSpice runner (no error checking) ────────────────────────────────────

fn run_incspice(sp: &Path) {
    let Ok((circuit, analyses, _)) = SpiceParser::parse_file(sp) else {
        return;
    };
    let registry = DeviceRegistry::new_default();

    for stmt in &analyses {
        let p = |key: &str| stmt.params.iter().find(|(k, _)| k == key).map(|(_, v)| *v);

        match &stmt.kind {
            AnalysisKind::DcOp => {
                let _ = run_dc_op(black_box(&circuit), &registry);
            }

            AnalysisKind::DcSweep => {
                let src = stmt
                    .params
                    .iter()
                    .find(|(k, _)| k.starts_with("__dc_src__"))
                    .map(|(k, _)| k["__dc_src__".len()..].to_string())
                    .unwrap_or_else(|| "v1".to_string());
                let cfg = DcSweepConfig::new(
                    &src,
                    p("start").unwrap_or(0.0),
                    p("stop").unwrap_or(1.0),
                    p("step").unwrap_or(0.1),
                );
                let _ = run_dc_sweep(black_box(&circuit), &registry, &cfg);
            }

            AnalysisKind::Tran => {
                let cfg = TransientConfig::with_adaptive(
                    p("tstep").unwrap_or(1e-9),
                    p("tstop").unwrap_or(1e-6),
                    incspice_analysis::IntegrationMethod::Trapezoidal,
                );
                let mut c = circuit.clone();
                let _ = run_transient(black_box(&mut c), &registry, &cfg);
            }

            AnalysisKind::Ac => {
                let cfg = AcConfig {
                    sweep: AcSweepType::Decade,
                    points_per: p("nd").or(p("np")).or(p("nl")).unwrap_or(10.0) as usize,
                    fstart: p("fstart").unwrap_or(1.0),
                    fstop: p("fstop").unwrap_or(1e9),
                };
                let _ = run_ac(black_box(&circuit), &registry, &cfg);
            }

            _ => {}
        }
    }
}

// ── External simulator runners ───────────────────────────────────────────────

fn run_ngspice(cfg: &NgspiceRunner, sp: &Path) {
    let _ = Command::new(&cfg.binary)
        .args(["-b", "-o", "/dev/null"])
        .arg(sp)
        .output();
}

fn run_xyce(cfg: &XyceRunner, sp: &Path) {
    let _ = Command::new(&cfg.binary)
        .arg(sp)
        .output();
}

fn run_vacask(cfg: &VacaskRunner, sp: &Path) {
    let _ = Command::new(&cfg.binary)
        .arg(sp)
        .output();
}

// ── Per-category benchmark ───────────────────────────────────────────────────

fn bench_category(c: &mut Criterion, sims: &Sims, category: &str) {
    let files = sp_files(category);
    if files.is_empty() {
        return;
    }

    let mut group = c.benchmark_group(category);
    group.sample_size(10);
    group.measurement_time(Duration::from_secs(60));
    group.warm_up_time(Duration::from_secs(3));
    group.throughput(Throughput::Elements(files.len() as u64));

    // BigOSpice
    group.bench_function("incspice", |b| {
        b.iter(|| {
            for sp in &files {
                run_incspice(black_box(sp));
            }
        });
    });

    // ngspice
    if let Some(cfg) = &sims.ngspice {
        group.bench_function("ngspice", |b| {
            b.iter(|| {
                for sp in &files {
                    run_ngspice(cfg, black_box(sp));
                }
            });
        });
    }

    // Xyce
    if let Some(cfg) = &sims.xyce {
        group.bench_function("xyce", |b| {
            b.iter(|| {
                for sp in &files {
                    run_xyce(cfg, black_box(sp));
                }
            });
        });
    }

    // VACASK
    if let Some(cfg) = &sims.vacask {
        group.bench_function("vacask", |b| {
            b.iter(|| {
                for sp in &files {
                    run_vacask(cfg, black_box(sp));
                }
            });
        });
    }

    group.finish();
}

// ── Per-file benchmark (single circuit, for profiling) ───────────────────────

fn bench_per_file(c: &mut Criterion, sims: &Sims, category: &str) {
    let files = sp_files(category);
    if files.is_empty() {
        return;
    }

    let mut group = c.benchmark_group(format!("{category}/per_file"));
    group.sample_size(10);
    group.measurement_time(Duration::from_secs(30));

    for sp in &files {
        let stem = sp.file_stem().unwrap().to_string_lossy().into_owned();

        group.bench_with_input(
            BenchmarkId::new("incspice", &stem),
            sp,
            |b, sp| b.iter(|| run_incspice(black_box(sp))),
        );

        if let Some(cfg) = &sims.ngspice {
            group.bench_with_input(
                BenchmarkId::new("ngspice", &stem),
                sp,
                |b, sp| b.iter(|| run_ngspice(cfg, black_box(sp))),
            );
        }

        if let Some(cfg) = &sims.xyce {
            group.bench_with_input(
                BenchmarkId::new("xyce", &stem),
                sp,
                |b, sp| b.iter(|| run_xyce(cfg, black_box(sp))),
            );
        }

        if let Some(cfg) = &sims.vacask {
            group.bench_with_input(
                BenchmarkId::new("vacask", &stem),
                sp,
                |b, sp| b.iter(|| run_vacask(cfg, black_box(sp))),
            );
        }
    }

    group.finish();
}

// ── Criterion entry points ───────────────────────────────────────────────────

fn all_category_benches(c: &mut Criterion) {
    let sims = Sims::detect();
    for cat in glob_categories() {
        bench_category(c, &sims, &cat);
    }
}

fn per_file_benches(c: &mut Criterion) {
    let sims = Sims::detect();
    // Per-file only on small categories to avoid multi-hour runs.
    // Add/remove dirs in tools/fixtures/ — picked up automatically.
    let small = ["basic", "quick", "analog"];
    for cat in glob_categories().into_iter().filter(|c| small.contains(&c.as_str())) {
        bench_per_file(c, &sims, &cat);
    }
}

criterion_group!(category_benches, all_category_benches);
criterion_group!(file_benches, per_file_benches);
criterion_main!(category_benches, file_benches);
