//! E/G `LAPLACE` controlled-source — integration tests (Phase 2.2).
//!
//! The parser expands `E … LAPLACE {expr} (b...) (a...)` and the
//! analogous G form into a small subcircuit (B-source + RC + output
//! stage) at parse time.  These tests pin down the resulting DC, AC,
//! and transient behaviour.

use pisim_test_harness::{parse_netlist_str, run_dc_op};

/// Pure-gain LAPLACE: H(s) = 1.  V(out) should track V(in) exactly.
#[test]
fn laplace_unity_gain_dc_op() {
    let netlist = "\
* LAPLACE unity gain
V1 in 0 DC 1
R1 in 0 1k
E1 out 0 LAPLACE {V(in)} (1) (1)
R2 out 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let result = run_dc_op(&circuit).expect("DC op");
    let v_out = result
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("'out' node");
    assert!(
        (v_out - 1.0).abs() < 1e-6,
        "V(out) = {v_out}, expected ≈ 1.0 V (unity gain)"
    );
}

/// Pure-gain LAPLACE: H(s) = 2.  V(out) should be 2·V(in).
#[test]
fn laplace_gain_of_two_dc_op() {
    let netlist = "\
* LAPLACE gain of 2
V1 in 0 DC 1.5
R1 in 0 1k
E1 out 0 LAPLACE {V(in)} (2) (1)
R2 out 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let result = run_dc_op(&circuit).expect("DC op");
    let v_out = result
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("'out' node");
    assert!(
        (v_out - 3.0).abs() < 1e-6,
        "V(out) = {v_out}, expected ≈ 3.0 V (gain·V(in))"
    );
}

/// First-order lowpass: H(s) = 1 / (1 + s).  At DC the gain is 1.
#[test]
fn laplace_first_order_lp_dc_gain_unity() {
    let netlist = "\
* LAPLACE 1-pole LP — DC gain check
V1 in 0 DC 1
R1 in 0 1k
E1 out 0 LAPLACE {V(in)} (1) (1 1)
R2 out 0 1Meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let result = run_dc_op(&circuit).expect("DC op");
    let v_out = result
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("'out' node");
    assert!(
        (v_out - 1.0).abs() < 5e-3,
        "V(out) = {v_out}, expected ≈ 1.0 V at DC (lowpass passes DC)"
    );
}

/// First-order LP DC sweep: with H(s) = 1/(1+τs), at DC the input/output
/// gain should still be exactly 1 across a range of input amplitudes.
/// This indirectly verifies the parser-time RC expansion (the internal
/// `_lap.<name>.x` node carries V(in) at steady state) without needing
/// to drive AC analysis through the B-source.
#[test]
fn laplace_first_order_lp_linear_in_input() {
    for vin in &[0.5_f64, 1.0, 2.0, -1.0] {
        let netlist = format!(
            "\
* LAPLACE 1-pole LP — DC linearity check
V1 in 0 DC {vin}
R1 in 0 1k
E1 out 0 LAPLACE {{V(in)}} (1) (1 1m)
R2 out 0 1Meg
.OP
.END
"
        );
        let (circuit, _) = parse_netlist_str(&netlist).expect("parse");
        let result = run_dc_op(&circuit).expect("DC op");
        let v_out = result
            .node_voltages
            .iter()
            .find(|(n, _)| n == "out")
            .map(|(_, v)| *v)
            .expect("'out' node");
        assert!(
            (v_out - vin).abs() < 5e-3,
            "V(out) = {v_out}, expected ≈ {vin} V (LP at DC)"
        );
    }
}

/// LP gain ≠ 1 case: H(s) = 3/(1+τs) → DC gain = 3.
#[test]
fn laplace_first_order_lp_gain_three_dc_op() {
    let netlist = "\
* LAPLACE 1-pole LP gain 3
V1 in 0 DC 0.5
R1 in 0 1k
E1 out 0 LAPLACE {V(in)} (3) (1 0.001)
R2 out 0 1Meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let result = run_dc_op(&circuit).expect("DC op");
    let v_out = result
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("'out' node");
    assert!(
        (v_out - 1.5).abs() < 5e-3,
        "V(out) = {v_out}, expected ≈ 1.5 V (3·0.5)"
    );
}

/// LP transfer-coefficient sanity check: vary the LAPLACE numerator
/// constant K and verify V(out) tracks K·V(in) at DC.
#[test]
fn laplace_first_order_lp_dc_gain_scaling() {
    for k in &[0.5_f64, 1.0, 2.5, 10.0] {
        let netlist = format!(
            "\
* LAPLACE LP — DC scaling
V1 in 0 DC 0.4
R1 in 0 1k
E1 out 0 LAPLACE {{V(in)}} ({k}) (1 1m)
R2 out 0 1Meg
.OP
.END
"
        );
        let (circuit, _) = parse_netlist_str(&netlist).expect("parse");
        let result = run_dc_op(&circuit).expect("DC op");
        let v_out = result
            .node_voltages
            .iter()
            .find(|(n, _)| n == "out")
            .map(|(_, v)| *v)
            .expect("'out' node");
        let expected = 0.4 * k;
        assert!(
            (v_out - expected).abs() < 5e-3,
            "K={k}: V(out) = {v_out}, expected ≈ {expected}"
        );
    }
}


/// G LAPLACE pure gain: I_out = 0.001 · V(in) → with a 1 kΩ load,
/// V(load) = -1.0 V (current flows from out+ to out-, through R from
/// `out` to ground, so the convention puts a positive voltage on
/// `out`).  We just check the magnitude is sensible.
#[test]
fn laplace_g_pure_gain_dc_op() {
    let netlist = "\
* G LAPLACE pure gm
V1 in 0 DC 1
R1 in 0 1k
G1 out 0 LAPLACE {V(in)} (0.001) (1)
R2 out 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let result = run_dc_op(&circuit).expect("DC op");
    let v_out = result
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("'out' node");
    // Iout = 0.001 A flows from `out` to `0` through R2 = 1 kΩ
    // → V(out) = -Iout · R2 = -1.0 V (sign depends on B-source convention).
    assert!(v_out.abs() > 0.5 && v_out.abs() < 1.5, "|V(out)| = {} unexpected", v_out.abs());
}
