//! Solver correctness: Newton-Raphson, convergence, gmin stepping.
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, Tolerance};

#[test]
fn newton_converges_linear_circuit() {
    let netlist = "* Simple linear\nV1 1 0 DC 5\nR1 1 0 1k\n.OP\n.END\n";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    let v1 = res.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    assert!(Tolerance::within(v1, 5.0, 1e-12, 1e-12), "V(1)={v1}");
}

#[test]
fn newton_converges_diode_nonlinear() {
    // Nonlinear circuit — tests Newton convergence on exponential device.
    let netlist = "\
* Diode
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    let v2 = res.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(v2 > 0.4 && v2 < 0.9, "V(2)={v2}");
}

#[test]
fn gmin_stepping_near_cutoff_mosfet() {
    // MOSFET near cutoff — exercises gmin-stepping convergence aid.
    let netlist = "\
* MOSFET near cutoff
VDD vdd 0 DC 3.3
VIN in 0 DC 0.4
M1 out in 0 0 NMOD W=10u L=1u
.MODEL NMOD NMOS (VTH0=0.5 KP=120u)
.OP
.END
";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    // Should not panic — if MOSFET is off, out floats near 0.
    let _ = run_dc_op(&ckt);
}

#[test]
fn newton_vcvs_gain() {
    let netlist = "\
* VCVS with gain=10
V1 1 0 DC 1
R1 1 0 1k
E1 3 0 1 0 10
R2 3 0 1k
.OP
.END
";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    let v3 = res.node_voltages.iter().find(|(n, _)| n == "3").unwrap().1;
    assert!(Tolerance::within(v3, 10.0, 1e-9, 1e-9), "V(3)={v3}");
}

#[test]
fn newton_vccs_transconductance() {
    let netlist = "\
* VCCS with gm=0.001
V1 1 0 DC 1
G1 2 0 1 0 0.001
R1 2 0 1k
.OP
.END
";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    let v2 = res.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(Tolerance::within(v2, -1.0, 1e-6, 1e-6), "V(2)={v2}");
}
