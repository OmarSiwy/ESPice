//! The process invocation each engine adapter hands the benchmark runner.
const std = @import("std");

/// One engine run of one fixture.
pub const Job = struct {
    argv: []const []const u8 = &.{},
    cwd: std.process.Child.Cwd = .inherit,
    /// The raw file the run writes, for `reader == .raw`.
    raw: []const u8 = "",
    /// Where the plots come from: `raw`, every `*.raw` in `cwd` (VACASK
    /// writes one per analysis), or a vendor tool's own files in `cwd`.
    reader: Reader = .raw,
    /// The deck has an `.op` card: vendor readers keep an operating-point
    /// plot only then, since HSPICE and Spectre write one for other reasons.
    op: bool = false,
    /// Non-empty: this engine cannot run the fixture, and why. Nothing runs.
    refused: []const u8 = "",
};
/// How the runner reads a finished job's plots back.
pub const Reader = enum { raw, vacask, hspice, spectre };
/// A vendor tool's own account of one run, in milliseconds: its elapsed
/// time less license checkout, and the sum of its per-analysis times.
pub const Reported = struct { run_ms: f64, analysis_ms: f64 };
/// Adapter failures while staging a job.
pub const Error = error{ DeckFailed, ScratchFailed, OutOfMemory };
