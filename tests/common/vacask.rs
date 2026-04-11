//! VACASK test utilities — spawn vacask, capture output, parse DC results.
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone)]
pub struct VacaskConfig {
    pub binary: String,
}

impl Default for VacaskConfig {
    fn default() -> Self {
        Self { binary: std::env::var("VACASK_BIN").unwrap_or_else(|_| "vacask".into()) }
    }
}

#[derive(Debug)]
pub enum VacaskError {
    NotFound,
    ProcessFailed(String),
}

impl std::fmt::Display for VacaskError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VacaskError::NotFound => write!(f, "vacask not found on PATH"),
            VacaskError::ProcessFailed(s) => write!(f, "vacask failed: {s}"),
        }
    }
}

#[derive(Debug, Default)]
pub struct VacaskResult {
    pub node_voltages: Vec<(String, f64)>,
}

impl VacaskConfig {
    pub fn is_available(&self) -> bool {
        Command::new(&self.binary)
            .arg("--version")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok()
    }

    pub fn run(&self, netlist_path: &Path) -> Result<VacaskResult, VacaskError> {
        let out = Command::new(&self.binary)
            .arg(netlist_path)
            .output()
            .map_err(|_| VacaskError::NotFound)?;
        if !out.status.success() {
            return Err(VacaskError::ProcessFailed(
                String::from_utf8_lossy(&out.stderr).into_owned(),
            ));
        }
        let stdout = String::from_utf8_lossy(&out.stdout);
        let node_voltages = parse_vacask_dc(&stdout);
        Ok(VacaskResult { node_voltages })
    }
}

fn parse_vacask_dc(output: &str) -> Vec<(String, f64)> {
    let mut pairs = Vec::new();
    for line in output.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("Node ") {
            if let Some((name, val)) = rest.split_once(':') {
                let val = val.trim().trim_end_matches('V').trim();
                if let Ok(v) = val.parse::<f64>() {
                    pairs.push((name.trim().to_owned(), v));
                }
            }
        } else if let Some(rest) = line.strip_prefix("V(") {
            if let Some((name, rest2)) = rest.split_once(')') {
                if let Some(val) = rest2.trim().strip_prefix('=') {
                    if let Ok(v) = val.trim().parse::<f64>() {
                        pairs.push((name.to_owned(), v));
                    }
                }
            }
        }
    }
    pairs
}
