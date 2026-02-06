//! Smoke test of the load-bearing claims in this reference against the pinned
//! compiler. Run: `zig run ref/SIMD-Strategies/verify.zig -O ReleaseFast -mcpu=native`
//! ponytail: spot-check, not a full differential test. The full discipline is T8.
const std = @import("std");
const builtin = @import("builtin");
const simd = std.simd;
const assert = std.debug.assert;

const V16 = @Vector(16, u8);

extern fn @"llvm.x86.ssse3.pshuf.b.128"(V16, V16) V16;
extern fn @"llvm.aarch64.neon.tbl1"(V16, V16) V16;
extern fn @"llvm.x86.pclmulqdq"(@Vector(2, u64), @Vector(2, u64), i8) @Vector(2, u64);

const has_ssse3 = builtin.cpu.arch.isX86() and
    std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3);
const has_pclmul = builtin.cpu.arch.isX86() and
    std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul);

/// out[i] = tbl[idx[i] & 15]. One instruction on x86 SSSE3 and on aarch64.
inline fn lookup16(tbl: V16, idx: V16) V16 {
    const lo = idx & @as(V16, @splat(0x0F));
    if (comptime has_ssse3) return @"llvm.x86.ssse3.pshuf.b.128"(tbl, lo);
    if (comptime builtin.cpu.arch == .aarch64) return @"llvm.aarch64.neon.tbl1"(tbl, lo);
    return lookup16Scalar(tbl, lo);
}

/// Portable oracle. Keep it even after shipping the intrinsic (T8 step 5).
fn lookup16Scalar(tbl: V16, idx: V16) V16 {
    const t: [16]u8 = tbl;
    const i: [16]u8 = idx;
    var out: [16]u8 = undefined;
    for (&out, i) |*o, x| o.* = t[x & 0x0F];
    return out;
}

fn prefixXorScalar(x: u64) u64 {
    var acc: u64 = 0;
    var run: u64 = 0;
    for (0..64) |b| {
        run ^= (x >> @intCast(b)) & 1;
        acc |= run << @intCast(b);
    }
    return acc;
}

fn maskEq(block: *const [64]u8, needle: u8) u64 {
    const V = @Vector(64, u8);
    const v: V = block.*;
    return @bitCast(v == @as(V, @splat(needle)));
}

// ZZVM P2 lexer kernel — LLVM identifier class [-a-zA-Z$._0-9] classification.
// Mirror of src/lex.zig (kept self-contained so this file runs standalone).
// T1 classify + T2 mask + @ctz to the first non-identifier byte.
const V16z = @Vector(16, u8);

fn isIdentScalar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '-' or c == '$' or c == '.' or c == '_';
}

fn vAnd(a: @Vector(16, bool), b: @Vector(16, bool)) @Vector(16, bool) {
    const ai: @Vector(16, u1) = @bitCast(a);
    const bi: @Vector(16, u1) = @bitCast(b);
    return @bitCast(ai & bi);
}
fn vOr(a: @Vector(16, bool), b: @Vector(16, bool)) @Vector(16, bool) {
    const ai: @Vector(16, u1) = @bitCast(a);
    const bi: @Vector(16, u1) = @bitCast(b);
    return @bitCast(ai | bi);
}
fn identEndVec(src: []const u8, start: usize) usize {
    var i = start;
    while (i + 16 <= src.len) : (i += 16) {
        const v: V16z = src[i..][0..16].*;
        const az = vAnd(v >= @as(V16z, @splat('a')), v <= @as(V16z, @splat('z')));
        const AZ = vAnd(v >= @as(V16z, @splat('A')), v <= @as(V16z, @splat('Z')));
        const num = vAnd(v >= @as(V16z, @splat('0')), v <= @as(V16z, @splat('9')));
        const sym = vOr(vOr(v == @as(V16z, @splat('-')), v == @as(V16z, @splat('$'))), vOr(v == @as(V16z, @splat('.')), v == @as(V16z, @splat('_'))));
        const in_class: u16 = @bitCast(vOr(vOr(az, AZ), vOr(num, sym)));
        const stop = ~in_class;
        if (stop != 0) return i + @ctz(stop);
    }
    while (i < src.len and isIdentScalar(src[i])) : (i += 1) {}
    return i;
}
fn identEndScalar(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and isIdentScalar(src[i])) : (i += 1) {}
    return i;
}

