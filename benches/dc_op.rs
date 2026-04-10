use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion};
use pisim_analysis::run_dc_op;
use pisim_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
use pisim_device::DeviceRegistry;

// ---------------------------------------------------------------------------
// Circuit builders
// ---------------------------------------------------------------------------

fn build_resistor_divider() -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("1");
    let n2 = ckt.add_node("2");

    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)])
            .with_param("dc", 1.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(1), "R1", DeviceKind::Resistor,
            &[(0, n1), (1, n2)])
            .with_param("resistance", 1000.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(2), "R2", DeviceKind::Resistor,
            &[(0, n2), (1, NodeId::GROUND)])
            .with_param("resistance", 1000.0),
    );
    ckt.build_topology();
    ckt
}

/// Build a resistor ladder with `n` stages:
///   V1 — R0 — n1 — R1 — n2 — … — R(n-1) — n(n)
/// Each node also has a shunt resistor to ground.
fn build_resistor_ladder(n: usize) -> Circuit {
    let mut ckt = Circuit::new();
    let n_in = ckt.add_node("n_in");

    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n_in), (1, NodeId::GROUND)])
            .with_param("dc", 1.0),
    );

    let mut prev = n_in;
    let mut dev_id = 1u32;
    for i in 0..n {
        let next = ckt.add_node(&format!("n{}", i + 1));
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(dev_id), &format!("R{i}"), DeviceKind::Resistor,
                &[(0, prev), (1, next)])
                .with_param("resistance", 1000.0),
        );
        dev_id += 1;
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(dev_id), &format!("Rs{i}"), DeviceKind::Resistor,
                &[(0, next), (1, NodeId::GROUND)])
                .with_param("resistance", 10_000.0),
        );
        dev_id += 1;
        prev = next;
    }
    ckt.build_topology();
    ckt
}

fn build_diode_rectifier() -> Circuit {
    let mut ckt = Circuit::new();
    let n_in = ckt.add_node("n_in");

    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n_in), (1, NodeId::GROUND)])
            .with_param("dc", 5.0),
    );

    let mut prev = n_in;
    for i in 0..5usize {
        let next = ckt.add_node(&format!("d{}", i + 1));
        ckt.add_device(
            DeviceInstance::new(DeviceId::new((i * 2 + 1) as u32), &format!("D{i}"),
                DeviceKind::Diode, &[(0, prev), (1, next)])
                .with_param("is", 1e-14)
                .with_param("n", 1.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new((i * 2 + 2) as u32), &format!("R{i}"),
                DeviceKind::Resistor, &[(0, next), (1, NodeId::GROUND)])
                .with_param("resistance", 1000.0),
        );
        prev = next;
    }
    ckt.build_topology();
    ckt
}

fn build_bjt_ce_amp() -> Circuit {
    let mut ckt = Circuit::new();
    let n_vcc = ckt.add_node("vcc");
    let n_base = ckt.add_node("base");
    let n_col = ckt.add_node("col");
    let n_emi = ckt.add_node("emi");

    // Supply
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "VCC", DeviceKind::VoltageSource,
            &[(0, n_vcc), (1, NodeId::GROUND)])
            .with_param("dc", 12.0),
    );
    // Base bias
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(1), "VB", DeviceKind::VoltageSource,
            &[(0, n_base), (1, NodeId::GROUND)])
            .with_param("dc", 0.8),
    );
    // Collector resistor
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(2), "RC", DeviceKind::Resistor,
            &[(0, n_vcc), (1, n_col)])
            .with_param("resistance", 1000.0),
    );
    // Emitter resistor
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(3), "RE", DeviceKind::Resistor,
            &[(0, n_emi), (1, NodeId::GROUND)])
            .with_param("resistance", 100.0),
    );
    // NPN BJT: C=col, B=base, E=emi
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(4), "Q1", DeviceKind::BjtNpn,
            &[(0, n_col), (1, n_base), (2, n_emi)])
            .with_param("is", 1e-16)
            .with_param("bf", 100.0),
    );
    ckt.build_topology();
    ckt
}

