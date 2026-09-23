const std = @import("std");

pub const Dialect = enum { ngspice, hspice, spectre };

/// Parsed declarations. Expressions and subcircuit calls are unresolved.
/// All slices borrow source bytes or storage in the parser's arena.
pub const Ast = struct {
    title: []const u8,
    dialect: Dialect,
    devices: []const Device,
    subcircuits: []const Subcircuit,
    models: []const Model,
    directives: []const Directive,
    params: []const Kv,
    foreign: []const Foreign,
};

/// Cold declaration records: expansion reads the ports, defaults, and body together.
pub const Subcircuit = struct {
    name: []const u8,
    ports: []const []const u8,
    defaults: []const Kv,
    devices: []const Device,
};

/// Builder scratch after parameter resolution, expansion, and model selection.
pub const Netlist = struct {
    title: []const u8,
    /// Flattened devices, stably sorted by card letter. AoS: every consumer
    /// reads a device's name, nodes and values together.
    devices: []const Device,
    /// `bucket_starts[c - 'a']` is the first device with letter c; [26] is the length.
    bucket_starts: [27]u32,
    models: []const Model,
    directives: []const Directive,

    pub fn bucket(self: Netlist, c: u8) []const Device {
        return self.devices[self.bucket_starts[c - 'a']..self.bucket_starts[c - 'a' + 1]];
    }
};

pub const Device = struct {
    name: []const u8,
    nodes: []const []const u8,
    positional: []const Value,
    kv: []const Kv,
    subckt_type: u16 = 0,
    subckt_instance: u32 = 0,

    pub fn letter(d: *const Device) u8 {
        return std.ascii.toLower(d.name[0]);
    }
};

pub const Model = struct {
    name: []const u8,
    kind: []const u8,
    kv: []const Kv,
};

pub const Directive = struct {
    kind: []const u8,
    args: []const Value,
};

pub const Kv = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    num: f64,
    name: []const u8,
    expr: *const Expr,
    group: Group,
};

pub const Group = struct {
    name: []const u8,
    args: []const Value,
};

pub const Expr = union(enum) {
    num: f64,
    ident: []const u8,
    call: Call,
    unop: Un,
    binop: Bin,

    pub const Call = struct { name: []const u8, args: []const *const Expr };
    pub const Un = struct { op: u8, a: *const Expr };
    pub const Bin = struct { op: u8, a: *const Expr, b: *const Expr };
};

pub const Foreign = struct {
    kind: ForeignKind,
    path: []const u8,
};

pub const ForeignKind = enum { osdi_include, pre_osdi, verilog_a, verilog };

pub inline fn foreignKindForPath(path: []const u8) ?ForeignKind {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".va") or
        std.ascii.eqlIgnoreCase(ext, ".vams") or
        std.ascii.eqlIgnoreCase(ext, ".veriloga"))
    {
        return .verilog_a;
    }
    if (std.ascii.eqlIgnoreCase(ext, ".v") or std.ascii.eqlIgnoreCase(ext, ".sv"))
        return .verilog;
    return null;
}
