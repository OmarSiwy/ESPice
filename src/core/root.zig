//! Shared data every layer speaks: numerics, query requests, the deck,
//! results, the name pool and the shared ids. Imports nothing but std and
//! stdpp, which AGENTS.md §2.8 counts as part of std.
const std = @import("std");

/// The process-wide general-purpose allocator. SmpAllocator does not build
/// single-threaded (the wasm playground), so there it is the page allocator,
/// which on wasm is WasmAllocator.
pub const gpa: std.mem.Allocator = if (@import("builtin").single_threaded) std.heap.page_allocator else std.heap.smp_allocator;
/// Vector kernels (stdpp), complex numbers, the frequency grid and the
/// solver tolerances.
pub const numerics = @import("numerics.zig");
/// One options struct per analysis, and the `Query` union over them.
pub const query = @import("query.zig");
/// Query validation (`validate.validate`), shared by the analysis boundary and the frontend.
pub const validate = @import("validate.zig");
/// The HSPICE `.model OPT` Levenberg-Marquardt optimizer, driven by its caller.
pub const lm = @import("lm.zig");
/// The HSPICE `.model OPT` bisection and pass/fail searches.
pub const bisect = @import("bisect.zig");
/// Dense real eigenvalues (balance, Hessenberg, Francis QR).
pub const eigen = @import("eigen.zig");
/// Test support: the allocator every allocation-failure sweep runs over.
pub const testing = @import("testing.zig");
pub const QueryId = query.QueryId;

const deck = @import("deck.zig");
pub const Deck = deck.Deck;
pub const Ic = deck.Ic;
pub const AcOverride = deck.AcOverride;
pub const Variants = deck.Variants;
pub const QueryBindings = deck.QueryBindings;
pub const Measure = deck.Measure;
pub const MeasureClause = deck.MeasureClause;
pub const GoalBound = deck.GoalBound;
pub const MeasureFunc = deck.MeasureFunc;
pub const Check = deck.Check;
pub const MeasureOp = deck.MeasureOp;
pub const MeasureRef = deck.MeasureRef;
pub const SaveOp = deck.SaveOp;
pub const Mosra = deck.Mosra;
pub const MosraModel = deck.MosraModel;
pub const Stim = deck.Stim;
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

const ids = @import("ids.zig");
pub const DeviceType = ids.DeviceType;
pub const GROUND = ids.GROUND;

test {
    _ = numerics;
    _ = intern;
    _ = lm;
    _ = bisect;
    _ = eigen;
    _ = query;
    _ = deck;
}
