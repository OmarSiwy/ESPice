//! HSPICE MOSRA (dev/analysis/mosra.md): binds the `.appendmodel`ed
//! MOSFETs to their `.model ... MOSRA LEVEL=1` cards and plans the aged runs
//! as variant rows whose `delvto`/`mulu0` values the facade fills from the
//! stress transient.
const std = @import("std");
const core = @import("core");
const device = @import("device");
const netlist = @import("netlist");
const builder = @import("builder");
const analyses = @import("analyses.zig");
const variants = @import("variants.zig");
const Netlist = netlist.Netlist;

/// The resolved `.mosra`, its aged rows and how every card fans out over
/// them. `mosra.tran` is left for the caller, which has the queries.
pub const Plan = struct { mosra: core.Mosra, variants: core.Variants, fanout: analyses.Fanout };

/// Most aged runs one `.mosra` may ask for.
const max_rel_times = 10_000;

/// Resolves `nl.deck.mosra` against the frozen `circuit`, whose card table
/// is `cards` and whose rows `nb` maps nets to. Lives in `sim`; `scratch`
/// holds the lookups. Asserts that `nl.deck.mosra` is set. Every deck the
/// aging cannot bind (a source with no MOSRA card, a MOSFET without `delvto`,
/// more than 10000 times) is `UnsupportedCard`.
pub fn plan(sim: std.mem.Allocator, scratch: std.mem.Allocator, nl: *const Netlist, nb: *const builder.NetBuilder, circuit: *const device.Circuit, cards: []const core.query.CardRef, temp_c: f64) !Plan {
    const card = nl.deck.mosra.?;
    const line = card.line;

    // One MOSRA model per `.appendmodel` source; `dst[k]` is aged by `models[src[k]]`.
    var models: std.ArrayList(core.MosraModel) = .empty;
    var model_names: std.ArrayList([]const u8) = .empty;
    const src = try scratch.alloc(u16, nl.deck.appendmodels.len);
    for (nl.deck.appendmodels, src) |app, *s| {
        s.* = for (model_names.items, 0..) |name, k| {
            if (std.mem.eql(u8, name, app.src)) break @intCast(k);
        } else blk: {
            const row = nl.model_ids.get(app.src) orelse return refuse(line, "an .appendmodel source with no .model card");
            const m = nl.models[row];
            if (!std.ascii.eqlIgnoreCase(m.kind, "mosra")) return refuse(line, "an .appendmodel source that is no MOSRA model");
            try models.append(sim, try readModel(m, line));
            try model_names.append(scratch, app.src);
            break :blk @intCast(models.items.len - 1);
        };
    }

    var by_name: std.StringHashMapUnmanaged(core.query.CardRef) = .empty;
    for (cards) |c| try by_name.put(scratch, c.name, c);
    // `delvto`, `mulu0`, `dtemp` and `temp` of each device, by (type,
    // instance). A VerA device keeps every parameter in its Model, one copy
    // per instance.
    var delvto: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var mulu0: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var dtemp: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var temp_param: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    const params = try variants.collect(scratch, circuit);
    for (params, 0..) |ref, k| {
        const key = refKey(ref.type, ref.index);
        const map = if (std.mem.eql(u8, ref.param_name, "delvto"))
            &delvto
        else if (std.mem.eql(u8, ref.param_name, "mulu0"))
            &mulu0
        else if (std.mem.eql(u8, ref.param_name, "dtemp"))
            &dtemp
        else if (std.mem.eql(u8, ref.param_name, "temp"))
            &temp_param
        else
            continue;
        try map.put(scratch, key, @intCast(k));
    }

    var names: std.ArrayList([]const u8) = .empty;
    var terminals: std.ArrayList([3]u32) = .empty;
    var pmos: std.ArrayList(bool) = .empty;
    var temp_k: std.ArrayList(f64) = .empty;
    var model: std.ArrayList(u16) = .empty;
    var delvto_refs: std.ArrayList(u32) = .empty;
    var mulu0_refs: std.ArrayList(u32) = .empty;
    var delvto_fresh: std.ArrayList(f64) = .empty;
    var mulu0_fresh: std.ArrayList(f64) = .empty;
    for (nl.bucket('m')) |e| {
        const d = nl.device(e);
        const mm = d.model orelse continue;
        const k = for (nl.deck.appendmodels, 0..) |app, k| {
            if (std.mem.eql(u8, app.dst, mm.name) or std.mem.eql(u8, app.dst, binBase(mm.name))) break k;
        } else continue;
        const c = by_name.get(d.name) orelse return refuse(line, "a bound MOSFET that is not in the circuit");
        const key = refKey(c.type, c.index);
        const dv = delvto.get(key) orelse return refuse(line, "a bound MOSFET whose model has no delvto parameter (bsim3, bsim4, BSIM-SOI, mos3 and mos9 have one)");
        const mu = mulu0.get(key) orelse core.Mosra.no_param;
        const md = models.items[src[k]];
        if (mu == core.Mosra.no_param and (md.titmu != 0 or md.hcimu != 0))
            return refuse(line, try std.fmt.allocPrint(scratch, "mobility aging (titmu, hcimu) on {s}, whose model {s} has no mulu0 (only bsim3 has one)", .{ d.name, mm.name }));
        if (d.pins.len < 3) return refuse(line, "a bound MOSFET with fewer than three terminals");
        var t: [3]u32 = undefined;
        for (&t, d.pins[0..3]) |*row, pin| {
            row.* = nb.frozenRow(pin.index());
            if (row.* == netlist.none) return refuse(line, "a bound MOSFET terminal with no circuit row");
        }
        try names.append(sim, try sim.dupe(u8, d.name));
        try terminals.append(sim, t);
        try pmos.append(sim, std.ascii.eqlIgnoreCase(mm.kind, "pmos"));
        // The device's own rule (mos3.va, ngspice): an explicit `temp`
        // wins, else the circuit temperature plus `dtemp`.
        const own = for (d.kv) |kv| {
            if (std.mem.eql(u8, kv.key, "temp")) break temp_param.get(key);
        } else null;
        try temp_k.append(sim, 273.15 + if (own) |r| params[r].get() else temp_c + if (dtemp.get(key)) |r| params[r].get() else 0);
        try model.append(sim, src[k]);
        try delvto_refs.append(sim, dv);
        try mulu0_refs.append(sim, mu);
        try delvto_fresh.append(sim, params[dv].get());
        try mulu0_fresh.append(sim, if (mu == core.Mosra.no_param) 1 else params[mu].get());
    }
    if (names.items.len == 0) return refuse(line, "a .mosra that binds no MOSFET (.appendmodel)");

    var times: std.ArrayList(f64) = .empty;
    if (card.rel_step > 0) {
        var k: f64 = 0;
        while (true) : (k += 1) {
            const t = card.rel_start_time + k * card.rel_step;
            if (t >= card.rel_total_time * (1 - 1e-12)) break;
            if (t > 0) try times.append(sim, t);
            if (times.items.len >= max_rel_times) return refuse(line, "more than 10000 reliability times");
        }
    }
    try times.append(sim, card.rel_total_time);

    const mosra: core.Mosra = .{
        .tran = .{ .t_stop = 0 },
        .rel_times = times.items,
        .aged_runs = card.aged_runs,
        .hci = card.rel_mode != 2,
        .bti = card.rel_mode != 1,
        .aging_start = card.aging_start,
        .aging_stop = card.aging_stop,
        .hci_threshold = card.hci_threshold,
        .bti_threshold = card.nbti_threshold,
        .deg_f = card.deg_f,
        .models = models.items,
        .names = names.items,
        .terminals = terminals.items,
        .pmos = pmos.items,
        .temp_k = temp_k.items,
        .model = model.items,
        .delvto = delvto_refs.items,
        .mulu0 = mulu0_refs.items,
        .delvto_fresh = delvto_fresh.items,
        .mulu0_fresh = mulu0_fresh.items,
    };
    if (!card.aged_runs) return .{ .mosra = mosra, .variants = .{}, .fanout = .{} };

    // One row per reliability time; `age` fills the values.
    const rows: u32 = @intCast(times.items.len);
    const labels = try sim.alloc([]const u8, rows);
    const temps = try sim.alloc(?f64, rows);
    const starts = try sim.alloc(u32, rows + 1);
    var refs: std.ArrayList(u32) = .empty;
    starts[0] = 0;
    for (times.items, labels, temps, starts[1..]) |t, *label, *temp, *start| {
        label.* = try std.fmt.allocPrint(sim, "reltime={d}", .{t});
        temp.* = null;
        for (delvto_refs.items, mulu0_refs.items) |dv, mu| {
            try refs.append(sim, dv);
            if (mu != core.Mosra.no_param) try refs.append(sim, mu);
        }
        start.* = @intCast(refs.items.len);
    }
    return .{
        .mosra = mosra,
        .variants = .{ .labels = labels, .temp_c = temps, .axis = times.items, .starts = starts, .refs = refs.items, .values = try zeros(sim, refs.items.len) },
        .fanout = .{ .global = .{ .first = 0, .count = rows, .nominal = true } },
    };
}

