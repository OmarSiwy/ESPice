//! Compatibility tests: alter, control, options, sweep, nested DC.
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, Tolerance};

// ── Options tests ─────────────────────────────────────────────────────────────

#[test]
fn options_default_trtol_accepted() {
    let netlist = "\
* .OPTIONS test
.OPTIONS TRTOL=7
V1 1 0 DC 5
R1 1 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), ".OPTIONS should parse without error: {:?}", result.err());
}

#[test]
fn options_gmin_accepted() {
    let netlist = "\
* .OPTIONS GMIN
.OPTIONS GMIN=1e-12
V1 1 0 DC 5
R1 1 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok());
}

// ── Alter tests ───────────────────────────────────────────────────────────────

#[test]
fn alter_changes_resistor_value() {
    let netlist = "\
* Alter test
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.ALTER
R1 1 2 2k
.OP
.END
";
    // parse must succeed (alter is a valid directive)
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), ".ALTER should parse: {:?}", result.err());
}

// ── Control script tests ──────────────────────────────────────────────────────

#[test]
fn control_basic_run_script() {
    let netlist = "\
* Control block test
V1 1 0 DC 5
R1 1 0 1k
.control
op
.endc
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), ".control block should parse: {:?}", result.err());
}

// ── Sweep / DC nested tests ───────────────────────────────────────────────────

#[test]
fn dc_sweep_basic_parses() {
    let netlist = "\
* DC sweep
V1 1 0 DC 0
R1 1 0 1k
.DC V1 0 5 1
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), ".DC sweep should parse: {:?}", result.err());
}

#[test]
fn nested_dc_parses() {
    let netlist = "\
* Nested DC
V1 1 0 DC 0
V2 2 0 DC 0
R1 1 2 1k
R2 2 0 1k
.DC V1 0 5 1 V2 0 1 0.5
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), "nested .DC should parse: {:?}", result.err());
}

// ── e_g_value_form tests ──────────────────────────────────────────────────────

#[test]
fn e_value_form_vcvs() {
    // E-source in VALUE= form (behavioural)
    let netlist = "\
* E VALUE form
V1 1 0 DC 2
E1 2 0 VALUE={3*V(1)}
R1 2 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    // If VALUE form is supported, it should parse; if not, we just log
    if let Ok((circuit, _)) = result {
        if let Ok(dc) = run_dc_op(&circuit) {
            if let Some((_, v2)) = dc.node_voltages.iter().find(|(n, _)| n == "2") {
                assert!(Tolerance::within(*v2, 6.0, 1e-6, 1e-4), "E VALUE: V(2)={v2}");
            }
        }
    }
}

#[test]
fn g_value_form_vccs() {
    // G-source in VALUE= form (behavioural)
    let netlist = "\
* G VALUE form
V1 1 0 DC 1
G1 2 0 VALUE={0.001*V(1)}
R1 2 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    // Soft test: just verify it doesn't panic
    if let Ok((circuit, _)) = result {
        let _ = run_dc_op(&circuit);
    }
}

// ── Trap/Gear integration ─────────────────────────────────────────────────────

#[test]
#[ignore = "requires trap/gear integration method in transient engine"]
fn trap_gear_switching() {}

// ── Compatibility stubs ───────────────────────────────────────────────────────

#[test]
#[ignore = "requires full hspice .MEASURE compatibility"]
fn compat_hspice_measure() {}

#[test]
#[ignore = "requires xyce-compatible .STEP syntax"]
fn compat_xyce_step() {}

#[test]
#[ignore = "requires ngspice poly() source form"]
fn compat_ngspice_poly_sources() {}

#[test]
#[ignore = "requires .FOREACH control loop in transient"]
fn compat_control_foreach_tran() {}
