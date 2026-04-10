//! AC analysis integration tests.

use pisim_test_harness::{parse_netlist_str, run_ac, Tolerance};
use pisim_analysis::AcSweepType;

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
fn ac_rlc_bandpass_center_frequency() {
    let netlist = std::fs::read_to_string("tests/fixtures/basic/rlc_bandpass.sp")
        .expect("fixture missing");
    let (circuit, _) = parse_netlist_str(&netlist).unwrap();
    let result = run_ac(&circuit, 1e3, 1e8, 20, AcSweepType::Decade).unwrap();

    let f0 = 1.0 / (2.0 * std::f64::consts::PI * (1e-6_f64 * 1e-9).sqrt());
    let (peak_idx, _) = result.node_magnitudes.iter()
        .enumerate()
        .max_by(|(_, a), (_, b)| a[1].partial_cmp(&b[1]).unwrap())
        .unwrap();
    let peak_freq = result.frequencies[peak_idx];

    let rel_err = ((peak_freq - f0) / f0).abs();
    assert!(rel_err < 0.05, "Peak at {peak_freq} Hz, expected {f0} Hz");
}
