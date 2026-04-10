//! Transmission line integration tests.
//!
//! Lossless T-line (Branin's method) end-to-end tests.

use pisim_test_harness::{parse_netlist_str, run_dc_op, run_transient};

/// Parse a T-line netlist and verify the circuit is constructed without error.
#[test]
fn tline_netlist_parses() {
    let netlist = "\
* Lossless T-line test
V1 1 0 DC 1
T1 1 0 2 0 Z0=50 TD=1n
R1 2 0 50
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), "T-line netlist failed to parse: {:?}", result.err());
    let (circuit, _) = result.unwrap();
    assert!(circuit.devices().len() >= 1, "Circuit has no devices");
}

/// DC operating point with a T-line converges without error.
///
/// At DC the delay history is empty (E=0), so the T-line companion sources
/// contribute zero.  The circuit should still converge.
#[test]
fn tline_dc_op_converges() {
    let netlist = "\
* T-line DC OP convergence
V1 in 0 DC 1
T1 in 0 out 0 Z0=50 TD=1n
R1 out 0 50
.DC V1 1 1 1
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    assert!(result.is_ok(), "T-line DC OP failed: {:?}", result.err());
}

/// Transient simulation with a T-line runs to completion.
///
/// Verifies that the stamper and history-update path execute for every
/// timestep without panicking or returning an error.
#[test]
fn tline_transient_runs() {
    let netlist = "\
* T-line transient
V1 src 0 PULSE(0 1 0 0.1n 0.1n 100n 200n)
R_s src in 50
T1 in 0 out 0 Z0=50 TD=2n
R_load out 0 50
.TRAN 0.1n 10n
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_transient(&circuit, 0.1e-9, 10e-9);
    assert!(result.is_ok(), "T-line transient failed: {:?}", result.err());
    let result = result.unwrap();
    assert!(result.times.len() >= 50, "expected >= 50 timesteps, got {}", result.times.len());
}

/// Parser accepts various keyword capitalisation and parameter orderings.
#[test]
fn tline_parse_case_variants() {
    let netlists = [
        "* lowercase z0/td\nV1 a 0 DC 1\nt1 a 0 b 0 z0=75 td=500p\nR1 b 0 75\n.OP\n.END\n",
        "* uppercase Z0/TD\nV1 a 0 DC 1\nT1 a 0 b 0 Z0=100 TD=1n\nR1 b 0 100\n.OP\n.END\n",
    ];
    for netlist in &netlists {
        let result = parse_netlist_str(netlist);
        assert!(result.is_ok(), "T-line parse failed:\n{netlist}\nError: {:?}", result.err());
    }
}
