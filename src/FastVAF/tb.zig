//! Testbench generation — the second artifact. LRM ch9 (§9.4 display tasks).
//!
//! FastVAF's device output answers "what does the solver stamp?". This file
//! answers "what does the model SAY?", by making the same .va into a program:
//!
//!   .va ──codegen(display = .emit)──> device.zig ──┐
//!                                                  ├─> zig build-exe ─> ./NAME
//!   `//!` directives ────renderRunner────> tb.zig ─┘
//!
//! Running it prints a transcript: every `$strobe` the model executes, plus the
//! residual and Jacobian at each declared operating point. That transcript is
//! the test. A fixture is one .va and one expected transcript, and authoring a
//! new test is writing Verilog-A — not Zig, and not a table of magic numbers in
//! another language.
//!
//! WHY THE DIRECTIVES ARE COMMENTS. A device's inputs are node voltages the
//! host supplies; nothing in the source says which ones are interesting. That
//! has to come from somewhere, and a `//!` line is the only place to put it that
//! (a) keeps the fixture a single file, (b) survives the preprocessor untouched
//! — §2.4 makes it a comment — and (c) leaves the .va compilable by any other
//! Verilog-A tool, which a made-up pragma would not.
//!
//! DOD: the directive table is parsed once into flat arena slices, and the
//! sweep is expanded HERE rather than emitted as nested loops. The runner is
//! straight-line code with one block per operating point, so its output order is
//! a property of the text, not of a loop nest.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The `//!` marker. Chosen over a bare `//` so an ordinary comment never
/// becomes a directive by accident, and over ``pragma`` so the file stays
/// portable Verilog-A.
pub const marker = "//!";

pub const Error = Allocator.Error || error{
    /// A `//!` line named a directive that does not exist. Silently ignoring it
    /// would turn a typo into a test that quietly checks nothing.
    UnknownDirective,
    /// A directive's operand was not a number.
    BadNumber,
    /// A directive that needs `name = value` did not get one.
    BadSyntax,
    /// The cartesian product of the `sweep` lines exceeded `max_points`.
    TooManyPoints,
};

/// One `name = value` binding: a model parameter, or a fixed unknown.
pub const Binding = struct { name: []const u8, value: f64 };

/// One `//! sweep <unknown> = v, v, …` line.
pub const Sweep = struct { name: []const u8, values: []const f64 };

/// §4.6.1 analysis kinds, spelled as the generated `AnalysisKind` enum does.
pub const Analysis = enum { static, ic, nodeset, dc, tran, ac, noise };

/// Everything the `//!` lines of one fixture said. Every field has a default, so
/// a .va with no directives at all is still runnable: one operating point with
/// every unknown at zero and every parameter at its §3.4 default.
pub const Directives = struct {
    /// §3.4 parameter overrides, in source order.
    params: []const Binding = &.{},
    /// Unknowns held at a fixed value across the whole sweep.
    bias: []const Binding = &.{},
    /// Swept unknowns. The operating points are the CARTESIAN PRODUCT, with the
    /// LAST line varying fastest — the same order a nested loop written in the
    /// directive order would visit, so the transcript reads top-down.
    sweeps: []const Sweep = &.{},
    /// §9.10 `$temperature`, in kelvin.
    temp: f64 = 300.15,
    /// §9.10 `$abstime` values. More than one makes each operating point run
    /// once per time, with `dt` set from the previous entry (§4.5.3 needs it)
    /// and the generated `updateState` called after each — so the §4.5 stateful
    /// operators see the history a transient solve would give them.
    times: []const f64 = &.{0.0},
    /// Per-timepoint values for an unknown: `//! wave V(in) = 0, 1, 1, 0`, one
    /// entry per `//! time`. A short list HOLDS its last value, which is how a
    /// step is written. Without this every §4.5 operator could only ever be
    /// shown its step response from zero.
    waves: []const Sweep = &.{},
    /// §4.6.1.
    analysis: Analysis = .dc,
    /// Print the residual and its Jacobian after each point's display output.
    /// `//! print none` leaves the transcript to the model's own `$strobe`s,
    /// which is what a fixture that tests §9.4 formatting wants.
    print_residual: bool = true,
};

