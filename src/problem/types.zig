//! Shared prepared data; consumers never import the Problem facade.
const std = @import("std");
pub const requests = @import("requests");
pub const numerics = @import("numerics");
pub const Circuit = @import("device").Circuit;
pub const GROUND: u32 = 0;

/// Resolved initial condition, applied together when a query starts with UIC.
pub const Ic = struct { node: u32, value: f64 };

/// A stable parameter identity; each analysis clone resolves its own pointer.
pub const AcOverride = struct {
    type_name: []const u8,
    index: u32,
    param_name: []const u8,
    value: f64,
};

/// Construction bindings retained for resolving later analysis directives.
pub const QueryBindings = struct {
    v_names: []const []const u8,
    i_names: []const []const u8,
    v_branches: []const u32,
    /// Node rows of each V card, `+` then `−`, post-permutation.
    v_pos: []const u32,
    v_neg: []const u32,
    /// Same for each I card. An I source has no branch row of its own.
    i_pos: []const u32,
    i_neg: []const u32,
    v_distof1: []const [2]f64,
    ports: []const requests.Port,
};

/// Session-owned construction result. Parse scratch may be released immediately.
/// The circuit is immutable once published; analysis clones mutable state.
pub const Prepared = struct {
    circuit: Circuit,
    probes: []const u32,
    probe_labels: []const []const u8,
    source_node: u32,
    source_branch: u32,
    ac_drive: []const f64,
    title: []const u8,
    n_devices: u32,
    ic: []const Ic,
    deck_tol: numerics.Tolerances,
    deck_temp: ?f64,
    deck_method: ?requests.Method,
    queries: []const requests.Query,
    bindings: QueryBindings,
    cards: []const requests.CardRef,
    ac_overrides: []const AcOverride,

    /// The caller owns the arena containing all remaining metadata slices.
    pub fn deinit(self: *Prepared) void {
        self.circuit.deinit();
        self.* = undefined;
    }
};
