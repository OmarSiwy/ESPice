//! engine.zig — orchestrator between the frontend netlist and the analysis module.
//!
//! Data flow:  types.Netlist ──buildCircuit──▶ builder.Builder
//!             ──compile()──▶ analysis.Circuit ──run()──▶ []Result
//!
//! Zero ArrayList: all arrays pre-allocated from bucket sizes / directive count.

const std = @import("std");
const analysis = @import("analysis");
const devices = @import("devices");
const types = @import("frontend/types.zig");
const fastvaf = @import("fastvaf");

const Circuit = analysis.Circuit;
const Job = analysis.Job;
const Result = analysis.Result;
const RunCtx = analysis.RunCtx;
const Builder = @import("builder.zig").Builder;
const DynDevice = analysis.dyn.DynDevice;
const DynKv = analysis.dyn.DynKv;
const GROUND = analysis.GROUND;

// ---------------------------------------------------------------------------
// Sweepable sources: parallel slices indexed by add order
// ---------------------------------------------------------------------------

const Sources = struct {
    v_names: []const []const u8,
    v_ports: []const u32,
    v_branches: []const u32,
    v_dc: []const *f32,
    i_names: []const []const u8,
    i_dc: []const *f32,
};

pub const CompiledDevice = struct {
    name: []const u8,
    so_path: []const u8,
    ports: []const []const u8,
    language: enum { verilog_a, verilog },
};

// ---------------------------------------------------------------------------
// Simulation — owns circuit, dispatches jobs, collects results
// ---------------------------------------------------------------------------

pub const Simulation = struct {
    arena: std.mem.Allocator,
    circuit: Circuit,
    probes: []u32,
    source_node: u32,
    source_branch: u32,
    sources: Sources,
    jobs: []Job,
    n_jobs: u32,
    results: []Result,
    n_results: u32,
    compiled_devices: []CompiledDevice,
    n_compiled: u32,
    /// Parallel eval context (policy: created here, referenced by Circuit).
    par_eval: ?analysis.par.ParEval,

    pub fn fromNetlist(arena: std.mem.Allocator, nl: types.Netlist, io: ?std.Io) !Simulation {
        var b = Builder.init(arena);
        var compiled_ok = false;
        errdefer if (!compiled_ok) b.deinit();

        // Node count is bounded by (and usually close to) device count;
        // reserving here avoids incremental rehash during interning.
        try b.reserveNodes(@intCast(@min(nl.devices.len(), std.math.maxInt(u32))));

        var nb = try NetBuilder.init(arena, &b, nl);
        try nb.build();

        try tagSubcircuitNodes(&b, nl.devices);

        // Generated (Verilog-A / Verilog) devices: compile → .so, dlopen,
        // add to Builder. Must happen before compile() freezes the pattern.
        var compiled_buf = try arena.alloc(CompiledDevice, nl.generated_devices.len);
        var n_compiled: u32 = 0;
        if (io) |io_val| {
            compileGeneratedDevices(compiled_buf, &n_compiled, arena, io_val, nl.generated_devices);
            try loadGeneratedDevices(&b, arena, compiled_buf[0..n_compiled], nl);
        }

        var sim: Simulation = undefined;
        sim.arena = arena;
        sim.circuit = try b.compile();
        compiled_ok = true;
        errdefer sim.circuit.deinit();

        // Sources: convert builder arrays to frozen slices
        sim.source_node = nb.source_node;
        sim.source_branch = nb.source_branch;
        sim.sources = .{
            .v_names = nb.v_names[0..nb.n_v],
            .v_ports = nb.v_ports[0..nb.n_v],
            .v_branches = nb.v_branches[0..nb.n_v],
            .v_dc = try collectDcRefs(&sim.circuit, arena, devices.vsource, false, nb.n_v),
            .i_names = nb.i_names[0..nb.n_i],
            .i_dc = try collectDcRefs(&sim.circuit, arena, devices.isource, true, nb.n_i),
        };

        // Probes: every named node (branch unknowns have no label)
        const probe_buf = try arena.alloc(u32, sim.circuit.n);
        var n_probes: u32 = 0;
        for (1..sim.circuit.n) |i| {
            if (sim.circuit.nodeName(@intCast(i)).len != 0) {
                probe_buf[n_probes] = @intCast(i);
                n_probes += 1;
            }
        }
        sim.probes = probe_buf[0..n_probes];

        // Jobs from directives: pre-allocate to directive count
        sim.jobs = try arena.alloc(Job, nl.directives.len);
        sim.n_jobs = 0;
        for (nl.directives) |dir| {
            if (buildJob(dir, &sim)) |job| {
                sim.jobs[sim.n_jobs] = job;
                sim.n_jobs += 1;
            }
        }

        // Results: one per job max
        sim.results = try arena.alloc(Result, @max(sim.n_jobs, 1));
        sim.n_results = 0;
        sim.compiled_devices = compiled_buf;
        sim.n_compiled = n_compiled;

        // Parallel device eval. ponytail: OPT-IN via ZPICEY_THREADS=N for
        // now — measured 2026-07-04, per-eval handoff + window zero/reduce
        // breaks even with eval work on the current fixture corpus, so
        // default-on would regress small/medium circuits. Auto-enable
        // (work-based threshold) is the Phase-5 tuning task.
        sim.par_eval = null;
        if (io) |io_val| enable_par: {
            const s = std.c.getenv("ZPICEY_THREADS") orelse break :enable_par;
            const lanes = std.fmt.parseInt(u32, std.mem.span(s), 10) catch break :enable_par;
            if (lanes < 2) break :enable_par;
            var total: u64 = 0;
            for (sim.circuit.batches) |batch| total += batch.count;
            if (total < analysis.par.default_min_instances) break :enable_par;
            sim.par_eval = analysis.par.ParEval.init(arena, io_val, &sim.circuit, @min(lanes, 16)) catch break :enable_par;
        }

        return sim;
    }

    pub fn deinit(self: *Simulation) void {
        self.circuit.par_eval = null;
        if (self.par_eval) |*p| p.deinit();
        self.circuit.deinit();
    }

    pub fn run(self: *Simulation) !void {
        // Attach here, not in fromNetlist: sim is returned by value there, so
        // a &self.par_eval taken earlier would dangle. `self` is stable now.
        if (self.par_eval) |*p| self.circuit.par_eval = p;
        var ctx = RunCtx{
            .circuit = &self.circuit,
            .x_op = null,
            .probes = self.probes,
            .source_node = self.source_node,
            .source_branch = self.source_branch,
            .allocator = self.arena,
        };

        // If no jobs queued, run an implicit OP
        if (self.n_jobs == 0) {
            ctx.x_op = try self.ensureOp(ctx.x_op);
            self.results[0] = try analysis.run(&ctx, .{ .op = .{} });
            self.n_results = 1;
            return;
        }

        for (self.jobs[0..self.n_jobs]) |job| {
            // Ensure operating point for analyses that need it
            ctx.x_op = try self.ensureOp(ctx.x_op);
            self.results[self.n_results] = try analysis.run(&ctx, job);
            self.n_results += 1;
        }
    }

    pub fn getResults(self: *const Simulation) []const Result {
        return self.results[0..self.n_results];
    }

    fn ensureOp(self: *Simulation, current: ?[]f64) ![]f64 {
        if (current) |x| return x;
        const x = try self.arena.alloc(f64, self.circuit.n);
        const result = try analysis.AnalysisId.Module(.op).solve(&self.circuit, x, .{}, self.arena);
        if (!result.converged) return error.OpDidNotConverge;
        return x;
    }

    fn nodeIndex(self: *const Simulation, name: []const u8) !u32 {
        return self.circuit.node_names.get(name) orelse error.UnknownNode;
    }
};

