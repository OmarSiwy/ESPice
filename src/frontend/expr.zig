//! Expressions as flat postfix: compile from text, fold on a value stack.
//! `compile` emits syntax only, names and probe arguments as indices into
//! `Scratch.names`; netlist.zig `subst` splices parameters in and maps probe
//! nets. No tree is built: a consumer walks subtrees backwards from their
//! last op (`subtreeStart`).
const std = @import("std");

/// `ParseError`: malformed expression text.
pub const Error = error{ OutOfMemory, ParseError };
/// Absent operand.
pub const none = std.math.maxInt(u32);

/// Postfix opcode; `a`/`b` operands as noted, none for the operators.
pub const Code = enum(u8) {
    /// a: constant pool index.
    num,
    /// A name no scope defines. Final ops: a = 1 for `l`, `w`, `mult`.
    ident,
    /// `v(p[,n])`: a, b are the nets (names before `subst`), `none` if absent.
    vprobe,
    /// `i(device)`; the device is not kept.
    iprobe,
    neg,
    not,
    add,
    sub,
    mul,
    div,
    pow,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    @"and",
    @"or",
    /// a: `Fn`, b: argument count.
    call,
};

/// Built-in functions; `other` is any name the table does not know.
pub const Fn = enum(u8) { sqrt, abs, min, max, pow, exp, ln, log, log10, sin, cos, tan, atan, floor, ceil, ternary, tanh, agauss, other };

const fns = std.StaticStringMap(Fn).initComptime(.{
    .{ "sqrt", .sqrt },   .{ "abs", .abs },       .{ "min", .min },      .{ "max", .max },
    .{ "pow", .pow },     .{ "exp", .exp },       .{ "ln", .ln },        .{ "log", .log },
    .{ "log10", .log10 }, .{ "sin", .sin },       .{ "cos", .cos },      .{ "tan", .tan },
    .{ "atan", .atan },   .{ "floor", .floor },   .{ "ceil", .ceil },    .{ "ternary", .ternary },
    .{ "tanh", .tanh },   .{ "agauss", .agauss }, .{ "gauss", .agauss },
});

/// One postfix op.
pub const Op = struct { code: Code, a: u32 = 0, b: u32 = 0 };

/// Compile output before parameters are spliced in.
pub const Scratch = struct {
    ops: std.ArrayList(Op) = .empty,
    consts: std.ArrayList(f64) = .empty,
    names: std.ArrayList([]const u8) = .empty,

    /// Table lengths to roll back to.
    pub const Mark = struct { ops: usize, consts: usize, names: usize };

    pub fn mark(s: Scratch) Mark {
        return .{ .ops = s.ops.items.len, .consts = s.consts.items.len, .names = s.names.items.len };
    }

    /// Drops everything appended since `m`.
    pub fn reset(s: *Scratch, m: Mark) void {
        s.ops.shrinkRetainingCapacity(m.ops);
        s.consts.shrinkRetainingCapacity(m.consts);
        s.names.shrinkRetainingCapacity(m.names);
    }
};

/// Compiles the expression starting at `text[pos]` into `s` and returns
/// where it ends. Grammar: ternary `?:` loosest, then `||`, `&&`,
/// comparisons, `+ -`, `* /`, `^`/`**` (all left associative); unary `-`/`+`
/// bind below power.
pub fn compile(comptime parseNum: fn ([]const u8) ?f64, gpa: std.mem.Allocator, s: *Scratch, text: []const u8, pos: usize) Error!usize {
    var p: Compiler(parseNum) = .{ .text = text, .pos = pos, .gpa = gpa, .s = s };
    try p.bin(0);
    return p.pos;
}

/// `compile` over the whole of `text`; trailing input is a ParseError.
pub fn compileAll(comptime parseNum: fn ([]const u8) ?f64, gpa: std.mem.Allocator, s: *Scratch, text: []const u8) Error!void {
    var p: Compiler(parseNum) = .{ .text = text, .gpa = gpa, .s = s };
    try p.bin(0);
    if (p.peek() != null) return error.ParseError;
}

