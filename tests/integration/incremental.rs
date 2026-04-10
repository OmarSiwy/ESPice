//! Incremental simulation tests — unique to VOLTAIC (TESTING.md Section 4).

use pisim_test_harness::{parse_netlist_str, Tolerance};
use pisim_analysis::run_dc_op;
use pisim_cache::IncrementalCache;
use pisim_device::DeviceRegistry;

#[test]
fn incremental_dc_resistor_value_change() {
    let netlist = "\
* Voltage divider for incremental test
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 2k
.OP
.END
";
    let (mut circuit, _) = parse_netlist_str(netlist).unwrap();
    let registry = DeviceRegistry::new_default();

    let output1 = run_dc_op(&circuit, &registry).unwrap();
    let v2_initial = output1.result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(Tolerance::within(v2_initial, 10.0 / 3.0, 1e-9, 1e-6),
        "V(2) = {v2_initial}, expected 3.333");

    circuit.set_device_param("r1", "resistance", 1500.0);

    let output2 = run_dc_op(&circuit, &registry).unwrap();
    let v2_changed = output2.result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    let expected = 5.0 * 2000.0 / 3500.0;
    assert!(Tolerance::within(v2_changed, expected, 1e-9, 1e-6),
        "V(2) = {v2_changed}, expected {expected}");
}

#[test]
fn incremental_cache_stores_and_retrieves() {
    let netlist = "\
* Cache test
V1 1 0 DC 5
R1 1 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let registry = DeviceRegistry::new_default();

    let output = run_dc_op(&circuit, &registry).unwrap();

    assert!(output.cache.warm_start().is_some(), "cache should have solution after run");
}

#[test]
fn incremental_topology_change_invalidates() {
    let mut cache = IncrementalCache::new(5);
    cache.store_op(&[1.0, 2.0, 3.0]);
    assert!(cache.warm_start().is_some());

    cache.on_topology_change();
    assert!(cache.warm_start().is_none(), "topology change should clear cache");
}

#[test]
#[ignore = "requires Woodbury rank-k update for incremental re-factorization"]
fn incremental_dc_resistor_timing() {
    let netlist = "\
* Timing test
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (mut circuit, _) = parse_netlist_str(netlist).unwrap();
    let registry = DeviceRegistry::new_default();

    let start = std::time::Instant::now();
    let _ = run_dc_op(&circuit, &registry).unwrap();
    let full_time = start.elapsed();

    circuit.set_device_param("r1", "resistance", 1100.0);
    let start = std::time::Instant::now();
    let _ = run_dc_op(&circuit, &registry).unwrap();
    let incr_time = start.elapsed();

    let ratio = incr_time.as_secs_f64() / full_time.as_secs_f64();
    assert!(ratio < 0.05, "Incremental took {ratio:.2}x of full, target <0.05x");
}

#[test]
#[ignore = "requires Woodbury rank-k update implementation"]
fn incremental_dc_mosfet_vth_change() {
    let netlist = "\
* CMOS inverter incremental Vth test
VDD vdd 0 DC 3.3
VIN in 0 DC 1.65
M1 out in 0 0 NMOD W=10u L=1u
M2 out in vdd vdd PMOD W=20u L=1u
.MODEL NMOD NMOS (VTH0=0.5 KP=120u)
.MODEL PMOD PMOS (VTH0=-0.5 KP=60u)
.OP
.END
";
    let (mut circuit, _) = parse_netlist_str(netlist).unwrap();
    let registry = DeviceRegistry::new_default();

    let r1 = run_dc_op(&circuit, &registry).unwrap();
    let vout1 = r1.result.node_voltages.iter().find(|(n, _)| n == "out").unwrap().1;

    circuit.set_device_param("m1", "vth0", 0.51);

    let r2 = run_dc_op(&circuit, &registry).unwrap();
    let vout2 = r2.result.node_voltages.iter().find(|(n, _)| n == "out").unwrap().1;

    assert!((vout1 - vout2).abs() > 1e-6, "Vth change should affect output");
    assert!(Tolerance::within(vout2, vout1, 0.1, 0.05),
        "Small Vth change should give small output change");
}

#[test]
#[ignore = "requires corner sweep with incremental cache"]
fn incremental_corner_sweep() {}

#[test]
#[ignore = "requires cache persistence to disk"]
fn cache_persistence_to_disk() {}