// ---------------------------------------------------------------------------
// Generated (Verilog-A / Verilog) device compilation + loading
// ---------------------------------------------------------------------------

fn compileGeneratedDevices(
    out: []CompiledDevice,
    n: *u32,
    arena: std.mem.Allocator,
    io: std.Io,
    generated: []const types.GeneratedDevice,
) void {
    for (generated) |gen| {
        const output_dir = std.fmt.allocPrint(arena, "/tmp/zpicey_gen_{s}", .{gen.name}) catch continue;
        var result = fastvaf.compileGenerated(arena, gen.name, gen.zig_source, .{
            .io = io,
            .output_dir = output_dir,
            .contract_root = "modules/devices/src/contract.zig",
            .device_name = gen.name,
        }) catch |err| {
            std.debug.print("Warning: failed to compile generated device '{s}': {s}\n", .{ gen.name, @errorName(err) });
            continue;
        };
        const so_path = result.shared_object_path;
        result.shared_object_path = "";
        result.deinit();
        out[n.*] = .{
            .name = gen.name,
            .so_path = so_path,
            .ports = gen.ports,
            .language = switch (gen.language) {
                .verilog_a => .verilog_a,
                .verilog => .verilog,
            },
        };
        n.* += 1;
        std.debug.print("Compiled generated device '{s}' → {s}\n", .{ gen.name, so_path });
    }
}

