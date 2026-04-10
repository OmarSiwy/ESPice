//! BSIM3v3 golden comparisons against ngspice.
//!
//! Phase 2.11 golden test suite. These tests stand up the netlist on both
//! PiSIM and ngspice (skipping cleanly when ngspice is not available, like
//! `tests/integration/ngspice_live.rs`) and compare DC operating-point and
//! DC sweep results.
//!
//! ─── Run ──────────────────────────────────────────────────────────────────
//!
//!   nix develop --command \
//!     cargo test --test bsim3_golden --release -- --include-ignored --nocapture
//!
//! ─── Status (measured 2026-04-07) ─────────────────────────────────────────
//!
//! These goldens assert parity between PiSIM and ngspice.
//! The parser routes `LEVEL=8|49` → `DeviceKind::Bsim3N/P` and the registry
//! wires both to the BSIM3v3 implementation in `crates/device/src/bsim3/`.
//! Tolerances match the nonlinear MOSFET tier in `ngspice_accuracy.rs`.
//!
//! Tests are `#[ignore]` and require ngspice — run with:
//!   --include-ignored --nocapture
//! They skip cleanly when ngspice is not available in the environment.
//!
//! ─── Reference fixtures ───────────────────────────────────────────────────
//!
//! The 0.18 µm-style nmos/pmos parameter sets are derived from
//! `tests/external/ngspice/tests/bsim3/{nmos,pmos}/parameters/` (CMC qaSpec
//! format). They are inlined here so the test is hermetic — `nix develop`
//! does not need to materialise the external test tree.

use pisim_test_harness::{parse_netlist_str, run_dc_op, NgspiceConfig, Tolerance};

// ──────────────────────────────────────────────────────────────────────────
// BSIM3 model cards (subset of `tests/external/ngspice/tests/bsim3/*`)
// ──────────────────────────────────────────────────────────────────────────

/// Minimal NMOS BSIM3v3 model card.  Mirrors the qaSpec file
/// `tests/external/ngspice/tests/bsim3/nmos/parameters/nmosParameters`
/// but trimmed to the parameters that influence first-order DC behaviour.
const BSIM3_NMOS_MODEL: &str = "\
.MODEL NMOD NMOS LEVEL=49
+ VERSION=3.3.0
+ TNOM=27 TOX=1.5e-08 XJ=1.5e-07 NCH=1.7e+17
+ VTH0=0.7 K1=0.5 K2=0.0 K3=80
+ DVT0=2.2 DVT1=0.53 DVT2=-0.032
+ U0=670 UA=2.25e-09 UB=5.87e-19 UC=-4.65e-11
+ VSAT=8e+04 A0=1.0 AGS=0.0 KETA=-0.047
+ RDSW=100 PRWG=0 PRWB=0
+ PCLM=1.3 PDIBLC1=0.39 PDIBLC2=0.0086 DROUT=0.56
+ PSCBE1=4.24e+8 PSCBE2=1e-05
+ ETA0=0.08 ETAB=-0.07 DSUB=0.56
+ VOFF=-0.08 NFACTOR=1.0 CIT=0
+ KT1=-0.11 KT2=-0.022 UTE=-1.48
";

/// Minimal PMOS BSIM3v3 model card.  Mirrors the qaSpec file
/// `tests/external/ngspice/tests/bsim3/pmos/parameters/pmosParameters`.
const BSIM3_PMOS_MODEL: &str = "\
.MODEL PMOD PMOS LEVEL=49
+ VERSION=3.3.0
+ TNOM=27 TOX=1.5e-08 XJ=1.5e-07 NCH=4.1589e+17
+ VTH0=-0.7 K1=0.5 K2=0.0 K3=80
+ DVT0=2.2 DVT1=0.53 DVT2=-0.032
+ U0=250 UA=2.25e-09 UB=5.87e-19 UC=-4.65e-11
+ VSAT=8e+04 A0=1.0 AGS=0.0 KETA=-0.047
+ RDSW=100 PRWG=0 PRWB=0
+ PCLM=1.3 PDIBLC1=0.39 PDIBLC2=0.0086 DROUT=0.56
+ PSCBE1=4.24e+8 PSCBE2=1e-05
+ ETA0=0.08 ETAB=-0.07 DSUB=0.56
+ VOFF=-0.08 NFACTOR=1.0 CIT=0
+ KT1=-0.11 KT2=-0.022 UTE=-1.48
";

