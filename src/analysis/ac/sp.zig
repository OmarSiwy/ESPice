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
/// instead of clamping its node.
const Port = @import("core").query.Port;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Sp;
const Lin = Options.Lin;

/// ngspice CONSTboltz (const.h), the constant the device noise models use.
const k_boltzmann = 1.38064852e-23;
/// Noise figure reference temperature, K (IEEE; HSPICE's RN and GN too).
const t0_kelvin = 290.0;
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
    const ports: []const Port = if (opts.ports.len > 0) opts.ports else &one_port;
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
    // Series z0 inside each port source: the branch row gains −z0·i_br.
    for (ports) |port| fs.addDiagG(port.branch, -port.z0);

    const axis = try scratch.alloc(f64, 2 * n_points);
    defer scratch.free(axis);
    const freqs = axis[0..n_points];
    const omegas = axis[n_points..];
    opts.sweep.fill(freqs, omegas);

    // One unit drive per port, every one solved against each factorization.
    const rhs = try scratch.alloc(f64, n_ports * nn);
    defer scratch.free(rhs);
    root.zeroSimd(rhs);
    for (ports, 0..) |port, p| rhs[p * nn + port.branch] = 1.0;

    var stream = try freq.Stream.init(scratch, &fs, ckt, ctx.x_op, omegas, rhs, false);
    defer stream.deinit(scratch);
    while (try stream.next(ckt)) |pt| {
        const row = data[pt.k * row_len ..][0..row_len];
        row[0] = freqs[pt.k];
        row[1] = 0;
        for (0..n_ports) |p| writeColumn(n, ports, pt.x[p * nn ..][0..nn], row[2..], p);
    }

    if (opts.lin) |lin| try linColumns(ctx, &fs, ports, omegas, rhs, data, row_len, lin);

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

/// Complex entries of S, Y, Z and (two or more ports) H, in that order.
fn paramCount(n_ports: usize) usize {
    return 3 * n_ports * n_ports + @as(usize, if (n_ports >= 2) 4 else 0);
}

/// Columns `run` publishes for `n_ports` ports, the frequency included.
pub fn columns(n_ports: usize, lin: ?Lin) usize {
    const l = lin orelse return 1 + n_ports * n_ports;
    const m = paramCount(n_ports);
    return 1 + m * (1 + @as(usize, @intFromBool(l.group_delay))) + if (l.noise and n_ports >= 2) noise_names.len else 0;
}

/// The two-port noise columns, in order.
const noise_names = [_][]const u8{ "NFMIN", "NF", "RN", "YOPT", "GAMMA_OPT" };

/// `.lin` column names: `frequency`, then `X(i,j)` for X = S, Y, Z, H
/// (H over ports 1-2), then the group delays `TD(X(i,j))` in seconds
/// (HSPICE probes them as `X(i,j)(TD)`) and the two-port noise parameters
/// (`noise_names`) when asked. Real quantities have a zero imaginary part.
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
    if (noisy) @memcpy(names[at..], &noise_names);
    return names;
}

/// Fills every `.lin` column after S from the S block of each row: Y, Z, H;
/// then the group delays (a forward sweep at ω(1 ± gd_step)); then the
/// noise parameters (an adjoint sweep with one right-hand side per port).
/// `fs` holds the port terminations and `rhs` the unit port drives.
fn linColumns(ctx: *const root.RunCtx, fs: *FreqSolver, ports: []const Port, omegas: []const f64, rhs: []const f64, data: []f64, row_len: usize, lin: Lin) !void {
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const nn = 2 * n;
    const np = ports.len;
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
        params(ports, lo, tmp);
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
            const side = if (pt.k % 2 == 0) lo else hi;
            readComplex(s_row, side[0 .. np * np]);
            params(ports, side, tmp);
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

    if (lin.noise and np >= 2) {
        const srcs = try ckt.collectNoiseSources(ctx.x_op, scratch);
        defer scratch.free(srcs);
        // Adjoint of each of the first two port voltages v(node) − v(neg).
        const e = try scratch.alloc(f64, 2 * nn);
        defer scratch.free(e);
        root.zeroSimd(e);
        for (ports[0..2], 0..) |port, i| {
            if (port.node != root.GROUND) e[i * nn + port.node] = 1.0;
            if (port.neg != root.GROUND) e[i * nn + port.neg] = -1.0;
        }
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
            for (srcs) |src| {
                const psd = noise.sourcePsd(src, f);
                const y1 = nodeV(pt.x[0..nn], n, src.node_p).sub(nodeV(pt.x[0..nn], n, src.node_n));
                const y2 = nodeV(pt.x[nn..], n, src.node_p).sub(nodeV(pt.x[nn..], n, src.node_n));
                c11 += psd * y1.magSq();
                c22 += psd * y2.magSq();
                c12 = c12.add(y2.mul(.{ .re = y1.re, .im = -y1.im }).scale(psd));
            }
            readComplex(row[2..][0 .. 2 * np * np], lo[0 .. np * np]);
            const s2 = [4]Complex{ lo[0], lo[1], lo[np], lo[np + 1] };
            const out = noiseParams(s2, .{ ports[0].z0, ports[1].z0 }, .{ c11, c22 }, c12);
            for (out, 0..) |v, i| {
                row[2 * (col + i)] = v.re;
                row[2 * (col + i) + 1] = v.im;
            }
        }
    }
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

/// Given S in `p[0..n²]` (row-major), fills Y, Z and H after it
/// (`paramCount` entries). With F = diag(√z0):
///   Y = F⁻¹ (E + S)⁻¹ (E − S) F⁻¹,   Z = F (E − S)⁻¹ (E + S) F,
/// and H over ports 1-2 comes from the Z of the 2x2 S block (the other
/// ports terminated in z0, as HSPICE defines it). A singular E ± S (an
/// open or a short port) gives non-finite entries. `tmp` holds n² values.
fn params(ports: []const Port, p: []Complex, tmp: []Complex) void {
    const n = ports.len;
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
            const f = @sqrt(ports[i].z0 * ports[j].z0);
            out[i * n + j] = out[i * n + j].scale(if (which == 0) 1 / f else f);
        };
    }
    if (n < 2) return;
    // Z of the port 1-2 block: (E − S₂)⁻¹ (E + S₂), scaled as above.
    var l2 = [4]Complex{ .{ .re = 1 - s[0].re, .im = -s[0].im }, s[1].scale(-1), s[n].scale(-1), .{ .re = 1 - s[n + 1].re, .im = -s[n + 1].im } };
    var z2 = [4]Complex{ .{ .re = 1 + s[0].re, .im = s[0].im }, s[1], s[n], .{ .re = 1 + s[n + 1].re, .im = s[n + 1].im } };
    solveDense(2, &l2, &z2);
    for (0..2) |i| for (0..2) |j| {
        z2[i * 2 + j] = z2[i * 2 + j].scale(@sqrt(ports[i].z0 * ports[j].z0));
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
