//! Circuit variants over one prepared circuit: `.step` points, HSPICE
//! `SWEEP`/`.data` points, `.alter` runs, Monte Carlo trials and the live
//! `.param` values a caller sets on a Problem (dev/analysis/variants.md).
//! Each point re-evaluates the netlist's live values (no re-parse),
//! rebinds the devices and keeps only the parameters that moved, as
//! `core.Variants` rows the executor writes through `ParamRef`. A point
//! whose topology moves becomes a `Rebuild` request, which the prepare
//! spine builds as its own run; a live value whose model bins move becomes
//! a new template (`Tuning`).
const std = @import("std");
const core = @import("core");
const device = @import("device");
const netlist = @import("netlist");
const builder = @import("builder");
const analyses = @import("analyses.zig");
const expr = netlist.expr;
const Netlist = netlist.Netlist;
const ParamRef = device.abi.ParamRef;

/// A run's variants: the table, how each card fans out over it, and the
/// runs that need their own circuit, for the caller to build in order.
pub const Plan = struct {
    variants: core.Variants = .{},
    fanout: analyses.Fanout = .{},
    rebuilds: []const Rebuild = &.{},
};

/// Which run of a deck `prepare.buildRun` builds.
pub const Run = struct {
    /// Label of the run's rows: `alter=2`, or a rebuilt point's own.
    prefix: []const u8 = "",
    /// A point whose circuit differs from the nominal one: the run sets
    /// its live values before it builds, and the run is that one row.
    point: ?Point = null,
    /// The point belongs to this analysis card's sweep alone.
    card: ?u32 = null,
};

/// A run the plan could not hold as rows: an `.alter` netlist, or the
/// planned netlist at one point. Both live in the planner's scratch arena.
pub const Rebuild = struct { nl: *Netlist, run: Run };

/// What one point sets, before it becomes a row.
pub const Point = struct {
    label: []const u8,
    axis: f64,
    temp: ?f64 = null,
    /// Every live name's value (`Live.names`).
    live: []const f64,
    /// Card primary values: a source's `dc`, a resistor's `r`.
    cards: []const CardValue = &.{},
    /// Monte Carlo trial, whose draws answer the distribution calls and
    /// the `DEV`/`LOT`/`.variation` rows.
    trial: ?Trial = null,
};

/// A card's primary value for one point, by card name.
pub const CardValue = struct { name: []const u8, value: f64 };

/// True when `deck` asks for variants: `.step`, `.alter` or a card's sweep.
pub fn any(deck: netlist.Deck) bool {
    for (deck.analyses) |a| if (a.sweep != .none) return true;
    return deck.steps.len != 0 or deck.alters.len != 0;
}

/// Plans every variant of `p`'s deck: each card's own sweep, then the
/// `.step` grid, then the `.alter` runs, as rows over `p.nominal` and runs
/// to rebuild where the topology moves. `p.prefix` labels an `.alter`
/// run's rows. `p.nl`'s live values are nominal again on success.
/// `UnsupportedCard` for a combination the plan cannot hold (SWEEP with
/// `.step`, a DC ensemble whose topology moves, a trial number past u32).
pub fn plan(p: *Planner) !Plan {
    const nl = p.nl;
    const deck = nl.deck;
    if (deck.optimize != null) return p.planOptimize();
    var fanout: analyses.Fanout = .{};
    const card_spans = try p.scratch.alloc(analyses.Fanout.Span, deck.analyses.len);
    @memset(card_spans, .{});
    var swept = false;
    for (deck.analyses, card_spans, 0..) |a, *span, ci| {
        if (a.sweep == .none) continue;
        if (deck.steps.len != 0) return p.refuse(a.line, "SWEEP together with .step");
        swept = true;
        span.first = p.count();
        const runs_before = p.rebuilds.items.len;
        const lanes = a.kind == .dc and a.args.len == 0;
        // Only Monte Carlo keeps the nominal run beside its trials.
        span.nominal = a.sweep == .monte and !lanes;
        p.card = @intCast(ci);
        switch (a.sweep) {
            .none, .optimize => unreachable,
            .step => |st| {
                for (st.values) |v| try p.add(try p.stepPoint(&.{st}, &.{v}));
                // `.dc param start stop incr`: the parameter is the axis.
                if (lanes) span.lanes = .{ .axis = switch (st.target) {
                    .param => |k| nl.live.names[k],
                    .card => |c| c,
                    .temp => "temp",
                }, .dc_plot = true };
            },
            .data => |name| {
                const table = for (deck.data) |d| {
                    if (std.mem.eql(u8, d.name, name)) break d;
                } else return p.refuse(a.line, "no such .data table");
                const cols = table.columns.len;
                var row: usize = 0;
                while (row * cols < table.values.len) : (row += 1)
                    try p.addRow(table, table.values[row * cols ..][0..cols]);
                if (lanes) span.lanes = .{ .axis = table.labels[0], .dc_plot = true };
            },
            .monte => |m| if (m.list.len != 0) {
                // A listed trial t is trial t of a `MONTE=max` run, Latin
                // hypercube stratum included.
                // A rebuilt trial draws from it after `plan` returns.
                const sampler = try p.scratch.create(Sampler);
                sampler.* = try .init(p.scratch, deck.config, std.mem.max(u32, m.list));
                for (m.list) |t| try p.addTrial(sampler, t, t - 1);
                if (lanes) span.lanes = .{ .axis = "run", .dc_plot = false };
            } else {
                const sampler = try p.scratch.create(Sampler);
                sampler.* = try .init(p.scratch, deck.config, m.n);
                if (m.n > std.math.maxInt(u32) - m.first + 1) return p.refuse(a.line, "a MONTE trial number past 4294967295");
                for (0..m.n) |k| try p.addTrial(sampler, m.first + @as(u32, @intCast(k)), @intCast(k));
                if (lanes) span.lanes = .{ .axis = "run", .dc_plot = false };
            },
        }
        p.card = null;
        span.count = p.count() - span.first;
        if (lanes and p.rebuilds.items.len != runs_before) return p.refuse(a.line, "a DC ensemble point that changes the topology");
    }
    if (swept) fanout.cards = try p.sim.dupe(analyses.Fanout.Span, card_spans);
    if (deck.steps.len != 0) {
        const values = try p.scratch.alloc(f64, deck.steps.len);
        fanout.global = .{ .first = p.count(), .nominal = false };
        var points: std.ArrayList(Point) = .empty;
        try p.grid(deck.steps, values, 0, &points);
        for (points.items) |pt| try p.add(pt);
        fanout.global.count = p.count() - fanout.global.first;
    }
    if (deck.alters.len != 0) {
        // With other variants, each `.alter` run carries its own: it is a
        // rebuild, adds no row, and the `.step` rows stay the global span
        // (#66).
        const own = swept or deck.steps.len != 0;
        if (!own) fanout.global = .{ .first = p.count(), .nominal = true };
        for (deck.alters, 1..) |text, k| try p.addAlter(text, k, own);
        if (!own) fanout.global.count = p.count() - fanout.global.first;
    }
    if (p.prefix.len != 0 and p.count() == 0) {
        try p.closeRow(p.prefix, 0, null);
        fanout.global = .{ .first = 0, .count = 1, .nominal = false };
    }
    _ = try nl.setLive(p.scratch, &p.stack, nl.live.nominal, null);
    return .{ .variants = try p.table(), .fanout = fanout, .rebuilds = p.rebuilds.items };
}

