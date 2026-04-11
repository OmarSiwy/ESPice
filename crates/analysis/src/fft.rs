//! `.FFT` — windowed FFT spectrum analysis.
//!
//! Implements an in-place radix-2 Cooley-Tukey FFT (no external dependency)
//! and the four standard SPICE windows: Hanning, Hamming, Blackman, Kaiser.
//! For `N` not a power of two the input is zero-padded to the next power of
//! two so the radix-2 routine can be used unconditionally.
//!
//! The public entry point `run_fft` consumes a uniformly-sampled waveform
//! (e.g. extracted from a transient result) and returns the magnitude /
//! phase spectrum together with the window-corrected coefficient power.

use bigospice_core::SimError;

use crate::fourier::FourierSignal;

/// Window function selector.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FftWindow {
    /// Rectangular window (no shaping).
    Rectangular,
    /// Hanning (raised cosine).
    Hanning,
    /// Hamming.
    Hamming,
    /// Blackman.
    Blackman,
    /// Kaiser-Bessel; the shape parameter `beta` is supplied via
    /// [`FftConfig::kaiser_beta`].
    Kaiser,
}

/// `.FFT` configuration.
#[derive(Debug, Clone)]
pub struct FftConfig {
    /// Number of points (will be rounded up to the next power of two).
    pub npoints: usize,
    /// Window selector.
    pub window: FftWindow,
    /// Kaiser β; ignored for other windows.
    pub kaiser_beta: f64,
}

impl Default for FftConfig {
    fn default() -> Self {
        Self {
            npoints: 1024,
            window: FftWindow::Hanning,
            kaiser_beta: 8.6,
        }
    }
}

/// FFT spectrum result.
#[derive(Debug, Clone)]
pub struct FftResult {
    /// Bin frequencies [Hz].
    pub frequencies: Vec<f64>,
    /// Magnitudes (single-sided, scaled by 2/N · window-coherent gain).
    pub magnitudes: Vec<f64>,
    /// Phase (radians) per bin.
    pub phases: Vec<f64>,
    /// Effective sample rate used by the FFT [Hz].
    pub fs: f64,
}

/// Run an FFT on a uniformly-sampled signal.
pub fn run_fft(signal: &FourierSignal, cfg: &FftConfig) -> Result<FftResult, SimError> {
    if signal.times.len() < 2 {
        return Err(SimError::Analysis("FFT: need at least two samples".into()));
    }
    let dt_avg = (signal.times.last().unwrap() - signal.times[0])
        / (signal.times.len() as f64 - 1.0);
    if dt_avg <= 0.0 {
        return Err(SimError::Analysis("FFT: non-monotonic time vector".into()));
    }
    let fs = 1.0 / dt_avg;

    // Resample uniformly into a power-of-two buffer of size n_pad.
    let requested = cfg.npoints.max(signal.values.len());
    let n_pad = next_pow2(requested);
    if n_pad == 0 {
        return Err(SimError::Analysis("FFT: zero-length transform".into()));
    }

    let t0 = signal.times[0];
    let t_end = *signal.times.last().unwrap();
    let span = t_end - t0;
    let mut samples = vec![0.0_f64; n_pad];
    let take = signal.values.len().min(n_pad);
    if take == n_pad {
        // Direct copy if same length.
        samples[..take].copy_from_slice(&signal.values[..take]);
    } else {
        // Linear resample over [t0, t_end] into the available samples.
        for i in 0..take {
            let t = t0 + (i as f64 / (take.max(1) as f64 - 1.0).max(1.0)) * span;
            samples[i] = interp(&signal.times, &signal.values, t);
        }
    }

    // Apply window.
    let win = build_window(cfg.window, n_pad, cfg.kaiser_beta);
    let mut re = vec![0.0_f64; n_pad];
    let mut im = vec![0.0_f64; n_pad];
    for i in 0..n_pad {
        re[i] = samples[i] * win[i];
    }

    // Coherent gain (sum(window) / N) — used to normalise magnitudes.
    let cg = win.iter().sum::<f64>() / n_pad as f64;
    let cg = if cg > 1e-300 { cg } else { 1.0 };

    fft_radix2(&mut re, &mut im);

    let half = n_pad / 2;
    let mut frequencies = Vec::with_capacity(half);
    let mut magnitudes = Vec::with_capacity(half);
    let mut phases = Vec::with_capacity(half);
    let scale = 2.0 / (n_pad as f64 * cg);
    for k in 0..half {
        let f_k = (k as f64) * fs / n_pad as f64;
        frequencies.push(f_k);
        let m = (re[k] * re[k] + im[k] * im[k]).sqrt() * scale;
        magnitudes.push(m);
        phases.push(im[k].atan2(re[k]));
    }
    // DC bin should not be doubled — undo the factor 2 there.
    if !magnitudes.is_empty() {
        magnitudes[0] *= 0.5;
    }

    Ok(FftResult {
        frequencies,
        magnitudes,
        phases,
        fs,
    })
}

