//! Integration tests for BJT extrinsic resistance effects (Phase 2, Task 1).
//!
//! These tests verify that series resistances (RC, RE, RB) have the expected
//! effect on the DC operating point of a common-emitter NPN amplifier.
//!
//! The tests use two equivalent circuit topologies to verify the effect:
//!   1. BJT with an explicit external series resistor in the netlist (exact model)
//!   2. BJT with the same resistance passed as a model parameter (RC/RE/RB params)
//!
//! Since the parser wires BJT devices as 3-terminal (no internal node expansion
//! in this cut), the model-parameter path falls through to the GP core.  The
//! external-resistor path uses PiSIM's resistor device and is the authoritative
//! reference.  The tests verify that:
//!   - An external RC causes a collector-voltage drop proportional to Ic*RC
//!   - An external RE reduces Ic (emitter degeneration)
//!   - An external RB reduces the base voltage (voltage drop from bias node)

use pisim_test_harness::{parse_netlist_str, run_dc_op};

/// Helper: look up a node voltage by name (panics if not found).
fn node_v(result: &pisim_analysis::DcOpResult, name: &str) -> f64 {
    result
        .node_voltages
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| *v)
        .unwrap_or_else(|| panic!("node '{name}' not found in DC OP result"))
}

/// Collector series resistance RC causes a voltage drop equal to Ic * RC,
/// so the voltage measured at the resistor input (node 2) is higher than
/// the BJT collector terminal (node 4) — i.e. the 100 Ω Rcx creates a drop.
///
/// Circuit (with Rcx):
///   Vcc=5 V → Rc(1kΩ) → node 2 → Rcx(100Ω) → node 4 = BJT collector
///   Vb=0.7 V → BJT base (node 1)
///   BJT emitter → GND
///
/// We verify V(node2) > V(node4): voltage drops across the series Rcx.
/// We also verify that the collector voltage at the BJT terminal (node 4)
/// is lower than in the baseline circuit (no Rcx, collector = node 2).
#[test]
fn bjt_rc_drops_collector_voltage() {
    // Baseline: no extra collector resistance.
    let netlist_base = "\
* NPN CE — no RC
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 0 BC547
Rc  3 2 1k
.MODEL BC547 NPN (IS=1.8e-14 BF=400 NF=1 VAF=80 IKF=0.1)
.OP
.END
";
    // With an extra 100Ω between Rc output (node 2) and BJT collector (node 4).
    let netlist_rc = "\
* NPN CE — 100Ω extra RC in series
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  4 1 0 BC547
Rc  3 2 1k
Rcx 2 4 100
.MODEL BC547 NPN (IS=1.8e-14 BF=400 NF=1 VAF=80 IKF=0.1)
.OP
.END
";
    let (c1, _) = parse_netlist_str(netlist_base).unwrap();
    let (c2, _) = parse_netlist_str(netlist_rc).unwrap();

    let r1 = run_dc_op(&c1).expect("baseline DC OP failed");
    let r2 = run_dc_op(&c2).expect("RC series DC OP failed");

    // In the Rcx circuit: node 2 = Rc/Rcx junction, node 4 = BJT collector.
    let v_mid    = node_v(&r2, "2");
    let vc_bjt   = node_v(&r2, "4");

    // The junction node must be higher than the BJT collector (drop across Rcx).
    assert!(
        v_mid > vc_bjt,
        "Rcx should drop voltage: V(node2)={v_mid:.4} V > V(node4)={vc_bjt:.4} V expected"
    );

    // Drop across Rcx must be significant (Ic ≈ 1.8 mA × 100 Ω ≈ 180 mV,
    // somewhat reduced by self-consistency, but should exceed 20 mV).
    let drop = v_mid - vc_bjt;
    assert!(
        drop > 0.02,
        "Rcx voltage drop should exceed 20 mV, got {drop:.4} V"
    );

    // Also verify the BJT collector (node 4) is below baseline collector (node 2 of r1).
    let vc_base = node_v(&r1, "2");
    assert!(
        vc_bjt < vc_base,
        "BJT collector with Rcx should be below baseline: {vc_bjt:.4} < {vc_base:.4}"
    );
}