fn Compiler(comptime parseNum: fn ([]const u8) ?f64) type {
    return struct {
        text: []const u8,
        pos: usize = 0,
        gpa: std.mem.Allocator,
        s: *Scratch,

        const P = @This();

        fn peek(p: *P) ?u8 {
            while (p.pos < p.text.len and (p.text[p.pos] == ' ' or p.text[p.pos] == '\t')) p.pos += 1;
            return if (p.pos < p.text.len) p.text[p.pos] else null;
        }

        fn emit(p: *P, op: Op) Error!void {
            try p.s.ops.append(p.gpa, op);
        }

        fn name(p: *P, n: []const u8) Error!u32 {
            try p.s.names.append(p.gpa, n);
            return @intCast(p.s.names.items.len - 1);
        }

        fn bin(p: *P, min_prec: u8) Error!void {
            try p.unary();
            while (true) {
                const c = p.peek() orelse break;
                if (c == '?' and min_prec == 0) {
                    p.pos += 1;
                    try p.bin(0);
                    if (p.peek() != ':') return error.ParseError;
                    p.pos += 1;
                    try p.bin(0);
                    try p.emit(.{ .code = .call, .a = @intFromEnum(Fn.ternary), .b = 3 });
                    continue;
                }
                const power = c == '*' and p.pos + 1 < p.text.len and p.text[p.pos + 1] == '*';
                const prec: u8 = switch (c) {
                    '|' => 1,
                    '&' => 2,
                    '<', '>', '=', '!' => 3,
                    '+', '-' => 4,
                    '*', '/' => if (power) 6 else 5,
                    '^' => 6,
                    else => break,
                };
                if (prec < min_prec) break;
                p.pos += 1;
                var code: Code = switch (c) {
                    '|' => .@"or",
                    '&' => .@"and",
                    '<' => .lt,
                    '>' => .gt,
                    '=' => .eq,
                    '!' => .ne,
                    '+' => .add,
                    '-' => .sub,
                    '*' => if (power) .pow else .mul,
                    '/' => .div,
                    else => .pow,
                };
                if (p.pos < p.text.len) {
                    const next = p.text[p.pos];
                    if (power) p.pos += 1;
                    if (next == '=' and (c == '<' or c == '>' or c == '=' or c == '!')) {
                        if (c == '<') code = .le;
                        if (c == '>') code = .ge;
                        p.pos += 1;
                    } else if (c == '=' or c == '!') return error.ParseError;
                    if (c == '&' or c == '|') {
                        if (next != c) return error.ParseError;
                        p.pos += 1;
                    }
                }
                try p.bin(prec + 1);
                try p.emit(.{ .code = code });
            }
        }

        fn unary(p: *P) Error!void {
            const c = p.peek() orelse return error.ParseError;
            switch (c) {
                '-' => {
                    p.pos += 1;
                    try p.bin(6);
                    try p.emit(.{ .code = .neg });
                },
                '+' => {
                    p.pos += 1;
                    try p.bin(6);
                },
                '!' => {
                    p.pos += 1;
                    try p.unary();
                    try p.emit(.{ .code = .not });
                },
                else => try p.atom(),
            }
        }

        /// A probe argument: up to `,` `)` or a blank, kept as a name (node
        /// `10` is a node, and a node `1n` must not read as 1e-9).
        fn nodeArg(p: *P) Error![]const u8 {
            _ = p.peek();
            const start = p.pos;
            while (p.pos < p.text.len) : (p.pos += 1) {
                const ch = p.text[p.pos];
                if (ch == ',' or ch == ')' or ch == ' ' or ch == '\t') break;
            }
            if (p.pos == start) return error.ParseError;
            return p.text[start..p.pos];
        }

        fn atom(p: *P) Error!void {
            const c = p.peek() orelse return error.ParseError;
            if (c == '"' or c == '\'' or c == '(') {
                p.pos += 1;
                try p.bin(0);
                if (p.peek() != if (c == '(') ')' else c) return error.ParseError;
                p.pos += 1;
                return;
            }
            if (std.ascii.isDigit(c) or c == '.') {
                const start = p.pos;
                p.pos += numberLen(p.text[start..]);
                const n = parseNum(p.text[start..p.pos]) orelse return error.ParseError;
                try p.s.consts.append(p.gpa, n);
                return p.emit(.{ .code = .num, .a = @intCast(p.s.consts.items.len - 1) });
            }
            if (!std.ascii.isAlphabetic(c) and c != '_') return error.ParseError;
            const start = p.pos;
            while (p.pos < p.text.len) : (p.pos += 1) {
                const ch = p.text[p.pos];
                if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.')) break;
            }
            const word = p.text[start..p.pos];
            if (p.peek() != '(') return p.emit(.{ .code = .ident, .a = try p.name(word) });
            p.pos += 1;
            const probe: ?Code = if (word.len != 1) null else switch (word[0]) {
                'v', 'V' => .vprobe,
                'i', 'I' => .iprobe,
                else => null,
            };
            var args: [2]u32 = .{ none, none };
            var argc: u32 = 0;
            if (p.peek() != ')') while (true) {
                if (probe != null) {
                    const node = try p.nodeArg();
                    if (argc < 2) args[argc] = try p.name(node);
                } else try p.bin(0);
                argc += 1;
                if ((p.peek() orelse return error.ParseError) != ',') break;
                p.pos += 1;
            };
            if (p.peek() != ')') return error.ParseError;
            p.pos += 1;
            if (probe) |code| return p.emit(.{ .code = code, .a = args[0], .b = args[1] });
            try p.emit(.{ .code = .call, .a = @intFromEnum(fns.get(word) orelse .other), .b = argc });
        }
    };
}

