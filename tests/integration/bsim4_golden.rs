//! BSIM4.8 golden comparisons against ngspice.
//!
//! Phase 2.12 golden test suite. Mirrors `bsim3_golden.rs` but exercises the
//! `LEVEL=14` (BSIM4) model card. Both NMOS and PMOS variants are covered.
//!
//! ─── Run ──────────────────────────────────────────────────────────────────
//!
//!   nix develop --command \
//!     cargo test --test bsim4_golden --release -- --include-ignored --nocapture
//!
//! ─── Status (measured 2026-04-07) ─────────────────────────────────────────
//!
//! These goldens assert parity between PiSIM and ngspice.
//! The parser routes `LEVEL=14|54` → `DeviceKind::Bsim4N/P` and the registry
//! wires both to the BSIM4.8 implementation in `crates/device/src/bsim4/`.
//! Tolerances match the nonlinear MOSFET tier in `ngspice_accuracy.rs`.
//!
//! Tests are `#[ignore]` and require ngspice — run with:
//!   --include-ignored --nocapture
//! They skip cleanly when ngspice is not available in the environment.
//!
//! ─── Reference fixtures ───────────────────────────────────────────────────
//!
//! The 65 nm-style nmos/pmos parameter sets are derived from the qaSpec
//! files at `tests/external/ngspice/tests/bsim4/{nmos,pmos}/parameters/`,
//! trimmed to the parameters that influence first-order DC behaviour.
//! Inlining keeps the test hermetic — `nix develop` does not need the
//! external ngspice tree on disk.

use pisim_test_harness::{parse_netlist_str, run_dc_op, NgspiceConfig, Tolerance};

// ──────────────────────────────────────────────────────────────────────────
// BSIM4 model cards (subset of `tests/external/ngspice/tests/bsim4/*`)
// ──────────────────────────────────────────────────────────────────────────

/// Minimal NMOS BSIM4.8 model card. Mirrors the qaSpec file
/// `tests/external/ngspice/tests/bsim4/nmos/parameters/nmosParameters`
/// but trimmed to first-order DC parameters.
const BSIM4_NMOS_MODEL: &str = "\
.MODEL NMOD NMOS LEVEL=14
+ VERSION=4.8.1
+ TNOM=27 TOXE=1.85e-9 TOXP=1.2e-9 TOXM=1.85e-9 EPSROX=3.9
+ XJ=1.96e-08 NDEP=2.54e+18 NSD=2e+20 NGATE=2e+20
+ VTH0=0.423 K1=0.4 K2=0.01 K3=0
+ DVT0=1 DVT1=2 DVT2=-0.032
+ U0=0.0491 UA=6e-10 UB=1.2e-18 UC=0
+ VSAT=124340 A0=1.0 AGS=1e-20 KETA=0.04
+ RDSW=165 RSW=85 RDW=85 PRWG=0 PRWB=6.8e-11
+ PCLM=0.04 PDIBLC1=0.001 PDIBLC2=0.001 DROUT=0.5
+ PSCBE1=8.14e+8 PSCBE2=1e-7
+ ETA0=0.0058 ETAB=0 DSUB=0.1 MINV=0.05
+ VOFF=-0.13 NFACTOR=1.9 CIT=0
+ KT1=-0.11 KT2=0.022 UTE=-1.5
+ VFB=-0.55
";

/// Minimal PMOS BSIM4.8 model card. Mirrors the qaSpec file
/// `tests/external/ngspice/tests/bsim4/pmos/parameters/pmosParameters`.
const BSIM4_PMOS_MODEL: &str = "\
.MODEL PMOD PMOS LEVEL=14
+ VERSION=4.8.1
+ TNOM=27 TOXE=1.85e-9 TOXP=1.2e-9 TOXM=1.85e-9 EPSROX=3.9
+ XJ=1.96e-08 NDEP=4.1e+18 NSD=2e+20 NGATE=2e+20
+ VTH0=-0.423 K1=0.4 K2=0.01 K3=0
+ DVT0=1 DVT1=2 DVT2=-0.032
+ U0=0.018 UA=6e-10 UB=1.2e-18 UC=0
+ VSAT=80000 A0=1.0 AGS=1e-20 KETA=0.04
+ RDSW=200 RSW=100 RDW=100 PRWG=0 PRWB=6.8e-11
+ PCLM=0.04 PDIBLC1=0.001 PDIBLC2=0.001 DROUT=0.5
+ PSCBE1=8.14e+8 PSCBE2=1e-7
+ ETA0=0.0058 ETAB=0 DSUB=0.1 MINV=0.05
+ VOFF=-0.13 NFACTOR=1.9 CIT=0
+ KT1=-0.11 KT2=0.022 UTE=-1.5
+ VFB=0.55
";

