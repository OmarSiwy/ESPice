//! A prepared process invocation. All fields are consumed together per run.
const std = @import("std");

pub const Job = struct {
    argv: []const []const u8 = &.{},
    cwd: std.process.Child.Cwd = .inherit,
    raw: []const u8 = "",
    refused: []const u8 = "",
};
pub const Error = error{ DeckFailed, ScratchFailed, OutOfMemory };
