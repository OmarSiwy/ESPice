//! HSPICE-style aggregated measurement output (`.mt0`).
//!
//! Phase 3.6 produces one `.mt0` file per Monte Carlo or worst-case run.
//! Each row corresponds to one sample / corner; the columns are the union of
//! the measurement names declared by `.MEAS` statements (plus a synthetic
//! `index` column).  The format is the textual ASCII variant — every modern
//! waveform viewer (gaw, CosmosScope, WaveView) reads it.
//!
//! Format (matches HSPICE `.mt0` ASCII):
//!
//! ```text
//! $DATA1 SOURCE='pisim-mc' VERSION='1.0'
//! .TITLE 'monte_carlo'
//! index   m1      m2      m3
//!   1     ...     ...     ...
//!   2     ...     ...     ...
//! ```
//!
//! Failed measurements are emitted as `nan` so the row count always matches.

use std::fmt::Write as _;
use std::fs::File;
use std::io::{self, Write};
use std::path::Path;

/// One row of a `.mt0` file.
///
/// The values vector must be the same length as the writer's column header
/// vector, in the same order.  Use `f64::NAN` for measurements that failed
/// for that particular sample / corner.
#[derive(Debug, Clone)]
pub struct Mt0Row {
    /// Sample / corner index (1-based, matching ngspice/hspice convention).
    pub index: u32,
    /// Measurement values, one per declared `.MEAS` name.
    pub values: Vec<f64>,
}

impl Mt0Row {
    pub fn new(index: u32, values: Vec<f64>) -> Self {
        Self { index, values }
    }
}

/// HSPICE `.mt0` ASCII writer — accumulates rows in memory then renders to a
/// `String` or writes them to a `Path`.
#[derive(Debug, Clone)]
pub struct Mt0Writer {
    /// Title line — user-supplied (typically the analysis kind, e.g. `"mc"`).
    pub title: String,
    /// Column names (the order in which row values are stored).
    pub measure_names: Vec<String>,
    /// Accumulated rows.
    pub rows: Vec<Mt0Row>,
}

impl Mt0Writer {
    /// Create an empty writer with a title and an ordered list of measurement
    /// column names.
    pub fn new(title: impl Into<String>, measure_names: Vec<String>) -> Self {
        Self {
            title: title.into(),
            measure_names,
            rows: Vec::new(),
        }
    }

    /// Append a row.  The row's `values.len()` must equal `measure_names.len()`
    /// — otherwise the writer panics in debug builds and silently truncates /
    /// pads with NaN in release builds.
    pub fn push_row(&mut self, mut row: Mt0Row) {
        debug_assert_eq!(
            row.values.len(),
            self.measure_names.len(),
            "Mt0Row value count must match measure_names",
        );
        if row.values.len() < self.measure_names.len() {
            row.values
                .resize(self.measure_names.len(), f64::NAN);
        } else if row.values.len() > self.measure_names.len() {
            row.values.truncate(self.measure_names.len());
        }
        self.rows.push(row);
    }

    /// Render the file body as a `String`.
    pub fn render(&self) -> String {
        let mut s = String::new();
        let _ = writeln!(s, "$DATA1 SOURCE='pisim-mc' VERSION='1.0'");
        let _ = writeln!(s, ".TITLE '{}'", self.title);

        // Header row: index + measure names.
        let _ = write!(s, "{:>8}", "index");
        for name in &self.measure_names {
            let _ = write!(s, " {:>14}", name);
        }
        s.push('\n');

        // Data rows.
        for row in &self.rows {
            let _ = write!(s, "{:>8}", row.index);
            for &v in &row.values {
                if v.is_nan() {
                    let _ = write!(s, " {:>14}", "nan");
                } else {
                    // Use scientific with 6 sig figs to match HSPICE column width.
                    let _ = write!(s, " {:>14.6e}", v);
                }
            }
            s.push('\n');
        }

        s
    }

    /// Write the rendered file to `path`, overwriting any existing file.
    pub fn write_to_path(&self, path: &Path) -> io::Result<()> {
        let mut f = File::create(path)?;
        f.write_all(self.render().as_bytes())
    }

    /// Number of rows accumulated so far.
    pub fn len(&self) -> usize {
        self.rows.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_writer_renders_only_header() {
        let w = Mt0Writer::new("mc", vec!["m1".into(), "m2".into()]);
        let body = w.render();
        assert!(body.contains("$DATA1"));
        assert!(body.contains(".TITLE 'mc'"));
        assert!(body.contains("index"));
        assert!(body.contains("m1"));
        assert!(body.contains("m2"));
    }

    #[test]
    fn rows_render_with_scientific_notation() {
        let mut w = Mt0Writer::new("mc", vec!["v_out".into()]);
        w.push_row(Mt0Row::new(1, vec![2.5]));
        w.push_row(Mt0Row::new(2, vec![3.1415]));
        let body = w.render();
        let lines: Vec<&str> = body.lines().collect();
        // Header is the third non-comment line; data rows follow.
        assert_eq!(w.len(), 2);
        assert!(lines.iter().any(|l| l.contains("2.500000e0")));
        assert!(lines.iter().any(|l| l.contains("3.141500e0")));
    }

    #[test]
    fn nan_renders_as_nan() {
        let mut w = Mt0Writer::new("wcase", vec!["m".into()]);
        w.push_row(Mt0Row::new(1, vec![f64::NAN]));
        let body = w.render();
        assert!(body.contains("nan"));
    }

    #[test]
    fn write_to_path_creates_file() {
        let dir = std::env::temp_dir();
        let path = dir.join("pisim_mt0_test.mt0");
        let mut w = Mt0Writer::new("mc", vec!["a".into(), "b".into()]);
        w.push_row(Mt0Row::new(1, vec![1.0, 2.0]));
        w.write_to_path(&path).unwrap();
        let read_back = std::fs::read_to_string(&path).unwrap();
        assert!(read_back.contains("$DATA1"));
        assert!(read_back.contains("1.000000e0"));
        let _ = std::fs::remove_file(&path);
    }
}
