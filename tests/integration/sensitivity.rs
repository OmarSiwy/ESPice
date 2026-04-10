//! DC sensitivity analysis integration tests.

use pisim_analysis::{run_sens_dc, SensConfig, SensOutput};
use pisim_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
use pisim_test_harness::parse_netlist_str;

/// Build a voltage divider: Vcc — R1 — node2 — R2 — GND.
/// Vout = V(2) = Vcc * R2 / (R1 + R2).
fn voltage_divider(r1: f64, r2: f64, vcc: f64) -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("1");
    let n2 = ckt.add_node("2");
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "Vcc", DeviceKind::VoltageSource, &[
            (0, n1),
            (1, NodeId::GROUND),
        ])
        .with_param("dc", vcc),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor, &[
            (0, n1),
            (1, n2),
        ])
        .with_param("resistance", r1),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "R2", DeviceKind::Resistor, &[
            (0, n2),
            (1, NodeId::GROUND),
        ])
        .with_param("resistance", r2),
    );
    ckt.build_topology();
    ckt
}

/// Analytical sensitivities for the voltage divider Vout = Vcc * R2 / (R1 + R2):
///
///   ∂Vout/∂R1  = -Vcc * R2 / (R1 + R2)²
///   ∂Vout/∂R2  =  Vcc * R1 / (R1 + R2)²
///   ∂Vout/∂Vcc =  R2 / (R1 + R2)

#[test]
fn sensitivity_baseline_output() {
    let ckt = voltage_divider(1e3, 2e3, 3.0);
    let cfg = SensConfig {
        output: SensOutput::NodeVoltage("2".into()),
        params: vec![],
    };
    let result = run_sens_dc(&ckt, &cfg).unwrap();
    // Vout = 3 * 2000/3000 = 2.0 V
    assert!(
        (result.output_value - 2.0).abs() < 1e-6,
        "expected Vout=2.0, got {}",
        result.output_value
    );
}

#[test]
fn sensitivity_r1() {
    let r1 = 1e3_f64;
    let r2 = 2e3_f64;
    let vcc = 3.0_f64;
    let ckt = voltage_divider(r1, r2, vcc);

    let cfg = SensConfig {
        output: SensOutput::NodeVoltage("2".into()),
        params: vec!["R1".into()],
    };
    let result = run_sens_dc(&ckt, &cfg).unwrap();

    // ∂Vout/∂R1 = -Vcc * R2 / (R1 + R2)^2 = -3 * 2000 / 9e6 ≈ -6.6667e-4
    let expected = -vcc * r2 / (r1 + r2).powi(2);
    let got = result.sensitivities[0].absolute;
    let rel_err = (got - expected).abs() / expected.abs();
    assert!(
        rel_err < 0.01,
        "∂Vout/∂R1: expected {expected:.6e}, got {got:.6e}, rel_err={rel_err:.4}"
    );
}

#[test]
fn sensitivity_r2() {
    let r1 = 1e3_f64;
    let r2 = 2e3_f64;
    let vcc = 3.0_f64;
    let ckt = voltage_divider(r1, r2, vcc);

    let cfg = SensConfig {
        output: SensOutput::NodeVoltage("2".into()),
        params: vec!["R2".into()],
    };
    let result = run_sens_dc(&ckt, &cfg).unwrap();

    // ∂Vout/∂R2 = Vcc * R1 / (R1 + R2)^2 = 3 * 1000 / 9e6 ≈ 3.3333e-4
    let expected = vcc * r1 / (r1 + r2).powi(2);
    let got = result.sensitivities[0].absolute;
    let rel_err = (got - expected).abs() / expected.abs();
    assert!(
        rel_err < 0.01,
        "∂Vout/∂R2: expected {expected:.6e}, got {got:.6e}, rel_err={rel_err:.4}"
    );
}

