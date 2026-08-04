//! A `Netlist` -> canonical text, one entry per line: the form both sides of
//! the grammar oracle print, so the real frontend and the grammar's lowering
//! are compared as two strings and a mismatch prints as a line diff.
//!
//!     dev <kind> <name> (<pin> ...) <positional> ... {<key>=<value> ...}
//!     model <name> <kind> {<key>=<value> ...}      (top-level models only)
//!     analysis <kind> <arg> ... [sweep]
//!     option <arg> ...          (`temp` instead of `option` for `.temp`)
//!     ic <net> <value>          nodeset <net> <value>
//!
//! Names print as the netlist holds them (lowercased in the SPICE dialects).
//! A number prints at 12 significant digits, so two readings that round a
//! literal or an expression differently in the last ulp still agree.
// ponytail: rounding to 12 digits can split a value sitting on a rounding
// boundary; compare numerically per field if that ever flakes.
const std = @import("std");
const netlist = @import("netlist");
const Netlist = netlist.Netlist;
const Value = netlist.Value;
const Kv = netlist.Kv;
const Writer = std.Io.Writer;

/// Writes every entry of `nl` in canonical form. A device named in `loose`
/// prints as `dev <name> (<pin> ...)`: the oracle checks only its name and
/// pins, since the frontend builds it as another device.
pub fn write(w: *Writer, nl: *const Netlist, loose: *const std.StringHashMapUnmanaged(void)) Writer.Error!void {
    for (0..nl.deviceCount()) |e| {
        const d = nl.device(.from(e));
        if (loose.contains(d.name)) {
            try w.print("dev {s} (", .{d.name});
            for (d.pins, 0..) |p, i| {
                if (i > 0) try w.writeByte(' ');
                try w.writeAll(nl.netName(p));
            }
            try w.writeAll(")\n");
            continue;
        }
        try w.print("dev {c} {s} (", .{ d.kind, d.name });
        for (d.pins, 0..) |p, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(nl.netName(p));
        }
        try w.writeByte(')');
        for (d.positional) |v| {
            try w.writeByte(' ');
            try value(w, v);
        }
        try kvs(w, d.kv);
        try w.writeByte('\n');
    }
    // Top-level models, each name's first card: a subcircuit's own models
    // and the bins they resolve to are rows per instance, checked through
    // the devices that name them.
    for (nl.models, 0..) |m, i| {
        if (nl.model_ids.get(m.name) != @as(u32, @intCast(i))) continue;
        try w.print("model {s} {s}", .{ m.name, m.kind });
        try kvs(w, m.kv);
        try w.writeByte('\n');
    }
    for (nl.deck.analyses) |a| {
        try w.print("analysis {t}", .{a.kind});
        for (a.args) |v| {
            try w.writeByte(' ');
            try value(w, v);
        }
        // The sweep's points are the variant runner's; the card only shows
        // that it has one.
        if (a.sweep != .none) try w.writeAll(" sweep");
        try w.writeByte('\n');
    }
    for (nl.deck.config) |c| {
        try w.writeAll(if (c.temp) "temp" else "option");
        for (c.args) |v| {
            try w.writeByte(' ');
            try value(w, v);
        }
        try w.writeByte('\n');
    }
    for (nl.deck.ic) |ic| try w.print("ic {s} {e:.11}\n", .{ nl.netName(ic.net), ic.value });
    for (nl.deck.nodeset) |ns| try w.print("nodeset {s} {e:.11}\n", .{ nl.netName(ns.net), ns.value });
}

fn kvs(w: *Writer, items: []const Kv) Writer.Error!void {
    if (items.len == 0) return;
    try w.writeAll(" {");
    for (items, 0..) |kv, i| {
        if (i > 0) try w.writeByte(' ');
        try w.print("{s}=", .{kv.key});
        try value(w, kv.value);
    }
    try w.writeByte('}');
}

/// One value: a number, a bare word, `<expr>` for postfix that did not fold
/// (its shape is the expression grammar's business, not the card's), or
/// `name(args)`.
pub fn value(w: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .num => |n| try w.print("{e:.11}", .{n}),
        .name => |s| try w.writeAll(s),
        .expr => try w.writeAll("<expr>"),
        .group => |g| {
            try w.print("{s}(", .{g.name});
            for (g.args, 0..) |a, i| {
                if (i > 0) try w.writeByte(' ');
                try value(w, a);
            }
            try w.writeByte(')');
        },
    }
}
