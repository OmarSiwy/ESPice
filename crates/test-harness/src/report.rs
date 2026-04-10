use serde::Serialize;
use std::fmt::Write as FmtWrite;
use std::path::Path;

#[derive(Debug, Clone, Serialize)]
pub struct ComparisonReport {
    pub entries: Vec<ReportEntry>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ReportEntry {
    pub test_name: String,
    pub analysis_type: String,
    pub status: TestStatus,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "status", rename_all = "lowercase")]
pub enum TestStatus {
    Passed {
        max_abs_error: f64,
        max_rel_error: f64,
    },
    Failed {
        max_abs_error: f64,
        max_rel_error: f64,
        worst_signal: String,
    },
    Skipped {
        reason: String,
    },
}

impl ComparisonReport {
    pub fn to_text(&self) -> String {
        let passed = self.entries.iter().filter(|e| matches!(e.status, TestStatus::Passed { .. })).count();
        let failed = self.entries.iter().filter(|e| matches!(e.status, TestStatus::Failed { .. })).count();
        let skipped = self.entries.iter().filter(|e| matches!(e.status, TestStatus::Skipped { .. })).count();
        let total = self.entries.len();

        let mut out = String::new();
        writeln!(out, "=== VOLTAIC vs NGSpice Comparison Report ===").unwrap();
        writeln!(out, "Total: {total}  Passed: {passed}  Failed: {failed}  Skipped: {skipped}").unwrap();

        let failures: Vec<_> = self.entries.iter().filter(|e| matches!(e.status, TestStatus::Failed { .. })).collect();
        if !failures.is_empty() {
            writeln!(out).unwrap();
            writeln!(out, "FAILED:").unwrap();
            for entry in failures {
                if let TestStatus::Failed { max_abs_error, max_rel_error, ref worst_signal } = entry.status {
                    writeln!(
                        out,
                        "  {} [{}]  max_abs={:.2e}  max_rel={:.2e}  signal={}",
                        entry.test_name, entry.analysis_type, max_abs_error, max_rel_error, worst_signal
                    ).unwrap();
                }
            }
        }

        let skips: Vec<_> = self.entries.iter().filter(|e| matches!(e.status, TestStatus::Skipped { .. })).collect();
        if !skips.is_empty() {
            writeln!(out).unwrap();
            writeln!(out, "SKIPPED:").unwrap();
            for entry in skips {
                if let TestStatus::Skipped { ref reason } = entry.status {
                    writeln!(out, "  {} [{}]", entry.test_name, reason).unwrap();
                }
            }
        }

        out
    }

    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    pub fn write_json(&self, path: &Path) -> Result<(), Box<dyn std::error::Error>> {
        let json = self.to_json()?;
        std::fs::write(path, json)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_report_all_pass() {
        let report = ComparisonReport {
            entries: vec![
                ReportEntry {
                    test_name: "voltage_divider".into(),
                    analysis_type: "DC".into(),
                    status: TestStatus::Passed {
                        max_abs_error: 1e-12,
                        max_rel_error: 1e-10,
                    },
                },
            ],
        };

        let text = report.to_text();
        assert!(text.contains("Total: 1"));
        assert!(text.contains("Passed: 1"));
        assert!(text.contains("Failed: 0"));
    }

    #[test]
    fn format_report_with_failures() {
        let report = ComparisonReport {
            entries: vec![
                ReportEntry {
                    test_name: "voltage_divider".into(),
                    analysis_type: "DC".into(),
                    status: TestStatus::Passed {
                        max_abs_error: 1e-12,
                        max_rel_error: 1e-10,
                    },
                },
                ReportEntry {
                    test_name: "bsim4_iv".into(),
                    analysis_type: "DC".into(),
                    status: TestStatus::Failed {
                        max_abs_error: 2.3e-4,
                        max_rel_error: 2.3e-4,
                        worst_signal: "I(Vds)".into(),
                    },
                },
                ReportEntry {
                    test_name: "xspice_adc".into(),
                    analysis_type: "DC".into(),
                    status: TestStatus::Skipped {
                        reason: "unsupported analysis".into(),
                    },
                },
            ],
        };

        let text = report.to_text();
        assert!(text.contains("Total: 3"));
        assert!(text.contains("Passed: 1"));
        assert!(text.contains("Failed: 1"));
        assert!(text.contains("Skipped: 1"));
        assert!(text.contains("bsim4_iv"));
        assert!(text.contains("I(Vds)"));
    }

    #[test]
    fn report_to_json() {
        let report = ComparisonReport {
            entries: vec![
                ReportEntry {
                    test_name: "divider".into(),
                    analysis_type: "DC".into(),
                    status: TestStatus::Passed {
                        max_abs_error: 1e-12,
                        max_rel_error: 1e-10,
                    },
                },
            ],
        };

        let json = report.to_json().unwrap();
        assert!(json.contains("\"test_name\":\"divider\"") || json.contains("\"test_name\": \"divider\""));
        assert!(json.contains("\"status\":\"passed\"") || json.contains("\"status\": \"passed\""));
    }
}
