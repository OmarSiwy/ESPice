//! Generic CSV writer with user-selectable columns.
//!
//! Supports any delimiter (comma by default), optional unit-row, optional
//! quoted-string headers, and configurable numeric precision.  Like the rest
//! of the io crate, the writer takes column-major data (`&[Vec<f64>]`) so it
//! plugs straight into SoA result containers.

use std::io::{self, Write};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CsvError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("column count mismatch: header has {headers}, data has {columns}")]
    ColumnMismatch { headers: usize, columns: usize },
    #[error("column lengths differ: column 0 has {first}, column {i} has {got}")]
    RowLengthMismatch { i: usize, first: usize, got: usize },
}

/// CSV writer.  Caller supplies header names and one `Vec<f64>` per column.
///
/// # Example
/// ```
/// use pisim_io::csv::CsvWriter;
/// let mut buf = Vec::<u8>::new();
/// let mut w = CsvWriter::new();
/// w.set_headers(&["time", "v(out)"]);
/// w.set_columns(&[
///     vec![0.0, 1e-6, 2e-6],
///     vec![0.0, 0.63, 0.86],
/// ]).unwrap();
/// w.write(&mut buf).unwrap();
/// let s = std::str::from_utf8(&buf).unwrap();
/// assert!(s.starts_with("time,v(out)"));
/// ```
pub struct CsvWriter {
    delimiter: char,
    precision: usize,
    headers: Vec<String>,
    units: Option<Vec<String>>,
    columns: Vec<Vec<f64>>,
}

impl Default for CsvWriter {
    fn default() -> Self {
        Self::new()
    }
}

impl CsvWriter {
    pub fn new() -> Self {
        Self {
            delimiter: ',',
            precision: 9,
            headers: Vec::new(),
            units: None,
            columns: Vec::new(),
        }
    }

    pub fn with_delimiter(mut self, delim: char) -> Self {
        self.delimiter = delim;
        self
    }

    pub fn with_precision(mut self, n: usize) -> Self {
        self.precision = n;
        self
    }

    pub fn set_headers(&mut self, names: &[&str]) {
        self.headers = names.iter().map(|s| (*s).to_string()).collect();
    }

    /// Optional second header row of units (e.g. `"s"`, `"V"`).
    pub fn set_units(&mut self, units: &[&str]) {
        self.units = Some(units.iter().map(|s| (*s).to_string()).collect());
    }

    /// Provide one `Vec<f64>` per column.  All columns must be the same length.
    pub fn set_columns(&mut self, cols: &[Vec<f64>]) -> Result<(), CsvError> {
        if !self.headers.is_empty() && cols.len() != self.headers.len() {
            return Err(CsvError::ColumnMismatch {
                headers: self.headers.len(),
                columns: cols.len(),
            });
        }
        if let Some(first) = cols.first() {
            let n = first.len();
            for (i, col) in cols.iter().enumerate() {
                if col.len() != n {
                    return Err(CsvError::RowLengthMismatch {
                        i,
                        first: n,
                        got: col.len(),
                    });
                }
            }
        }
        self.columns = cols.to_vec();
        Ok(())
    }

    /// Write the CSV stream.
    pub fn write<W: Write>(&self, mut w: W) -> Result<(), CsvError> {
        let delim = self.delimiter;

        // Header row.
        if !self.headers.is_empty() {
            for (i, h) in self.headers.iter().enumerate() {
                if i > 0 {
                    write!(w, "{delim}")?;
                }
                write!(w, "{}", quote_if_needed(h, delim))?;
            }
            writeln!(w)?;
        }

        // Optional units row.
        if let Some(units) = &self.units {
            for (i, u) in units.iter().enumerate() {
                if i > 0 {
                    write!(w, "{delim}")?;
                }
                write!(w, "{}", quote_if_needed(u, delim))?;
            }
            writeln!(w)?;
        }

        // Data rows: column-major source -> row-major output.
        let n_rows = self.columns.first().map(|c| c.len()).unwrap_or(0);
        let n_cols = self.columns.len();
        for r in 0..n_rows {
            for c in 0..n_cols {
                if c > 0 {
                    write!(w, "{delim}")?;
                }
                write!(w, "{:.*e}", self.precision, self.columns[c][r])?;
            }
            writeln!(w)?;
        }
        Ok(())
    }
}

/// Quote a header field if it contains the delimiter, a quote, or whitespace
/// that would confuse a downstream parser.  Doubles internal quotes per
/// RFC 4180.
fn quote_if_needed(s: &str, delim: char) -> String {
    let needs = s.chars().any(|c| c == delim || c == '"' || c == '\n');
    if needs {
        let escaped = s.replace('"', "\"\"");
        format!("\"{escaped}\"")
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_headers_and_rows() {
        let mut w = CsvWriter::new();
        w.set_headers(&["time", "v(out)", "i(v1)"]);
        w.set_columns(&[
            vec![0.0, 1e-6, 2e-6],
            vec![0.0, 0.63, 0.86],
            vec![1e-3, 0.9e-3, 0.6e-3],
        ])
        .unwrap();
        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();
        let s = String::from_utf8(buf).unwrap();
        let lines: Vec<&str> = s.lines().collect();
        assert_eq!(lines[0], "time,v(out),i(v1)");
        assert_eq!(lines.len(), 4); // header + 3 rows
    }

    #[test]
    fn quotes_special_characters() {
        let q = quote_if_needed("v(out, x)", ',');
        assert_eq!(q, "\"v(out, x)\"");
        let q = quote_if_needed("plain", ',');
        assert_eq!(q, "plain");
        let q = quote_if_needed("a\"b", ',');
        assert_eq!(q, "\"a\"\"b\"");
    }

    #[test]
    fn custom_delimiter_and_precision() {
        let mut w = CsvWriter::new().with_delimiter('\t').with_precision(3);
        w.set_headers(&["t", "y"]);
        w.set_columns(&[vec![1.0], vec![3.14159]]).unwrap();
        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();
        let s = String::from_utf8(buf).unwrap();
        assert!(s.contains("t\ty"));
        assert!(s.contains("3.142e0") || s.contains("3.142e00"));
    }

    #[test]
    fn column_count_mismatch_errors() {
        let mut w = CsvWriter::new();
        w.set_headers(&["a", "b"]);
        let err = w.set_columns(&[vec![1.0]]).unwrap_err();
        assert!(matches!(err, CsvError::ColumnMismatch { .. }));
    }

    #[test]
    fn row_length_mismatch_errors() {
        let mut w = CsvWriter::new();
        w.set_headers(&["a", "b"]);
        let err = w
            .set_columns(&[vec![1.0, 2.0], vec![3.0]])
            .unwrap_err();
        assert!(matches!(err, CsvError::RowLengthMismatch { .. }));
    }

    #[test]
    fn units_row() {
        let mut w = CsvWriter::new();
        w.set_headers(&["time", "v(out)"]);
        w.set_units(&["s", "V"]);
        w.set_columns(&[vec![0.0, 1e-6], vec![0.0, 0.63]]).unwrap();
        let mut buf = Vec::new();
        w.write(&mut buf).unwrap();
        let s = String::from_utf8(buf).unwrap();
        let lines: Vec<&str> = s.lines().collect();
        assert_eq!(lines[0], "time,v(out)");
        assert_eq!(lines[1], "s,V");
    }
}
