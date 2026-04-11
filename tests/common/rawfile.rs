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

            if line.trim().is_empty() {
                i += 1;
                continue;
            }

            if line.starts_with(' ') || line.starts_with(char::is_numeric) {
                if let Some(point) = current_point.take() {
                    data.push(point);
                }
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