/// Guard against a fixture that asks for a million points and a gigabyte of
/// generated Zig. Hit only by a mistake — a real sweep is tens of points.
pub const max_points: usize = 4096;

// ---------------------------------------------------------------------------
// Directive parsing
// ---------------------------------------------------------------------------

/// Read the `//!` lines out of RAW source — before the preprocessor, which
/// deletes comments (§2.4). Lines that are not directives are ignored, so this
/// is safe to run over any .va.
pub fn parse(arena: Allocator, source: []const u8) Error!Directives {
    var d: Directives = .{};
    var params: std.ArrayList(Binding) = .empty;
    var bias: std.ArrayList(Binding) = .empty;
    var sweeps: std.ArrayList(Sweep) = .empty;
    var waves: std.ArrayList(Sweep) = .empty;
    var saw_time = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, marker)) continue;
        const body = std.mem.trim(u8, line[marker.len..], " \t");
        if (body.len == 0) continue;

        const kw_end = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
        const kw = body[0..kw_end];
        const rest = std.mem.trim(u8, body[kw_end..], " \t");

        if (eq(kw, "param")) {
            try parseBindings(arena, rest, &params);
        } else if (eq(kw, "bias")) {
            try parseBindings(arena, rest, &bias);
        } else if (eq(kw, "sweep") or eq(kw, "wave")) {
            const at = std.mem.indexOfScalar(u8, rest, '=') orelse return error.BadSyntax;
            const name = unknownName(std.mem.trim(u8, rest[0..at], " \t"));
            if (name.len == 0) return error.BadSyntax;
            const entry: Sweep = .{
                .name = try arena.dupe(u8, name),
                .values = try parseNumbers(arena, rest[at + 1 ..]),
            };
            try (if (eq(kw, "sweep")) &sweeps else &waves).append(arena, entry);
        } else if (eq(kw, "temp")) {
            d.temp = try number(rest);
        } else if (eq(kw, "time")) {
            d.times = try parseNumbers(arena, rest);
            saw_time = true;
        } else if (eq(kw, "analysis")) {
            d.analysis = std.meta.stringToEnum(Analysis, rest) orelse return error.BadSyntax;
        } else if (eq(kw, "print")) {
            if (eq(rest, "none")) {
                d.print_residual = false;
            } else if (eq(rest, "residual")) {
                d.print_residual = true;
            } else return error.BadSyntax;
        } else {
            return error.UnknownDirective;
        }
    }

    if (saw_time and d.times.len == 0) return error.BadSyntax;
    d.params = params.items;
    d.bias = bias.items;
    d.sweeps = sweeps.items;
    d.waves = waves.items;
    return d;
}

/// `V(a)`, `x[a]` and a bare `a` all name the unknown `a`. The first two are
/// how a Verilog-A author already writes it and how the runner indexes it; both
/// are accepted so a fixture is not forced to learn a third spelling.
fn unknownName(raw: []const u8) []const u8 {
    var s = raw;
    if (std.mem.startsWith(u8, s, "V(") and std.mem.endsWith(u8, s, ")")) s = s[2 .. s.len - 1];
    if (std.mem.startsWith(u8, s, "I(") and std.mem.endsWith(u8, s, ")")) s = s[2 .. s.len - 1];
    if (std.mem.startsWith(u8, s, "x[") and std.mem.endsWith(u8, s, "]")) s = s[2 .. s.len - 1];
    return std.mem.trim(u8, s, " \t");
}

fn parseBindings(arena: Allocator, rest: []const u8, out: *std.ArrayList(Binding)) Error!void {
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len == 0) continue;
        const at = std.mem.indexOfScalar(u8, t, '=') orelse return error.BadSyntax;
        const name = std.mem.trim(u8, t[0..at], " \t");
        if (name.len == 0) return error.BadSyntax;
        try out.append(arena, .{
            .name = try arena.dupe(u8, unknownName(name)),
            .value = try number(t[at + 1 ..]),
        });
    }
}

fn parseNumbers(arena: Allocator, rest: []const u8) Error![]const f64 {
    var out: std.ArrayList(f64) = .empty;
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len == 0) continue;
        try out.append(arena, try number(t));
    }
    if (out.items.len == 0) return error.BadSyntax;
    return out.items;
}

