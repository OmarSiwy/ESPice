use serde::Deserialize;
use std::path::{Path, PathBuf};
use thiserror::Error;
use glob;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("TOML parse error: {0}")]
    Toml(#[from] toml::de::Error),
}

#[derive(Debug, Clone, Deserialize)]
pub struct TestConfig {
    pub test: TestMeta,
    #[serde(default)]
    pub tolerance: TomlTolerance,
    pub performance: Option<PerfMeta>,
    #[serde(default)]
    pub reference: ReferenceMeta,
    #[serde(skip)]
    pub base_dir: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TestMeta {
    pub name: String,
    #[serde(rename = "type")]
    pub test_type: String,
    #[serde(default)]
    pub tags: Vec<String>,
    pub netlist: String,
    #[serde(default)]
    pub golden: Option<String>,
    #[serde(default)]
    pub ignore: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default)]
pub struct TomlTolerance {
    pub voltage: Option<f64>,
    pub current: Option<f64>,
    pub timing: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PerfMeta {
    pub baseline_seconds: f64,
    pub target_speedup: f64,
    #[serde(default)]
    pub gpu_required: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ReferenceMeta {
    pub simulator: String,
}

impl Default for ReferenceMeta {
    fn default() -> Self {
        Self {
            simulator: "ngspice".to_string(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ExternalSuite {
    pub name: String,
    pub root: PathBuf,
    pub netlist_glob: String,
    pub default_tags: Vec<String>,
}

impl ExternalSuite {
    pub fn discover(&self) -> Vec<TestConfig> {
        let pattern = self.root.join(&self.netlist_glob).display().to_string();
        let mut configs: Vec<TestConfig> = glob::glob(&pattern)
            .into_iter()
            .flatten()
            .filter_map(|entry| entry.ok())
            .map(|path| {
                let stem = path.file_stem().unwrap_or_default().to_string_lossy();
                let file_name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
                let golden_file = format!("{}.csv", stem);
                let base = path.parent().unwrap_or(Path::new(".")).to_path_buf();

                TestConfig {
                    test: TestMeta {
                        name: format!("{}_{}", self.name, stem),
                        test_type: "external".to_string(),
                        tags: self.default_tags.clone(),
                        netlist: file_name,
                        golden: Some(golden_file),
                        ignore: None,
                    },
                    tolerance: TomlTolerance::default(),
                    performance: None,
                    reference: ReferenceMeta::default(),
                    base_dir: base,
                }
            })
            .collect();
        configs.sort_by(|a, b| a.test.name.cmp(&b.test.name));
        configs
    }
}

impl TestConfig {
    pub fn from_file(path: &Path) -> Result<Self, ConfigError> {
        let content = std::fs::read_to_string(path)?;
        let mut config: TestConfig = toml::from_str(&content)?;
        config.base_dir = path.parent().unwrap_or(Path::new(".")).to_path_buf();
        Ok(config)
    }

    pub fn netlist_path(&self) -> PathBuf {
        self.base_dir.join(&self.test.netlist)
    }

    pub fn golden_path(&self) -> Option<PathBuf> {
        self.test.golden.as_ref().map(|g| self.base_dir.join(g))
    }

    pub fn is_ignored(&self) -> bool {
        self.test.ignore.is_some()
    }

    pub fn matches_tags(&self, filter: &[String]) -> bool {
        if filter.is_empty() {
            return true;
        }
        filter.iter().any(|tag| self.test.tags.contains(tag))
    }
}

pub fn discover_tests(root: &Path, tag_filter: &[String]) -> Vec<TestConfig> {
    let mut configs = Vec::new();
    discover_recursive(root, tag_filter, &mut configs);
    configs.sort_by(|a, b| a.test.name.cmp(&b.test.name));
    configs
}

fn discover_recursive(dir: &Path, tag_filter: &[String], out: &mut Vec<TestConfig>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            discover_recursive(&path, tag_filter, out);
        } else if path.file_name().is_some_and(|n| n == "test.toml") {
            if let Ok(config) = TestConfig::from_file(&path) {
                if config.matches_tags(tag_filter) {
                    out.push(config);
                }
            }
        }
    }
}
