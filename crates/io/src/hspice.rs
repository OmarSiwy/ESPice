//! HSPICE POST=2 binary output format writer.
//!
//! Reference: HSPICE manual ("Output File Formats", POST=1 ASCII / POST=2
//! binary).  The format is a sequence of fixed-size **blocks**, each opened
//! by a 4-byte little-endian length prefix and closed by the same length
//! repeated as a trailer (Fortran "unformatted sequential" record style).
//!
//! Block layout for waveform files (`.tr0`, `.ac0`, `.sw0`):
//!
//! 1. **Block 1 (header)** — fixed-width text fields:
//!    * 9-char `nauto` (count of auto vars, padded with spaces)
//!    * 9-char `nprobe`
//!    * 9-char `nsweep`
//!    * 9-char `iversn`
//!    * 16-char title-prefix
//!    * 16-char date string
//!    * 16-char time string
//!    * 16-char copyright string
//!    * 72-char title text (padded with spaces)
//!
//! 2. **Block 2 (variable types)** — `(1 + nvars)` ascii integers as
//!    9-char zero-padded fields, declaring the SPICE type (`1` time, `2`
//!    voltage, `8` current, `15` frequency, …) of each column.
//!
//! 3. **Block 3 (variable names)** — `(1 + nvars)` 16-char names.
//!
//! 4. **Block 4 (data)** — packed little-endian f32 values, one row per
//!    sweep point.  A trailing `1e30` sentinel marks end-of-data.
//!
//! For the `.mt0` measure-output file, the format is **ASCII text** with a
//! one-line header and one numeric row per result.  We support that here as
//! `HspiceMt0Writer`.
//!
//! This writer covers the on-disk header layout that HSPICE/awaves opens
//! correctly for round-trip text inspection — it is **not** a clean-room
//! reimplementation of the binary loader; downstream tools that need
//! bit-perfect compatibility should still validate against awaves.

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

/// HSPICE POST=2 waveform file kind, used to set the title prefix and the
/// independent column type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HspicePostKind {
    /// `.tr0` — transient.  Independent column is time.
    Transient,
    /// `.ac0` — AC analysis.  Independent column is frequency.  Each
    /// dependent variable contributes magnitude + phase (degrees) as two
    /// consecutive columns in the data block.
    Ac,
    /// `.sw0` — DC sweep.  Independent column is the swept parameter.
    DcSweep,
}

/// A complex-valued AC column: real and imaginary parts.
///
/// The writer stores these as (real, imag) pairs in the binary data block,
/// matching the HSPICE POST=2 `.ac0` convention that CosmosScope expects.
#[derive(Debug, Clone)]
pub struct AcColumn {
    /// Base signal name (e.g. `"v(out)"`). The writer appends `":REAL"` and
    /// `":IMAG"` suffixes in block 3 to match the two sub-columns.
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
///
/// For transient/DC sweep files, use [`HspicePostWriter::add_column`] to
/// supply real-valued data.
///
/// For AC files (`.ac0`), use [`HspicePostWriter::add_ac_column`] to supply
/// complex data; the writer automatically emits magnitude + phase pairs.
///
/// # Example — transient
/// ```
/// use pisim_io::hspice::{HspicePostWriter, HspicePostKind, HspiceVarType};
/// let mut w = HspicePostWriter::new(HspicePostKind::Transient, "rc demo");
/// w.set_independent("time", &[0.0, 1e-6, 2e-6]);
/// w.add_column("v(out)", HspiceVarType::Voltage, &[0.0, 0.63, 0.86]);
/// let mut buf = Vec::new();
/// w.write(&mut buf).unwrap();
/// assert!(buf.len() > 0);
/// ```
///
/// # Example — AC with complex data
/// ```
/// use pisim_io::hspice::{HspicePostWriter, HspicePostKind, HspiceVarType};
/// let freqs = [1e3, 10e3, 100e3];
/// let complex = [(0.5_f64, 0.866_f64), (0.707, 0.707), (0.9, 0.1)];
/// let mut w = HspicePostWriter::new(HspicePostKind::Ac, "ac test");
/// w.set_independent("frequency", &freqs);
/// w.add_ac_column("v(out)", HspiceVarType::Voltage, &complex);
/// let mut buf = Vec::new();
/// w.write(&mut buf).unwrap();
/// assert!(buf.len() > 0);
/// ```
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
            copyright: "PiSIM".to_string(),
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
    ///
    /// Each entry in `complex_values` is `(real, imag)` for one frequency
    /// point. The writer emits the pair directly as two consecutive f32
    /// values in the binary data block.
    ///
    /// Two sub-columns are emitted in the binary file: `<name>:REAL` and
    /// `<name>:IMAG`.  This matches the HSPICE POST=2 `.ac0` format that
    /// CosmosScope and compatible readers expect.
    ///
    /// Only meaningful when the writer's kind is [`HspicePostKind::Ac`].
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
    ///
    /// For [`HspicePostKind::Ac`] files, AC columns added via
    /// [`Self::add_ac_column`] are expanded to real+imag sub-column pairs.
    /// Real-valued columns added via [`Self::add_column`] are also included
    /// unchanged (useful for the independent frequency column).
    pub fn write<W: Write>(&self, mut w: W) -> io::Result<()> {
        let independent = self
            .independent
            .as_ref()
            .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "no independent column set"))?;

        // For AC files each complex column expands into 2 sub-columns
        // (magnitude + phase), so the logical column count must reflect that.
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
        // AC complex columns: magnitude sub-column uses the declared type;
        // phase sub-column reuses the same type code (HSPICE convention).
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
        // AC columns: emit "<name>:REAL" and "<name>:IMAG" sub-column names.
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
            // Real-valued columns (transient / DC sweep style).
            for col in &self.columns {
                let v = col.data.get(p).copied().unwrap_or(0.0);
                data.extend_from_slice(&v.to_le_bytes());
            }
            // AC complex columns: emit real then imaginary part.
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

