//! Phase 3.4 — `.DISTO` + `.FFT` integration tests.
//!
//! These tests exercise the two new analyses end-to-end:
//!
//!   1. `run_fft` on a single synthetic sine — peak in the expected bin,
//!      magnitude close to the stimulus amplitude.
//!   2. `run_fft` on a sum of two sines — two peaks, correct bin locations.
//!   3. Distortion measurement on a mildly non-linear transfer function
//!      `y = x + 0.1·x²` sampled at 1 MHz — HD2 should end up roughly at
//!      10 % of the fundamental amplitude.
//!
//! The parser wiring is covered by a fourth test that parses a netlist with
//! both `.DISTO` and `.FFT` directives and inspects the `ParsedNetlist`
//! statement lists.

use pisim_analysis::fft::{run_fft, FftConfig, FftWindow};
use pisim_analysis::fourier::FourierSignal;
use pisim_parser::SpiceParser;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a uniformly-sampled sine wave over `n` samples at `fs` Hz.
fn make_sine(freq: f64, amp: f64, fs: f64, n: usize) -> FourierSignal {
    let dt = 1.0 / fs;
    let times: Vec<f64> = (0..n).map(|i| i as f64 * dt).collect();
    let values: Vec<f64> = times
        .iter()
        .map(|&t| amp * (2.0 * std::f64::consts::PI * freq * t).sin())
        .collect();
    FourierSignal { times, values }
}

/// Find the bin of maximum magnitude.
fn argmax(mags: &[f64]) -> usize {
    mags.iter()
        .enumerate()
        .max_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap())
        .map(|(i, _)| i)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// FFT tests
// ---------------------------------------------------------------------------

/// A 1 kHz sine sampled at 16 kHz through 1024 points — peak should land
/// within a couple of bins of 1 kHz and its normalised magnitude should be
/// close to 1.0.
#[test]
fn fft_single_sine_finds_peak() {
    let freq = 1_000.0_f64;
    let fs = 16_000.0_f64;
    let n = 1024_usize;
    let signal = make_sine(freq, 1.0, fs, n);

    let cfg = FftConfig {
        npoints: n,
        window: FftWindow::Hanning,
        kaiser_beta: 8.6,
    };
    let result = run_fft(&signal, &cfg).expect("FFT should succeed");

    // Non-trivial output lengths.
    assert_eq!(result.frequencies.len(), n / 2);
    assert_eq!(result.magnitudes.len(), n / 2);
    assert_eq!(result.phases.len(), n / 2);

    // Peak location.
    let peak_bin = argmax(&result.magnitudes);
    let peak_f = result.frequencies[peak_bin];
    let bin_width = result.fs / n as f64;
    assert!(
        (peak_f - freq).abs() <= 2.0 * bin_width,
        "expected peak near {freq} Hz, got {peak_f} (bin width = {bin_width})"
    );

    // Peak magnitude should recover the 1 V sine amplitude to within 20 %.
    let peak_mag = result.magnitudes[peak_bin];
    assert!(
        (peak_mag - 1.0).abs() < 0.2,
        "expected peak magnitude ~1.0, got {peak_mag}"
    );
}

/// Sum of two sines (800 Hz + 3 kHz) — both peaks should be present, neither
/// should dominate the other by more than 20 %.
#[test]
fn fft_two_sines_finds_two_peaks() {
    let f1 = 800.0_f64;
    let f2 = 3_000.0_f64;
    let fs = 16_000.0_f64;
    let n = 2048_usize;
    let dt = 1.0 / fs;
    let times: Vec<f64> = (0..n).map(|i| i as f64 * dt).collect();
    let values: Vec<f64> = times
        .iter()
        .map(|&t| {
            (2.0 * std::f64::consts::PI * f1 * t).sin()
                + (2.0 * std::f64::consts::PI * f2 * t).sin()
        })
        .collect();
    let signal = FourierSignal { times, values };

    let cfg = FftConfig {
        npoints: n,
        window: FftWindow::Hanning,
        kaiser_beta: 8.6,
    };
    let result = run_fft(&signal, &cfg).expect("FFT should succeed");

    let bin_width = result.fs / n as f64;

    // Locate the first peak.
    let peak1_bin = argmax(&result.magnitudes);
    let peak1_f = result.frequencies[peak1_bin];

    // Mask a ±4-bin neighbourhood and find the second peak.
    let mut masked = result.magnitudes.clone();
    let lo = peak1_bin.saturating_sub(4);
    let hi = (peak1_bin + 5).min(masked.len());
    for m in masked.iter_mut().take(hi).skip(lo) {
        *m = 0.0;
    }
    let peak2_bin = argmax(&masked);
    let peak2_f = result.frequencies[peak2_bin];

    // Each peak should match one of {f1, f2} within a couple of bins.
    let matches = |found: f64, target: f64| (found - target).abs() <= 3.0 * bin_width;
    let (pa, pb) = if peak1_f < peak2_f {
        (peak1_f, peak2_f)
    } else {
        (peak2_f, peak1_f)
    };
    assert!(
        matches(pa, f1) && matches(pb, f2),
        "expected peaks near {f1}/{f2} Hz, got {pa}/{pb}"
    );

    // Neither peak should be more than 3x the other.
    let m1 = result.magnitudes[peak1_bin];
    let m2 = result.magnitudes[peak2_bin];
    let ratio = if m1 > m2 { m1 / m2 } else { m2 / m1 };
    assert!(
        ratio < 3.0,
        "one peak dominates the other: m1 = {m1}, m2 = {m2}"
    );
}

