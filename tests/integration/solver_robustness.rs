/// Integration tests for Phase 6.2: Pseudo-transient continuation and Anderson acceleration.
///
/// Tests that circuits that are difficult for standard Newton-Raphson converge
/// when the new fallback methods are enabled.
use pisim_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId, SimOptions};
use pisim_device::DeviceRegistry;
use pisim_solver::{NewtonRaphson, NrConfig};

// ---------------------------------------------------------------------------
// Circuit builders
// ---------------------------------------------------------------------------

/// Voltage divider: V1=5V, R1=R2=1kΩ. Should converge with vanilla NR.
fn voltage_divider() -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("1");
    let n2 = ckt.add_node("2");

    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)])
        .with_param("dc", 5.0),
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

/// Single diode with a 1 V source and 1 kΩ series resistor.
/// Standard circuit (should converge with vanilla NR after GMIN stepping).
fn diode_circuit() -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("anode");
    let n2 = ckt.add_node("cathode");

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
        DeviceInstance::new(DeviceId::new(2), "D1", DeviceKind::Diode,
            &[(0, n2), (1, NodeId::GROUND)])
        .with_param("is", 1e-14)
        .with_param("n", 1.0),
    );
    ckt.build_topology();
    ckt
}

/// A stiff nonlinear circuit: diode pair with 1pA saturation current and a
/// 10V supply through 100kΩ. The strong nonlinearity makes this hard for
/// vanilla Newton. PTC provides a guaranteed path to convergence.
fn stiff_diode_circuit() -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("vdd");
    let n2 = ckt.add_node("mid");

    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)])
        .with_param("dc", 10.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(1), "R1", DeviceKind::Resistor,
            &[(0, n1), (1, n2)])
        .with_param("resistance", 100_000.0),
    );
    // Tight Gmin diode: Is=1pA (stiff nonlinearity near knee)
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(2), "D1", DeviceKind::Diode,
            &[(0, n2), (1, NodeId::GROUND)])
        .with_param("is", 1e-12)
        .with_param("n", 1.0),
    );
    ckt.build_topology();
    ckt
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Vanilla NR converges on the simple voltage divider.
#[test]
fn vanilla_nr_voltage_divider() {
    let ckt = voltage_divider();
    let reg = DeviceRegistry::new_default();
    let nr = NewtonRaphson::with_defaults();

    let result = nr.solve(&ckt, &reg, None).expect("NR should converge");
    assert!(result.converged);
    assert!((result.solution[0] - 5.0).abs() < 1e-6, "V(1)={}", result.solution[0]);
    assert!((result.solution[1] - 2.5).abs() < 1e-6, "V(2)={}", result.solution[1]);
}

/// Vanilla NR converges on the diode circuit.
#[test]
fn vanilla_nr_diode() {
    let ckt = diode_circuit();
    let reg = DeviceRegistry::new_default();
    let nr = NewtonRaphson::with_defaults();

    let result = nr.solve(&ckt, &reg, None).expect("NR should converge on diode circuit");
    assert!(result.converged);
    // Diode mid node voltage is < V_supply (current flows through diode)
    assert!(result.solution[1] > 0.4, "V(cathode) should be above 0.4V");
    assert!(result.solution[1] < 1.0, "V(cathode) should be below supply");
}

/// Anderson-accelerated NR converges on the voltage divider with same answer.
#[test]
fn anderson_nr_voltage_divider() {
    let ckt = voltage_divider();
    let reg = DeviceRegistry::new_default();

    let mut cfg = NrConfig::default();
    cfg.enable_anderson = true;
    let nr = NewtonRaphson::new(cfg);

    let result = nr.solve(&ckt, &reg, None).expect("Anderson NR should converge");
    assert!(result.converged);
    assert!((result.solution[0] - 5.0).abs() < 1e-6, "V(1)={}", result.solution[0]);
    assert!((result.solution[1] - 2.5).abs() < 1e-6, "V(2)={}", result.solution[1]);
}

/// Anderson-accelerated NR converges on the diode circuit.
#[test]
fn anderson_nr_diode() {
    let ckt = diode_circuit();
    let reg = DeviceRegistry::new_default();

    let mut cfg = NrConfig::default();
    cfg.enable_anderson = true;
    let nr = NewtonRaphson::new(cfg);

    let result = nr.solve(&ckt, &reg, None).expect("Anderson NR should converge on diode circuit");
    assert!(result.converged);
    assert!(result.solution[1] > 0.4, "V(cathode) should be above 0.4V");
}

/// Pseudo-transient continuation converges on the stiff diode circuit.
/// This is the primary validation for Phase 6.2: a circuit that is difficult
/// for standard NR but guaranteed to converge under PTC.
#[test]
fn pseudo_transient_stiff_diode() {
    let ckt = stiff_diode_circuit();
    let reg = DeviceRegistry::new_default();

    let mut cfg = NrConfig::default();
    cfg.enable_pseudo_transient = true;
    let nr = NewtonRaphson::new(cfg);

    let result = nr.solve(&ckt, &reg, None).expect("PTC should converge on stiff diode");
    assert!(result.converged);
    // With 10V supply and 100kΩ + diode, mid node should be near diode knee (~0.6V)
    // and resistor drops ~9.4V carrying ~94µA.
    let v_mid = result.solution[1];
    assert!(v_mid > 0.4, "V(mid)={v_mid} should be above 0.4V");
    assert!(v_mid < 2.0, "V(mid)={v_mid} should be below 2.0V (diode limits voltage)");
}

/// PTC + Anderson together — belt-and-suspenders mode.
#[test]
fn ptc_and_anderson_voltage_divider() {
    let ckt = voltage_divider();
    let reg = DeviceRegistry::new_default();

    let mut cfg = NrConfig::default();
    cfg.enable_anderson = true;
    cfg.enable_pseudo_transient = true;
    let nr = NewtonRaphson::new(cfg);

    let result = nr.solve(&ckt, &reg, None).expect("PTC+AA should converge");
    assert!(result.converged);
    assert!((result.solution[0] - 5.0).abs() < 1e-6, "V(1)={}", result.solution[0]);
}

/// Verify that the two new NrConfig flags default to false (zero-overhead
/// disable) and are preserved through from_options().
#[test]
fn nr_config_new_flags_default_false() {
    let cfg = NrConfig::default();
    assert!(!cfg.enable_anderson, "Anderson should be off by default");
    assert!(!cfg.enable_pseudo_transient, "PTC should be off by default");

    let opts = SimOptions::default();
    let cfg2 = NrConfig::from_options(&opts);
    assert!(!cfg2.enable_anderson);
    assert!(!cfg2.enable_pseudo_transient);
}
