//! Phase 1.3 — golden temperature test vs ngspice at 0/27/100 °C.
//!
//! Tolerances:
//!   Voltages: 0.5 % relative + 1 mV absolute
//!   Currents: 1 % relative + 10 nA absolute
//!
//! ## Temperature implementation status
//!
//! BJT temperature scaling (Is(T), beta(T), Vt(T)) is wired in
//! `crates/device/src/bjt.rs`. Resistor TC1/TC2 is implemented in
//! `crates/device/src/resistor.rs`. All corners inject temperature via
//! per-device `temp=`/`tnom=` parameters on the element line.

use pisim_analysis::dc_op::run_dc_op_with_options;
use pisim_device::DeviceRegistry;
use pisim_parser::SpiceParser;
use pisim_test_harness::run_dc_op;

// ──────────────────────────────────────────────────────────────────────────────
// Tolerances
// ──────────────────────────────────────────────────────────────────────────────

const TOL_V_ABS: f64 = 1e-3; // 1 mV
const TOL_V_REL: f64 = 5e-3; // 0.5 %
const TOL_I_ABS: f64 = 1e-8; // 10 nA
const TOL_I_REL: f64 = 1e-2; // 1 %

fn within(actual: f64, expected: f64, abs_tol: f64, rel_tol: f64, label: &str) {
    let abs_err = (actual - expected).abs();
    let rel_err = abs_err / expected.abs().max(1e-30);
    assert!(
        abs_err < abs_tol || rel_err < rel_tol,
        "{label}: PiSIM={actual:.6e}, ngspice={expected:.6e}, \
         abs_err={abs_err:.3e}, rel_err={rel_err:.3e}"
    );
}

fn v(result: &pisim_analysis::DcOpResult, name: &str) -> f64 {
    result
        .node_voltages
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| *v)
        .unwrap_or_else(|| panic!("node '{name}' not found"))
}

fn i(result: &pisim_analysis::DcOpResult, name: &str) -> f64 {
    result
        .branch_currents
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case(name))
        .map(|(_, v)| *v)
        .unwrap_or_else(|| panic!("device '{name}' not found"))
}

// ──────────────────────────────────────────────────────────────────────────────
// Sanity sub-test: room-temperature solve still works
// ──────────────────────────────────────────────────────────────────────────────

const NETLIST_DIODE_R: &str = "\
* Diode-resistor temperature corner test
V1 1 0 DC 1
R1 1 2 10k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
";

#[test]
fn temperature_room_runs() {
    let (circuit, _, opts) = SpiceParser::parse(NETLIST_DIODE_R).unwrap();
    let registry = DeviceRegistry::default();
    let result = run_dc_op_with_options(&circuit, &registry, &opts).unwrap();
    let v2 = v(&result.result, "2");
    assert!(v2 > 0.0 && v2 < 0.8, "expected 0 < V(2) < 0.8, got {v2}");
}

// ──────────────────────────────────────────────────────────────────────────────
// Diode-resistor temperature corners
// ──────────────────────────────────────────────────────────────────────────────

/// Build a diode-R netlist with explicit per-device temp= (Kelvin).
/// `.TEMP` propagation through the parser is gap-tracked under §1.3, so we
/// inject the temperature directly into the diode element line.
fn diode_r_netlist(kelvin: f64) -> String {
    format!(
        "* Diode-R temp={kelvin}K\n\
         V1 1 0 DC 1\n\
         R1 1 2 10k\n\
         D1 2 0 DMOD temp={kelvin} tnom=300.15\n\
         .MODEL DMOD D (IS=1e-14 N=1 XTI=3 EG=1.11)\n\
         .OP\n\
         .END\n"
    )
}

#[test]
fn diode_r_temperature_0c() {
    // ngspice: V(2)=0.6253836  I(V1)=-3.74616e-5
    let netlist = diode_r_netlist(273.15);
    let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    within(v(&result, "2"), 0.6253836, TOL_V_ABS, TOL_V_REL, "Diode V(2) @ 0C");
    within(i(&result, "V1"), -3.74616e-5, TOL_I_ABS, TOL_I_REL, "Diode I(V1) @ 0C");
}

#[test]
fn diode_r_temperature_27c() {
    // ngspice: V(2)=0.5735203  I(V1)=-4.26480e-5
    let netlist = diode_r_netlist(300.15);
    let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    within(v(&result, "2"), 0.5735203, TOL_V_ABS, TOL_V_REL, "Diode V(2) @ 27C");
    within(i(&result, "V1"), -4.26480e-5, TOL_I_ABS, TOL_I_REL, "Diode I(V1) @ 27C");
}

#[test]
fn diode_r_temperature_100c() {
    // ngspice: V(2)=0.4312956  I(V1)=-5.68704e-5
    let netlist = diode_r_netlist(373.15);
    let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    within(v(&result, "2"), 0.4312956, TOL_V_ABS, TOL_V_REL, "Diode V(2) @ 100C");
    within(i(&result, "V1"), -5.68704e-5, TOL_I_ABS, TOL_I_REL, "Diode I(V1) @ 100C");
}

// ──────────────────────────────────────────────────────────────────────────────
// BJT common-emitter temperature corners
// ──────────────────────────────────────────────────────────────────────────────

