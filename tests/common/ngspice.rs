#![allow(dead_code)]
use super::rawfile::{RawFile, RawFileError};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum NgspiceError {
    #[error("ngspice binary not found: {0}")]
    NotFound(String),
    #[error("ngspice process timed out after {0:?}")]
    Timeout(Duration),
    #[error("ngspice exited with code {code}: {stderr}")]
    NonZeroExit { code: i32, stderr: String },
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("rawfile parse error: {0}")]
    RawFile(#[from] RawFileError),
    #[error("no rawfile produced by ngspice")]
    NoOutput,
}

#[derive(Debug, Clone)]
pub struct NgspiceConfig {
    pub binary: PathBuf,
    pub timeout: Duration,
    pub extra_args: Vec<String>,
}

impl Default for NgspiceConfig {
    fn default() -> Self {
        let binary = std::env::var("NGSPICE_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("ngspice"));
        Self {
            binary,
            timeout: Duration::from_secs(60),
            extra_args: Vec::new(),
        }
    }
}

#[derive(Debug)]
pub struct NgspiceResult {
    pub rawfile: RawFile,
    pub wall_time: Duration,
    pub stderr: String,
    pub exit_code: i32,
}

impl NgspiceConfig {
    /// Check if ngspice is available by running `ngspice --version`.
    pub fn is_available(&self) -> bool {
        Command::new(&self.binary)
            .arg("--version")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok()
    }

    /// Run ngspice in batch mode on the given netlist.
    pub fn run(&self, netlist_path: &Path) -> Result<NgspiceResult, NgspiceError> {
        let netlist_path = netlist_path.canonicalize()?;
        let tmp_dir = tempfile::tempdir()?;
        let raw_output_path = tmp_dir.path().join("output.raw");

        let netlist_content = std::fs::read_to_string(&netlist_path)?;
        let has_control = netlist_content
            .lines()
            .any(|line| line.trim().eq_ignore_ascii_case(".control"));

        let run_path = if has_control {
            netlist_path.clone()
        } else {
            let wrapper_path = tmp_dir.path().join("wrapper.cir");
            let wrapper_content = format!(
                ".include {}\n.control\nset filetype=ascii\nrun\nwrite {} all\n.endc\n",
                netlist_path.display(),
                raw_output_path.display(),
            );
            std::fs::write(&wrapper_path, wrapper_content)?;
            wrapper_path
        };

        let start = Instant::now();
        let output = match Command::new(&self.binary)
            .arg("-b")
            .args(&self.extra_args)
            .arg(&run_path)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
        {
            Ok(child) => child,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(NgspiceError::NotFound(
                    self.binary.display().to_string(),
                ));
            }
            Err(e) => return Err(NgspiceError::Io(e)),
        };

        let output = output.wait_with_output()?;
        let wall_time = start.elapsed();

        if wall_time > self.timeout {
            return Err(NgspiceError::Timeout(self.timeout));
        }

        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let exit_code = output.status.code().unwrap_or(-1);

        if !raw_output_path.exists() {
            if exit_code != 0 {
                return Err(NgspiceError::NonZeroExit {
                    code: exit_code,
                    stderr,
                });
            }
            return Err(NgspiceError::NoOutput);
        }

        let rawfile = RawFile::parse_file(&raw_output_path)?;

        Ok(NgspiceResult {
            rawfile,
            wall_time,
            stderr,
            exit_code,
        })
    }
}
