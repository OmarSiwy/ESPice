//! Public query execution seam. Numerical implementations stay inside analysis.
pub const session = @import("session.zig");
pub const ExecutionConfig = @import("executor.zig").Config;
pub const validateBackend = @import("executor.zig").validateBackend;
pub const validateOutputSchema = session.validateOutputSchema;

test {
    _ = @import("tests/ac.zig");
    _ = @import("tests/circuit.zig");
    _ = @import("tests/eval.zig");
    _ = @import("tests/executor.zig");
    _ = @import("tests/four.zig");
    _ = @import("tests/gpu.zig");
    _ = @import("tests/periodic.zig");
    _ = @import("tests/pz.zig");
    _ = @import("tests/session.zig");
    _ = @import("tests/solvers.zig");
    _ = @import("tests/sweep.zig");
    _ = @import("tests/transient.zig");
    _ = @import("tests/integration.zig");

    // The `pss/*` implementations, imported for SEMA rather than for tests of
    // their own (they have none yet). Zig analyses lazily: a function nothing
    // references is never type-checked, so `hb.zig` sat on a `std.posix.getenv`
    // that Zig 0.16 had removed while `zig build test-analysis` reported every
    // test passing. It surfaced only when an artifact reaching `executor.zig`'s
    // harmonic-balance arm was linked, which the default `test` step does not
    // do. Importing them here turns a compile error in this subtree into a test
    // failure, where it is visible.
    _ = @import("pss/hb.zig");
    _ = @import("pss/pac.zig");
    _ = @import("pss/pnoise.zig");
    _ = @import("pss/pss.zig");
    _ = @import("pss/pxf.zig");
    _ = @import("pss/qpss.zig");
}
