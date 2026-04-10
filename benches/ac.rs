use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion};
use pisim_analysis::{run_ac, AcConfig, AcSweepType};
use pisim_device::DeviceRegistry;
use pisim_test_harness::parse_netlist_str;

// ---------------------------------------------------------------------------
// Netlists (parsed via test harness so AC stimuli are registered correctly)
// ---------------------------------------------------------------------------

const RC_LOWPASS: &str = "\
* RC lowpass filter
V1 in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 1n
.AC DEC 10 1 1G
.END
";

const RLC_BANDPASS: &str = "\
* RLC bandpass filter
V1 in 0 DC 0 AC 1
R1 in mid 100
L1 mid out 1u
C1 out 0 1n
.AC DEC 10 1k 100MEG
.END
";

const BJT_CE_AC: &str = "\
* BJT common-emitter amplifier AC
VCC vcc 0 DC 12
VS base 0 DC 0.8 AC 1
RC vcc col 1k
RE emi 0 100
Q1 col base emi NPNMOD
.MODEL NPNMOD NPN (IS=1e-16 BF=100)
.AC DEC 10 1 1G
.END
";

// ---------------------------------------------------------------------------
// Benchmark group
// ---------------------------------------------------------------------------

fn bench_ac(c: &mut Criterion) {
    let mut group = c.benchmark_group("ac");
    let reg = DeviceRegistry::new_default();

    let (rc_ckt, _) = parse_netlist_str(RC_LOWPASS).expect("parse failed");

    // 1-3. RC lowpass at 10 / 100 / 1000 freq points (decade sweep)
    for &n_pts in &[10usize, 100, 1000] {
        let cfg = AcConfig::new(1.0, 1e9, n_pts, AcSweepType::Decade);
        group.bench_with_input(
            BenchmarkId::new("rc_lowpass_points", n_pts),
            &n_pts,
            |b, _| b.iter(|| run_ac(&rc_ckt, &reg, &cfg).expect("ac failed")),
        );
    }

    // 4. RLC bandpass 100 points
    {
        let (rlc_ckt, _) = parse_netlist_str(RLC_BANDPASS).expect("parse failed");
        let cfg = AcConfig::new(1e3, 1e8, 100, AcSweepType::Decade);
        group.bench_function("rlc_bandpass_100", |b| {
            b.iter(|| run_ac(&rlc_ckt, &reg, &cfg).expect("ac failed"));
        });
    }

    // 5. BJT CE amp 100 points
    {
        let (bjt_ckt, _) = parse_netlist_str(BJT_CE_AC).expect("parse failed");
        let cfg = AcConfig::new(1.0, 1e9, 100, AcSweepType::Decade);
        group.bench_function("bjt_ce_ac_100", |b| {
            b.iter(|| run_ac(&bjt_ckt, &reg, &cfg).expect("ac failed"));
        });
    }

    group.finish();
}

criterion_group!(benches, bench_ac);
criterion_main!(benches);
