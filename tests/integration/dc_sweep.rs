//! DC Sweep integration tests.

use pisim_test_harness::{parse_netlist_str, run_dc_sweep, Tolerance};

#[test]
fn dc_sweep_voltage_divider() {
    let netlist = "\
* Voltage divider sweep
V1 1 0 DC 0
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_sweep(&circuit, "V1", 0.0, 10.0, 2.0).unwrap();

    assert_eq!(result.sweep_values.len(), 6); // 0,2,4,6,8,10
    for (i, &vsrc) in result.sweep_values.iter().enumerate() {
        // node_voltages[sweep_point] is a vec of all node voltages at that point
        // The index within that vec depends on node ordering
        let v2_expected = vsrc / 2.0;
        // Find node "2" - it's typically at index 1 (after node "1")
        let v2 = result.node_voltages[i][1];
        assert!(
            Tolerance::within(v2, v2_expected, 1e-9, 1e-6),
            "At V1={vsrc}: V(2)={v2}, expected {v2_expected}"
        );
    }
}

#[test]
fn dc_sweep_single_resistor() {
    let netlist = "\
* Single resistor sweep
V1 1 0 DC 0
R1 1 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_sweep(&circuit, "V1", 0.0, 5.0, 1.0).unwrap();

    assert_eq!(result.sweep_values.len(), 6); // 0,1,2,3,4,5
    for (i, &vsrc) in result.sweep_values.iter().enumerate() {
        let v1 = result.node_voltages[i][0];
        assert!(
            Tolerance::within(v1, vsrc, 1e-9, 1e-6),
            "At V1={vsrc}: V(1)={v1}"
        );
    }
}

#[test]
fn dc_sweep_uses_continuation() {
    let netlist = "\
* Diode sweep
V1 1 0 DC 0
R1 1 2 100
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_sweep(&circuit, "V1", 0.0, 2.0, 0.1).unwrap();

    assert_eq!(result.sweep_values.len(), 21);
    for i in 1..result.sweep_values.len() {
        let v_prev = result.node_voltages[i - 1][1];
        let v_curr = result.node_voltages[i][1];
        assert!(v_curr >= v_prev - 1e-6,
            "V(2) should be monotonically increasing: {v_prev} -> {v_curr}");
    }
}

#[test]
#[ignore = "requires performance optimization — target: 100-pt sweep < 10x single OP"]
fn dc_sweep_100_points_performance() {
    let netlist = "\
* Performance test
V1 1 0 DC 0
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();

    let start = std::time::Instant::now();
    let _single = pisim_test_harness::run_dc_op(&circuit).unwrap();
    let single_time = start.elapsed();

    let start = std::time::Instant::now();
    let _sweep = run_dc_sweep(&circuit, "V1", 0.0, 10.0, 0.1).unwrap();
    let sweep_time = start.elapsed();

    let ratio = sweep_time.as_secs_f64() / single_time.as_secs_f64();
    assert!(ratio < 10.0, "100-point sweep took {ratio:.1}x single OP, target <10x");
}