/// Planning state: the netlist, the nominal circuit's parameters, and the
/// rows and rebuilds so far.
pub const Planner = struct {
    lib: *const device.Library,
    sim: std.mem.Allocator,
    scratch: std.mem.Allocator,
    /// The netlist each point is set on in turn; nominal again when
    /// `plan` returns.
    nl: *Netlist,
    nominal: *const device.Circuit,
    cards: []const core.query.CardRef,
    prefix: []const u8 = "",
    /// Set while a card's own sweep is planned: rebuilt points keep only it.
    card: ?u32 = null,
    refs: []const ParamRef = &.{},
    stack: std.ArrayList(expr.Val) = .empty,
    labels: std.ArrayList([]const u8) = .empty,
    temps: std.ArrayList(?f64) = .empty,
    axes: std.ArrayList(f64) = .empty,
    starts: std.ArrayList(u32) = .empty,
    write_refs: std.ArrayList(u32) = .empty,
    write_values: std.ArrayList(f64) = .empty,
    rebuilds: std.ArrayList(Rebuild) = .empty,
    /// (type, parameter) to the ordinal of its instance 0, for card and
    /// variation writes.
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    /// Each live slot's value in the nominal circuit.
    nominal_slots: []const f64 = &.{},
    /// What the nominal circuit holds that no parameter write reaches. A
    /// run rebuilt at a point opens with that point's values here, not the
    /// deck's, so its own row does not read as moved and rebuild again.
    kept: Kept = .{},
    fast: Fast = .untested,
    /// Rebuild every moved point; the differential test's oracle.
    force_rebuild: bool = false,
    /// The fast path's (slot, parameter) pairs, parallel.
    fast_slots: []const u32 = &.{},
    fast_refs: []const u32 = &.{},
    /// Per parameter, its write's index in the open row, or `none`.
    row_at: []u32 = &.{},
    targets: ?Targets = null,

    const Targets = struct { starts: []const u32, ords: []const u32, keys: []const u64 };

    const Fast = enum { untested, identity, rebuild };

    /// A planner over `nl`, whose nominal circuit is `nominal` with card
    /// table `cards`; `prefix` labels an `.alter` run's rows.
    pub fn init(lib: *const device.Library, sim: std.mem.Allocator, scratch: std.mem.Allocator, nl: *Netlist, nominal: *const device.Circuit, cards: []const core.query.CardRef, prefix: []const u8) !Planner {
        var p: Planner = .{ .lib = lib, .sim = sim, .scratch = scratch, .nl = nl, .nominal = nominal, .cards = cards, .prefix = prefix };
        p.refs = try collect(scratch, nominal);
        p.row_at = try scratch.alloc(u32, p.refs.len);
        @memset(p.row_at, netlist.none);
        try p.starts.append(scratch, 0);
        const nominal_slots = try scratch.alloc(f64, nl.live.slots.len);
        for (nominal_slots, 0..) |*v, k| v.* = nl.slot(k).num;
        p.nominal_slots = nominal_slots;
        p.kept = try .of(scratch, nl);
        return p;
    }

    fn count(p: *const Planner) u32 {
        return @intCast(p.labels.items.len);
    }

    fn refuse(p: *const Planner, line: []const u8, what: []const u8) error{UnsupportedCard} {
        _ = p;
        if (!@import("builtin").is_test) std.log.err("variants: {s}: {s}", .{ what, line });
        return error.UnsupportedCard;
    }

    /// HSPICE `OPTIMIZE=`, once per base point (`bases`: each `.step`
    /// point, or the nominal one). With S of them, rows 0..S are the
    /// optimized card's and S..2S every later card's: the base point's
    /// writes, which the optimum's replace once its optimizer has run
    /// (`Tuner`). Under `.step`, rows 2S..3S run the earlier cards at the
    /// initial values; without it they run nominal.
    fn planOptimize(p: *Planner) !Plan {
        const deck = p.nl.deck;
        const bases = try p.basePoints();
        const n: u32 = @intCast(bases.len);
        const stepped = deck.steps.len != 0;
        const spans = try p.sim.alloc(analyses.Fanout.Span, deck.analyses.len);
        var card: ?u32 = null;
        for (deck.analyses, spans, 0..) |a, *span, ci| {
            if (a.sweep == .optimize) card = @intCast(ci) else if (a.sweep != .none) return p.refuse(a.line, "OPTIMIZE together with another SWEEP");
            const block: ?u32 = if (card) |c| @intFromBool(c != ci) else if (stepped) 2 else null;
            span.* = if (block) |b| .{ .first = b * n, .count = n, .nominal = false } else .{};
        }
        if (deck.alters.len != 0) return p.refuse(deck.analyses[card.?].line, "OPTIMIZE together with .alter");
        for (0..@as(u32, if (stepped) 3 else 2)) |block| for (bases) |pt| {
            var row = pt;
            if (block < 2) row.label = if (pt.label.len == 0)
                try std.fmt.allocPrint(p.scratch, "optimize={s}", .{deck.optimize.?.name})
            else
                try std.fmt.allocPrint(p.scratch, "optimize={s}, {s}", .{ deck.optimize.?.name, pt.label });
            try p.add(row);
        };
        if (p.rebuilds.items.len != 0) return p.refuse(deck.analyses[card.?].line, "OPTIMIZE over a .step point that changes the topology");
        return .{ .variants = try p.table(), .fanout = .{ .cards = spans } };
    }

    /// The points an optimization runs from: each `.step` point, or the
    /// nominal one.
    fn basePoints(p: *Planner) ![]const Point {
        const steps = p.nl.deck.steps;
        var out: std.ArrayList(Point) = .empty;
        if (steps.len == 0) {
            try out.append(p.scratch, .{ .label = "", .axis = 0, .live = p.nl.live.nominal });
        } else try p.grid(steps, try p.scratch.alloc(f64, steps.len), 0, &out);
        return out.items;
    }

    /// The rows so far, copied into the session arena.
    pub fn table(p: *Planner) !core.Variants {
        return .{
            .labels = try p.sim.dupe([]const u8, p.labels.items),
            .temp_c = try p.sim.dupe(?f64, p.temps.items),
            .axis = try p.sim.dupe(f64, p.axes.items),
            .starts = try p.sim.dupe(u32, p.starts.items),
            .refs = try p.sim.dupe(u32, p.write_refs.items),
            .values = try p.sim.dupe(f64, p.write_values.items),
        };
    }

    /// The `.step` cartesian product from card `depth` on, appended to
    /// `out`; the last card varies fastest.
    fn grid(p: *Planner, steps: []const netlist.Step, values: []f64, depth: usize, out: *std.ArrayList(Point)) !void {
        if (depth == steps.len) return out.append(p.scratch, try p.stepPoint(steps, values));
        for (steps[depth].values) |v| {
            values[depth] = v;
            try p.grid(steps, values, depth + 1, out);
        }
    }

    /// The point setting `steps[i]`'s target to `values[i]`.
    fn stepPoint(p: *Planner, steps: []const netlist.Step, values: []const f64) !Point {
        const live = try p.scratch.dupe(f64, p.nl.live.nominal);
        var pt: Point = .{ .label = "", .axis = values[0], .live = live };
        var label: std.ArrayList(u8) = .empty;
        var cards: std.ArrayList(CardValue) = .empty;
        for (steps, values) |st, v| {
            if (label.items.len != 0) try label.appendSlice(p.scratch, ", ");
            try label.print(p.scratch, "{s}={d}", .{ targetName(p.nl, st.target), v });
            switch (st.target) {
                .param => |k| live[k] = v,
                .temp => pt.temp = v,
                .card => |name| try cards.append(p.scratch, .{ .name = name, .value = v }),
            }
        }
        pt.label = label.items;
        pt.cards = cards.items;
        return pt;
    }

    /// One `.data` row.
    fn addRow(p: *Planner, data: netlist.Data, row: []const f64) !void {
        const live = try p.scratch.dupe(f64, p.nl.live.nominal);
        var pt: Point = .{ .label = "", .axis = row[0], .live = live };
        var label: std.ArrayList(u8) = .empty;
        var cards: std.ArrayList(CardValue) = .empty;
        for (data.columns, data.labels, row) |col, name, v| {
            if (label.items.len != 0) try label.appendSlice(p.scratch, ", ");
            try label.print(p.scratch, "{s}={d}", .{ name, v });
            switch (col) {
                .param => |k| live[k] = v,
                .temp => pt.temp = v,
                .card => |card| try cards.append(p.scratch, .{ .name = card, .value = v }),
            }
        }
        pt.label = label.items;
        pt.cards = cards.items;
        try p.add(pt);
    }

    fn addTrial(p: *Planner, sampler: *Sampler, trial: u32, index: u32) !void {
        try p.add(.{
            .label = try std.fmt.allocPrint(p.scratch, "monte={d}", .{trial}),
            .axis = @floatFromInt(trial),
            .live = p.nl.live.nominal,
            .trial = .{ .sampler = sampler, .trial = trial, .index = index },
        });
    }

    /// `.alter` run `k`. Without variants of its own, a run whose circuit
    /// matches the nominal one becomes a row; otherwise it is a rebuild
    /// that plans its own variants.
    fn addAlter(p: *Planner, text: []const u8, k: usize, own: bool) !void {
        const label = try std.fmt.allocPrint(p.sim, "alter={d}", .{k});
        const alt = try p.scratch.create(Netlist);
        alt.* = try netlist.parse(p.scratch, text, p.nl.deck.dialect);
        if (!own and sameCards(p.nl, alt)) {
            var arena = std.heap.ArenaAllocator.init(core.gpa);
            defer arena.deinit();
            var c = try circuitOf(p.lib, arena.allocator(), arena.allocator(), alt);
            defer c.deinit();
            if (sameTopology(p.nominal, &c)) {
                try p.diff(arena.allocator(), &c);
                return p.closeRow(label, @floatFromInt(k), null);
            }
        }
        try p.rebuilds.append(p.scratch, .{ .nl = alt, .run = .{ .prefix = label } });
    }

    /// Turns `pt` into a row, or into a rebuild when its live values
    /// change the topology or storage `ParamRef` cannot reach.
    pub fn add(p: *Planner, pt: Point) !void {
        const label = if (p.prefix.len == 0) try p.sim.dupe(u8, pt.label) else try std.fmt.allocPrint(p.sim, "{s}, {s}", .{ p.prefix, pt.label });
        if (try p.load(pt, label) == .circuit) return p.addRun(label, pt);
        try p.pointWrites(pt);
        try p.closeRow(label, pt.axis, pt.temp);
    }

    const Load = enum { row, circuit };

    /// Sets `pt`'s live values (and the bins they pick), then appends to
    /// the open row the parameter writes that turn the nominal circuit into
    /// it. `.circuit` when only a circuit of its own can hold the point: a
    /// model bin moved, a kept expression reads a moved value, or the
    /// topology changed; the open row is then partial. `UnsupportedCard`
    /// (naming `label`) when a top-level `.if` would take another branch.
    fn load(p: *Planner, pt: Point, label: []const u8) !Load {
        // ponytail: a point that flips a top-level `.if` is refused; re-parse
        // it as its own run if a deck needs branch selection per point.
        for (p.nl.live.conds) |span| {
            const ops = p.nl.exprOps(span);
            const at = try expr.eval(p.scratch, &p.stack, ops, p.nl.consts, pt.live, null);
            const nominal = try expr.eval(p.scratch, &p.stack, ops, p.nl.consts, p.nl.live.nominal, null);
            if ((at != 0) != (nominal != 0)) return p.refuse(label, "a top-level .if condition reads a swept parameter and selects another branch at this point");
        }
        try p.setLive(pt);
        var moved = false;
        var crossed = false;
        for (p.nominal_slots, 0..) |nominal, k| {
            const x = p.nl.slot(k).num;
            moved = moved or x != nominal;
            crossed = crossed or crossesZero(nominal, x);
        }
        if (!p.kept.holds(p.nl)) return .circuit;
        if (!moved) return .row;
        if (p.fast == .untested) p.fast = try p.probe(pt);
        // A value that reaches or leaves zero may collapse a node: only a
        // rebuild can tell.
        if (p.fast == .identity and !crossed) {
            for (p.fast_slots, p.fast_refs) |k, r| {
                const x = p.nl.slot(k).num;
                if (@as(u64, @bitCast(x)) != @as(u64, @bitCast(p.refs[r].get()))) try p.set(r, x);
            }
            return .row;
        }
        // The rebuild's tables die with it, so a long run of points does
        // not grow `scratch`.
        var arena = std.heap.ArenaAllocator.init(core.gpa);
        defer arena.deinit();
        var c = try circuitOf(p.lib, arena.allocator(), arena.allocator(), p.nl);
        defer c.deinit();
        if (!sameTopology(p.nominal, &c)) return .circuit;
        try p.diff(arena.allocator(), &c);
        return .row;
    }

    fn setLive(p: *Planner, pt: Point) !void {
        try setPoint(p.scratch, &p.stack, p.nl, pt);
    }

    /// Finds, with one rebuild at perturbed live values, whether every
    /// parameter the live values reach holds one of them unchanged. Then a
    /// point writes its values straight to those parameters (the C2 fast
    /// path); otherwise each point rebinds the netlist and diffs. `pt` is
    /// the point being added; its values are restored.
    fn probe(p: *Planner, pt: Point) !Fast {
        if (p.force_rebuild) return .rebuild;
        const fast = try p.probeIdentity();
        try p.setLive(pt);
        return fast;
    }

    fn probeIdentity(p: *Planner) !Fast {
        const probe_at = try p.scratch.alloc(f64, p.nominal_slots.len);
        var by_bits: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer by_bits.deinit(p.scratch);
        for (probe_at, p.nominal_slots, 0..) |*x, nominal, k| {
            if (!std.math.isFinite(nominal)) return .rebuild;
            // A zero slot stays put and maps nothing: a point that moves it
            // crosses zero, which `load` rebuilds anyway (#130).
            if (nominal == 0) {
                x.* = 0;
                continue;
            }
            // A distinct nearby value per slot, far from any rounding tie.
            x.* = nominal * (1 + @as(f64, @floatFromInt(k + 1)) * 0x1.0p-24);
            const gop = try by_bits.getOrPut(p.scratch, @bitCast(x.*));
            if (gop.found_existing) return .rebuild;
            gop.value_ptr.* = @intCast(k);
        }
        p.nl.setSlots(probe_at);
        var arena = std.heap.ArenaAllocator.init(core.gpa);
        defer arena.deinit();
        var c = try circuitOf(p.lib, arena.allocator(), arena.allocator(), p.nl);
        defer c.deinit();
        if (!sameTopology(p.nominal, &c)) return .rebuild;
        const moved = try collect(arena.allocator(), &c);
        var pair_slots: std.ArrayList(u32) = .empty;
        var pair_refs: std.ArrayList(u32) = .empty;
        for (p.refs, moved, 0..) |a, b, i| {
            const before = a.get();
            const after = b.get();
            if (@as(u64, @bitCast(before)) == @as(u64, @bitCast(after))) continue;
            const k = by_bits.get(@bitCast(after)) orelse return .rebuild;
            if (@as(u64, @bitCast(before)) != @as(u64, @bitCast(p.nominal_slots[k]))) return .rebuild;
            try pair_slots.append(p.scratch, k);
            try pair_refs.append(p.scratch, @intCast(i));
        }
        p.fast_slots = pair_slots.items;
        p.fast_refs = pair_refs.items;
        return .identity;
    }

    fn closeRow(p: *Planner, label: []const u8, axis: f64, temp: ?f64) !void {
        for (p.write_refs.items[p.starts.items[p.starts.items.len - 1]..]) |r| p.row_at[r] = netlist.none;
        try p.labels.append(p.scratch, label);
        try p.axes.append(p.scratch, axis);
        try p.temps.append(p.scratch, temp);
        try p.starts.append(p.scratch, @intCast(p.write_refs.items.len));
    }

    /// A point with its own circuit, rebuilt from the netlist at `pt`.
    fn addRun(p: *Planner, label: []const u8, pt: Point) !void {
        try p.rebuilds.append(p.scratch, .{ .nl = p.nl, .run = .{ .prefix = label, .point = pt, .card = p.card } });
    }

    /// Appends a write for every parameter `c` holds at another value;
    /// `scratch` holds `c`'s parameter table.
    fn diff(p: *Planner, scratch: std.mem.Allocator, c: *const device.Circuit) !void {
        const moved = try collect(scratch, c);
        for (p.refs, moved, 0..) |a, b, i| {
            const x = b.get();
            if (@as(u64, @bitCast(a.get())) == @as(u64, @bitCast(x))) continue;
            try p.set(@intCast(i), x);
        }
    }

    /// Card values and Monte Carlo variations of `pt`, over the open
    /// row's writes.
    fn pointWrites(p: *Planner, pt: Point) !void {
        for (pt.cards) |cv| try p.set(try p.cardRef(cv.name), cv.value);
        const trial = pt.trial orelse return;
        const targets = try p.variationTargets();
        for (p.nl.deck.variations, 0..) |v, i| {
            for (targets.ords[targets.starts[i]..targets.starts[i + 1]], targets.keys[targets.starts[i]..targets.starts[i + 1]]) |ord, key| {
                const base = p.current(ord);
                const u = trial.uniform(key);
                const spread = try p.spreadOf(v, ord, base);
                const x = switch (v.dist) {
                    .gauss => base + spread * normalQuantile(u),
                    .unif => base + spread * (2 * u - 1),
                    .limit => base + (if (u < 0.5) -spread else spread),
                };
                try p.set(ord, x);
            }
        }
    }

    /// The parameters each `.variation`/`DEV`/`LOT` row moves and the site
    /// each draws from, CSR by row; found on the first trial.
    fn variationTargets(p: *Planner) !Targets {
        if (p.targets) |t| return t;
        var by_card: std.StringHashMapUnmanaged(core.query.CardRef) = .empty;
        for (p.cards) |c| try by_card.put(p.scratch, c.name, c);
        var starts: std.ArrayList(u32) = .empty;
        var ords: std.ArrayList(u32) = .empty;
        var keys: std.ArrayList(u64) = .empty;
        try starts.append(p.scratch, 0);
        for (p.nl.deck.variations) |v| {
            const lot = netlist.siteKey(std.hash.Wyhash.hash(0, v.model), std.hash.Wyhash.hash(1, v.param));
            for (p.nl.order) |e| {
                const dev = p.nl.device(e);
                const hit = if (v.letter != 0) dev.kind == v.letter else if (dev.model) |m| std.mem.eql(u8, m.name, v.model) else false;
                if (!hit) continue;
                const card = by_card.get(dev.name) orelse continue;
                try ords.append(p.scratch, try p.paramRef(card.type, card.index, v.param));
                try keys.append(p.scratch, if (v.per_device) netlist.siteKey(std.hash.Wyhash.hash(2, dev.name), std.hash.Wyhash.hash(3, v.param)) else lot);
            }
            try starts.append(p.scratch, @intCast(ords.items.len));
        }
        p.targets = .{ .starts = starts.items, .ords = ords.items, .keys = keys.items };
        return p.targets.?;
    }

    /// The `.variation`/`DEV`/`LOT` rows as mismatch and sensitivity
    /// groups: a per-device row is one group per device it reaches
    /// (`<card>@<param>`), a per-model row one group over all of them
    /// (`<model>@<param>`). A member's step is one sigma: the row's value
    /// (times the nominal when relative), over sqrt(3) for a uniform spread
    /// and the half range itself for `limit`.
    pub fn variations(p: *Planner) !core.query.Variations {
        const targets = try p.variationTargets();
        var labels: std.ArrayList([]const u8) = .empty;
        var starts: std.ArrayList(u32) = .empty;
        var params: std.ArrayList(u32) = .empty;
        var sigmas: std.ArrayList(f64) = .empty;
        try starts.append(p.sim, 0);
        for (p.nl.deck.variations, 0..) |v, i| {
            const ords = targets.ords[targets.starts[i]..targets.starts[i + 1]];
            if (ords.len == 0) continue;
            for (ords) |ord| {
                const r = p.refs[ord];
                const spread = try p.spreadOf(v, ord, r.get());
                try params.append(p.sim, ord);
                try sigmas.append(p.sim, if (v.dist == .unif) spread / @sqrt(3.0) else spread);
                if (!v.per_device) continue;
                const card = core.query.CardRef.lookup(p.cards, r.type, r.index) orelse "?";
                try labels.append(p.sim, try std.fmt.allocPrint(p.sim, "{s}@{s}", .{ card, v.param }));
                try starts.append(p.sim, @intCast(params.items.len));
            }
            if (v.per_device) continue;
            try labels.append(p.sim, try std.fmt.allocPrint(p.sim, "{s}@{s}", .{ v.model, v.param }));
            try starts.append(p.sim, @intCast(params.items.len));
        }
        if (labels.items.len == 0) return .{};
        return .{ .labels = labels.items, .starts = starts.items, .params = params.items, .sigmas = sigmas.items };
    }

    /// The deck's own mismatch as groups, for a deck with no `.variation`
    /// block: one group per distribution site the circuit reads, whose
    /// members are the parameters a one-sigma draw there moves, each
    /// scaled by its move (#100). This is how a PDK such as sky130 states
    /// mismatch (`agauss` in its model cards). A site that moves no
    /// parameter (sky130's `mc_mm_switch=0`) is no group, and no group at
    /// all is an empty table, never the unit-variance fallback. The live
    /// values are nominal again on return.
    pub fn siteVariations(p: *Planner) !core.query.Variations {
        const live = p.nl.live;
        std.debug.assert(live.site_keys.len == live.site_ops.len);
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        var labels: std.ArrayList([]const u8) = .empty;
        var starts: std.ArrayList(u32) = .empty;
        var params: std.ArrayList(u32) = .empty;
        var steps: std.ArrayList(f64) = .empty;
        try starts.append(p.sim, 0);
        if (p.fast == .untested) p.fast = if (p.force_rebuild) .rebuild else try p.probeIdentity();
        // The steps are taken from every draw at its nominal, which under
        // `.option seed` is not the circuit's own state.
        _ = try p.nl.setLive(p.scratch, &p.stack, live.nominal, null);
        const base_slots = try p.scratch.alloc(f64, live.slots.len);
        for (base_slots, 0..) |*x, k| x.* = p.nl.slot(k).num;
        var base_arena = std.heap.ArenaAllocator.init(core.gpa);
        defer base_arena.deinit();
        var base_c = try circuitOf(p.lib, base_arena.allocator(), base_arena.allocator(), p.nl);
        defer base_c.deinit();
        const base_refs = try collect(base_arena.allocator(), &base_c);
        // Only a site inside a live slot reaches a device; the others sit in
        // model cards no instance binds (a PDK's unused bins).
        for (live.ops) |span| for (live.site_ops, live.site_keys) |op, key| {
            if (op < span.start or op >= span.start + span.len) continue;
            if ((try seen.getOrPut(p.scratch, key)).found_existing) continue;
            _ = try p.nl.setLive(p.scratch, &p.stack, live.nominal, OneSigma{ .site = key });
            const first = params.items.len;
            const crossed = for (base_slots, 0..) |x, k| {
                if (crossesZero(x, p.nl.slot(k).num)) break true;
            } else false;
            // The probe's slot-to-parameter map gives the steps without a
            // rebuild, unless the draw takes a slot across zero (#130).
            if (p.fast == .identity and !crossed) {
                for (p.fast_slots, p.fast_refs) |k, ord| {
                    const step = p.nl.slot(k).num - base_slots[k];
                    if (step == 0) continue;
                    try params.append(p.sim, ord);
                    try steps.append(p.sim, step);
                }
            } else {
                var arena = std.heap.ArenaAllocator.init(core.gpa);
                defer arena.deinit();
                var c = try circuitOf(p.lib, arena.allocator(), arena.allocator(), p.nl);
                defer c.deinit();
                if (!sameTopology(p.nominal, &c)) return p.refuse("", "a one-sigma mismatch draw that changes the topology");
                for (base_refs, try collect(arena.allocator(), &c), 0..) |x, y, ord| {
                    const step = y.get() - x.get();
                    if (step == 0) continue;
                    try params.append(p.sim, @intCast(ord));
                    try steps.append(p.sim, step);
                }
            }
            if (params.items.len == first) continue;
            const r = p.refs[params.items[first]];
            const card = core.query.CardRef.lookup(p.cards, r.type, r.index) orelse "?";
            try labels.append(p.sim, try std.fmt.allocPrint(p.sim, "{s}@{s}", .{ card, r.param_name }));
            try starts.append(p.sim, @intCast(params.items.len));
        };
        _ = try p.nl.setLive(p.scratch, &p.stack, live.nominal, null);
        std.debug.assert(starts.items.len == labels.items.len + 1);
        return .{ .labels = labels.items, .starts = starts.items, .params = params.items, .sigmas = steps.items };
    }

    /// Row `v`'s sigma (or half range) at parameter `ord` whose value is
    /// `base`: its number, or its expression over the device's `w`, `l`
    /// and `m`, times `base` when relative. `UnsupportedCard` when the
    /// expression is not finite there (a `w` or `l` the device lacks).
    fn spreadOf(p: *Planner, v: netlist.Variation, ord: u32, base: f64) !f64 {
        var spread = v.value;
        if (v.sigma.len != 0) {
            const r = p.refs[ord];
            var at: [netlist.Variation.sigma_names.len]f64 = undefined;
            for (netlist.Variation.sigma_names, &at) |name, *x| x.* = p.instanceValue(r, name) orelse
                if (name[0] == 'm') p.instanceValue(r, "mfactor") orelse 1 else std.math.nan(f64);
            spread *= try expr.eval(p.scratch, &p.stack, p.nl.exprOps(v.sigma), p.nl.consts, &at, null);
            if (!std.math.isFinite(spread)) return p.refuse(v.param, "a .variation sigma that is not a finite number at this device");
        }
        return if (v.relative) spread * base else spread;
    }

    /// Instance parameter `name` of the device that owns `r`, or null.
    fn instanceValue(p: *Planner, r: ParamRef, name: []const u8) ?f64 {
        const ord = p.paramRef(r.type, r.index, name) catch return null;
        return p.refs[ord].get();
    }

    /// The value parameter `ord` has in the open row.
    fn current(p: *Planner, ord: u32) f64 {
        const at = p.row_at[ord];
        return if (at != netlist.none) p.write_values.items[at] else p.refs[ord].get();
    }

    /// Writes `value` to `ord` in the open row, once per parameter.
    fn set(p: *Planner, ord: u32, value: f64) !void {
        if (p.row_at[ord] != netlist.none) {
            p.write_values.items[p.row_at[ord]] = value;
            return;
        }
        p.row_at[ord] = @intCast(p.write_refs.items.len);
        try p.write_refs.append(p.scratch, ord);
        try p.write_values.append(p.scratch, value);
    }

    /// The ordinal of card `name`'s primary value, as `.dc` sweeps it.
    fn cardRef(p: *Planner, name: []const u8) !u32 {
        const target = try analyses.dcTarget(&.{.{ .name = name }}, 0, p.cards);
        const d = switch (target) {
            .device => |d| d,
            .temp => unreachable,
        };
        return p.paramRef(d.type, d.index, d.param_name);
    }

    fn paramRef(p: *Planner, t: core.DeviceType, index: u32, name: []const u8) !u32 {
        if (p.by_name.count() == 0) for (p.refs, 0..) |r, i| {
            const gop = try p.by_name.getOrPut(p.scratch, try refKey(p.scratch, r.type, r.param_name));
            if (!gop.found_existing) gop.value_ptr.* = @intCast(i - r.index);
        };
        const first = p.by_name.get(try refKey(p.scratch, t, name)) orelse return error.UnknownParameter;
        const ord = first + index;
        if (ord >= p.refs.len or p.refs[ord].index != index or p.refs[ord].type != t) return error.UnknownParameter;
        return ord;
    }
};