// ---------------------------------------------------------------------------
// Window construction
// ---------------------------------------------------------------------------

fn build_window(kind: FftWindow, n: usize, kaiser_beta: f64) -> Vec<f64> {
    if n == 0 {
        return Vec::new();
    }
    match kind {
        FftWindow::Rectangular => vec![1.0; n],
        FftWindow::Hanning => (0..n)
            .map(|i| {
                0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / (n as f64 - 1.0)).cos()
            })
            .collect(),
        FftWindow::Hamming => (0..n)
            .map(|i| {
                0.54 - 0.46 * (2.0 * std::f64::consts::PI * i as f64 / (n as f64 - 1.0)).cos()
            })
            .collect(),
        FftWindow::Blackman => (0..n)
            .map(|i| {
                let x = 2.0 * std::f64::consts::PI * i as f64 / (n as f64 - 1.0);
                0.42 - 0.5 * x.cos() + 0.08 * (2.0 * x).cos()
            })
            .collect(),
        FftWindow::Kaiser => {
            let denom = bessel_i0(kaiser_beta);
            let nm1 = (n as f64 - 1.0).max(1.0);
            (0..n)
                .map(|i| {
                    let r = 2.0 * i as f64 / nm1 - 1.0;
                    bessel_i0(kaiser_beta * (1.0 - r * r).max(0.0).sqrt()) / denom
                })
                .collect()
        }
    }
}

/// Modified Bessel function of the first kind, order zero. Series-truncated
/// approximation accurate enough for FFT-window construction.
fn bessel_i0(x: f64) -> f64 {
    let mut sum = 1.0_f64;
    let mut term = 1.0_f64;
    let xh = x * 0.5;
    for k in 1..50 {
        term *= (xh / k as f64).powi(2);
        sum += term;
        if term < 1e-15 * sum {
            break;
        }
    }
    sum
}

// ---------------------------------------------------------------------------
// Radix-2 FFT
// ---------------------------------------------------------------------------

fn next_pow2(n: usize) -> usize {
    if n == 0 {
        return 0;
    }
    let mut p = 1_usize;
    while p < n {
        p <<= 1;
    }
    p
}

/// In-place radix-2 Cooley-Tukey FFT (decimation in time).  `re` and `im`
/// must have the same length and that length must be a power of two.
fn fft_radix2(re: &mut [f64], im: &mut [f64]) {
    let n = re.len();
    debug_assert_eq!(n, im.len());
    if n <= 1 {
        return;
    }
    debug_assert!(n.is_power_of_two(), "fft_radix2: length must be power of 2");

    // Bit-reversal permutation.
    let mut j = 0_usize;
    for i in 1..n {
        let mut bit = n >> 1;
        while (j & bit) != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }

    // Iterative Danielson-Lanczos.
    let mut len = 2_usize;
    while len <= n {
        let half = len / 2;
        let theta = -2.0 * std::f64::consts::PI / len as f64;
        let wlen_re = theta.cos();
        let wlen_im = theta.sin();
        let mut i = 0_usize;
        while i < n {
            let mut w_re = 1.0_f64;
            let mut w_im = 0.0_f64;
            for k in 0..half {
                let u_re = re[i + k];
                let u_im = im[i + k];
                let t_re = w_re * re[i + k + half] - w_im * im[i + k + half];
                let t_im = w_re * im[i + k + half] + w_im * re[i + k + half];
                re[i + k] = u_re + t_re;
                im[i + k] = u_im + t_im;
                re[i + k + half] = u_re - t_re;
                im[i + k + half] = u_im - t_im;
                let nw_re = w_re * wlen_re - w_im * wlen_im;
                let nw_im = w_re * wlen_im + w_im * wlen_re;
                w_re = nw_re;
                w_im = nw_im;
            }
            i += len;
        }
        len <<= 1;
    }
}

