//! Shared filesystem helpers for test_external and bench_external.

use std::path::{Path, PathBuf};

pub fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tools/fixtures")
}

/// All `.sp` files in `dir`, sorted.
pub fn sp_files_in(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", dir.display()))
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|ext| ext == "sp"))
        .collect();
    files.sort();
    files
}

/// All `.sp` files in `fixtures/<category>`, sorted.
#[allow(dead_code)]
pub fn sp_files(category: &str) -> Vec<PathBuf> {
    sp_files_in(&fixtures_dir().join(category))
}

/// All subdirectories of `fixtures/` except `adversarial`, sorted.
pub fn glob_categories() -> Vec<String> {
    let base = fixtures_dir();
    let mut cats: Vec<String> = std::fs::read_dir(&base)
        .unwrap_or_else(|e| panic!("cannot read fixtures dir: {e}"))
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    cats.sort();
    cats
}

/// Fixture categories after applying comma/space-separated environment filters.
pub fn filtered_categories() -> Vec<String> {
    let mut cats = glob_categories();
    if let Some(include) = env_filter("INCSPICE_EXTERNAL_CATEGORIES") {
        cats.retain(|cat| include.iter().any(|want| want == cat));
    }
    if let Some(exclude) = env_filter("INCSPICE_EXTERNAL_EXCLUDE") {
        cats.retain(|cat| !exclude.iter().any(|skip| skip == cat));
    }
    cats
}

fn env_filter(name: &str) -> Option<Vec<String>> {
    let raw = std::env::var(name).ok()?;
    let values: Vec<String> = raw
        .split(|c: char| c == ',' || c == ';' || c.is_ascii_whitespace())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_ascii_lowercase())
        .collect();
    (!values.is_empty()).then_some(values)
}
