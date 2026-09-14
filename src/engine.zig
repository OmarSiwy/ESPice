//! engine.zig — orchestrator between the frontend netlist and the analysis module.
//!
//! Data flow:  types.Netlist ──netlist.NetBuilder──▶ builder.Builder
//!             ──compile()──▶ analysis.Circuit ──run()──▶ []Result
//!
//! Netlist→device wiring policy lives in builder.zig; this file owns the
//! Simulation lifecycle: compile, job dispatch, result collection.

const std = @import("std");
const analysis = @import("analysis");
const devices = @import("devices");
const types = @import("frontend/types.zig");
const netlist = @import("builder.zig");
const gpu_context = @import("gpu_context.zig");

const Circuit = analysis.Circuit;
const Job = analysis.Job;
const Result = analysis.Result;
const RunCtx = analysis.RunCtx;
const Builder = @import("builder.zig").Builder;
const GROUND = analysis.GROUND;

const directiveName = netlist.directiveName;
const directiveNumber = netlist.directiveNumber;
const directiveNodeName = netlist.directiveNodeName;
const findNameIndex = netlist.findNameIndex;

// ---------------------------------------------------------------------------
// Sweepable sources: parse-arena scratch, consumed only by buildJob during
// fromNetlist. Never held on the run-time Simulation (would alias dev.name in
// the parse arena). The .dc job resolves source name → index eagerly here.
// ---------------------------------------------------------------------------

const Sources = struct {
    v_names: []const []const u8,
    i_names: []const []const u8,
    v_branches: []const u32,
    /// `{mag, phase deg}` of each V card's `DISTOF1`; `{0, _}` = absent.
    /// `.disto` picks its drive by this, never by card order.
    v_distof1: []const [2]f64,
    /// `.sp` ports declared by `portnum`/`z0` on V cards, in port order.
    /// Empty = no port card, which leaves `.sp` on its one-port fallback.
    ports: []const analysis.sp.Port = &.{},
    /// (device type, ordinal) -> card name, for `.sens` column naming.
    cards: []const analysis.CardRef = &.{},
};

pub const SimConfig = struct {
    /// Engage the GPU at all. False for `--backend cpu` (the default).
    gpu: bool = false,
    /// The user NAMED the device (`--gpu`, `--backend cuda|hip`) rather than
    /// asking for `auto`. One flag because it is one promise: the performance
    /// work-gate is bypassed AND a decline it cannot override is a hard error
    /// naming what was detected, never a silent CPU run. Correctness-driven
    /// fallbacks survive it — see `gpu_context.Decline`.
    gpu_explicit: bool = false,
};

/// One `.ic V(node)=value` card, resolved to a circuit index at build time.
/// Sim-arena lifetime: the node id is only meaningful against the compiled
/// Circuit, and `b.node_names` (the only name table there is) dies inside
/// `compile()`, so the resolution has to happen before that and the result has
/// to outlive the parse arena. Sorted-ness is irrelevant — this is scanned once
/// per uic transient, and decks carry a handful of cards at most.
const Ic = struct {
    node: u32,
    value: f64,
};

// ---------------------------------------------------------------------------
// Simulation — owns circuit, dispatches jobs, collects results
// ---------------------------------------------------------------------------

