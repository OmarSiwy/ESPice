//! HSPICE-style aggregated measurement output (`.mt0`).
//!
//! Phase 3.6 produces one `.mt0` file per Monte Carlo or worst-case run.
//! Each row corresponds to one sample / corner; the columns are the union of
//! the measurement names declared by `.MEAS` statements (plus a synthetic
//! `index` column).  The format is the textual ASCII variant.

use std::fmt::Write as _;
use std::fs::File;
use std::io::{self, Write};
use std::path::Path;

/// One row of a `.mt0` file.
#[derive(Debug, Clone)]
pub struct Mt0Row {
    /// Sample / corner index (1-based).
    pub index: u32,
    /// Measurement values, one per declared `.MEAS` name.
    pub values: Vec<f64>,
}

impl Mt0Row {
    pub fn new(index: u32, values: Vec<f64>) -> Self {
        Self { index, values }
    }
}

/// HSPICE `.mt0` ASCII writer.
#[derive(Debug, Clone)]
pub struct Mt0Writer {
    /// Title line.
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

    /// Append a row.
    pub fn push_row(&mut self, mut row: Mt0Row) {
        debug_assert_eq!(
            row.values.len(),
            self.measure_names.len(),
            "Mt0Row value count must match measure_names",
        );
        if row.values.len() < self.measure_names.len() {
            row.values.resize(self.measure_names.len(), f64::NAN);
        } else if row.values.len() > self.measure_names.len() {
            row.values.truncate(self.measure_names.len());
        }
        self.rows.push(row);
    }

    /// Render the file body as a `String`.
    pub fn render(&self) -> String {
        let mut s = String::new();
        let _ = writeln!(s, "$DATA1 SOURCE='incspice-mc' VERSION='1.0'");
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
