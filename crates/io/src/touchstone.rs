//! Touchstone `.sNp` writer for RF S/Y/Z parameter data.
//!
//! Reference: IBIS-ATM Touchstone 1.1 specification (the universal flavor).
//! A `.s2p` file looks like:
//!
//! ```text
//! ! 2-port S-parameter file written by PiSIM
//! # GHz S MA R 50
//! 1.00  0.95 -10  0.05  20  0.05  20  0.95 -10
//! 2.00  ...
//! ```
//!
//! Layout per row depends on the number of ports `N`:
//! * 1-port: `freq  S11_a S11_b`
//! * 2-port: `freq  S11 S21 S12 S22`  (note: 2-port is **column-major** in the
//!   spec — S21 comes before S12)
//! * N-port (N≥3): `freq  S11 S12 ... S1N` then continuation lines
//!   `S21 S22 ... S2N` etc., 4 entries per line for readability.
//!
//! Each Sxx complex number is written using the user-selected format:
//! * `MA` — magnitude / angle (degrees)
//! * `DB` — 20·log10(|S|) / angle (degrees)
//! * `RI` — real / imaginary
//!
//! This implementation supports S/Y/Z parameters, frequency units of
//! Hz/kHz/MHz/GHz, and any number of ports.

use std::io::{self, Write};
use thiserror::Error;

/// Frequency unit at the top of the option line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FreqUnit {
    Hz,
    KHz,
    MHz,
    GHz,
}

impl FreqUnit {
    pub fn as_str(&self) -> &'static str {
        match self {
            FreqUnit::Hz => "Hz",
            FreqUnit::KHz => "kHz",
            FreqUnit::MHz => "MHz",
            FreqUnit::GHz => "GHz",
        }
    }

    /// Scale factor to convert raw Hz to this unit (multiply Hz by this).
    pub fn scale_from_hz(&self) -> f64 {
        match self {
            FreqUnit::Hz => 1.0,
            FreqUnit::KHz => 1e-3,
            FreqUnit::MHz => 1e-6,
            FreqUnit::GHz => 1e-9,
        }
    }
}

/// Parameter type tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamType {
    /// Scattering parameters.
    S,
    /// Admittance parameters.
    Y,
    /// Impedance parameters.
    Z,
}

impl ParamType {
    pub fn as_str(&self) -> &'static str {
        match self {
            ParamType::S => "S",
            ParamType::Y => "Y",
            ParamType::Z => "Z",
        }
    }
}

/// Complex format option.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComplexFormat {
    /// Magnitude / angle in degrees.
    MA,
    /// 20·log10(magnitude) / angle in degrees.
    DB,
    /// Real / imaginary.
    RI,
}

impl ComplexFormat {
    pub fn as_str(&self) -> &'static str {
        match self {
            ComplexFormat::MA => "MA",
            ComplexFormat::DB => "DB",
            ComplexFormat::RI => "RI",
        }
    }

    /// Convert a (re, im) pair into the two on-disk fields.
    pub fn encode(&self, re: f64, im: f64) -> (f64, f64) {
        match self {
            ComplexFormat::RI => (re, im),
            ComplexFormat::MA => {
                let mag = (re * re + im * im).sqrt();
                let ang = im.atan2(re).to_degrees();
                (mag, ang)
            }
            ComplexFormat::DB => {
                let mag = (re * re + im * im).sqrt();
                let db = if mag > 0.0 { 20.0 * mag.log10() } else { -200.0 };
                let ang = im.atan2(re).to_degrees();
                (db, ang)
            }
        }
    }
}

#[derive(Debug, Error)]
pub enum TouchstoneError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("port count must be >= 1, got {0}")]
    InvalidPortCount(usize),
    #[error("data length mismatch: expected {expected} entries (n_ports^2 * n_freqs), got {got}")]
    LengthMismatch { expected: usize, got: usize },
}

/// Touchstone `.sNp` writer.  Caller provides the frequency vector and the
/// flat parameter matrix in column-major-per-frequency layout:
///
/// ```text
/// data[(f_idx * n_ports * n_ports) + (row * n_ports) + col] = (re, im)
/// ```
///
/// For 1-port files row/col are both 0.  The writer takes care of the 2-port
/// transposition convention (S21 comes before S12 in the row layout).
///
/// # Example
/// ```
/// use pisim_io::touchstone::{TouchstoneWriter, FreqUnit, ParamType, ComplexFormat};
/// let mut w = TouchstoneWriter::new(2, FreqUnit::GHz, ParamType::S, ComplexFormat::MA, 50.0);
/// w.set_frequencies(&[1e9, 2e9]);
/// // S-params at f0 and f1: 4 entries each (S11, S12, S21, S22).
/// w.set_data(&[
///     (0.95, -10.0_f64.to_radians()), (0.05, 20.0_f64.to_radians()),
///     (0.05, 20.0_f64.to_radians()),  (0.95, -10.0_f64.to_radians()),
///     (0.90, -20.0_f64.to_radians()), (0.10, 10.0_f64.to_radians()),
///     (0.10, 10.0_f64.to_radians()),  (0.90, -20.0_f64.to_radians()),
/// ]).unwrap();
/// let mut buf = Vec::new();
/// w.write(&mut buf).unwrap();
/// let s = std::str::from_utf8(&buf).unwrap();
/// assert!(s.contains("# GHz S MA R 50"));
/// ```
pub struct TouchstoneWriter {
    n_ports: usize,
    freq_unit: FreqUnit,
    param: ParamType,
    fmt: ComplexFormat,
    z_ref: f64,
    comments: Vec<String>,
    frequencies: Vec<f64>,
    /// Flat (re, im) pairs in row-major-per-frequency layout.  Length is
    /// `n_freqs * n_ports * n_ports`.
    data: Vec<(f64, f64)>,
}