/// Whether a slot that held `a` reaches, leaves or crosses zero at `b`,
/// which may collapse a node: only a rebuild can tell.
fn crossesZero(a: f64, b: f64) bool {
    return (a == 0) != (b == 0) or (a < 0) != (b < 0);
}

/// What a circuit holds that no parameter write reaches, read off the
/// netlist it was built from: each binned card's model row (bins differ in
/// which model parameters they give) and each constant-pool row a kept
/// expression reads (a B source's tape is not `ParamRef` storage). A point
/// that moves any of them needs a circuit of its own.
const Kept = struct {
    bins: []const u32 = &.{},
    /// `Live.pool_rows` then `Live.site_rows`, `none` rows read as 0.
    pool: []const f64 = &.{},

    /// The netlist's current values, allocated in `gpa`.
    fn of(gpa: std.mem.Allocator, nl: *const Netlist) !Kept {
        const live = nl.live;
        const bins = try gpa.alloc(u32, live.bins.edges.len);
        const model_of = nl.graph.edges.items(.model);
        for (bins, live.bins.edges) |*row, e| row.* = model_of[e];
        const pool = try gpa.alloc(f64, live.pool_rows.len + live.site_rows.len);
        for (pool[0..live.pool_rows.len], live.pool_rows) |*v, row| v.* = if (row == netlist.none) 0 else nl.consts[row];
        for (pool[live.pool_rows.len..], live.site_rows) |*v, row| v.* = nl.consts[row];
        return .{ .bins = bins, .pool = pool };
    }

    /// Whether `nl` at its current values still holds `k` bit for bit.
    fn holds(k: Kept, nl: *const Netlist) bool {
        const live = nl.live;
        std.debug.assert(k.bins.len == live.bins.edges.len);
        std.debug.assert(k.pool.len == live.pool_rows.len + live.site_rows.len);
        const model_of = nl.graph.edges.items(.model);
        for (k.bins, live.bins.edges) |row, e| if (model_of[e] != row) return false;
        // By value: a `0*agauss(...)` row is -0 or +0 by the draw's sign,
        // the same number to the tape.
        for (k.pool[0..live.pool_rows.len], live.pool_rows) |v, row| if (row != netlist.none and v != nl.consts[row]) return false;
        for (k.pool[live.pool_rows.len..], live.site_rows) |v, row| if (v != nl.consts[row]) return false;
        return true;
    }
};