/// A directive number. §2.6's engineering suffixes are accepted because a
/// Verilog-A author writes `1u`, not `1e-6`, three lines below in the source.
fn number(raw: []const u8) Error!f64 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len == 0) return error.BadNumber;
    const suffix: f64 = switch (t[t.len - 1]) {
        'T' => 1e12,
        'G' => 1e9,
        'M' => 1e6,
        'K', 'k' => 1e3,
        'm' => 1e-3,
        'u' => 1e-6,
        'n' => 1e-9,
        'p' => 1e-12,
        'f' => 1e-15,
        'a' => 1e-18,
        else => 0,
    };
    if (suffix == 0) return std.fmt.parseFloat(f64, t) catch error.BadNumber;
    const head = std.mem.trim(u8, t[0 .. t.len - 1], " \t");
    return suffix * (std.fmt.parseFloat(f64, head) catch return error.BadNumber);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// Runner generation
// ---------------------------------------------------------------------------

/// Emit the runner's Zig source. `title` is what each transcript block is keyed
/// by — the fixture's file stem, so a failing diff names the fixture.
///
/// Everything is written with `std.debug.print`, which is also where the
/// generated `$strobe` writes: ONE stream, so the interleaving of the model's
/// own output with the harness's is deterministic and diffable. stdout is left
/// alone for a caller that wants to pipe something else.
pub fn renderRunner(arena: Allocator, title: []const u8, d: Directives) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = Writer{ .arena = arena, .out = &out };

    try w.raw(runner_head);
    try w.print("const title = \"{f}\";\n\n", .{std.zig.fmtString(title)});
    try w.raw(runner_body);

    // --- main -------------------------------------------------------------
    try w.raw(
        \\pub fn main() void {
        \\    var model: D.Model = .{};
        \\
    );
    for (d.params) |p| {
        try w.print("    model.{f} = {f};\n", .{ std.zig.fmtId(p.name), fmtF64(p.value) });
        // §9.19 `$param_given` is answered from a companion field when codegen
        // emitted one. Setting the value without it would make an explicit
        // override read as "not given".
        try w.print(
            "    if (comptime @hasField(D.Model, \"{f}__given\")) @field(model, \"{f}__given\") = true;\n",
            .{ std.zig.fmtString(p.name), std.zig.fmtString(p.name) },
        );
    }
    try w.raw(
        \\
        \\    var inst: D.Instance = .{};
        \\
    );
    try w.print("    inst.temperature = {f};\n", .{fmtF64(d.temp)});
    try w.print("    inst.analysis_kind = .{t};\n", .{d.analysis});
    try w.raw(
        \\
        \\    std.debug.print("=== {s} ===\n", .{title});
        \\
    );

    // --- one straight-line block per operating point ------------------------
    //
    // The SWEEP is the outer loop and TIME the inner one, and the §4.5 operator
    // state belongs to the inner walk: each sweep point is its own transient run
    // and starts from a fresh `State`, or the second bias would inherit the
    // first one's history and no transcript line would mean anything on its own.
    const points = try expand(arena, d);
    var n: usize = 0;
    for (points) |pt| {
        try w.raw("    {\n        var x: [n_u]f64 = @splat(0.0);\n        var state = newState(&model, &inst);\n");
        for (d.bias) |b|
            try w.print("        x[ix(\"{f}\")] = {f};\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
        for (d.sweeps, pt) |s, v|
            try w.print("        x[ix(\"{f}\")] = {f};\n", .{ std.zig.fmtString(s.name), fmtF64(v) });
        for (d.times, 0..) |t, k| {
            for (d.waves) |wv| {
                // A short `wave` HOLDS its last value — that is how a step is
                // written without repeating the level once per remaining time.
                const v = wv.values[@min(k, wv.values.len - 1)];
                try w.print("        x[ix(\"{f}\")] = {f};\n", .{ std.zig.fmtString(wv.name), fmtF64(v) });
            }
            // §4.5.3 `ddt` divides by `dt`; the FIRST time is the DC point, so
            // it gets dt = 0 — which every operator kernel reads as "no history"
            // and answers with its DC form (§4.5.4 the initial condition,
            // §4.5.11 the filter's DC gain).
            const dt: f64 = if (k == 0) 0.0 else d.times[k] - d.times[k - 1];
            try w.print("        inst.abstime = {f};\n        inst.dt = {f};\n", .{ fmtF64(t), fmtF64(dt) });
            try w.print("        point({d}, &x, {f}, &model, &inst);\n", .{ n, fmtF64(t) });
            // §4.5.2 accepted-step bookkeeping. This is the whole reason the
            // stateful operators are observable at all: `eval` reads history out
            // of `Instance`, and only `updateState` ever writes it.
            try w.raw("        step(&model, &inst, &x, &state);\n");
            n += 1;
        }
        try w.raw("    }\n");
    }

    try w.raw(if (d.print_residual)
        \\}
        \\
        \\const print_residual = true;
        \\
    else
        \\}
        \\
        \\const print_residual = false;
        \\
    );
    return out.items;
}