/// dlopen each compiled .so and add its netlist instances to the Builder.
/// Two-pass per device: count matching instances, pre-allocate, fill.
fn loadGeneratedDevices(
    b: *Builder,
    arena: std.mem.Allocator,
    compiled: []const CompiledDevice,
    nl: types.Netlist,
) !void {
    const dl = nl.devices;
    for (compiled) |comp| {
        const dyn = DynDevice.open(comp.so_path) catch |err| {
            std.debug.print("Warning: failed to load generated device '{s}': {s}\n", .{ comp.name, @errorName(err) });
            continue;
        };

        // Pass 1: count instances referencing this model name
        var count: u32 = 0;
        for (0..dl.len()) |di| {
            const pos = dl.positional[di];
            if (pos.len == 0) continue;
            const model_name = switch (pos[0]) {
                .name => |nm| nm,
                else => continue,
            };
            if (std.mem.eql(u8, model_name, comp.name)) count += 1;
        }

        if (count == 0) {
            var d = dyn;
            d.close();
            continue;
        }

        // Pre-allocate per-instance arrays
        const node_sets = try arena.alloc([]const u32, count);
        const model_kvs = try arena.alloc([]const DynKv, count);
        const instance_kvs = try arena.alloc([]const DynKv, count);

        // Build shared model kv slice (same for all instances of this device)
        const shared_mkv = try buildNumericKvs(arena, if (findModel(nl.models, comp.name)) |m| m.kv else &.{});

        // Pass 2: fill
        var idx: u32 = 0;
        for (0..dl.len()) |di| {
            const pos = dl.positional[di];
            if (pos.len == 0) continue;
            const model_name = switch (pos[0]) {
                .name => |nm| nm,
                else => continue,
            };
            if (!std.mem.eql(u8, model_name, comp.name)) continue;

            const dev_nodes = dl.nodes[di];
            const port_nodes = try arena.alloc(u32, comp.ports.len);
            for (port_nodes, 0..) |*out, pidx| {
                const node_idx = pidx + 1;
                out.* = if (node_idx < dev_nodes.len) try b.internNode(dev_nodes[node_idx]) else GROUND;
            }
            node_sets[idx] = port_nodes;
            model_kvs[idx] = shared_mkv;
            instance_kvs[idx] = try buildNumericKvs(arena, dl.kv[di]);
            idx += 1;
        }

        b.addDynDevice(dyn, comp.name, node_sets, model_kvs, instance_kvs) catch |err| {
            std.debug.print("Warning: could not add generated device '{s}': {s}\n", .{ comp.name, @errorName(err) });
            continue;
        };
    }
}

/// Extract numeric key-value pairs from a Kv slice. Two-pass: count, alloc, fill.
fn buildNumericKvs(arena: std.mem.Allocator, kv: []const types.Kv) ![]const DynKv {
    var n: usize = 0;
    for (kv) |item| switch (item.value) {
        .num => n += 1,
        else => {},
    };
    const out = try arena.alloc(DynKv, n);
    var i: usize = 0;
    for (kv) |item| switch (item.value) {
        .num => |v| {
            out[i] = .{ .key = item.key, .value = v };
            i += 1;
        },
        else => {},
    };
    return out;
}

// ---------------------------------------------------------------------------
// NetBuilder — netlist → Builder wiring (no ArrayList, bucket-sized arrays)
// ---------------------------------------------------------------------------

fn isValueForm(comptime D: type) bool {
    return @hasDecl(D, "eval");
}

