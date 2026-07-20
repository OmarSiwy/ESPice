//! S-parameter sweep (`.sp`) and HSPICE `.lin` network parameters. One
//! linearization gives G and C, the port z0 terminations go into the
//! frequency solver's copy of G, and each frequency is one lane of
//! `freq.Stream` with one right-hand side per port.
//!
//! Wave variables (Kurokawa power waves):
//!   a_k = (V_k + z0_k·I_k) / (2√z0_k)
//!   b_k = (V_k - z0_k·I_k) / (2√z0_k)
//! where I_k = −i_br_k (branch stamps F_p = +i_br, so the DUT current is
//! negated). Driving port p with a unit source voltage (rhs[b_p] = 1) gives
//! a_p = 1/(2√z0_p) and a_j = 0 elsewhere, so column p of S(ω) is b_j / a_p.
//!
//! `.lin` converts S per frequency into Y, Z and H on small dense matrices,
//! takes group delays from a central difference at ω(1 ± gd_step) (two more
//! lanes per point, so frequency-dependent elements are differentiated
//! too), and reads the two-port noise parameters off one adjoint solve per
//! port (see `noiseParams`).
const std = @import("std");
const freq = @import("freq.zig");
const noise = @import("noise.zig");
const root = @import("../types.zig");
const Complex = @import("core").numerics.Complex;
const FreqSolver = @import("solver").freq_solve.FreqSolver;

/// A port is a netlist vsource: `node` and `neg` are its terminals, `branch`
/// its MNA branch-current unknown. Adding −z0 to the branch row diagonal
/// turns it into a Thevenin source with series z0
/// (v_p − v_n − z0·i_br = V_s), so an undriven port terminates in z0
/// instead of clamping its node. An HSPICE P card (`series_z0`) already
/// has that resistor in the circuit, between `node` and its source.
const Port = @import("core").query.Port;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Sp;
const Lin = Options.Lin;

/// ngspice CONSTboltz (const.h), the constant the device noise models use.
pub const k_boltzmann = 1.38064852e-23;
/// Noise figure reference temperature, K (IEEE; HSPICE's RN and GN too).
pub const t0_kelvin = 290.0;
/// Relative half-width of the group-delay central difference. Truncation is
/// O(gd_step²) and roundoff O(1e-16 / gd_step), both near 1e-10 relative.
const gd_step = 1e-5;