/// The cartesian product of the sweep lines, last varying fastest. One
/// allocation per point; a point is `sweeps.len` wide.
fn expand(arena: Allocator, d: Directives) Error![]const []const f64 {
    if (d.sweeps.len == 0) return &.{&.{}};
    var total: usize = 1;
    for (d.sweeps) |s| {
        total *|= s.values.len;
        if (total > max_points) return error.TooManyPoints;
    }
    const rows = try arena.alloc([]const f64, total);
    for (rows, 0..) |*row, n| {
        const cells = try arena.alloc(f64, d.sweeps.len);
        var rem = n;
        var k = d.sweeps.len;
        while (k > 0) {
            k -= 1;
            const len = d.sweeps[k].values.len;
            cells[k] = d.sweeps[k].values[rem % len];
            rem /= len;
        }
        row.* = cells;
    }
    return rows;
}

/// `{d}` on an f64 is shortest-round-trip, which is exact but can print `1e-14`
/// — legal Zig. What it must never print is `inf`/`nan`, which are not.
fn fmtF64(x: f64) std.fmt.Alt(f64, formatF64) {
    return .{ .data = x };
}

fn formatF64(x: f64, w: *Io.Writer) Io.Writer.Error!void {
    if (std.math.isNan(x)) return w.writeAll("std.math.nan(f64)");
    if (std.math.isInf(x)) return w.writeAll(if (x > 0) "std.math.inf(f64)" else "-std.math.inf(f64)");
    try w.print("{d}", .{x});
}

/// Thin bundle so the emitter reads as `w.print(...)` without threading two
/// values through every call.
const Writer = struct {
    arena: Allocator,
    out: *std.ArrayList(u8),

    fn raw(self: Writer, text: []const u8) Error!void {
        try self.out.appendSlice(self.arena, text);
    }

    fn print(self: Writer, comptime fmt: []const u8, args: anytype) Error!void {
        var aw: Io.Writer.Allocating = .fromArrayList(self.arena, self.out);
        defer self.out.* = aw.toArrayList();
        aw.writer.print(fmt, args) catch return error.OutOfMemory;
    }
};

// ---------------------------------------------------------------------------
// The runner's fixed text
// ---------------------------------------------------------------------------

const runner_head =
    \\// GENERATED BY FastVAF — DO NOT EDIT.
    \\// A runnable Verilog-A testbench: the device's own `$strobe` output plus
    \\// the residual and Jacobian at each `//!`-declared operating point.
    \\
    \\const std = @import("std");
    \\const D = @import("device");
    \\
    \\const n_u = @typeInfo(D.U).@"enum".fields.len;
    \\
    \\
;