pub const Simulation = struct {
    arena: std.mem.Allocator,
    circuit: Circuit,
    probes: []u32,
    /// Raw-file column label per probe ("i(v1)", "v(out)"), parallel to
    /// `probes`. Sim-arena: card names die with the parse arena, so the
    /// labels are formatted in fromNetlist.
    probe_labels: []const []const u8,
    source_node: u32,
    source_branch: u32,
    /// Composite AC excitation over the circuit unknowns — see RunCtx.ac_drive.
    ac_drive: []const f64,
    /// Duped into sim_arena: read at output time, after the parse arena is gone.
    title: []const u8,
    n_devices: u32,
    n_directives: u32,
    /// `.ic` cards, node-resolved. Read only by a `uic` transient.
    ic: []const Ic,
    /// `.options` tolerance overrides — the shared OP uses them too.
    deck_tol: analysis.converger.Tolerances,
    /// `.options temp=<C>`, applied once before the first job.
    deck_temp: ?f64,
    jobs: []Job,
    n_jobs: u32,
    results: []Result,
    n_results: u32,
    /// Output-lifetime memory: every Result's data/varnames/plotname is
    /// allocated here (RunCtx.allocator). Lives until the writers finish;
    /// main resets it per deck. Attached in run() for the same by-value
    /// stability reason as par_eval — `.allocator()` captures `&self`.
    results_arena: std.heap.ArenaAllocator,
    /// Parallel eval context (policy: created here, referenced by Circuit).
    par_eval: ?devices.par.ParEval,
    /// `--gpu`. Acted on in `run()`, not here: `fromNetlist` returns by value,
    /// so a context holding `&sim.circuit` taken now would dangle — the same
    /// reason `par_eval` is attached late.
    gpu_requested: bool,
    /// SimConfig.gpu_explicit — the user named the device, so the work gate is
    /// off and a machine-level refusal is an error rather than a CPU run.
    gpu_explicit: bool,
    gpu_ctx: ?*gpu_context.GpuContext,
    /// Operating point memo, indexed by flavor: [0] DCOP, [1] TRANOP. Each
    /// is solved once on first demand and shared across jobs of that flavor.
    op_cache: [2]?[]f64,

    /// `sim_arena` owns everything that outlives fromNetlist: Circuit,
    /// Workspace, jobs, probes, par_eval, the duped title. `parse_arena` owns
    /// the transient wiring — NetBuilder scratch and the dyn-device blobs
    /// (proto_add copies them into sim_arena storage) — and may be reset by the
    /// caller the moment this returns. The Builder runs on sim_arena so the
    /// frozen intern table is never a slice into parse memory.
    pub fn fromNetlist(sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, nl: types.Netlist, io: ?std.Io, config: SimConfig) !Simulation {
        const deck_opts = parseDeckOptions(nl.directives);
        var b = Builder.init(sim_arena);
        var compiled_ok = false;
        errdefer if (!compiled_ok) b.deinit();

        // Before `nb.build()`, because `.options tnom` is a MODEL-CARD default
        // (`b4set.c:1950`), not an analysis knob: every model is derived from
        // it as it is created, so nothing downstream has to re-derive and
        // `collapse` sees its final answer the first time.
        b.nom_temp_c = deck_opts.tnom_c;

        // Node count is bounded by (and usually close to) device count;
        // reserving here avoids incremental rehash during interning.
        try b.reserveNodes(@intCast(@min(nl.devices.len(), std.math.maxInt(u32))));

        var nb = try netlist.NetBuilder.init(parse_arena, &b, nl);
        try nb.build();

        try netlist.tagSubcircuitNodes(&b, nl.devices);

        // Runtime-loaded (.hdl card, dlopen'd) VA/V devices: erased Proto
        // path, batch machinery lives inside the model's .so. Must happen
        // before compile() freezes the pattern.
        try netlist.addDynDevices(&b, parse_arena, nl);

        var sim: Simulation = undefined;
        sim.arena = sim_arena;
        // Backed by sim_arena: reset(retain_capacity) reclaims result memory
        // between decks without tearing down the circuit. Only its .allocator()
        // is deferred to run() (captures &self); the value itself is stable.
        sim.results_arena = std.heap.ArenaAllocator.init(sim_arena);
        // Resolve the output node before compile() destroys the name table.
        const dir_nodes = try parse_arena.alloc(u32, nl.directives.len);
        for (nl.directives, dir_nodes) |dir, *id| {
            const arg: usize = if (std.ascii.eqlIgnoreCase(dir.kind, "four")) 1 else 0;
            if (analysis.Analysis.get(dir.kind) != null and arg < dir.args.len) switch (dir.args[arg]) {
                .group => |g| if (g.args.len != 1) return error.UnsupportedAnalysisOutput,
                else => {},
            };
            const name = directiveNodeName(dir, arg) orelse
                (if (arg < dir.args.len) icNodeName(parse_arena, dir.args[arg]) else null);
            id.* = if (name) |n| b.node_names.get(n) orelse NO_NODE else NO_NODE;
        }

        // `.ic` cards, resolved here for the same reason as `dir_nodes`: this is
        // the last point where `b.node_names` exists. Two passes so the result
        // is an exact sim-arena slice rather than a growable list — the count is
        // known from the arg shape (`v(node)` group followed by its value).
        var n_ic: usize = 0;
        for (nl.directives) |dir| {
            if (!std.ascii.eqlIgnoreCase(dir.kind, "ic")) continue;
            n_ic += dir.args.len / 2;
        }
        const ic_buf = try sim_arena.alloc(Ic, n_ic);
        var n_ic_used: usize = 0;
        for (nl.directives) |dir| {
            if (!std.ascii.eqlIgnoreCase(dir.kind, "ic")) continue;
            var i: usize = 0;
            while (i + 1 < dir.args.len) : (i += 2) {
                const name = icNodeName(parse_arena, dir.args[i]) orelse continue;
                const value = netlist.valueNumber(dir.args[i + 1]) orelse continue;
                // An `.ic` on a node the netlist never mentions is a typo, not a
                // constraint. Dropping it silently matches how the rest of the
                // directive path treats unresolvable names.
                const id = b.node_names.get(name) orelse continue;
                if (id == GROUND) continue;
                ic_buf[n_ic_used] = .{ .node = id, .value = value };
                n_ic_used += 1;
            }
        }
        sim.ic = ic_buf[0..n_ic_used];

        // compile() may apply the BBD node permutation (subckt decks) and
        // undefines the Builder on return, so the permutation comes back via
        // this out-param, not off `b`. Every index recorded BEFORE compile —
        // source branches/ports, inductor branches, `.ic` nodes, directive
        // nodes — is in old coordinates; the device protos were permuted
        // through applyPerm but these caller-side tables were not, which is
        // how a subckt branch probe read a voltage (fourbitadder i(vin1a) at
        // ~5 V). `mapNode` is the identity when perm is null (no BBD).
        var perm: ?[]const u32 = null;
        // compilePerm tears the Builder shell down; the card table is the one
        // thing on it that outlives the freeze (`.sens` names columns with it).
        // Rows are already on sim_arena — only the parse-arena name strings
        // have to be copied.
        const cards = try sim_arena.dupe(analysis.CardRef, b.cards.items);
        for (cards) |*c| c.name = try sim_arena.dupe(u8, c.name);
        sim.circuit = try b.compilePerm(&perm);
        // ponytail: opt-in until an end-to-end gate beats serial on sparse
        // block interiors; dense flop estimates alone overpredict their work.
        const solver_threads = if (std.c.getenv("ESPICE_SOLVER_THREADS")) |s|
            std.fmt.parseInt(u32, std.mem.span(s), 10) catch 1
        else
            1;
        sim.circuit.solver_execution = .{ .io = io, .threads = @intCast(@min(solver_threads, 16)) };
        compiled_ok = true;

        errdefer sim.circuit.deinit();

        const mapNode = struct {
            fn f(p: ?[]const u32, id: u32) u32 {
                const pp = p orelse return id;
                return if (id < pp.len) pp[id] else id;
            }
        }.f;
        for (nb.v_branches[0..nb.n_v]) |*v| v.* = mapNode(perm, v.*);
        // `v_ports` is build-time scratch everywhere EXCEPT portList, which
        // runs below and hands the row straight to the .sp solve.
        for (nb.v_ports[0..nb.n_v]) |*v| v.* = mapNode(perm, v.*);
        for (nb.br_rows[0..nb.n_br]) |*v| v.* = mapNode(perm, v.*);
        for (nb.l_branches[0..nb.n_l]) |*v| v.* = mapNode(perm, v.*);
        for (nb.ac_pos[0..nb.n_ac]) |*v| v.* = mapNode(perm, v.*);
        for (nb.ac_neg[0..nb.n_ac]) |*v| v.* = mapNode(perm, v.*);
        nb.source_node = mapNode(perm, nb.source_node);
        nb.source_branch = mapNode(perm, nb.source_branch);
        for (dir_nodes) |*v| {
            if (v.* != NO_NODE) v.* = mapNode(perm, v.*);
        }
        for (ic_buf[0..n_ic_used]) |*e| e.node = mapNode(perm, e.node);
        sim.gpu_requested = config.gpu;
        sim.gpu_explicit = config.gpu_explicit;
        sim.gpu_ctx = null;
        sim.op_cache = .{ null, null };

        // Escapes into run-time lifetime: title read at output time, counts in
        // the summary. Dupe/copy off the parse arena so it can be reset now.
        sim.title = try sim_arena.dupe(u8, nl.title);
        sim.n_devices = @intCast(nl.devices.len());
        sim.n_directives = @intCast(nl.directives.len);

        sim.source_node = nb.source_node;
        sim.source_branch = nb.source_branch;
        // Every `AC`-carrying source collapsed into ONE excitation vector, in
        // post-permutation coordinates. Built here rather than per analysis
        // because it is deck data, not analysis data.
        sim.ac_drive = try nb.acExcitation(sim_arena, sim.circuit.n);

        // Sources are parse-arena scratch; resolved into job indices below and
        // never stored on `sim`.
        const sources: Sources = .{
            .v_names = nb.v_names[0..nb.n_v],
            .i_names = nb.i_names[0..nb.n_i],
            .v_branches = nb.v_branches[0..nb.n_v],
            .v_distof1 = nb.v_distof1[0..nb.n_v],
            // Ports outlive `sources` — `.sp` Options holds the slice — so it
            // lands on the sim arena, not the parse arena.
            .ports = try nb.portList(sim_arena),
            .cards = cards,
        };

        // `ac=` overrides, card name -> (type, ordinal) -> ParamRef. Resolvable
        // only here: the ordinals come from the card table and the pointers
        // from the frozen batch storage, so neither exists before this point.
        if (nb.n_ac_res > 0) sim.circuit.ac_params = try acParams(
            sim_arena,
            &sim.circuit,
            cards,
            nb.ac_res_names[0..nb.n_ac_res],
            nb.ac_res_values[0..nb.n_ac_res],
        );

        // Probes: branch currents first, then every named node. The rule is
        // ngspice's and it is structural, not a list of letters: every MNA
        // branch-current unknown gets a `CKTmkCur` row and `CKTnames` turns
        // every such row into an `i(<card>)` column. That covers V and L, and
        // equally E (vcvsset.c:41-46), H (ccvsset.c:41-46) and a V-mode B
        // (asrcsetup.c:78-83) — `nb.br_*` carries those. F, G and S stamp no
        // branch and correctly have no column.
        //
        // A V card sensed by F/H/W is NOT skipped: it keeps its current, which
        // now lives on the controlling model's `ctrl` branch (builder
        // addBranchRef rewrites `v_branches[ctrl]` to that row). ngspice emits
        // i(vam) for it too.
        //
        // Branch-first, NOT ngspice's voltage-first: tf/sens/dcmatch/pxf/pac/
        // disto default their output variable to probes[len-1], so the last
        // probe must stay the last NAMED NODE. Raw readers key on column
        // names, never position.
        // Named nodes and branch rows are disjoint (branches carry no label),
        // so circuit.n bounds the total.
        const probe_buf = try sim_arena.alloc(u32, sim.circuit.n);
        const label_buf = try sim_arena.alloc([]const u8, sim.circuit.n);
        var n_probes: u32 = 0;
        for ([_][]const []const u8{ nb.v_names[0..nb.n_v], nb.l_names[0..nb.n_l], nb.br_names[0..nb.n_br] },
            [_][]const u32{ nb.v_branches[0..nb.n_v], nb.l_branches[0..nb.n_l], nb.br_rows[0..nb.n_br] }) |names, rows|
        {
            for (names, rows) |name, br| {
                probe_buf[n_probes] = br;
                label_buf[n_probes] = try std.fmt.allocPrint(sim_arena, "i({s})", .{name});
                n_probes += 1;
            }
        }
        for (1..sim.circuit.n) |i| {
            const label = sim.circuit.nodeName(@intCast(i));
            if (label.len != 0) {
                probe_buf[n_probes] = @intCast(i);
                label_buf[n_probes] = try std.fmt.allocPrint(sim_arena, "v({s})", .{label});
                n_probes += 1;
            }
        }
        sim.probes = probe_buf[0..n_probes];
        sim.probe_labels = label_buf[0..n_probes];

        // Jobs from directives. TWO per directive: a swept `.noise` card is
        // two ngspice plots, the spectral density curves and the band
        // integral (noisean.c:318-325 and :516-522), and one Result is one
        // plot. Every other card takes one slot and leaves the other.
        sim.deck_tol = deck_opts.tol;
        sim.deck_temp = deck_opts.temp_c;
        sim.jobs = try sim_arena.alloc(Job, nl.directives.len * 2);
        sim.n_jobs = 0;
        for (nl.directives, dir_nodes) |dir, node_id| {
            if (try buildJob(dir, node_id, sources)) |job0| {
                var job = job0;
                applyDeckOptions(&job, deck_opts);
                sim.jobs[sim.n_jobs] = job;
                sim.n_jobs += 1;
                // noisean.c:495 — no "Integrated Noise" plot for a degenerate
                // band, because there is nothing to integrate over.
                if (job == .noise and job.noise.f_start != job.noise.f_stop) {
                    job.noise.integrated = true;
                    sim.jobs[sim.n_jobs] = job;
                    sim.n_jobs += 1;
                }
            }
        }

        // Results: one per job max
        sim.results = try sim_arena.alloc(Result, @max(sim.n_jobs, 1));
        sim.n_results = 0;

        // Parallel device eval. ponytail: OPT-IN via ESPICE_THREADS=N for
        // now — measured 2026-07-04, per-eval handoff + window zero/reduce
        // breaks even with eval work on the current fixture corpus, so
        // default-on would regress small/medium circuits. Auto-enable
        // (work-based threshold) is the Phase-5 tuning task.
        sim.par_eval = null;
        if (io) |io_val| enable_par: {
            const s = std.c.getenv("ESPICE_THREADS") orelse break :enable_par;
            const lanes = std.fmt.parseInt(u32, std.mem.span(s), 10) catch break :enable_par;
            if (lanes < 2) break :enable_par;
            var total: u64 = 0;
            for (sim.circuit.batches) |batch| total += batch.count;
            if (total < devices.par.default_min_instances) break :enable_par;
            const ckt = &sim.circuit;
            // ESPICE_THREADS is honoured as asked. It used to be `@min(lanes,
            // 16)`, silently, which made every "32 lanes" measurement a 16-lane
            // measurement. The only clamp left is against the machine, and it
            // says so on stderr instead of pretending.
            const cpus: u32 = @intCast(std.Thread.getCpuCount() catch 16);
            const n_lanes = if (lanes > cpus) blk: {
                std.debug.print("espice: ESPICE_THREADS={d} exceeds {d} CPUs; using {d} lanes\n", .{ lanes, cpus, cpus });
                break :blk cpus;
            } else lanes;
            sim.par_eval = devices.par.ParEval.init(sim_arena, io_val, ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, ckt.trash_slot, n_lanes) catch break :enable_par;
        }

        return sim;
    }

    pub fn deinit(self: *Simulation) void {
        self.circuit.par_eval = null;
        self.circuit.gpu_hook = null;
        if (self.gpu_ctx) |g| g.deinit();
        if (self.par_eval) |*p| p.deinit();
        self.results_arena.deinit();
        self.circuit.deinit();
    }

    fn prepare(self: *Simulation) !RunCtx {
        // Attach here, not in fromNetlist: sim is returned by value there, so
        // a &self.par_eval taken earlier would dangle. `self` is stable now.
        if (self.par_eval) |*p| self.circuit.par_eval = p;

        // Same stability rule for the GPU context, which holds `&self.circuit`
        // and uploads the whole circuit to the device at init.
        //
        // Nothing here is EVER swallowed. `--gpu` silently meaning "ran on the
        // CPU" is exactly how the benchmark came to report CPU timings in its
        // GPU column, so every refusal either prints or returns.
        if (self.gpu_requested) {
            if (gpu_context.GpuContext.init(self.arena, &self.circuit, self.gpu_explicit)) |g| {
                self.gpu_ctx = g;
                self.circuit.gpu_hook = g.hook();
                self.circuit.gpu_active = true;
            } else |e| switch (gpu_context.declineKind(e)) {
                // POLICY. Only `auto` can reach this — an explicit request set
                // `gpu_explicit`, which turns the work gate off entirely.
                .policy => std.debug.print(
                    "note: auto declined the GPU; too little device work to beat the PCIe " ++
                        "round trip (override with --gpu, or tune ESPICE_GPU_MIN_WORK)\n",
                    .{},
                ),
                // CAPABILITY: no device type in this circuit has a kernel, or
                // every model that does was excluded from emission. No flag
                // changes that, so even an explicit request falls back — but
                // `init` has already named each demoted batch.
                .capability => std.debug.print(
                    "warning: GPU declined ({s}); nothing in this circuit has a device " ++
                        "kernel — running on the CPU\n",
                    .{@errorName(e)},
                ),
                // MACHINE: absent device, dead driver, exhausted memory, or a
                // build carrying no images at all. An explicit request names
                // what was detected and stops; `auto` warns and falls back.
                .machine => {
                    if (self.gpu_explicit) {
                        std.debug.print(
                            "Error: GPU requested but unavailable ({s}); detected artifacts: {s}\n",
                            .{ @errorName(e), gpu_context.detectedName() },
                        );
                        return e;
                    }
                    std.debug.print("warning: GPU unavailable ({s}); running on the CPU\n", .{@errorName(e)});
                },
            }
        }
        // `.options temp=<C>` — once, before any solve; device physics keys
        // off Instance.temperature, which setCircuitTemp republishes.
        if (self.deck_temp) |t| {
            self.circuit.setCircuitTemp(@floatCast(t));
            try self.circuit.recompute();
        }

        return .{
            .circuit = &self.circuit,
            .x_op = null,
            .probes = self.probes,
            .probe_labels = self.probe_labels,
            .source_node = self.source_node,
            .source_branch = self.source_branch,
            .ac_drive = self.ac_drive,
            // Results land in the output-lifetime arena. Stable now (self is
            // pinned), so taking .allocator() no longer dangles.
            .allocator = self.results_arena.allocator(),
            .scratch_allocator = std.heap.smp_allocator,
        };
    }

    pub fn run(self: *Simulation) !void {
        var ctx = try self.prepare();

        // If no jobs queued, run an implicit OP (DC-flavored).
        if (self.n_jobs == 0) {
            ctx.x_op = try self.ensureOp(false);
            self.results[0] = try analysis.run(&ctx, .{ .op = .{} });
            self.n_results = 1;
            return;
        }

        for (self.jobs[0..self.n_jobs]) |job| {
            // Every job starts from a DEFINED device sim state; nothing may
            // inherit its predecessor's. Two leaks otherwise: a deck whose op
            // ran TRANOP-flavored left `.ic` behind, so a following .dc/.ac
            // biased waveform sources at t = 0 instead of their DC value —
            // and a job AFTER a transient inherited t = t_stop, biasing the
            // next linearization at end-of-run waveform values. Transient-
            // family jobs re-establish their own state internally.
            const tf = isTranFlavor(job);
            self.circuit.setSimState(.{ .kind = if (tf) .ic else .dc });
            const uic = switch (job) {
                .tran => |o| o.uic,
                else => false,
            };
            if (uic) {
                // `.tran ... uic`: no operating point at all. The starting
                // point is the `.ic` cards over a zero vector — ngspice's rule,
                // and the reason uic exists (a latch or an oscillator has no
                // useful DC solution to start from).
                //
                // Handed over on a COPY of the context: `ctx.x_op` is the
                // memoized operating point every later job reuses, and an IC
                // guess is not one. Writing it there would silently feed a
                // following .ac or .noise a linearization about a point no
                // solver ever converged.
                var uic_ctx = ctx;
                uic_ctx.x_op = try self.icVector();
                self.results[self.n_results] = try analysis.run(&uic_ctx, job);
            } else {
                ctx.x_op = try self.ensureOp(tf);
                self.results[self.n_results] = try analysis.run(&ctx, job);
            }
            self.n_results += 1;
        }
    }

    pub fn getResults(self: *const Simulation) []const Result {
        return self.results[0..self.n_results];
    }

    /// Single-transient output without retaining a Waveform or Result buffer.
    pub fn runTransient(self: *Simulation, recorder: anytype) !analysis.tran.SimResult {
        if (self.n_jobs != 1 or std.meta.activeTag(self.jobs[0]) != .tran)
            return error.ExpectedSingleTransient;
        _ = try self.prepare();
        const opts = self.jobs[0].tran;
        self.circuit.setSimState(.{ .kind = .ic });
        const initial = if (opts.uic) try self.icVector() else try self.ensureOp(true);
        const a = std.heap.smp_allocator;
        const x = try a.dupe(f64, initial);
        defer a.free(x);
        const result = try analysis.tran.simulateInto(&self.circuit, x, self.probes, recorder, opts, a);
        if (!result.completed) return error.TimestepTooSmall;
        return result;
    }

    /// uic starting point: zero everywhere except the `.ic` nodes.
    fn icVector(self: *Simulation) ![]f64 {
        const x = try self.arena.alloc(f64, self.circuit.n);
        @memset(x, 0);
        for (self.ic) |e| if (e.node < x.len) {
            x[e.node] = e.value;
        };
        return x;
    }

    /// ngspice's TRANOP/DCOP split — now per FLAVOR, not per deck. A source
    /// with both a DC value and a waveform (`Vin 1 0 DC 1 SIN(0 1 …)`) biases
    /// at DC 1 for `.op`/`.ac`/`.dc`/`.noise` but at the waveform's t = 0 (0)
    /// for the transient's starting point — two different operating points,
    /// each memoized once and shared by every job of that flavor (res_array
    /// read v(1)=0 instead of 1 when one deck-wide TRANOP op served its .op).
    fn ensureOp(self: *Simulation, tran_flavor: bool) ![]f64 {
        const slot = &self.op_cache[@intFromBool(tran_flavor)];
        if (slot.*) |x| return x;
        const x = try self.arena.alloc(f64, self.circuit.n);
        const result = try analysis.AnalysisId.Module(.op).solve(&self.circuit, x, .{ .tol = self.deck_tol, .tran_op = tran_flavor });
        if (!result.converged) return error.OpDidNotConverge;
        slot.* = x;
        return x;
    }
};

