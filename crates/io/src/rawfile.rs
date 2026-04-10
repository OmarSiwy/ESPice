//! Berkeley rawfile reader and writer (ASCII + binary).
//!
//! The Berkeley rawfile is the de-facto interchange format for ngspice and
//! every common waveform viewer (`gaw`, `gwave`, `kst`).  Two flavors:
//!
//! * **ASCII** — header + `Values:` section, one value per line.  Easy to
//!   diff, slow on big runs.
//! * **Binary** — same header followed by `Binary:\n` and a tightly packed
//!   stream of native-endian `f64` values, point-major (row-major over
//!   variables × points).
//!
//! For the binary form, ngspice uses **platform-native** float endianness —
//! it's not portable across architectures.  Tools that read it (`ngspice -r`)
//! always run on the same machine that wrote it.  We follow that convention
//! exactly so produced files are bit-identical with ngspice.
//!
//! Both forms support real DC OP / DC sweep / transient (Real) and complex
//! AC sweep (Complex — pairs of f64 stored as `(re, im)` per value).

use std::io::{self, BufRead, BufReader, Read, Write};
use thiserror::Error;

/// Whether the data is real or complex (AC).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RawFlag {
    Real,
    Complex,
}

impl RawFlag {
    pub fn as_str(&self) -> &'static str {
        match self {
            RawFlag::Real => "real",
            RawFlag::Complex => "complex",
        }
    }
}

/// Single variable in the rawfile header.
#[derive(Debug, Clone, PartialEq)]
pub struct RawVariable {
    pub index: usize,
    pub name: String,
    pub var_type: String,
}

/// Errors from the rawfile reader.
#[derive(Debug, Error)]
pub enum RawFileError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("missing required field: {0}")]
    MissingField(String),
    #[error("parse error at line {line}: {msg}")]
    Parse { line: usize, msg: String },
    #[error("no data section found")]
    NoData,
    #[error("truncated binary data: expected {expected} f64 values, got {got}")]
    TruncatedBinary { expected: usize, got: usize },
}

/// Parsed representation of a Berkeley rawfile.  Real numbers are stored
/// directly; complex numbers are stored as (re, im) pairs flattened into the
/// inner `f64` slots — `data[point][2*var]` is the real part and
/// `data[point][2*var+1]` is the imaginary part when `flags == Complex`.
#[derive(Debug, Clone)]
pub struct RawFile {
    pub title: String,
    pub date: String,
    pub plotname: String,
    pub flags: RawFlag,
    pub variables: Vec<RawVariable>,
    /// `data[point_index][value_slot]`.  For real data, slot count == variable
    /// count.  For complex data, slot count == 2 * variable count.
    pub data: Vec<Vec<f64>>,
}

impl RawFile {
    /// Number of points stored.
    pub fn num_points(&self) -> usize {
        self.data.len()
    }

    /// Number of variables (columns).  This is the *variable* count, not the
    /// `f64`-slot count — for complex data the slot count is 2x this.
    pub fn num_variables(&self) -> usize {
        self.variables.len()
    }

    /// Get the real value of variable `var_idx` at `point_idx`.  For complex
    /// data this returns the real part.
    pub fn real(&self, point_idx: usize, var_idx: usize) -> f64 {
        match self.flags {
            RawFlag::Real => self.data[point_idx][var_idx],
            RawFlag::Complex => self.data[point_idx][2 * var_idx],
        }
    }

    /// Get the imaginary value of variable `var_idx` at `point_idx`.  Returns
    /// `0.0` for real data.
    pub fn imag(&self, point_idx: usize, var_idx: usize) -> f64 {
        match self.flags {
            RawFlag::Real => 0.0,
            RawFlag::Complex => self.data[point_idx][2 * var_idx + 1],
        }
    }

