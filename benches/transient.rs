use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion};
use pisim_analysis::{run_transient, TransientConfig};
use pisim_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
use pisim_device::DeviceRegistry;

// ---------------------------------------------------------------------------
// Circuit builders
// ---------------------------------------------------------------------------

fn build_rc_step() -> Circuit {
    let mut ckt = Circuit::new();
    let n_in = ckt.add_node("in");
    let n_out = ckt.add_node("out");

    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n_in), (1, NodeId::GROUND)])
            .with_param("dc", 5.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(1), "R1", DeviceKind::Resistor,
            &[(0, n_in), (1, n_out)])
            .with_param("resistance", 1000.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(2), "C1", DeviceKind::Capacitor,
            &[(0, n_out), (1, NodeId::GROUND)])
            .with_param("capacitance", 1e-9),
    );
    ckt.build_topology();
    ckt
}

fn build_rlc_ring() -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("n1");
    let n2 = ckt.add_node("n2");
    let n3 = ckt.add_node("n3");

    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)])
            .with_param("dc", 1.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(1), "R1", DeviceKind::Resistor,
            &[(0, n1), (1, n2)])
            .with_param("resistance", 50.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(2), "L1", DeviceKind::Inductor,
            &[(0, n2), (1, n3)])
            .with_param("inductance", 1e-6),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(3), "C1", DeviceKind::Capacitor,
            &[(0, n3), (1, NodeId::GROUND)])
            .with_param("capacitance", 1e-9),
    );
    ckt.build_topology();
    ckt
}

fn build_bjt_switch() -> Circuit {
    let mut ckt = Circuit::new();
    let n_vcc = ckt.add_node("vcc");
    let n_base = ckt.add_node("base");
    let n_col = ckt.add_node("col");

    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "VCC", DeviceKind::VoltageSource,
            &[(0, n_vcc), (1, NodeId::GROUND)])
            .with_param("dc", 5.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(1), "VB", DeviceKind::VoltageSource,
            &[(0, n_base), (1, NodeId::GROUND)])
            .with_param("dc", 0.9),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(2), "RC", DeviceKind::Resistor,
            &[(0, n_vcc), (1, n_col)])
            .with_param("resistance", 1000.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(3), "Q1", DeviceKind::BjtNpn,
            &[(0, n_col), (1, n_base), (2, NodeId::GROUND)])
            .with_param("is", 1e-16)
            .with_param("bf", 100.0),
    );
    ckt.build_topology();
    ckt
}

// ---------------------------------------------------------------------------
// Benchmark group
// ---------------------------------------------------------------------------

fn bench_transient(c: &mut Criterion) {
    let mut group = c.benchmark_group("transient");
    let reg = DeviceRegistry::new_default();

    // RC step response: 100 and 1000 timesteps
    // tstep chosen so total steps = N: tstep = tstop / N
    for &n_steps in &[100usize, 1000] {
        let tstop = 10e-9_f64;
        let tstep = tstop / n_steps as f64;
        let mut ckt = build_rc_step();
        let cfg = TransientConfig::new(tstep, tstop);
        group.bench_with_input(
            BenchmarkId::new("rc_step_steps", n_steps),
            &n_steps,
            |b, _| {
                b.iter(|| run_transient(&mut ckt.clone(), &reg, &cfg).expect("transient failed"))
            },
        );
    }

    // RLC ring oscillator — 100 steps
    {
        let tstop = 1e-6_f64;
        let tstep = tstop / 100.0;
        let mut ckt = build_rlc_ring();
        let cfg = TransientConfig::new(tstep, tstop);
        group.bench_function("rlc_ring_100", |b| {
            b.iter(|| run_transient(&mut ckt.clone(), &reg, &cfg).expect("transient failed"))
        });
    }

    // BJT switch — 100 steps
    {
        let tstop = 1e-7_f64;
        let tstep = tstop / 100.0;
        let mut ckt = build_bjt_switch();
        let cfg = TransientConfig::new(tstep, tstop);
        group.bench_function("bjt_switch_100steps", |b| {
            b.iter(|| run_transient(&mut ckt.clone(), &reg, &cfg).expect("transient failed"))
        });
    }

    group.finish();
}

criterion_group!(benches, bench_transient);
criterion_main!(benches);
