//! HSPICE POST=2 binary output format writer.
//!
//! Reference: HSPICE manual ("Output File Formats", POST=1 ASCII / POST=2
//! binary).  The format is a sequence of fixed-size **blocks**, each opened
//! by a 4-byte little-endian length prefix and closed by the same length
//! repeated as a trailer (Fortran "unformatted sequential" record style).

use std::io::{self, Write};

/// Variable types as defined by HSPICE POST.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HspiceVarType {
    /// Independent sweep variable (time / freq / param).
    Independent = 1,
    Voltage = 2,
    Current = 8,
    Frequency = 15,
}

impl HspiceVarType {
    pub fn code(self) -> i32 {
        self as i32
    }
}

/// HSPICE POST=2 waveform file kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HspicePostKind {
    /// `.tr0` — transient.  Independent column is time.
    Transient,
    /// `.ac0` — AC analysis.  Independent column is frequency.
    Ac,
    /// `.sw0` — DC sweep.  Independent column is the swept parameter.
    DcSweep,
}

/// A complex-valued AC column: real and imaginary parts.
#[derive(Debug, Clone)]
pub struct AcColumn {
    /// Base signal name (e.g. `"v(out)"`).
    pub name: String,
    /// Variable type reported for the magnitude sub-column.
    pub var_type: HspiceVarType,
    /// Complex data points (real, imag) for each frequency step.
    pub data: Vec<(f64, f64)>,
}

impl HspicePostKind {
    fn independent_type(self) -> HspiceVarType {
        match self {
            HspicePostKind::Transient => HspiceVarType::Independent,
            HspicePostKind::Ac => HspiceVarType::Frequency,
            HspicePostKind::DcSweep => HspiceVarType::Independent,
        }
    }

    fn title_prefix(self) -> &'static str {
        match self {
            HspicePostKind::Transient => "$&%#",
            HspicePostKind::Ac => "$&%#",
            HspicePostKind::DcSweep => "$&%#",
        }
    }
}

/// One column to be written.
struct HspiceColumn {
    name: String,
    var_type: HspiceVarType,
    data: Vec<f32>,
}

/// Builder/writer for HSPICE POST=2 binary waveform files.
pub struct HspicePostWriter {
    kind: HspicePostKind,
    title: String,
    date: String,
    time: String,
    copyright: String,
    independent: Option<HspiceColumn>,
    columns: Vec<HspiceColumn>,
    /// AC-specific: complex columns stored as (real, imag) pairs.
    ac_columns: Vec<AcColumn>,
}

impl HspicePostWriter {
    pub fn new(kind: HspicePostKind, title: &str) -> Self {
        Self {
            kind,
            title: title.to_string(),
            date: "01/01/2026".to_string(),
            time: "00:00:00".to_string(),
            copyright: "BigOSpice".to_string(),
            independent: None,
            columns: Vec::new(),
            ac_columns: Vec::new(),
        }
    }

    pub fn set_date(&mut self, date: &str) {
        self.date = date.to_string();
    }

    pub fn set_time(&mut self, time: &str) {
        self.time = time.to_string();
    }

    pub fn set_independent(&mut self, name: &str, values: &[f64]) {
        self.independent = Some(HspiceColumn {
            name: name.to_string(),
            var_type: self.kind.independent_type(),
            data: values.iter().map(|v| *v as f32).collect(),
        });
    }

    pub fn add_column(&mut self, name: &str, var_type: HspiceVarType, values: &[f64]) {
        self.columns.push(HspiceColumn {
            name: name.to_string(),
            var_type,
            data: values.iter().map(|v| *v as f32).collect(),
        });
    }

    /// Add a complex-valued AC column.
    pub fn add_ac_column(
        &mut self,
        name: &str,
        var_type: HspiceVarType,
        complex_values: &[(f64, f64)],
    ) {
        self.ac_columns.push(AcColumn {
            name: name.to_string(),
            var_type,
            data: complex_values.to_vec(),
        });
    }

