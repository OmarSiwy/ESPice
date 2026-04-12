//! Shared Criterion helpers for all benchmark categories.

use std::path::{Path, PathBuf};

/// All known fixture subdirectories under `tests/fixtures/`.
const FIXTURE_SUBDIRS: &[&str] = &[
    "basic",
    "quick",
    "medium",
    "scaling",
    "mosfet",
    "bjt",
    "analog",
    "power",
    "tline",
    "noise",
    "sensitivity",
    "convergence",
    "dc_sweep",
    "fourier",
    "ngspice",
    "xyce",
];

/// Root of the fixtures directory.
fn fixtures_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

/// Discover all `.sp` fixture files under `tests/fixtures/basic/`,
/// returning `(stem_name, file_content)` pairs sorted by name.
/// Kept for backward compatibility.
pub fn discover_fixtures() -> Vec<(String, String)> {
    discover_fixtures_from("basic")
}

/// Discover `.sp` fixtures from a specific subdirectory under `tests/fixtures/`.
/// Returns `(stem_name, file_content)` pairs sorted by name.
pub fn discover_fixtures_from(subdir: &str) -> Vec<(String, String)> {
    let dir = fixtures_root().join(subdir);
    if !dir.exists() {
        return Vec::new();
    }
    let pattern = dir.join("*.sp");
    let mut fixtures: Vec<(String, String)> = glob::glob(pattern.to_str().unwrap())
        .expect("invalid glob pattern")
        .filter_map(|e| e.ok())
        .filter_map(|path| {
            let name = path.file_stem()?.to_string_lossy().into_owned();
            let content = std::fs::read_to_string(&path).ok()?;
            Some((name, content))
        })
        .collect();
    fixtures.sort_by(|a, b| a.0.cmp(&b.0));
    fixtures
}

/// Discover all `.sp` fixtures across every known subdirectory.
/// Returns `(category/stem_name, file_content)` pairs sorted by name.
pub fn discover_all_fixtures() -> Vec<(String, String)> {
    let mut all = Vec::new();
    for &subdir in FIXTURE_SUBDIRS {
        for (name, content) in discover_fixtures_from(subdir) {
            all.push((format!("{subdir}/{name}"), content));
        }
    }
    all.sort_by(|a, b| a.0.cmp(&b.0));
    all
}

/// Quick tier: small circuits that run in < 1 second each.
const QUICK_DIRS: &[&str] = &["basic", "quick"];

/// Medium tier: moderate circuits, minutes total.
const MEDIUM_DIRS: &[&str] = &["medium", "mosfet", "bjt", "analog", "dc_sweep",
                                "fourier", "noise", "sensitivity", "tline",
                                "power", "convergence", "ngspice", "xyce"];

/// Full tier: large scaling circuits, may take hours.
const FULL_DIRS: &[&str] = &["scaling"];

/// Discover fixtures by tier. Returns `(category/stem, content)` pairs.
pub fn discover_fixtures_tiered(tier: BenchTier) -> Vec<(String, String)> {
    let dirs: &[&str] = match tier {
        BenchTier::Quick => QUICK_DIRS,
        BenchTier::Medium => MEDIUM_DIRS,
        BenchTier::Full => FULL_DIRS,
    };
    let mut all = Vec::new();
    for &subdir in dirs {
        for (name, content) in discover_fixtures_from(subdir) {
            all.push((format!("{subdir}/{name}"), content));
        }
    }
    all.sort_by(|a, b| a.0.cmp(&b.0));
    all
}

/// Benchmark tier for selecting fixture subsets.
#[derive(Clone, Copy, Debug)]
pub enum BenchTier {
    Quick,
    Medium,
    Full,
}

/// Load a single named fixture from `tests/fixtures/basic/{name}.sp`.
pub fn load_fixture(name: &str) -> String {
    let path = fixtures_root()
        .join("basic")
        .join(format!("{name}.sp"));
    std::fs::read_to_string(&path)
        .unwrap_or_else(|_| panic!("fixture not found: {name}.sp"))
}

