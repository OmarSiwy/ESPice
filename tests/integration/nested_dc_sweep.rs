//! Nested two-source DC sweep integration tests.
//!
//! Verifies that `.DC V1 ... V2 ...` (two nested sources) produces a correct
//! 2-D result grid where each cell holds an independent DC operating point.

use pisim_analysis::dc_op::run_nested_dc_sweep;
use pisim_analysis::sweep::{ParamSweep, ParamTarget};
use pisim_device::DeviceRegistry;
use pisim_parser::SpiceParser;

/// Two voltage sources V1 and V2 each swept over 3 values → 3×3 = 9 cells.
///
/// Circuit: V1 drives node 1 (through R1=1k to node 2), V2 drives node 2
/// (through R2=1k to ground).  The DC OP at each grid cell should satisfy
/// basic KVL/KCL.
#[test]
fn nested_dc_sweep_2d_grid() {
    // Simple two-source circuit:
    //   V1 1 0 DC <outer>    — sets V(1)
    //   R1 1 2  1k
    //   V2 2 0 DC <inner>    — overrides V(2) independently (voltage source)
    //   R2 2 0  1k           — load at node 2
    //
    // With V2 as a fixed voltage source it clamps V(2)=inner_val regardless
    // of R1/R2.  V(1)=outer_val.  This makes the grid trivial to verify.
    let netlist = "\
* Nested DC sweep test circuit
V1 1 0 DC 1
V2 2 0 DC 1
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (circuit, _, _) = SpiceParser::parse(netlist).unwrap();
    let registry = DeviceRegistry::default();

    // Outer sweep: V1 dc ∈ {1, 2, 3}
    let outer = ParamSweep::list(
        ParamTarget::DeviceParam("v1".into(), "dc".into()),
        vec![1.0, 2.0, 3.0],
    );
    // Inner sweep: V2 dc ∈ {0.5, 1.0, 1.5}
    let inner = ParamSweep::list(
        ParamTarget::DeviceParam("v2".into(), "dc".into()),
        vec![0.5, 1.0, 1.5],
    );

    let grid = run_nested_dc_sweep(&circuit, &registry, &outer, &inner).unwrap();

    // Shape: 3 outer rows × 3 inner columns.
    assert_eq!(grid.len(), 3, "expected 3 outer rows");
    for row in &grid {
        assert_eq!(row.len(), 3, "expected 3 inner columns per row");
    }

    // Verify: V(2) (clamped by V2) should equal the inner sweep value.
    for (oi, row) in grid.iter().enumerate() {
        for (ii, cell) in row.iter().enumerate() {
            let expected_v2 = inner.values[ii];
            let v2 = cell
                .result
                .node_voltages
                .iter()
                .find(|(n, _)| n == "2")
                .map(|(_, v)| *v)
                .unwrap_or(f64::NAN);
            assert!(
                (v2 - expected_v2).abs() < 1e-4,
                "grid[{oi}][{ii}]: V(2)={v2:.6} expected {expected_v2:.6}"
            );
        }
    }
}