// ZZVM P5 regalloc — liveness dataflow transfer over u64 word bitsets:
//   live_in = use | (live_out & ~def)
// SIMD over 512-bit (u64 x 8) blocks with a change accumulator, scalar tail.
// Mirrors src/regalloc.zig transfer/transferScalar (the real kernel of the
// backward liveness fixpoint feeding linear-scan register allocation).
const LW = 8;
const LVec = @Vector(LW, u64);
fn transferVec(dst: []u64, use: []const u64, out: []const u64, def: []const u64) bool {
    var changed: u64 = 0;
    var i: usize = 0;
    while (i + LW <= dst.len) : (i += LW) {
        const u: LVec = use[i..][0..LW].*;
        const o: LVec = out[i..][0..LW].*;
        const d: LVec = def[i..][0..LW].*;
        const new = u | (o & ~d);
        const old: LVec = dst[i..][0..LW].*;
        changed |= @reduce(.Or, new ^ old);
        dst[i..][0..LW].* = new;
    }
    while (i < dst.len) : (i += 1) {
        const new = use[i] | (out[i] & ~def[i]);
        changed |= new ^ dst[i];
        dst[i] = new;
    }
    return changed != 0;
}
fn transferOracle(dst: []u64, use: []const u64, out: []const u64, def: []const u64) bool {
    var changed = false;
    for (dst, use, out, def) |*d, u, o, df| {
        const new = u | (o & ~df);
        if (new != d.*) changed = true;
        d.* = new;
    }
    return changed;
}

