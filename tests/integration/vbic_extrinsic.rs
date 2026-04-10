//! Integration tests for VBIC extrinsic resistance effects (Phase 2, Task 2).
//!
//! These tests verify that VBIC collector and emitter series resistances
//! (rcx/rci for RC, re for RE) produce the expected DC operating-point effects
//! when modeled as explicit external resistors in the netlist.
//!
//! The VBIC model (LEVEL=4) is used for both baseline and comparison circuits.
//! Resistances are inserted as explicit netlist elements to exercise the full
//! solver path with the correct topology.

use pisim_test_harness::{parse_netlist_str, run_dc_op};

/// Helper: look up a node voltage by name.
fn node_v(result: &pisim_analysis::DcOpResult, name: &str) -> f64 {
    result
        .node_voltages
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| *v)
        .unwrap_or_else(|| panic!("node '{name}' not found in DC OP result"))
}

/// VBIC collector resistance (rcx) causes a voltage drop at the collector terminal.
///
/// Circuit topology:
///   Vcc=5 V → Rc(1kΩ) → node_mid → Rcx(150Ω) → BJT collector
///   Vb=0.7 V → BJT base
///   BJT emitter → GND
///   BJT substrate → GND
///
/// The BJT collector terminal voltage (node after Rcx) must be lower than
/// the baseline collector voltage (no Rcx).
#[test]
fn vbic_rcx_collector_drop() {
    let model = ".MODEL qv NPN (LEVEL=4 is=3.5e-15 nf=1.0 nr=1.0 vef=100 ver=10 \
                  ibei=1.75e-17 nei=1.0 ikf=0.03)";

    // Baseline: no extra collector resistance.
    let netlist_base = format!("\
* VBIC CE — no rcx
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 0 0 qv
Rc  3 2 1k
{model}
.OP
.END
");
    // With 150Ω collector series resistance inserted between Rc and BJT.
    let netlist_rcx = format!("\
* VBIC CE — 150Ω rcx
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  4 1 0 0 qv
Rc  3 2 1k
Rcx 2 4 150
{model}
.OP
.END
");
    let (c1, _) = parse_netlist_str(&netlist_base).unwrap();
    let (c2, _) = parse_netlist_str(&netlist_rcx).unwrap();

    let r1 = run_dc_op(&c1).expect("VBIC baseline DC OP failed");
    let r2 = run_dc_op(&c2).expect("VBIC rcx DC OP failed");

    let vc_base = node_v(&r1, "2");
    let vc_rcx  = node_v(&r2, "4"); // collector terminal of BJT

    assert!(
        vc_rcx < vc_base,
        "rcx should drop BJT collector voltage: base Vc={vc_base:.4} V, with rcx Vc={vc_rcx:.4} V"
    );

    // The additional 150Ω at ~1.8 mA nominal current should drop ≥ 100 mV.
    let drop = vc_base - vc_rcx;
    assert!(
        drop > 0.05,
        "Vc drop from 150Ω rcx should exceed 50 mV, got {drop:.4} V"
    );
}

/// VBIC emitter resistance (re) causes emitter degeneration: lower Ic.
///
/// Circuit topology:
///   Vcc=5 V → Rc(1kΩ) → BJT collector
///   Vb=0.7 V → BJT base
///   BJT emitter → Re(100Ω) → GND
///   BJT substrate → GND
///
/// With RE the effective Vbe is reduced, so Ic decreases and Vc rises.
#[test]
fn vbic_re_emitter_degeneration() {
    let model = ".MODEL qv NPN (LEVEL=4 is=3.5e-15 nf=1.0 nr=1.0 vef=100 ver=10 \
                  ibei=1.75e-17 nei=1.0 ikf=0.03)";

    // Baseline: emitter directly to GND.
    let netlist_base = format!("\
* VBIC CE — no re
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 0 0 qv
Rc  3 2 1k
{model}
.OP
.END
");
    // With 100Ω emitter resistance.
    let netlist_re = format!("\
* VBIC CE — 100Ω re
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 4 0 qv
Rc  3 2 1k
Re  4 0 100
{model}
.OP
.END
");
    let (c1, _) = parse_netlist_str(&netlist_base).unwrap();
    let (c2, _) = parse_netlist_str(&netlist_re).unwrap();

    let r1 = run_dc_op(&c1).expect("VBIC baseline DC OP failed");
    let r2 = run_dc_op(&c2).expect("VBIC re degeneration DC OP failed");

    let vc_base = node_v(&r1, "2");
    let vc_re   = node_v(&r2, "2");

    // With RE, Ic is lower → less drop across Rc → Vc rises.
    assert!(
        vc_re > vc_base,
        "RE degeneration should raise Vc: base Vc={vc_base:.4} V, with RE Vc={vc_re:.4} V"
    );

    // Vc should rise by at least 50 mV.
    let rise = vc_re - vc_base;
    assert!(
        rise > 0.05,
        "Vc rise from 100Ω RE should exceed 50 mV, got {rise:.4} V"
    );
}
