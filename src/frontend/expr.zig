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
    /// A name no scope defines. Final ops: a = 1 for `l`, `w`, `mult`,
    /// 2 for `time`, 3 for `temper`, 0 otherwise.
    ident,
    /// A swept global parameter kept symbolic: a indexes the live table
    /// (`fold`'s `live`). Only netlist.zig `subst` emits it.
    live,
    /// `v(p[,n])`: a, b are the nets (names before `subst`), `none` if absent.
    vprobe,
    /// `i(device)`: a is the device name (a name before `subst`, its
    /// flattened `Netlist.pool` index after).
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

/// Built-in functions; `other` is any name the table does not know. The
/// statistical distributions `agauss`, `gauss`, `unif`, `aunif` and HSPICE's
/// `limit(nom, var)` fold to their nominal, the first argument; a Monte Carlo
/// trial draws them instead (`eval`). `table(x, d, x1, y1, ...)` is the
/// smoothed transfer of an E/G TABLE or PWL(1) card, built only by the
/// B-source tape (models/bsource.va opcode 37).
pub const Fn = enum(u8) { sqrt, abs, min, max, pow, exp, ln, log, log10, sin, cos, tan, atan, floor, ceil, ternary, tanh, agauss, gauss, unif, aunif, limit, table, other };

/// True for the functions a Monte Carlo trial draws.
pub fn isDistribution(f: Fn) bool {
    return switch (f) {
        .agauss, .gauss, .unif, .aunif, .limit => true,
        else => false,
    };
}