/// Contract entry: opts.ports (or the deck's drive source as port 1), the
/// full S-matrix per frequency, then `.lin`'s columns (`linNames`).
/// Complex, point-major (frequency, S11, S12, ..., Snn, ...).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const nn = 2 * n;

    const one_port = [_]Port{.{ .node = ctx.source_node, .branch = ctx.source_branch }};
    var basis = try Basis.init(scratch, if (opts.ports.len > 0) opts.ports else &one_port, if (opts.lin) |l| l.common else .{ false, false });
    defer basis.deinit(scratch);
    // Solves run over the legs; every published matrix is over the modes.
    const ports = basis.legs;
    const n_ports = ports.len;
    const n_points: usize = opts.sweep.count();

    const names = if (opts.lin) |lin| try linNames(a, n_ports, lin) else blk: {
        const names = try a.alloc([]const u8, 1 + n_ports * n_ports);
        names[0] = "frequency";
        for (0..n_ports) |i| for (0..n_ports) |j| {
            // ngspice names the columns `S_<row>_<col>` (1-based) as UID_OTHER
            // (span.c:544-551), and its raw writer types every non-current UID
            // as a voltage, so the file spells them `v(S_1_1)`. Readers of an
            // ngspice raw look them up by that name.
            names[1 + i * n_ports + j] = try std.fmt.allocPrint(a, "v(S_{d}_{d})", .{ i + 1, j + 1 });
        };
        break :blk names;
    };
    const row_len = names.len * 2;
    const data = try a.alloc(f64, n_points * row_len);

    var fs = try FreqSolver.fromCircuit(scratch, ckt, ctx.x_op);
    defer fs.deinit(scratch);
    // Series z0 inside each ideal port source: the branch row gains −z0·i_br.
    if (!opts.net) for (ports) |port| if (!port.series_z0) fs.addDiagG(port.branch, -port.z0);

    const axis = try scratch.alloc(f64, 2 * n_points);
    defer scratch.free(axis);
    const freqs = axis[0..n_points];
    const omegas = axis[n_points..];
    opts.sweep.fill(freqs, omegas);

    // One unit drive per port, every one solved against each factorization.
    const rhs = try scratch.alloc(f64, n_ports * nn);
    defer scratch.free(rhs);
    root.zeroSimd(rhs);
    for (ports, 0..) |port, p| {
        if (port.branch != Port.no_branch) {
            rhs[p * nn + port.branch] = 1.0;
            continue;
        }
        // `.net`: a unit current into `node`, out of `neg`.
        if (port.node != root.GROUND) rhs[p * nn + port.node] = 1.0;
        if (port.neg != root.GROUND) rhs[p * nn + port.neg] = -1.0;
    }

    var stream = try freq.Stream.init(scratch, &fs, ckt, ctx.x_op, omegas, rhs, false);
    defer stream.deinit(scratch);
    while (try stream.next(ckt)) |pt| {
        const row = data[pt.k * row_len ..][0..row_len];
        row[0] = freqs[pt.k];
        row[1] = 0;
        if (opts.net) {
            netRow(n, ports, pt.x, row[2..]);
        } else for (0..n_ports) |p| writeColumn(n, ports, pt.x[p * nn ..][0..nn], row[2..], p);
        try basis.toModes(row[2..][0 .. 2 * n_ports * n_ports]);
    }

    if (opts.lin) |lin| try linColumns(ctx, &fs, &basis, omegas, rhs, data, row_len, lin);

    return .{
        // The job name ngspice opens the plot under (span.c:599-601).
        .plotname = if (opts.lin != null) "LIN Analysis" else "SP Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}

/// The voltage of `node` in the stacked solution `x`; ground is zero.
inline fn nodeV(x: []const f64, n: usize, node: u32) Complex {
    return if (node == root.GROUND) Complex.zero else .{ .re = x[node], .im = x[n + node] };
}

/// Writes column p of S, driven with a unit source on port p's branch
/// (incident wave 1/(2√z0_p)), into the stacked (re, im) S-matrix `s_row`
/// of one frequency.
fn writeColumn(n: usize, ports: []const Port, x: []const f64, s_row: []f64, p: usize) void {
    const n_ports = ports.len;
    const a_p = 1.0 / (2.0 * @sqrt(ports[p].z0));
    for (ports, 0..) |port, k| {
        const br: usize = port.branch;
        var v_k = nodeV(x, n, port.node);
        if (port.neg != root.GROUND) v_k = v_k.sub(nodeV(x, n, port.neg));
        const i_k = Complex{ .re = -x[br], .im = -x[n + br] };
        const b_k = v_k.sub(i_k.scale(port.z0)).scale(1.0 / (2.0 * @sqrt(port.z0)));
        const s = b_k.scale(1.0 / a_p);
        const idx = (k * n_ports + p) * 2;
        s_row[idx] = s.re;
        s_row[idx + 1] = s.im;
    }
}

/// Writes the S matrix of one `.net` frequency from the ideal-port
/// solutions `x` (one stacked block per port drive). Each drive j gives
/// every port's voltage and current into the network (a branch port's
/// −i_br, otherwise the unit drive or nothing), so V = Vm·d and I = Im·d,
/// Z = Vm·Im⁻¹, and S = (Zn − E)(Zn + E)⁻¹ with Zn = F⁻¹ Z F⁻¹, F = diag(√z0).
/// One or two ports.
fn netRow(n: usize, ports: []const Port, x: []const f64, s_row: []f64) void {
    const np = ports.len;
    std.debug.assert(np <= 2);
    var vt: [4]Complex = undefined;
    var it: [4]Complex = undefined;
    for (0..np) |j| {
        const xj = x[j * 2 * n ..][0 .. 2 * n];
        for (ports, 0..) |port, k| {
            // Transposed: row j is drive j.
            vt[j * np + k] = nodeV(xj, n, port.node).sub(nodeV(xj, n, port.neg));
            it[j * np + k] = if (port.branch != Port.no_branch)
                .{ .re = -xj[port.branch], .im = -xj[n + port.branch] }
            else
                .{ .re = @floatFromInt(@intFromBool(j == k)), .im = 0 };
        }
    }
    // Imᵀ Zᵀ = Vmᵀ, then (Znᵀ + E) Sᵀ = (Znᵀ − E).
    solveDense(np, it[0 .. np * np], vt[0 .. np * np]);
    for (0..np) |i| for (0..np) |j| {
        const zn = vt[i * np + j].scale(1 / @sqrt(ports[i].z0 * ports[j].z0));
        const eye: f64 = @floatFromInt(@intFromBool(i == j));
        it[i * np + j] = .{ .re = zn.re + eye, .im = zn.im };
        vt[i * np + j] = .{ .re = zn.re - eye, .im = zn.im };
    };
    solveDense(np, it[0 .. np * np], vt[0 .. np * np]);
    for (0..np) |k| for (0..np) |p| {
        s_row[(k * np + p) * 2] = vt[p * np + k].re;
        s_row[(k * np + p) * 2 + 1] = vt[p * np + k].im;
    };
}

/// Mixed-mode ports [SA Ch.17] as a change of basis. A balanced port has
/// two legs, each a single-ended port against the shared reference, and two
/// modes: differential, (a+ − a−)/√2 against 2·z0, and common, (a+ + a−)/√2
/// against z0/2. These are the power waves of V+ − V− and of (V+ + V−)/2
/// (Bockelman and Eisenstadt, IEEE Trans. MTT 43(7), 1995), so S over the
/// modes is M·S_legs·Mᵀ for the orthogonal M, and Y, Z, H and the noise
/// parameters follow from it unchanged. Modes are ordered as HSPICE maps
/// them to Touchstone (S13 = SDC11 for two balanced ports): each port's
/// first mode (single-ended or differential) in port order, then the common
/// modes of the balanced ports in port order. Legs follow the same order, so
/// with no balanced port M is the identity and is not stored.
const Basis = struct {
    legs: []Port,
    /// Mode-by-leg M, row-major; empty when no port is balanced.
    m: []f64,
    /// Reference impedance of each mode.
    z0: []f64,
    /// The modes `.lin` reads as its two-port (H, stability, noise).
    pair: [2]usize,

    /// `common[i]` picks port i's common mode for the two-port
    /// (`Lin.common`); error.InvalidQueryOptions when port i is not
    /// balanced. The legs and tables are allocated from `gpa`.
    fn init(gpa: std.mem.Allocator, ports: []const Port, common: [2]bool) !Basis {
        var n_bal: usize = 0;
        for (ports) |p| n_bal += @intFromBool(p.balanced != null);
        const nl = ports.len + n_bal;
        const legs = try gpa.alloc(Port, nl);
        errdefer gpa.free(legs);
        const z0 = try gpa.alloc(f64, nl);
        errdefer gpa.free(z0);
        const m = try gpa.alloc(f64, if (n_bal == 0) 0 else nl * nl);
        errdefer gpa.free(m);
        @memset(m, 0);
        var b: Basis = .{ .legs = legs, .m = m, .z0 = z0, .pair = .{ 0, 1 } };
        var c = ports.len;
        const r: f64 = std.math.sqrt1_2;
        for (ports, 0..) |p, k| {
            legs[k] = p;
            legs[k].balanced = null;
            z0[k] = p.z0;
            const minus = p.balanced orelse {
                if (m.len != 0) m[k * nl + k] = 1;
                if (k < 2 and common[k]) return error.InvalidQueryOptions;
                continue;
            };
            legs[c] = legs[k];
            legs[c].node = minus.node;
            legs[c].branch = minus.branch;
            m[k * nl + k] = r;
            m[k * nl + c] = -r;
            m[c * nl + k] = r;
            m[c * nl + c] = r;
            z0[k] = 2 * p.z0;
            z0[c] = p.z0 / 2;
            if (k < 2 and common[k]) b.pair[k] = c;
            c += 1;
        }
        return b;
    }

    fn deinit(b: *Basis, gpa: std.mem.Allocator) void {
        gpa.free(b.legs);
        gpa.free(b.m);
        gpa.free(b.z0);
    }

    /// Turns the stacked (re, im) leg S matrix `s` into the mode one in
    /// place: M·S·Mᵀ. A no-op with no balanced port.
    fn toModes(b: Basis, s: []f64) !void {
        if (b.m.len == 0) return;
        const n = b.legs.len;
        var tmp: [2 * 16 * 16]f64 = undefined;
        if (n > 16) return error.InvalidQueryOptions;
        // ponytail: dense O(n³) on at most 16 legs; M has two nonzeros a row.
        for (0..n) |i| for (0..n) |j| for (0..2) |c| {
            var acc: f64 = 0;
            for (0..n) |k| acc += b.m[i * n + k] * s[(k * n + j) * 2 + c];
            tmp[(i * n + j) * 2 + c] = acc;
        };
        for (0..n) |i| for (0..n) |j| for (0..2) |c| {
            var acc: f64 = 0;
            for (0..n) |k| acc += tmp[(i * n + k) * 2 + c] * b.m[j * n + k];
            s[(i * n + j) * 2 + c] = acc;
        };
    }

    /// Weight of leg `l`'s port voltage in mode `q`'s voltage: the mode
    /// wave's M entry scaled by √(z0_mode / z0_leg), so the noise wave of
    /// mode q is Σ_l w·v_l / √z0_q.
    fn voltageWeight(b: Basis, q: usize, l: usize) f64 {
        const mql = if (b.m.len == 0) @as(f64, @floatFromInt(@intFromBool(q == l))) else b.m[q * b.legs.len + l];
        return mql * @sqrt(b.z0[q] / b.legs[l].z0);
    }
};

/// Modes (published ports) of `ports`: a balanced port counts twice. At
/// least 1, because an empty list means `run`'s one port at the deck's drive
/// source.
pub fn modeCount(ports: []const Port) usize {
    var n: usize = @max(ports.len, 1);
    for (ports) |p| n += @intFromBool(p.balanced != null);
    return n;
}

/// Complex entries of S, Y, Z and (two or more ports) H, in that order.
fn paramCount(n_ports: usize) usize {
    return 3 * n_ports * n_ports + @as(usize, if (n_ports >= 2) 4 else 0);
}

/// Columns `run` publishes for `n_ports` modes (`modeCount`), the frequency
/// included; `session.schemaOf` sizes the result with it before the run.
pub fn columns(n_ports: usize, lin: ?Lin) usize {
    const l = lin orelse return 1 + n_ports * n_ports;
    const m = paramCount(n_ports);
    const two_port = stab_names.len + if (l.noise) noise_names.len else 0;
    return 1 + m * (1 + @as(usize, @intFromBool(l.group_delay))) + if (n_ports >= 2) two_port else 0;
}

/// The two-port noise columns, in order.
const noise_names = [_][]const u8{ "NFMIN", "NF", "RN", "YOPT", "GAMMA_OPT" };
/// The two-port stability columns (HSPICE's names), in order.
const stab_names = [_][]const u8{ "K_STABILITY_FACTOR", "MU_STABILITY_FACTOR" };

/// `.lin` column names: `frequency`, then `X(i,j)` for X = S, Y, Z, H
/// (H over ports 1-2), then the group delays `TD(X(i,j))` in seconds
/// (HSPICE probes them as `X(i,j)(TD)`), the stability factors of ports
/// 1-2 (`stab_names`) and the two-port noise parameters (`noise_names`)
/// when asked. Real quantities have a zero imaginary part.
fn linNames(a: std.mem.Allocator, n_ports: usize, lin: Lin) ![]const []const u8 {
    const m = paramCount(n_ports);
    const noisy = lin.noise and n_ports >= 2;
    const names = try a.alloc([]const u8, columns(n_ports, lin));
    names[0] = "frequency";
    var at: usize = 1;
    for ("SYZH") |x| {
        const w = if (x == 'H') @min(n_ports, 2) else n_ports;
        if (w < 2 and x == 'H') continue;
        for (0..w) |i| for (0..w) |j| {
            names[at] = try std.fmt.allocPrint(a, "{c}({d},{d})", .{ x, i + 1, j + 1 });
            at += 1;
        };
    }
    if (lin.group_delay) for (names[1..][0..m]) |name| {
        names[at] = try std.fmt.allocPrint(a, "TD({s})", .{name});
        at += 1;
    };
    if (n_ports >= 2) {
        @memcpy(names[at..][0..stab_names.len], &stab_names);
        at += stab_names.len;
    }
    if (noisy) @memcpy(names[at..], &noise_names);
    return names;
}

/// Fills every `.lin` column after S from the S block of each row: Y, Z, H;
/// then the group delays (a forward sweep at ω(1 ± gd_step)); then the
/// noise parameters (an adjoint sweep with one right-hand side per port).
/// `fs` holds the port terminations and `rhs` the unit port drives.
fn linColumns(ctx: *const root.RunCtx, fs: *FreqSolver, basis: *const Basis, omegas: []const f64, rhs: []const f64, data: []f64, row_len: usize, lin: Lin) !void {
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const nn = 2 * n;
    const ports = basis.legs;
    const np = ports.len;
    const pq = basis.pair;
    const m = paramCount(np);
    const n_points = omegas.len;

    const work = try scratch.alloc(Complex, 2 * m + np * np);
    defer scratch.free(work);
    const lo = work[0..m];
    const hi = work[m..][0..m];
    const tmp = work[2 * m ..];
    for (0..n_points) |k| {
        const row = data[k * row_len ..][0..row_len];
        readComplex(row[2..][0 .. 2 * np * np], lo[0 .. np * np]);
        params(basis.z0, pq, lo, tmp);
        writeComplex(lo[np * np ..], row[2 + 2 * np * np ..][0 .. 2 * (m - np * np)]);
    }
    var col: usize = 1 + m;

    if (lin.group_delay) {
        const pm = try scratch.alloc(f64, 2 * n_points + 2 * np * np);
        defer scratch.free(pm);
        const s_row = pm[2 * n_points ..];
        for (omegas, 0..) |w, k| {
            const dw = gd_step * @max(w, 1.0);
            pm[2 * k] = w - dw;
            pm[2 * k + 1] = w + dw;
        }
        var stream = try freq.Stream.init(scratch, fs, ckt, ctx.x_op, pm[0 .. 2 * n_points], rhs, false);
        defer stream.deinit(scratch);
        while (try stream.next(ckt)) |pt| {
            for (0..np) |p| writeColumn(n, ports, pt.x[p * nn ..][0..nn], s_row, p);
            try basis.toModes(s_row);
            const side = if (pt.k % 2 == 0) lo else hi;
            readComplex(s_row, side[0 .. np * np]);
            params(basis.z0, pq, side, tmp);
            if (pt.k % 2 == 0) continue;
            const k = pt.k / 2;
            const row = data[k * row_len ..][0..row_len];
            const span = pm[pt.k] - pm[pt.k - 1];
            for (lo, hi, 0..) |l, h, e| {
                // −dφ/dω, from the phase of the ratio so a wrap cannot enter.
                const r = h.div(l);
                row[2 * (col + e)] = -std.math.atan2(r.im, r.re) / span;
                row[2 * (col + e) + 1] = 0;
            }
        }
        col += m;
    }

    if (np >= 2) {
        for (0..n_points) |k| {
            const row = data[k * row_len ..][0..row_len];
            readComplex(row[2..][0 .. 2 * np * np], lo[0 .. np * np]);
            const ks = stability(block(lo, np, pq));
            for (ks, 0..) |v, i| {
                row[2 * (col + i)] = v;
                row[2 * (col + i) + 1] = 0;
            }
        }
        col += stab_names.len;
    }

    if (lin.noise and np >= 2) {
        const srcs = try ckt.collectNoiseSources(ctx.x_op, scratch);
        defer scratch.free(srcs);
        // Adjoint of each two-port mode's voltage, Σ_l w·(v(node) − v(neg))
        // over its legs (`Basis.voltageWeight`).
        const e = try scratch.alloc(f64, 2 * nn);
        defer scratch.free(e);
        root.zeroSimd(e);
        for (pq, 0..) |q, i| for (ports, 0..) |port, l| {
            const w = basis.voltageWeight(q, l);
            if (w == 0) continue;
            if (port.node != root.GROUND) e[i * nn + port.node] += w;
            if (port.neg != root.GROUND) e[i * nn + port.neg] -= w;
        };
        var stream = try freq.Stream.init(scratch, fs, ckt, ctx.x_op, omegas, e, true);
        defer stream.deinit(scratch);
        while (try stream.next(ckt)) |pt| {
            const row = data[pt.k * row_len ..][0..row_len];
            const f = row[0];
            // Port voltage noise correlation with every port terminated in
            // its (noiseless) z0: C_ij = Σ_s PSD_s · h_is · conj(h_js). The
            // stacked-real transpose solve is A^H y = e, so the transfer
            // h = conj(y_p − y_n), and h1·conj(h2) = conj(y1)·y2.
            var c11: f64 = 0;
            var c22: f64 = 0;
            var c12 = Complex.zero;
            var lead: usize = 0;
            while (lead < srcs.len) {
                const end = noise.NoiseSource.groupEnd(srcs, lead);
                defer lead = end;
                // One correlated group: its rows' transfers add as phasors.
                const psd = noise.sourcePsd(srcs[lead], f);
                const h1 = noise.transfer(srcs[lead..end], pt.x[0..nn], n);
                const h2 = noise.transfer(srcs[lead..end], pt.x[nn..], n);
                const y1: Complex = .{ .re = h1[0], .im = h1[1] };
                const y2: Complex = .{ .re = h2[0], .im = h2[1] };
                c11 += psd * y1.magSq();
                c22 += psd * y2.magSq();
                c12 = c12.add(y2.mul(.{ .re = y1.re, .im = -y1.im }).scale(psd));
            }
            readComplex(row[2..][0 .. 2 * np * np], lo[0 .. np * np]);
            const out = noiseParams(block(lo, np, pq), .{ basis.z0[pq[0]], basis.z0[pq[1]] }, .{ c11, c22 }, c12);
            for (out, 0..) |v, i| {
                row[2 * (col + i)] = v.re;
                row[2 * (col + i) + 1] = v.im;
            }
        }
    }
}

/// Rollett's K and Edwards-Sinsky's μ of the 2x2 S block `s` (row-major),
/// as HSPICE defines them [SA Ch.17]: with Δ = S11·S22 − S12·S21,
///   K = (1 − |S11|² − |S22|² + |Δ|²) / (2|S12·S21|),
///   μ = (1 − |S11|²) / (|S22 − Δ·S11*| + |S12·S21|).
/// A unilateral block (S12·S21 = 0) gives an infinite K.
fn stability(s: [4]Complex) [stab_names.len]f64 {
    const p = s[1].mul(s[2]);
    const delta = s[0].mul(s[3]).sub(p);
    const k = (1 - s[0].magSq() - s[3].magSq() + delta.magSq()) / (2 * @sqrt(p.magSq()));
    const d = s[3].sub(delta.mul(.{ .re = s[0].re, .im = -s[0].im }));
    const mu = (1 - s[0].magSq()) / (@sqrt(d.magSq()) + @sqrt(p.magSq()));
    return .{ k, mu };
}

fn readComplex(src: []const f64, dst: []Complex) void {
    for (dst, 0..) |*z, i| z.* = .{ .re = src[2 * i], .im = src[2 * i + 1] };
}

fn writeComplex(src: []const Complex, dst: []f64) void {
    for (src, 0..) |z, i| {
        dst[2 * i] = z.re;
        dst[2 * i + 1] = z.im;
    }
}

/// The 2x2 block of rows and columns `pq` of the n×n row-major `s`.
fn block(s: []const Complex, n: usize, pq: [2]usize) [4]Complex {
    return .{ s[pq[0] * n + pq[0]], s[pq[0] * n + pq[1]], s[pq[1] * n + pq[0]], s[pq[1] * n + pq[1]] };
}

/// Given S in `p[0..n²]` (row-major), fills Y, Z and H after it
/// (`paramCount` entries). With F = diag(√z0):
///   Y = F⁻¹ (E + S)⁻¹ (E − S) F⁻¹,   Z = F (E − S)⁻¹ (E + S) F,
/// and H over the two-port `pq` comes from the Z of its 2x2 S block (the
/// other ports terminated in z0, as HSPICE defines it). A singular E ± S
/// (an open or a short port) gives non-finite entries. `tmp` holds n²
/// values.
fn params(z0: []const f64, pq: [2]usize, p: []Complex, tmp: []Complex) void {
    const n = z0.len;
    const n2 = n * n;
    const s = p[0..n2];
    const y = p[n2..][0..n2];
    const z = p[2 * n2 ..][0..n2];
    const lhs = tmp[0..n2];
    for (0..2) |which| {
        // which 0: (E + S) Y' = (E − S); which 1: (E − S) Z' = (E + S).
        const sign: f64 = if (which == 0) 1 else -1;
        const out = if (which == 0) y else z;
        for (0..n) |i| for (0..n) |j| {
            const eye: f64 = if (i == j) 1 else 0;
            lhs[i * n + j] = .{ .re = eye + sign * s[i * n + j].re, .im = sign * s[i * n + j].im };
            out[i * n + j] = .{ .re = eye - sign * s[i * n + j].re, .im = -sign * s[i * n + j].im };
        };
        solveDense(n, lhs, out);
        for (0..n) |i| for (0..n) |j| {
            const f = @sqrt(z0[i] * z0[j]);
            out[i * n + j] = out[i * n + j].scale(if (which == 0) 1 / f else f);
        };
    }
    if (n < 2) return;
    // Z of the two-port block: (E − S₂)⁻¹ (E + S₂), scaled as above.
    const s2 = block(s, n, pq);
    var l2 = [4]Complex{ .{ .re = 1 - s2[0].re, .im = -s2[0].im }, s2[1].scale(-1), s2[2].scale(-1), .{ .re = 1 - s2[3].re, .im = -s2[3].im } };
    var z2 = [4]Complex{ .{ .re = 1 + s2[0].re, .im = s2[0].im }, s2[1], s2[2], .{ .re = 1 + s2[3].re, .im = s2[3].im } };
    solveDense(2, &l2, &z2);
    for (0..2) |i| for (0..2) |j| {
        z2[i * 2 + j] = z2[i * 2 + j].scale(@sqrt(z0[pq[i]] * z0[pq[j]]));
    };
    // V1 = h11·I1 + h12·V2, I2 = h21·I1 + h22·V2.
    const h = p[3 * n2 ..][0..4];
    const inv22 = Complex.div(.{ .re = 1, .im = 0 }, z2[3]);
    h[0] = z2[0].mul(z2[3]).sub(z2[1].mul(z2[2])).mul(inv22);
    h[1] = z2[1].mul(inv22);
    h[2] = z2[2].mul(inv22).scale(-1);
    h[3] = inv22;
}

/// Solves A·X = B in place (B becomes X) for n×n row-major complex A and
/// B, by Gaussian elimination with partial pivoting. Destroys A.
fn solveDense(n: usize, a: []Complex, b: []Complex) void {
    for (0..n) |c| {
        var piv = c;
        for (c + 1..n) |r| if (a[r * n + c].magSq() > a[piv * n + c].magSq()) {
            piv = r;
        };
        if (piv != c) for (0..n) |j| {
            std.mem.swap(Complex, &a[c * n + j], &a[piv * n + j]);
            std.mem.swap(Complex, &b[c * n + j], &b[piv * n + j]);
        };
        const inv = Complex.div(.{ .re = 1, .im = 0 }, a[c * n + c]);
        for (c + 1..n) |r| {
            const f = a[r * n + c].mul(inv);
            for (c..n) |j| a[r * n + j] = a[r * n + j].sub(f.mul(a[c * n + j]));
            for (0..n) |j| b[r * n + j] = b[r * n + j].sub(f.mul(b[c * n + j]));
        }
    }
    var c = n;
    while (c > 0) {
        c -= 1;
        const inv = Complex.div(.{ .re = 1, .im = 0 }, a[c * n + c]);
        for (0..n) |j| {
            var acc = b[c * n + j];
            for (c + 1..n) |k| acc = acc.sub(a[c * n + k].mul(b[k * n + j]));
            b[c * n + j] = acc.mul(inv);
        }
    }
}

/// Two-port noise parameters from the 2x2 S block `s` (row-major), the port
/// impedances and the port voltage noise correlation (one-sided, V²/Hz)
/// with both ports terminated in z0: diagonal `cv` and C₁₂ = ⟨v₁ v₂*⟩.
///
/// The terminated port voltages are the noise waves times √z0 (a = 0, so
/// b = v/√z0). The short-circuit noise currents are i = −2 F⁻¹ (E + S)⁻¹ c
/// (Hillbrand and Russer, IEEE Trans. CAS 23(4), 1976), and the chain form
/// puts v_n = −i₂/Y₂₁ and i_n = i₁ − (Y₁₁/Y₂₁) i₂ at the input. With
/// S_vv, S_ii and S_iv = ⟨i_n v_n*⟩ (4kT₀ = 4k·290 K):
///   RN = S_vv / 4kT₀,  YOPT = (√(S_ii S_vv − Im² S_iv) − j Im S_iv) / S_vv,
///   NFMIN = 1 + (Re S_iv + √(S_ii S_vv − Im² S_iv)) / 2kT₀,
///   NF = 1 + (S_ii + S_vv |Y_s|² + 2 Re(Y_s* S_iv)) / (4kT₀ G_s), Y_s = 1/z0₁.
/// NFMIN and NF are power ratios; GAMMA_OPT is YOPT's reflection against
/// port 1's z0.
fn noiseParams(s: [4]Complex, z0: [2]f64, cv: [2]f64, c12: Complex) [noise_names.len]Complex {
    // G = 2 F⁻¹ (E + S)⁻¹, rows scaled by 1/√z0.
    var e_s = [4]Complex{ .{ .re = 1 + s[0].re, .im = s[0].im }, s[1], s[2], .{ .re = 1 + s[3].re, .im = s[3].im } };
    var g = [4]Complex{ .{ .re = 2, .im = 0 }, Complex.zero, Complex.zero, .{ .re = 2, .im = 0 } };
    solveDense(2, &e_s, &g);
    for (0..2) |i| for (0..2) |j| {
        g[i * 2 + j] = g[i * 2 + j].scale(1 / @sqrt(z0[i]));
    };
    // Noise-wave correlation C_S = C_v / √(z0_i z0_j), then C_Y = G C_S Gᴴ.
    const cs = [4]Complex{
        .{ .re = cv[0] / z0[0], .im = 0 },
        c12.scale(1 / @sqrt(z0[0] * z0[1])),
        .{ .re = c12.re / @sqrt(z0[0] * z0[1]), .im = -c12.im / @sqrt(z0[0] * z0[1]) },
        .{ .re = cv[1] / z0[1], .im = 0 },
    };
    // Y of the block: G (E − S) / 2 · F⁻¹ = F⁻¹ (E + S)⁻¹ (E − S) F⁻¹.
    var y: [4]Complex = undefined;
    for (0..2) |i| for (0..2) |j| {
        var acc = Complex.zero;
        for (0..2) |k| {
            const eye: f64 = if (k == j) 1 else 0;
            acc = acc.add(g[i * 2 + k].mul(.{ .re = eye - s[k * 2 + j].re, .im = -s[k * 2 + j].im }));
        }
        y[i * 2 + j] = acc.scale(0.5 / @sqrt(z0[j]));
    };
    // T = [[0, −1/Y21], [1, −Y11/Y21]] maps the Y-form currents to (v_n, i_n);
    // M = T·G maps the noise waves to them directly.
    const inv21 = Complex.div(.{ .re = -1, .im = 0 }, y[2]);
    const t = [4]Complex{ Complex.zero, inv21, .{ .re = 1, .im = 0 }, y[0].mul(inv21) };
    var mm: [4]Complex = undefined;
    for (0..2) |i| for (0..2) |j| {
        mm[i * 2 + j] = t[i * 2].mul(g[j]).add(t[i * 2 + 1].mul(g[2 + j]));
    };
    // C_A = M C_S Mᴴ; only S_vv, S_ii and S_iv are needed.
    const quad = struct {
        fn f(u: [2]Complex, c: [4]Complex, w: [2]Complex) Complex {
            var acc = Complex.zero;
            for (0..2) |i| for (0..2) |j| {
                acc = acc.add(u[i].mul(c[i * 2 + j]).mul(.{ .re = w[j].re, .im = -w[j].im }));
            };
            return acc;
        }
    }.f;
    const v_row = [2]Complex{ mm[0], mm[1] };
    const i_row = [2]Complex{ mm[2], mm[3] };
    const s_vv = quad(v_row, cs, v_row).re;
    const s_ii = quad(i_row, cs, i_row).re;
    const s_iv = quad(i_row, cs, v_row);
    const kt = k_boltzmann * t0_kelvin;
    const root_term = @sqrt(@max(s_ii * s_vv - s_iv.im * s_iv.im, 0));
    const yopt = Complex{ .re = root_term / s_vv, .im = -s_iv.im / s_vv };
    const gs = 1 / z0[0];
    const f_min = 1 + (s_iv.re + root_term) / (2 * kt);
    const f_50 = 1 + (s_ii + s_vv * gs * gs + 2 * gs * s_iv.re) / (4 * kt * gs);
    const zy = yopt.scale(z0[0]);
    const gamma = Complex.div(.{ .re = 1 - zy.re, .im = -zy.im }, .{ .re = 1 + zy.re, .im = zy.im });
    return .{
        .{ .re = f_min, .im = 0 },
        .{ .re = f_50, .im = 0 },
        .{ .re = s_vv / (4 * kt), .im = 0 },
        yopt,
        gamma,
    };
}

const testing = std.testing;

fn expectNear(want: Complex, got: Complex, tol: f64) !void {
    try testing.expectApproxEqAbs(want.re, got.re, tol);
    try testing.expectApproxEqAbs(want.im, got.im, tol);
}

test solveDense {
    // Certificate: A·X = B for a dense complex A that needs a row swap
    // (zero leading pivot), X solved for B = I.
    const n = 3;
    const a0 = [n * n]Complex{
        .zero,                  .{ .re = 2, .im = -1 },  .{ .re = 0.5, .im = 0 },
        .{ .re = 1, .im = 1 },  .{ .re = -1, .im = 0 },  .{ .re = 0, .im = 3 },
        .{ .re = 4, .im = -2 }, .{ .re = 0, .im = 0.5 }, .{ .re = 1, .im = 0 },
    };
    var a = a0;
    var x: [n * n]Complex = @splat(.zero);
    for (0..n) |i| x[i * n + i] = .{ .re = 1, .im = 0 };
    solveDense(n, &a, &x);
    for (0..n) |i| for (0..n) |j| {
        var acc = Complex.zero;
        for (0..n) |k| acc = acc.add(a0[i * n + k].mul(x[k * n + j]));
        try expectNear(.{ .re = @floatFromInt(@intFromBool(i == j)), .im = 0 }, acc, 1e-14);
    };
}

test params {
    // Matched ports (S = 0): Y = diag(1/z0), Z = diag(z0), and the two-port
    // H is z0₁ at h11 and 1/z0₂ at h22.
    const z0 = [_]f64{ 50, 75, 25 };
    const np = z0.len;
    var p: [paramCount(np)]Complex = @splat(.zero);
    var tmp: [np * np]Complex = undefined;
    params(&z0, .{ 0, 1 }, &p, &tmp);
    const y = p[np * np ..][0 .. np * np];
    const zm = p[2 * np * np ..][0 .. np * np];
    const h = p[3 * np * np ..][0..4];
    for (0..np) |i| for (0..np) |j| {
        const on: f64 = @floatFromInt(@intFromBool(i == j));
        try expectNear(.{ .re = on / z0[i], .im = 0 }, y[i * np + j], 1e-15);
        try expectNear(.{ .re = on * z0[i], .im = 0 }, zm[i * np + j], 1e-12);
    };
    try expectNear(.{ .re = 50, .im = 0 }, h[0], 1e-12);
    try expectNear(.zero, h[1], 1e-15);
    try expectNear(.zero, h[2], 1e-15);
    try expectNear(.{ .re = 1.0 / 75.0, .im = 0 }, h[3], 1e-15);

    // Y·Z = E for a general S (certificate of the two inversions).
    const s = [_]Complex{
        .{ .re = 0.2, .im = 0.1 },   .{ .re = -0.3, .im = 0.05 }, .{ .re = 0.1, .im = 0 },
        .{ .re = 0.4, .im = -0.2 },  .{ .re = 0.1, .im = 0.3 },   .{ .re = 0, .im = -0.1 },
        .{ .re = 0.05, .im = 0.05 }, .{ .re = -0.1, .im = 0 },    .{ .re = 0.3, .im = 0.2 },
    };
    @memcpy(p[0 .. np * np], &s);
    params(&z0, .{ 0, 1 }, &p, &tmp);
    for (0..np) |i| for (0..np) |j| {
        var acc = Complex.zero;
        for (0..np) |k| acc = acc.add(y[i * np + k].mul(zm[k * np + j]));
        try expectNear(.{ .re = @floatFromInt(@intFromBool(i == j)), .im = 0 }, acc, 1e-12);
    };
}

test stability {
    // A matched amplifier (S11 = S22 = 0) has K = (1 + |p|²)/(2|p|) and
    // μ = 1/|p|, p = S12·S21; a unilateral one has K = ∞.
    const s = [4]Complex{ .zero, .{ .re = 0.1, .im = 0 }, .{ .re = 0, .im = 5 }, .zero };
    const ks = stability(s);
    try testing.expectApproxEqRel((1 + 0.25) / (2 * 0.5), ks[0], 1e-15);
    try testing.expectApproxEqRel(1 / 0.5, ks[1], 1e-15);
    const uni = stability(.{ .{ .re = 0.5, .im = 0 }, .zero, .{ .re = 3, .im = 0 }, .{ .re = 0.2, .im = 0 } });
    try testing.expect(std.math.isPositiveInf(uni[0]));
}

test noiseParams {
    // A noiseless two-port: no noise resistance and a 1.0 noise figure.
    const s = [4]Complex{ .{ .re = 0.1, .im = 0.2 }, .{ .re = 0.05, .im = 0 }, .{ .re = 2, .im = -1 }, .{ .re = -0.2, .im = 0.1 } };
    const out = noiseParams(s, .{ 50, 50 }, .{ 0, 0 }, .zero);
    try testing.expectEqual(@as(f64, 1), out[1].re);
    try testing.expectEqual(@as(f64, 0), out[2].re);
}

test netRow {
    // One ideal V port reading 1 V and drawing 10 mA (i_br = −10 mA): Z =
    // 100 Ω against z0 = 50 Ω, so S = (2 − 1)/(2 + 1).
    const n = 3;
    var x: [2 * n]f64 = @splat(0);
    x[1] = 1;
    x[2] = -0.01;
    const ports = [_]Port{.{ .node = 1, .branch = 2, .z0 = 50 }};
    var s_row: [2]f64 = undefined;
    netRow(n, &ports, &x, &s_row);
    try testing.expectApproxEqRel(1.0 / 3.0, s_row[0], 1e-14);
    try testing.expectApproxEqAbs(0, s_row[1], 1e-16);
}

test writeColumn {
    // A port terminated in its own z0 reads V = z0·I, so b = 0: S11 = 0.
    // Driven with 1 V through series z0 into a matched load, V = 0.5 and
    // I = 10 mA (i_br = −10 mA).
    const n = 3;
    var x: [2 * n]f64 = @splat(0);
    x[1] = 0.5;
    x[2] = -0.01;
    const ports = [_]Port{.{ .node = 1, .branch = 2, .z0 = 50 }};
    var s_row: [2]f64 = undefined;
    writeColumn(n, &ports, &x, &s_row, 0);
    try testing.expectApproxEqAbs(0, s_row[0], 1e-15);
    try testing.expectApproxEqAbs(0, s_row[1], 1e-15);
}

test Basis {
    // A balanced port and a single-ended one: legs (+, single, −), M
    // orthogonal, so the identity S stays the identity over the modes.
    const ports = [_]Port{
        .{ .node = 1, .branch = 4, .balanced = .{ .node = 2, .branch = 5 } },
        .{ .node = 3, .branch = 6 },
    };
    var b = try Basis.init(testing.allocator, &ports, .{ false, false });
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), b.legs.len);
    try testing.expectEqual(@as(u32, 2), b.legs[2].node);
    try testing.expectEqualSlices(f64, &.{ 100, 50, 25 }, b.z0);
    var s: [2 * 9]f64 = @splat(0);
    for (0..3) |i| s[(i * 3 + i) * 2] = 1;
    try b.toModes(&s);
    for (0..3) |i| for (0..3) |j| {
        try testing.expectApproxEqAbs(@as(f64, @floatFromInt(@intFromBool(i == j))), s[(i * 3 + j) * 2], 1e-15);
        try testing.expectApproxEqAbs(0, s[(i * 3 + j) * 2 + 1], 1e-15);
    };
    // The common mode of a balanced port can be the two-port's first port;
    // asking it of a single-ended port is an error.
    var c = try Basis.init(testing.allocator, &ports, .{ true, false });
    defer c.deinit(testing.allocator);
    try testing.expectEqual([2]usize{ 2, 1 }, c.pair);
    try testing.expectError(error.InvalidQueryOptions, Basis.init(testing.allocator, &ports, .{ false, true }));
}

test linNames {
    // Every slot `columns` sizes is written, for every port count and flag.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (1..5) |np| for ([_]bool{ false, true }) |gd| for ([_]bool{ false, true }) |nz| {
        const lin: Lin = .{ .group_delay = gd, .noise = nz };
        const names = try linNames(arena.allocator(), np, lin);
        try testing.expectEqual(columns(np, lin), names.len);
        const last = if (np >= 2 and nz) "GAMMA_OPT" else if (np >= 2) "MU_STABILITY_FACTOR" else if (gd) "TD(Z(1,1))" else "Z(1,1)";
        try testing.expectEqualStrings(last, names[names.len - 1]);
    };
    try testing.expectEqual(@as(usize, 1), modeCount(&.{}));
}
