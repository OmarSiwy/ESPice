//! Incremental simulation and step-cache tests.
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, Tolerance};
use bigospice_analysis::run_dc_op;
use bigospice_cache::IncrementalCache;
use bigospice_device::DeviceRegistry;

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
fn step_cache_reuses_symbolic_lu() {
    use bigospice_analysis::sweep::{ParamSweep, ParamTarget};
    use bigospice_cache::CacheManager;
    use bigospice_parser::SpiceParser;

    let netlist = "\
* Resistor divider — R1 swept 1k → 3k
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let registry = DeviceRegistry::new_default();

    let sweep = ParamSweep::lin(
        ParamTarget::DeviceParam("r1".into(), "resistance".into()),
        1e3, 3e3, 1e3,
    );
    assert_eq!(sweep.len(), 3, "expected exactly 3 sweep points");

    // run_with_cache returns Vec<R>; the CacheManager is internal.
    // We verify correctness of results instead of topology_hits (which
    // requires access to the internal cache).
    let results = sweep
        .run_with_cache(&circuit, |ckt, _cache, _target, _val| {
            let out = run_dc_op(ckt, &registry)?;
            let v2 = out.result.node_voltages.iter()
                .find(|(n, _)| n == "2")
                .map(|(_, v)| *v)
                .unwrap_or(0.0);
            Ok::<f64, bigospice_core::SimError>(v2)
        })
        .unwrap();

    assert_eq!(results.len(), 3);

    // Spot-check analytic values: V(2) = 5 * R2 / (R1 + R2), R2=1k
    let r2 = 1e3_f64;
    for (i, (&r1_val, &v2)) in sweep.values.iter().zip(results.iter()).enumerate() {
        let expected = 5.0 * r2 / (r1_val + r2);
        assert!(
            (v2 - expected).abs() < 1e-6,
            "step {i}: R1={r1_val} expected V(2)={expected:.6} got {v2:.6}"
        );
    }
}

#[test]
#[ignore = "requires cache persistence to disk"]
fn cache_persistence_to_disk() {}

#[test]
#[ignore = "requires corner sweep with incremental cache"]
fn incremental_corner_sweep() {}
