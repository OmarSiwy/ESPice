//! `.FOUR` Fourier decomposition of transient analysis results.
//!
//! Implements Branin's direct DFT over uniformly-resampled transient waveforms.
//! DC component + 9 harmonics are computed by default (SPICE standard).

use incspice_core::SimError;

use crate::result::TransientResult;

/// Configuration for a `.FOUR` Fourier analysis.
#[derive(Debug, Clone)]
pub struct FourierConfig {
    /// Fundamental frequency (Hz).
    pub freq: f64,
    /// Node index into `TransientResult::node_voltages_flat` to analyse.
    pub node_index: usize,
    /// Number of harmonics to compute (default: 9, SPICE standard).
    pub num_harmonics: usize,
}

impl FourierConfig {
    pub fn new(freq: f64, node_index: usize) -> Self {
        Self {
            freq,
            node_index,
            num_harmonics: 9,
        }
    }

    pub fn with_harmonics(mut self, n: usize) -> Self {
        self.num_harmonics = n;
        self
    }
}

/// A single Fourier harmonic.
#[derive(Debug, Clone)]
pub struct FourierHarmonic {
    /// Harmonic index (1 = fundamental, 2 = second harmonic, …).
    pub index: usize,
    /// Frequency of this harmonic (Hz).
    pub frequency: f64,
    /// Magnitude (peak amplitude) of this harmonic.
    pub magnitude: f64,
    /// Phase (degrees).
    pub phase_deg: f64,
    /// Normalised magnitude relative to fundamental (percent).
    pub normalised_pct: f64,
}

/// Result of a `.FOUR` analysis.
#[derive(Debug, Clone)]
pub struct FourierResult {
    /// DC component.
    pub dc: f64,
    /// Harmonics in ascending frequency order.
    pub harmonics: Vec<FourierHarmonic>,
    /// Total harmonic distortion (THD) as a percentage.
    pub thd_pct: f64,
}

/// Single-node waveform extracted from a `TransientResult`.
#[derive(Debug, Clone)]
pub struct FourierSignal {
    pub times: Vec<f64>,
    pub values: Vec<f64>,
}

impl FourierSignal {
    /// Extract the waveform for `node_index` from a `TransientResult`.
    pub fn from_transient(result: &TransientResult, node_index: usize) -> Self {
        let values: Vec<f64> = (0..result.num_steps())
            .map(|step| result.voltage(step, node_index))
            .collect();
        Self {
            times: result.times.clone(),
            values,
        }
    }
}

// ---------------------------------------------------------------------------
// Core DFT implementation
// ---------------------------------------------------------------------------

/// Run a `.FOUR` Fourier decomposition on `signal` using `config`.
///
/// The waveform is linearly resampled onto a uniform grid that spans exactly
/// one period of the fundamental frequency (1/`freq`), using the last period
/// present in the data.  DC + `config.num_harmonics` cosine/sine pairs are
/// extracted via a direct DFT.
pub fn run_fourier(
    signal: &FourierSignal,
    config: &FourierConfig,
) -> Result<FourierResult, SimError> {
    let period = 1.0 / config.freq;

    if signal.times.is_empty() {
        return Err(SimError::Analysis("fourier: empty waveform".into()));
    }

    let t_end = *signal.times.last().unwrap();
    let t_start = t_end - period;

    if t_start < signal.times[0] {
        return Err(SimError::Analysis(format!(
            "fourier: waveform too short for one full period at {:.3e} Hz (need >= {:.3e} s, have {:.3e} s)",
            config.freq,
            period,
            t_end - signal.times[0]
        )));
    }

    // Number of points for the DFT: use at least 1024 or the available sample count.
    let n_pts = 1024_usize.max(signal.times.len());

    // Resample the signal uniformly over [t_start, t_end].
    let dt = period / n_pts as f64;
    let uniform: Vec<f64> = (0..n_pts)
        .map(|i| {
            let t = t_start + i as f64 * dt;
            interpolate_linear(&signal.times, &signal.values, t)
        })
        .collect();

    // DC component.
    let dc = uniform.iter().sum::<f64>() / n_pts as f64;

    // Direct DFT: for each harmonic k compute cosine (a_k) and sine (b_k) coefficients.
    let n = n_pts as f64;
    let two_pi_over_n = 2.0 * std::f64::consts::PI / n;

    let mut harmonics = Vec::with_capacity(config.num_harmonics);
    let mut sum_sq = 0.0_f64;
    let mut fundamental_mag = 1.0_f64; // placeholder until k=1 is computed

    for k in 1..=config.num_harmonics {
        let kf = k as f64;
        let mut a_k = 0.0_f64;
        let mut b_k = 0.0_f64;
        for (i, &v) in uniform.iter().enumerate() {
            let theta = two_pi_over_n * kf * i as f64;
            a_k += v * theta.cos();
            b_k += v * theta.sin();
        }
        a_k *= 2.0 / n;
        b_k *= 2.0 / n;

        let mag = (a_k * a_k + b_k * b_k).sqrt();
        let phase_deg = b_k.atan2(a_k).to_degrees();

        if k == 1 {
            fundamental_mag = mag.max(1e-300); // avoid div-by-zero
        }
        if k > 1 {
            sum_sq += mag * mag;
        }

        harmonics.push(FourierHarmonic {
            index: k,
            frequency: config.freq * kf,
            magnitude: mag,
            phase_deg,
            normalised_pct: 0.0, // filled in below
        });
    }

    // Fill normalised_pct after fundamental is known.
    for h in &mut harmonics {
        h.normalised_pct = (h.magnitude / fundamental_mag) * 100.0;
    }

    let thd_pct = (sum_sq.sqrt() / fundamental_mag) * 100.0;

    Ok(FourierResult {
        dc,
        harmonics,
        thd_pct,
    })
}