/// Length of the number literal `text` starts with: digits and dots, an
/// exponent, then a letter suffix (`2.5e-3`, `10meg`).
pub fn numberLen(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (std.ascii.isDigit(ch) or ch == '.') continue;
        if (ch == 'e' and i + 1 < text.len and
            (std.ascii.isDigit(text[i + 1]) or
                ((text[i + 1] == '-' or text[i + 1] == '+') and i + 2 < text.len and std.ascii.isDigit(text[i + 2]))))
        {
            i += 1;
            if (text[i] == '+' or text[i] == '-') i += 1;
            continue;
        }
        break;
    }
    while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
    return i;
}

/// A byte that continues an expression after an operand.
pub fn isOperator(c: u8) bool {
    return switch (c) {
        '|', '&', '<', '>', '=', '!', '+', '-', '*', '/', '^', '?' => true,
        else => false,
    };
}

/// A folded value. `nominal` records, for an unknown value, whether a zero
/// multiplier may still erase it: finite constants, declared model geometry
/// (`l`, `w`, `mult`) and well-formed `agauss`/`gauss` draws, combined by
/// arithmetic and math calls (the nominal PDK corner `0*agauss(...)`).
pub const Val = struct {
    num: f64 = 0,
    known: bool,
    nominal: bool = false,

    fn isNominal(v: Val) bool {
        return if (v.known) std.math.isFinite(v.num) else v.nominal;
    }

    fn unknown(nominal: bool) Val {
        return .{ .known = false, .nominal = nominal };
    }

    fn of(n: f64) Val {
        return .{ .num = n, .known = true };
    }
};

fn bool01(b: bool) f64 {
    return @floatFromInt(@intFromBool(b));
}