/// Analyses whose starting operating point biases waveform sources at t = 0
/// (LRM "ic" phase) rather than at their DC value.
fn isTranFlavor(job: Job) bool {
    return switch (job) {
        .tran, .four, .tran_noise, .envelope, .pss, .qpss, .pnoise, .pac, .pxf => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Job builder — directive → analysis.Job (no ArrayList)
// ---------------------------------------------------------------------------

/// No node named in the directive, or a name no node answers to.
const NO_NODE: u32 = std.math.maxInt(u32);

/// The node inside an `.ic v(<node>)=<value>` group. `v(2)` tokenizes the node
/// as a NUMBER while `node_names` is keyed by the string the device cards used,
/// so an integral node has to be spelled back out before the lookup.
fn icNodeName(arena: std.mem.Allocator, value: types.Value) ?[]const u8 {
    const g = switch (value) {
        .group => |g| g,
        else => return null,
    };
    if (!std.ascii.eqlIgnoreCase(g.name, "v") or g.args.len == 0) return null;
    return switch (g.args[0]) {
        .name => |n| n,
        .num => |n| if (n == @trunc(n) and @abs(n) < 1e9)
            std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))}) catch null
        else
            null,
        else => null,
    };
}

/// Parsed `.options` overrides. One pass over the deck's directives; the
/// parser already splits `key=value` into adjacent name/value args.
const DeckOptions = struct {
    tol: analysis.converger.Tolerances = .{},
    method: ?analysis.tran.Method = null,
    temp_c: ?f64 = null,
    /// `.options tnom=<degC>` — ngspice `cktsopt.c:71-73` stores it as
    /// `TSKnomTemp = val + CONSTCtoK`, so the CARD is Celsius; the default is
    /// `cktntask.c:127`'s 300.15 K = 27 degC. Independent of `.options temp`
    /// (`OPT_TEMP`, the same file's next case): nominal is where the model card
    /// was extracted, `temp` is where the circuit is being run.
    ///
    /// Not optional and not applied per job: unlike `temp`, this is not an
    /// analysis knob — it reaches the devices at BUILD time, before the
    /// pattern is frozen, so no sweep can move it and `recompute`'s
    /// topology-change path is never involved.
    tnom_c: f64 = 27.0,
};

