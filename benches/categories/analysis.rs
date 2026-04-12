//! Analysis benchmarks: DC OP, transient, and AC across fixture files.

use criterion::Criterion;
use bigospice_analysis::{AcConfig, AcSweepType, TransientConfig};
use bigospice_device::DeviceRegistry;
use bigospice_parser::{AnalysisKind, SpiceParser};

pub fn bench_analysis(c: &mut Criterion) {
    let mut group = c.benchmark_group("analysis");

    for (name, content) in crate::common::discover_all_fixtures() {
        let Ok((circuit, analyses, _)) = SpiceParser::parse(&content) else { continue };
        let registry = DeviceRegistry::new_default();

        for stmt in &analyses {
            let p = |key: &str| stmt.params.iter().find(|(k, _)| k == key).map(|(_, v)| *v);

            match &stmt.kind {
                AnalysisKind::DcOp => {
                    group.bench_function(format!("{name}/dc_op"), |b| {
                        b.iter(|| bigospice_analysis::run_dc_op(&circuit, &registry).unwrap())
                    });
                }
                AnalysisKind::Tran => {
                    let cfg = TransientConfig::new(
                        p("tstep").unwrap_or(1e-9),
                        p("tstop").unwrap_or(1e-6),
                    );
                    group.bench_function(format!("{name}/tran"), |b| {
                        b.iter(|| {
                            let mut c = circuit.clone();
                            bigospice_analysis::run_transient(&mut c, &registry, &cfg).unwrap()
                        })
                    });
                }
                AnalysisKind::Ac => {
                    let sweep = match p("sweep_type").unwrap_or(1.0) as u8 {
                        0 => AcSweepType::Linear,
                        2 => AcSweepType::Octave,
                        _ => AcSweepType::Decade,
                    };
                    let cfg = AcConfig::new(
                        p("fstart").unwrap_or(1.0),
                        p("fstop").unwrap_or(1e9),
                        p("npoints").unwrap_or(10.0) as usize,
                        sweep,
                    );
                    group.bench_function(format!("{name}/ac"), |b| {
                        b.iter(|| bigospice_analysis::run_ac(&circuit, &registry, &cfg).unwrap())
                    });
                }
                _ => {}
            }
        }
    }

    group.finish();
}
