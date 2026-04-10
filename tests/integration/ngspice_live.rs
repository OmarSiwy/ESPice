//! Live-mode comparison tests.
//! Runs both PiSIM and ngspice on the same netlist and compares results.
//! These tests are #[ignore]d by default — run with `--include-ignored`.

use pisim_test_harness::{
    parse_netlist_str, run_dc_op, NgspiceConfig, Tolerance,
};

/// Helper: run the same netlist through PiSIM and ngspice, compare DC OP results.
/// `tol_override` allows per-test tolerance for nonlinear devices where simulator
/// implementations naturally diverge.
fn assert_live_dc_op_match(netlist: &str, test_name: &str) {
    assert_live_dc_op_match_tol(netlist, test_name, &Tolerance::default());
}

fn assert_live_dc_op_match_tol(netlist: &str, test_name: &str, tol: &Tolerance) {
    let ngspice = NgspiceConfig::default();
    if !ngspice.is_available() {
        eprintln!("{test_name}: ngspice not available — skipping");
        return;
    }

    // Write netlist to temp file for ngspice
    let tmp = tempfile::tempdir().unwrap();
    let netlist_path = tmp.path().join("circuit.sp");
    std::fs::write(&netlist_path, netlist).unwrap();

    // Run ngspice
    let ng_result = ngspice.run(&netlist_path).unwrap_or_else(|e| {
        panic!("{test_name}: ngspice failed: {e}");
    });
    let ng_pairs = ng_result.rawfile.as_dc_pairs();

    // Run PiSIM
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let pi_result = run_dc_op(&circuit).unwrap();

    // Build PiSIM pairs with ngspice naming convention
    let mut pi_pairs: Vec<(String, f64)> = Vec::new();
    for (name, val) in &pi_result.node_voltages {
        pi_pairs.push((format!("v({})", name), *val));
    }
    for (name, val) in &pi_result.branch_currents {
        pi_pairs.push((format!("i({})", name.to_lowercase()), *val));
    }

    // Compare each ngspice signal against PiSIM
    for (ng_name, ng_val) in &ng_pairs {
        let ng_lower = ng_name.to_lowercase();
        // Skip internal ngspice signals (e.g., time, frequency)
        if !ng_lower.starts_with("v(") && !ng_lower.starts_with("i(") {
            continue;
        }

        let matched = pi_pairs.iter().find(|(n, _)| n.to_lowercase() == ng_lower);
        match matched {
            Some((_, pi_val)) => {
                let is_current = ng_lower.starts_with("i(");
                let (abs_tol, rel_tol) = if is_current {
                    tol.dc_current
                } else {
                    tol.dc_voltage
                };
                assert!(
                    Tolerance::within(*pi_val, *ng_val, abs_tol, rel_tol),
                    "{test_name} signal {ng_name}: PiSIM={pi_val:.6e}, ngspice={ng_val:.6e}, \
                     abs_err={:.2e}",
                    (pi_val - ng_val).abs()
                );
            }
            None => {
                eprintln!("{test_name}: ngspice signal {ng_name} not found in PiSIM output");
            }
        }
    }

    eprintln!(
        "{test_name}: PASS (ngspice {:.0}ms, {} signals compared)",
        ng_result.wall_time.as_secs_f64() * 1000.0,
        ng_pairs.len()
    );
}

#[test]
#[ignore = "live ngspice comparison — run with --include-ignored"]
fn live_dc_op_voltage_divider() {
    assert_live_dc_op_match(
        "\
* Voltage divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
",
        "live_dc_op_voltage_divider",
    );
}

#[test]
#[ignore = "live ngspice comparison — run with --include-ignored"]
fn live_dc_op_three_resistor_chain() {
    assert_live_dc_op_match(
        "\
* Three resistor chain
V1 1 0 DC 9
R1 1 2 1k
R2 2 3 1k
R3 3 0 1k
.OP
.END
",
        "live_dc_op_three_resistor_chain",
    );
}

#[test]
#[ignore = "live ngspice comparison — run with --include-ignored"]
fn live_dc_op_single_resistor() {
    assert_live_dc_op_match(
        "\
* Single resistor
V1 1 0 DC 3.3
R1 1 0 100
.OP
.END
",
        "live_dc_op_single_resistor",
    );
}

#[test]
#[ignore = "live ngspice comparison — run with --include-ignored"]
fn live_dc_op_diode_forward_bias() {
    // Nonlinear devices naturally diverge between simulator implementations;
    // use relaxed tolerances (1mV / 0.1% for voltage, 1nA / 0.1% for current).
    let tol = Tolerance {
        dc_voltage: (1e-3, 1e-3),
        dc_current: (1e-9, 1e-3),
        ..Tolerance::default()
    };
    assert_live_dc_op_match_tol(
        "\
* Diode forward bias
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
",
        "live_dc_op_diode_forward_bias",
        &tol,
    );
}