fn parseDeckOptions(directives: []const types.Directive) DeckOptions {
    var o: DeckOptions = .{};
    var maxord: ?f64 = null;
    var gear = false;
    for (directives) |dir| {
        if (std.ascii.eqlIgnoreCase(dir.kind, "temp") and dir.args.len == 1) {
            o.temp_c = directiveNumber(dir, 0);
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(dir.kind, "options") and
            !std.ascii.eqlIgnoreCase(dir.kind, "option") and
            !std.ascii.eqlIgnoreCase(dir.kind, "opt") and
            !std.ascii.eqlIgnoreCase(dir.kind, "opts")) continue;
        var i: usize = 0;
        while (i < dir.args.len) : (i += 1) {
            const key = switch (dir.args[i]) {
                .name => |n| n,
                else => continue,
            };
            const num: ?f64 = if (i + 1 < dir.args.len) switch (dir.args[i + 1]) {
                .num => |v| v,
                else => null,
            } else null;
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(key, "method")) {
                if (i + 1 < dir.args.len) switch (dir.args[i + 1]) {
                    .name => |m| {
                        if (eq(m, "gear")) gear = true;
                        if (eq(m, "trap") or eq(m, "trapezoidal")) o.method = .trapezoidal;
                        i += 1;
                    },
                    else => {},
                };
                continue;
            }
            const v = num orelse continue;
            if (eq(key, "reltol")) o.tol.reltol = v;
            if (eq(key, "abstol")) o.tol.abstol = v;
            if (eq(key, "vntol")) o.tol.vntol = v;
            if (eq(key, "gmin")) o.tol.gmin = v;
            if (eq(key, "trtol")) o.tol.trtol = v;
            if (eq(key, "chgtol")) o.tol.chgtol = v;
            if (eq(key, "itl1")) o.tol.itl1 = @intFromFloat(v);
            if (eq(key, "itl2")) o.tol.itl2 = @intFromFloat(v);
            if (eq(key, "itl4")) o.tol.itl4 = @intFromFloat(v);
            if (eq(key, "maxord")) maxord = v;
            if (eq(key, "temp")) o.temp_c = v;
            if (eq(key, "tnom")) o.tnom_c = v; // cktsopt.c:268 `{ "tnom", OPT_TNOM, ... }`
            i += 1;
        }
    }
    if (gear) o.method = if (maxord != null and maxord.? < 2) .backward_euler else .gear_2;
    return o;
}

/// `uic` is a trailing KEYWORD, not a positional: `.tran 1n 100n uic` and
/// `.tran 1n 100n 0 1n uic` are both legal, so scan rather than index.
fn hasUic(dir: types.Directive) bool {
    for (dir.args) |a| switch (a) {
        .name => |n| if (std.ascii.eqlIgnoreCase(n, "uic")) return true,
        else => {},
    };
    return false;
}

fn applyDeckOptions(job: *Job, o: DeckOptions) void {
    switch (job.*) {
        inline else => |*opts| {
            if (comptime @hasField(@TypeOf(opts.*), "tol")) opts.tol = o.tol;
            if (comptime @hasField(@TypeOf(opts.*), "dc_options")) opts.dc_options.tol = o.tol;
            if (comptime @hasField(@TypeOf(opts.*), "temp_k")) {
                if (o.temp_c) |temp| opts.temp_k = temp + 273.15;
            }
        },
    }
    if (job.* == .temp) job.temp.t_nom = o.temp_c orelse 27;
    if (o.method) |m| switch (job.*) {
        .tran => |*t| t.method = m,
        else => {},
    };
}

fn number(dir: types.Directive, i: usize) !f64 {
    const n = directiveNumber(dir, i) orelse return error.InvalidAnalysisArguments;
    if (!std.math.isFinite(n)) return error.InvalidAnalysisArguments;
    return n;
}

fn positive(dir: types.Directive, i: usize) !f64 {
    const n = try number(dir, i);
    if (n <= 0) return error.InvalidAnalysisArguments;
    return n;
}

fn count(comptime T: type, dir: types.Directive, i: usize, default: T) !T {
    if (i >= dir.args.len) return default;
    const n = try positive(dir, i);
    if (n != @trunc(n) or n > std.math.maxInt(T)) return error.InvalidAnalysisArguments;
    return @intFromFloat(n);
}

