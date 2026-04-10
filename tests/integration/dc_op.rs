//! DC Operating Point integration tests.

use pisim_test_harness::{
    parse_netlist_str, run_dc_op, GoldenData, compare_dc_values, Tolerance,
};
use std::path::Path;

// ---- Active tests: implemented features ----

#[test]
fn dc_op_voltage_divider_analytical() {
    let netlist = "\
* Voltage divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!((v2 - 2.5).abs() < 1e-9, "V(2) = {v2}, expected 2.5");

    let iv1 = result.branch_currents.iter().find(|(n, _)| n.to_lowercase() == "v1").unwrap().1;
    assert!((iv1 + 0.0025).abs() < 1e-12, "I(V1) = {iv1}, expected -0.0025");
}

#[test]
fn dc_op_voltage_divider_vs_golden() {
    let netlist = "\
* Voltage divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let golden_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden/dc/voltage_divider.csv");
    if golden_path.exists() {
        let golden = GoldenData::from_csv(&golden_path).unwrap();
        let expected = golden.as_dc_pairs();

        for (name, exp_val) in &expected {
            if name.starts_with("I(") {
                let iv1 = result.branch_currents[0].1;
                assert!(
                    Tolerance::within(iv1, *exp_val, 1e-15, 1e-6),
                    "{name}: actual={iv1}, expected={exp_val}"
                );
            }
        }
    }
}

#[test]
fn dc_op_three_resistor_chain() {
    let netlist = "\
* Three resistor chain
V1 1 0 DC 9
R1 1 2 1k
R2 2 3 1k
R3 3 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v1 = result.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    let v3 = result.node_voltages.iter().find(|(n, _)| n == "3").unwrap().1;
    assert!((v1 - 9.0).abs() < 1e-9, "V(1) = {v1}");
    assert!((v2 - 6.0).abs() < 1e-9, "V(2) = {v2}");
    assert!((v3 - 3.0).abs() < 1e-9, "V(3) = {v3}");
}

#[test]
fn dc_op_single_resistor() {
    let netlist = "\
* Single resistor
V1 1 0 DC 3.3
R1 1 0 100
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v1 = result.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    assert!((v1 - 3.3).abs() < 1e-9);

    let iv = result.branch_currents[0].1;
    assert!((iv + 0.033).abs() < 1e-9, "I(V1) = {iv}");
}

#[test]
fn dc_op_cmos_inverter() {
    let netlist = "\
* CMOS Inverter
VDD vdd 0 DC 3.3
VIN in 0 DC 0.7
M1 out in 0 0 NMOD W=10u L=1u
M2 out in vdd vdd PMOD W=20u L=1u
.MODEL NMOD NMOS (VTH0=0.5 KP=120u)
.MODEL PMOD PMOS (VTH0=-0.5 KP=60u)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let vout = result.node_voltages.iter().find(|(n, _)| n == "out").unwrap().1;
    assert!(vout < 3.3, "Vout={vout} should be less than VDD");
    assert!(vout >= 0.0, "Vout={vout} should be non-negative");
}

#[test]
fn dc_op_diode_circuit() {
    let netlist = "\
* Diode forward bias
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(v2 > 0.4 && v2 < 0.9, "V(2) = {v2}, expected ~0.6-0.7V for forward-biased diode");
}

#[test]
fn dc_op_vcvs_gain() {
    let netlist = "\
* VCVS with gain=10
V1 1 0 DC 1
R1 1 0 1k
E1 3 0 1 0 10
R2 3 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let v1 = result.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    let v3 = result.node_voltages.iter().find(|(n, _)| n == "3").unwrap().1;
    assert!((v1 - 1.0).abs() < 1e-9, "V(1) = {v1}");
    assert!((v3 - 10.0).abs() < 1e-9, "V(3) = {v3}, expected 10.0 (gain=10)");
}

#[test]
fn dc_op_vccs_transconductance() {
    let netlist = "\
* VCCS with gm=0.001
V1 1 0 DC 1
G1 2 0 1 0 0.001
R1 2 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    // SPICE convention: G1 2 0 1 0 gm → current flows from N+(2) to N-(0),
    // so 1mA exits node 2. With R1=1k to ground: V(2) = -1.0V.
    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!((v2 - (-1.0)).abs() < 1e-6, "V(2) = {v2}, expected -1.0V");
}

// ---- Ignored tests: unimplemented features ----

#[test]
#[ignore = "requires BSIM4 model implementation"]
fn dc_op_bsim4_nmos_iv() {
    let netlist = std::fs::read_to_string("tests/fixtures/cmc/bsim4_nmos_iv.sp")
        .expect("fixture file missing");
    let (circuit, _) = parse_netlist_str(&netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    let golden = GoldenData::from_csv(Path::new("tests/golden/dc/bsim4_nmos_iv.csv")).unwrap();
    let expected = golden.as_dc_pairs();
    let actual: Vec<(String, f64)> = result.node_voltages.clone();
    let cmp = compare_dc_values(&actual, &expected, &Tolerance::default(), false);
    assert!(cmp.passed, "BSIM4 NMOS I-V mismatch: {:?}", cmp.failing_points);
}

#[test]
#[ignore = "requires BSIM-CMG (FinFET) model implementation"]
fn dc_op_bsimcmg_finfet() {
    let (circuit, _) = parse_netlist_str("* placeholder\n.END\n").unwrap();
    let _result = run_dc_op(&circuit);
}

#[test]
#[ignore = "requires PSP103 model implementation"]
fn dc_op_psp103_mosfet() {
    let (circuit, _) = parse_netlist_str("* placeholder\n.END\n").unwrap();
    let _result = run_dc_op(&circuit);
}

#[test]
#[ignore = "requires HICUM L2 model implementation"]
fn dc_op_hicum_l2_bjt() {
    let (circuit, _) = parse_netlist_str("* placeholder\n.END\n").unwrap();
    let _result = run_dc_op(&circuit);
}

#[test]
#[ignore = "requires MEXTRAM 505 model implementation"]
fn dc_op_mextram_505_bjt() {
    let (circuit, _) = parse_netlist_str("* placeholder\n.END\n").unwrap();
    let _result = run_dc_op(&circuit);
}
