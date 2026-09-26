//! The process invocation each engine adapter hands the benchmark runner.
const std = @import("std");

/// One engine run of one fixture.
pub const Job = struct {
    argv: []const []const u8 = &.{},
    cwd: std.process.Child.Cwd = .inherit,
    /// The raw file the run writes. Empty: every `*.raw` in `cwd` (VACASK
    /// writes one per analysis).
    raw: []const u8 = "",
    /// Non-empty: this engine cannot run the fixture, and why. Nothing runs.
    refused: []const u8 = "",
};
/// Adapter failures while staging a job.
pub const Error = error{ DeckFailed, ScratchFailed, OutOfMemory };