pub fn main() void {
    // T1 — runtime 16-way table lookup, intrinsic vs scalar oracle, 50k pairs.
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    for (0..50_000) |_| {
        var tbl: [16]u8 = undefined;
        var idx: [16]u8 = undefined;
        rand.bytes(&tbl);
        rand.bytes(&idx);
        const got: [16]u8 = lookup16(tbl, idx);
        const want: [16]u8 = lookup16Scalar(tbl, idx);
        assert(std.mem.eql(u8, &got, &want));
    }

    // T1 — nibble classification: lo_class & hi_class.
    {
        const lo_tbl: V16 = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0 };
        const hi_tbl: V16 = .{ 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        const bytes: V16 = @splat(0x20); // hi=2, lo=0
        const cls: [16]u8 = lookup16(lo_tbl, bytes) & lookup16(hi_tbl, bytes >> @splat(4));
        assert(cls[0] == (1 & 3));
    }

    // T2 — @Vector(64,u8) compare bitcasts to a u64 mask; lane 0 is the low bit.
    {
        var block: [64]u8 = @splat('.');
        block[0] = 'x';
        block[5] = 'x';
        block[63] = 'x';
        const m = maskEq(&block, 'x');
        assert(m == (1 | (1 << 5) | (1 << 63)));
        assert(@ctz(m) == 0);
        assert(63 - @clz(m) == 63);
        assert(@popCount(m) == 3);
        assert((m & (m -% 1)) == ((1 << 5) | (1 << 63)));
    }

    // T2 — run boundaries.
    {
        const m: u64 = 0b0111_0000;
        assert(m & ~(m << 1) == 0b0001_0000); // run start
        assert(m & ~(m >> 1) == 0b0100_0000); // run end
    }

    // T3 — mergeShift is alignr: real bytes from the previous block.
    {
        const prev: @Vector(4, u8) = .{ 1, 2, 3, 4 };
        const cur: @Vector(4, u8) = .{ 5, 6, 7, 8 };
        assert(@reduce(.And, simd.mergeShift(prev, cur, 3) == @Vector(4, u8){ 4, 5, 6, 7 }));
        assert(@reduce(.And, simd.mergeShift(prev, cur, 2) == @Vector(4, u8){ 3, 4, 5, 6 }));
    }

    // T4 — saturating subtract as a threshold test on UTF-8 lead bytes.
    {
        const lead: @Vector(4, u8) = .{ 0x41, 0xC3, 0xE2, 0xF0 };
        const hit = lead -| @as(@Vector(4, u8), @splat(0xDF));
        assert(@reduce(.And, hit == @Vector(4, u8){ 0, 0, 3, 17 }));
    }

    // T5 — carry propagation finds odd-length backslash-run ends.
    {
        const B: u64 = 0b1110;
        const starts = B & ~(B << 1);
        const odd_starts = starts & 0xAAAA_AAAA_AAAA_AAAA;
        const carries = B +% odd_starts;
        assert((carries ^ B) == 0b1_0000);
    }

    // T5 — prefix XOR via clmul vs scalar, 100k inputs.
    if (comptime has_pclmul) {
        for (0..100_000) |_| {
            const x = rand.int(u64);
            const v: @Vector(2, u64) = .{ x, 0 };
            const ones: @Vector(2, u64) = .{ ~@as(u64, 0), 0 };
            assert(@"llvm.x86.pclmulqdq"(v, ones, 0)[0] == prefixXorScalar(x));
        }
    }

    // T5 — lane-wise cousin.
    {
        const p = simd.prefixScan(.Add, 1, simd.iota(u8, 8));
        assert(@reduce(.And, p == @Vector(8, u8){ 0, 1, 3, 6, 10, 15, 21, 28 }));
    }

    // Gotcha 3 — the two "rights" point in opposite directions.
    {
        const v: @Vector(4, u8) = .{ 10, 20, 30, 40 };
        assert(@reduce(.And, simd.shiftElementsRight(v, 1, 99) == @Vector(4, u8){ 99, 10, 20, 30 }));
        assert(@reduce(.And, simd.shiftElementsLeft(v, 1, 99) == @Vector(4, u8){ 20, 30, 40, 99 }));
    }

    // ZZVM P2 — identifier-class classify: vector kernel vs scalar oracle, 50k
    // random buffers, runs deliberately crossing 16-byte block boundaries.
    {
        var buf: [200]u8 = undefined;
        const idc = "abcXYZ._-$0129";
        for (0..50_000) |_| {
            for (&buf) |*b| {
                const r = rand.int(u8);
                b.* = switch (r % 5) {
                    0 => ' ',
                    1 => '(',
                    else => idc[r % idc.len],
                };
            }
            const start = rand.uintLessThan(usize, 180);
            assert(identEndVec(&buf, start) == identEndScalar(&buf, start));
        }
    }

    // ZZVM P3 — verifier operand-bounds batch: the branchless vector predicate
    // `bad(x) = x != none AND x < arg_base AND x >= ninsts` over a flat u32 word
    // stream, vector kernel vs scalar oracle, 50k random buffers with the trip
    // deliberately placed at 16-lane block boundaries. This is the core of
    // src/verify.zig's operandBoundsBatchSimd, reduced to stand alone (the real
    // kernel scans the ir.Func `data` column, which is this same u32 stream).
    {
        const ARG_BASE: u32 = 1 << 30; // ir.Value.arg_base
        const NONE: u32 = ~@as(u32, 0);
        var words: [256]u32 = undefined;
        for (0..50_000) |_| {
            const ninsts = rand.intRangeAtMost(u32, 1, 120);
            const nwords = ninsts * 2;
            // Fill with a mix: valid inst refs, args, none, and out-of-range refs.
            for (words[0..nwords]) |*w| {
                w.* = switch (rand.intRangeAtMost(u8, 0, 9)) {
                    0 => NONE,
                    1 => ARG_BASE + rand.int(u16), // arg partition
                    2 => ninsts + rand.intRangeAtMost(u32, 0, 100), // out of range
                    else => if (ninsts == 0) 0 else rand.uintLessThan(u32, ninsts),
                };
            }
            assert(boundsFirstBadVec(words[0..nwords], ninsts, ARG_BASE, NONE) ==
                boundsFirstBadScalar(words[0..nwords], ninsts, ARG_BASE, NONE));
        }
    }

    // ZZVM P5 — liveness dataflow transfer: SIMD kernel vs scalar oracle, word
    // counts straddling the 8-word (512-bit) block boundary, 20k trials each.
    {
        var use: [40]u64 = undefined;
        var out: [40]u64 = undefined;
        var def: [40]u64 = undefined;
        var av: [40]u64 = undefined;
        var bv: [40]u64 = undefined;
        for ([_]usize{ 1, 7, 8, 9, 15, 16, 33, 40 }) |wlen| {
            for (0..20_000) |_| {
                for (0..wlen) |k| {
                    use[k] = rand.int(u64);
                    out[k] = rand.int(u64);
                    def[k] = rand.int(u64);
                    const seed = rand.int(u64);
                    av[k] = seed;
                    bv[k] = seed;
                }
                const c1 = transferVec(av[0..wlen], use[0..wlen], out[0..wlen], def[0..wlen]);
                const c2 = transferOracle(bv[0..wlen], use[0..wlen], out[0..wlen], def[0..wlen]);
                assert(c1 == c2);
                assert(std.mem.eql(u64, av[0..wlen], bv[0..wlen]));
            }
        }
    }

    // ZZVM P6 — def-use CSR counting kernel (src/opt/analysis.zig): count, per def,
    // how many operands reference it (histogram into row_start[def+1]) + total
    // inst->inst edges. SIMD mask + scalar histogram scatter. Operand counts
    // straddling the 16-lane block boundary, 20k trials each.
    {
        for ([_]u32{ 1, 15, 16, 17, 33, 100, 257, 1000 }) |n| {
            for (0..20_000) |_| {
                const nops = n * 2 + 3;
                var op_vals: [2003]u32 = undefined;
                for (op_vals[0..nops]) |*o| {
                    o.* = switch (rand.intRangeAtMost(u8, 0, 3)) {
                        0 => rand.intRangeLessThan(u32, 0, @max(n, 1)),
                        1 => (1 << 30) + rand.intRangeAtMost(u32, 0, 5), // arg partition
                        2 => std.math.maxInt(u32), // none
                        else => rand.intRangeAtMost(u32, 0, n * 4),
                    };
                }
                var rs_k: [2002]u32 = undefined;
                var rs_o: [2002]u32 = undefined;
                @memset(rs_k[0 .. n + 1], 0);
                @memset(rs_o[0 .. n + 1], 0);
                const tk = countUsesVec(op_vals[0..nops], n, rs_k[0 .. n + 1]);
                const to = countUsesScalar(op_vals[0..nops], n, rs_o[0 .. n + 1]);
                assert(tk == to);
                assert(std.mem.eql(u32, rs_k[0 .. n + 1], rs_o[0 .. n + 1]));
            }
        }
    }

    // Phase 4 LaneLu(W) — W sparse-LU factorizations replaying one SparseLu
    // pivot tape, values as []@Vector(W,f64). Its differential case (vector lane
    // l vs scalar SparseLu replay of lane l, on +/-5% perturbed matrices incl.
    // an MNA zero-diagonal pattern and a singular-lane/mask case) lives IN
    // src/solvers/lane_lu.zig test blocks, not here: this file runs standalone
    // via `zig run` and cannot import the solvers module (SparseLu, the oracle).
    // Run it under `zig build test-solvers`.

    // SparseLu.refactor stays SCALAR — measured, not assumed. The active-set
    // -local u16 replay tape (dense front, vector zero/normalize, run-split
    // vector axpy variants) was bit-identical to the scalar oracle but lost
    // 19% wall end-to-end: the per-flop tape streams with zero reuse (2.8x L2
    // read traffic) while global-coordinate li/lx column reads stay
    // D1-resident. Rerunnable rig: src/solvers/dev_harness.zig on a
    // ZP_LU_DUMP capture (differential-checks every variant vs lu.refactor,
    // bit-identical, before racing them). Full evidence:
    // docs/solvers/refactor-tape-2026-09.md.

    std.debug.print("ok — zig {f}, ssse3={}, pclmul={}\n", .{
        builtin.zig_version, has_ssse3, has_pclmul,
    });
}