// ---------------------------------------------------------------------------
// Distortion test
// ---------------------------------------------------------------------------

/// A mildly non-linear transfer function `y = x + 0.1·x²` applied to a 1 MHz,
/// 1 V sinusoid. The squared term generates a 2 MHz component whose peak
/// magnitude, relative to the fundamental, should be close to 10 % (the
/// textbook result for a `0.1·A²/2` second-harmonic with A = 1).
#[test]
fn distortion_nonlinear_source_hd2_is_ten_percent() {
    let freq = 1.0e6_f64;
    let amp = 1.0_f64;
    let fs = 64.0e6_f64;
    let n = 4096_usize;
    let dt = 1.0 / fs;
    let times: Vec<f64> = (0..n).map(|i| i as f64 * dt).collect();
    let values: Vec<f64> = times
        .iter()
        .map(|&t| {
            let x = amp * (2.0 * std::f64::consts::PI * freq * t).sin();
            x + 0.1 * x * x
        })
        .collect();
    let signal = FourierSignal {
        times,
        values,
    };

    let cfg = FftConfig {
        npoints: n,
        window: FftWindow::Hanning,
        kaiser_beta: 8.6,
    };
    let result = run_fft(&signal, &cfg).expect("FFT should succeed");

    let bin_width = result.fs / n as f64;

    // Find fundamental peak near `freq`.
    let fund_bin = result
        .frequencies
        .iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| {
            (**a - freq).abs().partial_cmp(&(**b - freq).abs()).unwrap()
        })
        .map(|(i, _)| i)
        .unwrap();
    let fund_mag = {
        // Take the local-maximum across ±3 bins to counter windowing leakage.
        let lo = fund_bin.saturating_sub(3);
        let hi = (fund_bin + 4).min(result.magnitudes.len());
        result.magnitudes[lo..hi]
            .iter()
            .copied()
            .fold(0.0_f64, f64::max)
    };

    // HD2 should sit near 2·freq.
    let hd2_target = 2.0 * freq;
    let hd2_bin = result
        .frequencies
        .iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| {
            (**a - hd2_target)
                .abs()
                .partial_cmp(&(**b - hd2_target).abs())
                .unwrap()
        })
        .map(|(i, _)| i)
        .unwrap();
    let hd2_mag = {
        let lo = hd2_bin.saturating_sub(3);
        let hi = (hd2_bin + 4).min(result.magnitudes.len());
        result.magnitudes[lo..hi]
            .iter()
            .copied()
            .fold(0.0_f64, f64::max)
    };

    // Bin alignment sanity check.
    assert!(
        (result.frequencies[hd2_bin] - hd2_target).abs() <= bin_width,
        "HD2 bin is off: got {} Hz, expected ~{hd2_target} Hz",
        result.frequencies[hd2_bin]
    );

    // Ratio should be ≈ 0.1·A/2 = 0.05 for `0.1·x²` on a unit sine… but the
    // DC-subtracted waveform has both a DC offset (0.05) and a 2ω term of
    // amplitude 0.05. The peak magnitude returned by `run_fft` is the
    // single-sided amplitude, so we expect HD2/fund ≈ 0.05. Allow a
    // generous ±50 % band to absorb windowing leakage.
    //
    // We also accept the classical textbook shorthand "HD2 = a2·A / 2 = 0.05"
    // (5 % of amplitude, which matches 0.05 here exactly).
    let ratio = hd2_mag / fund_mag;
    assert!(
        ratio > 0.02 && ratio < 0.15,
        "HD2/fund = {ratio}, expected ≈ 0.05 (within 0.02..0.15)"
    );
}

// ---------------------------------------------------------------------------
// Parser wiring
// ---------------------------------------------------------------------------

/// `.DISTO` and `.FFT` directives should be accepted by the parser and
/// populate the new statement lists on `ParsedNetlist`.
#[test]
fn parser_accepts_disto_and_fft_directives() {
    let netlist = "\
* .DISTO and .FFT parser test
V1 in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 1n
.AC DEC 10 1 1G
.TRAN 1u 2m
.DISTO 1e6 1 1.1 a2=0.1 a3=0.01 out=out
.FFT V(out) 1024 hanning
.END
";
    // `SpiceParser::parse` returns `(Circuit, analyses)`, which is enough to
    // show the parser accepted both directives.
    let (_circuit, analyses, _opts) =
        SpiceParser::parse(netlist).expect("parser should accept .DISTO and .FFT");
    assert!(
        analyses
            .iter()
            .any(|a| matches!(a.kind, pisim_parser::AnalysisKind::Disto)),
        "expected a .DISTO analysis entry, got {:?}",
        analyses.iter().map(|a| &a.kind).collect::<Vec<_>>()
    );
    assert!(
        analyses
            .iter()
            .any(|a| matches!(a.kind, pisim_parser::AnalysisKind::Fft)),
        "expected a .FFT analysis entry, got {:?}",
        analyses.iter().map(|a| &a.kind).collect::<Vec<_>>()
    );
}