const NetBuilder = struct {
    arena: std.mem.Allocator,
    b: *Builder,
    nl: types.Netlist,

    // Pre-allocated to bucket('v').size()
    v_names: [][]const u8,
    v_ports: []u32,
    v_branches: []u32,
    n_v: u32,

    // Pre-allocated to bucket('i').size()
    i_names: [][]const u8,
    n_i: u32,

    // Pre-allocated to bucket('l').size()
    l_names: [][]const u8,
    l_branches: []u32,
    n_l: u32,

    // Pre-allocated to sum of f/h/w/k bucket sizes
    deferred: []Deferred,
    n_deferred: u32,

    source_node: u32,
    source_branch: u32,
    have_source: bool,

    const Deferred = struct { dev: types.Device, letter: u8 };

    fn init(arena: std.mem.Allocator, b: *Builder, nl: types.Netlist) !NetBuilder {
        const dl = nl.devices;
        const nv = dl.bucket('v').size();
        const ni = dl.bucket('i').size();
        const nl_ = dl.bucket('l').size();
        const n_def = dl.bucket('f').size() + dl.bucket('h').size() +
            dl.bucket('w').size() + dl.bucket('k').size();

        return .{
            .arena = arena,
            .b = b,
            .nl = nl,
            .v_names = try arena.alloc([]const u8, nv),
            .v_ports = try arena.alloc(u32, nv),
            .v_branches = try arena.alloc(u32, nv),
            .n_v = 0,
            .i_names = try arena.alloc([]const u8, ni),
            .n_i = 0,
            .l_names = try arena.alloc([]const u8, nl_),
            .l_branches = try arena.alloc(u32, nl_),
            .n_l = 0,
            .deferred = try arena.alloc(Deferred, n_def),
            .n_deferred = 0,
            .source_node = GROUND,
            .source_branch = GROUND,
            .have_source = false,
        };
    }

    fn build(self: *NetBuilder) !void {
        const dl = self.nl.devices;
        try self.addBucket(dl.bucket('v'));
        try self.addBucket(dl.bucket('l'));
        try self.addBucket(dl.bucket('i'));
        try self.addBucket(dl.bucket('f'));
        try self.addBucket(dl.bucket('h'));
        try self.addBucket(dl.bucket('w'));
        try self.addBucket(dl.bucket('k'));
        inline for ("abcdefghijklmnopqrstuvwxyz") |c| {
            if (comptime c != 'f' and c != 'h' and c != 'i' and c != 'k' and c != 'l' and c != 'v' and c != 'w')
                try self.addBucket(dl.bucket(c));
        }
        try self.resolveDeferred();
    }

    fn addBucket(self: *NetBuilder, bkt: types.DeviceList.Bucket) !void {
        for (0..bkt.size()) |i| try self.addDevice(bkt.get(i));
    }

    fn addDevice(self: *NetBuilder, dev: types.Device) !void {
        const letter = dev.letter();
        if (devices.letter_map.get(&.{letter}) == null) return error.UnsupportedDevice;

        switch (letter) {
            'r' => _ = try self.addPassive(devices.resistor, dev, "resist", "r"),
            'c' => _ = try self.addPassive(devices.capacitor, dev, "cap", "c"),
            'l' => {
                const br = try self.addPassive(devices.inductor, dev, "inductance", "l");
                self.l_names[self.n_l] = dev.name;
                self.l_branches[self.n_l] = br;
                self.n_l += 1;
            },
            'v' => {
                if (comptime !isValueForm(devices.vsource)) return error.UnsupportedDevice;
                var model: devices.vsource.Model = .{};
                model.dc = @floatCast(sourceDc(dev));
                applySourceWaveform(&model, dev);
                try applyKv(&model, dev.kv);
                const nodes = try deviceNodes(self.b, devices.vsource, dev);
                const br = self.b.n;
                try self.b.addDevice(devices.vsource, model, .{}, nodes);
                self.v_names[self.n_v] = dev.name;
                self.v_ports[self.n_v] = nodes[0];
                self.v_branches[self.n_v] = br;
                self.n_v += 1;
                if (!self.have_source) {
                    self.have_source = true;
                    self.source_node = nodes[0];
                    self.source_branch = br;
                }
            },
            'i' => {
                if (comptime !isValueForm(devices.isource)) return error.UnsupportedDevice;
                var instance: devices.isource.Instance = .{};
                instance.dc = @floatCast(sourceDc(dev));
                applySourceWaveform(&instance, dev);
                try applyKv(&instance, dev.kv);
                try self.b.addDevice(devices.isource, .{}, instance, try deviceNodes(self.b, devices.isource, dev));
                self.i_names[self.n_i] = dev.name;
                self.n_i += 1;
            },
            'f', 'h', 'w', 'k' => {
                self.deferred[self.n_deferred] = .{ .dev = dev, .letter = letter };
                self.n_deferred += 1;
            },
            'b' => try addBsource(self.b, dev, self.nl.models),
            else => try self.addByLetter(letter, dev),
        }
    }

    fn addPassive(
        self: *NetBuilder,
        comptime D: type,
        dev: types.Device,
        comptime instance_field: []const u8,
        comptime short_field: []const u8,
    ) !u32 {
        if (comptime !isValueForm(D)) return error.UnsupportedDevice;
        var model: D.Model = .{};
        var instance: D.Instance = .{};
        const value = positionalNumber(dev, 0) orelse kvNumber(dev.kv, instance_field) orelse kvNumber(dev.kv, short_field) orelse 0;
        @field(instance, instance_field) = castField(@TypeOf(@field(instance, instance_field)), value);
        try applyKv(&model, dev.kv);
        try applyKv(&instance, dev.kv);
        const nodes = try deviceNodes(self.b, D, dev);
        const br = self.b.n;
        try self.b.addDevice(D, model, instance, nodes);
        return br;
    }

    fn addByLetter(self: *NetBuilder, letter: u8, dev: types.Device) !void {
        switch (resolveDeviceId(letter, dev, self.nl.models)) {
            inline else => |comptime_id| {
                const D = devices.DeviceId.Type(comptime_id);
                try addSingleDevice(self.b, D, dev, self.nl.models);
            },
        }
    }

    fn resolveDeferred(self: *NetBuilder) !void {
        for (self.deferred[0..self.n_deferred]) |def| {
            switch (def.letter) {
                'f' => try self.addBranchRef(devices.cccs, def.dev, 1.0),
                'h' => try self.addBranchRef(devices.ccvs, def.dev, 0.0),
                'w' => try self.addBranchRef(devices.cswitch, def.dev, null),
                'k' => try self.addKinduc(def.dev),
                else => unreachable,
            }
        }
    }

    // ponytail: linear scan over v_names/l_names — O(n_v) per lookup,
    // fine for typical SPICE circuits (< 100 sources). HashMap if profiled.
    fn findVBranch(self: *const NetBuilder, name: []const u8) ?u32 {
        for (self.v_names[0..self.n_v], self.v_branches[0..self.n_v]) |n, br| {
            if (std.mem.eql(u8, n, name)) return br;
        }
        return null;
    }

    fn findLBranch(self: *const NetBuilder, name: []const u8) ?u32 {
        for (self.l_names[0..self.n_l], self.l_branches[0..self.n_l]) |n, br| {
            if (std.mem.eql(u8, n, name)) return br;
        }
        return null;
    }

    fn addBranchRef(self: *NetBuilder, comptime D: type, dev: types.Device, comptime default_gain: ?f64) !void {
        if (comptime !isValueForm(D)) return error.UnsupportedDevice;
        const ctrl_name = positionalName(dev, 0) orelse return error.MissingControlSource;
        const ctrl_br = self.findVBranch(ctrl_name) orelse return error.UnknownControlSource;

        var model: D.Model = .{};
        if (modelName(dev)) |name| {
            if (findModel(self.nl.models, name)) |m| try applyKv(&model, m.kv);
        }
        var instance: D.Instance = .{};
        if (comptime default_gain) |dflt|
            instance.gain = castField(@TypeOf(instance.gain), positionalNumber(dev, 1) orelse kvNumber(dev.kv, "gain") orelse dflt);
        try applyKv(&instance, dev.kv);

        const nodes = [3]u32{
            if (dev.nodes.len > 0) try self.b.internNode(dev.nodes[0]) else GROUND,
            if (dev.nodes.len > 1) try self.b.internNode(dev.nodes[1]) else GROUND,
            ctrl_br,
        };
        try self.b.addDevice(D, model, instance, nodes);
    }

    fn addKinduc(self: *NetBuilder, dev: types.Device) !void {
        if (comptime !isValueForm(devices.kinduc)) return error.UnsupportedDevice;
        const l1_name = positionalName(dev, 0) orelse return error.KinducMissingInductor;
        const l2_name = positionalName(dev, 1) orelse return error.KinducMissingInductor;
        const ibr1 = self.findLBranch(l1_name) orelse return error.KinducUnknownInductor;
        const ibr2 = self.findLBranch(l2_name) orelse return error.KinducUnknownInductor;
        var model: devices.kinduc.Model = .{};
        if (positionalNumber(dev, 2)) |k| model.k = castField(f32, k);
        if (modelName(dev)) |name| {
            if (findModel(self.nl.models, name)) |m| try applyKv(&model, m.kv);
        }
        try applyKv(&model, dev.kv);
        try self.b.addDevice(devices.kinduc, model, .{}, [2]u32{ ibr1, ibr2 });
    }
};

