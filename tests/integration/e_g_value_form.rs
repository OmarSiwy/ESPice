//! Integration tests for E/G `VALUE={expr}` behavioral form.
//!
//! `E name n+ n- VALUE={expr}` is reduced to `B_e_name n+ n- V={expr}`.
//! `G name n+ n- VALUE={expr}` is reduced to `B_g_name n+ n- I={expr}`.

use pisim_test_harness::{parse_netlist_str, run_dc_op};

// ── E VALUE= (voltage-controlled voltage source behavioral form) ─────────────

/// E1 out 0 VALUE={2*V(in)} acts as a 2x gain amplifier.
/// V(in)=3 V → V(out) should be 6 V.
#[test]
fn e_value_gain_2x() {
    let netlist = "\
* E VALUE= 2x gain amplifier
V1 in 0 DC 3
E1 out 0 VALUE={2*V(in)}
R1 out 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let vout = result
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("node 'out' missing from DC-op result");
    assert!(
        (vout - 6.0).abs() < 1e-9,
        "E VALUE= 2x: V(out)={vout}, expected 6.0"
    );
}

/// E1 out 0 VALUE={V(in)} acts as a unity buffer.
/// V(in)=5 V → V(out) should be 5 V.
#[test]
fn e_value_unity_buffer() {
    let netlist = "\
* E VALUE= unity buffer
V1 in 0 DC 5
E1 out 0 VALUE={V(in)}
R1 out 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let vout = result
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("node 'out' missing from DC-op result");
    assert!(
        (vout - 5.0).abs() < 1e-9,
        "E VALUE= unity: V(out)={vout}, expected 5.0"
    );
}

// ── G VALUE= (voltage-controlled current source behavioral form) ─────────────

/// G1 out 0 VALUE={0.001*V(in)} acts as a 1 mS transconductance.
/// V(in)=2 V, R_load=1 kΩ → I=2 mA → V(out)=2 V.
#[test]
fn g_value_transconductance() {
    let netlist = "\
* G VALUE= transconductance 1mS
V1 in 0 DC 2
G1 out 0 VALUE={0.001*V(in)}
R1 out 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let vout = result
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("node 'out' missing from DC-op result");
    // I = 0.001 * 2 = 2e-3 A; V = I * 1k = 2.0 V
    assert!(
        (vout - 2.0).abs() < 1e-9,
        "G VALUE= gm: V(out)={vout}, expected 2.0"
    );
}

/// G1 out 0 VALUE={0.005*V(in)} with R_load=2 kΩ.
/// V(in)=4 V → I=20 mA → V(out)=40 V.
#[test]
fn g_value_high_gain() {
    let netlist = "\
* G VALUE= high gain
V1 in 0 DC 4
G1 out 0 VALUE={0.005*V(in)}
R1 out 0 2k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let vout = result
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("node 'out' missing from DC-op result");
    // I = 0.005 * 4 = 0.02 A; V = 0.02 * 2000 = 40 V
    assert!(
        (vout - 40.0).abs() < 1e-6,
        "G VALUE= high-gain: V(out)={vout}, expected 40.0"
    );
}

// ── Parser-level checks ──────────────────────────────────────────────────────

/// E VALUE= without `=` should return a parse error.
#[test]
fn e_value_missing_equals_is_error() {
    let netlist = "\
* E VALUE missing = sign
V1 in 0 DC 1
E1 out 0 VALUE {V(in)}
R1 out 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(
        result.is_err(),
        "E VALUE without '=' should be a parse error"
    );
}