// ──────────────────────────────────────────────────────────────────────────
// Comparison helpers
// ──────────────────────────────────────────────────────────────────────────

/// Run a netlist through both simulators and report DC OP divergence.
///
/// `enforce` controls whether divergence beyond `tol` becomes a hard panic.
/// While the BSIM3 dispatch wiring is incomplete (Phase 2.11), all calls
/// pass `enforce = false` and only print the divergence summary so that
/// the test is informative rather than a permanent red flag.
fn compare_bsim3_dc_op(
    netlist: &str,
    test_name: &str,
    tol: &Tolerance,
    enforce: bool,
) -> ComparisonSummary {
    let mut summary = ComparisonSummary::new(test_name);

    let ngspice = NgspiceConfig::default();
    if !ngspice.is_available() {
        eprintln!("{test_name}: ngspice not available — skipping");
        summary.skipped = true;
        return summary;
    }

    // Write netlist for ngspice.
    let tmp = tempfile::tempdir().unwrap();
    let netlist_path = tmp.path().join("circuit.sp");
    std::fs::write(&netlist_path, netlist).unwrap();

    // Run ngspice.
    let ng_result = match ngspice.run(&netlist_path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{test_name}: ngspice failed: {e}");
            summary.ngspice_failed = true;
            return summary;
        }
    };
    let ng_pairs = ng_result.rawfile.as_dc_pairs();

    // Run PiSIM.
    let (circuit, _) = match parse_netlist_str(netlist) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{test_name}: PiSIM parse failed: {e}");
            summary.pisim_failed = true;
            return summary;
        }
    };
    let pi_result = match run_dc_op(&circuit) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{test_name}: PiSIM dc_op failed: {e}");
            summary.pisim_failed = true;
            return summary;
        }
    };

    // Build PiSIM pairs in ngspice naming convention.
    let mut pi_pairs: Vec<(String, f64)> = Vec::new();
    for (name, val) in &pi_result.node_voltages {
        pi_pairs.push((format!("v({})", name), *val));
        // Sanity: PiSIM should never produce NaN/Inf.
        assert!(
            val.is_finite(),
            "{test_name}: PiSIM v({name}) is non-finite ({val})"
        );
    }
    for (name, val) in &pi_result.branch_currents {
        pi_pairs.push((format!("i({})", name.to_lowercase()), *val));
        assert!(
            val.is_finite(),
            "{test_name}: PiSIM i({name}) is non-finite ({val})"
        );
    }

    // Compare each ngspice signal against PiSIM.
    for (ng_name, ng_val) in &ng_pairs {
        let ng_lower = ng_name.to_lowercase();
        if !ng_lower.starts_with("v(") && !ng_lower.starts_with("i(") {
            continue;
        }
        let matched = pi_pairs.iter().find(|(n, _)| n.to_lowercase() == ng_lower);
        if let Some((_, pi_val)) = matched {
            let is_current = ng_lower.starts_with("i(");
            let (abs_tol, rel_tol) = if is_current {
                tol.dc_current
            } else {
                tol.dc_voltage
            };
            let abs_err = (pi_val - ng_val).abs();
            let rel_err = abs_err / ng_val.abs().max(1e-30);
            let within = Tolerance::within(*pi_val, *ng_val, abs_tol, rel_tol);

            summary.signals_compared += 1;
            if within {
                summary.signals_within += 1;
            } else {
                summary.signals_diverged += 1;
                summary.max_rel_err = summary.max_rel_err.max(rel_err);
                if enforce {
                    panic!(
                        "{test_name} signal {ng_name}: PiSIM={pi_val:.6e} ngspice={ng_val:.6e} \
                         abs_err={abs_err:.2e} rel_err={rel_err:.2e}"
                    );
                }
                eprintln!(
                    "{test_name}   {ng_name:<20} PiSIM={pi_val:.6e}  ngspice={ng_val:.6e}  \
                     abs={abs_err:.2e} rel={rel_err:.2e}"
                );
            }
        } else {
            eprintln!("{test_name}: ngspice signal {ng_name} not found in PiSIM output");
        }
    }

    eprintln!(
        "{test_name}: {} signals compared, {} within tol, {} diverged, max_rel_err={:.2e} \
         (ngspice {:.0}ms)",
        summary.signals_compared,
        summary.signals_within,
        summary.signals_diverged,
        summary.max_rel_err,
        ng_result.wall_time.as_secs_f64() * 1000.0,
    );

    summary
}