// ---------------------------------------------------------------------------
// Subcircuit BBD tagging
// ---------------------------------------------------------------------------

fn tagSubcircuitNodes(b: *Builder, dl: types.DeviceList) !void {
    for (0..dl.len()) |i| {
        const dev = dl.get(i);
        if (dev.subckt_instance == 0) continue;
        for (dev.nodes) |node_name| {
            if (b.node_names.get(node_name)) |node_id|
                try b.tagNodeInstance(node_id, dev.subckt_type, dev.subckt_instance);
        }
    }
}

// ---------------------------------------------------------------------------
// Job builder — directive → analysis.Job (no ArrayList)
// ---------------------------------------------------------------------------

fn buildJob(dir: types.Directive, sim: *const Simulation) ?Job {
    const id = analysis.Analysis.get(dir.kind) orelse return null;
    return switch (id) {
        .op => .{ .op = .{} },
        .tran => blk: {
            const a0 = directiveNumber(dir, 0);
            const a1 = directiveNumber(dir, 1);
            const t_stop = a1 orelse a0 orelse break :blk null;
            break :blk .{ .tran = .{ .t_stop = t_stop, .dt_init = if (a1 != null) a0.? else t_stop / 100.0 } };
        },
        .ac => .{ .ac = .{
            .f_start = directiveNumber(dir, dir.args.len -| 2) orelse return null,
            .f_stop = directiveNumber(dir, dir.args.len -| 1) orelse return null,
            .points_per_decade = @intFromFloat(directiveNumber(dir, 1) orelse 10),
        } },
        .dc => blk: {
            const name1 = directiveName(dir, 0) orelse break :blk null;
            _ = name1;
            break :blk .{ .dc = .{
                .start = directiveNumber(dir, 1) orelse 0,
                .stop = directiveNumber(dir, 2) orelse 0,
                .step = directiveNumber(dir, 3) orelse 1,
            } };
        },
        .noise => .{ .noise = .{
            .out_node = sim.nodeIndex(directiveNodeName(dir, 0) orelse return null) catch return null,
            .f_start = directiveNumber(dir, dir.args.len -| 2) orelse return null,
            .f_stop = directiveNumber(dir, dir.args.len -| 1) orelse return null,
            .points_per_decade = @intFromFloat(directiveNumber(dir, dir.args.len -| 3) orelse 10),
        } },
        .pz => .{ .pz = .{} },
        .pss => .{ .pss = .{
            .period = directiveNumber(dir, 0) orelse return null,
        } },
        .hb => .{ .hb = .{
            .f0 = directiveNumber(dir, 0) orelse return null,
            .n_harmonics = @intFromFloat(directiveNumber(dir, 1) orelse 8),
        } },
        // ponytail: remaining analyses follow the same pattern —
        // parse positional args from directive, resolve names via sim.nodeIndex.
        // Expand as each analysis module lands.
        else => null,
    };
}

