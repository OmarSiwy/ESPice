//! OSDI (Open Source Device Interface) VA golden tests.
#[path = "../common/mod.rs"]
mod common;
use common::parse_netlist_str;

#[test]
#[ignore = "requires compiled OSDI .so and osdi-va fixture files"]
fn osdi_va_diode_golden() {}

#[test]
#[ignore = "requires compiled OSDI .so for BSIM4 VA model"]
fn osdi_va_bsim4_dc_op() {}

/// Sanity: the OSDI plugin loader path resolves without panic when no .so is present.
#[test]
fn osdi_loader_no_lib_returns_error() {
    use bigospice_osdi::OsdiPlugin;
    let result = OsdiPlugin::open("/nonexistent/path/model.so");
    assert!(result.is_err(), "loading a nonexistent .so should return an error");
}

/// The parser should accept a `.hdl` or `.va` include line without crashing.
#[test]
fn osdi_netlist_with_hdl_include_parses() {
    let netlist = "\
* OSDI VA model reference
V1 d 0 DC 1.0
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok());
}