/// Scalar oracle for the def-use CSR counting kernel (src/opt/analysis.zig
/// countUsesScalar). arg_base = 1<<30 partitions inst results from args/consts;
/// an operand is an in-range inst result iff raw < arg_base and raw < n.
fn countUsesScalar(op_vals: []const u32, n: u32, row_start: []u32) u32 {
    const arg_base: u32 = 1 << 30;
    var total: u32 = 0;
    for (op_vals) |raw| {
        if (raw < arg_base and raw < n) {
            row_start[raw + 1] += 1;
            total += 1;
        }
    }
    return total;
}

/// Vector kernel (mirror of src/opt/analysis.zig countUsesKernel): the in-range
/// inst-result predicate is two lane-wise range compares; the reduction (total
/// edges) is a horizontal add of the mask; the histogram scatter is scalar over
/// the set lanes (a scatter to arbitrary indices is not a lane op). 16 u32 lanes
/// per block; scalar tail = the oracle body.
fn countUsesVec(op_vals: []const u32, n: u32, row_start: []u32) u32 {
    const arg_base: u32 = 1 << 30;
    const lanes = 16;
    const V = @Vector(lanes, u32);
    var total: u32 = 0;
    const arg_v: V = @splat(arg_base);
    const n_v: V = @splat(n);
    var i: usize = 0;
    while (i + lanes <= op_vals.len) : (i += lanes) {
        const wv: V = op_vals[i..][0..lanes].*;
        const mask = (wv < arg_v) & (wv < n_v);
        const ones: V = @select(u32, mask, @as(V, @splat(1)), @as(V, @splat(0)));
        total += @reduce(.Add, ones);
        inline for (0..lanes) |lane| {
            if (mask[lane]) row_start[wv[lane] + 1] += 1;
        }
    }
    while (i < op_vals.len) : (i += 1) {
        if (op_vals[i] < arg_base and op_vals[i] < n) {
            row_start[op_vals[i] + 1] += 1;
            total += 1;
        }
    }
    return total;
}

