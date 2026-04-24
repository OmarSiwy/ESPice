//! Output module — single source of truth for all printing.
//!
//! `print_output()` takes `OutputParams` with many Option fields.
//! Any field that is Some gets printed. None fields are silent.
//! This way we never have scattered eprintln!/println! calls.
//!
//! ## Streaming sinks
//!
//! `RawfileSink`, `CsvSink`, `ChannelSink`, and `spawn_streaming_pipeline`
//! are re-exported from `crate::io::sinks`.  The CLI builds variable-name
//! slices from the circuit and calls those constructors directly.

use std::io::{self, Write};

// ── Re-export streaming sinks from crate::io ─────────────────────────────────
//
// The concrete sink types live in crate::io::sinks.  We re-export them so
// callers can `use crate::output::{RawfileSink, CsvSink, ChannelSink, …}`.
pub use crate::io::{spawn_streaming_pipeline, ChannelSink, CsvSink, RawfileSink};
use incspice_core::{Circuit, StreamingSink};

// ── OutputParams — the "ton of parameters" approach ───────────────────────────

#[derive(Debug, Default)]
pub struct OutputParams {
    // Parse stage
    pub parse_nodes: Option<usize>,
    pub parse_devices: Option<usize>,
    pub parse_analyses: Option<usize>,
    pub parse_time_ms: Option<f64>,

    // Topology stage
    pub topology_hash: Option<u64>,
    pub topology_cache_hit: Option<bool>,

    // Solver stage
    pub nr_iterations: Option<usize>,
    pub nr_converged: Option<bool>,
    pub nr_time_ms: Option<f64>,
    pub nr_fallback: Option<String>,

    // Analysis stage
    pub analysis_name: Option<String>,
    pub analysis_done: Option<bool>,
    pub analysis_points: Option<usize>,
    pub analysis_time_ms: Option<f64>,

    // Cache telemetry
    pub cache_topo_hits: Option<u64>,
    pub cache_topo_misses: Option<u64>,
    pub cache_dirty_count: Option<usize>,
    pub cache_affine_hits: Option<u64>,
    pub cache_woodbury_used: Option<bool>,

    // Output stage
    pub output_file: Option<String>,
    pub output_format: Option<String>,
    pub output_points: Option<usize>,
    pub output_bytes: Option<u64>,

    // Errors / warnings
    pub warning: Option<String>,
    pub error: Option<String>,
}

/// Print all non-None fields.  Single source of truth for output formatting.
pub fn print_output(p: OutputParams) {
    // Parse
    if let Some(n) = p.parse_nodes {
        eprint!("nodes={n} ");
    }
    if let Some(d) = p.parse_devices {
        eprint!("devices={d} ");
    }
    if let Some(a) = p.parse_analyses {
        eprint!("analyses={a}");
    }
    if p.parse_nodes.is_some() || p.parse_devices.is_some() || p.parse_analyses.is_some() {
        eprintln!();
    }
    if let Some(t) = p.parse_time_ms {
        eprintln!("parse: {t:.1}ms");
    }

    // Topology
    if let Some(h) = p.topology_hash {
        eprintln!("topology hash: {h:#018x}");
    }
    if let Some(hit) = p.topology_cache_hit {
        eprintln!("topology cache: {}", if hit { "HIT" } else { "MISS" });
    }

    // Solver
    if let Some(iter) = p.nr_iterations {
        let conv = p.nr_converged.unwrap_or(false);
        eprintln!(
            "NR: {iter} iterations, {}",
            if conv { "converged" } else { "FAILED" }
        );
    }
    if let Some(t) = p.nr_time_ms {
        eprintln!("  solve: {t:.2}ms");
    }
    if let Some(ref fb) = p.nr_fallback {
        eprintln!("  fallback: {fb}");
    }

    // Analysis
    if let Some(ref name) = p.analysis_name {
        if p.analysis_done == Some(true) {
            eprintln!("[{name}] done");
        }
    }
    if let Some(pts) = p.analysis_points {
        eprintln!("  points: {pts}");
    }
    if let Some(t) = p.analysis_time_ms {
        eprintln!("  time: {t:.1}ms");
    }

    // Cache
    if let Some(h) = p.cache_topo_hits {
        eprint!("cache topo_hits={h} ");
    }
    if let Some(m) = p.cache_topo_misses {
        eprint!("topo_misses={m} ");
    }
    if let Some(d) = p.cache_dirty_count {
        eprint!("dirty={d} ");
    }
    if let Some(a) = p.cache_affine_hits {
        eprint!("affine_hits={a} ");
    }
    if let Some(w) = p.cache_woodbury_used {
        eprint!("woodbury={w} ");
    }
    if p.cache_topo_hits.is_some() || p.cache_dirty_count.is_some() {
        eprintln!();
    }

    // Output
    if let Some(ref f) = p.output_file {
        eprintln!("output: {f}");
    }
    if let Some(ref fmt) = p.output_format {
        eprintln!("  format: {fmt}");
    }
    if let Some(pts) = p.output_points {
        eprintln!("  points: {pts}");
    }
    if let Some(b) = p.output_bytes {
        eprintln!("  bytes: {b}");
    }

    // Errors
    if let Some(ref w) = p.warning {
        eprintln!("WARNING: {w}");
    }
    if let Some(ref e) = p.error {
        eprintln!("ERROR: {e}");
    }
}

// ── Circuit → variable name helpers ──────────────────────────────────────────

/// Build the variable name slice that sink constructors expect from a circuit.
///
/// Returns names ordered by `matrix_index` (which is the column order the
/// solver uses), prefixed with `"sweep"` as the independent variable.
pub fn circuit_variable_names(circuit: &Circuit) -> Vec<String> {
    let mut nodes: Vec<_> = circuit
        .nodes()
        .iter()
        .filter_map(|n| n.matrix_index.map(|idx| (idx, format!("v({})", n.name))))
        .collect();
    nodes.sort_by_key(|(idx, _)| *idx);
    let mut names = vec!["sweep".to_string()];
    names.extend(nodes.into_iter().map(|(_, name)| name));
    names
}

/// Convenience: build a `RawfileSink` wired to a circuit's node ordering.
pub fn rawfile_sink_for_circuit<W: Write + io::Seek>(
    inner: W,
    circuit: &Circuit,
) -> io::Result<RawfileSink<W>> {
    let names = circuit_variable_names(circuit);
    let name_refs: Vec<&str> = names.iter().map(String::as_str).collect();
    RawfileSink::new(inner, &name_refs)
}

/// Convenience: build a `CsvSink` wired to a circuit's node ordering.
pub fn csv_sink_for_circuit<W: Write>(inner: W, circuit: &Circuit) -> CsvSink<W> {
    let names = circuit_variable_names(circuit);
    let name_refs: Vec<&str> = names.iter().map(String::as_str).collect();
    CsvSink::new(inner, &name_refs)
}