// ---------------------------------------------------------------------------
// Linear interpolation helper (mirrors fourier::interpolate_linear).
// ---------------------------------------------------------------------------

fn interp(times: &[f64], values: &[f64], t: f64) -> f64 {
    if times.is_empty() {
        return 0.0;
    }
    if t <= times[0] {
        return values[0];
    }
    let last = times.len() - 1;
    if t >= times[last] {
        return values[last];
    }
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

    fn make_sine(freq: f64, fs: f64, n: usize) -> FourierSignal {
        let dt = 1.0 / fs;
        let times: Vec<f64> = (0..n).map(|i| i as f64 * dt).collect();
        let values: Vec<f64> = times
            .iter()
            .map(|&t| (2.0 * std::f64::consts::PI * freq * t).sin())
            .collect();
        FourierSignal { times, values }
    }

    #[test]
    fn next_pow2_basic() {
        assert_eq!(next_pow2(1), 1);
        assert_eq!(next_pow2(2), 2);
        assert_eq!(next_pow2(3), 4);
        assert_eq!(next_pow2(15), 16);
        assert_eq!(next_pow2(1024), 1024);
        assert_eq!(next_pow2(1025), 2048);
    }

    #[test]
    fn radix2_round_trip() {
        // Verify a delta input gives a flat magnitude spectrum.
        let n = 16;
        let mut re = vec![0.0_f64; n];
        let mut im = vec![0.0_f64; n];
        re[0] = 1.0;
        fft_radix2(&mut re, &mut im);
        for k in 0..n {
            let mag = (re[k] * re[k] + im[k] * im[k]).sqrt();
            assert!((mag - 1.0).abs() < 1e-10, "bin {k} mag = {mag}");
        }
    }

    #[test]
    fn windows_have_expected_lengths() {
        for win in [
            FftWindow::Rectangular,
            FftWindow::Hanning,
            FftWindow::Hamming,
            FftWindow::Blackman,
            FftWindow::Kaiser,
        ] {
            let w = build_window(win, 32, 8.6);
            assert_eq!(w.len(), 32);
            // Should be non-negative for these windows.
            for &v in &w {
                assert!(v >= 0.0 || (-v) < 1e-10);
            }
        }
    }

    #[test]
    fn fft_finds_sine_peak() {
        // 1 kHz sine sampled at 16 kHz, 1024 samples.
        let freq = 1e3;
        let fs = 16e3;
        let n = 1024;
        let signal = make_sine(freq, fs, n);
        let cfg = FftConfig {
            npoints: n,
            window: FftWindow::Hanning,
            kaiser_beta: 8.6,
        };
        let res = run_fft(&signal, &cfg).unwrap();
        // Find max bin.
        let (peak_bin, peak_mag) = res
            .magnitudes
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap())
            .unwrap();
        let peak_f = res.frequencies[peak_bin];
        // The Hanning-window peak should land within ±2 bins of the true frequency.
        let bin_width = res.fs / n as f64;
        assert!(
            (peak_f - freq).abs() < 2.0 * bin_width,
            "peak at {peak_f} Hz, expected near {freq} Hz",
        );
        // And its magnitude should be close to 1.0 (sine amplitude).
        assert!(
            (*peak_mag - 1.0).abs() < 0.2,
            "peak magnitude = {peak_mag}, expected ~1.0",
        );
    }

    #[test]
    fn bessel_i0_basics() {
        // I0(0) = 1, I0(1) ≈ 1.2660658
        assert!((bessel_i0(0.0) - 1.0).abs() < 1e-12);
        assert!((bessel_i0(1.0) - 1.2660658).abs() < 1e-4);
    }
}