/// Scalar oracle for the verifier operand-bounds batch (src/verify.zig). Returns
/// the index of the first out-of-range word, or null. Kept as the ground truth.
fn boundsFirstBadScalar(words: []const u32, ninsts: u32, arg_base: u32, none: u32) ?usize {
    for (words, 0..) |w, i| {
        if (w != none and w < arg_base and w >= ninsts) return i;
    }
    return null;
}

/// Vector kernel: the same branchless compare src/verify.zig runs (accumulate a
/// per-block OR, locate on trip). 16 u32 lanes per block; scalar tail.
fn boundsFirstBadVec(words: []const u32, ninsts: u32, arg_base: u32, none: u32) ?usize {
    const lanes = 16;
    const V = @Vector(lanes, u32);
    const arg_v: V = @splat(arg_base);
    const none_v: V = @splat(none);
    const n_v: V = @splat(ninsts);
    var i: usize = 0;
    while (i + lanes <= words.len) : (i += lanes) {
        const wv: V = words[i..][0..lanes].*;
        const bad = (wv != none_v) & (wv < arg_v) & (wv >= n_v);
        if (@reduce(.Or, bad)) {
            var k: usize = i;
            while (k < i + lanes) : (k += 1) {
                if (words[k] != none and words[k] < arg_base and words[k] >= ninsts) return k;
            }
        }
    }
    while (i < words.len) : (i += 1) {
        if (words[i] != none and words[i] < arg_base and words[i] >= ninsts) return i;
    }
    return null;
}