// ──────────────────────────────────────────────────────────────────────────
// Comparison helpers
// ──────────────────────────────────────────────────────────────────────────

/// Run a netlist through both simulators and report DC OP divergence.
///
/// `enforce` controls whether divergence beyond `tol` becomes a hard panic.
/// While the BSIM4 dispatch wiring is incomplete (Phase 2.12), all calls
/// pass `enforce = false` and only print the divergence summary so that
/// the test is informative rather than a permanent red flag.
fn compare_bsim4_dc_op(
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

    let tmp = tempfile::tempdir().unwrap();
    let netlist_path = tmp.path().join("circuit.sp");
    std::fs::write(&netlist_path, netlist).unwrap();

    let ng_result = match ngspice.run(&netlist_path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{test_name}: ngspice failed: {e}");
            summary.ngspice_failed = true;
            return summary;
        }
    };
    let ng_pairs = ng_result.rawfile.as_dc_pairs();

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

    let mut pi_pairs: Vec<(String, f64)> = Vec::new();
    for (name, val) in &pi_result.node_voltages {
        pi_pairs.push((format!("v({})", name), *val));
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

/// BSIM4 NMOS in saturation (Vds=Vgs=1.2 V on a 65 nm-style card).
#[test]
#[ignore = "BSIM4 golden — run with --include-ignored"]
fn bsim4_nmos_saturation_op() {
    let netlist = format!(
        "\
* BSIM4 NMOS saturation operating point
VDD d 0 DC 1.2
VGG g 0 DC 1.2
M1 d g 0 0 NMOD W=10u L=0.06u
{}
.OP
.END
",
        BSIM4_NMOS_MODEL
    );

    let summary = compare_bsim4_dc_op(
        &netlist,
        "bsim4_nmos_saturation_op",
        &Tolerance::default(),
        /*enforce=*/ true,
    );
    assert!(
        !summary.pisim_failed,
        "PiSIM BSIM4 NMOS saturation: convergence or parse failure"
    );
}

/// BSIM4 PMOS in saturation (Vds=Vgs=-1.2 V).
#[test]
#[ignore = "BSIM4 golden — run with --include-ignored"]
fn bsim4_pmos_saturation_op() {
    let netlist = format!(
        "\
* BSIM4 PMOS saturation operating point
VDD d 0 DC -1.2
VGG g 0 DC -1.2
M1 d g 0 0 PMOD W=20u L=0.06u
{}
.OP
.END
",
        BSIM4_PMOS_MODEL
    );

    let summary = compare_bsim4_dc_op(
        &netlist,
        "bsim4_pmos_saturation_op",
        &Tolerance::default(),
        /*enforce=*/ true,
    );
    assert!(!summary.pisim_failed);
}

/// CMOS inverter biased at the trip point.
#[test]
#[ignore = "BSIM4 golden — run with --include-ignored"]
fn bsim4_cmos_inverter_trip_point() {
    let netlist = format!(
        "\
* BSIM4 CMOS inverter at trip point
VDD vdd 0 DC 1.2
VIN  in  0 DC 0.6
MN out in 0   0   NMOD W=2u L=0.06u
MP out in vdd vdd PMOD W=4u L=0.06u
{}
{}
.OP
.END
",
        BSIM4_NMOS_MODEL, BSIM4_PMOS_MODEL
    );

    let summary = compare_bsim4_dc_op(
        &netlist,
        "bsim4_cmos_inverter_trip_point",
        &Tolerance::default(),
        /*enforce=*/ true,
    );
    assert!(!summary.pisim_failed);
}

/// Diode-connected NMOS — exercises subthreshold and strong-inversion in
/// the same operating point through a series gate-drain resistor.
#[test]
#[ignore = "BSIM4 golden — run with --include-ignored"]
fn bsim4_nmos_diode_connected() {
    let netlist = format!(
        "\
* BSIM4 diode-connected NMOS
VDD d 0 DC 1.2
R1 d g 100k
M1 g g 0 0 NMOD W=10u L=0.06u
{}
.OP
.END
",
        BSIM4_NMOS_MODEL
    );

    let summary = compare_bsim4_dc_op(
        &netlist,
        "bsim4_nmos_diode_connected",
        &Tolerance::default(),
        /*enforce=*/ true,
    );
    assert!(!summary.pisim_failed);
}