fn arity(dir: types.Directive, min: usize, max: usize) !void {
    if (dir.args.len < min or dir.args.len > max) return error.InvalidAnalysisArguments;
}

fn outputNode(node: u32) !u32 {
    if (node == NO_NODE or node == GROUND) return error.AnalysisNodeNotFound;
    return node;
}

/// Resolve `<card> ac=<value>` to the ParamRef of that card's resistance.
/// One linear pass per override; decks spell a handful of these at most.
fn acParams(
    arena: std.mem.Allocator,
    ckt: *analysis.Circuit,
    cards: []const analysis.CardRef,
    names: []const []const u8,
    values: []const f64,
) ![]analysis.AcParam {
    const refs = try ckt.collectParams();
    var out: std.ArrayList(analysis.AcParam) = .empty;
    for (names, values) |name, value| {
        for (refs) |ref| {
            if (!std.mem.eql(u8, ref.param_name, "r")) continue;
            const card = analysis.CardRef.lookup(cards, ref) orelse continue;
            if (!std.mem.eql(u8, card, name)) continue;
            try out.append(arena, .{ .ptr = ref, .ac_value = value });
            break;
        }
    }
    return out.toOwnedSlice(arena);
}

fn voltageSource(dir: types.Directive, i: usize, sources: Sources) !usize {
    const name = directiveName(dir, i) orelse return error.InvalidAnalysisArguments;
    return findNameIndex(sources.v_names, name) orelse error.AnalysisSourceNotFound;
}

fn dcSource(dir: types.Directive, i: usize, sources: Sources) !u32 {
    const name = directiveName(dir, i) orelse return error.InvalidAnalysisArguments;
    if (findNameIndex(sources.v_names, name)) |index| return @intCast(index);
    if (findNameIndex(sources.i_names, name)) |index| {
        // ponytail: DC Options has only a batch-local index; add source kind
        // before permitting mixed V/I decks, where indices otherwise alias.
        if (sources.v_names.len != 0) return error.UnsupportedMixedCurrentSweep;
        return @intCast(index);
    }
    return error.AnalysisSourceNotFound;
}

fn checkStep(start: f64, stop: f64, step: f64) !void {
    const intervals = (stop - start) / step;
    if (step == 0 or !std.math.isFinite(intervals) or intervals < 0 or
        intervals >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidAnalysisArguments;
}

/// Only DEC is supported by the shared frequency sweep. Reject LIN/OCT
/// instead of silently executing a different frequency grid.
fn frequencyOptions(comptime T: type, dir: types.Directive, offset: usize) !T {
    const mode = directiveName(dir, offset) orelse return error.InvalidAnalysisArguments;
    if (!std.ascii.eqlIgnoreCase(mode, "dec")) return error.UnsupportedFrequencySweep;
    const first = try positive(dir, offset + 2);
    const last = try positive(dir, offset + 3);
    if (last < first) return error.InvalidAnalysisArguments;
    return .{ .f_start = first, .f_stop = last, .points_per_decade = try count(u16, dir, offset + 1, 10) };
}

fn buildJob(dir: types.Directive, node_id: u32, sources: Sources) !?Job {
    const id = analysis.Analysis.get(dir.kind) orelse return null;
    switch (id) {
        .op => {
            try arity(dir, 0, 0);
            return .{ .op = .{} };
        },
        .tran, .tran_noise, .matex => {
            try arity(dir, 2, if (id == .tran) 5 else 2);
            const step = try positive(dir, 0);
            const stop = try positive(dir, 1);
            if (id == .matex) return .{ .matex = .{ .t_stop = stop, .h_output_cap = step } };
            if (id == .tran_noise) return .{ .tran_noise = .{ .t_stop = stop, .dt_init = step, .dt_max = step } };
            var numeric_end = dir.args.len;
            const uic = hasUic(dir);
            if (uic) numeric_end -= 1;
            if (numeric_end > 4) return error.InvalidAnalysisArguments;
            // Output suppression is not implemented: never silently ignore it.
            if (numeric_end > 2 and try number(dir, 2) != 0) return error.UnsupportedTransientStart;
            return .{ .tran = .{ .t_stop = stop, .dt_init = step, .dt_max = if (numeric_end > 3) try positive(dir, 3) else @min(step, stop / 50), .uic = uic } };
        },
        .ac, .disto => {
            try arity(dir, 4, 4);
            if (id == .ac) return .{ .ac = try frequencyOptions(analysis.ac.Options, dir, 0) };
            var opts = try frequencyOptions(analysis.disto.Options, dir, 0);
            // ngspice cktdisto.c:100-117: the F1 drive is whichever card
            // carries DISTOF1 — never "the first source" — and it lands on
            // that card's BRANCH row. `disto/bjt_ce` is the proof: its first V
            // card is the supply Vcc and the DISTOF1 is on Vin.
            // ponytail: first such card only. ngspice sums every DISTOF1
            // source into one RHS; no fixture has two, and the loop is the
            // upgrade when one does.
            for (sources.v_branches, sources.v_distof1) |br, d| {
                if (d[0] == 0) continue;
                opts.drive_branch = br;
                opts.ac_magnitude = d[0];
                opts.ac_phase = d[1];
                break;
            }
            return .{ .disto = opts };
        },
        .dc => {
            if (dir.args.len != 4 and dir.args.len != 8) return error.InvalidAnalysisArguments;
            var opts: analysis.dc.Options = .{ .source_index = try dcSource(dir, 0, sources), .start = try number(dir, 1), .stop = try number(dir, 2), .step = try number(dir, 3) };
            try checkStep(opts.start, opts.stop, opts.step);
            if (dir.args.len == 8) {
                const name = directiveName(dir, 4) orelse return error.InvalidAnalysisArguments;
                if (std.ascii.eqlIgnoreCase(name, "temp")) opts.source2_is_temp = true else opts.source2_index = try dcSource(dir, 4, sources);
                opts.start2 = try number(dir, 5);
                opts.stop2 = try number(dir, 6);
                opts.step2 = try number(dir, 7);
                try checkStep(opts.start2, opts.stop2, opts.step2);
            }
            return .{ .dc = opts };
        },
        .noise, .pnoise => {
            try arity(dir, if (id == .noise) 6 else 7, if (id == .noise) 6 else 8);
            // The card's second argument names the INPUT source, and ngspice
            // keys the input-referred spectrum on it (noisean.c:89, :416-430).
            // Resolving it and dropping it is what left `inoise_spectrum`
            // with nothing to divide by.
            const in_branch = sources.v_branches[try voltageSource(dir, 1, sources)];
            const sweep = try frequencyOptions(analysis.ac.Options, dir, 2);
            const node = try outputNode(node_id);
            if (id == .noise) return .{ .noise = .{ .out_node = node, .in_branch = in_branch, .f_start = sweep.f_start, .f_stop = sweep.f_stop, .points_per_decade = sweep.points_per_decade } };
            const sidebands = if (dir.args.len == 8) try number(dir, 7) else 7;
            if (sidebands < 0 or sidebands != @trunc(sidebands) or sidebands > 31) return error.InvalidAnalysisArguments;
            return .{ .pnoise = .{ .out_node = node, .f_start = sweep.f_start, .f_stop = sweep.f_stop, .points_per_decade = sweep.points_per_decade, .f_fundamental = try positive(dir, 6), .n_sidebands = @intFromFloat(sidebands) } };
        },
        .tf => {
            try arity(dir, 2, 2);
            return .{ .tf = .{ .output_node = try outputNode(node_id), .input_branch = sources.v_branches[try voltageSource(dir, 1, sources)] } };
        },
        .sens, .dcmatch => {
            try arity(dir, 1, 1);
            const node = try outputNode(node_id);
            if (id == .sens) return .{ .sens = .{ .output_node = node, .cards = sources.cards } };
            return .{ .dcmatch = .{ .output_node = node } };
        },
        .four => {
            try arity(dir, 2, 3);
            return .{ .four = .{ .f_fundamental = try positive(dir, 0), .output_node = try outputNode(node_id), .n_harmonics = try count(u16, dir, 2, 9) } };
        },
        .pz => {
            // The eigenvalue module computes poles, not transfer zeros.
            if (dir.args.len != 0) return error.UnsupportedPoleZeroArguments;
            return .{ .pz = .{} };
        },
        .pss => {
            try arity(dir, 1, 2);
            return .{ .pss = .{ .period = 1 / try positive(dir, 0), .n_samples = try count(u32, dir, 1, 256) } };
        },
        .hb => {
            try arity(dir, 1, 2);
            if (sources.v_names.len == 0) return error.AnalysisSourceNotFound;
            return .{ .hb = .{ .f0 = try positive(dir, 0), .n_harmonics = try count(u16, dir, 1, 8) } };
        },
        .qpss => {
            try arity(dir, 2, 4);
            if (sources.v_names.len == 0) return error.AnalysisSourceNotFound;
            return .{ .qpss = .{ .f1 = try positive(dir, 0), .f2 = try positive(dir, 1), .k1 = try count(u16, dir, 2, 5), .k2 = try count(u16, dir, 3, 5) } };
        },
        .pac, .pxf => {
            try arity(dir, 5, 5);
            const sweep = try frequencyOptions(analysis.ac.Options, dir, 1);
            const lo = try positive(dir, 0);
            if (id == .pac) return .{ .pac = .{ .f_lo = lo, .f_start = sweep.f_start, .f_stop = sweep.f_stop, .points_per_decade = sweep.points_per_decade } };
            return .{ .pxf = .{ .f_lo = lo, .f_start = sweep.f_start, .f_stop = sweep.f_stop, .points_per_decade = sweep.points_per_decade } };
        },
        .sp => {
            try arity(dir, 4, 4);
            const mode = directiveName(dir, 0) orelse return error.InvalidAnalysisArguments;
            const first = try positive(dir, 2);
            const last = try positive(dir, 3);
            if (last < first) return error.InvalidAnalysisArguments;
            const n = try count(u16, dir, 1, 50);
            const sweep = std.StaticStringMap(analysis.sp.SweepType).initComptime(.{ .{ "dec", .log }, .{ "lin", .linear } }).get(mode) orelse return error.UnsupportedFrequencySweep;
            const npoints = if (sweep == .log) analysis.types.logSweepCount(first, last, n) else n;
            if (npoints > std.math.maxInt(u16)) return error.InvalidAnalysisArguments;
            return .{ .sp = .{ .f_start = first, .f_stop = last, .n_points = @intCast(npoints), .sweep_type = sweep, .ports = sources.ports } };
        },
        .stb => return error.UnsupportedStabilityAnalysis,
        .envelope => {
            try arity(dir, 2, 2);
            return .{ .envelope = .{ .t_carrier = try positive(dir, 0), .t_stop = try positive(dir, 1) } };
        },
        .mc => {
            try arity(dir, 1, 2);
            var opts: analysis.mc.Options = .{ .n_trials = try count(u16, dir, 0, 100) };
            if (dir.args.len == 2) opts.variation = try number(dir, 1);
            if (opts.variation < 0) return error.InvalidAnalysisArguments;
            return .{ .mc = opts };
        },
        .temp => {
            // Standard single-temperature card is deck configuration.
            if (dir.args.len == 1) {
                if (try number(dir, 0) <= -273.15) return error.InvalidAnalysisArguments;
                return null;
            }
            try arity(dir, 3, 3);
            const opts: analysis.temp_sweep.Options = .{ .t_start = try number(dir, 0), .t_stop = try number(dir, 1), .t_step = try number(dir, 2) };
            try checkStep(opts.t_start, opts.t_stop, opts.t_step);
            if (opts.t_step <= 0 or (opts.t_stop - opts.t_start) / opts.t_step >= std.math.maxInt(u32) or
                @min(opts.t_start, opts.t_stop) <= -273.15) return error.InvalidAnalysisArguments;
            return .{ .temp = opts };
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Parser = @import("frontend/parser.zig").Parser;
const ngspice = @import("frontend/tokenizer.zig").ngspice;

/// Release parse storage before running, as the CLI does.
fn runDeck(sim_arena: std.mem.Allocator, parse_arena: *std.heap.ArenaAllocator, src: []const u8) !Simulation {
    const nl = try Parser(ngspice).parse(parse_arena.allocator(), src);
    var sim = try Simulation.fromNetlist(sim_arena, parse_arena.allocator(), nl, null, .{});
    _ = parse_arena.reset(.free_all);
    try sim.run();
    return sim;
}

test "uic: .ic seeds the transient and the OP is skipped" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();

    // An RC with the source at 0 V: the operating point is v(2) = 0, so a
    // transient that ran the OP starts flat at zero. With `uic` the cap starts
    // charged at 1 V and decays — the two are unmistakable.
    var sim = try runDeck(sa.allocator(), &pa,
        \\uic rc
        \\v1 1 0 dc 0
        \\r1 1 2 1k
        \\c1 2 0 1u
        \\.ic v(2)=1.0
        \\.tran 1u 2m uic
        \\.end
    );
    defer sim.deinit();

    try std.testing.expectEqual(@as(usize, 1), sim.ic.len);
    try std.testing.expectEqual(@as(f64, 1.0), sim.ic[0].value);

    const res = sim.getResults();
    try std.testing.expectEqual(@as(usize, 1), res.len);
    // v(2) at t=0 must be the IC, not the OP's zero.
    const v2_first = probeFirst(res[0], "2") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), v2_first, 1e-9);

    // ...and it must decay: one RC is 1 ms, so by 2 ms it is well under half.
    const v2_last = probeLast(res[0], "2") orelse return error.NoProbe;
    try std.testing.expect(v2_last < 0.5);
}

test "uic: without the keyword the transient starts from the operating point" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();

    // Same deck, same .ic card, no `uic`: the OP wins and v(2) starts at 0.
    var sim = try runDeck(sa.allocator(), &pa,
        \\op rc
        \\v1 1 0 dc 0
        \\r1 1 2 1k
        \\c1 2 0 1u
        \\.ic v(2)=1.0
        \\.tran 1u 2m
        \\.end
    );
    defer sim.deinit();

    const v2_first = probeFirst(sim.getResults()[0], "2") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), v2_first, 1e-9);
}

