use criterion::{criterion_group, criterion_main, Criterion};
use pisim_core::*;
use pisim_device::DeviceRegistry;
use pisim_solver::NewtonRaphson;

/// Build a voltage-divider circuit: V1 (5V) -> R1 (1k) -> node 2 -> R2 (1k) -> GND.
fn voltage_divider() -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("1");
    let n2 = ckt.add_node("2");

    let v1 = DeviceInstance::new(
        DeviceId::new(0),
        "V1",
        DeviceKind::VoltageSource,
        &[(0, n1), (1, NodeId::GROUND)],
    )
    .with_param("dc", 5.0);

    let r1 = DeviceInstance::new(
        DeviceId::new(0),
        "R1",
        DeviceKind::Resistor,
        &[(0, n1), (1, n2)],
    )
    .with_param("resistance", 1000.0);

    let r2 = DeviceInstance::new(
        DeviceId::new(0),
        "R2",
        DeviceKind::Resistor,
        &[(0, n2), (1, NodeId::GROUND)],
    )
    .with_param("resistance", 1000.0);

    ckt.add_device(v1);
    ckt.add_device(r1);
    ckt.add_device(r2);
    ckt.build_topology();
    ckt
}

/// Build a simple diode circuit: V1 (5V) -> R1 (1k) -> D1 -> GND.
fn diode_circuit() -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("1");
    let n2 = ckt.add_node("2");

    let v1 = DeviceInstance::new(
        DeviceId::new(0),
        "V1",
        DeviceKind::VoltageSource,
        &[(0, n1), (1, NodeId::GROUND)],
    )
    .with_param("dc", 5.0);

    let r1 = DeviceInstance::new(
        DeviceId::new(0),
        "R1",
        DeviceKind::Resistor,
        &[(0, n1), (1, n2)],
    )
    .with_param("resistance", 1000.0);

    let d1 = DeviceInstance::new(
        DeviceId::new(0),
        "D1",
        DeviceKind::Diode,
        &[(0, n2), (1, NodeId::GROUND)],
    )
    .with_param("is", 1e-14)
    .with_param("n", 1.0);

    ckt.add_device(v1);
    ckt.add_device(r1);
    ckt.add_device(d1);
    ckt.build_topology();
    ckt
}

fn bench_newton_raphson(c: &mut Criterion) {
    let mut group = c.benchmark_group("newton_raphson");
    let reg = DeviceRegistry::new_default();
    let nr = NewtonRaphson::with_defaults();

    let divider = voltage_divider();
    group.bench_function("voltage_divider", |b| {
        b.iter(|| nr.solve(&divider, &reg, None).unwrap());
    });

    let diode = diode_circuit();
    group.bench_function("diode_circuit", |b| {
        b.iter(|| nr.solve(&diode, &reg, None).unwrap());
    });

    group.finish();
}

criterion_group!(benches, bench_newton_raphson);
criterion_main!(benches);
