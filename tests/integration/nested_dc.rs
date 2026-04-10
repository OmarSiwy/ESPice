//! Integration tests for nested .DC solver execution (N.1.4).
//!
//! Verifies that sweeping two sources independently produces the correct
//! 2-D matrix of operating points.

use pisim_analysis::dc_op::{run_nested_dc, NestedDcConfig};
use pisim_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
use pisim_device::DeviceRegistry;

/// Build a simple two-source, single-resistor circuit:
///   V1 – R1 – n1 – R2 – n2 – V2 – GND
///
/// n1 = V1 - I*R1,  n2 = -V2 + I*R2  ... but simpler as a voltage divider
/// topology with two independent voltage sources so both can be swept.
///
/// Topology: V1 (n1↔GND) + V2 (n2↔GND) + R12 (n1↔n2).
/// Then V(n1) = V1_val, V(n2) = V2_val, and I_R12 = (V1-V2)/R.
fn two_source_circuit() -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("n1");
    let n2 = ckt.add_node("n2");
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)]).with_param("dc", 1.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "V2", DeviceKind::VoltageSource,
            &[(0, n2), (1, NodeId::GROUND)]).with_param("dc", 1.0),
    );
    ckt.add_device(
        DeviceInstance::new(DeviceId::new(0), "R12", DeviceKind::Resistor,
            &[(0, n1), (1, n2)]).with_param("resistance", 1000.0),
    );
    ckt.build_topology();
    ckt
}

/// Sweep V1 ∈ {1,2,3} and V2 ∈ {0,1,2}: verify all 9 operating points.
#[test]
fn nested_dc_two_source_sweep() {
    let ckt = two_source_circuit();
    let reg = DeviceRegistry::new_default();

    let outer_values = vec![1.0, 2.0, 3.0]; // V1 values
    let inner_values = vec![0.0, 1.0, 2.0]; // V2 values

    let config = NestedDcConfig::new(
        "v1", "dc", outer_values.clone(),
        "v2", "dc", inner_values.clone(),
    );

    let result = run_nested_dc(&ckt, &reg, &config).unwrap();

    assert_eq!(result.outer_len(), 3, "outer sweep should have 3 points");
    assert_eq!(result.inner_len(), 3, "inner sweep should have 3 points");
    assert_eq!(result.points.len(), 9, "should have 9 operating points total");

    for (oi, &v1) in outer_values.iter().enumerate() {
        for (ii, &v2) in inner_values.iter().enumerate() {
            let pt = result.get(oi, ii);

            // V(n1) should equal V1 (forced by V1 source).
            let vn1 = pt.node_voltages.iter()
                .find(|(n, _)| n == "n1")
                .map(|(_, v)| *v)
                .expect("n1 not found in result");
            assert!(
                (vn1 - v1).abs() < 1e-6,
                "V(n1) = {vn1:.6} expected {v1} (outer={oi}, inner={ii})"
            );

            // V(n2) should equal V2.
            let vn2 = pt.node_voltages.iter()
                .find(|(n, _)| n == "n2")
                .map(|(_, v)| *v)
                .expect("n2 not found in result");
            assert!(
                (vn2 - v2).abs() < 1e-6,
                "V(n2) = {vn2:.6} expected {v2} (outer={oi}, inner={ii})"
            );
        }
    }
}

/// Degenerate: single-point sweep (1×1) should produce exactly one result.
#[test]
fn nested_dc_single_point() {
    let ckt = two_source_circuit();
    let reg = DeviceRegistry::new_default();

    let config = NestedDcConfig::new(
        "v1", "dc", vec![5.0],
        "v2", "dc", vec![3.0],
    );

    let result = run_nested_dc(&ckt, &reg, &config).unwrap();
    assert_eq!(result.points.len(), 1);

    let pt = result.get(0, 0);
    let vn1 = pt.node_voltages.iter().find(|(n, _)| n == "n1").unwrap().1;
    let vn2 = pt.node_voltages.iter().find(|(n, _)| n == "n2").unwrap().1;
    assert!((vn1 - 5.0).abs() < 1e-6, "V(n1) = {vn1} expected 5.0");
    assert!((vn2 - 3.0).abs() < 1e-6, "V(n2) = {vn2} expected 3.0");
}
