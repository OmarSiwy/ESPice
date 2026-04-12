#![allow(dead_code)]
//! Xyce test utilities — spawn Xyce, parse .prn DC results.
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone)]
pub struct XyceConfig {
    pub binary: String,
}

impl Default for XyceConfig {
    fn default() -> Self {
        Self { binary: std::env::var("XYCE_BIN").unwrap_or_else(|_| "Xyce".into()) }
    }
}

#[derive(Debug)]
pub enum XyceError {
    NotFound,
    ProcessFailed(String),
    ParseError(String),
}

impl std::fmt::Display for XyceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            XyceError::NotFound => write!(f, "Xyce not found on PATH"),
            XyceError::ProcessFailed(s) => write!(f, "Xyce failed: {s}"),
            XyceError::ParseError(s) => write!(f, "Xyce parse error: {s}"),
        }
    }
}

#[derive(Debug, Default)]
pub struct XyceResult {
    pub node_voltages: Vec<(String, f64)>,
}

impl XyceConfig {
    pub fn is_available(&self) -> bool {
        Command::new(&self.binary)
            .arg("-v")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok()
    }

    pub fn run(&self, netlist_path: &Path) -> Result<XyceResult, XyceError> {
        let out = Command::new(&self.binary)
            .arg(netlist_path)
            .output()
            .map_err(|_| XyceError::NotFound)?;
        if !out.status.success() {
            return Err(XyceError::ProcessFailed(
                String::from_utf8_lossy(&out.stderr).into_owned(),
            ));
        }
        let prn_path = netlist_path.with_extension("prn");
        let node_voltages = if prn_path.exists() {
            let content = std::fs::read_to_string(&prn_path)
                .map_err(|e| XyceError::ParseError(e.to_string()))?;
            parse_xyce_prn(&content)
        } else {
            parse_xyce_prn(&String::from_utf8_lossy(&out.stdout))
        };
        Ok(XyceResult { node_voltages })
    }
}

fn parse_xyce_prn(content: &str) -> Vec<(String, f64)> {
    let mut lines = content.lines().filter(|l| !l.trim().is_empty());
    let header = loop {
        match lines.next() {
            None => return Vec::new(),
            Some(l) if l.trim_start().starts_with("Index") || l.contains("V(") => break l,
            _ => continue,
        }
    };
    let cols: Vec<&str> = header.split_whitespace().collect();
    let last = lines
        .filter(|l| l.trim_start().chars().next().map_or(false, |c| c.is_ascii_digit()))
        .last();
    let Some(row) = last else { return Vec::new() };
    let vals: Vec<&str> = row.split_whitespace().collect();
    cols.iter().zip(vals.iter())
        .filter_map(|(name, val)| {
            let lower = name.to_lowercase();
            if lower.starts_with("v(") {
                let node = name.trim_start_matches("V(").trim_start_matches("v(").trim_end_matches(')');
                val.parse::<f64>().ok().map(|v| (node.to_owned(), v))
            } else {
                None
            }
        })
        .collect()
}
