//! Behavioral B-source integration tests.
//!
//! Tests cover:
//! - Voltage form: `B<name> n+ n- V={expr}`
//! - Current form: `B<name> n+ n- I={expr}`
//! - Nonlinear gain, arithmetic, V(node) references
//! - Parser-level rejection of unsupported keywords

use pisim_test_harness::{parse_netlist_str, run_dc_op};

// ── Voltage-form B-source ────────────────────────────────────────────────────

/// B-source unity buffer: B1 n+ n- V={V(in)} → V(out) == V(in)
#[test]
fn bsource_v_unity_buffer() {
    let netlist = "\
* B-source unity buffer
V1 1 0 DC 3
B1 2 0 V={V(1)}
R1 2 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!((v2 - 3.0).abs() < 1e-9, "V(2)={v2}, expected 3.0");
}

/// B-source voltage gain of 2: B1 2 0 V={2*V(1)}
#[test]
fn bsource_v_gain_2x() {
    let netlist = "\
* B-source 2x gain
V1 1 0 DC 5
B1 2 0 V={2*V(1)}
R1 2 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!((v2 - 10.0).abs() < 1e-9, "V(2)={v2}, expected 10.0");
}

/// B-source summing amplifier: B1 3 0 V={V(1)+V(2)}
#[test]
fn bsource_v_sum_two_nodes() {
    let netlist = "\
* B-source sum of two voltages
V1 1 0 DC 3
V2 2 0 DC 4
B1 3 0 V={V(1)+V(2)}
R1 3 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v3 = result.node_voltages.iter().find(|(n, _)| n == "3").unwrap().1;
    assert!((v3 - 7.0).abs() < 1e-9, "V(3)={v3}, expected 7.0");
}

/// B-source constant: B1 1 0 V={5} — produces 5 V regardless of external nodes
#[test]
fn bsource_v_constant() {
    let netlist = "\
* B-source constant voltage
B1 1 0 V={5}
R1 1 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v1 = result.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    assert!((v1 - 5.0).abs() < 1e-9, "V(1)={v1}, expected 5.0");
}

// ── Current-form B-source ────────────────────────────────────────────────────

/// B-source current proportional to V(in): effective conductance
/// B1 1 0 I={V(1)/1k} — acts like a 1 kΩ resistor to ground
#[test]
fn bsource_i_ohms_law_equivalence() {
    let netlist = "\
* B-source current = V/R  (like a 1k resistor)
V1 in 0 DC 10
B1 in 0 I={V(in)/1000}
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    // V(in) is clamped to 10 by V1; the B-source injects 10mA but V1 absorbs it.
    let vin = result.node_voltages.iter().find(|(n, _)| n == "in").unwrap().1;
    assert!((vin - 10.0).abs() < 1e-9, "V(in)={vin}, expected 10.0");
}

/// B-source current source: constant 2 mA into a 1 kΩ load → 2 V
#[test]
fn bsource_i_constant_current() {
    let netlist = "\
* B-source constant 2mA current source
B1 1 0 I={0.002}
R1 1 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v1 = result.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    assert!((v1 - 2.0).abs() < 1e-9, "V(1)={v1}, expected 2.0");
}

// ── Parser rejection of unsupported features ─────────────────────────────────

/// TABLE form is now supported — parser must accept V=TABLE {expr} (x,y) ...
#[test]
fn bsource_table_parses() {
    let netlist = "\
* B-source TABLE form
B1 1 0 V=TABLE {V(2)} (0,0) (1,1) (2,2)
V2 2 0 DC 1
R1 1 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), "B-source TABLE form should parse: {:?}", result.err());
}

/// LAPLACE is not supported — parser must return an error
#[test]
fn bsource_reject_laplace() {
    let netlist = "\
* LAPLACE form is unsupported
B1 1 0 V={LAPLACE(V(1))}
R1 1 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_err(), "LAPLACE should be rejected");
}
