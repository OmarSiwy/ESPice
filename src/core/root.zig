//! Shared data every layer speaks: numerics, query requests, the deck,
//! results and the name pool. Imports nothing but std.
const std = @import("std");
pub const numerics = @import("numerics.zig");
pub const query = @import("query.zig");
pub const QueryId = query.QueryId;

const deck = @import("deck.zig");
pub const Deck = deck.Deck;
pub const Ic = deck.Ic;
pub const AcOverride = deck.AcOverride;
pub const Variants = deck.Variants;
pub const QueryBindings = deck.QueryBindings;
pub const Measure = deck.Measure;
pub const MeasureClause = deck.MeasureClause;
pub const MeasureFunc = deck.MeasureFunc;
pub const MeasureOp = deck.MeasureOp;
pub const measure_unset = deck.measure_unset;
pub const measure_last = deck.measure_last;
pub const measure_no_at = deck.measure_no_at;

const result = @import("result.zig");
pub const Result = result.Result;
pub const Schema = result.Schema;
pub const QuerySchema = result.QuerySchema;

const intern = @import("intern.zig");
pub const InternPool = intern.InternPool;
pub const Name = intern.Name;

/// Dense id of a device type in a `device.Library`: built-ins first, in
/// catalog order, then runtime-loaded ones. A device never knows its own id;
/// the host stamps it where one is needed (`ParamRef.type`, `CardRef.type`).
pub const DeviceType = enum(u16) { unset = std.math.maxInt(u16), _ };

/// Row 0 of every circuit: the reference node.
pub const GROUND: u32 = 0;

test {
    _ = numerics;
    _ = intern;
}
