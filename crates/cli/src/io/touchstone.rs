//! Touchstone `.sNp` writer for RF S/Y/Z parameter data.
//!
//! Reference: IBIS-ATM Touchstone 1.1 specification.

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
                let db = if mag > 0.0 {
                    20.0 * mag.log10()
                } else {
                    -200.0
                };
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

/// Touchstone `.sNp` writer.
pub struct TouchstoneWriter {
    n_ports: usize,
    freq_unit: FreqUnit,
    param: ParamType,
    fmt: ComplexFormat,
    z_ref: f64,
    comments: Vec<String>,
    frequencies: Vec<f64>,
    /// Flat (re, im) pairs in row-major-per-frequency layout.
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
            "! {n}-port {p}-parameter file written by BigOSpice",
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
            write!(w, "{:<15.9e}", freq_hz * scale)?;

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
                    write!(w, " {:>15.9e} {:>15.9e}", a, b)?;
                    col_count = 1;
                } else {
                    if col_count == 4 {
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