// ---------------------------------------------------------------------------
// DC ref collection — stable pointers into frozen batches
// ---------------------------------------------------------------------------

fn collectDcRefs(
    ckt: *const Circuit,
    allocator: std.mem.Allocator,
    comptime D: type,
    comptime is_instance: bool,
    count: u32,
) ![]const *f32 {
    // Collect from the matching batch only — collecting every param of every
    // device (and doing it twice, for V and I sources) dominated build time
    // and memory on large netlists.
    var list: std.ArrayList(analysis.ParamRef) = .empty;
    defer list.deinit(allocator);
    for (ckt.batches) |b| {
        if (!std.mem.eql(u8, b.type_name, @typeName(D))) continue;
        try b.collect_params(b.ctx, allocator, &list);
    }
    const refs = list.items;
    const out = try allocator.alloc(*f32, count);
    for (refs) |ref| {
        if (ref.is_instance != is_instance) continue;
        if (!std.mem.eql(u8, ref.param_name, "dc")) continue;
        if (ref.index < count) out[ref.index] = ref.ptr;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Device resolution
// ---------------------------------------------------------------------------

fn resolveDeviceId(letter: u8, dev: types.Device, spice_models: []const types.Model) devices.DeviceId {
    const level = modelLevel(dev, spice_models);
    return switch (letter) {
        'm' => devices.mosfetDeviceId(level),
        'q' => devices.bjtDeviceId(level),
        'd' => devices.diodeDeviceId(level),
        'j' => devices.jfetDeviceId(level),
        else => devices.letter_map.get(&.{letter}) orelse .resistor,
    };
}

fn addSingleDevice(b: *Builder, comptime D: type, dev: types.Device, spice_models: []const types.Model) !void {
    if (comptime !isValueForm(D)) return error.UnsupportedDevice;
    var model: D.Model = .{};
    var instance: D.Instance = .{};
    if (modelName(dev)) |name| {
        if (findModel(spice_models, name)) |m| try applyKv(&model, m.kv);
    }
    if (comptime @hasField(D.Instance, "gain"))
        instance.gain = castField(@TypeOf(instance.gain), positionalNumber(dev, 0) orelse 0);
    try applyKv(&instance, dev.kv);
    try b.addDevice(D, model, instance, try deviceNodes(b, D, dev));
}

// ---------------------------------------------------------------------------
// B-source expression extraction
// ---------------------------------------------------------------------------

fn addBsource(b: *Builder, dev: types.Device, spice_models: []const types.Model) !void {
    if (comptime !isValueForm(devices.bsource)) return error.UnsupportedDevice;
    var model: devices.bsource.Model = .{};
    var instance: devices.bsource.Instance = .{};
    if (modelName(dev)) |name| {
        if (findModel(spice_models, name)) |m| try applyKv(&model, m.kv);
    }
    try applyKv(&model, dev.kv);
    try applyKv(&instance, dev.kv);

    var ctrl_node_name: ?[]const u8 = null;
    for (dev.kv) |item| switch (item.value) {
        .expr => |expr| {
            // Key selects output mode: i={...} = current source, v={...} = voltage source.
            if (item.key.len > 0 and item.key[0] == 'i') model.imode = 1;
            ctrl_node_name = extractSingleVoltageProbe(expr);
            extractPolyCoeffs(expr, &model);
        },
        else => {},
    };

    const nodes = [4]u32{
        if (dev.nodes.len > 0) try b.internNode(dev.nodes[0]) else GROUND,
        if (dev.nodes.len > 1) try b.internNode(dev.nodes[1]) else GROUND,
        if (ctrl_node_name) |cn| try b.internNode(cn) else GROUND,
        GROUND,
    };
    try b.addDevice(devices.bsource, model, instance, nodes);
}

fn extractSingleVoltageProbe(expr: *const types.Expr) ?[]const u8 {
    switch (expr.*) {
        .call => |c| {
            if (std.mem.eql(u8, c.name, "v") and c.args.len >= 1)
                return switch (c.args[0].*) {
                    .ident => |id| id,
                    else => null,
                };
            for (c.args) |arg| if (extractSingleVoltageProbe(arg)) |name| return name;
            return null;
        },
        .binop => |b| return extractSingleVoltageProbe(b.a) orelse extractSingleVoltageProbe(b.b),
        .unop => |u| return extractSingleVoltageProbe(u.a),
        .num, .ident => return null,
    }
}

fn extractPolyCoeffs(expr: *const types.Expr, model: *devices.bsource.Model) void {
    var c: [3]f64 = .{ 0, 0, 0 };
    if (collectTerms(expr, 1.0, &c)) {
        model.c0 = @floatCast(c[0]);
        model.c1 = @floatCast(c[1]);
        model.c2 = @floatCast(c[2]);
    }
}

fn collectTerms(expr: *const types.Expr, scale: f64, c: *[3]f64) bool {
    switch (expr.*) {
        .num => |n| {
            c[0] += scale * n;
            return true;
        },
        .call => |call| {
            if (std.mem.eql(u8, call.name, "v") and call.args.len >= 1) {
                c[1] += scale;
                return true;
            }
            return false;
        },
        .binop => |b| switch (b.op) {
            '+' => return collectTerms(b.a, scale, c) and collectTerms(b.b, scale, c),
            '-' => return collectTerms(b.a, scale, c) and collectTerms(b.b, -scale, c),
            '*' => {
                const da = vDegree(b.a) orelse return false;
                const db = vDegree(b.b) orelse return false;
                if (da + db > 2) return false;
                c[da + db] += scale * numericCoeff(b.a) * numericCoeff(b.b);
                return true;
            },
            else => return false,
        },
        .unop => |u| switch (u.op) {
            '-' => return collectTerms(u.a, -scale, c),
            '+' => return collectTerms(u.a, scale, c),
            else => return false,
        },
        .ident => return false,
    }
}

fn vDegree(expr: *const types.Expr) ?u8 {
    switch (expr.*) {
        .num => return 0,
        .call => |c| return if (std.mem.eql(u8, c.name, "v")) 1 else null,
        .binop => |b| {
            if (b.op != '*') return null;
            const da = vDegree(b.a) orelse return null;
            const db = vDegree(b.b) orelse return null;
            return da + db;
        },
        .unop => |u| return if (u.op == '-' or u.op == '+') vDegree(u.a) else null,
        .ident => return null,
    }
}

fn numericCoeff(expr: *const types.Expr) f64 {
    switch (expr.*) {
        .num => |n| return n,
        .call => return 1.0,
        .binop => |b| return if (b.op == '*') numericCoeff(b.a) * numericCoeff(b.b) else 1.0,
        .unop => |u| return if (u.op == '-') -numericCoeff(u.a) else numericCoeff(u.a),
        .ident => return 1.0,
    }
}

// ---------------------------------------------------------------------------
// Waveform tables
// ---------------------------------------------------------------------------

const Wave = enum(u8) { pulse = 1, sin = 2, exp = 3, pwl = 4, sffm = 5, am = 6 };

const wave_map = std.StaticStringMap(Wave).initComptime(.{
    .{ "pulse", .pulse }, .{ "sin", .sin },   .{ "exp", .exp },
    .{ "pwl", .pwl },     .{ "sffm", .sffm }, .{ "am", .am },
});

fn applySourceWaveform(target: anytype, dev: types.Device) void {
    const T = @TypeOf(target.*);
    for (dev.positional) |pos| {
        const group = switch (pos) {
            .group => |g| g,
            else => continue,
        };
        var buf: [8]u8 = undefined;
        if (group.name.len > buf.len) continue;
        const kind = wave_map.get(std.ascii.lowerString(&buf, group.name)) orelse continue;
        target.waveform = @intFromEnum(kind);
        switch (kind) {
            .pwl => if (comptime @hasField(T, "pwl_times")) {
                var k: usize = 0;
                var i: usize = 0;
                while (i + 1 < group.args.len and k < target.pwl_times.len) : ({
                    i += 2;
                    k += 1;
                }) {
                    if (valueNumber(group.args[i])) |t| target.pwl_times[k] = @floatCast(t);
                    if (valueNumber(group.args[i + 1])) |v| target.pwl_values[k] = @floatCast(v);
                }
                target.pwl_len = @intCast(k);
            },
            inline else => |cw| applyGroupArgs(T, target, group.args, comptime fieldPairs(cw)),
        }
    }
}

fn applyGroupArgs(comptime T: type, target: anytype, args: []const types.Value, comptime field_pairs: []const []const u8) void {
    comptime var i: usize = 0;
    inline while (i < field_pairs.len) : (i += 2) {
        const arg_idx = i / 2;
        if (arg_idx < args.len) {
            if (valueNumber(args[arg_idx])) |v| {
                if (comptime @hasField(T, field_pairs[i])) @field(target.*, field_pairs[i]) = @floatCast(v) else if (comptime @hasField(T, field_pairs[i + 1])) @field(target.*, field_pairs[i + 1]) = @floatCast(v);
            }
        }
    }
}

// ponytail: fieldPairs lives on Wave — same table, moved inline
fn fieldPairs(comptime w: Wave) []const []const u8 {
    return switch (w) {
        .pulse => &.{ "pulse_v1", "pulse_i1", "pulse_v2", "pulse_i2", "pulse_td", "pulse_td", "pulse_tr", "pulse_tr", "pulse_tf", "pulse_tf", "pulse_pw", "pulse_pw", "pulse_per", "pulse_per", "pulse_phase", "pulse_phase" },
        .sin => &.{ "sin_vo", "sin_ioff", "sin_va", "sin_iamp", "sin_freq", "sin_freq", "sin_td", "sin_td", "sin_theta", "sin_theta", "sin_phase", "sin_phase" },
        .exp => &.{ "exp_v1", "exp_i1", "exp_v2", "exp_i2", "exp_td1", "exp_td1", "exp_tau1", "exp_tau1", "exp_td2", "exp_td2", "exp_tau2", "exp_tau2" },
        .pwl => &.{},
        .sffm => &.{ "sffm_vo", "sffm_vo", "sffm_va", "sffm_va", "sffm_fc", "sffm_fc", "sffm_mdi", "sffm_mdi", "sffm_fs", "sffm_fs", "sffm_phasec", "sffm_phasec", "sffm_phases", "sffm_phases" },
        .am => &.{ "am_va", "am_va", "am_vo", "am_vo", "am_mf", "am_mf", "am_fc", "am_fc", "am_td", "am_td", "am_phasec", "am_phasec", "am_phases", "am_phases" },
    };
}

// ---------------------------------------------------------------------------
// Kv / positional utilities
// ---------------------------------------------------------------------------

fn deviceNodes(b: *Builder, comptime D: type, dev: types.Device) ![D.num_ports]u32 {
    var out: [D.num_ports]u32 = undefined;
    inline for (0..D.num_ports) |idx| {
        out[idx] = if (idx < dev.nodes.len) try b.internNode(dev.nodes[idx]) else GROUND;
    }
    return out;
}

fn modelLevel(dev: types.Device, spice_models: []const types.Model) u16 {
    if (modelName(dev)) |name| {
        if (findModel(spice_models, name)) |m| {
            if (kvNumber(m.kv, "level")) |l| return @intFromFloat(l);
        }
    }
    return 1;
}

fn findNameIndex(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, target)) return i;
    return null;
}