    /// Write the binary POST=2 file.
    pub fn write<W: Write>(&self, mut w: W) -> io::Result<()> {
        let independent = self
            .independent
            .as_ref()
            .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "no independent column set"))?;

        let ac_expanded_count = self.ac_columns.len() * 2;
        let nauto = self.columns.len() + ac_expanded_count + 1; // +1 for independent
        let nprobe: usize = 0;
        let nsweep: usize = 0;
        let iversn: usize = 9007;

        // ── Block 1: header ──────────────────────────────────────────
        let mut header_bytes = Vec::<u8>::new();
        write_padded(&mut header_bytes, &nauto.to_string(), 9);
        write_padded(&mut header_bytes, &nprobe.to_string(), 9);
        write_padded(&mut header_bytes, &nsweep.to_string(), 9);
        write_padded(&mut header_bytes, &iversn.to_string(), 9);
        write_padded(&mut header_bytes, self.kind.title_prefix(), 16);
        write_padded(&mut header_bytes, &self.date, 16);
        write_padded(&mut header_bytes, &self.time, 16);
        write_padded(&mut header_bytes, &self.copyright, 16);
        write_padded(&mut header_bytes, &self.title, 72);
        write_record(&mut w, &header_bytes)?;

        // ── Block 2: variable type codes ────────────────────────────
        let mut types = Vec::<u8>::new();
        write_padded(&mut types, &independent.var_type.code().to_string(), 9);
        for c in &self.columns {
            write_padded(&mut types, &c.var_type.code().to_string(), 9);
        }
        for c in &self.ac_columns {
            write_padded(&mut types, &c.var_type.code().to_string(), 9);
            write_padded(&mut types, &c.var_type.code().to_string(), 9);
        }
        write_record(&mut w, &types)?;

        // ── Block 3: variable names ─────────────────────────────────
        let mut names = Vec::<u8>::new();
        write_padded(&mut names, &independent.name, 16);
        for c in &self.columns {
            write_padded(&mut names, &c.name, 16);
        }
        for c in &self.ac_columns {
            let real_name = format!("{}:REAL", c.name);
            let imag_name = format!("{}:IMAG", c.name);
            write_padded(&mut names, &real_name, 16);
            write_padded(&mut names, &imag_name, 16);
        }
        write_record(&mut w, &names)?;

        // ── Block 4: data, packed little-endian f32 ─────────────────
        let n_pts = independent.data.len();
        let mut data = Vec::<u8>::new();
        for p in 0..n_pts {
            data.extend_from_slice(&independent.data[p].to_le_bytes());
            for col in &self.columns {
                let v = col.data.get(p).copied().unwrap_or(0.0);
                data.extend_from_slice(&v.to_le_bytes());
            }
            for col in &self.ac_columns {
                let (re, im) = col.data.get(p).copied().unwrap_or((0.0, 0.0));
                data.extend_from_slice(&(re as f32).to_le_bytes());
                data.extend_from_slice(&(im as f32).to_le_bytes());
            }
        }
        // EOD sentinel — HSPICE uses 1e30 as the end marker.
        data.extend_from_slice(&1e30f32.to_le_bytes());
        write_record(&mut w, &data)?;

        Ok(())
    }
}

/// Pad-and-truncate `s` to exactly `width` bytes (ASCII), pushing onto `out`.
fn write_padded(out: &mut Vec<u8>, s: &str, width: usize) {
    if s.len() >= width {
        out.extend_from_slice(&s.as_bytes()[..width]);
    } else {
        out.extend_from_slice(s.as_bytes());
        for _ in 0..(width - s.len()) {
            out.push(b' ');
        }
    }
}

/// Write a Fortran-style unformatted record: 4-byte LE length, payload,
/// 4-byte LE length again.
fn write_record<W: Write>(w: &mut W, payload: &[u8]) -> io::Result<()> {
    let len = payload.len() as u32;
    w.write_all(&len.to_le_bytes())?;
    w.write_all(payload)?;
    w.write_all(&len.to_le_bytes())?;
    Ok(())
}

// ─── HSPICE .mt0 (measurement output, ASCII) ─────────────────────────────────

/// HSPICE `.mt0` measurement results writer.
pub struct HspiceMt0Writer {
    title: String,
    measurements: Vec<(String, f64)>,
}

impl HspiceMt0Writer {
    pub fn new(title: &str) -> Self {
        Self {
            title: title.to_string(),
            measurements: Vec::new(),
        }
    }

    pub fn add_measurement(&mut self, name: &str, value: f64) {
        self.measurements.push((name.to_string(), value));
    }

    /// Write the `.mt0` ASCII file.
    pub fn write<W: Write>(&self, mut w: W) -> io::Result<()> {
        writeln!(w, "$DATA1 SOURCE='BigOSpice' VERSION='0.1.0'")?;
        writeln!(w, ".TITLE '{}'", self.title)?;
        // Header: column names, space-padded to 16-char fields.
        for (name, _) in &self.measurements {
            write!(w, "{:>16} ", name)?;
        }
        writeln!(w)?;
        // Numeric row.
        for (_, value) in &self.measurements {
            write!(w, "{:>16.6e} ", value)?;
        }
        writeln!(w)?;
        Ok(())
    }
}