impl TouchstoneWriter {
    pub fn new(
        n_ports: usize,
        freq_unit: FreqUnit,
        param: ParamType,
        fmt: ComplexFormat,
        z_ref: f64,
    ) -> Self {
        Self {
            n_ports,
            freq_unit,
            param,
            fmt,
            z_ref,
            comments: Vec::new(),
            frequencies: Vec::new(),
            data: Vec::new(),
        }
    }

    pub fn add_comment(&mut self, line: &str) {
        self.comments.push(line.to_string());
    }

    pub fn set_frequencies(&mut self, freqs_hz: &[f64]) {
        self.frequencies = freqs_hz.to_vec();
    }

    /// Provide the data as a flat list of (re, im) pairs in row-major
    /// `[f_idx][row][col]` order with raw (untransposed) layout.
    pub fn set_data(&mut self, data: &[(f64, f64)]) -> Result<(), TouchstoneError> {
        if self.n_ports == 0 {
            return Err(TouchstoneError::InvalidPortCount(0));
        }
        let expected = self.frequencies.len() * self.n_ports * self.n_ports;
        if data.len() != expected {
            return Err(TouchstoneError::LengthMismatch {
                expected,
                got: data.len(),
            });
        }
        self.data = data.to_vec();
        Ok(())
    }

    /// Default file extension based on the configured port count.
    pub fn extension(&self) -> String {
        format!("s{}p", self.n_ports)
    }

