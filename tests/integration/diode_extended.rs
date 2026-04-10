//! Extended diode model integration tests.
//!
//! Covers Zener breakdown, area scaling, and forward-bias DC operating point
//! using the full netlist → parse → solve pipeline.

use pisim_test_harness::{parse_netlist_str, run_dc_op};

/// Basic forward-bias OP with D1N4148-like parameters.
/// Verifies the solver converges and the forward current matches a hand-calc.
///
/// Circuit: V1(5V) → R1(1kΩ) → D1(anode) → GND
/// At convergence: V(anode) ≈ 0.6–0.7 V, I ≈ (5 - Vf) / 1kΩ ≈ 4.3–4.4 mA.
#[test]
fn diode_d1n4148_dc_op_converges() {
    let netlist = "\
* D1N4148-like diode forward bias
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 D1N4148
.MODEL D1N4148 D (Is=2.5e-9 N=1.9 BV=75 IBV=1e-5)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let vf = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;

    // Forward voltage must be in physically meaningful range.
    assert!(
        vf > 0.3 && vf < 1.0,
        "V(anode) = {vf}, expected 0.3–1.0 V for D1N4148 forward bias"
    );

    // Forward current: I = (V1 - Vf) / R1.  With N=1.9 the threshold is higher
    // than ideal silicon, but still a few mA at 5 V through 1 kΩ.
    let i_fwd = (5.0 - vf) / 1e3;
    assert!(
        i_fwd > 1e-3 && i_fwd < 10e-3,
        "I_fwd = {i_fwd} A, expected 1–10 mA"
    );

    // Cross-check that the diode current (from Shockley) matches the resistor
    // current to within 0.1 % (KCL at node 2).
    let is = 2.5e-9_f64;
    let n  = 1.9_f64;
    // Use the DEFAULT_VT path (no temp override in the netlist).
    let nvt = n * 0.02585;
    let id_shockley = is * ((vf / nvt).exp() - 1.0);
    let rel_err = (id_shockley - i_fwd).abs() / i_fwd.abs().max(1e-9);
    assert!(
        rel_err < 0.01,
        "KCL mismatch: Id(Shockley)={id_shockley:.6e}, I_resistor={i_fwd:.6e}, rel_err={rel_err:.4}"
    );
}

/// Zener regulator: 12 V source → 1 kΩ → Zener(BV=5.1) → GND.
/// The Zener clamps the output node to ≈ BV.
#[test]
fn zener_regulator_clamps_at_bv() {
    let netlist = "\
* Zener regulator
V1 1 0 DC 12
R1 1 2 1k
D1 0 2 ZMOD
.MODEL ZMOD D (Is=1e-14 N=1 BV=5.1 IBV=1e-4)
.OP
.END
";
    // The Zener anode is GND (0), cathode is node 2.
    // In reverse breakdown the cathode-to-anode voltage is BV, so V(2) ≈ BV.
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;

    // Should clamp within ±0.5 V of BV = 5.1 V.
    assert!(
        (v2 - 5.1).abs() < 0.5,
        "Zener regulator: V(2) = {v2}, expected ≈ 5.1 V (BV)"
    );
    // Must be well below the 12 V supply.
    assert!(v2 < 11.0, "V(2) = {v2} not clamped, expected < 11 V");
}

/// Area scaling: same circuit twice with area=1 and area=10.
/// The diode with area=10 should carry ~10× the current at the same voltage,
/// shifting the node voltage upward (more current through the resistor).
#[test]
fn area_scaling_increases_current() {
    let netlist_base = "\
* Area = 1
V1 1 0 DC 1
R1 1 2 10k
D1 2 0 DMOD
.MODEL DMOD D (Is=1e-14 N=1 area=1)
.OP
.END
";
    let netlist_10x = "\
* Area = 10
V1 1 0 DC 1
R1 1 2 10k
D1 2 0 DMOD
.MODEL DMOD D (Is=1e-14 N=1 area=10)
.OP
.END
";
    let (c1, _) = parse_netlist_str(netlist_base).unwrap();
    let (c10, _) = parse_netlist_str(netlist_10x).unwrap();

    let r1  = run_dc_op(&c1).unwrap();
    let r10 = run_dc_op(&c10).unwrap();

    let vf1  = r1.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    let vf10 = r10.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;

    // Larger area → lower Vf (more current capacity at the same voltage, so
    // the DC OP settles at a lower forward voltage for the same supply).
    // Both must be in a valid forward-bias range.
    assert!(
        vf1  > 0.0 && vf1  < 1.0,
        "area=1:  V(2) = {vf1}"
    );
    assert!(
        vf10 > 0.0 && vf10 < 1.0,
        "area=10: V(2) = {vf10}"
    );

    // With 10× area the diode conducts the same current at ~N*Vt*ln(10) ≈ 59 mV
    // lower voltage.  The node voltage should be noticeably lower for area=10.
    assert!(
        vf10 < vf1,
        "area=10 Vf ({vf10}) should be lower than area=1 Vf ({vf1})"
    );

    // The resistor current for area=10 should be higher (lower Vf → more drop
    // across R1? No — lower Vf means less drop across R1, hence LESS current).
    // Actually: I = (Vsup - Vf)/R, so lower Vf → higher I.  Verify.
    let i1  = (1.0 - vf1)  / 10e3;
    let i10 = (1.0 - vf10) / 10e3;
    assert!(
        i10 > i1,
        "area=10 current ({i10:.3e}) should exceed area=1 current ({i1:.3e})"
    );
}

