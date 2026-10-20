//! Frontend: netlist source in, a frozen `device.Circuit` and resolved
//! queries out (prepare.zig is the spine). Leaves never import this root; it
//! only re-exports what the facade calls. Cites nothing itself.
const preparation = @import("prepare.zig");
pub const Source = preparation.Source;
pub const Dialect = preparation.Dialect;
pub const prepare = preparation.prepare;
pub const loadModels = preparation.loadModels;
pub const parseDialect = preparation.parseDialect;
pub const detectDialect = preparation.detectDialect;
pub const build = preparation.build;
pub const Prepared = preparation.Prepared;
pub const Tuner = @import("variants.zig").Tuner;
pub const resolveQueries = preparation.resolveQueries;
pub const Library = @import("device").Library;

test {
    _ = @import("tests/builder.zig");
    _ = @import("tests/prepared.zig");
    _ = @import("tests/models.zig");
    _ = @import("tests/variants.zig");
    _ = @import("variants.zig");
    _ = @import("analyses.zig");
    _ = @import("mosra.zig");
    _ = @import("prepare.zig");
}
