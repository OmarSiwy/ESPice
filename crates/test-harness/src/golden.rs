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

    pub fn from_rawfile(raw: &crate::rawfile::RawFile) -> Self {
        let headers: Vec<String> = raw.variables.iter().map(|v| v.name.clone()).collect();
        let rows: Vec<Vec<f64>> = raw.data.clone();
        GoldenData { headers, rows }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn load_dc_golden_csv() {
        let dir = std::env::temp_dir().join("pisim_test_golden");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("dc_test.csv");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "V(1),V(2),I(V1)").unwrap();
        writeln!(f, "5.0,2.5,-0.0025").unwrap();
        drop(f);

        let golden = GoldenData::from_csv(&path).unwrap();
        assert_eq!(golden.headers, vec!["V(1)", "V(2)", "I(V1)"]);
        assert_eq!(golden.rows.len(), 1);

        let pairs = golden.as_dc_pairs();
        assert_eq!(pairs.len(), 3);
        assert!((pairs[0].1 - 5.0).abs() < 1e-12);
        assert!((pairs[1].1 - 2.5).abs() < 1e-12);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn write_and_read_golden_csv() {
        let dir = std::env::temp_dir().join("pisim_test_golden_write");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("write_test.csv");

        let golden = GoldenData {
            headers: vec!["V(1)".into(), "V(2)".into(), "I(V1)".into()],
            rows: vec![vec![5.0, 2.5, -0.0025]],
        };
        golden.write_csv(&path).unwrap();

        // Read it back and verify roundtrip
        let loaded = GoldenData::from_csv(&path).unwrap();
        assert_eq!(loaded.headers, golden.headers);
        assert_eq!(loaded.rows.len(), 1);
        assert!((loaded.rows[0][0] - 5.0).abs() < 1e-12);
        assert!((loaded.rows[0][1] - 2.5).abs() < 1e-12);
        assert!((loaded.rows[0][2] + 0.0025).abs() < 1e-12);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn rawfile_to_golden_conversion() {
        use crate::rawfile::RawFile;

        let raw_input = "\
Title: * voltage divider test
Date: Sun Apr  5 16:30:31  2026
Command: ngspice-44.2
Plotname: Operating Point
Flags: real
No. Variables: 3
No. Points: 1
Variables:
\t0\tv(1)\tvoltage
\t1\tv(2)\tvoltage
\t2\ti(v1)\tcurrent
Values:
 0\t5.000000000000000e+00
\t2.500000000000000e+00
\t-2.500000000000000e-03
";
        let raw = RawFile::parse(raw_input).unwrap();
        let golden = GoldenData::from_rawfile(&raw);

        assert_eq!(golden.headers, vec!["v(1)", "v(2)", "i(v1)"]);
        assert_eq!(golden.rows.len(), 1);
        assert!((golden.rows[0][0] - 5.0).abs() < 1e-12);
        assert!((golden.rows[0][2] + 0.0025).abs() < 1e-12);
    }
}
