//! Device model tests: BSIM3/4, BJT, VBIC, diode, JFET, B-source, poly sources.
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op};

// ── Basic device tests (from dc_op.rs) ──────────────────────────────────────

#[test]
fn device_diode_forward_bias() {
    let netlist = "\
* Diode forward bias
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(v2 > 0.4 && v2 < 0.9, "V(2) = {v2}, expected ~0.6-0.7V for forward-biased diode");
}

#[test]
fn device_cmos_inverter_basic() {
    let netlist = "\
* CMOS Inverter
VDD vdd 0 DC 3.3
VIN in 0 DC 0.7
M1 out in 0 0 NMOD W=10u L=1u
M2 out in vdd vdd PMOD W=20u L=1u
.MODEL NMOD NMOS (VTH0=0.5 KP=120u)
.MODEL PMOD PMOS (VTH0=-0.5 KP=60u)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let vout = result.node_voltages.iter().find(|(n, _)| n == "out").unwrap().1;
    assert!(vout < 3.3, "Vout={vout} should be less than VDD");
    assert!(vout >= 0.0, "Vout={vout} should be non-negative");
}

// ── B-source tests (from bsource.rs) ────────────────────────────────────────

#[test]
fn bsource_v_unity_buffer() {
    let netlist = "\
* B-source unity buffer
V1 1 0 DC 3
B1 2 0 V={V(1)}
R1 2 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!((v2 - 3.0).abs() < 1e-9, "V(2)={v2}, expected 3.0");
}

#[test]
fn bsource_v_gain_2x() {
    let netlist = "\
* B-source 2x gain
V1 1 0 DC 5
B1 2 0 V={2*V(1)}
R1 2 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!((v2 - 10.0).abs() < 1e-9, "V(2)={v2}, expected 10.0");
}

#[test]
fn bsource_v_constant() {
    let netlist = "\
* B-source constant voltage
B1 1 0 V={5}
R1 1 0 1meg
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v1 = result.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    assert!((v1 - 5.0).abs() < 1e-9, "V(1)={v1}, expected 5.0");
}

#[test]
fn bsource_i_constant_current() {
    let netlist = "\
* B-source constant 2mA current source
B1 1 0 I={0.002}
R1 1 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v1 = result.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    assert!((v1 - 2.0).abs() < 1e-9, "V(1)={v1}, expected 2.0");
}

#[test]
fn bsource_table_parses() {
    let netlist = "\
* B-source TABLE form
B1 1 0 V=TABLE {V(2)} (0,0) (1,1) (2,2)
V2 2 0 DC 1
R1 1 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), "B-source TABLE form should parse: {:?}", result.err());
}

#[test]
fn bsource_reject_laplace() {
    let netlist = "\
* LAPLACE form is unsupported
B1 1 0 V={LAPLACE(V(1))}
R1 1 0 1k
.OP
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_err(), "LAPLACE should be rejected");
}

// ── BSIM3 golden tests ───────────────────────────────────────────────────────

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
    let (circuit, _) = parse_netlist_str(&netlist).unwrap();
    let result = run_dc_op(&circuit);
    assert!(result.is_ok(), "BSIM3 NMOS saturation should converge");
}

#[test]
#[ignore = "BSIM4 golden — run with --include-ignored"]
fn bsim4_nmos_dc_op() {
    let netlist = "\
* BSIM4 NMOS basic DC OP
VDD d 0 DC 1.0
VGG g 0 DC 1.0
M1 d g 0 0 NMOD W=1u L=65n
.MODEL NMOD NMOS LEVEL=54
+ TOX=1.2e-9 VTH0=0.25 K1=0.4
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    assert!(result.is_ok(), "BSIM4 NMOS DC OP should converge");
}

#[test]
#[ignore = "BJT Gummel-Poon golden — run with --include-ignored"]
fn bjt_gummel_poon_npn_dc_op() {
    let netlist = "\
* BJT NPN common emitter
VCC c 0 DC 5
VBB b 0 DC 0.7
Q1 c b 0 QMOD
.MODEL QMOD NPN (IS=1e-16 BF=100 BR=0.1 VA=75)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    assert!(result.is_ok(), "BJT NPN DC OP should converge");
}

#[test]
#[ignore = "VBIC model golden — run with --include-ignored"]
fn vbic_npn_dc_op() {
    let netlist = "\
* VBIC NPN basic
VCC c 0 DC 3.3
VBB b 0 DC 0.8
Q1 c b 0 0 QMOD
.MODEL QMOD NPN LEVEL=4
+ IS=2e-16 BF=150 NF=1.0
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    assert!(result.is_ok(), "VBIC NPN DC OP should converge");
}

#[test]
#[ignore = "JFET L2 model — run with --include-ignored"]
fn jfet_l2_dc_op() {
    let netlist = "\
* JFET N-channel basic
VDD d 0 DC 5
VGG g 0 DC -1
J1 d g 0 JMOD
.MODEL JMOD NJF LEVEL=2 (VTO=-2 BETA=1m LAMBDA=0.01)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    assert!(result.is_ok(), "JFET L2 DC OP should converge");
}

#[test]
#[ignore = "diode extended model — run with --include-ignored"]
fn diode_extended_model_dc_op() {
    let netlist = "\
* Diode extended model
V1 1 0 DC 0.7
D1 1 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1.05 RS=5 CJO=1p VJ=0.75 M=0.4)
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit);
    assert!(result.is_ok(), "Extended diode DC OP should converge");
}