    /// Write the Touchstone file.
    pub fn write<W: Write>(&self, mut w: W) -> Result<(), TouchstoneError> {
        // Comment block.
        writeln!(
            w,
            "! {n}-port {p}-parameter file written by PiSIM",
            n = self.n_ports,
            p = self.param.as_str()
        )?;
        for line in &self.comments {
            writeln!(w, "! {line}")?;
        }
        // Option line.
        writeln!(
            w,
            "# {unit} {param} {fmt} R {z}",
            unit = self.freq_unit.as_str(),
            param = self.param.as_str(),
            fmt = self.fmt.as_str(),
            z = self.z_ref
        )?;

        let n = self.n_ports;
        let scale = self.freq_unit.scale_from_hz();

        for (f_idx, &freq_hz) in self.frequencies.iter().enumerate() {
            // First column on the freq row is the scaled frequency.  Use a
            // left-aligned numeric so detection of "freq vs continuation" lines
            // by readers (and our tests) is unambiguous.
            write!(w, "{:<15.9e}", freq_hz * scale)?;

            // Build the per-frequency (re, im) array in the on-disk order.
            // Touchstone 1.1 quirk: 2-port files store S11 S21 S12 S22 (col-major),
            // 1-port stores S11, N-port (N>=3) stores row-major S11 S12 ... S1N etc.
            let mut on_disk: Vec<(f64, f64)> = Vec::with_capacity(n * n);
            if n == 2 {
                // S11, S21, S12, S22.
                let s = |r: usize, c: usize| self.data[(f_idx * n * n) + (r * n) + c];
                on_disk.push(s(0, 0));
                on_disk.push(s(1, 0));
                on_disk.push(s(0, 1));
                on_disk.push(s(1, 1));
            } else {
                // 1-port or N-port (N>=3): row-major.
                for r in 0..n {
                    for c in 0..n {
                        on_disk.push(self.data[(f_idx * n * n) + (r * n) + c]);
                    }
                }
            }

            // Encode and emit.  4 columns per physical line for readability.
            let mut col_count = 0;
            for (entry_idx, (re, im)) in on_disk.iter().enumerate() {
                let (a, b) = self.fmt.encode(*re, *im);
                if entry_idx == 0 {
                    // First entry sits on the freq row.
                    write!(w, " {:>15.9e} {:>15.9e}", a, b)?;
                    col_count = 1;
                } else {
                    if col_count == 4 {
                        // Wrap to a continuation line.  Continuations are
                        // indented so a downstream reader can distinguish them
                        // from a fresh frequency row, which is left-aligned.
                        writeln!(w)?;
                        write!(w, "                ")?; // 16-space gutter
                        col_count = 0;
                    }
                    write!(w, " {:>15.9e} {:>15.9e}", a, b)?;
                    col_count += 1;
                }
            }
            writeln!(w)?;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn complex_format_encodings() {
        // RI is identity.
        let (a, b) = ComplexFormat::RI.encode(0.5, -0.3);
        assert!((a - 0.5).abs() < 1e-15);
        assert!((b - -0.3).abs() < 1e-15);

        // MA: magnitude and angle in degrees.
        let (mag, ang) = ComplexFormat::MA.encode(1.0, 0.0);
        assert!((mag - 1.0).abs() < 1e-15);
        assert!(ang.abs() < 1e-15);

        let (mag, ang) = ComplexFormat::MA.encode(0.0, 1.0);
        assert!((mag - 1.0).abs() < 1e-15);
        assert!((ang - 90.0).abs() < 1e-12);

        // DB: 20*log10(mag).
        let (db, _) = ComplexFormat::DB.encode(0.1, 0.0);
        assert!((db - -20.0).abs() < 1e-12);
    }

    #[test]
    fn s1p_one_freq() {
        let mut w = TouchstoneWriter::new(
            1,
            FreqUnit::GHz,
            ParamType::S,
            ComplexFormat::MA,
            50.0,
        );
        w.set_frequencies(&[2e9]);
        w.set_data(&[(0.5, 0.0)]).unwrap();

        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();
        let s = String::from_utf8(buf).unwrap();
        assert!(s.contains("# GHz S MA R 50"));
        assert!(s.contains("1-port"));
    }

    #[test]
    fn s2p_five_freqs() {
        let mut w = TouchstoneWriter::new(
            2,
            FreqUnit::GHz,
            ParamType::S,
            ComplexFormat::MA,
            50.0,
        );
        let freqs: Vec<f64> = (1..=5).map(|i| i as f64 * 1e9).collect();
        w.set_frequencies(&freqs);
        // 5 freqs * 2*2 = 20 entries.
        let mut data = Vec::new();
        for _ in 0..5 {
            data.push((0.95, 0.0)); // S11
            data.push((0.05, 0.0)); // S12
            data.push((0.05, 0.0)); // S21
            data.push((0.95, 0.0)); // S22
        }
        w.set_data(&data).unwrap();

        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();
        let s = String::from_utf8(buf).unwrap();

        // Check option line.
        assert!(s.contains("# GHz S MA R 50"));

        // Count freq lines: 5 frequencies, each has the freq value followed
        // by 4 complex numbers.  A freq line starts with an ASCII digit
        // (the left-aligned scientific notation of the frequency).
        let freq_lines: Vec<&str> = s
            .lines()
            .filter(|l| l.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false))
            .collect();
        assert_eq!(
            freq_lines.len(),
            5,
            "expected 5 freq lines, got {}",
            freq_lines.len()
        );

        // First entry on each line should be the scaled frequency (1.0, 2.0, ...).
        for (i, line) in freq_lines.iter().enumerate() {
            let first: f64 = line.split_whitespace().next().unwrap().parse().unwrap();
            assert!(
                ((i + 1) as f64 - first).abs() < 1e-9,
                "freq mismatch on row {i}: {first}"
            );
        }
    }

    #[test]
    fn s2p_2port_transposition() {
        // Build a circuit where S11 != S22 and S12 != S21 so we can verify the
        // on-disk order is S11, S21, S12, S22.
        let mut w = TouchstoneWriter::new(
            2,
            FreqUnit::Hz,
            ParamType::S,
            ComplexFormat::RI,
            50.0,
        );
        w.set_frequencies(&[1.0]);
        // Row-major input: S11=1, S12=2, S21=3, S22=4.
        w.set_data(&[(1.0, 0.0), (2.0, 0.0), (3.0, 0.0), (4.0, 0.0)])
            .unwrap();

        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();
        let s = String::from_utf8(buf).unwrap();
        // Find the freq line (starts with a digit).
        let freq_line = s
            .lines()
            .find(|l| l.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false))
            .unwrap();
        let nums: Vec<f64> = freq_line
            .split_whitespace()
            .map(|t| t.parse().unwrap())
            .collect();
        // freq + 4 (re,im) pairs = 9 numbers
        assert_eq!(nums.len(), 9);
        assert_eq!(nums[0], 1.0); // freq
        // S11 = 1+0j
        assert_eq!(nums[1], 1.0);
        assert_eq!(nums[2], 0.0);
        // S21 = 3+0j  (NOT S12, the 2-port transposition rule)
        assert_eq!(nums[3], 3.0);
        assert_eq!(nums[4], 0.0);
        // S12 = 2+0j
        assert_eq!(nums[5], 2.0);
        assert_eq!(nums[6], 0.0);
        // S22 = 4+0j
        assert_eq!(nums[7], 4.0);
        assert_eq!(nums[8], 0.0);
    }

    #[test]
    fn extension_matches_port_count() {
        let w = TouchstoneWriter::new(3, FreqUnit::GHz, ParamType::S, ComplexFormat::MA, 50.0);
        assert_eq!(w.extension(), "s3p");
    }
}
