//! Generic CSV writer with user-selectable columns.
//!
//! Supports any delimiter (comma by default), optional unit-row, optional
//! quoted-string headers, and configurable numeric precision.  Like the rest
//! of the io module, the writer takes column-major data (`&[Vec<f64>]`) so it
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

// ---------------------------------------------------------------------------
// Unit tests (TODO §15)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn write_to_string(w: &CsvWriter) -> String {
        let mut buf = Vec::new();
        w.write(&mut buf).expect("write should succeed");
        String::from_utf8(buf).expect("valid UTF-8")
    }

    #[test]
    fn test_csv_writer_headers() {
        let mut w = CsvWriter::new();
        w.set_headers(&["time", "V(1)", "V(2)"]);
        w.set_columns(&[vec![0.0], vec![1.0], vec![2.0]]).unwrap();
        let out = write_to_string(&w);
        let mut lines = out.lines();
        let header_line = lines.next().expect("should have a header line");
        assert_eq!(header_line, "time,V(1),V(2)", "header row mismatch");
    }

    #[test]
    fn test_csv_writer_single_point() {
        // One data row, two columns.
        let mut w = CsvWriter::new();
        w.set_headers(&["x", "y"]);
        w.set_columns(&[vec![1.0], vec![2.5]]).unwrap();
        let out = write_to_string(&w);
        let lines: Vec<&str> = out.lines().collect();
        // Line 0 = header, line 1 = data row.
        assert_eq!(lines.len(), 2, "expected header + 1 data row");
        // Both numbers should appear in the data row.
        assert!(lines[1].contains("1.0") || lines[1].contains("1e") || lines[1].contains("1.000"),
            "x value should appear in data row: {}", lines[1]);
        // Verify delimiter is present.
        assert!(lines[1].contains(','), "data row should contain comma delimiter");
    }

    #[test]
    fn test_csv_writer_multiple_points() {
        let mut w = CsvWriter::new();
        w.set_headers(&["t", "v"]);
        let t_col: Vec<f64> = (0..5).map(|i| i as f64 * 1e-6).collect();
        let v_col: Vec<f64> = (0..5).map(|i| i as f64 * 1.0).collect();
        w.set_columns(&[t_col, v_col]).unwrap();
        let out = write_to_string(&w);
        let lines: Vec<&str> = out.lines().collect();
        // header + 5 data rows = 6 lines.
        assert_eq!(lines.len(), 6, "expected header + 5 data rows, got {} lines", lines.len());
        // Each data row should contain a comma.
        for line in &lines[1..] {
            assert!(line.contains(','), "data row missing comma: {line}");
        }
    }

    #[test]
    fn test_csv_writer_column_mismatch_error() {
        // set_columns with a different count than headers should return an error.
        let mut w = CsvWriter::new();
        w.set_headers(&["a", "b", "c"]);
        let result = w.set_columns(&[vec![1.0], vec![2.0]]); // only 2 columns for 3 headers
        assert!(result.is_err(), "mismatched column count should return error");
        match result.unwrap_err() {
            CsvError::ColumnMismatch { headers, columns } => {
                assert_eq!(headers, 3);
                assert_eq!(columns, 2);
            }
            e => panic!("unexpected error variant: {e}"),
        }
    }

    #[test]
    fn test_csv_writer_units_row() {
        let mut w = CsvWriter::new();
        w.set_headers(&["time", "voltage"]);
        w.set_units(&["s", "V"]);
        w.set_columns(&[vec![0.0, 1.0], vec![5.0, 3.0]]).unwrap();
        let out = write_to_string(&w);
        let lines: Vec<&str> = out.lines().collect();
        // header + units + 2 data rows = 4 lines.
        assert_eq!(lines.len(), 4, "expected header+units+2 data rows");
        assert_eq!(lines[1], "s,V", "units row should be second line");
    }

    #[test]
    fn test_csv_writer_custom_delimiter() {
        let mut w = CsvWriter::new().with_delimiter('\t');
        w.set_headers(&["a", "b"]);
        w.set_columns(&[vec![1.0], vec![2.0]]).unwrap();
        let out = write_to_string(&w);
        let lines: Vec<&str> = out.lines().collect();
        assert!(lines[0].contains('\t'), "header should use tab delimiter");
        assert!(lines[1].contains('\t'), "data should use tab delimiter");
    }
}