    /// Read a rawfile from any `Read`.  Auto-detects ASCII vs binary.
    pub fn read<R: Read>(reader: R) -> Result<Self, RawFileError> {
        // Buffer the whole stream — both writers and the binary reader need it.
        let mut buf_reader = BufReader::new(reader);
        let mut header = Vec::<u8>::new();

        // Read header until we hit either "Values:\n" or "Binary:\n".
        let mut binary = false;
        loop {
            let mut line = Vec::<u8>::new();
            let n = buf_reader.read_until(b'\n', &mut line)?;
            if n == 0 {
                break;
            }
            // Check for the section delimiter (case-sensitive ngspice convention).
            let trimmed: &[u8] = line
                .strip_suffix(b"\n")
                .map(|s| s.strip_suffix(b"\r").unwrap_or(s))
                .unwrap_or(&line);
            header.extend_from_slice(&line);
            if trimmed == b"Values:" {
                break;
            }
            if trimmed == b"Binary:" {
                binary = true;
                break;
            }
        }

        let header_str = String::from_utf8_lossy(&header);
        let (title, date, plotname, flags, variables, num_points, _num_vars) =
            parse_header(&header_str)?;

        if binary {
            // Read raw f64 values: num_points * (vars or 2*vars).
            let slot_count = match flags {
                RawFlag::Real => variables.len(),
                RawFlag::Complex => 2 * variables.len(),
            };
            let total = num_points * slot_count;
            let mut bytes = Vec::with_capacity(total * 8);
            buf_reader.read_to_end(&mut bytes)?;
            if bytes.len() < total * 8 {
                return Err(RawFileError::TruncatedBinary {
                    expected: total,
                    got: bytes.len() / 8,
                });
            }
            let mut data: Vec<Vec<f64>> = Vec::with_capacity(num_points);
            for p in 0..num_points {
                let mut row = Vec::with_capacity(slot_count);
                for s in 0..slot_count {
                    let offset = (p * slot_count + s) * 8;
                    let mut buf = [0u8; 8];
                    buf.copy_from_slice(&bytes[offset..offset + 8]);
                    row.push(f64::from_ne_bytes(buf));
                }
                data.push(row);
            }
            Ok(RawFile {
                title,
                date,
                plotname,
                flags,
                variables,
                data,
            })
        } else {
            // ASCII section: read remaining lines and dispatch to the parser.
            let mut rest = String::new();
            buf_reader.read_to_string(&mut rest)?;
            let data = parse_ascii_values(&rest, &flags, variables.len(), num_points)?;
            Ok(RawFile {
                title,
                date,
                plotname,
                flags,
                variables,
                data,
            })
        }
    }

    /// Write the rawfile in ASCII form.
    pub fn write_ascii<W: Write>(&self, mut w: W) -> io::Result<()> {
        writeln!(w, "Title: {}", self.title)?;
        if !self.date.is_empty() {
            writeln!(w, "Date: {}", self.date)?;
        }
        writeln!(w, "Plotname: {}", self.plotname)?;
        writeln!(w, "Flags: {}", self.flags.as_str())?;
        writeln!(w, "No. Variables: {}", self.variables.len())?;
        writeln!(w, "No. Points: {}", self.num_points())?;
        writeln!(w, "Variables:")?;
        for v in &self.variables {
            writeln!(w, "\t{}\t{}\t{}", v.index, v.name, v.var_type)?;
        }
        writeln!(w, "Values:")?;
        let nvars = self.variables.len();
        for (pidx, row) in self.data.iter().enumerate() {
            // ngspice uses "<idx>\t<value>" for the first value of each point,
            // then "\t<value>" for the rest.  Real data has nvars values per
            // point; complex has nvars values printed as "<re>,<im>".
            for v in 0..nvars {
                if v == 0 {
                    write!(w, " {pidx}\t")?;
                } else {
                    write!(w, "\t")?;
                }
                match self.flags {
                    RawFlag::Real => writeln!(w, "{:.15e}", row[v])?,
                    RawFlag::Complex => writeln!(w, "{:.15e},{:.15e}", row[2 * v], row[2 * v + 1])?,
                }
            }
            writeln!(w)?;
        }
        Ok(())
    }

    /// Write the rawfile in native-endian binary form.
    pub fn write_binary<W: Write>(&self, mut w: W) -> io::Result<()> {
        writeln!(w, "Title: {}", self.title)?;
        if !self.date.is_empty() {
            writeln!(w, "Date: {}", self.date)?;
        }
        writeln!(w, "Plotname: {}", self.plotname)?;
        writeln!(w, "Flags: {}", self.flags.as_str())?;
        writeln!(w, "No. Variables: {}", self.variables.len())?;
        writeln!(w, "No. Points: {}", self.num_points())?;
        writeln!(w, "Variables:")?;
        for v in &self.variables {
            writeln!(w, "\t{}\t{}\t{}", v.index, v.name, v.var_type)?;
        }
        writeln!(w, "Binary:")?;
        for row in &self.data {
            for v in row {
                w.write_all(&v.to_ne_bytes())?;
            }
        }
        Ok(())
    }
}

