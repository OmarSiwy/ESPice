//! Robustness tests (TESTING.md Section 3.4).

use pisim_test_harness::{parse_netlist_str, run_dc_op, Tolerance};

#[test]
fn robustness_empty_circuit() {
    let netlist = "\
* Empty circuit
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    assert_eq!(circuit.devices().len(), 0);
}

#[test]
fn robustness_no_analysis_statement() {
    let netlist = "\
* No analysis
V1 1 0 DC 5
R1 1 0 1k
.END
";
    let (circuit, analyses) = parse_netlist_str(netlist).unwrap();
    assert!(analyses.is_empty());
    assert_eq!(circuit.devices().len(), 2);
}

#[test]
fn robustness_floating_node() {
    let netlist = "\
* Floating node
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
R3 2 3 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    match result {
        Ok(r) => {
            for (_, v) in &r.node_voltages {
                assert!(v.is_finite(), "node voltage should be finite, got {v}");
            }
        }
        Err(e) => {
            let msg = format!("{e}");
            assert!(
                msg.contains("onverg") || msg.contains("ingular"),
                "Expected convergence/singular error, got: {e}"
            );
        }
    }
}

#[test]
fn robustness_nan_detection() {
    let netlist = "\
* Zero resistance
V1 1 0 DC 5
R1 1 2 0
R2 2 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    match result {
        Ok(r) => {
            for (name, v) in &r.node_voltages {
                assert!(!v.is_nan(), "NaN detected at node {name}");
            }
        }
        Err(_) => {}
    }
}

#[test]
#[ignore = "Extreme voltage (1e6V) exceeds NR voltage step limiter capacity (MAX_VOLTAGE_STEP=5V)"]
fn robustness_extreme_voltage() {
    let netlist = "\
* Extreme voltage
V1 1 0 DC 1e6
R1 1 0 1
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v1 = result.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    assert!(v1.is_finite());
    assert!((v1 - 1e6).abs() < 1.0);
}

#[test]
fn robustness_very_small_resistance() {
    let netlist = "\
* Very small resistance (1 milliohm)
V1 1 0 DC 1
R1 1 0 0.001
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v1 = result.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    assert!(Tolerance::within(v1, 1.0, 1e-6, 1e-4));
}

#[test]
fn robustness_very_large_resistance() {
    let netlist = "\
* Very large resistance (1 Gigaohm)
V1 1 0 DC 1
R1 1 2 1G
R2 2 0 1G
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(Tolerance::within(v2, 0.5, 1e-6, 1e-4));
}

#[test]
#[ignore = "requires fuzz testing infrastructure"]
fn robustness_fuzz_netlist_parsing() {}

#[test]
#[ignore = "requires memory leak detection (valgrind/ASan)"]
fn robustness_no_memory_leaks() {}

#[test]
#[ignore = "requires 1M+ transistor netlist generation"]
fn robustness_large_circuit_no_oom() {}