test "uic: keyword is positional-independent and .ic on an unknown node is dropped" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();

    var sim = try runDeck(sa.allocator(), &pa,
        \\uic forms
        \\v1 1 0 dc 0
        \\r1 1 2 1k
        \\c1 2 0 1u
        \\.ic v(2)=0.25 v(nosuchnode)=9.0
        \\.tran 1u 2m 0 1u uic
        \\.end
    );
    defer sim.deinit();

    // The bogus card is dropped, the real one survives.
    try std.testing.expectEqual(@as(usize, 1), sim.ic.len);
    const v2_first = probeFirst(sim.getResults()[0], "2") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), v2_first, 1e-9);
}

test "branch currents: op emits i(<card>) with ngspice's sign, last probe stays a node" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();

    // ngspice 44.2 on this deck: i(v1) = -1e-3 (current INTO the + terminal),
    // i(l1) = +1e-3 (p->n through the inductor). Signs must match exactly.
    var sim = try runDeck(sa.allocator(), &pa,
        \\divider
        \\v1 1 0 dc 1
        \\r1 1 2 500
        \\l1 2 0 1m
        \\.op
        \\.end
    );
    defer sim.deinit();

    const res = sim.getResults()[0];
    const iv = findNameIndex(res.varnames, "i(v1)") orelse return error.NoBranchColumn;
    const il = findNameIndex(res.varnames, "i(l1)") orelse return error.NoBranchColumn;
    try std.testing.expectApproxEqAbs(@as(f64, -2e-3), res.data[iv], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2e-3), res.data[il], 1e-9);
    // Branch probes go FIRST: tf/sens/dcmatch/pxf/pac/disto default their
    // output to probes[len-1], which must remain the last named node.
    try std.testing.expect(std.mem.startsWith(u8, res.varnames[res.varnames.len - 1], "v("));
}

test "urc: U card expands into a lump ladder whose series R telescopes to L*RPERL" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();

    // r0 = L*RPERL = 1k against a 1k load: v(out) is 0.5 iff the geometric
    // lump sizing (r1*K^i from both ends) sums back to exactly r0 and the
    // two half-chains actually meet in the middle.
    var sim = try runDeck(sa.allocator(), &pa,
        \\urc ladder
        \\v1 in 0 dc 1
        \\u1 in out 0 umod l=1 n=4
        \\rl out 0 1k
        \\.model umod urc(rperl=1000 cperl=1u)
        \\.op
        \\.end
    );
    defer sim.deinit();

    const vout = probeLast(sim.getResults()[0], "out") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), vout, 1e-6);
}

