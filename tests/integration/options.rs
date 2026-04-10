//! Integration tests for `.OPTIONS` plumbing through the solver stack.

use pisim_core::SimOptions;
use pisim_device::DeviceRegistry;
use pisim_parser::SpiceParser;
use pisim_solver::{ConvergenceCriteria, NrConfig};
use pisim_analysis::{run_dc_op_with_options, run_transient_with_options, TransientConfig};

/// Verify that `.OPTIONS` tolerances are correctly mapped into `NrConfig` /
/// `ConvergenceCriteria` and that a DC OP on a simple resistive divider still
/// converges with the injected (tighter) values.
#[test]
fn options_plumbing_dc_op_converges() {
    let netlist = "\
* Resistive divider with explicit OPTIONS
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OPTIONS abstol=1e-10 reltol=1e-5 gmin=1e-9 itl1=50 method=trap
.OP
.END
";
    let (_circuit, _analyses, opts) = SpiceParser::parse(netlist).unwrap();

    // Verify the parser populated the options correctly.
    assert_eq!(opts.abstol, 1e-10, "abstol");
    assert_eq!(opts.reltol, 1e-5,  "reltol");
    assert_eq!(opts.gmin,   1e-9,  "gmin");
    assert_eq!(opts.itl1,   50,    "itl1");

    // Verify that ConvergenceCriteria reflects the injected values.
    let criteria = ConvergenceCriteria::from(&opts);
    assert_eq!(criteria.abs_tol,  1e-10);
    assert_eq!(criteria.rel_tol,  1e-5);
    assert_eq!(criteria.max_iter, 50);

    // Verify that NrConfig carries the voltage step and gmin floor.
    let nr = NrConfig::from(&opts);
    assert_eq!(nr.convergence.abs_tol, 1e-10);
    // gmin_floor = max(opts.gmin, DEFAULT_GMIN_FLOOR=1e-9) = 1e-9
    assert!((nr.gmin_floor - 1e-9).abs() < 1e-20, "gmin_floor={}", nr.gmin_floor);

    // Run the analysis through the full stack and verify the result.
    let (circuit, _analyses, opts2) = SpiceParser::parse(netlist).unwrap();
    let registry = DeviceRegistry::new_default();
    let output = run_dc_op_with_options(&circuit, &registry, &opts2).unwrap();

    let v2 = output.result.node_voltages.iter()
        .find(|(n, _)| n == "2")
        .unwrap()
        .1;
    assert!((v2 - 2.5).abs() < 1e-6, "V(2) = {v2}, expected 2.5");
}

/// Verify that omitting `.OPTIONS` keeps default behaviour (regression test).
#[test]
fn options_absent_uses_defaults() {
    let netlist = "\
* No OPTIONS — should use default tolerances
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (_circuit, _analyses, opts) = SpiceParser::parse(netlist).unwrap();
    let default = SimOptions::default();

    assert_eq!(opts.abstol, default.abstol);
    assert_eq!(opts.reltol, default.reltol);
    assert_eq!(opts.itl1,   default.itl1);

    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let registry = DeviceRegistry::new_default();
    let output = run_dc_op_with_options(&circuit, &registry, &SimOptions::default()).unwrap();

    let v2 = output.result.node_voltages.iter()
        .find(|(n, _)| n == "2")
        .unwrap()
        .1;
    assert!((v2 - 2.5).abs() < 1e-6, "V(2) = {v2}");
}

/// Verify that `.OPTIONS method=gear` produces a clear error.
#[test]
fn options_gear_method_errors_clearly() {
    let netlist = "\
* GEAR method — not yet implemented
V1 1 0 DC 5
R1 1 0 1k
.OPTIONS method=gear
.TRAN 1n 10n
.END
";
    let (mut circuit, _analyses, opts) = SpiceParser::parse(netlist).unwrap();
    let registry = DeviceRegistry::new_default();
    let config = TransientConfig::new(1e-9, 10e-9);

    let err = run_transient_with_options(&mut circuit, &registry, &config, &opts)
        .expect_err("GEAR should return an error");

    let msg = format!("{err}");
    assert!(
        msg.contains("GEAR") || msg.contains("not yet implemented"),
        "error message should mention GEAR: {msg}"
    );
}
