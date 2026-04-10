//! `.ALTER` integration tests — N.3.4.

use pisim_analysis::alter::{run_alter, AlterBlock, AlterParam};
use pisim_analysis::dc_op::run_dc_op;
use pisim_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
use pisim_device::DeviceRegistry;

fn voltage_divider(r1: f64) -> Circuit {
    let mut ckt = Circuit::new();
    let n1 = ckt.add_node("1");
    let n2 = ckt.add_node("2");
    ckt.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0),
    );
    ckt.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, n2)],
        )
        .with_param("resistance", r1),
    );
    ckt.add_device(
        DeviceInstance::new(
            DeviceId::new(0),
            "R2",
            DeviceKind::Resistor,
            &[(0, n2), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0),
    );
    ckt.build_topology();
    ckt
}

/// Base R1=1kΩ, ALTER R1=2kΩ — Vout should change between runs.
#[test]
fn alter_changes_resistor_value() {
    let base = voltage_divider(1000.0);
    let reg = DeviceRegistry::new_default();

    let blocks = vec![
        AlterBlock::new("run2").with_param(AlterParam::device("R1", "resistance", 2000.0)),
    ];

    let results = run_alter(&base, &blocks, |ckt| {
        run_dc_op(ckt, &reg)
            .map(|out| {
                out.result
                    .node_voltages
                    .iter()
                    .find(|(n, _)| n == "2")
                    .map(|(_, v)| *v)
                    .unwrap_or(f64::NAN)
            })
            .map_err(|e| e.to_string())
    })
    .unwrap();

    assert_eq!(results.len(), 2);

    // Base: V(2) = 5 * R2/(R1+R2) = 5 * 1000/2000 = 2.5 V
    let v_base = *results[0].output.as_ref().unwrap();
    assert!((v_base - 2.5).abs() < 1e-6, "base V(2)={v_base}");

    // Alter: V(2) = 5 * 1000/3000 ≈ 1.667 V
    let v_alter = *results[1].output.as_ref().unwrap();
    let expected = 5.0 / 3.0;
    assert!(
        (v_alter - expected).abs() < 1e-4,
        "alter V(2)={v_alter}, expected {expected}"
    );

    assert_ne!(v_base, v_alter, "ALTER should change Vout");
    assert_eq!(results[1].title, "run2");
}

/// Multiple alter blocks each produce independent results.
#[test]
fn alter_multiple_blocks() {
    let base = voltage_divider(1000.0);
    let reg = DeviceRegistry::new_default();

    let blocks = vec![
        AlterBlock::new("r_500").with_param(AlterParam::device("R1", "resistance", 500.0)),
        AlterBlock::new("r_4k").with_param(AlterParam::device("R1", "resistance", 4000.0)),
    ];

    let results = run_alter(&base, &blocks, |ckt| {
        run_dc_op(ckt, &reg)
            .map(|out| {
                out.result
                    .node_voltages
                    .iter()
                    .find(|(n, _)| n == "2")
                    .map(|(_, v)| *v)
                    .unwrap_or(f64::NAN)
            })
            .map_err(|e| e.to_string())
    })
    .unwrap();

    assert_eq!(results.len(), 3); // base + 2 alter blocks

    let v_base = *results[0].output.as_ref().unwrap();
    let v_r500 = *results[1].output.as_ref().unwrap();
    let v_r4k = *results[2].output.as_ref().unwrap();

    // R1=500 → R2/(R1+R2) = 1000/1500 → V(2)=5*1000/1500 ≈ 3.333
    assert!((v_r500 - 10.0 / 3.0).abs() < 1e-4, "r_500 V(2)={v_r500}");
    // R1=4k → R2/(R1+R2) = 1000/5000 → V(2)=1.0
    assert!((v_r4k - 1.0).abs() < 1e-4, "r_4k V(2)={v_r4k}");

    // Results are strictly ordered: higher R1 → lower V(2)
    assert!(v_r500 > v_base, "smaller R1 → larger Vout");
    assert!(v_base > v_r4k, "larger R1 → smaller Vout");
}

/// Base circuit is not mutated by alter runs.
#[test]
fn alter_does_not_mutate_base() {
    let base = voltage_divider(1000.0);
    let reg = DeviceRegistry::new_default();

    let blocks = vec![
        AlterBlock::new("patched").with_param(AlterParam::device("R1", "resistance", 999.0)),
    ];

    let _ = run_alter(&base, &blocks, |ckt| {
        run_dc_op(ckt, &reg).map(|_| ()).map_err(|e| e.to_string())
    })
    .unwrap();

    // Base circuit's R1 must still be 1kΩ
    let r1 = base.find_device("R1").unwrap().params.get("resistance").unwrap();
    assert!((r1 - 1000.0).abs() < 1e-9, "base R1 was mutated: {r1}");
}