/// Output format for [`RawfileWriter`].  Controlled by `.OPTIONS FILETYPE=ASCII`
/// or `RAWFMT=ASCII` in the netlist, or by choosing the appropriate constructor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Filetype {
    /// Tightly-packed native-endian IEEE 754 `f64` stream after the `Binary:`
    /// header separator.  Faster and smaller; the default.
    Binary,
    /// Space/newline-separated ASCII decimal numbers after the `Values:`
    /// header separator.  Human-readable and diff-friendly; required by some
    /// waveform viewers.
    Ascii,
}

/// Strongly-typed builder/writer for rawfiles.  This is the public writer API
/// used by the analysis crate — it accepts column-major (`&[f64]` per
/// variable) data and writes either ASCII or binary form.
///
/// The output format is selected at construction time via [`RawfileWriter::new`]
/// (binary, the default) or [`RawfileWriter::new_ascii`] (ASCII).  It can also
/// be changed after construction with the [`RawfileWriter::ascii`] /
/// [`RawfileWriter::binary`] builder methods.
///
/// # Example — binary (default)
/// ```
/// use pisim_io::rawfile::{RawfileWriter, RawFlag};
/// let mut buf = Vec::<u8>::new();
/// let mut w = RawfileWriter::new("rc demo", "Transient Analysis", RawFlag::Real);
/// w.add_variable("time", "time");
/// w.add_variable("v(out)", "voltage");
/// w.set_real_columns(&[
///     vec![0.0, 1e-6, 2e-6],     // time
///     vec![0.0, 0.63, 0.86],     // v(out)
/// ]).unwrap();
/// w.write(&mut buf).unwrap();
/// // Binary header contains "Binary:" not "Values:"
/// assert!(!std::str::from_utf8(&buf[..200]).unwrap_or("").contains("Values:"));
/// ```
///
/// # Example — ASCII
/// ```
/// use pisim_io::rawfile::{RawfileWriter, RawFlag};
/// let mut buf = Vec::<u8>::new();
/// let mut w = RawfileWriter::new_ascii("rc demo", "Transient Analysis", RawFlag::Real);
/// w.add_variable("time", "time");
/// w.add_variable("v(out)", "voltage");
/// w.set_real_columns(&[
///     vec![0.0, 1e-6, 2e-6],     // time
///     vec![0.0, 0.63, 0.86],     // v(out)
/// ]).unwrap();
/// w.write(&mut buf).unwrap();
/// assert!(std::str::from_utf8(&buf).unwrap().contains("Values:"));
/// ```
pub struct RawfileWriter {
    title: String,
    date: String,
    plotname: String,
    flags: RawFlag,
    /// Whether to emit ASCII (`Values:`) or binary (`Binary:`) output.
    pub filetype: Filetype,
    variables: Vec<RawVariable>,
    /// Column-major: `columns[var_idx]` is a vec of f64 (real) or pairs (complex).
    /// For complex data the per-column length is 2 * num_points and is laid
    /// out as `[re, im, re, im, ...]`.
    columns: Vec<Vec<f64>>,
}

impl RawfileWriter {
    /// Create a writer that emits **binary** rawfile output (the default).
    pub fn new(title: &str, plotname: &str, flags: RawFlag) -> Self {
        Self {
            title: title.to_string(),
            date: String::new(),
            plotname: plotname.to_string(),
            flags,
            filetype: Filetype::Binary,
            variables: Vec::new(),
            columns: Vec::new(),
        }
    }

    /// Create a writer that emits **ASCII** rawfile output (`Values:` separator,
    /// decimal numbers).  Equivalent to `RawfileWriter::new(…).ascii()`.
    pub fn new_ascii(title: &str, plotname: &str, flags: RawFlag) -> Self {
        Self {
            filetype: Filetype::Ascii,
            ..Self::new(title, plotname, flags)
        }
    }

    /// Switch output to ASCII format (builder method).
    pub fn ascii(mut self) -> Self {
        self.filetype = Filetype::Ascii;
        self
    }