fn sweepCount(start: f64, stop: f64, step: f64) usize {
    if (step == 0 or (stop - start) * std.math.sign(step) < 0) return 1;
    return @as(usize, @intFromFloat(@floor((stop - start) / step))) + 1;
}

fn positionalNumber(dev: types.Device, index: usize) ?f64 {
    if (index >= dev.positional.len) return null;
    return valueNumber(dev.positional[index]);
}

fn positionalName(dev: types.Device, index: usize) ?[]const u8 {
    if (index >= dev.positional.len) return null;
    return switch (dev.positional[index]) {
        .name => |n| n,
        else => null,
    };
}

fn directiveName(dir: types.Directive, index: usize) ?[]const u8 {
    if (index >= dir.args.len) return null;
    return switch (dir.args[index]) {
        .name => |n| n,
        else => null,
    };
}

fn directiveNumber(dir: types.Directive, index: usize) ?f64 {
    if (index >= dir.args.len) return null;
    return valueNumber(dir.args[index]);
}

fn directiveNodeName(dir: types.Directive, index: usize) ?[]const u8 {
    if (index >= dir.args.len) return null;
    return switch (dir.args[index]) {
        .name => |n| n,
        .group => |g| if (std.mem.eql(u8, g.name, "v") and g.args.len > 0)
            switch (g.args[0]) {
                .name => |n| n,
                else => null,
            }
        else
            null,
        else => null,
    };
}

