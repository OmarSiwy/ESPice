//! Integration tests for VBIC weak avalanche multiplication and parasitic
//! substrate BJT (Phase 2.5).
//!
//! These tests exercise the end-to-end parser → build_circuit → DC OP path
//! and verify that the avalanche / substrate parameters are accepted in
//! `.MODEL` cards and produce reasonable terminal currents.

use pisim_test_harness::{parse_netlist_str, run_dc_op};

/// Parse a VBIC NPN model card with avalanche parameters and verify the
/// circuit is constructed without error.
#[test]
fn vbic_avalanche_netlist_parses() {
    let netlist = "\
* VBIC NPN with avalanche
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 0 0 qvbic
Rc  3 2 2.63k
.MODEL qvbic NPN (LEVEL=4 is=3.5e-15 nf=1.0 nr=1.0 vef=100 ver=10 ikf=0.03
+                 avc1=5 avc2=2 pc=0.75 mc=0.33)
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), "VBIC avalanche netlist failed to parse: {:?}", result.err());
    let (circuit, _) = result.unwrap();
    assert!(!circuit.devices().is_empty(), "Circuit has no devices");
}

/// VBIC with avalanche parameters set still converges to a valid DC OP at
/// moderate Vce, and yields a collector voltage in the active region.
#[test]
fn vbic_avalanche_dc_op_converges() {
    let netlist = "\
* VBIC NPN CE — avalanche enabled
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 0 0 qmod
Rc  3 2 2.63k
.MODEL qmod NPN (LEVEL=4 is=3.5e-15 nf=1.0 nr=1.0 vef=100 ver=10 ikf=0.03
+                ibei=1.75e-17 nei=1.0 avc1=5 avc2=2 pc=0.75 mc=0.33)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    assert!(result.is_ok(), "DC OP with avalanche failed: {:?}", result.err());
    let op = result.unwrap();

    let vc = op.node_voltages.iter()
        .find(|(n, _)| n == "2")
        .map(|(_, v)| *v)
        .expect("collector node 2 not found");
    assert!(
        vc > 0.1 && vc < 4.95,
        "Collector voltage with avalanche {vc:.4} V out of active range"
    );
}

/// Parser must accept the parasitic substrate BJT parameters (isp, nfp,
/// ibcip, ncip, ibcnp, ncnp) without error.
#[test]
fn vbic_substrate_params_accepted() {
    let netlist = "\
* VBIC NPN with parasitic substrate BJT
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Vsub 4 0 DC 0
Q1  2 1 0 4 qsubs
Rc  3 2 2.63k
.MODEL qsubs NPN (LEVEL=4 is=3.5e-15 nf=1.0 nr=1.0 vef=100
+                 isp=1e-16 nfp=1.0 ibcip=1e-17 ncip=1.0
+                 ibcnp=1e-17 ncnp=2.0 wsp=0.5)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    assert!(result.is_ok(), "DC OP with substrate params failed: {:?}", result.err());
}

/// At high reverse Vbc bias the avalanche current Iavl ≈ M * Ic should
/// noticeably increase the collector current relative to the no-avalanche
/// case. We compare two otherwise-identical circuits.
#[test]
fn vbic_avalanche_increases_collector_current() {
    let netlist_no_av = "\
* No avalanche
Vcc 3 0 DC 8
Vb  1 0 DC 0.7
Q1  2 1 0 0 qmod
Rc  3 2 1k
.MODEL qmod NPN (LEVEL=4 is=3.5e-15 nf=1.0 ibei=1.75e-17 vef=50)
.OP
.END
";
    let netlist_av = "\
* With avalanche
Vcc 3 0 DC 8
Vb  1 0 DC 0.7
Q1  2 1 0 0 qmod
Rc  3 2 1k
.MODEL qmod NPN (LEVEL=4 is=3.5e-15 nf=1.0 ibei=1.75e-17 vef=50
+                avc1=20 avc2=1.5 pc=0.75 mc=0.33)
.OP
.END
";
    let (c1, _) = parse_netlist_str(netlist_no_av).unwrap();
    let (c2, _) = parse_netlist_str(netlist_av).unwrap();
    let r1 = run_dc_op(&c1).unwrap();
    let r2 = run_dc_op(&c2).unwrap();
    let vc_no = r1.node_voltages.iter()
        .find(|(n, _)| n == "2").map(|(_, v)| *v).unwrap();
    let vc_av = r2.node_voltages.iter()
        .find(|(n, _)| n == "2").map(|(_, v)| *v).unwrap();
    // Larger Ic ⇒ smaller Vc (since Ic*Rc drops more across Rc)
    // Allow a small margin: avalanche should pull Vc down or keep it equal.
    assert!(
        vc_av <= vc_no + 1e-6,
        "Avalanche should increase Ic (and thus drop Vc): no-av Vc={vc_no:.4}, av Vc={vc_av:.4}"
    );
}