/// Turns optimizer points into variant rows (HSPICE `OPTIMIZE=`,
/// dev/analysis/optimize.md): each point sets the optimized parameters'
/// live values and goes through `Planner.add`, so it takes the same
/// probe-mapped fast path as a `.step` point. Lives in the parse arena,
/// with the netlist it re-evaluates.
pub const Tuner = struct {
    planner: Planner,
    /// The optimized card's index in the deck's analyses.
    card: u32,
    /// The optimization, its parameters' initial values and names, and
    /// the `.model OPT` options.
    spec: netlist.Optimize,
    initial: []const f64,
    names: []const []const u8,
    options: core.lm.Options,
    method: core.bisect.Method,
    /// The RESULTS cards' indices in the deck's `.meas` cards.
    results: []const u32,
    /// The points each optimization starts from (`Planner.basePoints`): one
    /// optimization per `.step` point.
    bases: []const Point,

    /// A tuner over the planner of the deck's main run. Asserts that the
    /// deck has an optimization and a card with `SWEEP OPTIMIZE=`;
    /// `UnsupportedCard` for RESULTS or `.model OPT` settings it cannot run.
    pub fn init(planner: Planner) !Tuner {
        var pl = planner;
        const nl = planner.nl;
        const spec = nl.deck.optimize.?;
        const card: u32 = for (nl.deck.analyses, 0..) |a, ci| {
            if (a.sweep == .optimize) break @intCast(ci);
        } else unreachable;
        const init_values = try planner.scratch.alloc(f64, spec.live.len);
        const names = try planner.scratch.alloc([]const u8, spec.live.len);
        for (spec.live, init_values, names) |k, *v, *name| {
            v.* = nl.live.nominal[k];
            name.* = nl.live.names[k];
        }
        const line = nl.deck.analyses[card].line;
        const results = try planner.scratch.alloc(u32, spec.results.len);
        for (spec.results, results) |name, *index| {
            index.* = for (nl.deck.measures, 0..) |m, i| {
                if (std.mem.eql(u8, m.name, name) and m.analysis == nl.deck.analyses[card].kind and m.goalError(0) != null) break @intCast(i);
            } else return planner.refuse(line, "a RESULTS name that is no .meas card of this analysis with GOAL=");
        }
        const options, const method = try optOptions(nl, spec.model, line);
        // ponytail: one parameter and one RESULTS card for a bisection; the
        // manual's AND over several bisected parameters is not specified.
        if (method != .lm and (spec.live.len != 1 or results.len != 1)) return planner.refuse(line, "a bisection over more than one parameter or RESULTS card");
        // A bisection passes on the sign of the goal error, which an inequality goal zeroes.
        const goal = nl.deck.measures[results[0]];
        if (method != .lm and (if (goal.first.goal != null) goal.first else goal.second).goal_bound != .equal) return planner.refuse(line, "a bisection on a GOAL < or GOAL > card");
        return .{ .planner = planner, .card = card, .spec = spec, .initial = init_values, .names = names, .options = options, .method = method, .results = results, .bases = try pl.basePoints() };
    }

    /// One row per point of `points` (the optimized parameters' values,
    /// `spec.live.len` per point) on top of `bases[base]`, allocated in
    /// `arena`. `nominal` is the prepared circuit the rows write into.
    /// Resets the planner's rows, so a table from an earlier call stays
    /// valid (it was copied out) but the planner no longer holds it.
    pub fn rows(t: *Tuner, arena: std.mem.Allocator, nominal: *const device.Circuit, points: []const f64, base: usize) !core.Variants {
        const p = &t.planner;
        p.nominal = nominal;
        p.sim = arena;
        inline for (.{ &p.labels, &p.temps, &p.axes, &p.write_refs, &p.write_values }) |list| list.clearRetainingCapacity();
        p.starts.shrinkRetainingCapacity(1);
        const b = t.bases[base];
        const live = try arena.dupe(f64, b.live);
        const n = t.spec.live.len;
        var at: usize = 0;
        while (at < points.len) : (at += n) {
            for (t.spec.live, points[at..][0..n]) |k, v| live[k] = v;
            try p.add(.{ .label = "", .axis = 0, .live = live, .temp = b.temp, .cards = b.cards });
            if (p.rebuilds.items.len != 0) return p.refuse(p.nl.deck.analyses[t.card].line, "an optimized value that changes the topology");
        }
        return p.table();
    }

    /// `planned` (the deck's variant table) with each optimum installed:
    /// rows `0..n` and `n..2n` take `best[v % n]`'s writes, one optimum per
    /// `bases` entry (`n = best.len`), and the rows after keep the plan's.
    /// Labels, temperatures and axes stay the plan's. Allocated in `arena`.
    pub fn optimized(arena: std.mem.Allocator, planned: core.Variants, best: []const core.Variants) !core.Variants {
        const n = best.len;
        var starts: std.ArrayList(u32) = .empty;
        var refs: std.ArrayList(u32) = .empty;
        var values: std.ArrayList(f64) = .empty;
        try starts.append(arena, 0);
        for (0..planned.starts.len - 1) |v| {
            const w_refs, const w_values = if (v < 2 * n) best[v % n].writes(0) else planned.writes(@intCast(v));
            try refs.appendSlice(arena, w_refs);
            try values.appendSlice(arena, w_values);
            try starts.append(arena, @intCast(refs.items.len));
        }
        var out = planned;
        out.starts = starts.items;
        out.refs = refs.items;
        out.values = values.items;
        return out;
    }
};

