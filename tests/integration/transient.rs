//! Transient analysis integration tests.
//!
//! Most are #[ignore] because the transient engine is a stub.

use pisim_test_harness::{parse_netlist_str, run_transient, Tolerance};

#[test]
fn tran_pure_resistive_constant() {
    let netlist = "\
* Resistive transient
V1 1 0 DC 5
R1 1 0 1k
.TRAN 1n 10n
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_transient(&circuit, 1e-9, 10e-9).unwrap();

    assert!(result.times.len() >= 5);
    for voltages in &result.node_voltages {
        assert!(
            Tolerance::within(voltages[0], 5.0, 1e-6, 1e-4),
            "V(1) = {}, expected 5.0 (constant for resistive)",
            voltages[0]
        );
    }
}

#[test]
#[ignore = "requires capacitor companion model in transient engine"]
fn tran_rc_step_response() {
    let netlist = "\
* RC step response
V1 in 0 DC 5
R1 in out 1k
C1 out 0 1n
.TRAN 0.1n 10n
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_transient(&circuit, 0.1e-9, 10e-9).unwrap();

    let rc = 1e3 * 1e-9;
    for (i, &t) in result.times.iter().enumerate() {
        let expected = 5.0 * (1.0 - (-t / rc).exp());
        let actual = result.node_voltages[i][1];
        assert!(
            Tolerance::within(actual, expected, 1e-6, 1e-4),
            "t={t}: V(out)={actual}, expected {expected}"
        );
    }
}

#[test]
#[ignore = "requires capacitor companion model in transient engine"]
fn tran_rc_time_constant() {
    let netlist = std::fs::read_to_string("tests/fixtures/basic/rc_transient.sp")
        .expect("fixture missing");
    let (circuit, _) = parse_netlist_str(&netlist).unwrap();
    let result = run_transient(&circuit, 0.1e-9, 10e-9).unwrap();

    let rc = 1e-6;
    let idx = result.times.iter().position(|&t| t >= rc).unwrap();
    let v_at_rc = result.node_voltages[idx][1];
    let expected = 5.0 * 0.6321;
    assert!(
        Tolerance::within(v_at_rc, expected, 1e-3, 1e-2),
        "V(out) at t=RC: {v_at_rc}, expected ~{expected}"
    );
}

#[test]
fn tran_rl_step_response() {
    let netlist = "\
* RL step response
V1 1 0 DC 5
R1 1 2 1k
L1 2 0 1m
.TRAN 1u 10m
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let _result = run_transient(&circuit, 1e-6, 10e-3).unwrap();
}

#[test]
#[ignore = "requires nonlinear transient with MOSFET models"]
fn tran_ring_oscillator_period() {
    let netlist = "\
* 9-stage ring oscillator
VDD vdd 0 DC 3.3
M1 n1 n9 0 0 NMOD W=10u L=1u
M10 n1 n9 vdd vdd PMOD W=20u L=1u
M2 n2 n1 0 0 NMOD W=10u L=1u
M11 n2 n1 vdd vdd PMOD W=20u L=1u
M3 n3 n2 0 0 NMOD W=10u L=1u
M12 n3 n2 vdd vdd PMOD W=20u L=1u
M4 n4 n3 0 0 NMOD W=10u L=1u
M13 n4 n3 vdd vdd PMOD W=20u L=1u
M5 n5 n4 0 0 NMOD W=10u L=1u
M14 n5 n4 vdd vdd PMOD W=20u L=1u
M6 n6 n5 0 0 NMOD W=10u L=1u
M15 n6 n5 vdd vdd PMOD W=20u L=1u
M7 n7 n6 0 0 NMOD W=10u L=1u
M16 n7 n6 vdd vdd PMOD W=20u L=1u
M8 n8 n7 0 0 NMOD W=10u L=1u
M17 n8 n7 vdd vdd PMOD W=20u L=1u
M9 n9 n8 0 0 NMOD W=10u L=1u
M18 n9 n8 vdd vdd PMOD W=20u L=1u
.MODEL NMOD NMOS (VTH0=0.5 KP=120u)
.MODEL PMOD PMOS (VTH0=-0.5 KP=60u)
.TRAN 0.1n 100n
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_transient(&circuit, 0.1e-9, 100e-9).unwrap();

    let vdd_half = 1.65;
    let crossings: usize = result.node_voltages.windows(2)
        .filter(|w| {
            let v0 = w[0][0];
            let v1 = w[1][0];
            (v0 < vdd_half && v1 >= vdd_half) || (v0 >= vdd_half && v1 < vdd_half)
        })
        .count();
    assert!(crossings >= 4, "Ring oscillator should have multiple crossings, got {crossings}");
}
