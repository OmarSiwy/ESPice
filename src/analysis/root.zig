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
}