const runner_body =
    \\/// Index of the unknown a directive named. A miss is a compile error that
    \\/// names the directive, not a runtime surprise.
    \\fn ix(comptime name: []const u8) usize {
    \\    const u = comptime std.meta.stringToEnum(D.U, name) orelse
    \\        @compileError(title ++ ": `//!` names unknown `" ++ name ++ "`, which this module does not have");
    \\    return @intFromEnum(u);
    \\}
    \\
    \\/// Forward-mode dual: value plus one partial per solver unknown. This is
    \\/// the same scalar the engine instantiates for the Jacobian, written out
    \\/// here so the testbench has no dependency beyond the device itself.
    \\const Dual = struct {
    \\    v: f64,
    \\    d: [n_u]f64 = @splat(0.0),
    \\    const T = @This();
    \\
    \\    pub fn con(c: f64) T { return .{ .v = c }; }
    \\    pub fn val(a: T) f64 { return a.v; }
    \\    pub fn ddxAt(a: T, i: usize) f64 { return a.d[i]; }
    \\
    \\    fn map(a: T, v: f64, k: f64) T { // chain rule: k = df/da at a.v
    \\        var r: T = .{ .v = v };
    \\        for (0..n_u) |i| r.d[i] = k * a.d[i];
    \\        return r;
    \\    }
    \\    fn map2(a: T, b: T, v: f64, ka: f64, kb: f64) T {
    \\        var r: T = .{ .v = v };
    \\        for (0..n_u) |i| r.d[i] = ka * a.d[i] + kb * b.d[i];
    \\        return r;
    \\    }
    \\
    \\    pub fn add(a: T, b: T) T { return map2(a, b, a.v + b.v, 1.0, 1.0); }
    \\    pub fn sub(a: T, b: T) T { return map2(a, b, a.v - b.v, 1.0, -1.0); }
    \\    pub fn mul(a: T, b: T) T { return map2(a, b, a.v * b.v, b.v, a.v); }
    \\    pub fn div(a: T, b: T) T { return map2(a, b, a.v / b.v, 1.0 / b.v, -a.v / (b.v * b.v)); }
    \\    pub fn neg(a: T) T { return map(a, -a.v, -1.0); }
    \\    pub fn scale(a: T, c: f64) T { return map(a, a.v * c, c); }
    \\    pub fn addC(a: T, c: f64) T { return map(a, a.v + c, 1.0); }
    \\    pub fn exp(a: T) T { return map(a, @exp(a.v), @exp(a.v)); }
    \\    pub fn log(a: T) T { return map(a, @log(a.v), 1.0 / a.v); }
    \\    pub fn sqrt(a: T) T { return map(a, @sqrt(a.v), 0.5 / @sqrt(a.v)); }
    \\    pub fn sin(a: T) T { return map(a, @sin(a.v), @cos(a.v)); }
    \\    pub fn cos(a: T) T { return map(a, @cos(a.v), -@sin(a.v)); }
    \\    pub fn tanh(a: T) T { const t = std.math.tanh(a.v); return map(a, t, 1.0 - t * t); }
    \\    pub fn sinh(a: T) T { return map(a, std.math.sinh(a.v), std.math.cosh(a.v)); }
    \\    pub fn cosh(a: T) T { return map(a, std.math.cosh(a.v), std.math.sinh(a.v)); }
    \\    pub fn atan(a: T) T { return map(a, std.math.atan(a.v), 1.0 / (1.0 + a.v * a.v)); }
    \\    pub fn abs(a: T) T { return map(a, @abs(a.v), if (a.v < 0.0) -1.0 else 1.0); }
    \\    pub fn pow(a: T, c: f64) T {
    \\        return map(a, std.math.pow(f64, a.v, c), c * std.math.pow(f64, a.v, c - 1.0));
    \\    }
    \\    // §4.3.1 min/max are selections: the derivative is the winner's.
    \\    pub fn minC(a: T, c: f64) T { return if (a.v <= c) a else con(c); }
    \\    pub fn maxC(a: T, c: f64) T { return if (a.v >= c) a else con(c); }
    \\    pub fn min(a: T, b: T) T { return if (a.v <= b.v) a else b; }
    \\    pub fn max(a: T, b: T) T { return if (a.v >= b.v) a else b; }
    \\};
    \\
    \\/// §4.5.2 accepted-step bookkeeping. `void` for a module with no stateful
    \\/// operator, which is most of them — codegen emits the state machine only
    \\/// when one is present.
    \\const State = if (@hasDecl(D, "updateState") and @hasDecl(D, "initState")) D.State else void;
    \\
    \\fn newState(model: *const D.Model, inst: *D.Instance) State {
    \\    if (State == void) return {};
    \\    return D.initState(model, inst);
    \\}
    \\
    \\/// Commit the accepted solution, exactly as a transient solver does after
    \\/// a converged step. `eval` READS the history out of `Instance`; this is the
    \\/// only thing that ever writes it, so without this call every §4.5 operator
    \\/// would answer from zero history at every time point and the transcript
    \\/// would claim more than it proves.
    \\fn step(model: *const D.Model, inst: *D.Instance, x: *const [n_u]f64, state: *State) void {
    \\    if (State == void) return;
    \\    _ = D.updateState(model, inst, x.*, state);
    \\}
    \\
    \\fn seed(x: *const [n_u]f64) [n_u]Dual {
    \\    var out: [n_u]Dual = undefined;
    \\    for (0..n_u) |i| {
    \\        out[i] = .{ .v = x[i] };
    \\        out[i].d[i] = 1.0;
    \\    }
    \\    return out;
    \\}
    \\
    \\const u_names = blk: {
    \\    const f = @typeInfo(D.U).@"enum".fields;
    \\    var names: [f.len][]const u8 = undefined;
    \\    for (f, 0..) |e, i| names[i] = e.name;
    \\    break :blk names;
    \\};
    \\
    \\/// One operating point: the bias, then whatever the model prints, then the
    \\/// residual it stamps and the Jacobian the solver would see.
    \\fn point(n: usize, x: *const [n_u]f64, t: f64, model: *const D.Model, inst: *const D.Instance) void {
    \\    std.debug.print("--- point {d} ---\n", .{n});
    \\    for (0..n_u) |i| std.debug.print("  x[{s}] = {e:.6}\n", .{ u_names[i], x[i] });
    \\    if (inst.abstime != 0.0 or inst.dt != 0.0)
    \\        std.debug.print("  t = {e:.6}  dt = {e:.6}\n", .{ inst.abstime, inst.dt });
    \\
    \\    // §5.10.5 the host's breakpoint hook, when codegen emitted one (only a
    \\    // module with a `timer` has one). Printed OUTSIDE `print_residual`
    \\    // because it is not part of the residual and the fixtures that test it
    \\    // are `print none`; `@hasDecl` keeps every other transcript unchanged.
    \\    if (@hasDecl(D, "nextBreakpoint")) {
    \\        if (D.nextBreakpoint(model, t)) |bp|
    \\            std.debug.print("  next_bp = {e:.6}\n", .{bp})
    \\        else
    \\            std.debug.print("  next_bp = none\n", .{});
    \\    }
    \\
    \\    const xd = seed(x);
    \\    // §9.4 the model's own transcript. Runs BEFORE the residual print so a
    \\    // fixture's `$strobe` lines sit next to the bias that produced them.
    \\    if (@hasDecl(D, "display")) D.display(Dual, xd, model, inst, t);
    \\    if (!print_residual) return;
    \\
    \\    const res = D.eval(Dual, xd, model, inst, t);
    \\    for (0..n_u) |i| {
    \\        std.debug.print("  res[{s}] = {e:.6}\n", .{ u_names[i], res[i].v });
    \\        for (0..n_u) |j| {
    \\            if (res[i].d[j] == 0.0) continue;
    \\            std.debug.print("    d res[{s}]/d x[{s}] = {e:.6}\n", .{ u_names[i], u_names[j], res[i].d[j] });
    \\        }
    \\    }
    \\    // §5.6.1.2 the reactive half, when the model has one. Its derivative is
    \\    // the capacitance/inductance matrix the host multiplies by d/dt.
    \\    if (@hasDecl(D, "q")) {
    \\        const qq = D.q(Dual, xd, model, inst, t);
    \\        for (0..n_u) |i| {
    \\            if (qq[i].v == 0.0 and allZero(qq[i].d)) continue;
    \\            std.debug.print("  q[{s}] = {e:.6}\n", .{ u_names[i], qq[i].v });
    \\            for (0..n_u) |j| {
    \\                if (qq[i].d[j] == 0.0) continue;
    \\                std.debug.print("    d q[{s}]/d x[{s}] = {e:.6}\n", .{ u_names[i], u_names[j], qq[i].d[j] });
    \\            }
    \\        }
    \\    }
    \\}
    \\
    \\fn allZero(v: [n_u]f64) bool {
    \\    for (v) |e| if (e != 0.0) return false;
    \\    return true;
    \\}
    \\
    \\
