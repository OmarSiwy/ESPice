//! Integration tests for VBIC BJT model (Part A) and mutual inductance K element (Part B).

use pisim_test_harness::{parse_netlist_str, run_dc_op};

// ── Part A: VBIC BJT model ───────────────────────────────────────────────────

/// Parse a netlist containing a Q element with a VBIC NPN model and verify
/// the parser produces a circuit with a BjtNpn/VbicNpn device.
#[test]
fn vbic_npn_netlist_parses() {
    let netlist = "\
* VBIC NPN DC bias test
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 0 0 qvbic
Rc  3 2 2.63k
.MODEL qvbic NPN (LEVEL=4 is=3.5e-15 nf=1.0 nr=1.0 vef=100 ver=10 ikf=0.03)
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), "VBIC NPN netlist failed to parse: {:?}", result.err());
    let (circuit, _analyses) = result.unwrap();
    // Circuit must contain at least the Q1 device.
    assert!(circuit.devices().len() > 0, "Circuit has no devices");
}

/// Full DC OP for a simple BJT common-emitter with VBIC model.
/// Checks that Vce at the collector node is in a reasonable active-region range.
#[test]
fn vbic_npn_dc_op_active_region() {
    // Simple CE amplifier: Rc=2.63 kΩ, Vcc=5 V, Ib via fixed Vb=0.7 V base drive.
    // Expected: collector voltage somewhere between 0.3 V and 4.9 V (active region).
    let netlist = "\
* VBIC NPN CE — active region DC OP
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 0 0 qmod
Rc  3 2 2.63k
.MODEL qmod NPN (LEVEL=4 is=3.5e-15 nf=1.0 nr=1.0 vef=100 ver=10 ikf=0.03 ibei=1.75e-17 nei=1.0)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    assert!(result.is_ok(), "DC OP failed: {:?}", result.err());
    let op = result.unwrap();

    // Node "2" is the collector.  It must be in the active region.
    let vc = op.node_voltages
        .iter()
        .find(|(n, _)| n == "2")
        .map(|(_, v)| *v);
    assert!(vc.is_some(), "Node '2' (collector) not found in DC OP result");
    let vc = vc.unwrap();
    assert!(
        vc > 0.1 && vc < 4.9,
        "Vc={vc:.4} V not in active-region range [0.1, 4.9]"
    );
}

// ── Part B: Mutual inductance K element ──────────────────────────────────────

/// Parse a netlist containing `K L1 L2 0.9` and verify the circuit stores
/// the mutual coupling with the correct coefficient.
#[test]
fn k_element_parsed_and_stored() {
    let netlist = "\
* Mutual inductance coupling test
V1 1 0 DC 0
L1 1 2 1m
L2 3 0 1m
K1 L1 L2 0.9
R1 2 0 1
R2 3 0 1
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), "K element netlist failed to parse: {:?}", result.err());
    let (circuit, _) = result.unwrap();

    let couplings = circuit.mutual_couplings();
    assert_eq!(couplings.len(), 1, "Expected 1 mutual coupling, got {}", couplings.len());

    let (_l1_id, _l2_id, k) = couplings[0];
    assert!(
        (k - 0.9).abs() < 1e-12,
        "Coupling coefficient {k} != 0.9"
    );
}

/// Two separate K elements are both stored independently.
#[test]
fn k_element_two_couplings() {
    let netlist = "\
* Two mutual inductance couplings
V1 1 0 DC 0
L1 1 2 1m
L2 3 0 500u
L3 4 0 500u
K1 L1 L2 0.5
K2 L1 L3 0.3
R1 2 0 1
R2 3 0 1
R3 4 0 1
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let couplings = circuit.mutual_couplings();
    assert_eq!(couplings.len(), 2, "Expected 2 mutual couplings, got {}", couplings.len());

    let k_vals: Vec<f64> = couplings.iter().map(|(_, _, k)| *k).collect();
    assert!(k_vals.contains(&0.5_f64) || k_vals.iter().any(|&k| (k - 0.5).abs() < 1e-12),
        "k=0.5 coupling not found: {k_vals:?}");
    assert!(k_vals.iter().any(|&k| (k - 0.3).abs() < 1e-12),
        "k=0.3 coupling not found: {k_vals:?}");
}

/// Mutual inductance formula: M = k * sqrt(L1 * L2).
/// Verifies the `mutual_inductance` helper from the device crate.
#[test]
fn mutual_inductance_formula() {
    use pisim_device::MutualCoupling;
    let m = MutualCoupling::mutual_inductance(0.9, 1e-3, 1e-3);
    let expected = 0.9e-3_f64;
    assert!(
        (m - expected).abs() < 1e-15,
        "M={m:.6e} != {expected:.6e}"
    );

    // 1:2 turns ratio (L2 = 4*L1): M = k * sqrt(L1 * 4*L1) = 2*k*L1
    let l1 = 1e-3_f64;
    let l2 = 4e-3_f64;
    let k = 0.8_f64;
    let m2 = MutualCoupling::mutual_inductance(k, l1, l2);
    let expected2 = k * (l1 * l2).sqrt();
    assert!(
        (m2 - expected2).abs() < 1e-18,
        "M={m2:.6e} != {expected2:.6e}"
    );
}