/// Global `.param` values set on a prepared circuit (`Problem.set_params`,
/// #101; dev/analysis/variants.md §5). Each call re-evaluates the netlist
/// at the new values as a `.step` point does, never re-parsing, and becomes
/// one more row of the deck's variant table over the current template:
/// the probe-mapped writes or a rebuild's diff. When no writes can make the
/// point (a model bin moved, or a kept expression reads a moved value) the
/// row and later rows run on an earlier template that holds the point's
/// bins and kept values, or else on the circuit built at it, so the
/// templates are bounded by the distinct bin selections visited (#129).
/// Lives in the parse arena, with the netlist it re-evaluates.
pub const Tuning = struct {
    gpa: std.mem.Allocator,
    /// The planner's tables, in `arenas[current]`; a planner re-opened over
    /// another template builds in the other one, so a failure keeps the old.
    arenas: [2]std.heap.ArenaAllocator,
    current: u1 = 0,
    planner: Planner,
    /// The template the planner is open over; it differs from `template`
    /// only after a call failed past re-opening it.
    planned: u32 = 0,
    /// Every live name's value now, and the call's candidate values.
    values: []f64,
    next: []f64,
    /// The `.option seed` draw (trial 1), when the deck takes one, so a
    /// point keeps the nominal circuit's mismatch sample.
    trial: ?Trial,
    /// Template 0 (the nominal circuit, `circuit` null) and those built
    /// where no writes could make the point, oldest first, all in `gpa`;
    /// `Session.templates` numbers them the same way.
    templates: std.ArrayList(Template) = .empty,
    /// The template the last row runs on, and later rows diff against.
    template: u32 = 0,
    /// The deck's variant table with each call's row appended, in the
    /// session arena (`Planner.sim`); seeded on the first call.
    seeded: bool = false,
    labels: std.ArrayList([]const u8) = .empty,
    temps: std.ArrayList(?f64) = .empty,
    axes: std.ArrayList(f64) = .empty,
    starts: std.ArrayList(u32) = .empty,
    refs: std.ArrayList(u32) = .empty,
    write_values: std.ArrayList(f64) = .empty,

    /// What one call changed: the whole variant table, whose last row is
    /// the call's, the template that row runs on (0 for the nominal
    /// circuit, k for the k-th built), and that template's circuit when
    /// this call built it.
    pub const Change = struct { variants: core.Variants, template: u32, built: ?*const device.Circuit };

    /// A circuit rows can run on, the live values it was built at, and what
    /// it holds that writes cannot reach, which a point must match to run
    /// on it.
    const Template = struct {
        circuit: ?*device.Circuit,
        values: []const f64,
        kept: Kept,

        /// The planner's nominal state over `circuit`, copied into `gpa`.
        fn of(gpa: std.mem.Allocator, circuit: ?*device.Circuit, values: []const f64, kept: Kept) !Template {
            const v = try gpa.dupe(f64, values);
            errdefer gpa.free(v);
            const bins = try gpa.dupe(u32, kept.bins);
            errdefer gpa.free(bins);
            return .{ .circuit = circuit, .values = v, .kept = .{ .bins = bins, .pool = try gpa.dupe(f64, kept.pool) } };
        }

        /// Frees the copies and the circuit, which `gpa` owns.
        fn deinit(tm: Template, gpa: std.mem.Allocator) void {
            if (tm.circuit) |c| {
                c.deinit();
                gpa.destroy(c);
            }
            gpa.free(tm.values);
            gpa.free(tm.kept.bins);
            gpa.free(tm.kept.pool);
        }
    };

    /// A tuning over `nl`, whose nominal circuit is `nominal` with card
    /// table `cards`. `scratch` (the parse arena) holds the result; `sim`
    /// (the session arena) holds the variant table. Asserts that `nl` has
    /// tunable names. The caller releases it with `deinit`.
    pub fn init(gpa: std.mem.Allocator, lib: *const device.Library, sim: std.mem.Allocator, scratch: std.mem.Allocator, nl: *Netlist, nominal: *const device.Circuit, cards: []const core.query.CardRef) !*Tuning {
        std.debug.assert(nl.tunable.len != 0);
        const t = try scratch.create(Tuning);
        t.* = .{ .gpa = gpa, .arenas = .{ .init(gpa), .init(gpa) }, .planner = undefined, .values = try scratch.dupe(f64, nl.live.nominal), .next = try scratch.dupe(f64, nl.live.nominal), .trial = null };
        errdefer for (&t.arenas) |*a| a.deinit();
        t.planner = try Planner.init(lib, sim, t.arenas[0].allocator(), nl, nominal, cards, "");
        try t.templates.ensureTotalCapacity(gpa, 1);
        errdefer t.templates.deinit(gpa);
        t.templates.appendAssumeCapacity(try .of(gpa, null, nl.live.nominal, t.planner.kept));
        if (nl.deck.draw_seed) {
            const sampler = try scratch.create(Sampler);
            sampler.* = try Sampler.init(scratch, nl.deck.config, 1);
            t.trial = .{ .sampler = sampler, .trial = 1, .index = 0 };
        }
        return t;
    }

    /// Frees the templates and the planner. The variant table stays with
    /// the session arena.
    pub fn deinit(t: *Tuning) void {
        for (t.templates.items) |tm| tm.deinit(t.gpa);
        t.templates.deinit(t.gpa);
        for (&t.arenas) |*a| a.deinit();
    }

    /// Re-opens the planner over template `k`, with the netlist at the
    /// values it was built at. `nominal` is template 0's circuit.
    fn open(t: *Tuning, k: u32, nominal: *const device.Circuit) !void {
        const p = &t.planner;
        const tm = t.templates.items[k];
        try setPoint(p.scratch, &p.stack, p.nl, .{ .label = "", .axis = 0, .live = tm.values, .trial = t.trial });
        const next = &t.arenas[~t.current];
        _ = next.reset(.free_all);
        const planner = try Planner.init(p.lib, p.sim, next.allocator(), p.nl, tm.circuit orelse nominal, p.cards, "");
        _ = t.arenas[t.current].reset(.free_all);
        t.current = ~t.current;
        p.* = planner;
        t.planned = k;
    }

    /// Sets each live name in `names` to the matching value, keeping every
    /// other at its last value, and returns the table with the point's row
    /// appended. `nominal` is the prepared circuit (template 0); `current`
    /// is the deck's table, read on the first call only. Names compare as
    /// the dialect spells them (case-insensitively but in Spectre).
    ///
    /// All-or-nothing: on failure the values, the table and the templates
    /// stay as they were. `UnknownParameter` for a name that is not live,
    /// `InvalidArgument` for a non-finite value, `ModelBinNotFound` when no
    /// bin holds a new L/W, `UnsupportedCard` when the point flips a
    /// top-level `.if` or changes the topology. Asserts that `names` and
    /// `values` have the same length.
    pub fn set(t: *Tuning, nominal: *const device.Circuit, current: core.Variants, names: []const []const u8, values: []const f64) !Change {
        std.debug.assert(names.len == values.len);
        std.debug.assert(t.template < t.templates.items.len);
        const p = &t.planner;
        const nl = p.nl;
        @memcpy(t.next, t.values);
        for (names, values) |name, v| {
            if (!std.math.isFinite(v)) return error.InvalidArgument;
            const k = for (nl.live.names, 0..) |live, k| {
                const same = if (nl.deck.dialect == .spectre) std.mem.eql(u8, live, name) else std.ascii.eqlIgnoreCase(live, name);
                if (same) break k;
            } else return error.UnknownParameter;
            t.next[k] = v;
        }
        var label: std.ArrayList(u8) = .empty;
        for (nl.tunable, 0..) |k, i| try label.print(p.sim, "{s}{s}={d}", .{ if (i == 0) "" else ", ", nl.live.names[k], t.next[k] });
        if (t.planned != t.template) try t.open(t.template, nominal);
        // `nominal` is the Problem's own circuit; the one the planner opened
        // over in `init` was moved into it since.
        p.nominal = t.templates.items[t.planned].circuit orelse nominal;
        // The open row starts empty; a failed call may have left writes.
        for (p.write_refs.items) |r| p.row_at[r] = netlist.none;
        p.write_refs.clearRetainingCapacity();
        p.write_values.clearRetainingCapacity();
        const pt: Point = .{ .label = label.items, .axis = 0, .live = t.next, .trial = t.trial };
        // Room for the row and a template first, so nothing fails after
        // the template list grows.
        if (!t.seeded) {
            try t.labels.appendSlice(p.sim, current.labels);
            try t.temps.appendSlice(p.sim, current.temp_c);
            try t.axes.appendSlice(p.sim, current.axis);
            try t.starts.appendSlice(p.sim, if (current.starts.len == 0) &.{0} else current.starts);
            try t.refs.appendSlice(p.sim, current.refs);
            try t.write_values.appendSlice(p.sim, current.values);
            t.seeded = true;
        }
        try t.labels.ensureUnusedCapacity(p.sim, 1);
        try t.temps.ensureUnusedCapacity(p.sim, 1);
        try t.axes.ensureUnusedCapacity(p.sim, 1);
        try t.starts.ensureUnusedCapacity(p.sim, 1);
        try t.templates.ensureUnusedCapacity(t.gpa, 1);
        var built: ?*device.Circuit = null;
        errdefer if (built != null) {
            // Not published: the next call re-opens the planner.
            t.templates.pop().?.deinit(t.gpa);
            t.planned = std.math.maxInt(u32);
        };
        if (try p.load(pt, label.items) == .circuit) {
            // An earlier template that holds the point's bins and kept values
            // takes it; otherwise the circuit built at it is a new template.
            const reuse: ?u32 = for (t.templates.items, 0..) |tm, k| {
                if (k != t.planned and tm.kept.holds(nl)) break @intCast(k);
            } else null;
            if (reuse) |k| {
                try t.open(k, nominal);
            } else {
                const c = try t.gpa.create(device.Circuit);
                var owned = true;
                errdefer if (owned) t.gpa.destroy(c);
                var scratch = std.heap.ArenaAllocator.init(t.gpa);
                defer scratch.deinit();
                c.* = try circuitOf(p.lib, t.gpa, scratch.allocator(), nl);
                errdefer if (owned) c.deinit();
                if (!sameTopology(t.templates.items[t.planned].circuit orelse nominal, c)) return p.refuse(label.items, "a parameter value that changes the topology");
                const kept: Kept = try .of(scratch.allocator(), nl);
                t.templates.appendAssumeCapacity(try .of(t.gpa, c, t.next, kept));
                owned = false;
                built = c;
                try t.open(@intCast(t.templates.items.len - 1), nominal);
            }
            if (try p.load(pt, label.items) != .row) return p.refuse(label.items, "a parameter value that changes the topology");
        }
        try p.pointWrites(pt);
        try t.refs.appendSlice(p.sim, p.write_refs.items);
        try t.write_values.appendSlice(p.sim, p.write_values.items);
        t.template = t.planned;
        t.labels.appendAssumeCapacity(label.items);
        t.temps.appendAssumeCapacity(null);
        t.axes.appendAssumeCapacity(0);
        t.starts.appendAssumeCapacity(@intCast(t.refs.items.len));
        @memcpy(t.values, t.next);
        return .{ .template = t.template, .built = built, .variants = .{
            .labels = t.labels.items,
            .temp_c = t.temps.items,
            .axis = t.axes.items,
            .starts = t.starts.items,
            .refs = t.refs.items,
            .values = t.write_values.items,
        } };
    }
};