;

// ---------------------------------------------------------------------------
// Building the executable
// ---------------------------------------------------------------------------

pub const BuildOptions = struct {
    /// Scratch: `device.zig` and `tb.zig` are written here, and the binary
    /// lands here too unless `out_path` says otherwise.
    work_dir: []const u8,
    /// Root of the `contract` module the generated device imports.
    contract: []const u8,
    /// Artifact name — the module name, so the binary is `./<module>`.
    name: []const u8,
    out_path: ?[]const u8 = null,
    zig_exe: []const u8 = "zig",
};

pub const BuildResult = union(enum) {
    /// Path of the built binary (borrowed from the caller's allocator).
    ok: []const u8,
    /// `zig`'s stderr, verbatim. Generated code that does not compile is an
    /// ENGINE bug, and the only useful report is what the compiler said.
    failed: []const u8,

    pub fn deinit(self: BuildResult, gpa: Allocator) void {
        switch (self) {
            .ok => |p| gpa.free(p),
            .failed => |t| gpa.free(t),
        }
    }
};

/// device.zig + runner.zig → one native binary.
///
/// `build-exe` directly rather than through orchestrator.zig: that path exists
/// to produce a hot-reloadable `.so` with a generation counter and an incremental
/// resident compiler, and none of that applies to a testbench that is built once
/// and run once. Debug, not ReleaseFast — a transcript is a float comparison,
/// and `-OReleaseFast` is exactly where the backend is allowed to reassociate.
pub fn buildExe(
    gpa: Allocator,
    io: Io,
    device_zig: []const u8,
    runner_zig: []const u8,
    opts: BuildOptions,
) !BuildResult {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, opts.work_dir);
    var dir = try cwd.openDir(io, opts.work_dir, .{});
    defer dir.close(io);

    const dev_rel = try std.fmt.allocPrint(gpa, "{s}.device.zig", .{opts.name});
    defer gpa.free(dev_rel);
    const run_rel = try std.fmt.allocPrint(gpa, "{s}.tb.zig", .{opts.name});
    defer gpa.free(run_rel);
    try dir.writeFile(io, .{ .sub_path = dev_rel, .data = device_zig });
    try dir.writeFile(io, .{ .sub_path = run_rel, .data = runner_zig });

    const dev_path = try std.fs.path.join(gpa, &.{ opts.work_dir, dev_rel });
    defer gpa.free(dev_path);
    const run_path = try std.fs.path.join(gpa, &.{ opts.work_dir, run_rel });
    defer gpa.free(run_path);
    const bin = if (opts.out_path) |p|
        try gpa.dupe(u8, p)
    else
        try std.fs.path.join(gpa, &.{ opts.work_dir, opts.name });
    errdefer gpa.free(bin);

    // `--dep` binds to the NEXT `-M`, and the FIRST `-M` is the root module.
    const emit = try std.fmt.allocPrint(gpa, "-femit-bin={s}", .{bin});
    defer gpa.free(emit);
    const m_root = try std.fmt.allocPrint(gpa, "-Mroot={s}", .{run_path});
    defer gpa.free(m_root);
    const m_dev = try std.fmt.allocPrint(gpa, "-Mdevice={s}", .{dev_path});
    defer gpa.free(m_dev);
    const m_contract = try std.fmt.allocPrint(gpa, "-Mcontract={s}", .{opts.contract});
    defer gpa.free(m_contract);

    const argv = [_][]const u8{
        opts.zig_exe,  "build-exe",  emit,
        "--cache-dir", ".zig-cache", "--dep",
        "device",      "--dep",      "contract",
        m_root,        "--dep",      "contract",
        m_dev,         m_contract,
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });

    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var aw: Io.Writer.Allocating = .fromArrayList(gpa, &text);
    _ = reader.interface.streamRemaining(&aw.writer) catch {};
    text = aw.toArrayList();

    const term = try child.wait(io);
    const failed = switch (term) {
        .exited => |c| c != 0,
        else => true,
    };
    if (failed) {
        gpa.free(bin);
        return .{ .failed = try text.toOwnedSlice(gpa) };
    }
    text.deinit(gpa);
    return .{ .ok = bin };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "directives: defaults when the source has none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(), "module m; endmodule\n");
    try testing.expectEqual(@as(usize, 0), d.sweeps.len);
    try testing.expectEqual(@as(usize, 0), d.params.len);
    try testing.expectEqual(@as(f64, 300.15), d.temp);
    try testing.expectEqual(Analysis.dc, d.analysis);
    try testing.expect(d.print_residual);
}

