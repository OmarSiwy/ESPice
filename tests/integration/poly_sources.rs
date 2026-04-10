//! POLY(n) polynomial controlled-source integration tests.
//!
//! Tests cover:
//! - VCVS (E) and VCCS (G) with POLY(1) linear, quadratic
//! - VCVS with POLY(2) cross-term
//! - Legacy opamp macromodel-style E POLY(1) feedback

use pisim_test_harness::{parse_netlist_str, run_dc_op};

// ── POLY(1) VCVS linear: E n+ n- POLY(1) (vc+ vc-) c0 c1 → Vout = c1*Vin ───

#[test]
fn poly1_vcvs_linear() {
    // E1 with POLY(1), c0=0, c1=2.0: Vout = 2*Vin
    // Vin = 3V → Vout should be 6V
    let netlist = "\
* POLY(1) VCVS linear gain=2
V1 1 0 DC 3
E1 2 0 POLY(1) (1 0) 0 2
R1 2 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(
        (v2 - 6.0).abs() < 1e-6,
        "poly1_vcvs_linear: V(2)={v2}, expected 6.0"
    );
}

// ── POLY(1) VCVS quadratic: c0=0, c1=0, c2=1 → Vout = Vin^2 ────────────────

#[test]
fn poly1_vcvs_quadratic() {
    // E1 with POLY(1), c0=0, c1=0, c2=1.0: Vout = Vin^2
    // Vin = 2V → Vout should be 4V
    let netlist = "\
* POLY(1) VCVS quadratic
V1 1 0 DC 2
E1 2 0 POLY(1) (1 0) 0 0 1
R1 2 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(
        (v2 - 4.0).abs() < 1e-4,
        "poly1_vcvs_quadratic: V(2)={v2}, expected 4.0"
    );
}

// ── POLY(1) VCCS linear: G n+ n- POLY(1) (vc+ vc-) c0 c1 → Iout = c1*Vin ───

#[test]
fn poly1_vccs_linear() {
    // G1 with POLY(1), c0=0, c1=0.01: Iout = 0.01*Vin
    // Vin = 5V, Rload = 1k → Vout = Iout * Rload = 0.01*5*1000 = 50V
    let netlist = "\
* POLY(1) VCCS linear gm=0.01
V1 1 0 DC 5
G1 2 0 POLY(1) (1 0) 0 0.01
R1 2 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    // Iout = 0.01 * 5 = 0.05 A, V(2) = 0.05 * 1000 = 50V
    assert!(
        (v2 - 50.0).abs() < 1e-6,
        "poly1_vccs_linear: V(2)={v2}, expected 50.0"
    );
}

// ── POLY(2) VCVS cross-term: c4=1 → Vout = x1*x2 ────────────────────────────

#[test]
fn poly2_vcvs_cross() {
    // E1 with POLY(2), only c4=1.0 (x1*x2 term):
    //   monomials: c0, c1*x1, c2*x2, c3*x1^2, c4*x1*x2, c5*x2^2
    //   coeffs:     0    0      0       0        1.0       0
    // V1=2, V2=3 → Vout = 2*3 = 6
    let netlist = "\
* POLY(2) VCVS cross term x1*x2
V1 1 0 DC 2
V2 3 0 DC 3
E1 2 0 POLY(2) (1 0) (3 0) 0 0 0 0 1 0
R1 2 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(
        (v2 - 6.0).abs() < 1e-5,
        "poly2_vcvs_cross: V(2)={v2}, expected 6.0"
    );
}

// ── Legacy opamp macromodel: E POLY(1) for unity-gain feedback ───────────────

#[test]
fn poly1_vcvs_opamp_macromodel() {
    // Simplified LM741-style macromodel:
    //   Rin = 1Meg between v+ and v-
    //   Eout = POLY(1) (vplus vminus) 0 200000   (open-loop gain = 200k)
    //   Rout = 75 ohm
    //   Unity-gain buffer: vout connected back to v-.
    //
    // With Vin=1V at v+, v- tied to vout through Rf=Rout:
    //   Vout ≈ Vin * Aol / (1 + Aol) ≈ Vin for large Aol
    let netlist = "\
* Simplified opamp unity-gain buffer via POLY(1)
* v+ = node 1, v- = node 2 (= output through Rfb), vout = node 3
Vin 1 0 DC 1
Rin 1 2 1meg
Eout 3 0 POLY(1) (1 2) 0 200k
Rout 3 2 75
R1 2 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let vout = result.node_voltages.iter().find(|(n, _)| n == "3").unwrap().1;
    // Unity-gain buffer: Vout ≈ Vin = 1V (within 0.001% for Aol=200k)
    assert!(
        (vout - 1.0).abs() < 0.01,
        "poly1_vcvs_opamp_macromodel: Vout={vout}, expected ~1.0"
    );
}
