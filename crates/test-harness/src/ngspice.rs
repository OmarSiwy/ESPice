use crate::rawfile::{RawFile, RawFileError};
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
        // 1. Canonicalize netlist path
        let netlist_path = netlist_path.canonicalize()?;

        // 2. Create temp directory
        let tmp_dir = tempfile::tempdir()?;
        let raw_output_path = tmp_dir.path().join("output.raw");

        // 3. Check if netlist has a .control block
        let netlist_content = std::fs::read_to_string(&netlist_path)?;
        let has_control = netlist_content
            .lines()
            .any(|line| line.trim().eq_ignore_ascii_case(".control"));

        // 4. Determine which netlist to run
        let run_path = if has_control {
            netlist_path.clone()
        } else {
            // Create a wrapper netlist that .includes the original
            let wrapper_path = tmp_dir.path().join("wrapper.cir");
            let wrapper_content = format!(
                ".include {}\n.control\nset filetype=ascii\nrun\nwrite {} all\n.endc\n",
                netlist_path.display(),
                raw_output_path.display(),
            );
            std::fs::write(&wrapper_path, wrapper_content)?;
            wrapper_path
        };

        // 5. Run ngspice -b <wrapper_or_original>
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

        // 6. Check exit status and parse output
        if !raw_output_path.exists() {
            if exit_code != 0 {
                return Err(NgspiceError::NonZeroExit {
                    code: exit_code,
                    stderr,
                });
            }
            return Err(NgspiceError::NoOutput);
        }

        // 7. Parse the rawfile
        let rawfile = RawFile::parse_file(&raw_output_path)?;

        Ok(NgspiceResult {
            rawfile,
            wall_time,
            stderr,
            exit_code,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ngspice_is_available_check() {
        let config = NgspiceConfig::default();
        let available = config.is_available();
        if available {
            println!("ngspice found at: {:?}", config.binary);
        } else {
            println!("ngspice not found — live tests will be skipped");
        }
    }

    #[test]
    fn ngspice_config_from_env() {
        let config = NgspiceConfig::default();
        assert!(!config.binary.as_os_str().is_empty());
        assert_eq!(config.timeout, Duration::from_secs(60));
    }

    #[test]
    fn run_ngspice_voltage_divider() {
        let config = NgspiceConfig::default();
        if !config.is_available() {
            eprintln!("ngspice not available — skipping");
            return;
        }

        let tmp = tempfile::tempdir().unwrap();
        let netlist_path = tmp.path().join("divider.sp");
        std::fs::write(&netlist_path, "\
* Voltage divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
").unwrap();

        let result = config.run(&netlist_path).unwrap();
        assert_eq!(result.rawfile.plotname, "Operating Point");
        assert_eq!(result.rawfile.variables.len(), 3);

        let pairs = result.rawfile.as_dc_pairs();
        let v1 = pairs.iter().find(|(n, _)| n == "v(1)").unwrap().1;
        let v2 = pairs.iter().find(|(n, _)| n == "v(2)").unwrap().1;
        assert!((v1 - 5.0).abs() < 1e-9, "v(1) = {v1}");
        assert!((v2 - 2.5).abs() < 1e-9, "v(2) = {v2}");

        let i_v1 = pairs.iter().find(|(n, _)| n.contains("v1")).unwrap().1;
        assert!((i_v1 + 0.0025).abs() < 1e-9, "i(v1) = {i_v1}");

        assert!(result.wall_time.as_millis() < 10_000, "took too long");
    }

    #[test]
    fn run_ngspice_nonexistent_binary() {
        let config = NgspiceConfig {
            binary: PathBuf::from("/nonexistent/ngspice"),
            timeout: Duration::from_secs(5),
            extra_args: Vec::new(),
        };
        assert!(!config.is_available());

        let tmp = tempfile::tempdir().unwrap();
        let netlist_path = tmp.path().join("test.sp");
        std::fs::write(&netlist_path, "* test\n.END\n").unwrap();

        let result = config.run(&netlist_path);
        assert!(result.is_err());
    }
}