    /// Switch output to binary format (builder method).
    pub fn binary(mut self) -> Self {
        self.filetype = Filetype::Binary;
        self
    }

    pub fn set_date(&mut self, date: &str) {
        self.date = date.to_string();
    }

    /// Append a variable definition.  Returns the index assigned to it.
    pub fn add_variable(&mut self, name: &str, var_type: &str) -> usize {
        let idx = self.variables.len();
        self.variables.push(RawVariable {
            index: idx,
            name: name.to_string(),
            var_type: var_type.to_string(),
        });
        idx
    }

    /// Provide column-major real data.  Each inner slice is one variable's
    /// values across all points.  All slices must have the same length.
    pub fn set_real_columns(&mut self, columns: &[Vec<f64>]) -> Result<(), RawFileError> {
        if self.flags != RawFlag::Real {
            return Err(RawFileError::Parse {
                line: 0,
                msg: "set_real_columns called on a Complex writer".into(),
            });
        }
        if columns.len() != self.variables.len() {
            return Err(RawFileError::Parse {
                line: 0,
                msg: format!(
                    "expected {} columns, got {}",
                    self.variables.len(),
                    columns.len()
                ),
            });
        }
        if let Some(first) = columns.first() {
            let n = first.len();
            for (i, col) in columns.iter().enumerate() {
                if col.len() != n {
                    return Err(RawFileError::Parse {
                        line: 0,
                        msg: format!("column {i} has length {} != {n}", col.len()),
                    });
                }
            }
        }
        self.columns = columns.to_vec();
        Ok(())
    }

    /// Provide column-major complex data as parallel `(re, im)` slices.
    pub fn set_complex_columns(
        &mut self,
        re: &[Vec<f64>],
        im: &[Vec<f64>],
    ) -> Result<(), RawFileError> {
        if self.flags != RawFlag::Complex {
            return Err(RawFileError::Parse {
                line: 0,
                msg: "set_complex_columns called on a Real writer".into(),
            });
        }
        if re.len() != self.variables.len() || im.len() != self.variables.len() {
            return Err(RawFileError::Parse {
                line: 0,
                msg: format!(
                    "expected {} re/im columns, got re={} im={}",
                    self.variables.len(),
                    re.len(),
                    im.len()
                ),
            });
        }
        let n = re.first().map(|c| c.len()).unwrap_or(0);
        for (i, (rc, ic)) in re.iter().zip(im.iter()).enumerate() {
            if rc.len() != n || ic.len() != n {
                return Err(RawFileError::Parse {
                    line: 0,
                    msg: format!("complex column {i} has mismatched length"),
                });
            }
        }
        // Pack as interleaved (re, im) per element so the row layout matches RawFile.
        self.columns = re
            .iter()
            .zip(im.iter())
            .map(|(rc, ic)| {
                let mut interleaved = Vec::with_capacity(2 * rc.len());
                for (r, im) in rc.iter().zip(ic.iter()) {
                    interleaved.push(*r);
                    interleaved.push(*im);
                }
                interleaved
            })
            .collect();
        Ok(())
    }

    fn build(&self) -> RawFile {
        let num_points = self
            .columns
            .first()
            .map(|c| match self.flags {
                RawFlag::Real => c.len(),
                RawFlag::Complex => c.len() / 2,
            })
            .unwrap_or(0);

        // Convert column-major to row-major (the on-disk shape).
        let nvars = self.variables.len();
        let slots_per_point = match self.flags {
            RawFlag::Real => nvars,
            RawFlag::Complex => 2 * nvars,
        };
        let mut data = vec![vec![0.0_f64; slots_per_point]; num_points];
        for (var_idx, col) in self.columns.iter().enumerate() {
            for p in 0..num_points {
                match self.flags {
                    RawFlag::Real => data[p][var_idx] = col[p],
                    RawFlag::Complex => {
                        data[p][2 * var_idx] = col[2 * p];
                        data[p][2 * var_idx + 1] = col[2 * p + 1];
                    }
                }
            }
        }

        RawFile {
            title: self.title.clone(),
            date: self.date.clone(),
            plotname: self.plotname.clone(),
            flags: self.flags,
            variables: self.variables.clone(),
            data,
        }
    }

    /// Write ASCII rawfile.
    pub fn write_ascii<W: Write>(&self, w: W) -> io::Result<()> {
        self.build().write_ascii(w)
    }