fn build_mosfet_inverter() -> Circuit {
    let mut ckt = Circuit::new();
    let n_vdd = ckt.add_node("vdd");
    let n_in = ckt.add_node("in");
    let n_out = ckt.add_node("out");

    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "VDD", DeviceKind::VoltageSource,
            &[(0, n_vdd), (1, NodeId::GROUND)])
            .with_param("dc", 3.3),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(1), "VIN", DeviceKind::VoltageSource,
            &[(0, n_in), (1, NodeId::GROUND)])
            .with_param("dc", 0.7),
    );
    // NMOS: D=out, G=in, S=GND, B=GND
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(2), "MN", DeviceKind::MosfetN,
            &[(0, n_out), (1, n_in), (2, NodeId::GROUND), (3, NodeId::GROUND)])
            .with_param("vth", 0.5)
            .with_param("kp", 120e-6)
            .with_param("w", 10e-6)
            .with_param("l", 1e-6),
    );
    // PMOS: D=out, G=in, S=VDD, B=VDD
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(3), "MP", DeviceKind::MosfetP,
            &[(0, n_out), (1, n_in), (2, n_vdd), (3, n_vdd)])
            .with_param("vth", -0.5)
            .with_param("kp", 60e-6)
            .with_param("w", 20e-6)
            .with_param("l", 1e-6),
    );
    ckt.build_topology();
    ckt
}

fn build_bsim4_nmos_dcop() -> Circuit {
    let mut ckt = Circuit::new();
    let n_d = ckt.add_node("drain");
    let n_g = ckt.add_node("gate");
    let n_s = NodeId::GROUND;
    let n_b = NodeId::GROUND;

    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "VD", DeviceKind::VoltageSource,
            &[(0, n_d), (1, NodeId::GROUND)])
            .with_param("dc", 1.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(1), "VG", DeviceKind::VoltageSource,
            &[(0, n_g), (1, NodeId::GROUND)])
            .with_param("dc", 1.0),
    );
    // BSIM4 NMOS: D, G, S, B
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(2), "M1", DeviceKind::Bsim4N,
            &[(0, n_d), (1, n_g), (2, n_s), (3, n_b)])
            .with_param("w", 1e-6)
            .with_param("l", 100e-9),
    );
    ckt.build_topology();
    ckt
}

// ---------------------------------------------------------------------------
// Benchmark groups
// ---------------------------------------------------------------------------

fn bench_dc_op(c: &mut Criterion) {
    let mut group = c.benchmark_group("dc_op");
    let reg = DeviceRegistry::new_default();

    // 1. resistor_divider_2node
    {
        let ckt = build_resistor_divider();
        group.bench_function("resistor_divider_2node", |b| {
            b.iter(|| run_dc_op(&ckt, &reg).expect("dc_op failed"));
        });
    }

    // 2 & 3. Parametric resistor ladders
    for &n in &[100usize, 1000] {
        let ckt = build_resistor_ladder(n);
        group.bench_with_input(
            BenchmarkId::new("resistor_ladder", n),
            &n,
            |b, _| b.iter(|| run_dc_op(&ckt, &reg).expect("dc_op failed")),
        );
    }

    // 4. diode_rectifier_5
    {
        let ckt = build_diode_rectifier();
        group.bench_function("diode_rectifier_5", |b| {
            b.iter(|| run_dc_op(&ckt, &reg).expect("dc_op failed"));
        });
    }

    // 5. bjt_ce_amp
    {
        let ckt = build_bjt_ce_amp();
        group.bench_function("bjt_ce_amp", |b| {
            b.iter(|| run_dc_op(&ckt, &reg).expect("dc_op failed"));
        });
    }

    // 6. mosfet_l1_inverter
    {
        let ckt = build_mosfet_inverter();
        group.bench_function("mosfet_l1_inverter", |b| {
            b.iter(|| run_dc_op(&ckt, &reg).expect("dc_op failed"));
        });
    }

    // 7. bsim4_nmos_dcop
    {
        let ckt = build_bsim4_nmos_dcop();
        group.bench_function("bsim4_nmos_dcop", |b| {
            b.iter(|| run_dc_op(&ckt, &reg).expect("dc_op failed"));
        });
    }

    group.finish();
}

criterion_group!(benches, bench_dc_op);
criterion_main!(benches);
