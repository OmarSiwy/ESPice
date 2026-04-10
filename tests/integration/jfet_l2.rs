//! JFET Level 2 (Parker-Skellern) integration tests — Phase 2.7.
//!
//! Tests cover: DC OP convergence for N/P-channel, L1 vs L2 current
//! difference, channel-length modulation (lambda), and sub-threshold cutoff.

use pisim_test_harness::{parse_netlist_str, run_dc_op};

/// (a) NJF with LEVEL=2, common-source stage: verify DC OP converges and
/// Id is nonzero in saturation.
#[test]
fn jfet_l2_dc_op_n_channel() {
    // Common-source N-JFET: Vdd=10V, Rd=1k, Vgs=-0.5V (gate held via Vg source).
    // VTO=-2V, BETA=2e-3, LAMBDA=0.01, LEVEL=2.
    // With Vgs=-0.5, Vov = -0.5 - (-2) = 1.5 V > 0 → device is ON.
    // Expected: drain voltage < Vdd (current flows), Id > 0.
    let netlist = "\
* NJF Level 2 common-source
.MODEL JN NJF LEVEL=2 VTO=-2 BETA=2e-3 LAMBDA=0.01 DELTA=0 MVST=0.5 NDS=2 HFETA=0
Vdd 1 0 DC 10
Rd 1 2 1k
J1 2 3 0 JN
Vg 3 0 DC -0.5
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse failed");
    let result = run_dc_op(&circuit).expect("dc op failed");

    // Drain node (node 2) should be < Vdd (i.e. there IS a voltage drop across Rd → Id > 0).
    let vd = result.node_voltages.iter()
        .find(|(n, _)| n == "2")
        .map(|(_, v)| *v)
        .expect("node 2 not found");

    assert!(vd < 9.9, "NJF L2: drain should be pulled down, got V(2)={vd}");
    assert!(vd > 0.0, "NJF L2: drain should be above ground, got V(2)={vd}");

    // Id ≈ (Vdd - Vd) / Rd
    let id = (10.0 - vd) / 1000.0;
    assert!(id > 1e-4, "NJF L2: Id should be nonzero in saturation, got {id}");
}

/// (b) PJF with LEVEL=2, common-source stage: verify DC OP converges and Id is nonzero.
///
/// P-JFET sign convention in this model:
///   sign = -1; vgs_eff = -(Vg - Vs); vds_eff = -(Vd - Vs).
///   Device ON when vov = vgs_eff - vto > 0.
///   For vto=-2: need vgs_eff > -2.
///
/// Circuit: Source at +10V (Vss), Gate at +9V (Vg), Drain via Rd=1k to 0V.
///   vgs_eff = -(9 - 10) = 1V; vov = 1 - (-2) = 3V > 0 → ON ✓
///   vds_eff = -(Vd - 10); Vd < 10 → vds_eff > 0 ✓
///   Gate junction: vgs_eff=1V would forward-bias in N-ch equiv...
///   BUT the actual gate-to-source voltage is Vg-Vs = 9-10 = -1V (reverse biased ✓).
///
/// Use Vss=10V (node 1), Rd=1k from 0V to node 2 (drain), Gate at node 3=9V.
#[test]
fn jfet_l2_dc_op_p_channel() {
    let netlist = "\
* PJF Level 2 common-source: Vss=10V source, drain via Rd to gnd
.MODEL JP PJF LEVEL=2 VTO=-2 BETA=2e-3 LAMBDA=0.01 DELTA=0 MVST=0.5 NDS=2 HFETA=0
Vss 1 0 DC 10
Rd 2 0 1k
J1 2 3 1 JP
Vg 3 0 DC 9
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse failed");
    let result = run_dc_op(&circuit).expect("dc op failed");

    // Drain node (node 2): if P-JFET conducts, current flows from Vss (node 1=10V)
    // through J1 to drain (node 2), then through Rd=1k to gnd.
    // V(2) = Id * Rd > 0 (current flows into node 2, through Rd to gnd).
    let vd = result.node_voltages.iter()
        .find(|(n, _)| n == "2")
        .map(|(_, v)| *v)
        .expect("node 2 not found");

    // With Id flowing, V(2) = Id*Rd > 0. Expect significant current.
    let id = vd / 1000.0;
    assert!(
        id > 1e-5,
        "PJF L2: Id should be nonzero in saturation, got Id={id:.3e} V(2)={vd:.4}"
    );
}

