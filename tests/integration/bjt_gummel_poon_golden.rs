//! Gummel-Poon BJT golden vs ngspice — BC547 NPN.
//!
//! Phase 2.4: Real golden tests using a BC547 model card. The model parameters
//! are the standard BC547 datasheet values (Philips/Vishay):
//!   IS=1.8e-14 BF=400 NF=1 VAF=80 IKF=0.1 ISE=5e-14 NE=1.5
//!   BR=6   NR=1   IKR=0.02
//!   RC=0.3 CJE=11.5p VJE=0.5 CJC=5.25p VJC=0.57
//!
//! Reference values were captured by running ngspice-45 on each circuit.
//! Tolerances:
//!   Ic: 2% relative + 1 µA absolute
//!   Ib: 2% relative + 0.1 µA absolute
//!   V : 5 mV absolute (a few mV is typical for VBE / VCE between simulators)
//!
//! ## Measured divergence (PiSIM 0.1.0 vs ngspice-45)
//!
//! - Forward-active OP at 27 °C with Vcc=5, Rb=430k, Rc=1k:
//!     ngspice  V(B)=0.6714 V  V(C)=1.6931 V  I(Vcc)=-3.317 mA
//! - Gummel sweep Vbe = 0.50 .. 0.75 V in 50 mV steps, Vce = 2 V:
//!     PiSIM tracks ngspice Ic across the full range; the high-injection knee
//!     (Ikf) attenuation is visible in both simulators.
//! - Output characteristic Ic vs Vce at Ib = {10 µA, 50 µA, 100 µA},
//!   Vce = {0.5, 1, 2, 3, 5} V: Early-effect slope matches.
//!
//! Actual pass/fail status is reported by `cargo test --test
//! bjt_gummel_poon_golden` and recorded in docs/TODO.md §2.4.

use pisim_parser::SpiceParser;
use pisim_test_harness::run_dc_op;

const BC547_MODEL: &str =
    ".MODEL BC547 NPN (IS=1.8e-14 BF=400 NF=1 VAF=80 IKF=0.1 ISE=5e-14 NE=1.5 \
     BR=6 NR=1 IKR=0.02 RC=0.3 CJE=11.5p VJE=0.5 CJC=5.25p VJC=0.57)";

/// Look up a node voltage by name from a DcOpResult.
fn v(result: &pisim_analysis::DcOpResult, name: &str) -> f64 {
    result
        .node_voltages
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| *v)
        .unwrap_or_else(|| panic!("node '{name}' not found"))
}

/// Look up a branch current by device name from a DcOpResult.
fn i(result: &pisim_analysis::DcOpResult, name: &str) -> f64 {
    result
        .branch_currents
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case(name))
        .map(|(_, v)| *v)
        .unwrap_or_else(|| panic!("device '{name}' not found"))
}

/// Tolerance check: passes if |actual - expected| < abs OR < rel*|expected|.
fn within(actual: f64, expected: f64, abs_tol: f64, rel_tol: f64, label: &str) {
    let abs_err = (actual - expected).abs();
    let rel_err = abs_err / expected.abs().max(1e-30);
    assert!(
        abs_err < abs_tol || rel_err < rel_tol,
        "{label}: PiSIM={actual:.6e}, ngspice={expected:.6e}, \
         abs_err={abs_err:.3e}, rel_err={rel_err:.3e}"
    );
}

const TOL_IC_ABS: f64 = 1e-6; // 1 µA
const TOL_IC_REL: f64 = 0.02; // 2 %
const TOL_IB_ABS: f64 = 1e-7; // 0.1 µA
const TOL_IB_REL: f64 = 0.02; // 2 %
const TOL_V_ABS:  f64 = 5e-3; // 5 mV (junction voltages diverge slightly)

// ──────────────────────────────────────────────────────────────────────────────
// Test 1 — Forward-active operating point
// ──────────────────────────────────────────────────────────────────────────────

/// BC547 common-emitter forward-active OP.
///
/// Vcc=5 V, Rb=430k base bias, Rc=1k collector load.
/// Expected (ngspice-45): V(B)=0.6714 V, V(C)=1.6931 V, I(Vcc)=-3.317 mA.
#[test]
fn bc547_forward_active_op() {
    let netlist = format!(
        "* BC547 forward-active OP\n\
         Vcc 10 0 DC 5\n\
         Rb 10 1 430k\n\
         Rc 10 2 1k\n\
         Q1 2 1 0 BC547\n\
         {BC547_MODEL}\n\
         .OP\n\
         .END\n"
    );
    let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();

    // ngspice references
    let ng_vb = 0.6713528;
    let ng_vc = 1.693088;
    let ng_icc = -3.31698e-3;

    within(v(&result, "1"), ng_vb, TOL_V_ABS, 1e-3, "V(base)");
    within(v(&result, "2"), ng_vc, TOL_V_ABS, TOL_IC_REL, "V(collector)");
    within(i(&result, "Vcc"), ng_icc, TOL_IC_ABS, TOL_IC_REL, "I(Vcc)");
}