/// The optimizer options of `.model name OPT` [CR .MODEL; SA Ch.19, 27]
/// and its search: METHOD=BISECTION|PASSFAIL, else LEVEL 1 (LM), 2
/// (bisection) or 3 (pass/fail); METHOD supersedes LEVEL. Unknown keys are
/// refused; CENDIF and DYNACC (a speed-up through reduced accuracy) are
/// accepted and ignored.
fn optOptions(nl: *const Netlist, name: []const u8, line: []const u8) !struct { core.lm.Options, core.bisect.Method } {
    const model = nl.findModel(name) orelse {
        if (!@import("builtin").is_test) std.log.err("optimize: no .model {s} OPT: {s}", .{ name, line });
        return error.UnsupportedCard;
    };
    var o: core.lm.Options = .{};
    var method: ?core.bisect.Method = null;
    var level: core.bisect.Method = .lm;
    const Key = enum { itropt, relin, relout, close, cut, difsiz, parmin, grad, max, level, method, cendif, absin, absout, dynacc };
    const ok = std.mem.eql(u8, model.kind, "opt") and for (model.kv) |kv| {
        const key = std.meta.stringToEnum(Key, kv.key) orelse break false;
        if (key == .method) {
            if (kv.value != .name) break false;
            method = std.meta.stringToEnum(core.bisect.Method, kv.value.name) orelse break false;
            continue;
        }
        const v = switch (kv.value) {
            .num => |v| v,
            else => break false,
        };
        if (key == .dynacc) continue;
        if (!(v > 0) or !std.math.isFinite(v)) break false;
        switch (key) {
            .itropt => o.itropt = std.math.lossyCast(u32, v),
            .relin => o.relin = v,
            .relout => o.relout = v,
            .close => o.close = v,
            .cut => o.cut = v,
            .difsiz => o.difsiz = v,
            .parmin => o.parmin = v,
            .grad => o.grad = v,
            .max => o.max = v,
            .absin => o.absin = v,
            .absout => o.absout = v,
            .level => level = switch (std.math.lossyCast(u8, v)) {
                1 => .lm,
                2 => .bisection,
                3 => .passfail,
                else => break false,
            },
            .method, .cendif, .dynacc => {},
        }
    } else true;
    if (!ok or o.cut <= 1) {
        if (!@import("builtin").is_test) std.log.err("optimize: unsupported .model {s} OPT option: {s}", .{ name, line });
        return error.UnsupportedCard;
    }
    return .{ o, method orelse level };
}