    /// Write native-endian binary rawfile.
    pub fn write_binary<W: Write>(&self, w: W) -> io::Result<()> {
        self.build().write_binary(w)
    }

    /// Write rawfile in the format selected by [`Self::filetype`].
    ///
    /// * [`Filetype::Binary`] — emits a `Binary:` separator and packed f64 bytes.
    /// * [`Filetype::Ascii`]  — emits a `Values:` separator and decimal numbers.
    pub fn write<W: Write>(&self, w: W) -> io::Result<()> {
        match self.filetype {
            Filetype::Binary => self.write_binary(w),
            Filetype::Ascii => self.write_ascii(w),
        }
    }
}

// ─── header / values parsers ──────────────────────────────────────────────────

#[allow(clippy::type_complexity)]
fn parse_header(
    header: &str,
) -> Result<
    (
        String,
        String,
        String,
        RawFlag,
        Vec<RawVariable>,
        usize,
        usize,
    ),
    RawFileError,
> {
    let lines: Vec<&str> = header.lines().collect();
    let mut i = 0;

    let mut title: Option<String> = None;
    let mut date: String = String::new();
    let mut plotname: Option<String> = None;
    let mut flags: Option<RawFlag> = None;
    let mut num_variables: Option<usize> = None;
    let mut num_points: Option<usize> = None;

    while i < lines.len() {
        let line = lines[i];
        if line == "Variables:" {
            i += 1;
            break;
        }
        if let Some(val) = line.strip_prefix("Title: ") {
            title = Some(val.to_string());
        } else if let Some(val) = line.strip_prefix("Date: ") {
            date = val.to_string();
        } else if let Some(val) = line.strip_prefix("Plotname: ") {
            plotname = Some(val.to_string());
        } else if let Some(val) = line.strip_prefix("Flags: ") {
            flags = Some(match val.trim().to_lowercase().as_str() {
                "real" => RawFlag::Real,
                "complex" => RawFlag::Complex,
                other => {
                    return Err(RawFileError::Parse {
                        line: i + 1,
                        msg: format!("unknown flag: {other}"),
                    });
                }
            });
        } else if let Some(val) = line.strip_prefix("No. Variables: ") {
            num_variables =
                Some(val.trim().parse::<usize>().map_err(|e| RawFileError::Parse {
                    line: i + 1,
                    msg: format!("invalid variable count: {e}"),
                })?);
        } else if let Some(val) = line.strip_prefix("No. Points: ") {
            num_points =
                Some(val.trim().parse::<usize>().map_err(|e| RawFileError::Parse {
                    line: i + 1,
                    msg: format!("invalid point count: {e}"),
                })?);
        }
        i += 1;
    }

    let title = title.ok_or_else(|| RawFileError::MissingField("Title".into()))?;
    let plotname = plotname.ok_or_else(|| RawFileError::MissingField("Plotname".into()))?;
    let flags = flags.ok_or_else(|| RawFileError::MissingField("Flags".into()))?;
    let num_variables =
        num_variables.ok_or_else(|| RawFileError::MissingField("No. Variables".into()))?;
    let num_points =
        num_points.ok_or_else(|| RawFileError::MissingField("No. Points".into()))?;

    let mut variables = Vec::with_capacity(num_variables);
    for _ in 0..num_variables {
        if i >= lines.len() {
            return Err(RawFileError::Parse {
                line: i + 1,
                msg: "unexpected end of header in Variables section".into(),
            });
        }
        let line = lines[i];
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() < 4 {
            return Err(RawFileError::Parse {
                line: i + 1,
                msg: format!("expected variable definition, got: {line}"),
            });
        }
        let index = parts[1].trim().parse::<usize>().map_err(|e| RawFileError::Parse {
            line: i + 1,
            msg: format!("invalid variable index: {e}"),
        })?;
        let name = parts[2].to_string();
        let var_type = parts[3].to_string();
        variables.push(RawVariable {
            index,
            name,
            var_type,
        });
        i += 1;
    }

    Ok((title, date, plotname, flags, variables, num_points, num_variables))
}