#[derive(Debug)]
struct ComparisonSummary {
    name: String,
    skipped: bool,
    pisim_failed: bool,
    ngspice_failed: bool,
    signals_compared: usize,
    signals_within: usize,
    signals_diverged: usize,
    max_rel_err: f64,
}

impl ComparisonSummary {
    fn new(name: &str) -> Self {
        Self {
            name: name.to_string(),
            skipped: false,
            pisim_failed: false,
            ngspice_failed: false,
            signals_compared: 0,
            signals_within: 0,
            signals_diverged: 0,
            max_rel_err: 0.0,
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

/// BSIM3 NMOS in saturation (Vds=Vgs=1.0, W/L=10/0.5 µm).
/// Documents divergence — Level 1 fallback severely under-/over-estimates Id.
#[test]
#[ignore = "BSIM3 golden — run with --include-ignored"]
fn bsim3_nmos_saturation_op() {
    let netlist = format!(
        "\
* BSIM3 NMOS saturation operating point
VDD d 0 DC 1.0
VGG g 0 DC 1.0
M1 d g 0 0 NMOD W=10u L=0.5u
{}
.OP
.END
",
        BSIM3_NMOS_MODEL
    );

    let summary = compare_bsim3_dc_op(
        &netlist,
        "bsim3_nmos_saturation_op",
        &Tolerance::default(),
        /*enforce=*/ true,
    );
    assert!(
        !summary.pisim_failed,
        "PiSIM BSIM3 NMOS saturation: convergence or parse failure"
    );
}

/// BSIM3 PMOS in saturation (Vds=Vgs=-1.0).
#[test]
#[ignore = "BSIM3 golden — run with --include-ignored"]
fn bsim3_pmos_saturation_op() {
    let netlist = format!(
        "\
* BSIM3 PMOS saturation operating point
VDD d 0 DC -1.0
VGG g 0 DC -1.0
M1 d g 0 0 PMOD W=20u L=0.5u
{}
.OP
.END
",
        BSIM3_PMOS_MODEL
    );

    let summary = compare_bsim3_dc_op(
        &netlist,
        "bsim3_pmos_saturation_op",
        &Tolerance::default(),
        /*enforce=*/ true,
    );
    assert!(!summary.pisim_failed);
}

/// CMOS inverter biased at the trip point (Vin = VDD/2). Exercises both
/// NMOS and PMOS BSIM3 cards in the same circuit.
#[test]
#[ignore = "BSIM3 golden — run with --include-ignored"]
fn bsim3_cmos_inverter_trip_point() {
    let netlist = format!(
        "\
* BSIM3 CMOS inverter at trip point
VDD vdd 0 DC 1.8
VIN  in  0 DC 0.9
MN out in 0   0   NMOD W=2u L=0.5u
MP out in vdd vdd PMOD W=4u L=0.5u
{}
{}
.OP
.END
",
        BSIM3_NMOS_MODEL, BSIM3_PMOS_MODEL
    );

    let summary = compare_bsim3_dc_op(
        &netlist,
        "bsim3_cmos_inverter_trip_point",
        &Tolerance::default(),
        /*enforce=*/ true,
    );
    assert!(!summary.pisim_failed);
}

/// Diode-connected NMOS with a series resistor — exercises a BSIM3 device
/// in subthreshold/strong-inversion crossover.
#[test]
#[ignore = "BSIM3 golden — run with --include-ignored"]
fn bsim3_nmos_diode_connected() {
    let netlist = format!(
        "\
* BSIM3 diode-connected NMOS
VDD d 0 DC 1.8
R1 d g 100k
M1 g g 0 0 NMOD W=10u L=0.5u
{}
.OP
.END
",
        BSIM3_NMOS_MODEL
    );

    let summary = compare_bsim3_dc_op(
        &netlist,
        "bsim3_nmos_diode_connected",
        &Tolerance::default(),
        /*enforce=*/ true,
    );
    assert!(!summary.pisim_failed);
}
