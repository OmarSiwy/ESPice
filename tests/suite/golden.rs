//! Golden comparison tests: ngspice, temperature, device goldens.
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, NgspiceConfig, GoldenData, Tolerance};
use std::path::Path;

/// Helper: run bigospice DC OP and compare named node voltages.
fn assert_dc_nodes(netlist: &str, expected: &[(&str, f64)], abs_tol: f64, rel_tol: f64) {
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    for (node, exp_val) in expected {
        let actual = result.node_voltages.iter()
            .find(|(n, _)| n.to_lowercase() == node.to_lowercase())
            .map(|(_, v)| *v)
            .unwrap_or_else(|| panic!("node {node} not in result"));
        assert!(
            Tolerance::within(actual, *exp_val, abs_tol, rel_tol),
            "V({node}): actual={actual:.6e}, expected={exp_val:.6e}"
        );
    }
}

// ── Self-contained golden (no ngspice required) ───────────────────────────────

#[test]
fn golden_voltage_divider_dc_op() {
    assert_dc_nodes(
        "* Voltage divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n",
        &[("1", 5.0), ("2", 2.5)],
        1e-9, 1e-6,
    );
}

#[test]
fn golden_three_resistor_chain() {
    assert_dc_nodes(
        "* Three resistors\nV1 1 0 DC 9\nR1 1 2 1k\nR2 2 3 1k\nR3 3 0 1k\n.OP\n.END\n",
        &[("1", 9.0), ("2", 6.0), ("3", 3.0)],
        1e-9, 1e-6,
    );
}

#[test]
fn golden_vcvs_gain10() {
    assert_dc_nodes(
        "* VCVS\nV1 1 0 DC 1\nR1 1 0 1k\nE1 3 0 1 0 10\nR2 3 0 1k\n.OP\n.END\n",
        &[("1", 1.0), ("3", 10.0)],
        1e-9, 1e-6,
    );
}

#[test]
fn golden_csv_file_if_exists() {
    let golden_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden/dc/voltage_divider.csv");
    if !golden_path.exists() {
        eprintln!("golden CSV not present — skipping file comparison");
        return;
    }
    let golden = GoldenData::from_csv(&golden_path).unwrap();
    let netlist = "* Voltage divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    for (name, exp_val) in golden.as_dc_pairs() {
        if name.starts_with("V(") || name.starts_with("v(") {
            let node = name.trim_start_matches("V(").trim_start_matches("v(").trim_end_matches(')');
            if let Some((_, actual)) = result.node_voltages.iter().find(|(n, _)| n == node) {
                assert!(Tolerance::within(*actual, exp_val, 1e-9, 1e-6),
                    "{name}: actual={actual}, expected={exp_val}");
            }
        }
    }
}

// ── ngspice live golden tests ─────────────────────────────────────────────────

#[test]
#[ignore = "requires ngspice on PATH"]
fn ngspice_golden_voltage_divider() {
    let config = NgspiceConfig::default();
    if !config.is_available() {
        eprintln!("ngspice not available — skipping");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("divider.sp");
    std::fs::write(&path, "* Voltage divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n").unwrap();
    let ng = config.run(&path).unwrap();
    let pairs = ng.rawfile.as_dc_pairs();
    let v2 = pairs.iter().find(|(n, _)| n.to_lowercase() == "v(2)").unwrap().1;
    let (circuit, _) = parse_netlist_str("* Voltage divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n").unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let pi_v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(Tolerance::within(pi_v2, v2, 1e-6, 1e-4),
        "BigOSpice V(2)={pi_v2} vs ngspice V(2)={v2}");
}

#[test]
#[ignore = "requires ngspice on PATH"]
fn ngspice_golden_diode_circuit() {
    let config = NgspiceConfig::default();
    if !config.is_available() {
        eprintln!("ngspice not available — skipping");
        return;
    }
    let netlist = "\
* Diode forward bias
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
";
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("diode.sp");
    std::fs::write(&path, netlist).unwrap();
    let ng = config.run(&path).unwrap();
    let ng_pairs = ng.rawfile.as_dc_pairs();
    let ng_v2 = ng_pairs.iter().find(|(n, _)| n.to_lowercase() == "v(2)").unwrap().1;

    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let pi_v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;

    assert!(Tolerance::within(pi_v2, ng_v2, 1e-4, 1e-3),
        "Diode V(2): BigOSpice={pi_v2:.4} vs ngspice={ng_v2:.4}");
}

// ── VACASK live golden tests ──────────────────────────────────────────────────

#[test]
#[ignore = "requires vacask on PATH"]
fn vacask_golden_voltage_divider() {
    let config = common::VacaskConfig::default();
    if !config.is_available() {
        eprintln!("vacask not available — skipping");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("divider.sp");
    std::fs::write(&path, "* Voltage divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n").unwrap();
    let va = config.run(&path).unwrap();
    let va_v2 = va.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    let (circuit, _) = parse_netlist_str("* Voltage divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n").unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let pi_v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(Tolerance::within(pi_v2, va_v2, 1e-6, 1e-4),
        "BigOSpice V(2)={pi_v2} vs vacask V(2)={va_v2}");
}

// ── Xyce live golden tests ────────────────────────────────────────────────────

#[test]
#[ignore = "requires Xyce on PATH"]
fn xyce_golden_voltage_divider() {
    let config = common::XyceConfig::default();
    if !config.is_available() {
        eprintln!("Xyce not available — skipping");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("divider.sp");
    std::fs::write(&path, "* Voltage divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n").unwrap();
    let xy = config.run(&path).unwrap();
    let xy_v2 = xy.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    let (circuit, _) = parse_netlist_str("* Voltage divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n").unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let pi_v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(Tolerance::within(pi_v2, xy_v2, 1e-6, 1e-4),
        "BigOSpice V(2)={pi_v2} vs Xyce V(2)={xy_v2}");
}

#[test]
#[ignore = "requires temperature sweep implementation"]
fn temperature_golden_resistor_tc() {}

#[test]
#[ignore = "requires BSIM4 model and ngspice golden"]
fn bsim4_golden_iv_curve() {}

#[test]
#[ignore = "requires BJT Gummel-Poon and ngspice golden"]
fn bjt_golden_gummel_plot() {}
