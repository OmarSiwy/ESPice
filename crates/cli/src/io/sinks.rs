//! Concrete `StreamingSink` implementations for the CLI.
//!
//! ## Streaming Pipeline
//!
//! True streaming: solver thread produces points, writer thread consumes via
//! bounded channel.
//!
//! ```text
//! [Solver Thread] --emit_point()--> [bounded channel (cap 4)] --> [Writer Thread] --write to disk-->
//! ```
//!
//! - `ChannelSink` wraps a `crossbeam::Sender`. Solver calls `emit_point()` which
//!   sends through the channel.
//! - Writer thread receives and writes to `RawfileSink`/`CsvSink`. I/O overlaps compute.
//! - Fallback: `NullSink` (benchmarks), direct `RawfileSink` (single-threaded mode).

use std::io::{self, Seek, Write};
use std::thread::{self, JoinHandle};

use crossbeam_channel::{bounded, Receiver, Sender};

use incspice_core::{SimError, StreamingSink};

use super::rawfile::{RawFlag, RawfileWriter};
use super::csv::CsvWriter;

// ── Message type ──────────────────────────────────────────────────────────────

enum SinkMsg {
    Point { sweep_val: f64, values: Vec<f64> },
    Finalize,
}

// ── RawfileSink ───────────────────────────────────────────────────────────────

/// A `StreamingSink` that buffers points and writes a Berkeley rawfile on
/// `finalize()`.  The writer accumulates columns in memory (column-major)
/// then emits the header + body in one pass.
///
/// Uses binary format by default.  To switch to ASCII, call
/// `RawfileSink::new_ascii` or set `sink.writer.filetype`.
pub struct RawfileSink<W: Write + Seek> {
    inner: W,
    writer: RawfileWriter,
    /// Column-major accumulation: `columns[var_idx]` grows as points arrive.
    columns: Vec<Vec<f64>>,
    /// Number of variables (not counting the independent sweep column).
    num_vars: usize,
}

impl<W: Write + Seek> RawfileSink<W> {
    /// Create a binary rawfile sink.  `var_names[0]` is the independent
    /// variable (time / sweep); the rest are dependent node voltages / currents.
    pub fn new(inner: W, var_names: &[&str]) -> io::Result<Self> {
        let mut writer = RawfileWriter::new("BigOSpice simulation", "Transient Analysis", RawFlag::Real);
        for name in var_names {
            let var_type = if *name == "sweep" || *name == "time" || *name == "frequency" {
                "time"
            } else if name.starts_with("i(") {
                "current"
            } else {
                "voltage"
            };
            writer.add_variable(name, var_type);
        }
        let num_vars = var_names.len();
        let columns = vec![Vec::new(); num_vars];
        Ok(Self { inner, writer, columns, num_vars })
    }
}

impl<W: Write + Seek> StreamingSink for RawfileSink<W> {
    fn emit_point(&mut self, sweep_val: f64, values: &[f64]) -> Result<(), SimError> {
        // Column 0 is the independent variable (sweep_val).
        if !self.columns.is_empty() {
            self.columns[0].push(sweep_val);
        }
        for (i, &v) in values.iter().enumerate() {
            let col_idx = i + 1;
            if col_idx < self.num_vars {
                self.columns[col_idx].push(v);
            }
        }
        Ok(())
    }

    fn finalize(&mut self) -> Result<(), SimError> {
        self.writer
            .set_real_columns(&self.columns)
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
        self.writer.write(&mut self.inner).map_err(SimError::Io)
    }
}

// ── CsvSink ───────────────────────────────────────────────────────────────────

/// A `StreamingSink` that writes CSV output.  Points are buffered in memory
/// (column-major) then written on `finalize()`.
pub struct CsvSink<W: Write> {
    inner: W,
    headers: Vec<String>,
    columns: Vec<Vec<f64>>,
    num_vars: usize,
}

impl<W: Write> CsvSink<W> {
    pub fn new(inner: W, var_names: &[&str]) -> Self {
        let num_vars = var_names.len();
        let headers = var_names.iter().map(|s| s.to_string()).collect();
        let columns = vec![Vec::new(); num_vars];
        Self { inner, headers, columns, num_vars }
    }
}

impl<W: Write> StreamingSink for CsvSink<W> {
    fn emit_point(&mut self, sweep_val: f64, values: &[f64]) -> Result<(), SimError> {
        if !self.columns.is_empty() {
            self.columns[0].push(sweep_val);
        }
        for (i, &v) in values.iter().enumerate() {
            let col_idx = i + 1;
            if col_idx < self.num_vars {
                self.columns[col_idx].push(v);
            }
        }
        Ok(())
    }

    fn finalize(&mut self) -> Result<(), SimError> {
        let mut writer = CsvWriter::new();
        let header_refs: Vec<&str> = self.headers.iter().map(String::as_str).collect();
        writer.set_headers(&header_refs);
        writer
            .set_columns(&self.columns)
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
        writer
            .write(&mut self.inner)
            .map_err(|e| SimError::Io(io::Error::new(io::ErrorKind::Other, e.to_string())))
    }
}

// ── ChannelSink ───────────────────────────────────────────────────────────────

/// A `StreamingSink` that forwards each point over a bounded
/// `crossbeam_channel`.  The writer thread on the other end holds a
/// concrete sink (e.g. `RawfileSink` or `CsvSink`) and flushes to disk.
///
/// Backpressure is provided by the channel capacity — the solver blocks when
/// the writer is slower than compute.
pub struct ChannelSink {
    tx: Sender<SinkMsg>,
}

impl StreamingSink for ChannelSink {
    fn emit_point(&mut self, sweep_val: f64, values: &[f64]) -> Result<(), SimError> {
        self.tx
            .send(SinkMsg::Point {
                sweep_val,
                values: values.to_vec(),
            })
            .map_err(|_| SimError::Io(io::Error::new(io::ErrorKind::BrokenPipe, "writer thread disconnected")))
    }

    fn finalize(&mut self) -> Result<(), SimError> {
        self.tx
            .send(SinkMsg::Finalize)
            .map_err(|_| SimError::Io(io::Error::new(io::ErrorKind::BrokenPipe, "writer thread disconnected")))
    }
}

// ── spawn_streaming_pipeline ──────────────────────────────────────────────────

/// Spawn a writer thread and return a `(ChannelSink, JoinHandle)` pair.
///
/// The solver thread calls `channel_sink.emit_point()` which sends through a
/// bounded channel (capacity `channel_cap`).  The writer thread receives and
/// calls the inner sink's `emit_point` + `finalize`.
///
/// ```text
/// [Solver] --channel--> [Writer thread] ---> disk
/// ```
///
/// Call `writer_handle.join()` after the solver finishes to wait for the
/// writer to complete and surface any I/O errors.
pub fn spawn_streaming_pipeline(
    mut inner: Box<dyn StreamingSink + Send>,
    channel_cap: usize,
) -> (ChannelSink, JoinHandle<Result<(), SimError>>) {
    let (tx, rx): (Sender<SinkMsg>, Receiver<SinkMsg>) = bounded(channel_cap);

    let handle = thread::spawn(move || -> Result<(), SimError> {
        loop {
            match rx.recv() {
                Ok(SinkMsg::Point { sweep_val, values }) => {
                    inner.emit_point(sweep_val, &values)?;
                }
                Ok(SinkMsg::Finalize) => {
                    inner.finalize()?;
                    return Ok(());
                }
                Err(_) => {
                    // Sender dropped without sending Finalize — treat as finalize.
                    inner.finalize()?;
                    return Ok(());
                }
            }
        }
    });

    (ChannelSink { tx }, handle)
}