/// Placeholder row values until `Problem.age` writes the aged ones.
fn zeros(sim: std.mem.Allocator, n: usize) ![]f64 {
    const v = try sim.alloc(f64, n);
    @memset(v, 0);
    return v;
}

/// A `.model name MOSRA LEVEL=1 ...` card's parameters; any other level or
/// key is refused.
fn readModel(m: netlist.Model, line: []const u8) !core.MosraModel {
    var md: core.MosraModel = .{};
    for (m.kv) |kv| {
        if (kv.value != .num) return refuse(line, "a MOSRA model value that is not a number");
        const v = kv.value.num;
        if (std.mem.eql(u8, kv.key, "level")) {
            if (v != 1) return refuse(line, "a MOSRA model LEVEL other than 1");
            continue;
        }
        inline for (@typeInfo(core.MosraModel).@"struct".field_names) |name| {
            if (std.mem.eql(u8, kv.key, name)) {
                @field(md, name) = v;
                break;
            }
        } else return refuse(line, "a MOSRA model key other than LEVEL, TIT0, TITFD, TITTD, TN, HCI0, HCIFD, HCITD, HCIN, TITMU, HCIMU");
    }
    if (!(md.tn > 0 and md.hcin > 0 and md.tit0 >= 0 and md.hci0 >= 0)) return refuse(line, "a MOSRA model with TN or HCIN <= 0, or a negative TIT0 or HCI0");
    return md;
}