test "directives: every form, including the §2.6 suffixes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try parse(arena_state.allocator(),
        \\//! param is = 1e-14, n = 1.05
        \\//! bias V(c) = 0
        \\//! sweep V(a) = 0, 0.3, 0.6
        \\//! temp 350
        \\//! time 0, 1n
        \\//! analysis tran
        \\//! print none
        \\module m(a, c); endmodule
    );
    try testing.expectEqual(@as(usize, 2), d.params.len);
    try testing.expectEqualStrings("is", d.params[0].name);
    try testing.expectEqual(@as(f64, 1e-14), d.params[0].value);
    try testing.expectEqualStrings("c", d.bias[0].name);
    try testing.expectEqualStrings("a", d.sweeps[0].name);
    try testing.expectEqual(@as(usize, 3), d.sweeps[0].values.len);
    try testing.expectEqual(@as(f64, 0.6), d.sweeps[0].values[2]);
    try testing.expectEqual(@as(f64, 350), d.temp);
    try testing.expectEqual(@as(f64, 1e-9), d.times[1]);
    try testing.expectEqual(Analysis.tran, d.analysis);
    try testing.expect(!d.print_residual);
}

test "directives: a typo is an error, not a silently skipped test" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.UnknownDirective, parse(arena_state.allocator(), "//! sweeep V(a) = 1\n"));
    try testing.expectError(error.BadSyntax, parse(arena_state.allocator(), "//! sweep V(a)\n"));
    try testing.expectError(error.BadNumber, parse(arena_state.allocator(), "//! temp warm\n"));
}

