//! Multi-simulator subprocess runner for head-to-head benchmarks.

use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

/// Result of running a single simulator invocation.
pub struct SimRun {
    pub duration: Duration,
    pub success: bool,
    pub stderr: String,
}

/// Lightweight benchmark runner that wraps bigospice analysis calls.
pub struct BenchRunner;

impl BenchRunner {
    /// Run ngspice in batch mode on a netlist file, returning wall time.
    pub fn time_ngspice(netlist_path: &Path) -> Option<SimRun> {
        let binary = std::env::var("NGSPICE_BIN").unwrap_or_else(|_| "ngspice".into());
        let tmp = tempfile::tempdir().ok()?;
        let raw_out = tmp.path().join("output.raw");
        let content = std::fs::read_to_string(netlist_path).ok()?;
        let wrapper = tmp.path().join("wrapper.cir");
        std::fs::write(
            &wrapper,
            format!(
                ".include {}\n.control\nset filetype=ascii\nrun\nwrite {} all\n.endc\n",
                netlist_path.display(),
                raw_out.display(),
            ),
        ).ok()?;

        let start = Instant::now();
        let output = Command::new(&binary)
            .arg("-b")
            .arg(&wrapper)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .spawn().ok()?
            .wait_with_output().ok()?;
        let duration = start.elapsed();
        let _ = content; // silence unused warning

        Some(SimRun {
            duration,
            success: output.status.success(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        })
    }

    /// Check whether ngspice is available on PATH.
    pub fn ngspice_available() -> bool {
        let binary = std::env::var("NGSPICE_BIN").unwrap_or_else(|_| "ngspice".into());
        Command::new(&binary)
            .arg("--version")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok()
    }
}