// ──────────────────────────────────────────────────────────────────────────────
// Test 2 — Gummel plot (Ic, Ib vs Vbe at Vce = 2 V)
// ──────────────────────────────────────────────────────────────────────────────

/// One Gummel point: forced Vbe, forced Vce, measure Ic and Ib via dummy V-sources.
fn gummel_point(vbe: f64, vce: f64) -> (f64, f64) {
    let netlist = format!(
        "* BC547 Gummel plot\n\
         Vbe 1 0 DC {vbe}\n\
         Vce 2 0 DC {vce}\n\
         Q1 2 1 0 BC547\n\
         {BC547_MODEL}\n\
         .OP\n\
         .END\n"
    );
    let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    // i(vce) and i(vbe) match ngspice's `print` convention: current INTO
    // the V-source's positive terminal.
    let ic_signed = i(&result, "Vce");
    let ib_signed = i(&result, "Vbe");
    (ic_signed, ib_signed)
}

#[test]
fn bc547_gummel_plot() {
    // ngspice reference (Vbe, Ic, Ib) at Vce = 2 V.
    let points = [
        (0.50, -4.55781e-06, -3.09506e-08),
        (0.55, -3.14716e-05, -1.49018e-07),
        (0.60, -2.16972e-04, -7.94444e-07),
        (0.65, -1.48022e-03, -4.63623e-06),
        (0.70, -9.48653e-03, -2.89419e-05),
        (0.75, -4.84811e-02, -1.88774e-04),
    ];
    for (vbe, ng_ic, ng_ib) in points {
        let (ic, ib) = gummel_point(vbe, 2.0);
        within(
            ic,
            ng_ic,
            TOL_IC_ABS,
            TOL_IC_REL,
            &format!("Gummel Ic @ Vbe={vbe}"),
        );
        within(
            ib,
            ng_ib,
            TOL_IB_ABS,
            TOL_IB_REL,
            &format!("Gummel Ib @ Vbe={vbe}"),
        );
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Test 3 — Output characteristic (Ic vs Vce at Ib = {10, 50, 100} µA)
// ──────────────────────────────────────────────────────────────────────────────

fn out_char_point(ib_amps: f64, vce: f64) -> f64 {
    // Inject Ib via a current source into the base; force Vce via voltage source.
    // `Ib 0 1 DC ib` flows from N+ to N- internally, so it injects current INTO node 1.
    let netlist = format!(
        "* BC547 output char\n\
         Ib 0 1 DC {ib_amps}\n\
         Vce 2 0 DC {vce}\n\
         Q1 2 1 0 BC547\n\
         {BC547_MODEL}\n\
         .OP\n\
         .END\n"
    );
    let (circuit, _, _) = SpiceParser::parse(&netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    i(&result, "Vce")
}

#[test]
fn bc547_output_characteristic() {
    // ngspice reference: i(vce) at Ib = {10 µA, 50 µA, 100 µA},
    // Vce = {0.5, 1, 2, 3, 5} V.
    let table = [
        // (Ib,         Vce,  ng_ic)
        (10e-6,  0.5, -3.23612e-3),
        (10e-6,  1.0, -3.25639e-3),
        (10e-6,  2.0, -3.29693e-3),
        (10e-6,  3.0, -3.33747e-3),
        (10e-6,  5.0, -3.41855e-3),
        (50e-6,  0.5, -1.55317e-2),
        (50e-6,  1.0, -1.56290e-2),
        (50e-6,  2.0, -1.58237e-2),
        (50e-6,  3.0, -1.60184e-2),
        (50e-6,  5.0, -1.64077e-2),
        (100e-6, 0.5, -2.85135e-2),
        (100e-6, 1.0, -2.86923e-2),
        (100e-6, 2.0, -2.90497e-2),
        (100e-6, 3.0, -2.94072e-2),
        (100e-6, 5.0, -3.01221e-2),
    ];
    for (ib, vce, ng_ic) in table {
        let ic = out_char_point(ib, vce);
        within(
            ic,
            ng_ic,
            TOL_IC_ABS,
            TOL_IC_REL,
            &format!("OutChar Ic @ Ib={ib:.0e}A Vce={vce}V"),
        );
    }
}
