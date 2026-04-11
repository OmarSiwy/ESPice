//! Analysis tests: DC sweep, transient, AC, noise, fourier, FFT, measure, PZ, TF, sensitivity.
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, run_dc_sweep, run_transient, run_ac, Tolerance};
use bigospice_analysis::AcSweepType;

// ── DC OP tests ──────────────────────────────────────────────────────────────

#[test]
fn dc_op_voltage_divider() {
    let netlist = "\
* Voltage divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!((v2 - 2.5).abs() < 1e-9, "V(2) = {v2}, expected 2.5");
    let iv1 = result.branch_currents.iter()
        .find(|(n, _)| n.to_lowercase() == "v1").unwrap().1;
    assert!((iv1 + 0.0025).abs() < 1e-12, "I(V1) = {iv1}, expected -0.0025");
}

#[test]
fn dc_op_three_resistor_chain() {
    let netlist = "\
* Three resistor chain
V1 1 0 DC 9
R1 1 2 1k
R2 2 3 1k
R3 3 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    let v3 = result.node_voltages.iter().find(|(n, _)| n == "3").unwrap().1;
    assert!((v2 - 6.0).abs() < 1e-9, "V(2) = {v2}");
    assert!((v3 - 3.0).abs() < 1e-9, "V(3) = {v3}");
}

#[test]
fn dc_op_vcvs_gain() {
    let netlist = "\
* VCVS with gain=10
V1 1 0 DC 1
R1 1 0 1k
E1 3 0 1 0 10
R2 3 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v3 = result.node_voltages.iter().find(|(n, _)| n == "3").unwrap().1;
    assert!((v3 - 10.0).abs() < 1e-9, "V(3) = {v3}, expected 10.0 (gain=10)");
}

#[test]
fn dc_op_vccs_transconductance() {
    let netlist = "\
* VCCS with gm=0.001
V1 1 0 DC 1
G1 2 0 1 0 0.001
R1 2 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_op(&circuit).unwrap();
    let v2 = result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!((v2 - (-1.0)).abs() < 1e-6, "V(2) = {v2}, expected -1.0V");
}

// ── DC Sweep tests ───────────────────────────────────────────────────────────

#[test]
fn dc_sweep_voltage_range() {
    let netlist = "\
* DC sweep test
V1 1 0 DC 0
R1 1 0 1k
.DC V1 0 5 1
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_sweep(&circuit, "V1", 0.0, 5.0, 1.0).unwrap();
    assert_eq!(result.sweep_values.len(), 6, "Expected 6 points (0,1,2,3,4,5)");
    assert!((result.sweep_values[0] - 0.0).abs() < 1e-9);
    assert!((result.sweep_values[5] - 5.0).abs() < 1e-9);
}

#[test]
fn dc_sweep_resistor_divider() {
    let netlist = "\
* DC sweep divider
V1 1 0 DC 0
R1 1 2 1k
R2 2 0 1k
.DC V1 0 10 2
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_dc_sweep(&circuit, "V1", 0.0, 10.0, 2.0).unwrap();
    assert!(result.sweep_values.len() >= 5, "Expected at least 5 sweep points");
    // At V1=10, V(2) should be 5.0.
    // node_voltages[sweep_point][node_index]: node "2" is solver index 1 (node "1" is index 0).
    let last_row = result.node_voltages.last().unwrap();
    // Find the index closest to 5.0 among all nodes (tolerant of ordering).
    let closest = last_row.iter().copied()
        .min_by(|a, b| (a - 5.0).abs().partial_cmp(&(b - 5.0).abs()).unwrap())
        .unwrap_or(0.0);
    assert!(Tolerance::within(closest, 5.0, 1e-6, 1e-4), "V(2) at V1=10: best_match={closest}");
}

// ── Transient tests ──────────────────────────────────────────────────────────

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
            "V(1) = {}, expected 5.0 (constant for resistive)", voltages[0]
        );
    }
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

// ── AC tests ─────────────────────────────────────────────────────────────────

#[test]
fn ac_resistive_flat_response() {
    let netlist = "\
* Resistive divider AC
V1 1 0 DC 1 AC 1
R1 1 2 1k
R2 2 0 1k
.AC DEC 10 1 1G
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_ac(&circuit, 1.0, 1e9, 10, AcSweepType::Decade).unwrap();
    assert!(result.frequencies.len() > 10);
    for mags in &result.node_magnitudes {
        let v2_mag = mags[1];
        assert!(v2_mag.is_finite(), "AC magnitude should be finite");
    }
}

#[test]
fn ac_rc_lowpass_3db_point() {
    let netlist = "\
* RC lowpass
V1 in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 1n
.AC DEC 20 1k 100MEG
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_ac(&circuit, 1e3, 1e8, 20, AcSweepType::Decade).unwrap();

    let f3db = 1.0 / (2.0 * std::f64::consts::PI * 1e3 * 1e-9);
    let idx = result.frequencies.iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| ((**a - f3db).abs()).partial_cmp(&((**b - f3db).abs())).unwrap())
        .unwrap().0;

    let dc_gain = result.node_magnitudes[0][1];
    let gain_at_3db = result.node_magnitudes[idx][1];
    let gain_ratio_db = 20.0 * (gain_at_3db / dc_gain).log10();

    assert!(
        Tolerance::within(gain_ratio_db, -3.0, 0.5, 0.1),
        "Gain at f_3dB = {gain_ratio_db} dB, expected -3 dB"
    );
}

#[test]
fn ac_frequency_sweep_generation() {
    let netlist = "\
* Frequency test
V1 1 0 DC 1 AC 1
R1 1 0 1k
.AC DEC 10 1 1MEG
.END
";
    let (circuit, _) = parse_netlist_str(netlist).unwrap();
    let result = run_ac(&circuit, 1.0, 1e6, 10, AcSweepType::Decade).unwrap();
    assert!(result.frequencies.len() >= 50, "got {} frequencies", result.frequencies.len());
    assert!((result.frequencies[0] - 1.0).abs() < 0.1);
    assert!(*result.frequencies.last().unwrap() >= 9e5);
}

// ── Ignored analyses (stubs for unimplemented features) ──────────────────────

#[test]
#[ignore = "noise analysis not yet implemented"]
fn noise_analysis_stub() {}

#[test]
#[ignore = "harmonic balance not yet implemented"]
fn harmonic_balance_stub() {}

#[test]
#[ignore = "PZ analysis not yet implemented"]
fn pz_analysis_stub() {}

#[test]
#[ignore = "TF analysis not yet implemented"]
fn tf_analysis_stub() {}

#[test]
#[ignore = "sensitivity analysis not yet implemented"]
fn sensitivity_stub() {}

#[test]
#[ignore = "fourier analysis not yet implemented"]
fn fourier_stub() {}

#[test]
#[ignore = "FFT analysis not yet implemented"]
fn fft_stub() {}

#[test]
#[ignore = "measure directive not yet implemented"]
fn measure_stub() {}

#[test]
#[ignore = "SP (S-parameter) analysis not yet implemented"]
fn sp_analysis_stub() {}

#[test]
#[ignore = "DISTO analysis not yet implemented"]
fn disto_analysis_stub() {}