const fns = std.StaticStringMap(Fn).initComptime(.{
    .{ "sqrt", .sqrt },   .{ "abs", .abs },       .{ "min", .min },     .{ "max", .max },
    .{ "pow", .pow },     .{ "exp", .exp },       .{ "ln", .ln },       .{ "log", .log },
    .{ "log10", .log10 }, .{ "sin", .sin },       .{ "cos", .cos },     .{ "tan", .tan },
    .{ "atan", .atan },   .{ "floor", .floor },   .{ "ceil", .ceil },   .{ "ternary", .ternary },
    .{ "tanh", .tanh },   .{ "agauss", .agauss }, .{ "gauss", .gauss }, .{ "unif", .unif },
    .{ "aunif", .aunif }, .{ "limit", .limit },   .{ "table", .table },
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

    /// The current table lengths, for a later `reset`.
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
/// bind below power. Nesting deeper than `max_depth` is a ParseError.
/// Invalidates slices of `s`'s tables, which grow in `gpa`.
pub fn compile(comptime parseNum: fn ([]const u8) ?f64, gpa: std.mem.Allocator, s: *Scratch, text: []const u8, pos: usize) Error!usize {
    var p: Compiler(parseNum) = .{ .text = text, .pos = pos, .gpa = gpa, .s = s };
    try p.bin(0);
    return p.pos;
}

/// `compile` over the whole of `text`; trailing input is a ParseError.
/// Invalidates slices of `s`'s tables, which grow in `gpa`.
pub fn compileAll(comptime parseNum: fn ([]const u8) ?f64, gpa: std.mem.Allocator, s: *Scratch, text: []const u8) Error!void {
    var p: Compiler(parseNum) = .{ .text = text, .gpa = gpa, .s = s };
    try p.bin(0);
    if (p.peek() != null) return error.ParseError;
}

/// Recursion bound of `compile`, in parser calls: a level of parentheses,
/// quotes, call arguments or ternary branch costs two, a unary operator one
/// or two. Deeper input is a ParseError rather than a stack overflow.
pub const max_depth = 512;

fn Compiler(comptime parseNum: fn ([]const u8) ?f64) type {
    return struct {
        text: []const u8,
        pos: usize = 0,
        gpa: std.mem.Allocator,
        s: *Scratch,
        depth: u16 = 0,

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
            if (p.depth == max_depth) return error.ParseError;
            p.depth += 1;
            defer p.depth -= 1;
            try p.unary();
            while (true) {
                const c = p.peek() orelse break;
                if (c == '?' and min_prec == 0) {
                    p.pos += 1;
                    try p.bin(0);
                    if (p.peek() != ':') return error.ParseError;
                    p.pos += 1;
                    try p.bin(0);
                    try p.emit(.{ .code = .call, .a = @backingInt(Fn.ternary), .b = 3 });
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

        // Every recursion passes through `bin` or `unary`, so the guard in
        // both bounds them all.
        fn unary(p: *P) Error!void {
            if (p.depth == max_depth) return error.ParseError;
            p.depth += 1;
            defer p.depth -= 1;
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
            try p.emit(.{ .code = .call, .a = @backingInt(fns.get(word) orelse .other), .b = argc });
        }
    };
}

/// Length of the number literal `text` starts with: digits and dots, an
/// exponent, then a letter suffix (`2.5e-3`, `10meg`). `E` is an exponent
/// too, as `lines.zig` reads it, for Spectre's case-kept text.
pub fn numberLen(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (std.ascii.isDigit(ch) or ch == '.') continue;
        if ((ch == 'e' or ch == 'E') and i + 1 < text.len and
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
/// (`l`, `w`, `mult`) and distributions (`agauss(...)`) whose nominal did not fold, combined by
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

/// Folds final ops (after `subst`) to a value; `stack` is reused scratch
/// in `gpa`. `geometry` lets model-card `l`/`w`/`mult` vanish behind a zero
/// switch; `live` holds the current value of each `.live` operand. Asserts
/// `ops` is one complete postfix expression, as `compile` emits.
pub fn fold(gpa: std.mem.Allocator, stack: *std.ArrayList(Val), ops: []const Op, consts: []const f64, geometry: bool, live: []const f64) Error!Val {
    stack.clearRetainingCapacity();
    // Every op pushes at most one value: one reserve, no per-op growth check.
    try stack.ensureTotalCapacity(gpa, ops.len);
    for (ops) |op| step(stack, op, consts, geometry, live);
    return stack.pop().?;
}

/// Applies one postfix op to the value stack, which has room for its push.
fn step(stack: *std.ArrayList(Val), op: Op, consts: []const f64, geometry: bool, live: []const f64) void {
    const v: Val = switch (op.code) {
        .num => .of(consts[op.a]),
        .live => .of(live[op.a]),
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
            const result = call(@fromBackingInt(@intCast(op.a)), args);
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
    stack.appendAssumeCapacity(v);
}

fn call(f: Fn, args: []const Val) Val {
    var all_nominal = true;
    var all_known = true;
    for (args) |a| {
        all_nominal = all_nominal and a.isNominal();
        all_known = all_known and a.known;
    }
    const want: usize = switch (f) {
        .tanh, .table, .other => return .unknown(false),
        // ponytail: nominal only; Monte Carlo sampling (C3) draws here.
        .agauss, .gauss, .unif, .aunif => return if (args.len >= 2 and args.len <= 4 and args[0].known) args[0] else .unknown(args.len >= 2 and all_nominal),
        .limit => return if (args.len == 2 and args[0].known) args[0] else .unknown(false),
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
        .ternary, .tanh, .agauss, .gauss, .unif, .aunif, .limit, .table, .other => unreachable,
    });
}

/// Operands an op pops.
pub fn arity(op: Op) u32 {
    return switch (op.code) {
        .num, .ident, .live, .vprobe, .iprobe => 0,
        .neg, .not => 1,
        .call => op.b,
        else => 2,
    };
}

/// First op of the subtree whose root is `ops[end]`. O(subtree size).
/// Asserts `ops[0..end + 1]` holds that whole subtree.
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

/// Evaluates ops that fold to a number: constants, `.live` operands and
/// arithmetic, as `fold` would, except that the distribution call ending at
/// op `i` returns `draw.value(i, f, args)` when `draw` is not null. `stack`
/// is reused scratch in `gpa`. Ops `fold` leaves unknown evaluate to NaN.
/// Asserts `ops` is one complete postfix expression.
pub fn eval(gpa: std.mem.Allocator, stack: *std.ArrayList(Val), ops: []const Op, consts: []const f64, live: []const f64, draw: anytype) Error!f64 {
    stack.clearRetainingCapacity();
    try stack.ensureTotalCapacity(gpa, ops.len);
    for (ops, 0..) |op, i| {
        if (op.code == .call and @TypeOf(draw) != @TypeOf(null) and isDistribution(@fromBackingInt(@intCast(op.a)))) {
            const argc: usize = op.b;
            var nums: [4]f64 = @splat(0);
            const args = stack.items[stack.items.len - argc ..];
            for (args, 0..) |a, k| if (k < nums.len) {
                nums[k] = if (a.known) a.num else std.math.nan(f64);
            };
            stack.shrinkRetainingCapacity(stack.items.len - argc);
            stack.appendAssumeCapacity(.of(draw.value(i, @fromBackingInt(@intCast(op.a)), nums[0..@min(argc, nums.len)])));
            continue;
        }
        step(stack, op, consts, false, live);
    }
    const top = stack.pop().?;
    return if (top.known) top.num else std.math.nan(f64);
}

const test_num = @import("lines.zig").ngspice.parseNum;

fn testFold(a: std.mem.Allocator, text: []const u8) !Val {
    var s: Scratch = .{};
    try compileAll(test_num, a, &s, text);
    var stack: std.ArrayList(Val) = .empty;
    return fold(a, &stack, s.ops.items, s.consts.items, false, &.{});
}

test "compile and fold: precedence, associativity and calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, f64 };
    for ([_]Case{
        .{ "1+2*3", 1 + 2 * 3 },   .{ "(1+2)*3", (1 + 2) * 3 },    .{ "7-2-1", 7 - 2 - 1 },
        .{ "10/4", 10.0 / 4.0 },   .{ "2^3^2", 64 },               .{ "2**3", 8 },
        .{ "-2^2", -4 },           .{ "2^-1", 0.5 },               .{ "+3", 3 },
        .{ "1<2", 1 },             .{ "2<=1", 0 },                 .{ "1>=1", 1 },
        .{ "3>2", 1 },             .{ "1==1", 1 },                 .{ "1!=1", 0 },
        .{ "1&&0", 0 },            .{ "1||0", 1 },                 .{ "!0", 1 },
        .{ "!3", 0 },              .{ "1?2:3", 2 },                .{ "0?2:3", 3 },
        .{ "1+1?4:5", 4 },         .{ "'1+2'*2", 6 },              .{ "\"2\"", 2 },
        .{ "sqrt(16)", 4 },        .{ "max(1,min(5,3))", 3 },      .{ "pow(2,10)", 1024 },
        .{ "abs(-3)", 3 },         .{ "floor(2.5)+ceil(2.5)", 5 }, .{ "1k*2", 2000 },
        .{ "agauss(1,0.1,3)", 1 }, .{ "limit(2,1)", 2 },           .{ "1e-3*2", 2e-3 },
    }) |case| {
        const v = try testFold(a, case[0]);
        try std.testing.expect(v.known);
        try std.testing.expectEqual(case[1], v.num);
    }
    // Names, probes, unknown functions and wrong arities stay symbolic.
    for ([_][]const u8{ "x+1", "v(a)", "i(v1)*2", "foo(1)", "sqrt()", "min(1)", "tanh(0)", "agauss(1)" }) |text|
        try std.testing.expect(!(try testFold(a, text)).known);
    for ([_][]const u8{ "", "1+", "(1", "1)", "a=b", "a|b", "a&b", "1 2", "1?2", "f(1,", "#", "'1" }) |text| {
        var s: Scratch = .{};
        try std.testing.expectError(error.ParseError, compileAll(test_num, a, &s, text));
    }
    // `compile` stops at the first byte that cannot continue the expression.
    var s: Scratch = .{};
    try std.testing.expectEqual(6, try compile(test_num, a, &s, "x 1+2 y", 2));
}

test "compile bounds its recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 100_000;
    for ([_][3]u8{ .{ '(', '1', ')' }, .{ '-', '1', ' ' }, .{ '!', '1', ' ' } }) |shape| {
        const text = try a.alloc(u8, 2 * n + 1);
        @memset(text[0..n], shape[0]);
        text[n] = shape[1];
        @memset(text[n + 1 ..], shape[2]);
        var s: Scratch = .{};
        try std.testing.expectError(error.ParseError, compileAll(test_num, a, &s, text));
    }
    // `1?1:1?1:...1` is valid but recurses through `bin` alone.
    var chain: std.ArrayList(u8) = .empty;
    for (0..n) |_| try chain.appendSlice(a, "1?1:");
    try chain.appendSlice(a, "1");
    var s: Scratch = .{};
    try std.testing.expectError(error.ParseError, compileAll(test_num, a, &s, chain.items));
    // Realistic nesting still compiles.
    try std.testing.expectEqual(1, (try testFold(a, "((((((((((((((((1))))))))))))))))")).num);
}

test "a zero multiplier erases only nominal unknowns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stack: std.ArrayList(Val) = .empty;
    // `0*w` with w declared geometry (ident a = 1), and `0*x` for any other name.
    const geometry = [_]Op{ .{ .code = .num }, .{ .code = .ident, .a = 1 }, .{ .code = .mul } };
    const other = [_]Op{ .{ .code = .num }, .{ .code = .ident, .a = 0 }, .{ .code = .mul } };
    try std.testing.expectEqual(Val.of(0), try fold(a, &stack, &geometry, &.{0}, true, &.{}));
    try std.testing.expect(!(try fold(a, &stack, &geometry, &.{0}, false, &.{})).known);
    try std.testing.expect(!(try fold(a, &stack, &other, &.{0}, true, &.{})).known);
    // `0*agauss(w, 1, 1)`: the distribution of a nominal unknown is nominal.
    const dist = [_]Op{
        .{ .code = .num },                                       .{ .code = .ident, .a = 1 },
        .{ .code = .num, .a = 1 },                               .{ .code = .num, .a = 1 },
        .{ .code = .call, .a = @backingInt(Fn.agauss), .b = 3 }, .{ .code = .mul },
    };
    try std.testing.expectEqual(Val.of(0), try fold(a, &stack, &dist, &.{ 0, 1 }, true, &.{}));
    // `0*(1/0 + w)`: an infinite term is not nominal, so the zero keeps it.
    const inf_ops = [_]Op{ .{ .code = .num }, .{ .code = .num, .a = 1 }, .{ .code = .div }, .{ .code = .ident, .a = 1 }, .{ .code = .add }, .{ .code = .num, .a = 1 }, .{ .code = .mul } };
    try std.testing.expect(!(try fold(a, &stack, &inf_ops, &.{ 1, 0 }, true, &.{})).known);
}

test eval {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stack: std.ArrayList(Val) = .empty;
    var s: Scratch = .{};
    try compileAll(test_num, a, &s, "agauss(1,2,3)+1");
    try std.testing.expectEqual(2, try eval(a, &stack, s.ops.items, s.consts.items, &.{}, null));
    const Draw = struct {
        fn value(_: @This(), i: usize, f: Fn, args: []const f64) f64 {
            std.debug.assert(i == 3 and f == .agauss and args.len == 3);
            return 41;
        }
    };
    try std.testing.expectEqual(42, try eval(a, &stack, s.ops.items, s.consts.items, &.{}, Draw{}));
    const live = [_]Op{ .{ .code = .live }, .{ .code = .num }, .{ .code = .add } };
    try std.testing.expectEqual(5, try eval(a, &stack, &live, &.{3}, &.{2}, null));
    s = .{};
    try compileAll(test_num, a, &s, "x+1");
    try std.testing.expect(std.math.isNan(try eval(a, &stack, s.ops.items, s.consts.items, &.{}, null)));
}

test "postfix subtrees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s: Scratch = .{};
    try compileAll(test_num, arena.allocator(), &s, "1+2*3");
    const ops = s.ops.items; // 1 2 3 mul add
    try std.testing.expectEqual(5, ops.len);
    try std.testing.expectEqual(0, subtreeStart(ops, 4));
    try std.testing.expectEqual(1, subtreeStart(ops, 3));
    try std.testing.expectEqual(2, subtreeStart(ops, 2));
    var buf: [4]usize = undefined;
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, operands(ops, 4, &buf));
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, operands(ops, 3, &buf));
    try std.testing.expectEqualSlices(usize, &.{0}, operands(ops, 4, buf[0..1]));
    // Probes keep their arguments as names; `1n` stays a node, not 1e-9.
    s = .{};
    try compileAll(test_num, arena.allocator(), &s, "v(1n,2)+i(vdd)");
    try std.testing.expectEqual(Code.vprobe, s.ops.items[0].code);
    try std.testing.expectEqualStrings("1n", s.names.items[s.ops.items[0].a]);
    try std.testing.expectEqualStrings("vdd", s.names.items[s.ops.items[1].a]);
    s = .{};
    try compileAll(test_num, arena.allocator(), &s, "v(out)");
    try std.testing.expectEqual(none, s.ops.items[0].b);
}

test numberLen {
    try std.testing.expectEqual(7, numberLen("2.5e-3k+1"));
    try std.testing.expectEqual(5, numberLen("10meg)"));
    try std.testing.expectEqual(2, numberLen("1e+"));
    try std.testing.expectEqual(3, numberLen("1e5"));
    try std.testing.expectEqual(3, numberLen("1E5"));
    try std.testing.expectEqual(0, numberLen(""));
    try std.testing.expect(isOperator('+') and isOperator('?') and !isOperator(')') and !isOperator(','));
}
