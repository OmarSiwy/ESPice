//! The analysis module's public seam: the query session, execution config and
//! result schemas. The numerical implementations stay private to the module.
/// The query graph and its scheduler (`Session`).
pub const session = @import("session.zig");
pub const ExecutionConfig = @import("executor.zig").Config;
pub const validateBackend = @import("executor.zig").validateBackend;
/// The result shape of a query, without running it.
pub const schemaOf = session.schemaOf;
/// HSPICE MOSRA level 1 aging over a stress transient.
pub const mosra = @import("post/mosra.zig");

test {
    _ = @import("tests/ac.zig");
    _ = @import("tests/circuit.zig");
    _ = @import("tests/executor.zig");
    _ = @import("tests/four.zig");
    _ = @import("tests/gpu.zig");
    _ = @import("tests/periodic.zig");
    _ = @import("tests/pz.zig");
    _ = @import("tests/session.zig");
    _ = @import("tests/sweep.zig");
    _ = @import("tests/transient.zig");
    _ = @import("tests/integration.zig");
    _ = @import("post/mosra.zig");
    _ = @import("par_eval.zig");
    _ = @import("session.zig");

    // Imported for semantic analysis only: Zig never type-checks an
    // unreferenced function, and the test step does not link the executor's
    // dispatch into these files.
    _ = @import("pss/hb.zig");
    _ = @import("pss/hb_lptv.zig");
    _ = @import("pss/phasenoise.zig");
    _ = @import("pss/pac.zig");
    _ = @import("pss/pnoise.zig");
    _ = @import("pss/pss.zig");
    _ = @import("pss/pxf.zig");
    _ = @import("pss/qpss.zig");
}