#[test]
fn sensitivity_vcc() {
    let r1 = 1e3_f64;
    let r2 = 2e3_f64;
    let vcc = 3.0_f64;
    let ckt = voltage_divider(r1, r2, vcc);

    let cfg = SensConfig {
        output: SensOutput::NodeVoltage("2".into()),
        params: vec!["Vcc".into()],
    };
    let result = run_sens_dc(&ckt, &cfg).unwrap();

    // ∂Vout/∂Vcc = R2 / (R1 + R2) = 2000/3000 ≈ 0.6667
    let expected = r2 / (r1 + r2);
    let got = result.sensitivities[0].absolute;
    let rel_err = (got - expected).abs() / expected.abs();
    assert!(
        rel_err < 0.01,
        "∂Vout/∂Vcc: expected {expected:.6e}, got {got:.6e}, rel_err={rel_err:.4}"
    );
}

#[test]
fn sensitivity_relative_vcc_equals_one() {
    let r1 = 1e3_f64;
    let r2 = 2e3_f64;
    let vcc = 3.0_f64;
    let ckt = voltage_divider(r1, r2, vcc);

    let cfg = SensConfig {
        output: SensOutput::NodeVoltage("2".into()),
        params: vec!["Vcc".into()],
    };
    let result = run_sens_dc(&ckt, &cfg).unwrap();

    // Relative sens of Vout w.r.t. Vcc = (Vcc/Vout) * ∂Vout/∂Vcc
    //   = (3/2) * (2/3) = 1.0  (Vout is linearly proportional to Vcc)
    let rel = result.sensitivities[0].relative;
    assert!(
        (rel - 1.0).abs() < 0.01,
        "relative sensitivity w.r.t. Vcc: expected 1.0, got {rel:.6}"
    );
}

#[test]
fn sensitivity_all_params() {
    let ckt = voltage_divider(1e3, 2e3, 3.0);
    let cfg = SensConfig {
        output: SensOutput::NodeVoltage("2".into()),
        params: vec!["R1".into(), "R2".into(), "Vcc".into()],
    };
    let result = run_sens_dc(&ckt, &cfg).unwrap();
    assert_eq!(result.sensitivities.len(), 3);
    assert_eq!(result.sensitivities[0].param_name, "R1");
    assert_eq!(result.sensitivities[1].param_name, "R2");
    assert_eq!(result.sensitivities[2].param_name, "Vcc");
}

#[test]
fn sensitivity_resistor_divider_netlist_parse() {
    // The original scaffold test: parsing the netlist with .SENS is enough here.
    let netlist = "\
* Sensitivity of V(2) to R1
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.SENS V(2)
.END
";
    let (_circuit, analyses) = parse_netlist_str(netlist).unwrap();
    use pisim_parser::netlist::{AnalysisKind, SensOutputSpec};
    let sens = analyses
        .iter()
        .find(|a| matches!(&a.kind, AnalysisKind::Sens { .. }));
    assert!(sens.is_some(), ".SENS analysis should be parsed");
    if let Some(a) = sens {
        if let AnalysisKind::Sens { output, params } = &a.kind {
            assert_eq!(output, &SensOutputSpec::NodeVoltage("2".into()));
            assert!(params.is_empty());
        }
    }
}

#[test]
fn sensitivity_netlist_with_params_parse() {
    let netlist = "\
* Sensitivity with explicit params
V1 1 0 DC 3
R1 1 2 1k
R2 2 0 2k
.SENS V(2) R1 R2 V1
.END
";
    let (_circuit, analyses) = parse_netlist_str(netlist).unwrap();
    use pisim_parser::netlist::{AnalysisKind, SensOutputSpec};
    let sens = analyses
        .iter()
        .find(|a| matches!(&a.kind, AnalysisKind::Sens { .. }));
    assert!(sens.is_some());
    if let Some(a) = sens {
        if let AnalysisKind::Sens { output, params } = &a.kind {
            assert_eq!(output, &SensOutputSpec::NodeVoltage("2".into()));
            assert_eq!(params, &["r1", "r2", "v1"]);
        }
    }
}
