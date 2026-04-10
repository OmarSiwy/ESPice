//! S-parameter golden tests — N.3.1.

use pisim_analysis::ac::AcSweepType;
use pisim_analysis::sp::{run_sp, SpConfig, SpPort};
use pisim_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
use pisim_device::DeviceRegistry;

fn build_thru_circuit() -> (Circuit, usize, usize) {
    // Two-port thru with bias resistors to ground for DC stability.
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("1");
    let n2 = ckt.add_node("2");
    // Near-ideal thru: very low resistance wire
    ckt.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "R_thru",
            DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        )
        .with_param("resistance", 1e-6),
    );
    // DC bias resistors — 1 GΩ to ground, negligible RF loading
    ckt.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "R_bias1",
            DeviceKind::Resistor,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1e9),
    );
    ckt.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "R_bias2",
            DeviceKind::Resistor,
            &[(0, n2), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1e9),
    );
    ckt.build_topology();
    // NodeId.0 is 1-based; matrix index = NodeId.0 - 1
    let n1_idx = (n1.0 - 1) as usize;
    let n2_idx = (n2.0 - 1) as usize;
    (ckt, n1_idx, n2_idx)
}

/// A thru connection should yield |S21| ≈ 1, |S11| ≈ 0 across all frequencies.
#[test]
fn sp_two_port_thru() {
    let (ckt, n1_idx, n2_idx) = build_thru_circuit();
    let reg = DeviceRegistry::new_default();

    let config = SpConfig::new(
        vec![SpPort::new(n1_idx), SpPort::new(n2_idx)],
        1e6,
        1e9,
        5,
        AcSweepType::Linear,
    );

    let result = run_sp(&ckt, &reg, &config).expect("sp thru");

    assert_eq!(result.num_ports, 2);
    assert!(!result.frequencies.is_empty());

    for f_idx in 0..result.frequencies.len() {
        let s21 = result.s(f_idx, 1, 0).magnitude();
        let s12 = result.s(f_idx, 0, 1).magnitude();
        let s11 = result.s(f_idx, 0, 0).magnitude();
        let s22 = result.s(f_idx, 1, 1).magnitude();
        let f = result.frequencies[f_idx];

        assert!(s21 > 0.9, "f={f:.2e}: |S21|={s21:.4} should be ~1");
        assert!(s12 > 0.9, "f={f:.2e}: |S12|={s12:.4} should be ~1");
        assert!(s11 < 0.2, "f={f:.2e}: |S11|={s11:.4} should be ~0");
        assert!(s22 < 0.2, "f={f:.2e}: |S22|={s22:.4} should be ~0");
    }
}

/// RC low-pass filter: |S21|² should drop at frequencies above f_c = 1/(2πRC).
#[test]
fn sp_rc_lowpass_s21() {
    let r = 1e3_f64;   // 1 kΩ
    let c = 1e-9_f64;  // 1 nF
    let f_c = 1.0 / (2.0 * std::f64::consts::PI * r * c); // ≈ 159 kHz

    let mut ckt = Circuit::new();
    let n_in = ckt.add_node("in");
    let n_out = ckt.add_node("out");

    // Series resistor (filter element)
    ckt.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n_in), (1, n_out)],
        )
        .with_param("resistance", r),
    );
    // Shunt capacitor (filter element)
    ckt.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "C1",
            DeviceKind::Capacitor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", c),
    );
    // DC bias to ground — large R to avoid loading ports
    ckt.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "R_bias_in",
            DeviceKind::Resistor,
            &[(0, n_in), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1e9),
    );
    ckt.build_topology();

    let n_in_idx = (n_in.0 - 1) as usize;
    let n_out_idx = (n_out.0 - 1) as usize;

    let reg = DeviceRegistry::new_default();
    let config = SpConfig::new(
        vec![SpPort::new(n_in_idx), SpPort::new(n_out_idx)],
        f_c * 0.01,   // well below cutoff
        f_c * 100.0,  // well above cutoff
        20,
        AcSweepType::Decade,
    );

    let result = run_sp(&ckt, &reg, &config).expect("sp rc");

    // Find indices for frequencies near f_c/10 (passband) and 10*f_c (stopband)
    let pb_idx = result.frequencies.iter()
        .position(|&f| f >= f_c * 0.05)
        .unwrap_or(0);
    let sb_idx = result.frequencies.iter()
        .position(|&f| f >= f_c * 10.0)
        .unwrap_or(result.frequencies.len() - 1);

    let s21_passband = result.s(pb_idx, 1, 0).magnitude();
    let s21_stopband = result.s(sb_idx, 1, 0).magnitude();

    // Passband |S21| should be reasonable (not near zero)
    assert!(
        s21_passband > s21_stopband,
        "|S21| passband={s21_passband:.4} should exceed stopband={s21_stopband:.4}"
    );
}
