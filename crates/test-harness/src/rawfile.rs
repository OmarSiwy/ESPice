use std::path::Path;
use thiserror::Error;

/// Flag indicating whether rawfile data is real or complex.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RawFlag {
    Real,
    Complex,
}

/// A single variable declaration from the rawfile header.
#[derive(Debug, Clone)]
pub struct RawVariable {
    pub index: usize,
    pub name: String,
    pub var_type: String,
}

/// Parsed representation of an ngspice ASCII rawfile.
#[derive(Debug, Clone)]
pub struct RawFile {
    pub title: String,
    pub plotname: String,
    pub flags: RawFlag,
    pub variables: Vec<RawVariable>,
    /// data[point_index][variable_index]
    pub data: Vec<Vec<f64>>,
}

/// Errors that can occur while parsing a rawfile.
#[derive(Debug, Error)]
pub enum RawFileError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("missing required field: {0}")]
    MissingField(String),
    #[error("parse error at line {line}: {msg}")]
    Parse { line: usize, msg: String },
    #[error("no data section found")]
    NoData,
}

impl RawFile {
    /// Parse a rawfile from a string containing the full file content.
    pub fn parse(input: &str) -> Result<Self, RawFileError> {
        // Handle empty/whitespace-only input
        if input.trim().is_empty() {
            return Ok(RawFile {
                title: String::new(),
                plotname: String::new(),
                flags: RawFlag::Real,
                variables: Vec::new(),
                data: Vec::new(),
            });
        }

        let lines: Vec<&str> = input.lines().collect();
        let mut i = 0;

        let mut title: Option<String> = None;
        let mut plotname: Option<String> = None;
        let mut flags: Option<RawFlag> = None;
        let mut num_variables: Option<usize> = None;
        let mut num_points: Option<usize> = None;

        // Parse header fields
        while i < lines.len() {
            let line = lines[i];

            if line == "Variables:" {
                i += 1;
                break;
            }

            if let Some(val) = line.strip_prefix("Title: ") {
                title = Some(val.to_string());
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
                        })
                    }
                });
            } else if let Some(val) = line.strip_prefix("No. Variables: ") {
                num_variables = Some(val.trim().parse::<usize>().map_err(|e| {
                    RawFileError::Parse {
                        line: i + 1,
                        msg: format!("invalid variable count: {e}"),
                    }
                })?);
            } else if let Some(val) = line.strip_prefix("No. Points: ") {
                num_points = Some(val.trim().parse::<usize>().map_err(|e| {
                    RawFileError::Parse {
                        line: i + 1,
                        msg: format!("invalid point count: {e}"),
                    }
                })?);
            }
            // Date: and Command: are parsed but not stored

            i += 1;
        }

        let title = title.ok_or_else(|| RawFileError::MissingField("Title".into()))?;
        let plotname = plotname.ok_or_else(|| RawFileError::MissingField("Plotname".into()))?;
        let flags = flags.ok_or_else(|| RawFileError::MissingField("Flags".into()))?;
        let num_variables =
            num_variables.ok_or_else(|| RawFileError::MissingField("No. Variables".into()))?;
        let num_points =
            num_points.ok_or_else(|| RawFileError::MissingField("No. Points".into()))?;

        // Parse Variables: section
        let mut variables = Vec::with_capacity(num_variables);
        for _ in 0..num_variables {
            if i >= lines.len() {
                return Err(RawFileError::Parse {
                    line: i + 1,
                    msg: "unexpected end of file in Variables section".into(),
                });
            }
            let line = lines[i];
            let parts: Vec<&str> = line.split('\t').collect();
            // Expected format: \t<index>\t<name>\t<type>
            // After split on \t, first element is empty string (leading tab)
            if parts.len() < 4 {
                return Err(RawFileError::Parse {
                    line: i + 1,
                    msg: format!("expected variable definition, got: {line}"),
                });
            }
            let index = parts[1].trim().parse::<usize>().map_err(|e| {
                RawFileError::Parse {
                    line: i + 1,
                    msg: format!("invalid variable index: {e}"),
                }
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

        // Handle 0 points case
        if num_points == 0 {
            return Ok(RawFile {
                title,
                plotname,
                flags,
                variables,
                data: Vec::new(),
            });
        }

        // Find Values: line
        let mut found_values = false;
        while i < lines.len() {
            if lines[i] == "Values:" {
                i += 1;
                found_values = true;
                break;
            }
            i += 1;
        }

        if !found_values {
            return Err(RawFileError::NoData);
        }

        // Parse Values: section
        let mut data: Vec<Vec<f64>> = Vec::with_capacity(num_points);
        let mut current_point: Option<Vec<f64>> = None;

        while i < lines.len() {
            let line = lines[i];

            // Skip empty lines
            if line.trim().is_empty() {
                i += 1;
                continue;
            }

            // Check if this is the start of a new point (starts with space + index + tab)
            if line.starts_with(' ') || line.starts_with(char::is_numeric) {
                // Save previous point if any
                if let Some(point) = current_point.take() {
                    data.push(point);
                }
                // Parse: " <idx>\t<value>"
                let parts: Vec<&str> = line.splitn(2, '\t').collect();
                if parts.len() < 2 {
                    return Err(RawFileError::Parse {
                        line: i + 1,
                        msg: format!("expected point index and value, got: {line}"),
                    });
                }
                let value = parts[1].trim().parse::<f64>().map_err(|e| {
                    RawFileError::Parse {
                        line: i + 1,
                        msg: format!("invalid value: {e}"),
                    }
                })?;
                current_point = Some(vec![value]);
            } else if line.starts_with('\t') {
                // Continuation value for current point: "\t<value>"
                let value = line.trim().parse::<f64>().map_err(|e| {
                    RawFileError::Parse {
                        line: i + 1,
                        msg: format!("invalid value: {e}"),
                    }
                })?;
                match current_point.as_mut() {
                    Some(point) => point.push(value),
                    None => {
                        return Err(RawFileError::Parse {
                            line: i + 1,
                            msg: "value without preceding point index".into(),
                        })
                    }
                }
            }

            i += 1;
        }

        // Don't forget the last point
        if let Some(point) = current_point.take() {
            data.push(point);
        }

        Ok(RawFile {
            title,
            plotname,
            flags,
            variables,
            data,
        })
    }

    /// Parse a rawfile from a file on disk.
    pub fn parse_file(path: &Path) -> Result<Self, RawFileError> {
        let content = std::fs::read_to_string(path)?;
        Self::parse(&content)
    }

    /// Extract (name, value) pairs from a single-point result (DC OP).
    pub fn as_dc_pairs(&self) -> Vec<(String, f64)> {
        if self.data.is_empty() {
            return Vec::new();
        }
        self.variables
            .iter()
            .zip(self.data[0].iter())
            .map(|(var, val)| (var.name.clone(), *val))
            .collect()
    }

    /// Extract (sweep_column, signal_names, data_matrix) for waveform results.
    /// First variable is treated as the sweep/time column.
    pub fn as_waveform(&self) -> (Vec<f64>, Vec<String>, Vec<Vec<f64>>) {
        let sweep: Vec<f64> = self.data.iter().map(|row| row[0]).collect();
        let names: Vec<String> = self.variables.iter().skip(1).map(|v| v.name.clone()).collect();
        let data: Vec<Vec<f64>> = self.data.iter().map(|row| row[1..].to_vec()).collect();
        (sweep, names, data)
    }

    /// Get all values for a named variable across all points.
    pub fn variable_by_name(&self, name: &str) -> Option<Vec<f64>> {
        let idx = self.variables.iter().position(|v| v.name == name)?;
        Some(self.data.iter().map(|row| row[idx]).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DC_OP_RAW: &str = "\
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

    const TRAN_RAW: &str = "\
Title: * rc transient
Date: Sun Apr  5 16:30:31  2026
Command: ngspice-44.2
Plotname: Transient Analysis
Flags: real
No. Variables: 3
No. Points: 3
Variables:
\t0\ttime\ttime
\t1\tv(1)\tvoltage
\t2\tv(2)\tvoltage
Values:
 0\t0.000000000000000e+00
\t5.000000000000000e+00
\t0.000000000000000e+00
 1\t5.000000000000000e-07
\t5.000000000000000e+00
\t3.934693402873666e+00
 2\t1.000000000000000e-06
\t5.000000000000000e+00
\t4.323323583816936e+00
";

    #[test]
    fn parse_dc_op_rawfile() {
        let raw = RawFile::parse(DC_OP_RAW).unwrap();
        assert_eq!(raw.title, "* voltage divider test");
        assert_eq!(raw.plotname, "Operating Point");
        assert!(matches!(raw.flags, RawFlag::Real));
        assert_eq!(raw.variables.len(), 3);
        assert_eq!(raw.variables[0].name, "v(1)");
        assert_eq!(raw.variables[0].var_type, "voltage");
        assert_eq!(raw.variables[2].name, "i(v1)");
        assert_eq!(raw.variables[2].var_type, "current");
        assert_eq!(raw.data.len(), 1);
        assert!((raw.data[0][0] - 5.0).abs() < 1e-12);
        assert!((raw.data[0][1] - 2.5).abs() < 1e-12);
        assert!((raw.data[0][2] + 0.0025).abs() < 1e-12);
    }

    #[test]
    fn parse_transient_rawfile() {
        let raw = RawFile::parse(TRAN_RAW).unwrap();
        assert_eq!(raw.plotname, "Transient Analysis");
        assert_eq!(raw.variables.len(), 3);
        assert_eq!(raw.data.len(), 3);
        assert!((raw.data[0][0] - 0.0).abs() < 1e-15);
        assert!((raw.data[1][0] - 5e-7).abs() < 1e-15);
        assert!((raw.data[2][2] - 4.323323583816936).abs() < 1e-12);
    }

    #[test]
    fn rawfile_as_dc_pairs() {
        let raw = RawFile::parse(DC_OP_RAW).unwrap();
        let pairs = raw.as_dc_pairs();
        assert_eq!(pairs.len(), 3);
        assert_eq!(pairs[0].0, "v(1)");
        assert!((pairs[0].1 - 5.0).abs() < 1e-12);
        assert_eq!(pairs[1].0, "v(2)");
        assert!((pairs[1].1 - 2.5).abs() < 1e-12);
        assert_eq!(pairs[2].0, "i(v1)");
        assert!((pairs[2].1 + 0.0025).abs() < 1e-12);
    }

    #[test]
    fn rawfile_as_waveform() {
        let raw = RawFile::parse(TRAN_RAW).unwrap();
        let (sweep, names, data) = raw.as_waveform();
        assert_eq!(sweep.len(), 3);
        assert!((sweep[0] - 0.0).abs() < 1e-15);
        assert!((sweep[1] - 5e-7).abs() < 1e-15);
        assert_eq!(names, vec!["v(1)", "v(2)"]);
        assert_eq!(data.len(), 3);
        assert!((data[0][0] - 5.0).abs() < 1e-12);
    }

    #[test]
    fn rawfile_variable_by_name() {
        let raw = RawFile::parse(TRAN_RAW).unwrap();
        let v2 = raw.variable_by_name("v(2)").unwrap();
        assert_eq!(v2.len(), 3);
        assert!((v2[0] - 0.0).abs() < 1e-12);
        assert!((v2[1] - 3.934693402873666).abs() < 1e-12);
    }

    #[test]
    fn rawfile_variable_by_name_missing() {
        let raw = RawFile::parse(DC_OP_RAW).unwrap();
        assert!(raw.variable_by_name("v(nonexistent)").is_none());
    }

    #[test]
    fn parse_empty_input() {
        let result = RawFile::parse("");
        assert!(result.is_ok());
        let raw = result.unwrap();
        assert!(raw.data.is_empty());
    }

    #[test]
    fn parse_missing_values_section() {
        let input = "\
Title: test
Plotname: Operating Point
Flags: real
No. Variables: 1
No. Points: 1
Variables:
\t0\tv(1)\tvoltage
";
        let result = RawFile::parse(input);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("no data") || err.to_string().contains("NoData"), "got: {err}");
    }

    #[test]
    fn parse_complex_flag() {
        let input = "\
Title: ac test
Plotname: AC Analysis
Flags: complex
No. Variables: 1
No. Points: 0
Variables:
\t0\tv(1)\tvoltage
";
        let raw = RawFile::parse(input).unwrap();
        assert_eq!(raw.flags, RawFlag::Complex);
    }

    #[test]
    fn parse_file_not_found() {
        let result = RawFile::parse_file(Path::new("/nonexistent/path.raw"));
        assert!(result.is_err());
    }
}
