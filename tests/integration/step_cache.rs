//! Phase 5 — .STEP sweep cache reuse integration tests.
//!
//! Verifies that running a 3-step .STEP sweep over a resistor divider
//! reuses the symbolic LU factorisation (topology_hits > 0) on steps 2 and 3.

use pisim_analysis::dc_op::run_dc_op;
use pisim_analysis::sweep::{ParamSweep, ParamTarget};
use pisim_device::DeviceRegistry;
use pisim_parser::SpiceParser;

/// Run a 3-step resistor sweep using `run_with_cache` and assert that
/// `cache.topology_hits > 0` after completion, confirming the symbolic LU
/// was reused rather than rebuilt on every step.
#[test]
fn step_cache_reuses_symbolic_lu() {
    let netlist = "\
* Resistor divider — R1 swept 1k → 3k
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
        3e3,
        1e3,
    );
    assert_eq!(sweep.len(), 3, "expected exactly 3 sweep points");

    let (results, cache) = sweep
        .run_with_cache(&circuit, |ckt, _target, _val, _cache| {
            let out = run_dc_op(ckt, &registry)?;
            let v2 = out
                .result
                .node_voltages
                .iter()
                .find(|(n, _)| n == "2")
                .map(|(_, v)| *v)
                .unwrap_or(0.0);
            Ok::<f64, pisim_core::SimError>(v2)
        })
        .unwrap();

    // 3 results should exist.
    assert_eq!(results.len(), 3);

    // Steps 2 and 3 should have triggered topology_hits (topology unchanged).
    assert!(
        cache.topology_hits > 0,
        "expected topology_hits > 0 after 3-step sweep, got {}",
        cache.topology_hits
    );

    // Spot-check analytic values: V(2) = 5 * R2 / (R1 + R2)
    let r2 = 1e3_f64;
    for (i, (&r1_val, &v2)) in sweep.values.iter().zip(results.iter()).enumerate() {
        let expected = 5.0 * r2 / (r1_val + r2);
        assert!(
            (v2 - expected).abs() < 1e-6,
            "step {i}: R1={r1_val} expected V(2)={expected:.6} got {v2:.6}"
        );
    }
}