fn bjt_ce_netlist(kelvin: f64) -> String {
    // BC547 CE amplifier. Temperature is injected via per-device `temp=`/`tnom=`
    // parameters on the Q1 element line so that BJT temperature scaling
    // (Is(T), beta(T), Vt(T)) is exercised at each corner.
    format!(
        "* BC547 CE\n\
         Vcc 10 0 DC 5\n\
         Rb 10 1 430k\n\
         Rc 10 2 1k\n\
         Q1 2 1 0 BC547 temp={kelvin} tnom=300.15\n\
         .MODEL BC547 NPN (IS=1.8e-14 BF=400 NF=1 VAF=80 IKF=0.1 ISE=5e-14 NE=1.5 \
         BR=6 NR=1 IKR=0.02 RC=0.3 XTB=0 XTI=3 EG=1.11)\n\
         .OP\n\
         .END\n"
    )
}

/// Always-on structural check: every corner parses cleanly.
#[test]
fn bjt_ce_temperature_parse_all_corners() {
    for k in [273.15_f64, 300.15, 373.15] {
        let netlist = bjt_ce_netlist(k);
        let _parsed = SpiceParser::parse(&netlist)
            .unwrap_or_else(|e| panic!("BJT @ {k}K failed to parse: {e}"));
    }
}

#[test]
fn bjt_ce_temperature_0c() {
    // ngspice: V(B)=0.7172025  V(C)=1.729377  I(Vcc)=-3.28058e-3
    let netlist = bjt_ce_netlist(273.15);
    let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    within(v(&result, "1"), 0.7172025, TOL_V_ABS, TOL_V_REL, "BJT V(B) @ 0C");
    within(v(&result, "2"), 1.729377, TOL_V_ABS, TOL_V_REL, "BJT V(C) @ 0C");
    within(i(&result, "Vcc"), -3.28058e-3, TOL_I_ABS, TOL_I_REL, "BJT I(Vcc) @ 0C");
}

#[test]
fn bjt_ce_temperature_27c() {
    // ngspice: V(B)=0.6713528  V(C)=1.693088  I(Vcc)=-3.31698e-3
    // 27 °C = the model card's tnom — Is/beta scaling is unity here.
    let netlist = bjt_ce_netlist(300.15);
    let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    within(v(&result, "1"), 0.6713528, TOL_V_ABS, TOL_V_REL, "BJT V(B) @ 27C");
    within(v(&result, "2"), 1.693088, TOL_V_ABS, TOL_V_REL, "BJT V(C) @ 27C");
    within(i(&result, "Vcc"), -3.31698e-3, TOL_I_ABS, TOL_I_REL, "BJT I(Vcc) @ 27C");
}

#[test]
fn bjt_ce_temperature_100c() {
    // ngspice: V(B)=0.5446488  V(C)=1.592789  I(Vcc)=-3.41757e-3
    let netlist = bjt_ce_netlist(373.15);
    let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    within(v(&result, "1"), 0.5446488, TOL_V_ABS, TOL_V_REL, "BJT V(B) @ 100C");
    within(v(&result, "2"), 1.592789, TOL_V_ABS, TOL_V_REL, "BJT V(C) @ 100C");
    within(i(&result, "Vcc"), -3.41757e-3, TOL_I_ABS, TOL_I_REL, "BJT I(Vcc) @ 100C");
}

// ──────────────────────────────────────────────────────────────────────────────
// Resistor TC1/TC2 temperature corners
// ──────────────────────────────────────────────────────────────────────────────

/// Build a resistor-with-TC netlist with explicit per-device temp= (Kelvin).
/// tnom=300.15 K (27 °C) is the standard SPICE nominal temperature.
fn rtc_netlist(kelvin: f64) -> String {
    format!(
        "* R with TC1/TC2 temp={kelvin}K\n\
         V1 1 0 DC 5\n\
         R1 1 0 1k TC1=0.001 TC2=1e-6 temp={kelvin} tnom=300.15\n\
         .OP\n\
         .END\n"
    )
}

/// Verify the parser accepts TC1/TC2 syntax. Always-on structural check.
#[test]
fn resistor_tc1_tc2_parses() {
    let _parsed = SpiceParser::parse(&rtc_netlist(300.15)).expect("R with TC1/TC2 should parse");
}

/// Resistor temperature scaling: R(T) = R0 * (1 + TC1*(T-Tnom) + TC2*(T-Tnom)^2).
#[test]
fn resistor_tc1_tc2_temperature_0c() {
    // ngspice (T=0 °C, dT=-27): R = 1k*(1 + 0.001*(-27) + 1e-6*729) ≈ 973.73
    // I(V1) = -5/973.73 ≈ -5.13490 mA
    let (circuit, _, _) = SpiceParser::parse(&rtc_netlist(273.15)).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    within(i(&result, "V1"), -5.13490e-3, TOL_I_ABS, TOL_I_REL, "R(TC) I @ 0C");
}

#[test]
fn resistor_tc1_tc2_temperature_27c() {
    // At Tnom (27 °C), TC1/TC2 contribute zero, so R = 1 kΩ exactly.
    let (circuit, _, _) = SpiceParser::parse(&rtc_netlist(300.15)).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    within(i(&result, "V1"), -5.0e-3, TOL_I_ABS, TOL_I_REL, "R(TC) I @ 27C");
}

#[test]
fn resistor_tc1_tc2_temperature_100c() {
    // ngspice (T=100 °C, dT=+73): R = 1k*(1 + 0.001*73 + 1e-6*5329) ≈ 1078.33
    // I(V1) = -5/1078.33 ≈ -4.63680 mA
    let (circuit, _, _) = SpiceParser::parse(&rtc_netlist(373.15)).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    within(i(&result, "V1"), -4.63680e-3, TOL_I_ABS, TOL_I_REL, "R(TC) I @ 100C");
}