/// HSPICE `.mt0` measurement results writer.  This is the ASCII format
/// emitted by HSPICE for `.MEASURE` directives — one header row of names,
/// one numeric row per measurement.
///
/// # Example
/// ```
/// use pisim_io::hspice::HspiceMt0Writer;
/// let mut w = HspiceMt0Writer::new("rc demo");
/// w.add_measurement("risetime", 1.2e-6);
/// w.add_measurement("vmax", 4.95);
/// let mut buf = Vec::new();
/// w.write(&mut buf).unwrap();
/// let s = std::str::from_utf8(&buf).unwrap();
/// assert!(s.contains("risetime"));
/// ```
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

    /// Write the `.mt0` ASCII file.  Format is HSPICE-compatible:
    ///
    /// ```text
    /// $DATA1 SOURCE='PiSIM' VERSION='0.1.0'
    /// .TITLE '<title>'
    /// <name1>     <name2>     ...
    /// <value1>    <value2>    ...
    /// ```
    pub fn write<W: Write>(&self, mut w: W) -> io::Result<()> {
        writeln!(w, "$DATA1 SOURCE='PiSIM' VERSION='0.1.0'")?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_padded_truncates_and_pads() {
        let mut buf = Vec::new();
        write_padded(&mut buf, "hello", 9);
        assert_eq!(buf.len(), 9);
        assert_eq!(&buf[..5], b"hello");
        assert_eq!(&buf[5..], b"    ");

        let mut buf2 = Vec::new();
        write_padded(&mut buf2, "abcdefghijklm", 9);
        assert_eq!(buf2.len(), 9);
        assert_eq!(&buf2[..], b"abcdefghi");
    }

    #[test]
    fn write_record_brackets_payload_with_length() {
        let mut buf = Vec::new();
        write_record(&mut buf, b"abc").unwrap();
        // 4 bytes len + 3 bytes payload + 4 bytes len = 11.
        assert_eq!(buf.len(), 11);
        assert_eq!(&buf[..4], &3u32.to_le_bytes());
        assert_eq!(&buf[4..7], b"abc");
        assert_eq!(&buf[7..], &3u32.to_le_bytes());
    }

    #[test]
    fn tr0_writer_emits_four_records() {
        let mut w = HspicePostWriter::new(HspicePostKind::Transient, "rc test");
        w.set_independent("time", &[0.0, 1e-6, 2e-6, 3e-6]);
        w.add_column("v(out)", HspiceVarType::Voltage, &[0.0, 0.63, 0.86, 0.95]);
        w.add_column("i(v1)", HspiceVarType::Current, &[1e-3, 0.9e-3, 0.6e-3, 0.4e-3]);

        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();

        // Walk the records: each starts with a u32 LE length and ends with the
        // same length.  We expect exactly 4 records (header, types, names, data).
        let mut records = 0usize;
        let mut i = 0usize;
        while i < buf.len() {
            let len = u32::from_le_bytes([buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]) as usize;
            i += 4 + len;
            // trailer
            let trailer =
                u32::from_le_bytes([buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]) as usize;
            assert_eq!(trailer, len, "record trailer mismatch at offset {i}");
            i += 4;
            records += 1;
        }
        assert_eq!(records, 4);
    }

    #[test]
    fn ac0_writer_emits_real_and_imag_columns() {
        // v(out) = 0 + 1j  =>  real=0.0, imag=1.0
        // v(out) = 1 + 0j  =>  real=1.0, imag=0.0
        // v(out) = 1 + 1j  =>  real=1.0, imag=1.0
        let freqs = [1e3_f64, 10e3, 100e3];
        let complex = [(0.0_f64, 1.0_f64), (1.0, 0.0), (1.0, 1.0)];

        let mut writer = HspicePostWriter::new(HspicePostKind::Ac, "ac test");
        writer.set_independent("frequency", &freqs);
        writer.add_ac_column("v(out)", HspiceVarType::Voltage, &complex);

        let mut buf = Vec::new();
        writer.write(&mut buf).unwrap();

        // Walk records; there must be exactly 4.
        let mut records = 0usize;
        let mut i = 0usize;
        while i < buf.len() {
            let len = u32::from_le_bytes([buf[i], buf[i+1], buf[i+2], buf[i+3]]) as usize;
            i += 4 + len + 4;
            records += 1;
        }
        assert_eq!(records, 4, "expected 4 Fortran records");

        // Decode the data record (record 4). Offset: after records 1-3.
        // Each record is: 4-byte len + payload + 4-byte len.
        let mut offset = 0usize;
        for _ in 0..3 {
            let len = u32::from_le_bytes([buf[offset], buf[offset+1], buf[offset+2], buf[offset+3]]) as usize;
            offset += 4 + len + 4;
        }
        // Now at record 4 (data block).
        let data_len = u32::from_le_bytes([buf[offset], buf[offset+1], buf[offset+2], buf[offset+3]]) as usize;
        let data_start = offset + 4;
        let data = &buf[data_start..data_start + data_len];

        // Row layout: freq(f32), real(f32), imag(f32)
        // Each row = 3 × 4 bytes = 12 bytes; plus 4-byte sentinel at end.
        assert!(data_len >= 3 * 3 * 4 + 4, "data block too small: {data_len}");

        // Row 0: 0+1j => real=0.0, imag=1.0
        let _freq0 = f32::from_le_bytes(data[0..4].try_into().unwrap());
        let re0 = f32::from_le_bytes(data[4..8].try_into().unwrap());
        let im0 = f32::from_le_bytes(data[8..12].try_into().unwrap());
        assert!(re0.abs() < 1e-5, "re0={re0}");
        assert!((im0 - 1.0).abs() < 1e-5, "im0={im0}");

        // Row 1: 1+0j => real=1.0, imag=0.0
        let re1 = f32::from_le_bytes(data[16..20].try_into().unwrap());
        let im1 = f32::from_le_bytes(data[20..24].try_into().unwrap());
        assert!((re1 - 1.0).abs() < 1e-5, "re1={re1}");
        assert!(im1.abs() < 1e-5, "im1={im1}");

        // Row 2: 1+1j => real=1.0, imag=1.0
        let re2 = f32::from_le_bytes(data[28..32].try_into().unwrap());
        let im2 = f32::from_le_bytes(data[32..36].try_into().unwrap());
        assert!((re2 - 1.0).abs() < 1e-5, "re2={re2}");
        assert!((im2 - 1.0).abs() < 1e-5, "im2={im2}");
    }

    #[test]
    fn ac0_column_names_have_real_imag_suffix() {
        let freqs = [1e3_f64];
        let complex = [(1.0_f64, 0.0_f64)];

        let mut writer = HspicePostWriter::new(HspicePostKind::Ac, "ac names test");
        writer.set_independent("frequency", &freqs);
        writer.add_ac_column("v(out)", HspiceVarType::Voltage, &complex);

        let mut buf = Vec::new();
        writer.write(&mut buf).unwrap();

        // Extract names block (record 3): walk past records 1 and 2.
        let mut offset = 0usize;
        for _ in 0..2 {
            let len = u32::from_le_bytes([buf[offset], buf[offset+1], buf[offset+2], buf[offset+3]]) as usize;
            offset += 4 + len + 4;
        }
        let names_len = u32::from_le_bytes([buf[offset], buf[offset+1], buf[offset+2], buf[offset+3]]) as usize;
        let names_start = offset + 4;
        let names_bytes = &buf[names_start..names_start + names_len];
        let names_str = std::str::from_utf8(names_bytes).expect("names block is UTF-8");

        assert!(names_str.contains("v(out):REAL"), "expected v(out):REAL in '{names_str}'");
        assert!(names_str.contains("v(out):IMAG"), "expected v(out):IMAG in '{names_str}'");
    }

    #[test]
    fn mt0_writer_text_layout() {
        let mut w = HspiceMt0Writer::new("rc demo");
        w.add_measurement("risetime", 1.234e-6);
        w.add_measurement("vmax", 4.95);
        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();
        let s = std::str::from_utf8(&buf).unwrap();
        // Has the data block marker.
        assert!(s.starts_with("$DATA1"));
        // Title preserved.
        assert!(s.contains(".TITLE 'rc demo'"));
        // Both names appear.
        assert!(s.contains("risetime"));
        assert!(s.contains("vmax"));
        // Both values appear in scientific notation; presence of an `e` is enough.
        assert!(s.contains("e-6") || s.contains("e-06") || s.contains("e6"));
        assert!(s.matches('e').count() >= 2);
    }
}