/// `.FFT` is not yet implemented.
///
/// Returns `SimError::Analysis("unsupported")`.
///
/// TODO: Phase 3.4 — full .FFT with windowing via rustfft.
pub fn run_fft(
    _signal: &FourierSignal,
    _config: &FourierConfig,
) -> Result<FourierResult, SimError> {
    Err(SimError::Analysis(
        ".FFT is not yet supported. Use .FOUR for Fourier analysis.".into(),
    ))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Linear interpolation into a sorted `times` / `values` pair.
///
/// Returns the first value for `t < times[0]` and the last value for
/// `t > times[last]`.  For `times` with a single point, returns that value.
fn interpolate_linear(times: &[f64], values: &[f64], t: f64) -> f64 {
    debug_assert_eq!(times.len(), values.len());
    if times.len() == 1 || t <= times[0] {
        return values[0];
    }
    let last = times.len() - 1;
    if t >= times[last] {
        return values[last];
    }
    // Binary search for the interval containing t.
    let idx = times.partition_point(|&ts| ts <= t);
    let i = idx.saturating_sub(1).min(last - 1);
    let t0 = times[i];
    let t1 = times[i + 1];
    let v0 = values[i];
    let v1 = values[i + 1];
    let alpha = (t - t0) / (t1 - t0);
    v0 + alpha * (v1 - v0)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sine_signal(freq: f64, amplitude: f64, n: usize) -> FourierSignal {
        let period = 1.0 / freq;
        // Two full periods so the extractor can use the last one.
        let t_end = 2.0 * period;
        let dt = t_end / n as f64;
        let times: Vec<f64> = (0..=n).map(|i| i as f64 * dt).collect();
        let values: Vec<f64> = times
            .iter()
            .map(|&t| amplitude * (2.0 * std::f64::consts::PI * freq * t).sin())
            .collect();
        FourierSignal { times, values }
    }

    #[test]
    fn dc_only_signal() {
        // Constant signal: DC = 2.5, all harmonics ≈ 0.
        let n = 512;
        let t_end = 2e-6_f64;
        let dt = t_end / n as f64;
        let times: Vec<f64> = (0..=n).map(|i| i as f64 * dt).collect();
        let values = vec![2.5_f64; n + 1];
        let signal = FourierSignal { times, values };
        let config = FourierConfig::new(1e6, 0);
        let result = run_fourier(&signal, &config).unwrap();
        assert!((result.dc - 2.5).abs() < 1e-6, "DC = {}", result.dc);
        for h in &result.harmonics {
            assert!(
                h.magnitude < 1e-6,
                "harmonic {} magnitude = {}",
                h.index,
                h.magnitude
            );
        }
    }

    #[test]
    fn pure_sine_fundamental() {
        // 1 MHz, 1V amplitude sine — fundamental should be ~1V, harmonics ~0.
        let freq = 1e6_f64;
        let amp = 1.0_f64;
        let signal = sine_signal(freq, amp, 2048);
        let config = FourierConfig::new(freq, 0);
        let result = run_fourier(&signal, &config).unwrap();
        assert!(result.dc.abs() < 1e-4, "DC = {}", result.dc);
        let fund = &result.harmonics[0];
        assert!(
            (fund.magnitude - amp).abs() < 0.01,
            "fundamental magnitude = {}",
            fund.magnitude
        );
        for h in &result.harmonics[1..] {
            assert!(
                h.magnitude < 0.05 * amp,
                "harmonic {} = {}",
                h.index,
                h.magnitude
            );
        }
        assert!(result.thd_pct < 5.0, "THD = {}%", result.thd_pct);
    }

    #[test]
    fn waveform_too_short_errors() {
        let signal = FourierSignal {
            times: vec![0.0, 1e-9],
            values: vec![0.0, 1.0],
        };
        // Requesting 1 kHz period (1ms) but waveform is only 1ns.
        let config = FourierConfig::new(1e3, 0);
        let result = run_fourier(&signal, &config);
        assert!(result.is_err(), "expected error for short waveform");
    }

    #[test]
    fn run_fft_returns_unsupported() {
        let signal = sine_signal(1e6, 1.0, 256);
        let config = FourierConfig::new(1e6, 0);
        let result = run_fft(&signal, &config);
        assert!(result.is_err());
        if let Err(SimError::Analysis(msg)) = result {
            assert!(
                msg.contains(".FFT"),
                "error message should mention .FFT: {msg}"
            );
        } else {
            panic!("expected SimError::Analysis");
        }
    }

    #[test]
    fn fourier_config_default_9_harmonics() {
        let cfg = FourierConfig::new(1e6, 0);
        assert_eq!(cfg.num_harmonics, 9);
    }

    #[test]
    fn fourier_config_with_harmonics() {
        let cfg = FourierConfig::new(1e6, 2).with_harmonics(4);
        assert_eq!(cfg.num_harmonics, 4);
        assert_eq!(cfg.node_index, 2);
    }

    #[test]
    fn fourier_harmonic_indices_start_at_1() {
        let sig = sine_signal(1e3, 1.0, 2048);
        let cfg = FourierConfig::new(1e3, 0);
        let result = run_fourier(&sig, &cfg).unwrap();
        for (i, h) in result.harmonics.iter().enumerate() {
            assert_eq!(h.index, i + 1, "harmonic index should be 1-based");
        }
    }

    #[test]
    fn fourier_harmonic_frequencies_multiples_of_fundamental() {
        let freq = 1e6;
        let sig = sine_signal(freq, 1.0, 2048);
        let cfg = FourierConfig::new(freq, 0);
        let result = run_fourier(&sig, &cfg).unwrap();
        for h in &result.harmonics {
            let expected_f = freq * h.index as f64;
            assert!((h.frequency - expected_f).abs() < 1.0,
                "harmonic {} freq={} expected {}", h.index, h.frequency, expected_f);
        }
    }

    #[test]
    fn fourier_thd_near_zero_for_pure_sine() {
        let freq = 1e6;
        let sig = sine_signal(freq, 1.0, 4096);
        let cfg = FourierConfig::new(freq, 0);
        let result = run_fourier(&sig, &cfg).unwrap();
        assert!(result.thd_pct < 5.0, "THD for pure sine should be < 5%, got {}%", result.thd_pct);
    }

    #[test]
    fn fourier_normalised_pct_fundamental_is_100() {
        let freq = 1e6;
        let sig = sine_signal(freq, 1.0, 2048);
        let cfg = FourierConfig::new(freq, 0);
        let result = run_fourier(&sig, &cfg).unwrap();
        let fund_pct = result.harmonics[0].normalised_pct;
        assert!((fund_pct - 100.0).abs() < 0.5,
            "fundamental normalised_pct should be ~100%, got {fund_pct}");
    }

    #[test]
    fn fourier_signal_from_transient() {
        use crate::result::TransientResult;
        let n_steps = 100usize;
        let freq = 1e3_f64;
        let times: Vec<f64> = (0..n_steps).map(|i| i as f64 / (n_steps as f64 * freq)).collect();
        let v0: Vec<f64> = times.iter().map(|&t| (2.0 * std::f64::consts::PI * freq * t).sin()).collect();
        let v1: Vec<f64> = times.iter().map(|&t| 2.0 * t).collect();

        // Two-node transient result
        let mut flat = Vec::new();
        for i in 0..n_steps {
            flat.push(v0[i]);
            flat.push(v1[i]);
        }
        let result = TransientResult {
            times: times.clone(),
            node_voltages: flat.chunks(2).map(|c| c.to_vec()).collect(),
            node_voltages_flat: flat,
            num_nodes: 2,
            branch_names: vec![],
            branch_currents_flat: vec![],
        };

        let sig0 = FourierSignal::from_transient(&result, 0);
        let sig1 = FourierSignal::from_transient(&result, 1);
        assert_eq!(sig0.times, times);
        assert_eq!(sig0.values, v0);
        assert_eq!(sig1.values, v1);
    }

    #[test]
    fn fourier_empty_waveform_errors() {
        let sig = FourierSignal { times: vec![], values: vec![] };
        let cfg = FourierConfig::new(1e6, 0);
        assert!(run_fourier(&sig, &cfg).is_err());
    }

    #[test]
    fn fourier_harmonics_count_matches_config() {
        let freq = 1e6;
        let sig = sine_signal(freq, 1.0, 2048);
        let cfg = FourierConfig::new(freq, 0).with_harmonics(5);
        let result = run_fourier(&sig, &cfg).unwrap();
        assert_eq!(result.harmonics.len(), 5);
    }
}