fn refKey(a: std.mem.Allocator, t: core.DeviceType, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}:{s}", .{ @backingInt(t), name });
}

fn targetName(nl: *const Netlist, t: netlist.StepTarget) []const u8 {
    return switch (t) {
        .param => |k| nl.live.names[k],
        .temp => "temp",
        .card => |name| name,
    };
}

/// Every parameter of `c`'s batches, typed, in `Circuit.collectParams`
/// order. Caller owns the returned slice and must free it with `gpa`; the
/// refs point into `c`'s storage and die with it.
pub fn collect(gpa: std.mem.Allocator, c: *const device.Circuit) ![]const ParamRef {
    var list: std.ArrayList(ParamRef) = .empty;
    for (c.batches, c.batch_types) |b, t| {
        const first = list.items.len;
        try b.hooks.collect_params(b.ctx, gpa, &list).unwrap();
        for (list.items[first..]) |*r| r.type = t;
    }
    return list.toOwnedSlice(gpa);
}

/// The frozen circuit `nl` binds to, as `prepare.build` constructs it, with
/// `nl`'s live values as they stand. Caller owns the circuit and releases
/// it with `deinit`; `scratch` holds the construction tables.
pub fn circuitOf(lib: *const device.Library, gpa: std.mem.Allocator, scratch: std.mem.Allocator, nl: *const Netlist) !device.Circuit {
    const deck_opts = try analyses.deckOptions(nl.deck.config, nl.deck.dialect);
    var b = try builder.Builder.init(gpa, lib);
    var compiled = false;
    errdefer if (!compiled) b.deinit();
    b.nom_temp_c = deck_opts.tnom_c;
    b.reltol = deck_opts.tol.reltol;
    b.abstol = deck_opts.tol.abstol;
    b.vntol = deck_opts.tol.vntol;
    b.gmin = deck_opts.tol.gmin;
    try b.reserveNodes(nl.graph.vertexCount());
    var nb = try builder.NetBuilder.init(scratch, &b, nl.*);
    try nb.build();
    try nb.tagSubcircuitNodes();
    try nb.addDynDevices();
    var perm: ?[]const u32 = null;
    const c = try b.compilePerm(&perm);
    compiled = true;
    return c;
}

/// Same matrix pattern, node count and devices per type: parameter writes
/// can turn `a` into `b`.
fn sameTopology(a: *const device.Circuit, b: *const device.Circuit) bool {
    if (a.n != b.n or a.nnz != b.nnz or a.batches.len != b.batches.len) return false;
    if (!std.mem.eql(u32, a.col_ptr, b.col_ptr) or !std.mem.eql(u32, a.row_idx, b.row_idx)) return false;
    if (!std.mem.eql(bool, a.current_row, b.current_row)) return false;
    for (a.batches, b.batches, a.batch_types, b.batch_types) |x, y, tx, ty|
        if (tx != ty or x.count != y.count) return false;
    return true;
}

/// Same cards on the same nets, and the same analyses: an `.alter` run
/// that only changed values.
fn sameCards(a: *const Netlist, b: *const Netlist) bool {
    if (a.deviceCount() != b.deviceCount() or a.deck.analyses.len != b.deck.analyses.len or a.deck.config.len != b.deck.config.len) return false;
    for (a.deck.analyses, b.deck.analyses) |x, y| if (!std.mem.eql(u8, x.line, y.line)) return false;
    for (a.deck.config, b.deck.config) |x, y| if (!std.mem.eql(u8, x.line, y.line)) return false;
    for (a.order, b.order) |ea, eb| {
        const x = a.device(ea);
        const y = b.device(eb);
        if (x.kind != y.kind or !std.mem.eql(u8, x.name, y.name) or x.pins.len != y.pins.len) return false;
        for (x.pins, y.pins) |px, py| if (!std.mem.eql(u8, a.netName(px), b.netName(py))) return false;
    }
    return true;
}

// Monte Carlo draws.

/// Draws for one sweep's trials: counter-based, so trial k's value at a
/// site depends only on (seed, k, site), never on order or other sites.
/// Latin hypercube stratifies each site over the sweep's trials.
pub const Sampler = struct {
    seed: u64,
    n: u32,
    lhs: bool,
    arena: std.mem.Allocator,
    /// Latin hypercube: per site, trial index to stratum.
    strata: std.AutoHashMapUnmanaged(u64, []const u32) = .empty,

    /// Reads `.option seed=` (HSPICE default 1) and `sampling_method=lhs`;
    /// any method other than `lhs` or `srs` is `UnsupportedCard`.
    pub fn init(arena: std.mem.Allocator, config: []const netlist.Config, n: u32) !Sampler {
        var s: Sampler = .{ .seed = 1, .n = n, .lhs = false, .arena = arena };
        for (config) |c| if (!c.temp) for (c.args, 0..) |a, i| {
            if (a != .name or i + 1 >= c.args.len) continue;
            const next = c.args[i + 1];
            // lossyCast: a NaN or out-of-range seed saturates, never traps.
            if (std.ascii.eqlIgnoreCase(a.name, "seed") and next == .num) s.seed = std.math.lossyCast(u64, @abs(next.num));
            if (std.ascii.eqlIgnoreCase(a.name, "sampling_method") and next == .name) {
                if (std.ascii.eqlIgnoreCase(next.name, "lhs")) s.lhs = true else if (!std.ascii.eqlIgnoreCase(next.name, "srs")) return error.UnsupportedCard;
            }
        };
        return s;
    }

    /// Uniform in (0, 1) for HSPICE trial number `trial` at `site`.
    /// `index` (0-based within the sweep) picks the Latin hypercube
    /// stratum: it must be below `n`, which only the safety-checked
    /// `strata[index]` enforces. The first Latin hypercube draw at a site
    /// allocates its strata in `arena` (on allocation failure the draw
    /// falls back to plain sampling).
    pub fn uniform(s: *Sampler, site: u64, trial: u32, index: u32) f64 {
        const bits = netlist.siteKey(netlist.siteKey(s.seed, trial), site);
        const u = (@as(f64, @floatFromInt(bits >> 11)) + 0.5) * 0x1.0p-53;
        if (!s.lhs) return u;
        const strata = s.strataOf(site) catch return u;
        return (@as(f64, @floatFromInt(strata[index])) + u) / @as(f64, @floatFromInt(s.n));
    }

    /// A random permutation of the `n` strata for `site`.
    fn strataOf(s: *Sampler, site: u64) ![]const u32 {
        const gop = try s.strata.getOrPut(s.arena, site);
        if (gop.found_existing) return gop.value_ptr.*;
        const perm = try s.arena.alloc(u32, s.n);
        for (perm, 0..) |*x, i| x.* = @intCast(i);
        var prng = std.Random.DefaultPrng.init(netlist.siteKey(s.seed, site));
        // A u64 index draws the same bits on every target; `shuffle`'s
        // usize index permuted differently on wasm32.
        prng.random().shuffleWithIndex(u32, perm, u64);
        gop.value_ptr.* = perm;
        return perm;
    }
};