/// Temperature sweep golden test: diode forward voltage drops with temperature.
///
/// Circuit: 5 V supply → 1 kΩ → D1 → GND.
/// At 27°C (Tnom): V(anode) ≈ 0.5–0.7 V.
/// At 100°C: Is is ~8000× larger, so the diode conducts the same current at
/// a significantly lower forward voltage.  Expect Vf(100°C) < Vf(27°C) - 0.05 V.
#[test]
fn temperature_forward_voltage_decreases_with_temp() {
    let netlist_27 = "\
* Diode at 27C (tnom = 300.15 K)
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (Is=1e-14 N=1 temp=300.15 tnom=300.15)
.OP
.END
";
    let netlist_100 = "\
* Diode at 100C (temp = 373.15 K)
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (Is=1e-14 N=1 temp=373.15 tnom=300.15)
.OP
.END
";
    let (c27,  _) = parse_netlist_str(netlist_27).unwrap();
    let (c100, _) = parse_netlist_str(netlist_100).unwrap();

    let r27  = run_dc_op(&c27).unwrap();
    let r100 = run_dc_op(&c100).unwrap();

    let vf27  = r27.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    let vf100 = r100.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;

    // Both must be valid forward-bias voltages.
    assert!(vf27  > 0.1 && vf27  < 1.0, "27°C:  Vf={vf27}");
    assert!(vf100 > 0.1 && vf100 < 1.0, "100°C: Vf={vf100}");

    // The higher-temperature diode must have a noticeably lower forward voltage
    // (standard dVf/dT ≈ -2 mV/°C; 73°C difference → ~146 mV drop).
    assert!(
        vf100 < vf27 - 0.05,
        "Vf at 100°C ({vf100:.4}) should be at least 50 mV below Vf at 27°C ({vf27:.4})"
    );
}

/// M=2 multiplier golden test: two parallel diodes (M=2) vs a single diode
/// through equal resistors from the same supply.
///
/// Circuit: 2 V → 500 Ω → D1 → GND, with M=1 vs M=2.
/// With M=2 the effective Is doubles, so Vf(M=2) < Vf(M=1) and the resistor
/// current I=(2-Vf)/500 is higher for M=2.
#[test]
fn m_multiplier_golden_lower_vf_and_higher_current() {
    let netlist_m1 = "\
* M=1 baseline
V1 1 0 DC 2
R1 1 2 500
D1 2 0 DMOD
.MODEL DMOD D (Is=1e-14 N=1 m=1)
.OP
.END
";
    let netlist_m2 = "\
* M=2 parallel multiplier
V1 1 0 DC 2
R1 1 2 500
D1 2 0 DMOD
.MODEL DMOD D (Is=1e-14 N=1 m=2)
.OP
.END
";
    let (c1, _) = parse_netlist_str(netlist_m1).unwrap();
    let (c2, _) = parse_netlist_str(netlist_m2).unwrap();

    let r1 = run_dc_op(&c1).unwrap();
    let r2 = run_dc_op(&c2).unwrap();

    let vf1 = r1.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    let vf2 = r2.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;

    assert!(vf1 > 0.1 && vf1 < 1.0, "M=1: Vf={vf1}");
    assert!(vf2 > 0.1 && vf2 < 1.0, "M=2: Vf={vf2}");

    // M=2 → lower forward voltage.
    assert!(
        vf2 < vf1,
        "M=2 Vf ({vf2:.4}) should be below M=1 Vf ({vf1:.4})"
    );

    // M=2 → higher resistor current (lower Vf → larger (V1-Vf)/R).
    let i1 = (2.0 - vf1) / 500.0;
    let i2 = (2.0 - vf2) / 500.0;
    assert!(
        i2 > i1,
        "M=2 current ({i2:.4e}) should exceed M=1 current ({i1:.4e})"
    );
}