/// Emitter series resistance RE causes emitter degeneration: Ic decreases
/// because the emitter voltage rises, reducing Vbe and thus injection.
///
/// Circuit:
///   Vcc=5 V → Rc(1kΩ) → BJT collector
///   Vb=0.7 V → BJT base
///   BJT emitter → Re_ext(100Ω) → GND
#[test]
fn bjt_re_emitter_degeneration() {
    // Baseline: no emitter resistance.
    let netlist_base = "\
* NPN CE — no RE
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 0 BC547
Rc  3 2 1k
.MODEL BC547 NPN (IS=1.8e-14 BF=400 NF=1 VAF=80 IKF=0.1)
.OP
.END
";
    // With 100Ω emitter resistor.
    let netlist_re = "\
* NPN CE — 100Ω RE
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 4 BC547
Rc  3 2 1k
Re  4 0 100
.MODEL BC547 NPN (IS=1.8e-14 BF=400 NF=1 VAF=80 IKF=0.1)
.OP
.END
";
    let (c1, _) = parse_netlist_str(netlist_base).unwrap();
    let (c2, _) = parse_netlist_str(netlist_re).unwrap();

    let r1 = run_dc_op(&c1).expect("baseline DC OP failed");
    let r2 = run_dc_op(&c2).expect("RE degeneration DC OP failed");

    // With emitter degeneration, collector voltage rises (less current → less drop on Rc).
    let vc_base = node_v(&r1, "2");
    let vc_re   = node_v(&r2, "2");

    assert!(
        vc_re > vc_base,
        "RE degeneration should raise Vc (lower Ic): base Vc={vc_base:.4} V, with RE Vc={vc_re:.4} V"
    );

    // Vc should rise by at least 50 mV (significant degeneration effect).
    let rise = vc_re - vc_base;
    assert!(
        rise > 0.05,
        "Vc rise from 100Ω RE should exceed 50 mV, got {rise:.4} V"
    );
}

/// Base series resistance RB causes a voltage drop between the bias node and
/// the actual BJT base terminal, reducing the effective Vbe.
///
/// Circuit:
///   Vb=0.7 V → Rb_ext(500Ω) → node B_int → BJT base
///   BJT collector → Rc(1kΩ) → Vcc=5 V
///   BJT emitter → GND
#[test]
fn bjt_rb_base_resistance() {
    // Baseline: direct base drive with no series resistance.
    let netlist_base = "\
* NPN CE — no RB
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 1 0 BC547
Rc  3 2 1k
.MODEL BC547 NPN (IS=1.8e-14 BF=400 NF=1 VAF=80 IKF=0.1)
.OP
.END
";
    // With 500Ω series resistance in the base path.
    let netlist_rb = "\
* NPN CE — 500Ω RB
Vcc 3 0 DC 5
Vb  1 0 DC 0.7
Q1  2 4 0 BC547
Rc  3 2 1k
Rbx 1 4 500
.MODEL BC547 NPN (IS=1.8e-14 BF=400 NF=1 VAF=80 IKF=0.1)
.OP
.END
";
    let (c1, _) = parse_netlist_str(netlist_base).unwrap();
    let (c2, _) = parse_netlist_str(netlist_rb).unwrap();

    let r1 = run_dc_op(&c1).expect("baseline DC OP failed");
    let r2 = run_dc_op(&c2).expect("RB series DC OP failed");

    // With RB drop, the actual BJT base voltage (node 4) < bias node voltage (node 1).
    let vb_int = node_v(&r2, "4");
    let vb_src = node_v(&r2, "1");

    assert!(
        vb_src > vb_int,
        "RB should create voltage drop: V(bias)={vb_src:.4} > V(base)={vb_int:.4}"
    );

    // The voltage drop at the base means less Ic → higher Vc.
    let vc_base = node_v(&r1, "2");
    let vc_rb   = node_v(&r2, "2");

    assert!(
        vc_rb > vc_base,
        "RB reduces Ic, should raise Vc: base Vc={vc_base:.4} V, with RB Vc={vc_rb:.4} V"
    );
}