/// Probe columns are named `v(<node>)`/`i(<card>)` (probeNames) and a
/// transient's column 0 is "time". Result.data is ROW-major:
/// data[point * ncols + col].
fn probeColumn(r: Result, node: []const u8) ?usize {
    var buf: [64]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "v({s})", .{node}) catch return null;
    // ponytail: reuse the exact, first-match lookup already used for source names.
    return findNameIndex(r.varnames, want);
}

fn probeAt(r: Result, node: []const u8, point: usize) ?f64 {
    const c = probeColumn(r, node) orelse return null;
    if (point >= r.npoints) return null;
    return r.data[point * r.varnames.len + c];
}

fn probeFirst(r: Result, node: []const u8) ?f64 {
    return probeAt(r, node, 0);
}

fn probeLast(r: Result, node: []const u8) ?f64 {
    if (r.npoints == 0) return null;
    return probeAt(r, node, r.npoints - 1);
}

test "recorded transient matches retained RC samples with and without uic" {
    inline for (.{ false, true }) |uic| {
        const src =
            "recorded rc\n" ++
            "v1 in 0 pulse(0 1 0 1u 1u 100u 200u)\n" ++
            "r1 in out 1k\n" ++
            "c1 out 0 1n\n" ++
            ".ic v(out)=0.75\n" ++
            ".options temp=85\n" ++
            (if (uic) ".tran 1u 20u uic\n" else ".tran 1u 20u\n") ++
            ".end\n";
        var retained_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer retained_arena.deinit();
        var retained_parse = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer retained_parse.deinit();
        var retained = try runDeck(retained_arena.allocator(), &retained_parse, src);
        defer retained.deinit();

        var streamed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer streamed_arena.deinit();
        var streamed_parse = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer streamed_parse.deinit();
        const nl = try Parser(ngspice).parse(streamed_parse.allocator(), src);
        var streamed = try Simulation.fromNetlist(streamed_arena.allocator(), streamed_parse.allocator(), nl, null, .{});
        defer streamed.deinit();
        _ = streamed_parse.reset(.free_all);

        var waveform = try analysis.tran.Waveform.init(std.testing.allocator, @intCast(streamed.probes.len), 1);
        defer waveform.deinit();
        const completed = try streamed.runTransient(&waveform);
        const expected = retained.getResults()[0];
        try std.testing.expect(completed.completed);
        try std.testing.expectEqual(@as(u32, 0), streamed.n_results);
        try std.testing.expectEqual(expected.npoints, waveform.len);
        try std.testing.expectEqual(completed.steps + 1, waveform.len);
        try std.testing.expectEqual(@as(f64, 0), waveform.timeSlice()[0]);
        try std.testing.expectApproxEqAbs(@as(f64, 20e-6), completed.t_final, 1e-18);
        try std.testing.expectEqual(completed.t_final, waveform.timeSlice()[waveform.len - 1]);
        const out_col = findNameIndex(expected.varnames, "v(out)") orelse return error.NoProbe;
        try std.testing.expectEqual(@as(f64, if (uic) 0.75 else 0), waveform.probeValues(@intCast(out_col - 1))[0]);
        for (waveform.timeSlice(), 0..) |time, point| {
            const row = expected.data[point * expected.varnames.len ..][0..expected.varnames.len];
            try std.testing.expectEqual(@as(u64, @bitCast(row[0])), @as(u64, @bitCast(time)));
            for (row[1..], 0..) |value, probe|
                try std.testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(waveform.probeValues(@intCast(probe))[point])));
        }
    }
}

test "recorded transient propagates output failure without a result" {
    const FailingRecorder = struct {
        pub fn record(_: @This(), t: f64, _: []const f64, _: []const u32) error{WriteFailed}!void {
            if (t > 0) return error.WriteFailed;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const nl = try Parser(ngspice).parse(parse_arena.allocator(),
        \\recording failure
        \\v1 out 0 dc 1
        \\.tran 1u 2u
        \\.end
    );
    var sim = try Simulation.fromNetlist(arena.allocator(), parse_arena.allocator(), nl, null, .{});
    defer sim.deinit();
    _ = parse_arena.reset(.free_all);
    try std.testing.expectError(error.WriteFailed, sim.runTransient(FailingRecorder{}));
    try std.testing.expectEqual(@as(u32, 0), sim.n_results);
}

test "analysis directives dispatch every implemented capability and reject malformed requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources: Sources = .{ .v_names = &.{"vin"}, .i_names = &.{}, .v_branches = &.{2}, .v_distof1 = &.{.{ 0, 0 }} };
    const directives = [_][]const u8{
        ".ac dec 2 10 100",                     ".dc vin 0 1 0.1",       ".dcmatch v(out)",
        ".disto dec 2 10 100",                  ".envelope 1m 5m",       ".four 1k v(out)",
        ".hb 1k",                               ".matex 1u 10u",         ".mc 4",
        ".noise v(out) vin dec 2 10 100",       ".op",                   ".pac 1k dec 2 10 100",
        ".pnoise v(out) vin dec 2 10 100 1k 0", ".pss 1k 128",           ".pxf 1k dec 2 10 100",
        ".pz",                                  ".qpss 1k 1414 1 1",     ".sens v(out)",
        ".sp dec 2 10 100",                     ".stb vin dec 2 10 100", ".temp -40 125 55",
        ".tf v(out) vin",                       ".tran 1u 10u",          ".tran_noise 1u 10u",
    };
    try std.testing.expectEqual(std.meta.fields(analysis.AnalysisId).len, directives.len);
    for (directives, 0..) |directive, index| {
        const nl = try Parser(ngspice).parse(a, try std.fmt.allocPrint(a, "dispatch\n{s}\n.end\n", .{directive}));
        const id: analysis.AnalysisId = @enumFromInt(index);
        if (id == .stb) {
            try std.testing.expectError(error.UnsupportedStabilityAnalysis, buildJob(nl.directives[0], 1, sources));
            continue;
        }
        const job = (try buildJob(nl.directives[0], 1, sources)).?;
        try std.testing.expectEqual(id, std.meta.activeTag(job));
        if (job == .pss) try std.testing.expectEqual(@as(f64, 1e-3), job.pss.period);
    }
    const malformed = [_][]const u8{
        ".ac dec 0 1 10",                ".ac dec -1 1 10",     ".ac dec 2.5 1 10",                      ".ac dec 2 10 1",
        ".ac lin 2 1 10",                ".dc missing 0 1 0.1", ".dc vin 0 1 0",                         ".dc vin 0 1 -1",
        ".dc vin 0 1 1 missing 0 1 1",   ".tran 0 1u",          ".tran 1u 2u 1u",                        ".pss 0",
        ".pss 1k 2m v(out) 128 4 50 1m", ".mc 65536",           ".pnoise v(out) vin dec 2 10 100 1k -1", ".pz in 0 out 0 vol pz",
        ".tf v(out) missing",            ".temp -300 125 55",
    };
    for (malformed) |directive| {
        const nl = try Parser(ngspice).parse(a, try std.fmt.allocPrint(a, "invalid\n{s}\n.end\n", .{directive}));
        if (buildJob(nl.directives[0], 1, sources)) |_| return error.AcceptedInvalidAnalysis else |_| {}
    }
    const unknown: types.Directive = .{ .kind = "options", .args = &.{} };
    try std.testing.expectEqual(null, try buildJob(unknown, NO_NODE, sources));
}

test "tf resolves numeric output and named second input before parse arena dies" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    var sim = try runDeck(sa.allocator(), &pa,
        \\two independent inputs
        \\va ignored 0 dc 2
        \\vb in 0 dc 10
        \\r1 in 2 1k
        \\r2 2 0 3k
        \\.tf v(2) vb
        \\.end
    );
    defer sim.deinit();
    const result = sim.getResults()[0];
    try std.testing.expectEqualStrings("Transfer Function", result.plotname);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), result.data[0], 1e-9);
}

