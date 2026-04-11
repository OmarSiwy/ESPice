use csv::ReaderBuilder;
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum GoldenError {
    #[error("CSV read error: {0}")]
    Csv(#[from] csv::Error),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("no data columns in golden file")]
    Empty,
}

#[derive(Debug, Clone)]
pub struct GoldenData {
    pub headers: Vec<String>,
    pub rows: Vec<Vec<f64>>,
}

impl GoldenData {
    pub fn from_csv(path: &Path) -> Result<Self, GoldenError> {
        let mut rdr = ReaderBuilder::new()
            .has_headers(true)
            .flexible(true)
            .trim(csv::Trim::All)
            .from_path(path)?;

        let headers: Vec<String> = rdr.headers()?.iter().map(|s| s.to_string()).collect();
        if headers.is_empty() {
            return Err(GoldenError::Empty);
        }

        let mut rows = Vec::new();
        for record in rdr.records() {
            let record = record?;
            let row: Vec<f64> = record
                .iter()
                .map(|s| s.trim().parse::<f64>().unwrap_or(f64::NAN))
                .collect();
            rows.push(row);
        }

        Ok(GoldenData { headers, rows })
    }

    pub fn as_dc_pairs(&self) -> Vec<(String, f64)> {
        if self.rows.is_empty() {
            return Vec::new();
        }
        self.headers
            .iter()
            .zip(self.rows[0].iter())
            .map(|(name, val)| (name.clone(), *val))
            .collect()
    }

    pub fn as_waveform(&self) -> (Vec<f64>, Vec<String>, Vec<Vec<f64>>) {
        let sweep_col: Vec<f64> = self.rows.iter().map(|r| r.get(0).copied().unwrap_or(0.0)).collect();
        let signal_names: Vec<String> = self.headers.iter().skip(1).cloned().collect();
        let data: Vec<Vec<f64>> = self.rows.iter().map(|r| r[1..].to_vec()).collect();
        (sweep_col, signal_names, data)
    }

    pub fn write_csv(&self, path: &Path) -> Result<(), GoldenError> {
        let mut wtr = csv::WriterBuilder::new().from_path(path)?;
        wtr.write_record(&self.headers)?;
        for row in &self.rows {
            let fields: Vec<String> = row.iter().map(|v| format!("{v:.15e}")).collect();
            wtr.write_record(&fields)?;
        }
        wtr.flush()?;
        Ok(())
    }

    pub fn from_rawfile(raw: &super::rawfile::RawFile) -> Self {
        let headers: Vec<String> = raw.variables.iter().map(|v| v.name.clone()).collect();
        let rows: Vec<Vec<f64>> = raw.data.clone();
        GoldenData { headers, rows }
    }
}