/// (c) Same circuit with LEVEL=1 vs LEVEL=2 gives measurably different Id (>1%).
///
/// L2 uses HFETA (high-frequency gate effect) which divides Id by (1+HFETA*Vgs).
/// With HFETA=0.3 and Vgs=-0.5, the denominator = 1 + 0.3*(-0.5) = 0.85,
/// so L2 Id is ~15% lower than L1, well above the 1% threshold.
#[test]
fn jfet_l2_differs_from_l1() {
    // L1: HFETA not used (Level 1 ignores it)
    let netlist_l1 = "\
* NJF Level 1 common-source
.MODEL JN NJF LEVEL=1 VTO=-2 BETA=2e-3 LAMBDA=0.01
Vdd 1 0 DC 10
Rd 1 2 1k
J1 2 3 0 JN
Vg 3 0 DC -0.5
.OP
.END
";
    // L2: HFETA=0.3 creates a denominator effect that reduces Id by ~15%
    let netlist_l2 = "\
* NJF Level 2 common-source with HFETA
.MODEL JN NJF LEVEL=2 VTO=-2 BETA=2e-3 LAMBDA=0.01 DELTA=0 MVST=0.5 NDS=2 HFETA=0.3
Vdd 1 0 DC 10
Rd 1 2 1k
J1 2 3 0 JN
Vg 3 0 DC -0.5
.OP
.END
";
    let (ckt1, _) = parse_netlist_str(netlist_l1).expect("parse L1 failed");
    let (ckt2, _) = parse_netlist_str(netlist_l2).expect("parse L2 failed");

    let res1 = run_dc_op(&ckt1).expect("dc op L1 failed");
    let res2 = run_dc_op(&ckt2).expect("dc op L2 failed");

    let vd1 = res1.node_voltages.iter().find(|(n, _)| n == "2").map(|(_, v)| *v).unwrap();
    let vd2 = res2.node_voltages.iter().find(|(n, _)| n == "2").map(|(_, v)| *v).unwrap();

    let id1 = (10.0 - vd1) / 1000.0;
    let id2 = (10.0 - vd2) / 1000.0;

    // L2 with HFETA=0.3, Vgs=-0.5: denom=0.85 → Id_L2 ≈ Id_L1 * 0.85, so ~15% lower.
    let rel_diff = ((id1 - id2) / id1.max(id2)).abs();
    assert!(
        rel_diff > 0.01,
        "L1 vs L2 should differ by >1%: Id_L1={id1:.6e} Id_L2={id2:.6e} rel_diff={rel_diff:.4}"
    );
}

/// (d) Lambda (channel-length modulation) produces expected CLM slope in saturation.
///
/// Strategy: use a current source to force a fixed Vgs, then compare Id at two
/// different Vds values forced by two different voltage sources on the drain.
/// This isolates CLM from the load-line self-consistency that hides the effect.
///
/// For a fixed Vgs=0V, Vto=-2V → Vov=2V.  In saturation (Vds > Vov):
///   L1: Id = beta * Vov^2 * (1 + lambda*Vds)
///   L2: Id ≈ beta * veff^2 * (1 + lambda*Vds) * block(Vds)
///
/// We use Vds_lo=3V and Vds_hi=8V directly via voltage sources, measuring I(Vd).
#[test]
fn jfet_l2_lambda_clm() {
    // Circuit: Vd forces drain voltage directly; Vs=0; Vg=0.
    // Measure branch current of Vd = -Id_into_drain.
    let make_netlist = |vds: f64| {
        format!("\
* NJF L2 CLM: Vds={vds} forced
.MODEL JN NJF LEVEL=2 VTO=-2 BETA=2e-3 LAMBDA=0.1 DELTA=0 MVST=0.5 NDS=2 HFETA=0
Vd 2 0 DC {vds}
J1 2 3 0 JN
Vg 3 0 DC 0
.OP
.END
")
    };

    let (ckt_lo, _) = parse_netlist_str(&make_netlist(3.0)).expect("parse lo failed");
    let res_lo = run_dc_op(&ckt_lo).expect("dc op lo failed");

    let (ckt_hi, _) = parse_netlist_str(&make_netlist(8.0)).expect("parse hi failed");
    let res_hi = run_dc_op(&ckt_hi).expect("dc op hi failed");

    // Branch current of Vd: I(Vd) = current injected into drain.
    // The JFET drain current = -I(Vd) (Vd sources the current the JFET consumes).
    let id_lo = res_lo.branch_currents.iter()
        .find(|(n, _)| n.to_lowercase() == "vd")
        .map(|(_, v)| v.abs())
        .expect("branch current Vd_lo not found");
    let id_hi = res_hi.branch_currents.iter()
        .find(|(n, _)| n.to_lowercase() == "vd")
        .map(|(_, v)| v.abs())
        .expect("branch current Vd_hi not found");

    // lambda=0.1: Id_hi/Id_lo ≈ (1+0.1*8)/(1+0.1*3) = 1.8/1.3 ≈ 1.38 → >1.
    assert!(
        id_hi > id_lo,
        "L2 CLM: Vds=8V should give higher Id than Vds=3V. Id_lo={id_lo:.6e} Id_hi={id_hi:.6e}"
    );
    let clm_ratio = id_hi / id_lo;
    assert!(
        clm_ratio > 1.1,
        "L2 CLM: ratio Id_hi/Id_lo={clm_ratio:.4} should be >1.1 for lambda=0.1 (Vds: 3→8V)"
    );
}

/// (e) Sub-VTO (deep cutoff) gives Id ≈ 0.
#[test]
fn jfet_l2_threshold() {
    // Vgs = -5V → well below VTO = -2V → device OFF, Id ≈ 0.
    let netlist = "\
* NJF L2 threshold / cutoff test
.MODEL JN NJF LEVEL=2 VTO=-2 BETA=2e-3 LAMBDA=0.01 DELTA=0 MVST=0.5 NDS=2 HFETA=0
Vdd 1 0 DC 10
Rd 1 2 1k
J1 2 3 0 JN
Vg 3 0 DC -5
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse failed");
    let result = run_dc_op(&circuit).expect("dc op failed");

    let vd = result.node_voltages.iter()
        .find(|(n, _)| n == "2")
        .map(|(_, v)| *v)
        .expect("node 2 not found");

    // With JFET off, almost no current flows → V(2) ≈ Vdd = 10V.
    let id = (10.0 - vd) / 1000.0;
    assert!(
        id < 1e-9,
        "L2 threshold: device should be near-off, got Id={id:.3e}, V(2)={vd}"
    );
}
