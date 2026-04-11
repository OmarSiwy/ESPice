//! Linear algebra correctness tests (sparse LU, BTF, KLU).
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, Tolerance};

#[test]
fn sparse_lu_voltage_divider() {
    // Exercises the full sparse LU path via a simple 2-node circuit.
    let netlist = "* Voltage divider\nV1 1 0 DC 10\nR1 1 2 2k\nR2 2 0 2k\n.OP\n.END\n";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    let v2 = res.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(Tolerance::within(v2, 5.0, 1e-9, 1e-9), "V(2)={v2}");
}

#[test]
fn sparse_lu_large_resistor_ladder() {
    // 100-node resistor ladder — stresses sparse LU fill-in.
    let mut netlist = String::from("* 100-node resistor ladder\nV1 1 0 DC 1\n");
    for i in 1..=99usize {
        netlist.push_str(&format!("R{i} {i} {} 1k\n", i + 1));
    }
    netlist.push_str("R100 100 0 1k\n.OP\n.END\n");
    let (ckt, _) = parse_netlist_str(&netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    let v1 = res.node_voltages.iter().find(|(n, _)| n == "1").map(|(_, v)| *v).unwrap_or(0.0);
    let v100 = res.node_voltages.iter().find(|(n, _)| n == "100").map(|(_, v)| *v).unwrap_or(0.0);
    assert!(v1 > v100, "v1={v1} should be > v100={v100}");
}

#[test]
fn sparse_lu_three_node_mesh() {
    let netlist = "\
* Three resistor chain
V1 1 0 DC 9
R1 1 2 1k
R2 2 3 1k
R3 3 0 1k
.OP
.END
";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    let v2 = res.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    let v3 = res.node_voltages.iter().find(|(n, _)| n == "3").unwrap().1;
    assert!(Tolerance::within(v2, 6.0, 1e-9, 1e-9), "V(2)={v2}");
    assert!(Tolerance::within(v3, 3.0, 1e-9, 1e-9), "V(3)={v3}");
}
