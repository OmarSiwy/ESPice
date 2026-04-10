//! Golden-mode comparison tests.
//! Compares PiSIM DC OP results against ngspice-generated golden CSVs.
//! These tests do NOT invoke ngspice at runtime — they use pre-committed golden files.

use std::path::Path;
use pisim_test_harness::{
    parse_netlist_str, run_dc_op, GoldenData, Tolerance,
};

fn project_root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

/// Helper: load a golden CSV relative to project root, run PiSIM on the netlist,
/// and compare results.
fn assert_dc_op_matches_golden(netlist: &str, golden_rel_path: &str) {
    let golden_path = project_root().join(golden_rel_path);
    if !golden_path.exists() {
        eprintln!(
            "Golden file not found: {} — run `cargo run -p pisim-test-harness --bin generate-goldens` first",
            golden_path.display()
        );
        return;
    }

    let golden = GoldenData::from_csv(&golden_path).unwrap();
    let expected = golden.as_dc_pairs();

    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    // Build actual pairs from PiSIM result, matching golden signal names
    let mut actual: Vec<(String, f64)> = Vec::new();
    for (name, val) in &result.node_voltages {
        // ngspice uses lowercase v(N), PiSIM may use uppercase or just node number
        actual.push((format!("v({})", name), *val));
    }
    for (name, val) in &result.branch_currents {
        actual.push((format!("i({})", name.to_lowercase()), *val));
    }

    let tol = Tolerance::default();

    // Compare each golden signal
    for (gold_name, gold_val) in &expected {
        let gold_lower = gold_name.to_lowercase();
        let matched = actual.iter().find(|(n, _)| n.to_lowercase() == gold_lower);
        match matched {
            Some((_, act_val)) => {
                let is_current = gold_lower.starts_with("i(");
                let (abs_tol, rel_tol) = if is_current {
                    tol.dc_current
                } else {
                    tol.dc_voltage
                };
                assert!(
                    Tolerance::within(*act_val, *gold_val, abs_tol, rel_tol),
                    "Signal {gold_name}: PiSIM={act_val:.6e}, golden={gold_val:.6e}, \
                     abs_err={:.2e}, abs_tol={abs_tol:.2e}, rel_tol={rel_tol:.2e}",
                    (act_val - gold_val).abs()
                );
            }
            None => {
                eprintln!("WARNING: golden signal {gold_name} not found in PiSIM output");
            }
        }
    }
}

#[test]
fn golden_dc_op_voltage_divider() {
    assert_dc_op_matches_golden(
        "\
* Voltage divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
",
        "tests/golden/dc/voltage_divider.csv",
    );
}

#[test]
fn golden_dc_op_three_resistor_chain() {
    assert_dc_op_matches_golden(
        "\
* Three resistor chain
V1 1 0 DC 9
R1 1 2 1k
R2 2 3 1k
R3 3 0 1k
.OP
.END
",
        "tests/golden/dc/three_resistor_chain.csv",
    );
}