test "sweep expansion is the cartesian product, last fastest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! sweep V(a) = 0, 1
        \\//! sweep V(b) = 10, 20, 30
    );
    const pts = try expand(arena, d);
    try testing.expectEqual(@as(usize, 6), pts.len);
    try testing.expectEqualSlices(f64, &.{ 0, 10 }, pts[0]);
    try testing.expectEqualSlices(f64, &.{ 0, 20 }, pts[1]);
    try testing.expectEqualSlices(f64, &.{ 0, 30 }, pts[2]);
    try testing.expectEqualSlices(f64, &.{ 1, 10 }, pts[3]);
    try testing.expectEqualSlices(f64, &.{ 1, 30 }, pts[5]);
}

test "a wave is per-timepoint and holds its last value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! time 0, 1n, 2n, 3n
        \\//! wave V(in) = 0, 1
        \\//! bias V(out) = 0
    );
    try testing.expectEqual(@as(usize, 4), d.times.len);
    try testing.expectEqualStrings("in", d.waves[0].name);
    try testing.expectEqual(@as(usize, 2), d.waves[0].values.len);

    const src = try renderRunner(arena, "060_wave", d);
    // Four time points, one `x[…] = 1` per point after the first, and exactly
    // one `step(...)` per point: the state has to advance or the operators
    // answer from zero history every time.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, src, "        point("));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, src, "        step(&model"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "= newState("));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, src, "x[ix(\"in\")] = 1;"));
}

test "each sweep point starts its transient from a fresh State" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! sweep V(a) = 0, 1, 2
        \\//! time 0, 1n
    );
    const src = try renderRunner(arena, "061_reset", d);
    // Three sweep points × two times, and a `newState` per sweep point — not
    // per time, and not once for the whole run.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "        point("));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, src, "= newState("));
    // Point numbers are global, so no two transcript blocks share a label.
    try testing.expect(std.mem.indexOf(u8, src, "point(5, &x") != null);
}

test "renderRunner emits parseable Zig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try parse(arena,
        \\//! param g = 2m
        \\//! sweep V(p) = 0, 1
        \\//! bias V(n) = 0
    );
    const src = try renderRunner(arena, "001_demo", d);
    const z = try arena.dupeZ(u8, src);
    var ast = try std.zig.Ast.parse(testing.allocator, z, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
    // The sweep really did become two straight-line blocks.
    try testing.expect(std.mem.indexOf(u8, src, "point(0, &x") != null);
    try testing.expect(std.mem.indexOf(u8, src, "point(1, &x") != null);
    try testing.expect(std.mem.indexOf(u8, src, "model.g = 0.002") != null);
}
