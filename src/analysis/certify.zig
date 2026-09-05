//! The KCL certificate (`zig build -Dcertify`, #53): at every point direct
//! Newton converges on, re-evaluate the devices at the published x with the
//! limiters cleared and check the result against the solver's own promise.
//!
//! Asserted: the converger's per-row residual gate
//! (`converger.residualGate`, with the same gmin and force loads). A row
//! over it panics, naming the row, so a corpus run fails that deck.
//! Reported: the current bound ||F_kcl||_inf <= abstol + reltol * max|I|,
//! where F_kcl is every non-branch row and max|I| the largest branch
//! current in x. The circuit keeps the worst ratio and prints it once, on
//! release. The gate is looser than this bound by design (dev/analysis/
//! tolerance-system.md, "KCL certificate"), so the bound only reports.
//!
//! Off by default, and comptime-gated: without `-Dcertify` the `Tally`
//! field is void and `newton` never calls `check`.

const std = @import("std");
const converger = @import("solver").converger;

/// Whether this build certifies, from `-Dcertify`.
pub const enabled = @import("build_options").certify;

/// One circuit's certificate record: the worst current-bound ratio, where
/// it fell, and the point counts. `scratch` holds the planes `check`
/// restores, sized on first use and freed by `deinit`.
pub const Tally = struct {
    points: u64 = 0,
    /// Points whose ratio exceeded 1.
    over: u64 = 0,
    worst: f64 = 0,
    worst_t: f64 = 0,
    worst_row: u32 = 0,
    worst_kind: []const u8 = "",
    scratch: []f64 = &.{},

    /// Prints the record when any point was certified, then frees `scratch`.
    pub fn deinit(self: *Tally, gpa: std.mem.Allocator, node_name: []const u8) void {
        if (self.points > 0) std.debug.print(
            "certify: {d} points, {d} over abstol+reltol*max|I|, worst |F|/bound = {e:.3} ({s} t={e:.3} row {d} {s})\n",
            .{ self.points, self.over, self.worst, self.worst_kind, self.worst_t, self.worst_row, node_name },
        );
        gpa.free(self.scratch);
        self.* = .{};
    }
};

/// What `measure` found at one point.
pub const Point = struct {
    /// The first row over the converger's gate, or null when every row
    /// passes it.
    gate_row: ?u32,
    /// |F| and the gate on `gate_row`; zero when it is null.
    gate_f: f64 = 0,
    gate_tol: f64 = 0,
    /// ||F_kcl||_inf / (abstol + reltol * max|I|), and its row.
    ratio: f64,
    kcl_row: u32,
};

/// The f64 count of `scratch` that `measure` needs for `ckt`.
pub fn scratchLen(ckt: anytype) usize {
    return ckt.g_vals.len + ckt.c_vals.len + ckt.rhs.len + ckt.q_vec.len;
}

/// Re-evaluates `ckt` at the converged `x` through `hook`, with the
/// limiters cleared and `opts`' gmin and force loads, and measures it
/// against the gate and the current bound (see the file comment). Leaves
/// the planes and `q_fresh` as it found them, but the limiters cleared: a
/// transient carries limiter history from point to point, so a certified
/// run can take other steps than an uncertified one.
/// `scratch.len` must be `scratchLen(ckt)`.
pub fn measure(ckt: anytype, hook: anytype, x: []const f64, t: f64, opts: converger.Options, scratch: []f64) Point {
    const n: usize = ckt.n;
    std.debug.assert(x.len == n);
    std.debug.assert(scratch.len == scratchLen(ckt));
    const planes = .{ "g_vals", "c_vals", "rhs", "q_vec" };
    var off: usize = 0;
    inline for (planes) |p| {
        const src = @field(ckt, p);
        @memcpy(scratch[off..][0..src.len], src);
        off += src.len;
    }
    const q_fresh = ckt.q_fresh;

    ckt.clearLimits();
    hook.assemble(ckt, x, t);
    const v = hook.vals(ckt);
    converger.loadExtras(ckt, v, x, opts);
    var pt: Point = .{ .gate_row = null, .ratio = 0, .kcl_row = 0 };
    var kcl: f64 = 0;
    var i_max: f64 = 0;
    for (0..n) |i| {
        const f = @abs(ckt.rhs[i]);
        const gate = converger.residualGate(opts, v[ckt.diag_slots[i]], x[i]);
        // Negated, so a NaN residual fails too.
        if (!(f <= gate) and pt.gate_row == null) {
            pt.gate_row = @intCast(i);
            pt.gate_f = f;
            pt.gate_tol = gate;
        }
        if (ckt.current_row[i]) {
            i_max = @max(i_max, @abs(x[i]));
        } else if (!(f <= kcl)) {
            kcl = f;
            pt.kcl_row = @intCast(i);
        }
    }
    pt.ratio = kcl / (opts.abstol + opts.reltol * i_max);

    ckt.clearLimits();
    off = 0;
    inline for (planes) |p| {
        const dst = @field(ckt, p);
        @memcpy(dst, scratch[off..][0..dst.len]);
        off += dst.len;
    }
    ckt.q_fresh = q_fresh;
    std.debug.assert(off == scratch.len);
    return pt;
}

/// `measure`, then panics when a row is over the converger's gate, and
/// records the ratio in `ckt.cert`. `newton` calls it, through
/// `Circuit.certifyPoint`, on every converged x under `-Dcertify`, after
/// every gate and before `updateStates` stages the point: a device whose
/// eval reads its staged history would otherwise see x twice.
pub fn check(ckt: anytype, hook: anytype, x: []const f64, t: f64, opts: converger.Options) void {
    comptime std.debug.assert(enabled);
    const tally = &ckt.cert;
    const need = scratchLen(ckt);
    if (tally.scratch.len != need) {
        ckt.gpa.free(tally.scratch);
        tally.scratch = ckt.gpa.alloc(f64, need) catch @panic("certify: out of memory");
    }
    const pt = measure(ckt, hook, x, t, opts, tally.scratch);
    if (pt.gate_row) |row| std.debug.panic(
        "certify: row {d} ({s}) |F| = {e:.3} exceeds the converger's gate {e:.3} at {s} t={e:.6}, x = {e:.6}",
        .{ row, ckt.nodeName(row), pt.gate_f, pt.gate_tol, @tagName(ckt.sim.kind), t, x[row] },
    );
    tally.points += 1;
    if (pt.ratio > 1) tally.over += 1;
    if (!(pt.ratio <= tally.worst)) {
        tally.worst = pt.ratio;
        tally.worst_t = t;
        tally.worst_row = pt.kcl_row;
        tally.worst_kind = @tagName(ckt.sim.kind);
    }
    std.debug.assert(tally.over <= tally.points);
}
