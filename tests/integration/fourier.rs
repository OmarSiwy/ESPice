//! Fourier analysis integration tests.
//!
//! `.FOUR` directive parsing and run_fourier/run_fft correctness tests.

use pisim_analysis::fourier::{FourierConfig, FourierSignal, run_fourier, run_fft};
use pisim_test_harness::parse_netlist_str;

/// Parse a netlist with a `.FOUR` directive and verify no parse errors.
#[test]
fn four_directive_parses() {
    let netlist = "\
* .FOUR parse test
V1 1 0 SIN(0 1 1k)
R1 1 0 1k
.TRAN 1u 2m
.FOUR 1k V(1)
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), ".FOUR netlist failed to parse: {:?}", result.err());
}

/// Parse a netlist with a `.FFT` directive and verify no parse errors.
#[test]
fn fft_directive_parses() {
    let netlist = "\
* .FFT parse test
V1 1 0 SIN(0 1 1k)
R1 1 0 1k
.TRAN 1u 2m
.FFT V(1)
.END
";
    let result = parse_netlist_str(netlist);
    assert!(result.is_ok(), ".FFT netlist failed to parse: {:?}", result.err());
}

/// run_fft returns an unsupported error (stub).
#[test]
fn run_fft_is_stub() {
    let freq = 1e3_f64;
    let period = 1.0 / freq;
    let n = 256_usize;
    let dt = 2.0 * period / n as f64;
    let times: Vec<f64> = (0..=n).map(|i| i as f64 * dt).collect();
    let values: Vec<f64> = times.iter()
        .map(|&t| (2.0 * std::f64::consts::PI * freq * t).sin())
        .collect();
    let signal = FourierSignal { times, values };
    let config = FourierConfig::new(freq, 0);
    let result = run_fft(&signal, &config);
    assert!(result.is_err(), "run_fft should return an error (stub)");
}

/// run_fourier recovers the fundamental frequency of a pure sine wave.
#[test]
fn run_fourier_recovers_fundamental() {
    let freq = 1e6_f64;
    let amp = 2.0_f64;
    let n = 2048_usize;
    let t_end = 2.0 / freq; // two full periods
    let dt = t_end / n as f64;
    let times: Vec<f64> = (0..=n).map(|i| i as f64 * dt).collect();
    let values: Vec<f64> = times.iter()
        .map(|&t| amp * (2.0 * std::f64::consts::PI * freq * t).sin())
        .collect();
    let signal = FourierSignal { times, values };
    let config = FourierConfig::new(freq, 0);
    let result = run_fourier(&signal, &config).expect("run_fourier failed");

    // DC should be near zero.
    assert!(result.dc.abs() < 0.05, "DC = {}", result.dc);
    // Fundamental magnitude should be close to amp.
    let fund = &result.harmonics[0];
    assert!(
        (fund.magnitude - amp).abs() < amp * 0.05,
        "fundamental magnitude = {}, expected ~{amp}", fund.magnitude
    );
    // THD should be low for a pure sine.
    assert!(result.thd_pct < 5.0, "THD = {}%", result.thd_pct);
}

/// run_fourier on a constant (DC) signal: all harmonics near zero.
#[test]
fn run_fourier_dc_signal() {
    let freq = 1e6_f64;
    let n = 512_usize;
    let t_end = 2.0 / freq;
    let dt = t_end / n as f64;
    let times: Vec<f64> = (0..=n).map(|i| i as f64 * dt).collect();
    let values = vec![3.3_f64; n + 1];
    let signal = FourierSignal { times, values };
    let config = FourierConfig::new(freq, 0);
    let result = run_fourier(&signal, &config).expect("run_fourier failed");

    assert!((result.dc - 3.3).abs() < 0.01, "DC = {}", result.dc);
    for h in &result.harmonics {
        assert!(h.magnitude < 0.01, "harmonic {} magnitude = {}", h.index, h.magnitude);
    }
}

/// run_fourier returns an error if the waveform is shorter than one period.
#[test]
fn run_fourier_short_waveform_errors() {
    let signal = FourierSignal {
        times: vec![0.0, 1e-9, 2e-9],
        values: vec![0.0, 0.5, 1.0],
    };
    // Requesting 1 kHz = 1 ms period, but waveform is only 2 ns.
    let config = FourierConfig::new(1e3, 0);
    let result = run_fourier(&signal, &config);
    assert!(result.is_err(), "expected error for waveform shorter than one period");
}