/// Folds final ops (after `subst`) to a value; `stack` is reused scratch.
/// `geometry` lets model-card `l`/`w`/`mult` vanish behind a zero switch.
pub fn fold(gpa: std.mem.Allocator, stack: *std.ArrayList(Val), ops: []const Op, consts: []const f64, geometry: bool) Error!Val {
    stack.clearRetainingCapacity();
    for (ops) |op| {
        const v: Val = switch (op.code) {
            .num => .of(consts[op.a]),
            .ident => .unknown(geometry and op.a == 1),
            .vprobe, .iprobe => .unknown(false),
            .neg, .not => blk: {
                const x = stack.pop().?;
                if (!x.known) break :blk .unknown(x.isNominal());
                break :blk .of(if (op.code == .neg) -x.num else bool01(x.num == 0));
            },
            .call => blk: {
                const argc: usize = op.b;
                const args = stack.items[stack.items.len - argc ..];
                const result = call(@enumFromInt(op.a), args);
                stack.shrinkRetainingCapacity(stack.items.len - argc);
                break :blk result;
            },
            else => blk: {
                const b = stack.pop().?;
                const a = stack.pop().?;
                if (op.code == .mul and ((a.known and a.num == 0 and !b.known and b.nominal) or
                    (b.known and b.num == 0 and !a.known and a.nominal))) break :blk .of(0);
                if (!a.known or !b.known) break :blk .unknown(a.isNominal() and b.isNominal());
                const x = a.num;
                const y = b.num;
                break :blk .of(switch (op.code) {
                    .add => x + y,
                    .sub => x - y,
                    .mul => x * y,
                    .div => x / y,
                    .pow => std.math.pow(f64, x, y),
                    .lt => bool01(x < y),
                    .gt => bool01(x > y),
                    .le => bool01(x <= y),
                    .ge => bool01(x >= y),
                    .eq => bool01(x == y),
                    .ne => bool01(x != y),
                    .@"and" => bool01(x != 0 and y != 0),
                    .@"or" => bool01(x != 0 or y != 0),
                    else => unreachable,
                });
            },
        };
        try stack.append(gpa, v);
    }
    return stack.pop().?;
}

fn call(f: Fn, args: []const Val) Val {
    var all_nominal = true;
    var all_known = true;
    for (args) |a| {
        all_nominal = all_nominal and a.isNominal();
        all_known = all_known and a.known;
    }
    const want: usize = switch (f) {
        .tanh, .other => return .unknown(false),
        .agauss => return .unknown(args.len == 3 and all_known and all_nominal),
        .ternary => 3,
        .pow, .min, .max => 2,
        else => 1,
    };
    if (args.len != want or !args[0].known) return .unknown(all_nominal);
    const a = args[0].num;
    if (f == .ternary) {
        const picked = args[if (a != 0) 1 else 2];
        return if (picked.known) picked else .unknown(all_nominal);
    }
    if (want == 2 and !args[1].known) return .unknown(all_nominal);
    const b = if (want == 2) args[1].num else 0;
    return .of(switch (f) {
        .sqrt => @sqrt(a),
        .abs => @abs(a),
        .min => @min(a, b),
        .max => @max(a, b),
        .pow => std.math.pow(f64, a, b),
        .exp => @exp(a),
        .ln, .log => @log(a),
        .log10 => @log10(a),
        .sin => @sin(a),
        .cos => @cos(a),
        .tan => @tan(a),
        .atan => std.math.atan(a),
        .floor => @floor(a),
        .ceil => @ceil(a),
        .ternary, .tanh, .agauss, .other => unreachable,
    });
}

/// Operands an op pops.
pub fn arity(op: Op) u32 {
    return switch (op.code) {
        .num, .ident, .vprobe, .iprobe => 0,
        .neg, .not => 1,
        .call => op.b,
        else => 2,
    };
}

/// First op of the subtree whose root is `ops[end]`.
pub fn subtreeStart(ops: []const Op, end: usize) usize {
    var need: u32 = 1;
    var i = end;
    while (true) : (i -= 1) {
        need = need - 1 + arity(ops[i]);
        if (need == 0) return i;
    }
}

/// Last op of each operand of `ops[end]`, left to right.
pub fn operands(ops: []const Op, end: usize, out: []usize) []usize {
    const n = arity(ops[end]);
    var i: usize = n;
    var last = end;
    while (i > 0) {
        i -= 1;
        last -= 1;
        if (i < out.len) out[i] = last;
        last = subtreeStart(ops, last);
    }
    return out[0..@min(n, out.len)];
}