fn parse_ascii_values(
    body: &str,
    flags: &RawFlag,
    nvars: usize,
    num_points: usize,
) -> Result<Vec<Vec<f64>>, RawFileError> {
    let slots = match flags {
        RawFlag::Real => nvars,
        RawFlag::Complex => 2 * nvars,
    };
    let mut data: Vec<Vec<f64>> = Vec::with_capacity(num_points);
    let mut current: Option<Vec<f64>> = None;

    for (lineno, line) in body.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        // First line of a point starts with " <idx>\t<value>"
        // Continuation lines start with "\t<value>"
        let parse_value = |s: &str, line: usize| -> Result<Vec<f64>, RawFileError> {
            // For real values: just parse as f64.
            // For complex: parse as "re,im".
            match flags {
                RawFlag::Real => {
                    let v = s.trim().parse::<f64>().map_err(|e| RawFileError::Parse {
                        line,
                        msg: format!("invalid real value: {e}"),
                    })?;
                    Ok(vec![v])
                }
                RawFlag::Complex => {
                    let trimmed = s.trim();
                    let (re_str, im_str) = match trimmed.split_once(',') {
                        Some(p) => p,
                        None => {
                            return Err(RawFileError::Parse {
                                line,
                                msg: format!("expected re,im pair, got: {trimmed}"),
                            });
                        }
                    };
                    let re = re_str.parse::<f64>().map_err(|e| RawFileError::Parse {
                        line,
                        msg: format!("invalid real part: {e}"),
                    })?;
                    let im = im_str.parse::<f64>().map_err(|e| RawFileError::Parse {
                        line,
                        msg: format!("invalid imag part: {e}"),
                    })?;
                    Ok(vec![re, im])
                }
            }
        };

        if line.starts_with(' ') || line.starts_with(char::is_numeric) {
            if let Some(prev) = current.take() {
                data.push(prev);
            }
            let parts: Vec<&str> = line.splitn(2, '\t').collect();
            if parts.len() < 2 {
                return Err(RawFileError::Parse {
                    line: lineno + 1,
                    msg: format!("expected point header + value, got: {line}"),
                });
            }
            let mut row = Vec::with_capacity(slots);
            row.extend(parse_value(parts[1], lineno + 1)?);
            current = Some(row);
        } else if line.starts_with('\t') {
            let row = current.as_mut().ok_or_else(|| RawFileError::Parse {
                line: lineno + 1,
                msg: "continuation value before any point header".into(),
            })?;
            row.extend(parse_value(line, lineno + 1)?);
        }
    }
    if let Some(prev) = current.take() {
        data.push(prev);
    }
    Ok(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_real_writer() -> RawfileWriter {
        let mut w = RawfileWriter::new("rc demo", "Transient Analysis", RawFlag::Real);
        w.set_date("Sun Apr  7 12:00:00 2026");
        w.add_variable("time", "time");
        w.add_variable("v(out)", "voltage");
        w.add_variable("v(in)", "voltage");
        w.set_real_columns(&[
            vec![0.0, 1e-6, 2e-6, 3e-6],
            vec![0.0, 0.63, 0.86, 0.95],
            vec![5.0, 5.0, 5.0, 5.0],
        ][..])
        .unwrap();
        w
    }

    #[test]
    fn ascii_round_trip_real() {
        let w = make_real_writer();
        let mut buf = Vec::new();
        w.write_ascii(&mut buf).unwrap();

        let parsed = RawFile::read(&buf[..]).unwrap();
        assert_eq!(parsed.title, "rc demo");
        assert_eq!(parsed.plotname, "Transient Analysis");
        assert_eq!(parsed.flags, RawFlag::Real);
        assert_eq!(parsed.variables.len(), 3);
        assert_eq!(parsed.num_points(), 4);

        for p in 0..4 {
            for v in 0..3 {
                let original = match v {
                    0 => p as f64 * 1e-6,
                    1 => [0.0, 0.63, 0.86, 0.95][p],
                    2 => 5.0,
                    _ => unreachable!(),
                };
                assert!((parsed.real(p, v) - original).abs() < 1e-12);
            }
        }
    }

    #[test]
    fn binary_round_trip_real() {
        let w = make_real_writer();
        let mut buf = Vec::new();
        w.write_binary(&mut buf).unwrap();

        let parsed = RawFile::read(&buf[..]).unwrap();
        assert_eq!(parsed.flags, RawFlag::Real);
        assert_eq!(parsed.num_points(), 4);
        assert!((parsed.real(2, 1) - 0.86).abs() < 1e-15);
        assert!((parsed.real(3, 2) - 5.0).abs() < 1e-15);
    }

    #[test]
    fn ascii_round_trip_complex() {
        let mut w = RawfileWriter::new("ac demo", "AC Analysis", RawFlag::Complex);
        w.add_variable("frequency", "frequency");
        w.add_variable("v(out)", "voltage");
        w.set_complex_columns(
            &[vec![1.0, 10.0, 100.0], vec![1.0, 0.7, 0.1]][..],
            &[vec![0.0, 0.0, 0.0], vec![0.0, -0.3, -0.9]][..],
        )
        .unwrap();

        let mut buf = Vec::new();
        w.write_ascii(&mut buf).unwrap();

        let parsed = RawFile::read(&buf[..]).unwrap();
        assert_eq!(parsed.flags, RawFlag::Complex);
        assert_eq!(parsed.num_points(), 3);
        assert!((parsed.real(1, 1) - 0.7).abs() < 1e-12);
        assert!((parsed.imag(1, 1) - (-0.3)).abs() < 1e-12);
        assert!((parsed.real(2, 0) - 100.0).abs() < 1e-12);
    }

    #[test]
    fn binary_round_trip_complex() {
        let mut w = RawfileWriter::new("ac demo", "AC Analysis", RawFlag::Complex);
        w.add_variable("frequency", "frequency");
        w.add_variable("v(out)", "voltage");
        w.set_complex_columns(
            &[vec![1.0, 10.0, 100.0], vec![1.0, 0.7, 0.1]][..],
            &[vec![0.0, 0.0, 0.0], vec![0.0, -0.3, -0.9]][..],
        )
        .unwrap();

        let mut buf = Vec::new();
        w.write_binary(&mut buf).unwrap();
        let parsed = RawFile::read(&buf[..]).unwrap();
        assert_eq!(parsed.flags, RawFlag::Complex);
        assert!((parsed.imag(2, 1) - (-0.9)).abs() < 1e-15);
    }

    // ── Filetype / write() dispatch tests ────────────────────────────────────

    /// `new_ascii` + `write()` must produce a file with a `Values:` marker and
    /// no `Binary:` marker, and the reader must round-trip the values exactly.
    #[test]
    fn filetype_ascii_write_dispatch() {
        let mut w =
            RawfileWriter::new_ascii("filetype test", "Transient Analysis", RawFlag::Real);
        w.set_date("Thu Apr  9 00:00:00 2026");
        w.add_variable("time", "time");
        w.add_variable("v(a)", "voltage");
        w.add_variable("v(b)", "voltage");
        w.set_real_columns(&[
            vec![0.0, 1e-9, 2e-9, 3e-9],
            vec![0.0, 1.23456789012345, -3.14159265358979, 1e-15],
            vec![5.0, 4.5, 4.0, 3.5],
        ])
        .unwrap();

        // Verify the filetype field is set correctly.
        assert_eq!(w.filetype, Filetype::Ascii);

        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();

        // The header text must contain "Values:" and must NOT contain "Binary:".
        let text = std::str::from_utf8(&buf).unwrap();
        assert!(text.contains("Values:"), "expected 'Values:' in ASCII output");
        assert!(!text.contains("Binary:"), "unexpected 'Binary:' in ASCII output");

        // Round-trip: reader must recover all values within f64 round-trip precision.
        let parsed = RawFile::read(&buf[..]).unwrap();
        assert_eq!(parsed.title, "filetype test");
        assert_eq!(parsed.plotname, "Transient Analysis");
        assert_eq!(parsed.flags, RawFlag::Real);
        assert_eq!(parsed.variables.len(), 3);
        assert_eq!(parsed.num_points(), 4);

        let expected_time = [0.0_f64, 1e-9, 2e-9, 3e-9];
        let expected_va = [0.0_f64, 1.23456789012345, -3.14159265358979, 1e-15];
        let expected_vb = [5.0_f64, 4.5, 4.0, 3.5];
        for p in 0..4 {
            assert!(
                (parsed.real(p, 0) - expected_time[p]).abs() < 1e-24,
                "time[{p}] mismatch: got {}, expected {}",
                parsed.real(p, 0),
                expected_time[p]
            );
            assert!(
                (parsed.real(p, 1) - expected_va[p]).abs() < 1e-12,
                "v(a)[{p}] mismatch: got {}, expected {}",
                parsed.real(p, 1),
                expected_va[p]
            );
            assert!(
                (parsed.real(p, 2) - expected_vb[p]).abs() < 1e-12,
                "v(b)[{p}] mismatch: got {}, expected {}",
                parsed.real(p, 2),
                expected_vb[p]
            );
        }
    }

    /// `new()` (binary default) + `write()` must produce a file with `Binary:`
    /// and no `Values:` in the readable portion of the header.
    #[test]
    fn filetype_binary_write_dispatch() {
        let w = make_real_writer();
        assert_eq!(w.filetype, Filetype::Binary);

        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();

        // Only the header is text; the body is binary — scan just the header.
        // The header ends after "Binary:\n" which is ~200 bytes at most.
        let header_end = buf
            .windows(7)
            .position(|win| win == b"Binary:")
            .map(|p| p + 8)
            .unwrap_or(buf.len());
        let header = std::str::from_utf8(&buf[..header_end]).unwrap();
        assert!(header.contains("Binary:"), "expected 'Binary:' in binary output");
        assert!(!header.contains("Values:"), "unexpected 'Values:' in binary output");

        // And it must still round-trip correctly.
        let parsed = RawFile::read(&buf[..]).unwrap();
        assert_eq!(parsed.num_points(), 4);
        assert!((parsed.real(2, 1) - 0.86).abs() < 1e-15);
    }

    /// Builder method `.ascii()` must switch an existing binary writer to ASCII.
    #[test]
    fn builder_ascii_method() {
        let mut w = RawfileWriter::new("builder test", "DC", RawFlag::Real);
        w.add_variable("v(1)", "voltage");
        w.set_real_columns(&[vec![1.0, 2.0, 3.0]]).unwrap();
        let w = w.ascii(); // consume + return Self with filetype changed
        assert_eq!(w.filetype, Filetype::Ascii);
        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();
        let text = std::str::from_utf8(&buf).unwrap();
        assert!(text.contains("Values:"));
    }

    /// Builder method `.binary()` must switch an ASCII writer back to binary.
    #[test]
    fn builder_binary_method() {
        let w = RawfileWriter::new_ascii("builder test", "DC", RawFlag::Real)
            .binary();
        assert_eq!(w.filetype, Filetype::Binary);
    }

    /// ASCII round-trip for complex (AC) data via `new_ascii` + `write()`.
    #[test]
    fn filetype_ascii_complex_round_trip() {
        let mut w = RawfileWriter::new_ascii("ac filetype", "AC Analysis", RawFlag::Complex);
        w.add_variable("frequency", "frequency");
        w.add_variable("v(out)", "voltage");
        w.set_complex_columns(
            &[vec![1e3, 1e6], vec![0.8, 0.1]][..],
            &[vec![0.0, 0.0], vec![-0.2, -0.9]][..],
        )
        .unwrap();

        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();
        let text = std::str::from_utf8(&buf).unwrap();
        assert!(text.contains("Values:"));

        let parsed = RawFile::read(&buf[..]).unwrap();
        assert_eq!(parsed.flags, RawFlag::Complex);
        assert_eq!(parsed.num_points(), 2);
        assert!((parsed.real(0, 1) - 0.8).abs() < 1e-12);
        assert!((parsed.imag(0, 1) - (-0.2)).abs() < 1e-12);
        assert!((parsed.real(1, 0) - 1e6).abs() < 1.0); // frequency, loose tol
        assert!((parsed.imag(1, 1) - (-0.9)).abs() < 1e-12);
    }

    #[test]
    fn dc_op_single_point() {
        let mut w = RawfileWriter::new("op", "Operating Point", RawFlag::Real);
        w.add_variable("v(1)", "voltage");
        w.add_variable("v(2)", "voltage");
        w.add_variable("i(v1)", "current");
        w.set_real_columns(&[vec![5.0], vec![2.5], vec![-2.5e-3]][..]).unwrap();
        let mut buf = Vec::new();
        w.write_ascii(&mut buf).unwrap();
        let parsed = RawFile::read(&buf[..]).unwrap();
        assert_eq!(parsed.num_points(), 1);
        assert!((parsed.real(0, 0) - 5.0).abs() < 1e-12);
        assert!((parsed.real(0, 2) - -2.5e-3).abs() < 1e-12);
    }
}