fn kvNumber(kv: []const types.Kv, key: []const u8) ?f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) return valueNumber(item.value);
    return null;
}

fn sourceDc(dev: types.Device) f64 {
    if (kvNumber(dev.kv, "dc")) |dc| return dc;
    for (dev.positional, 0..) |pos, idx| switch (pos) {
        .num => |n| return n,
        .group => |group| {
            if (std.mem.eql(u8, group.name, "dc") and group.args.len > 0)
                return valueNumber(group.args[0]) orelse 0;
        },
        .name => |name| {
            if (std.mem.eql(u8, name, "dc"))
                if (positionalNumber(dev, idx + 1)) |dc| return dc;
        },
        else => {},
    };
    return 0;
}

fn modelName(dev: types.Device) ?[]const u8 {
    if (dev.positional.len == 0) return null;
    return switch (dev.positional[0]) {
        .name => |name| name,
        else => null,
    };
}

fn findModel(spice_models: []const types.Model, name: []const u8) ?types.Model {
    for (spice_models) |model| if (std.mem.eql(u8, model.name, name)) return model;
    return null;
}

fn valueNumber(value: types.Value) ?f64 {
    return switch (value) {
        .num => |n| n,
        else => null,
    };
}

fn applyKv(target: anytype, kv: []const types.Kv) !void {
    const T = @TypeOf(target.*);
    @setEvalBranchQuota(10_000);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isScalarAssignable(field.type)) {
            if (kvNumber(kv, field.name)) |num|
                @field(target.*, field.name) = castField(field.type, num);
        }
    }
}

fn isScalarAssignable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        else => false,
    };
}

fn castField(comptime T: type, value: f64) T {
    return switch (@typeInfo(T)) {
        .float => @floatCast(value),
        .int => @intFromFloat(value),
        .bool => value != 0,
        else => @compileError("unsupported numeric field type"),
    };
}