/// Sets `nl`'s live values to `pt`'s, drawing its Monte Carlo trial if it
/// has one. `stack` is evaluation scratch, grown with `scratch`.
pub fn setPoint(scratch: std.mem.Allocator, stack: *std.ArrayList(expr.Val), nl: *Netlist, pt: Point) !void {
    if (pt.trial) |t| {
        _ = try nl.setLive(scratch, stack, pt.live, TrialDraw{ .trial = t });
    } else _ = try nl.setLive(scratch, stack, pt.live, null);
}

/// Draws every distribution site of `nl` once, as trial 1 of the deck's
/// `.option seed`, into its live values (`Deck.draw_seed`). `scratch` holds
/// the sampler and the evaluation stack.
pub fn drawOnce(scratch: std.mem.Allocator, nl: *Netlist) !void {
    var sampler = try Sampler.init(scratch, nl.deck.config, 1);
    var stack: std.ArrayList(expr.Val) = .empty;
    _ = try nl.setLive(scratch, &stack, nl.live.nominal, TrialDraw{ .trial = .{ .sampler = &sampler, .trial = 1, .index = 0 } });
}

/// Holds every distribution call at its nominal except those at `site`,
/// which sit one sigma above it: a uniform's half range over sqrt(3), a
/// `limit`'s whole range (`Planner.siteVariations`).
const OneSigma = struct {
    site: u64,

    /// Asserts that `args` holds at least the nominal value.
    pub fn sample(self: OneSigma, site: u64, f: expr.Fn, args: []const f64) f64 {
        std.debug.assert(args.len >= 1);
        const nom = args[0];
        if (site != self.site) return nom;
        const width = if (args.len > 1) args[1] else 0;
        const gaussian = f == .agauss or f == .gauss;
        const sigmas = if (gaussian and args.len > 2 and args[2] != 0) args[2] else 1;
        return nom + switch (f) {
            .agauss => width / sigmas,
            .gauss => nom * width / sigmas,
            .aunif => width / @sqrt(3.0),
            .unif => nom * width / @sqrt(3.0),
            else => width, // else: `limit`; only distribution calls reach a sampler
        };
    }
};

/// One Monte Carlo trial of a sweep.
pub const Trial = struct {
    sampler: *Sampler,
    /// HSPICE trial number; keys the draws.
    trial: u32,
    /// Position within the sweep; picks the Latin hypercube stratum.
    index: u32,

    fn uniform(t: Trial, site: u64) f64 {
        return t.sampler.uniform(site, t.trial, t.index);
    }
};

/// Answers the distribution calls of one trial [SA Ch.20 "Monte Carlo
/// Parameter Distribution"]: `agauss(nom, abs, sigmas[, mult])`,
/// `gauss(nom, rel, sigmas[, mult])`, `aunif(nom, abs[, mult])`,
/// `unif(nom, rel[, mult])`, `limit(nom, abs)`. With a multiplier m the
/// draw of largest deviation among m is kept.
const TrialDraw = struct {
    trial: Trial,

    /// The trial's draw for distribution call `f` at `site`. `args` must
    /// hold at least the nominal value; unlike `OneSigma.sample` there is
    /// no assert, only the safety-checked read of `args[0]`.
    pub fn sample(self: TrialDraw, site: u64, f: expr.Fn, args: []const f64) f64 {
        const nom = args[0];
        const width = if (args.len > 1) args[1] else 0;
        const gaussian = f == .agauss or f == .gauss;
        const sigmas = if (gaussian and args.len > 2 and args[2] != 0) args[2] else 1;
        const mult_at: usize = if (gaussian) 3 else 2;
        const mult: u32 = if (f != .limit and args.len > mult_at and args[mult_at] >= 1) @intFromFloat(@min(args[mult_at], 1e6)) else 1;
        const scale = switch (f) {
            .agauss => width / sigmas,
            .gauss => nom * width / sigmas,
            .unif => nom * width,
            else => width,
        };
        var best: f64 = 0;
        for (0..mult) |m| {
            const u = self.trial.uniform(netlist.siteKey(site, m));
            const d = switch (f) {
                .agauss, .gauss => scale * normalQuantile(u),
                .limit => if (u < 0.5) -scale else scale,
                else => scale * (2 * u - 1),
            };
            if (m == 0 or @abs(d) > @abs(best)) best = d;
        }
        return nom + best;
    }
};

/// The standard normal quantile Φ⁻¹(u), u in (0, 1): Acklam's rational
/// approximation, relative error below 1.2e-9. At 0 or 1 it returns NaN,
/// so callers draw from the open interval.
pub fn normalQuantile(u: f64) f64 {
    const a = [_]f64{ -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00 };
    const b = [_]f64{ -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01, -1.328068155288572e+01 };
    const c = [_]f64{ -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00 };
    const d = [_]f64{ 7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00 };
    const low = 0.02425;
    if (u < low or u > 1 - low) {
        const q = @sqrt(-2 * @log(if (u < low) u else 1 - u));
        const x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
            ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
        return if (u < low) x else -x;
    }
    const q = u - 0.5;
    const r = q * q;
    return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
        (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
}

test "normal quantile: symmetric, and the 97.5% point is 1.96" {
    try std.testing.expectApproxEqAbs(@as(f64, 0), normalQuantile(0.5), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.959963984540054), normalQuantile(0.975), 1e-8);
    try std.testing.expectApproxEqAbs(-normalQuantile(0.01), normalQuantile(0.99), 1e-12);
}

test "Sampler.init reads seed and sampling method, and a wild seed saturates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = struct {
        fn of(args: []const netlist.Value) [1]netlist.Config {
            return .{.{ .temp = false, .args = args }};
        }
    }.of;
    var c = cfg(&.{ .{ .name = "seed" }, .{ .num = -7 }, .{ .name = "sampling_method" }, .{ .name = "LHS" } });
    const s = try Sampler.init(a, &c, 4);
    try std.testing.expectEqual(@as(u64, 7), s.seed);
    try std.testing.expect(s.lhs);
    c = cfg(&.{ .{ .name = "seed" }, .{ .num = comptime std.math.nan(f64) } });
    try std.testing.expectEqual(@as(u64, 0), (try Sampler.init(a, &c, 4)).seed);
    c = cfg(&.{ .{ .name = "seed" }, .{ .num = 1e300 } });
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), (try Sampler.init(a, &c, 4)).seed);
    c = cfg(&.{ .{ .name = "sampling_method" }, .{ .name = "sobol" } });
    try std.testing.expectError(error.UnsupportedCard, Sampler.init(a, &c, 4));
    // A trailing key with no value is skipped.
    c = cfg(&.{.{ .name = "seed" }});
    try std.testing.expectEqual(@as(u64, 1), (try Sampler.init(a, &c, 4)).seed);
}

test "TrialDraw keeps the largest deviation of a multiplier's draws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sampler = try Sampler.init(arena.allocator(), &.{}, 1);
    const draw: TrialDraw = .{ .trial = .{ .sampler = &sampler, .trial = 1, .index = 0 } };
    const one = draw.sample(5, .agauss, &.{ 1, 0.1, 1 });
    const many = draw.sample(5, .agauss, &.{ 1, 0.1, 1, 8 });
    // m = 0 is the single draw, so the max over eight is at least as far.
    try std.testing.expect(@abs(many - 1) >= @abs(one - 1));
    // `limit` lands on nom +- abs exactly; `aunif` stays inside the band.
    try std.testing.expectEqual(@as(f64, 0.5), @abs(draw.sample(9, .limit, &.{ 2, 0.5 }) - 2));
    try std.testing.expect(@abs(draw.sample(9, .aunif, &.{ 2, 0.5 }) - 2) < 0.5);
    // Nominal only: no spread.
    try std.testing.expectEqual(@as(f64, 3), draw.sample(9, .agauss, &.{3}));
}

test "normal quantile is monotone across the tail seam" {
    var prev = normalQuantile(1e-12);
    for ([_]f64{ 1e-6, 0.02, 0.02425, 0.0243, 0.3, 0.5, 0.7, 0.97575, 0.98, 1 - 1e-12 }) |u| {
        const x = normalQuantile(u);
        try std.testing.expect(x > prev);
        prev = x;
    }
    try std.testing.expect(std.math.isNan(normalQuantile(0)));
}