/// `nch` for a bin card `nch.3`; the name itself otherwise.
fn binBase(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    for (name[dot + 1 ..]) |ch| if (!std.ascii.isDigit(ch)) return name;
    return if (dot + 1 < name.len) name[0..dot] else name;
}

fn refKey(t: core.DeviceType, index: u32) u64 {
    return @as(u64, @backingInt(t)) << 32 | index;
}

fn refuse(line: []const u8, what: []const u8) error{UnsupportedCard} {
    if (!@import("builtin").is_test) std.log.err("netlist: .mosra: {s}: {s}", .{ what, line });
    return error.UnsupportedCard;
}

test binBase {
    try std.testing.expectEqualStrings("nch", binBase("nch.3"));
    try std.testing.expectEqualStrings("nch.a", binBase("nch.a"));
    try std.testing.expectEqualStrings("nch.", binBase("nch."));
    try std.testing.expectEqualStrings("nch", binBase("nch"));
    try std.testing.expectEqualStrings("a.b", binBase("a.b.12"));
}

test refKey {
    const a = refKey(@fromBackingInt(1), 2);
    try std.testing.expect(a != refKey(@fromBackingInt(2), 1));
    try std.testing.expectEqual(@as(u64, 1 << 32 | 2), a);
}

test readModel {
    const kv = netlist.Kv;
    const good = try readModel(.{ .name = "nra", .kind = "mosra", .kv = &[_]kv{
        .{ .key = "level", .value = .{ .num = 1 } },
        .{ .key = "tit0", .value = .{ .num = 1e-4 } },
        .{ .key = "tn", .value = .{ .num = 0.25 } },
    } }, "");
    try std.testing.expectEqual(@as(f64, 1e-4), good.tit0);
    try std.testing.expectEqual(@as(f64, 0.25), good.tn);
    for ([_][]const kv{
        &.{.{ .key = "level", .value = .{ .num = 2 } }},
        &.{.{ .key = "bogus", .value = .{ .num = 1 } }},
        &.{.{ .key = "tit0", .value = .{ .name = "x" } }},
        &.{.{ .key = "tn", .value = .{ .num = 0 } }},
        &.{.{ .key = "tit0", .value = .{ .num = -1 } }},
    }) |pairs| try std.testing.expectError(error.UnsupportedCard, readModel(.{ .name = "nra", .kind = "mosra", .kv = pairs }, ""));
}
