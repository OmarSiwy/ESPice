//! Phase 3.5 — generic ParamSweep runner integration tests.
//!
//! Verifies that a `.STEP`-driven sweep over a device parameter produces the
//! expected DC operating points.

use pisim_analysis::dc_op::run_dc_op;
use pisim_analysis::sweep::{ParamSweep, ParamTarget, sweep_from_step};
use pisim_device::DeviceRegistry;
use pisim_parser::SpiceParser;

/// Resistor divider with R1 swept from 1k to 5k. The midpoint voltage should
/// follow V_out = 5 * R2 / (R1 + R2) for each swept value.
#[test]
fn sweep_resistor_divider_midpoint() {
    let netlist = "\
* Resistor divider with R1 sweep
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let registry = DeviceRegistry::default();

    let sweep = ParamSweep::lin(
        ParamTarget::DeviceParam("r1".into(), "resistance".into()),
        1e3,
        5e3,
        1e3,
    );
    assert_eq!(sweep.len(), 5);

    let results = sweep
        .run(&circuit, |ckt, _target, value| {
            let out = run_dc_op(ckt, &registry)?;
            let v2 = out
                .result
                .node_voltages
                .iter()
                .find(|(n, _)| n == "2")
                .map(|(_, v)| *v)
                .unwrap_or(0.0);
            Ok::<(f64, f64), pisim_core::SimError>((value, v2))
        })
        .unwrap();

    // Spot-check the analytic divider at each sweep point.
    for (r1_val, v2) in &results {
        let expected = 5.0 * 1e3 / (r1_val + 1e3);
        assert!(
            (v2 - expected).abs() < 1e-6,
            "R1={r1_val}: expected V(2)={expected}, got {v2}"
        );
    }
}

/// Verify that `sweep_from_step` parses the `device.param` form correctly.
#[test]
fn sweep_from_step_device_form() {
    let s = sweep_from_step("r1.resistance", vec![1e3, 2e3, 3e3]);
    match s.target {
        ParamTarget::DeviceParam(dev, key) => {
            assert_eq!(dev, "r1");
            assert_eq!(key, "resistance");
        }
        _ => panic!("expected DeviceParam"),
    }
    assert_eq!(s.values, vec![1e3, 2e3, 3e3]);
}

/// `.STEP DEC r1 100 10k 1` — exponential sweep should hit 100, 1k, 10k.
#[test]
fn sweep_dec_three_decades() {
    let s = ParamSweep::dec(
        ParamTarget::DeviceParam("r1".into(), "resistance".into()),
        100.0,
        10_000.0,
        1,
    );
    assert!(s.values.len() >= 3);
    assert!((s.values[0] - 100.0).abs() < 1e-9);
    assert!((s.values.last().unwrap() - 10_000.0).abs() < 1.0);
}

/// `.STEP LIST` — explicit values pass through unchanged.
#[test]
fn sweep_list_explicit_values() {
    let s = ParamSweep::list(
        ParamTarget::DeviceParam("r1".into(), "resistance".into()),
        vec![47.0, 220.0, 1e3, 4.7e3],
    );
    assert_eq!(s.values, vec![47.0, 220.0, 1e3, 4.7e3]);
}
