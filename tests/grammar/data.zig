//! The data-file grammars' oracles: a file's grammar tree -> the reading the
//! frontend's own reader returns, written from the spec, not from the
//! reader. Touchstone (touchstone.peg) lowers to `sparam.Raw`, an RLGC
//! file (rlgc.peg) to `wfit.RlgcFile`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const wfit = @import("wfit");
const sparam = wfit.sparam;
const peg = @import("peg.zig");

/// Why the oracle refuses a file the grammar accepts: a record or noise
/// rule outside the PEG (dev/research/data-file-syntax.md §1, "Constraints
/// outside the PEG").
pub const Error = error{ OutOfMemory, Refused };

/// The Touchstone reading of `t`: the first option line's settings over
/// the defaults (`GHz S MA R 50`, TS1.1 p.5), then the value stream cut
/// into 1 + 2N² records while frequencies ascend, and what follows checked
/// as a 2-port noise block (TS1.1 p.10-11).
pub fn touchstone(arena: Allocator, g: peg.Grammar, t: peg.Tree, ports: usize) Error!sparam.Raw {
    const r = .{
        .option = g.rule("Option"),
        .unit = g.rule("Unit"),
        .param = g.rule("Param"),
        .format = g.rule("Format"),
        .ref = g.rule("Ref"),
        .num = g.rule("Num"),
    };
    var raw: sparam.Raw = .{ .values = &.{}, .nf = 0 };
    var nums: std.ArrayList(f64) = .empty;
    var roots = t.children(null);
    const file = roots.next() orelse return error.Refused;
    var it = t.children(file);
    while (it.next()) |c| {
        const rule = t.rows[c].rule;
        if (rule == r.num) {
            try nums.append(arena, std.fmt.parseFloat(f64, t.text(c)) catch return error.Refused);
        } else if (rule == r.option) {
            var o = t.children(c);
            while (o.next()) |tok| {
                const k = t.rows[tok].rule;
                var buf: [3]u8 = undefined;
                const text = t.text(tok);
                if (k == r.unit) {
                    raw.unit = switch (std.ascii.toLower(text[0])) {
                        'g' => 1e9,
                        'm' => 1e6,
                        'k' => 1e3,
                        else => 1,
                    };
                } else if (k == r.param) {
                    raw.kind = std.ascii.toLower(text[0]);
                } else if (k == r.format) {
                    const f = std.ascii.lowerString(&buf, text[0..2]);
                    raw.format = std.meta.stringToEnum(sparam.Raw.Format, f).?;
                } else if (k == r.ref) {
                    var n = t.children(tok);
                    raw.z0 = std.fmt.parseFloat(f64, t.text(n.next().?)) catch return error.Refused;
                }
            }
        }
    }
    // R is a real, positive number (TS2.0 p.6).
    if (!(raw.z0 > 0) or !std.math.isFinite(raw.z0)) return error.Refused;
    const stride = 1 + 2 * ports * ports;
    const all = nums.items;
    var nf: usize = 0;
    while ((nf + 1) * stride <= all.len) : (nf += 1) {
        if (nf > 0 and !(all[nf * stride] > all[(nf - 1) * stride])) break;
    }
    if (nf == 0) return error.Refused;
    const tail = all[nf * stride ..];
    if (tail.len > 0) {
        if (ports != 2 or tail.len % 5 != 0) return error.Refused;
        if (!(tail[0] <= all[(nf - 1) * stride])) return error.Refused;
        var k: usize = 5;
        while (k < tail.len) : (k += 5) if (!(tail[k] > tail[k - 5])) return error.Refused;
    }
    raw.values = all[0 .. nf * stride];
    raw.nf = nf;
    return raw;
}

/// True when two readings agree on every setting and value.
pub fn sameRaw(a: sparam.Raw, b: sparam.Raw) bool {
    if (a.unit != b.unit or a.kind != b.kind or a.format != b.format or a.z0 != b.z0 or a.nf != b.nf) return false;
    return std.mem.eql(f64, a.values, b.values);
}

/// The RLGC reading of `t`: N first, then whole lower triangles, L and C
/// required and at most six (SI Table 4, p.107). N past `wfit.max_n` is
/// ESPice's limit, reported apart.
pub fn rlgc(g: peg.Grammar, t: peg.Tree) (Error || wfit.RlgcError)!wfit.RlgcFile {
    const num = g.rule("Num");
    var nums: [1 + 6 * 10]f64 = undefined;
    var count: usize = 0;
    var roots = t.children(null);
    var it = t.children(roots.next() orelse return error.Refused);
    while (it.next()) |c| {
        if (t.rows[c].rule != num) continue;
        if (count == nums.len) return error.Refused;
        nums[count] = std.fmt.parseFloat(f64, t.text(c)) catch return error.Refused;
        count += 1;
    }
    if (count == 0 or !(nums[0] >= 1) or @floor(nums[0]) != nums[0]) return error.Refused;
    if (nums[0] > wfit.max_n) return error.TooManyConductors;
    const n: usize = @intFromFloat(nums[0]);
    const tri = n * (n + 1) / 2;
    if ((count - 1) % tri != 0) return error.Refused;
    const mats = (count - 1) / tri;
    if (mats < 2 or mats > 6) return error.Refused;
    var file: wfit.RlgcFile = .{ .n = n, .mats = mats };
    for (0..mats) |k| @memcpy(file.tri[k][0..tri], nums[1 + k * tri ..][0..tri]);
    return file;
}