test "deck temperature and tolerances reach statistical and noise jobs" {
    const options: DeckOptions = .{ .temp_c = 85, .tol = .{ .reltol = 1e-5 } };
    var noise_job: Job = .{ .noise = .{ .out_node = 0, .f_start = 1, .f_stop = 10 } };
    applyDeckOptions(&noise_job, options);
    try std.testing.expectEqual(@as(f64, 358.15), noise_job.noise.temp_k);
    var temp_job: Job = .{ .temp = .{} };
    applyDeckOptions(&temp_job, options);
    try std.testing.expectEqual(@as(f64, 85), temp_job.temp.t_nom);
    try std.testing.expectEqual(options.tol.reltol, temp_job.temp.dc_options.tol.reltol);
}

test "sensitivity and mismatch keep separate resistor parameters and analytical derivatives" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    var sim = try runDeck(sa.allocator(), &pa,
        \\parameter derivatives
        \\vin in 0 dc 10
        \\r1 in out 1k
        \\r2 out 0 3k
        \\.sens v(out)
        \\.dcmatch v(out)
        \\.end
    );
    defer sim.deinit();
    for (sim.getResults()) |result| {
        for (result.varnames, 0..) |name, i| {
            for (result.varnames[0..i]) |previous| try std.testing.expect(!std.mem.eql(u8, name, previous));
        }
        // `.sens` names columns after the CARD, ngspice-style (v(r1));
        // `.dcmatch` still keys by device-class ordinal.
        const sens_cols = std.mem.eql(u8, result.plotname, "Sensitivity Analysis");
        const r1 = findNameIndex(result.varnames, if (sens_cols) "v(r1)" else "resistor#0.r") orelse return error.MissingSensitivity;
        const r2 = findNameIndex(result.varnames, if (sens_cols) "v(r2)" else "resistor#1.r") orelse return error.MissingSensitivity;
        try std.testing.expectApproxEqAbs(@as(f64, -0.001875), result.data[r1], 1e-8);
        try std.testing.expectApproxEqAbs(@as(f64, 0.000625), result.data[r2], 1e-8);
    }
}

test "spectral analysis cannot publish an unconverged result" {
    inline for (.{ ".hb 1k 1", ".qpss 1k 1414 1 1" }) |directive| {
        var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer sa.deinit();
        var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer pa.deinit();
        const nl = try Parser(ngspice).parse(pa.allocator(), "unconverged spectrum\nvin in 0 dc 0\nr1 in out 1k\nc1 out 0 1u\n" ++ directive ++ "\n.end\n");
        var sim = try Simulation.fromNetlist(sa.allocator(), pa.allocator(), nl, null, .{});
        defer sim.deinit();
        _ = pa.reset(.free_all);
        if (sim.jobs[0] == .hb) {
            sim.jobs[0].hb.max_iter = 0;
            try std.testing.expectError(error.HbDidNotConverge, sim.run());
        } else {
            sim.jobs[0].qpss.max_newton = 0;
            try std.testing.expectError(error.QpssDidNotConverge, sim.run());
        }
        try std.testing.expectEqual(@as(u32, 0), sim.n_results);
    }
}

test "generated parameter collection excludes runtime state and Monte Carlo varies model values" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    var sim = try runDeck(sa.allocator(), &pa,
        \\statistical model parameters
        \\vin in 0 dc 10
        \\r1 in out 1k
        \\r2 out 0 3k
        \\.mc 16 0.05
        \\.end
    );
    defer sim.deinit();
    var resistors: u32 = 0;
    for (try sim.circuit.collectParams()) |ref| {
        if (ref.is_instance) {
            try std.testing.expect(std.mem.eql(u8, ref.param_name, "temperature") or std.mem.eql(u8, ref.param_name, "mfactor"));
            try std.testing.expect(!ref.primary);
        }
        if (std.mem.eql(u8, ref.device_type, "resistor") and std.mem.eql(u8, ref.param_name, "r")) {
            try std.testing.expect(ref.primary);
            resistors += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 2), resistors);
    const result = sim.getResults()[0];
    try std.testing.expectEqual(@as(usize, 16), result.npoints);
    const out = findNameIndex(result.varnames, "v(out)") orelse return error.NoProbe;
    var varied = false;
    for (0..result.npoints) |i| {
        const value = result.data[i * result.varnames.len + out];
        try std.testing.expect(std.math.isFinite(value));
        varied = varied or @abs(value - result.data[out]) > 1e-6;
    }
    try std.testing.expect(varied);
}

test "BSIM4 tnoimod1 retains DC conduction with zero source and drain squares" {
    var currents: [2][2]f64 = undefined;
    for (&currents, 0..) |*row, mode| {
        var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer sa.deinit();
        var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer pa.deinit();
        const src = try std.fmt.allocPrint(pa.allocator(),
            \\noise topology DC regression
            \\vdn dn 0 1
            \\vgn gn 0 1.2
            \\vdp dp 0 -1
            \\vgp gp 0 -1.2
            \\mn dn gn 0 0 nm l=1u w=10u nrd=0 nrs=0
            \\mp dp gp 0 0 pm l=1u w=10u nrd=0 nrs=0
            \\.model nm nmos(level=54 tnoimod={d} rdsmod=0)
            \\.model pm pmos(level=54 tnoimod={d} rdsmod=0)
            \\.op
            \\.end
        , .{ mode, mode });
        var sim = try runDeck(sa.allocator(), &pa, src);
        defer sim.deinit();
        const result = sim.getResults()[0];
        for ([_][]const u8{ "i(vdn)", "i(vdp)" }, row) |name, *current| {
            const col = findNameIndex(result.varnames, name) orelse return error.NoProbe;
            current.* = result.data[col];
            try std.testing.expect(std.math.isFinite(current.*) and @abs(current.*) > 1e-6);
        }
    }
    // Noise mode must preserve DC conduction. The regression fixture checks
    // absolute ngspice accuracy separately; its existing model gap stays visible.
    for (currents[0], currents[1]) |direct, internal| try std.testing.expectApproxEqRel(direct, internal, 1e-5);
}

test "selected numeric parameters fail closed while unused models remain inert" {
    inline for (.{
        ".model nm nmos(level=1 tox={missing})\nm1 out in 0 0 nm\n",
        "r1 out 0 r=0*missing\n",
        ".param mc=1\n.model nm nmos(level=1 tox={1e-7+mc*agauss(0,1e-9,1)})\nm1 out in 0 0 nm\n",
    }) |body| {
        var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer sa.deinit();
        var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer pa.deinit();
        const nl = try Parser(ngspice).parse(pa.allocator(), "unresolved numeric parameter\n.param dummy=1\nvin in 0 dc 1\nrload in out 1k\n" ++ body ++ ".op\n.end\n");
        try std.testing.expectError(error.UnresolvedParameter, Simulation.fromNetlist(sa.allocator(), pa.allocator(), nl, null, .{}));
    }
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    var sim = try runDeck(sa.allocator(), &pa,
        \\unused model
        \\.model unused nmos(level=1 tox={missing})
        \\vin in 0 dc 1
        \\r1 in out 1k
        \\r2 out 0 1k
        \\.op
        \\.end
    );
    defer sim.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), probeLast(sim.getResults()[0], "out").?, 1e-9);
}

test "nonfinite model parameter cannot become its default" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    const nl = try Parser(ngspice).parse(pa.allocator(),
        \\invalid model value
        \\.model nm nmos(level=1 tox={1/0})
        \\vin in 0 1
        \\r1 in out 1k
        \\m1 out in 0 0 nm
        \\.op
        \\.end
    );
    try std.testing.expectError(error.NonFiniteParameter, Simulation.fromNetlist(sa.allocator(), pa.allocator(), nl, null, .{}));
}

test "BSIM4 pub model-card parameter reaches its escaped Zig field" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    const nl = try Parser(ngspice).parse(pa.allocator(),
        \\escaped parameter name
        \\.model nm nmos(level=54 pub=1.25e-18)
        \\vd drain 0 1
        \\vg gate 0 1.2
        \\m1 drain gate 0 0 nm l=1u w=10u
        \\.op
        \\.end
    );
    var sim = try Simulation.fromNetlist(sa.allocator(), pa.allocator(), nl, null, .{});
    defer sim.deinit();
    for (try sim.circuit.collectParams()) |ref| {
        if (std.mem.eql(u8, ref.param_name, "pubZ")) {
            try std.testing.expectEqual(@as(f64, 1.25e-18), ref.get());
            return;
        }
    }
    return error.MissingModelParameter;
}
