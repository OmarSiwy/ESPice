const std = @import("std");
const Allocator = std.mem.Allocator;
const Buf = @import("emit").Buf;
const Ast = @import("Ast.zig");
const Token = @import("Token.zig");
const Lexer = @import("Lexer.zig");
const Tag = Token.Tag;

const Parser = @This();

/// One SoA expression node: 9 bytes across three columns.
const ExprNode = struct { tag: Ast.ExprTag, lhs: u32, rhs: u32 };

source: []const u8,
/// SoA token storage — peek() touches only the tag column.
tokens: Lexer.TokenList,
pos: u32 = 0,
allocator: Allocator,
errors: Buf(Error) = .empty,
stmt_pool: Buf(Ast.Stmt) = .empty,
has_unclosed_comment: bool,

/// SoA expression storage — one MultiArrayList; its columns are handed out
/// as separate slices in the SourceFile.
exprs: std.MultiArrayList(ExprNode) = .empty,
extra: Buf(u32) = .empty,
str_refs: Buf([]const u8) = .empty,

pub const Error = struct {
    msg: []const u8,
    token_pos: u32,
};

pub fn init(allocator: Allocator, source: []const u8) !Parser {
    const result = try Lexer.tokenize(allocator, source);
    const token_count = result.tokens.len;
    // Pre-size pools — ~1 expr per 2 tokens, ~1 stmt per 8 tokens.
    var p = Parser{
        .source = source,
        .tokens = result.tokens,
        .has_unclosed_comment = result.has_unclosed_comment,
        .allocator = allocator,
    };
    try p.exprs.ensureTotalCapacity(allocator, token_count / 2);
    try p.extra.ensureTotalCapacity(allocator, token_count / 4);
    try p.str_refs.ensureTotalCapacity(allocator, token_count / 8);
    try p.stmt_pool.ensureTotalCapacity(allocator, token_count / 8);
    return p;
}

pub fn deinit(self: *Parser) void {
    self.tokens.deinit(self.allocator);
    self.errors.deinit(self.allocator);
    self.stmt_pool.deinit(self.allocator);
    self.exprs.deinit(self.allocator);
    self.extra.deinit(self.allocator);
    self.str_refs.deinit(self.allocator);
}

// ── Arena helpers ────────────────────────────────────────────────────

fn addStmt(self: *Parser, stmt: Ast.Stmt) !Ast.StmtId {
    const idx: u32 = self.stmt_pool.len;
    try self.stmt_pool.append(self.allocator, stmt);
    return @enumFromInt(idx);
}

// ── SoA expression helpers ──────────────────────────────────────────

fn addExprNode(self: *Parser, tag: Ast.ExprTag, lhs: u32, rhs: u32) Allocator.Error!Ast.ExprId {
    const idx: u32 = @intCast(self.exprs.len);
    try self.exprs.append(self.allocator, .{ .tag = tag, .lhs = lhs, .rhs = rhs });
    return @enumFromInt(idx);
}

/// Id of the most recently emitted expression node.
fn lastExpr(self: *const Parser) Ast.ExprId {
    return @enumFromInt(@as(u32, @intCast(self.exprs.len - 1)));
}

fn addStr(self: *Parser, s: []const u8) !u32 {
    const idx: u32 = self.str_refs.len;
    try self.str_refs.append(self.allocator, s);
    return idx;
}

fn addExtra(self: *Parser, vals: []const u32) !u32 {
    const idx: u32 = self.extra.len;
    try self.extra.appendSlice(self.allocator, vals);
    return idx;
}

fn binaryOpToTag(op: Ast.BinaryOp) Ast.ExprTag {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .modulo => .modulo,
        .power => .power,
        .eq => .eq,
        .neq => .neq,
        .lt => .lt,
        .gt => .gt,
        .lte => .lte,
        .gte => .gte,
        .logic_and => .logic_and,
        .logic_or => .logic_or,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .bit_nxor => .bit_nxor,
        .shl => .shl,
        .shr => .shr,
        .ashl => .ashl,
        .ashr => .ashr,
    };
}

fn unaryOpToTag(op: Ast.UnaryOp) Ast.ExprTag {
    return switch (op) {
        .negate => .negate,
        .bit_not => .bit_not,
        .logic_not => .logic_not,
        .plus => .u_plus,
    };
}

/// Emit a literal_int into the SoA arrays.
fn emitExprInt(self: *Parser, val: i64) !void {
    if (val >= std.math.minInt(i32) and val <= std.math.maxInt(i32)) {
        _ = try self.addExprNode(.literal_int_small, @bitCast(@as(i32, @intCast(val))), 0);
    } else {
        const bits: u64 = @bitCast(val);
        const lo: u32 = @truncate(bits);
        const hi: u32 = @truncate(bits >> 32);
        const ei = try self.addExtra(&.{ lo, hi });
        _ = try self.addExprNode(.literal_int_large, ei, 0);
    }
}

/// Emit a literal_real into the SoA arrays.
fn emitExprReal(self: *Parser, val: f64) !void {
    const bits: u64 = @bitCast(val);
    const lo: u32 = @truncate(bits);
    const hi: u32 = @truncate(bits >> 32);
    const ei = try self.addExtra(&.{ lo, hi });
    _ = try self.addExprNode(.literal_real, ei, 0);
}

/// Emit a func_call / system_call / nature_access into the SoA arrays.
fn emitExprCallLike(self: *Parser, tag: Ast.ExprTag, name: []const u8, args: []const Ast.ExprId) !void {
    const si = try self.addStr(name);
    const arg_count: u32 = @intCast(args.len);
    // extra layout: [arg_count, arg0, arg1, ...]
    try self.extra.ensureTotalCapacity(self.allocator, self.extra.len + 1 + args.len);
    const ei: u32 = self.extra.len;
    self.extra.appendAssumeCapacity(arg_count);
    for (args) |a| {
        self.extra.appendAssumeCapacity(@intFromEnum(a));
    }
    _ = try self.addExprNode(tag, si, ei);
}

// ── Token access (SoA: peek only touches tag array) ──────────────────

fn peek(self: *const Parser) Tag {
    if (self.pos >= self.tokens.len) return .eof;
    return self.tokens.items(.tag)[self.pos];
}

fn peekAhead(self: *const Parser, offset: u32) Tag {
    const idx = self.pos + offset;
    if (idx >= self.tokens.len) return .eof;
    return self.tokens.items(.tag)[idx];
}

fn advance(self: *Parser) u32 {
    const idx = self.pos;
    if (self.pos < self.tokens.len) self.pos += 1;
    return idx;
}

fn expect(self: *Parser, tag: Tag) !u32 {
    if (self.peek() != tag) {
        try self.emitError(@tagName(tag));
        return error.ParseError;
    }
    return self.advance();
}

fn eat(self: *Parser, tag: Tag) bool {
    if (self.peek() == tag) {
        _ = self.advance();
        return true;
    }
    return false;
}

pub fn tokenText(self: *const Parser, idx: u32) []const u8 {
    if (idx >= self.tokens.len) return "";
    const start = self.tokens.items(.start)[idx];
    return self.source[start..Lexer.tokenEnd(self.source, start)];
}

fn peekText(self: *const Parser) []const u8 {
    return self.tokenText(self.pos);
}

fn emitError(self: *Parser, expected: []const u8) !void {
    try self.errors.append(self.allocator, .{
        .msg = expected,
        .token_pos = self.pos,
    });
}

fn isIdent(self: *const Parser) bool {
    const t = self.peek();
    return t == .identifier or t == .escaped_identifier;
}

fn expectIdent(self: *Parser) !u32 {
    if (self.isIdent()) return self.advance();
    try self.emitError("identifier");
    return error.ParseError;
}

fn expectIdentOrKeyword(self: *Parser) !u32 {
    const t = self.peek();
    if (t == .identifier or t == .escaped_identifier or
        (@intFromEnum(t) >= @intFromEnum(Tag.kw_module) and @intFromEnum(t) < @intFromEnum(Tag.semicolon)))
    {
        return self.advance();
    }
    try self.emitError("identifier");
    return error.ParseError;
}

/// Compute line:col from a source offset for error reporting.
pub fn sourceLocation(self: *const Parser, token_pos: u32) struct { line: u32, col: u32, line_start: u32, line_end: u32 } {
    const offset: u32 = if (token_pos < self.tokens.len)
        self.tokens.items(.start)[token_pos]
    else
        @intCast(self.source.len);

    var line: u32 = 1;
    var col: u32 = 1;
    var line_start: u32 = 0;
    for (self.source[0..@min(offset, @as(u32, @intCast(self.source.len)))], 0..) |ch, i| {
        if (ch == '\n') {
            line += 1;
            col = 1;
            line_start = @intCast(i + 1);
        } else {
            col += 1;
        }
    }
    var line_end = offset;
    while (line_end < self.source.len and self.source[line_end] != '\n') : (line_end += 1) {}
    return .{ .line = line, .col = col, .line_start = line_start, .line_end = line_end };
}

/// Format a diagnostic string for an error, showing source context.
pub fn formatError(self: *const Parser, err: Error, writer: anytype) !void {
    const loc = self.sourceLocation(err.token_pos);
    const found = if (err.token_pos < self.tokens.len) self.tokenText(err.token_pos) else "EOF";
    try writer.print("{d}:{d}: error: expected {s}, got '{s}'\n", .{ loc.line, loc.col, err.msg, found });
    if (loc.line_start < loc.line_end) {
        try writer.print("  {s}\n", .{self.source[loc.line_start..loc.line_end]});
        try writer.writeByteNTimes(' ', loc.col + 1);
        try writer.writeAll("^\n");
    }
}

// ── Top-level parsing ────────────────────────────────────────────────

pub fn parseSourceFile(self: *Parser) !Ast.SourceFile {
    var modules: Buf(Ast.ModuleDecl) = .empty;
    var disciplines: Buf(Ast.DisciplineDecl) = .empty;
    var natures: Buf(Ast.NatureDecl) = .empty;
    var paramsets: Buf(Ast.ParamsetDecl) = .empty;

    while (self.peek() != .eof) {
        switch (self.peek()) {
            .kw_module => try modules.append(self.allocator, try self.parseModule()),
            .kw_discipline => try disciplines.append(self.allocator, try self.parseDiscipline()),
            .kw_nature => try natures.append(self.allocator, try self.parseNature()),
            .kw_paramset => try paramsets.append(self.allocator, try self.parseParamset()),
            else => _ = self.advance(),
        }
    }

    return .{
        .modules = try modules.toOwnedSlice(self.allocator),
        .disciplines = try disciplines.toOwnedSlice(self.allocator),
        .natures = try natures.toOwnedSlice(self.allocator),
        .paramsets = try paramsets.toOwnedSlice(self.allocator),
        .stmts = try self.stmt_pool.toOwnedSlice(self.allocator),
        // Column views into the parser's arena-owned MAL buffer: valid for
        // the arena's lifetime, no copies.
        .expr_tags = self.exprs.items(.tag),
        .expr_lhs = self.exprs.items(.lhs),
        .expr_rhs = self.exprs.items(.rhs),
        .extra_data = try self.extra.toOwnedSlice(self.allocator),
        .str_refs = try self.str_refs.toOwnedSlice(self.allocator),
    };
}

// ── Discipline ───────────────────────────────────────────────────────

fn parseDiscipline(self: *Parser) !Ast.DisciplineDecl {
    _ = try self.expect(.kw_discipline);
    const name_idx = try self.expectIdentOrKeyword();
    // Semicolon optional: pre-LRM inline declarations (EKV) omit it.
    _ = self.eat(.semicolon);

    var attrs: Buf(Ast.DisciplineAttr) = .empty;
    var potential_nature: ?[]const u8 = null;
    var flow_nature: ?[]const u8 = null;
    var domain: ?[]const u8 = null;

    while (self.peek() != .kw_enddiscipline and self.peek() != .eof) {
        if (self.peek() == .kw_potential) {
            _ = self.advance();
            const val_idx = self.advance();
            const val = self.tokenText(val_idx);
            potential_nature = val;
            _ = self.eat(.semicolon);
            try attrs.append(self.allocator, .{ .name = "potential", .value = val });
        } else if (self.peek() == .kw_flow) {
            _ = self.advance();
            const val_idx = self.advance();
            const val = self.tokenText(val_idx);
            flow_nature = val;
            _ = self.eat(.semicolon);
            try attrs.append(self.allocator, .{ .name = "flow", .value = val });
        } else if (self.peek() == .kw_domain) {
            _ = self.advance();
            if (self.eat(.eq)) {
                const val_idx = self.advance();
                domain = self.tokenText(val_idx);
                _ = self.eat(.semicolon);
                try attrs.append(self.allocator, .{ .name = "domain", .value = domain.? });
            } else {
                const val_idx = self.advance();
                domain = self.tokenText(val_idx);
                _ = self.eat(.semicolon);
                try attrs.append(self.allocator, .{ .name = "domain", .value = domain.? });
            }
        } else if (self.peek() == .identifier) {
            const attr_name_idx = self.advance();
            const attr_name = self.tokenText(attr_name_idx);
            if (self.eat(.eq)) {
                const val_idx = self.advance();
                _ = self.eat(.semicolon);
                const val = self.tokenText(val_idx);
                if (std.mem.eql(u8, attr_name, "potential")) {
                    potential_nature = val;
                } else if (std.mem.eql(u8, attr_name, "flow")) {
                    flow_nature = val;
                } else if (std.mem.eql(u8, attr_name, "domain")) {
                    domain = val;
                }
                try attrs.append(self.allocator, .{ .name = attr_name, .value = val });
            } else {
                _ = self.eat(.semicolon);
                try attrs.append(self.allocator, .{ .name = attr_name, .value = "" });
            }
        } else {
            const attr_name = @tagName(self.peek());
            _ = self.advance();
            if (self.peek() == .identifier or self.peek().isKeyword()) {
                const val_idx = self.advance();
                _ = self.eat(.semicolon);
                try attrs.append(self.allocator, .{ .name = attr_name, .value = self.tokenText(val_idx) });
            } else if (self.eat(.eq)) {
                const val_idx = self.advance();
                _ = self.eat(.semicolon);
                try attrs.append(self.allocator, .{ .name = attr_name, .value = self.tokenText(val_idx) });
            } else {
                _ = self.eat(.semicolon);
                try attrs.append(self.allocator, .{ .name = attr_name, .value = "" });
            }
        }
    }
    _ = self.eat(.kw_enddiscipline);

    return .{
        .name = self.tokenText(name_idx),
        .potential_nature = potential_nature,
        .flow_nature = flow_nature,
        .domain = domain,
        .attrs = try attrs.toOwnedSlice(self.allocator),
    };
}

// ── Nature ───────────────────────────────────────────────────────────

fn parseNature(self: *Parser) !Ast.NatureDecl {
    _ = try self.expect(.kw_nature);
    const name_idx = try self.expectIdentOrKeyword();

    var parent: ?[]const u8 = null;
    if (self.eat(.colon)) {
        const p = try self.expectIdentOrKeyword();
        parent = self.tokenText(p);
    }
    // Semicolon optional: pre-LRM inline declarations (EKV) omit it.
    _ = self.eat(.semicolon);

    var attrs: Buf(Ast.NatureAttr) = .empty;
    while (self.peek() != .kw_endnature and self.peek() != .eof) {
        if (self.peek() == .identifier or self.peek().isKeyword()) {
            const attr_name_idx = self.advance();
            _ = try self.expect(.eq);
            const val = try self.parseExpr();
            _ = self.eat(.semicolon);
            try attrs.append(self.allocator, .{ .name = self.tokenText(attr_name_idx), .value = val });
        } else {
            _ = self.advance();
        }
    }
    _ = self.eat(.kw_endnature);

    return .{
        .name = self.tokenText(name_idx),
        .parent = parent,
        .attrs = try attrs.toOwnedSlice(self.allocator),
    };
}

// ── Paramset ────────────────────────────────────────────────────────

fn parseParamset(self: *Parser) !Ast.ParamsetDecl {
    _ = try self.expect(.kw_paramset);
    const name_idx = try self.expectIdent();
    const base_idx = try self.expectIdentOrKeyword();
    _ = try self.expect(.semicolon);

    var params: Buf(Ast.ParamDecl) = .empty;
    while (self.peek() != .kw_endparamset and self.peek() != .eof) {
        if (self.peek() == .kw_parameter or self.peek() == .kw_localparam) {
            try params.append(self.allocator, try self.parseParamDecl(self.peek() == .kw_localparam));
        } else {
            while (self.peek() != .semicolon and self.peek() != .kw_endparamset and self.peek() != .eof) {
                _ = self.advance();
            }
            _ = self.eat(.semicolon);
        }
    }
    _ = self.eat(.kw_endparamset);

    return .{
        .name = self.tokenText(name_idx),
        .base_module = self.tokenText(base_idx),
        .params = try params.toOwnedSlice(self.allocator),
    };
}

// ── Module ───────────────────────────────────────────────────────────

fn parseModule(self: *Parser) !Ast.ModuleDecl {
    _ = try self.expect(.kw_module);
    const name_idx = try self.expectIdent();

    var ports: Buf(Ast.Port) = .empty;
    var items_from_ports: Buf(Ast.ModuleItem) = .empty;
    if (self.eat(.l_paren)) {
        while (self.peek() != .r_paren and self.peek() != .eof) {
            var dir: Ast.Direction = .inout;
            var discipline: ?[]const u8 = null;

            if (self.peek() == .kw_input) { _ = self.advance(); dir = .input; } else if (self.peek() == .kw_output) { _ = self.advance(); dir = .output; } else if (self.peek() == .kw_inout) { _ = self.advance(); dir = .inout; }

            if (self.peek() == .kw_electrical or self.peek() == .kw_thermal) {
                discipline = self.tokenText(self.advance());
            } else if (self.isIdent() and (self.peekAhead(1) == .identifier or self.peekAhead(1) == .escaped_identifier)) {
                discipline = self.tokenText(self.advance());
            }

            const port_name_idx = try self.expectIdent();
            const port_name = self.tokenText(port_name_idx);
            try ports.append(self.allocator, .{ .name = port_name, .direction = dir });

            if (discipline != null) {
                const name_slice = try self.allocator.alloc([]const u8, 1);
                name_slice[0] = port_name;
                try items_from_ports.append(self.allocator, .{ .port_decl = .{
                    .direction = dir,
                    .discipline = discipline,
                    .names = name_slice,
                } });
                try items_from_ports.append(self.allocator, .{ .net_decl = .{
                    .discipline = discipline.?,
                    .names = name_slice,
                } });
            }

            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.r_paren);
    }
    _ = try self.expect(.semicolon);

    var items: Buf(Ast.ModuleItem) = .empty;
    for (items_from_ports.slice()) |item| try items.append(self.allocator, item);
    items_from_ports.deinit(self.allocator);
    while (self.peek() != .kw_endmodule and self.peek() != .eof) {
        // ponytail: handle multi-param declarations inline
        if (self.peek() == .kw_parameter or self.peek() == .kw_localparam) {
            const is_local = self.peek() == .kw_localparam;
            _ = self.advance();
            const ty = self.parseType();
            while (true) {
                const pd = try self.parseSingleParam(ty, is_local);
                try items.append(self.allocator, .{ .param_decl = pd });
                if (!self.eat(.comma)) break;
            }
            _ = self.eat(.semicolon);
            continue;
        }
        if (self.parseModuleItem()) |maybe_item| {
            if (maybe_item) |item| try items.append(self.allocator, item);
        } else |_| {
            while (self.peek() != .semicolon and self.peek() != .kw_endmodule and self.peek() != .kw_end and self.peek() != .eof) {
                _ = self.advance();
            }
            _ = self.eat(.semicolon);
        }
    }
    if (!self.eat(.kw_endmodule)) {
        try self.emitError("endmodule");
    }

    return .{
        .name = self.tokenText(name_idx),
        .ports = try ports.toOwnedSlice(self.allocator),
        .items = try items.toOwnedSlice(self.allocator),
    };
}

fn parseModuleItem(self: *Parser) !?Ast.ModuleItem {
    if (self.peek() == .attr_open) {
        while (self.peek() != .attr_close and self.peek() != .eof) _ = self.advance();
        _ = self.eat(.attr_close);
    }

    switch (self.peek()) {
        .kw_input, .kw_output, .kw_inout => return .{ .port_decl = try self.parsePortDecl() },
        .kw_electrical, .kw_thermal => return .{ .net_decl = try self.parseNetDecl() },
        .kw_ground => {
            _ = self.advance();
            while (self.peek() != .semicolon and self.peek() != .eof) _ = self.advance();
            _ = self.eat(.semicolon);
            return null;
        },
        .kw_branch => return .{ .branch_decl = try self.parseBranchDecl() },
        .kw_parameter => return .{ .param_decl = try self.parseParamDecl(false) },
        .kw_localparam => return .{ .param_decl = try self.parseParamDecl(true) },
        .kw_aliasparam => return .{ .alias_param = try self.parseAliasParam() },
        .kw_real, .kw_integer, .kw_string => return .{ .var_decl = try self.parseVarDecl() },
        .kw_analog => return try self.parseAnalogItem(),
        .kw_function => return .{ .func_decl = try self.parseFuncDecl() },
        .kw_genvar => {
            _ = self.advance();
            while (self.peek() != .semicolon and self.peek() != .eof) _ = self.advance();
            _ = self.eat(.semicolon);
            return null;
        },
        .kw_generate => {
            _ = self.advance();
            var depth: u32 = 1;
            while (depth > 0 and self.peek() != .eof) {
                if (self.peek() == .kw_generate) depth += 1;
                if (self.peek() == .kw_endgenerate) depth -= 1;
                if (depth > 0) _ = self.advance();
            }
            _ = self.eat(.kw_endgenerate);
            return null;
        },
        .identifier, .escaped_identifier => {
            const saved = self.pos;
            const name = self.peekText();
            _ = self.advance();
            if (self.isIdent()) {
                _ = self.advance();
                if (self.peek() == .l_paren or self.peek() == .hash or self.peek() == .dot) {
                    while (self.peek() != .semicolon and self.peek() != .kw_endmodule and self.peek() != .eof) _ = self.advance();
                    _ = self.eat(.semicolon);
                    return null;
                }
                self.pos = saved;
                return .{ .net_decl = try self.parseNetDeclGeneric(name) };
            }
            self.pos = saved;
            _ = self.advance();
            return null;
        },
        else => {
            _ = self.advance();
            return null;
        },
    }
}

fn parseAnalogItem(self: *Parser) !Ast.ModuleItem {
    _ = try self.expect(.kw_analog);

    if (self.peek() == .kw_function) {
        return .{ .func_decl = try self.parseFuncDecl() };
    }

    if (self.peek() == .kw_initial_step or
        (self.peek() == .identifier and std.mem.eql(u8, self.peekText(), "initial")))
    {
        if (self.peek() == .identifier) _ = self.advance();
        const stmt = try self.parseStmt();
        return .{ .analog_initial = .{ .is_initial = true, .stmt = stmt } };
    }

    const stmt = try self.parseStmt();
    return .{ .analog_block = .{ .stmt = stmt } };
}

fn parsePortDecl(self: *Parser) !Ast.PortDecl {
    const dir_idx = self.advance();
    const dir_tag = self.tokens.items(.tag)[dir_idx];
    const direction: Ast.Direction = switch (dir_tag) {
        .kw_input => .input,
        .kw_output => .output,
        .kw_inout => .inout,
        else => unreachable,
    };

    var discipline: ?[]const u8 = null;
    if (self.peek() == .kw_electrical or self.peek() == .kw_thermal) {
        discipline = self.tokenText(self.advance());
    } else if (self.isIdent()) {
        const saved = self.pos;
        const name = self.peekText();
        _ = self.advance();
        if (self.isIdent()) {
            discipline = name;
        } else {
            self.pos = saved;
        }
    }

    var names: Buf([]const u8) = .empty;
    while (true) {
        const n = try self.expectIdent();
        try names.append(self.allocator, self.tokenText(n));
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);

    return .{
        .direction = direction,
        .discipline = discipline,
        .names = try names.toOwnedSlice(self.allocator),
    };
}

fn parseNetDecl(self: *Parser) !Ast.NetDecl {
    const disc_idx = self.advance();
    return self.parseNetDeclGeneric(self.tokenText(disc_idx));
}

fn parseNetDeclGeneric(self: *Parser, discipline: []const u8) !Ast.NetDecl {
    if (self.isIdent() and std.mem.eql(u8, self.peekText(), discipline)) {
        _ = self.advance();
    }

    var names: Buf([]const u8) = .empty;
    while (true) {
        const n = try self.expectIdent();
        try names.append(self.allocator, self.tokenText(n));
        if (self.eat(.l_bracket)) {
            while (self.peek() != .r_bracket and self.peek() != .eof) _ = self.advance();
            _ = self.eat(.r_bracket);
        }
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);

    return .{
        .discipline = discipline,
        .names = try names.toOwnedSlice(self.allocator),
    };
}

fn parseBranchDecl(self: *Parser) !Ast.BranchDecl {
    _ = try self.expect(.kw_branch);
    _ = try self.expect(.l_paren);
    const a = try self.expectIdent();
    var b: ?[]const u8 = null;
    if (self.eat(.comma)) {
        const b_idx = try self.expectIdent();
        b = self.tokenText(b_idx);
    }
    _ = try self.expect(.r_paren);
    const name = try self.expectIdent();
    _ = try self.expect(.semicolon);

    return .{
        .name = self.tokenText(name),
        .node_a = self.tokenText(a),
        .node_b = b,
    };
}

fn parseSingleParam(self: *Parser, ty: Ast.Type, is_local: bool) !Ast.ParamDecl {
    const name_idx = try self.expectIdent();
    // ponytail: skip array dimensions [lo:hi] if present
    if (self.peek() == .l_bracket) {
        while (self.peek() != .r_bracket and self.peek() != .eof) _ = self.advance();
        _ = self.eat(.r_bracket);
    }
    var default: Ast.ExprId = .none;
    if (self.eat(.eq)) {
        default = try self.parseExpr();
    }
    var ranges: Buf(Ast.Range) = .empty;
    while (self.peek() == .kw_from or self.peek() == .kw_exclude) {
        try ranges.append(self.allocator, try self.parseRange());
    }
    return .{
        .is_local = is_local,
        .ty = ty,
        .name = self.tokenText(name_idx),
        .default = default,
        .ranges = try ranges.toOwnedSlice(self.allocator),
    };
}

fn parseParamDecl(self: *Parser, is_local: bool) !Ast.ParamDecl {
    _ = self.advance();
    const ty = self.parseType();
    const pd = try self.parseSingleParam(ty, is_local);
    // ponytail: skip any remaining comma-separated params (consumed by parseModule for module-level)
    while (self.peek() != .semicolon and self.peek() != .eof) _ = self.advance();
    _ = self.eat(.semicolon);
    return pd;
}

fn parseAliasParam(self: *Parser) !Ast.AliasParam {
    _ = try self.expect(.kw_aliasparam);
    const name_idx = try self.expectIdent();
    _ = try self.expect(.eq);
    const target_idx = try self.expectIdent();
    _ = try self.expect(.semicolon);

    return .{
        .name = self.tokenText(name_idx),
        .target = self.tokenText(target_idx),
    };
}

fn parseVarDecl(self: *Parser) !Ast.VarDecl {
    const ty = self.parseType();
    var names: Buf([]const u8) = .empty;
    var inits: Buf(Ast.ExprId) = .empty;

    while (true) {
        const n = try self.expectIdent();
        try names.append(self.allocator, self.tokenText(n));
        if (self.eat(.l_bracket)) {
            while (self.peek() != .r_bracket and self.peek() != .eof) _ = self.advance();
            _ = self.eat(.r_bracket);
        }
        if (self.eat(.eq)) {
            try inits.append(self.allocator, try self.parseExpr());
        } else {
            try inits.append(self.allocator, .none);
        }
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);

    return .{
        .ty = ty,
        .names = try names.toOwnedSlice(self.allocator),
        .init_values = try inits.toOwnedSlice(self.allocator),
    };
}

fn parseFuncDecl(self: *Parser) !Ast.FuncDecl {
    _ = try self.expect(.kw_function);
    const ret = self.parseType();
    const name = try self.expectIdent();
    _ = try self.expect(.semicolon);

    var args: Buf(Ast.FuncArg) = .empty;
    while (self.peek() == .kw_input or self.peek() == .kw_output or self.peek() == .kw_inout) {
        const dir_idx = self.advance();
        const dir_tag = self.tokens.items(.tag)[dir_idx];
        const direction: Ast.Direction = switch (dir_tag) {
            .kw_input => .input,
            .kw_output => .output,
            .kw_inout => .inout,
            else => unreachable,
        };
        const arg_ty = self.parseType();
        while (true) {
            const arg_name = try self.expectIdent();
            try args.append(self.allocator, .{ .direction = direction, .ty = arg_ty, .name = self.tokenText(arg_name) });
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }

    while (self.peek() == .kw_real or self.peek() == .kw_integer or self.peek() == .kw_string) {
        _ = self.advance();
        while (self.peek() != .semicolon and self.peek() != .eof) _ = self.advance();
        _ = self.eat(.semicolon);
    }

    const body = try self.parseStmt();
    _ = try self.expect(.kw_endfunction);

    return .{
        .return_type = ret,
        .name = self.tokenText(name),
        .args = try args.toOwnedSlice(self.allocator),
        .body = body,
    };
}

fn parseType(self: *Parser) Ast.Type {
    switch (self.peek()) {
        .kw_real => { _ = self.advance(); return .real; },
        .kw_integer => { _ = self.advance(); return .integer; },
        .kw_string => { _ = self.advance(); return .string; },
        else => return .real,
    }
}

fn parseRange(self: *Parser) !Ast.Range {
    const kind: @TypeOf(@as(Ast.Range, undefined).kind) = if (self.peek() == .kw_from) blk: {
        _ = self.advance();
        break :blk .from;
    } else blk: {
        _ = try self.expect(.kw_exclude);
        break :blk .exclude;
    };

    if (self.peek() != .l_bracket and self.peek() != .l_paren) {
        const val = try self.parseExpr();
        return .{ .kind = kind, .lo_inclusive = true, .lo = val, .hi = val, .hi_inclusive = true };
    }

    const lo_inclusive = self.peek() == .l_bracket;
    _ = self.advance();
    const lo = try self.parseExpr();
    _ = try self.expect(.colon);
    const hi = try self.parseExpr();
    const hi_inclusive = self.peek() == .r_bracket;
    _ = self.advance();

    return .{ .kind = kind, .lo_inclusive = lo_inclusive, .lo = lo, .hi = hi, .hi_inclusive = hi_inclusive };
}

// ── Statements ───────────────────────────────────────────────────────

fn parseStmt(self: *Parser) error{ ParseError, OutOfMemory }!Ast.StmtId {
    switch (self.peek()) {
        .semicolon => { _ = self.advance(); return self.addStmt(.empty); },
        .kw_begin => return self.parseBlock(),
        .kw_if => return self.parseIf(),
        .kw_while => return self.parseWhile(),
        .kw_for => return self.parseFor(),
        .kw_case => return self.parseCase(),
        .at_sign => return self.parseEventControl(),
        .kw_disable => return self.parseDisable(),
        else => return self.parseExprOrContributeStmt(),
    }
}

fn parseBlock(self: *Parser) !Ast.StmtId {
    _ = try self.expect(.kw_begin);

    var name: ?[]const u8 = null;
    if (self.eat(.colon)) {
        const n = try self.expect(.identifier);
        name = self.tokenText(n);
    }

    var local_vars: Buf(Ast.VarDecl) = .empty;
    var local_params: Buf(Ast.ParamDecl) = .empty;

    while (self.peek() == .kw_real or self.peek() == .kw_integer or self.peek() == .kw_string or
        self.peek() == .kw_parameter or self.peek() == .kw_localparam)
    {
        if (self.peek() == .kw_parameter or self.peek() == .kw_localparam) {
            try local_params.append(self.allocator, try self.parseParamDecl(self.peek() == .kw_localparam));
        } else {
            try local_vars.append(self.allocator, try self.parseVarDecl());
        }
    }

    var stmts: Buf(Ast.StmtId) = .empty;
    while (self.peek() != .kw_end and self.peek() != .eof) {
        const stmt = self.parseStmt() catch {
            while (self.peek() != .semicolon and self.peek() != .kw_end and self.peek() != .eof) _ = self.advance();
            _ = self.eat(.semicolon);
            continue;
        };
        try stmts.append(self.allocator, stmt);
    }
    _ = self.eat(.kw_end);

    return self.addStmt(.{ .block = .{
        .name = name,
        .stmts = try stmts.toOwnedSlice(self.allocator),
        .local_vars = try local_vars.toOwnedSlice(self.allocator),
        .local_params = try local_params.toOwnedSlice(self.allocator),
    } });
}

fn parseIf(self: *Parser) !Ast.StmtId {
    _ = try self.expect(.kw_if);
    _ = try self.expect(.l_paren);
    const cond = try self.parseExpr();
    _ = try self.expect(.r_paren);
    const then_branch = try self.parseStmt();

    var else_branch: Ast.StmtId = .none;
    if (self.eat(.kw_else)) {
        else_branch = try self.parseStmt();
    }

    return self.addStmt(.{ .if_stmt = .{ .cond = cond, .then_branch = then_branch, .else_branch = else_branch } });
}

fn parseWhile(self: *Parser) !Ast.StmtId {
    _ = try self.expect(.kw_while);
    _ = try self.expect(.l_paren);
    const cond = try self.parseExpr();
    _ = try self.expect(.r_paren);
    const body = try self.parseStmt();
    return self.addStmt(.{ .while_stmt = .{ .cond = cond, .body = body } });
}

fn parseFor(self: *Parser) !Ast.StmtId {
    _ = try self.expect(.kw_for);
    _ = try self.expect(.l_paren);
    const init_target = try self.parseExpr();
    _ = try self.expect(.eq);
    const init_value = try self.parseExpr();
    _ = try self.expect(.semicolon);
    const cond = try self.parseExpr();
    _ = try self.expect(.semicolon);
    const incr_target = try self.parseExpr();
    _ = try self.expect(.eq);
    const incr_value = try self.parseExpr();
    _ = try self.expect(.r_paren);
    const body = try self.parseStmt();

    return self.addStmt(.{ .for_stmt = .{
        .init_target = init_target, .init_value = init_value,
        .cond = cond,
        .incr_target = incr_target, .incr_value = incr_value,
        .body = body,
    } });
}

fn parseCase(self: *Parser) !Ast.StmtId {
    _ = try self.expect(.kw_case);
    _ = try self.expect(.l_paren);
    const discr = try self.parseExpr();
    _ = try self.expect(.r_paren);

    var arms: Buf(Ast.CaseArm) = .empty;
    while (self.peek() != .kw_endcase and self.peek() != .eof) {
        if (self.eat(.kw_default)) {
            _ = self.eat(.colon);
            const body = try self.parseStmt();
            const empty_vals: []const Ast.ExprId = &.{};
            try arms.append(self.allocator, .{ .values = empty_vals, .body = body });
        } else {
            var vals: Buf(Ast.ExprId) = .empty;
            while (true) {
                try vals.append(self.allocator, try self.parseExpr());
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.colon);
            const body = try self.parseStmt();
            try arms.append(self.allocator, .{ .values = try vals.toOwnedSlice(self.allocator), .body = body });
        }
    }
    _ = try self.expect(.kw_endcase);

    return self.addStmt(.{ .case_stmt = .{ .discriminant = discr, .arms = try arms.toOwnedSlice(self.allocator) } });
}

fn parseEventControl(self: *Parser) !Ast.StmtId {
    _ = try self.expect(.at_sign);
    _ = try self.expect(.l_paren);
    const event = try self.parseExpr();
    _ = try self.expect(.r_paren);
    const body = try self.parseStmt();
    return self.addStmt(.{ .event_control = .{ .event = event, .body = body } });
}

fn parseDisable(self: *Parser) !Ast.StmtId {
    _ = try self.expect(.kw_disable);
    const name_idx = try self.expectIdent();
    _ = try self.expect(.semicolon);
    return self.addStmt(.{ .disable = self.tokenText(name_idx) });
}

fn parseExprOrContributeStmt(self: *Parser) !Ast.StmtId {
    const lhs = try self.parseExpr();

    if (self.eat(.contribute)) {
        const rhs = try self.parseExpr();
        _ = try self.expect(.semicolon);
        const kind: Ast.ContributeKind = blk: {
            const lhs_idx = @intFromEnum(lhs);
            if (lhs_idx < self.exprs.len and self.exprs.items(.tag)[lhs_idx] == .nature_access) {
                const str_idx = self.exprs.items(.lhs)[lhs_idx];
                const name = self.str_refs.slice()[str_idx];
                if (std.mem.eql(u8, name, "V") or std.mem.eql(u8, name, "Vp")) {
                    break :blk .potential;
                }
            }
            break :blk .flow;
        };
        return self.addStmt(.{ .contribute = .{ .kind = kind, .branch = lhs, .rhs = rhs } });
    }

    if (self.eat(.eq)) {
        const rhs = try self.parseExpr();
        _ = try self.expect(.semicolon);
        return self.addStmt(.{ .assign = .{ .target = lhs, .value = rhs } });
    }

    if (self.peek() == .kw_begin) return self.parseBlock();

    if (self.peek() == .identifier and self.peekAhead(1) == .colon) {
        _ = self.advance();
        _ = self.advance();
        if (self.peek() == .kw_begin) return self.parseBlock();
    }

    while (self.peek() != .semicolon and self.peek() != .kw_end and self.peek() != .kw_endmodule and self.peek() != .eof) {
        _ = self.advance();
    }
    _ = self.eat(.semicolon);
    return self.addStmt(.{ .expr_stmt = lhs });
}

// ── Expressions (precedence climbing) ────────────────────────────────

fn parseExpr(self: *Parser) error{ ParseError, OutOfMemory }!Ast.ExprId {
    return self.parseTernary();
}

fn parseTernary(self: *Parser) !Ast.ExprId {
    var expr = try self.parseBinExpr(0);
    if (self.eat(.question)) {
        const then_expr = try self.parseExpr();
        _ = try self.expect(.colon);
        const else_expr = try self.parseExpr();
        const cond = expr;
        const ei = try self.addExtra(&.{ @intFromEnum(cond), @intFromEnum(then_expr), @intFromEnum(else_expr) });
        expr = try self.addExprNode(.ternary, ei, 0);
    }
    return expr;
}

const Prec = u4;

fn binopPrec(tag: Tag) ?struct { prec: Prec, op: Ast.BinaryOp } {
    return switch (tag) {
        .pipe2 => .{ .prec = 1, .op = .logic_or },
        .amp2 => .{ .prec = 2, .op = .logic_and },
        .pipe => .{ .prec = 3, .op = .bit_or },
        .caret => .{ .prec = 4, .op = .bit_xor },
        .nxor_l, .nxor_r => .{ .prec = 4, .op = .bit_nxor },
        .amp => .{ .prec = 5, .op = .bit_and },
        .eq2 => .{ .prec = 6, .op = .eq },
        .neq => .{ .prec = 6, .op = .neq },
        .lt => .{ .prec = 7, .op = .lt },
        .gt => .{ .prec = 7, .op = .gt },
        .lte => .{ .prec = 7, .op = .lte },
        .gte => .{ .prec = 7, .op = .gte },
        .shl => .{ .prec = 8, .op = .shl },
        .shr => .{ .prec = 8, .op = .shr },
        .ashl => .{ .prec = 8, .op = .ashl },
        .ashr => .{ .prec = 8, .op = .ashr },
        .plus => .{ .prec = 9, .op = .add },
        .minus => .{ .prec = 9, .op = .sub },
        .star => .{ .prec = 10, .op = .mul },
        .slash => .{ .prec = 10, .op = .div },
        .percent => .{ .prec = 10, .op = .modulo },
        .pow => .{ .prec = 11, .op = .power },
        else => null,
    };
}

fn parseBinExpr(self: *Parser, min_prec: Prec) !Ast.ExprId {
    var lhs = try self.parseUnaryExpr();

    while (true) {
        const info = binopPrec(self.peek()) orelse break;
        if (info.prec < min_prec) break;
        _ = self.advance();
        const next_prec: Prec = if (info.op == .power) info.prec else info.prec + 1;
        const rhs = try self.parseBinExpr(next_prec);
        const lhs_prev = lhs;
        lhs = try self.addExprNode(binaryOpToTag(info.op), @intFromEnum(lhs_prev), @intFromEnum(rhs));
    }

    return lhs;
}

fn parseUnaryExpr(self: *Parser) !Ast.ExprId {
    switch (self.peek()) {
        .minus => {
            _ = self.advance();
            const operand = try self.parseUnaryExpr();
            return self.addExprNode(.negate, @intFromEnum(operand), 0);
        },
        .plus => {
            _ = self.advance();
            const operand = try self.parseUnaryExpr();
            return self.addExprNode(.u_plus, @intFromEnum(operand), 0);
        },
        .bang => {
            _ = self.advance();
            const operand = try self.parseUnaryExpr();
            return self.addExprNode(.logic_not, @intFromEnum(operand), 0);
        },
        .tilde => {
            _ = self.advance();
            const operand = try self.parseUnaryExpr();
            return self.addExprNode(.bit_not, @intFromEnum(operand), 0);
        },
        else => return self.parsePrimaryExpr(),
    }
}

fn parsePrimaryExpr(self: *Parser) !Ast.ExprId {
    switch (self.peek()) {
        .int_literal => {
            const idx = self.advance();
            const text = self.tokenText(idx);
            const val = std.fmt.parseInt(i64, text, 10) catch 0;
            try self.emitExprInt(val);
            return self.lastExpr();
        },
        .real_literal => {
            const idx = self.advance();
            const text = self.tokenText(idx);
            const val = std.fmt.parseFloat(f64, text) catch 0.0;
            try self.emitExprReal(val);
            return self.lastExpr();
        },
        .si_real_literal => {
            const idx = self.advance();
            const text = self.tokenText(idx);
            const val = parseSiReal(text);
            try self.emitExprReal(val);
            return self.lastExpr();
        },
        .string_literal => {
            const idx = self.advance();
            const text = self.tokenText(idx);
            const str = if (text.len >= 2) text[1 .. text.len - 1] else text;
            const si = try self.addStr(str);
            return self.addExprNode(.literal_string, si, 0);
        },
        .kw_inf => {
            _ = self.advance();
            return self.addExprNode(.literal_inf, 0, 0);
        },
        .system_identifier => {
            const idx = self.advance();
            const name = self.tokenText(idx);
            if (self.eat(.l_paren)) {
                var args: Buf(Ast.ExprId) = .empty;
                if (self.peek() != .r_paren) {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpr());
                        if (!self.eat(.comma)) break;
                    }
                }
                _ = try self.expect(.r_paren);
                const owned_args = try args.toOwnedSlice(self.allocator);
                try self.emitExprCallLike(.system_call, name, owned_args);
                return self.lastExpr();
            }
            const empty_args: []const Ast.ExprId = &.{};
            try self.emitExprCallLike(.system_call, name, empty_args);
            return self.lastExpr();
        },
        .kw_initial_step, .kw_final_step => {
            const idx = self.advance();
            const name = self.tokenText(idx);
            if (self.eat(.l_paren)) {
                var args: Buf(Ast.ExprId) = .empty;
                if (self.peek() != .r_paren) {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpr());
                        if (!self.eat(.comma)) break;
                    }
                }
                _ = try self.expect(.r_paren);
                const owned_args = try args.toOwnedSlice(self.allocator);
                try self.emitExprCallLike(.func_call, name, owned_args);
                return self.lastExpr();
            }
            const empty_args: []const Ast.ExprId = &.{};
            try self.emitExprCallLike(.func_call, name, empty_args);
            return self.lastExpr();
        },
        .identifier, .escaped_identifier => {
            const idx = self.advance();
            const name = self.tokenText(idx);

            if (self.eat(.l_paren)) {
                var args: Buf(Ast.ExprId) = .empty;
                if (self.peek() != .r_paren) {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpr());
                        if (!self.eat(.comma)) break;
                    }
                }
                _ = try self.expect(.r_paren);
                const owned_args = try args.toOwnedSlice(self.allocator);

                const tag: Ast.ExprTag = if (isNatureAccess(name)) .nature_access else .func_call;
                try self.emitExprCallLike(tag, name, owned_args);
                return self.lastExpr();
            }
            const si = try self.addStr(name);
            return self.addExprNode(.ident, si, 0);
        },
        .lt => {
            if (self.peekAhead(1) == .identifier or self.peekAhead(1) == .escaped_identifier) {
                if (self.peekAhead(2) == .gt) {
                    _ = self.advance();
                    const name_idx = self.advance();
                    _ = self.advance();
                    const name = self.tokenText(name_idx);
                    const si = try self.addStr(name);
                    return self.addExprNode(.port_flow, si, 0);
                }
            }
            try self.emitError("expression");
            _ = self.advance();
            try self.emitExprInt(0);
            return self.lastExpr();
        },
        .l_paren => {
            _ = self.advance();
            const expr = try self.parseExpr();
            _ = try self.expect(.r_paren);
            return self.addExprNode(.paren, @intFromEnum(expr), 0);
        },
        .arr_start => {
            _ = self.advance();
            var elems: Buf(Ast.ExprId) = .empty;
            while (self.peek() != .r_brace and self.peek() != .eof) {
                try elems.append(self.allocator, try self.parseExpr());
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.r_brace);
            const owned_elems = try elems.toOwnedSlice(self.allocator);
            var extra_buf: Buf(u32) = .empty;
            defer extra_buf.deinit(self.allocator);
            try extra_buf.ensureTotalCapacity(self.allocator, owned_elems.len);
            for (owned_elems) |e| extra_buf.appendAssumeCapacity(@intFromEnum(e));
            const ei = try self.addExtra(extra_buf.slice());
            return self.addExprNode(.array, ei, @intCast(owned_elems.len));
        },
        .l_brace => {
            _ = self.advance();
            var elems: Buf(Ast.ExprId) = .empty;
            while (self.peek() != .r_brace and self.peek() != .eof) {
                try elems.append(self.allocator, try self.parseExpr());
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.r_brace);
            const owned_elems = try elems.toOwnedSlice(self.allocator);
            var extra_buf: Buf(u32) = .empty;
            defer extra_buf.deinit(self.allocator);
            try extra_buf.ensureTotalCapacity(self.allocator, owned_elems.len);
            for (owned_elems) |e| extra_buf.appendAssumeCapacity(@intFromEnum(e));
            const ei = try self.addExtra(extra_buf.slice());
            return self.addExprNode(.array, ei, @intCast(owned_elems.len));
        },
        else => {
            try self.emitError("expression");
            _ = self.advance();
            try self.emitExprInt(0);
            return self.lastExpr();
        },
    }
}

fn isNatureAccess(name: []const u8) bool {
    // ponytail: explicit list of standard access functions per LRM 2.4.0
    return std.mem.eql(u8, name, "V") or
        std.mem.eql(u8, name, "I") or
        std.mem.eql(u8, name, "Vp") or
        std.mem.eql(u8, name, "Ip") or
        std.mem.eql(u8, name, "Pwr") or
        std.mem.eql(u8, name, "Temp") or
        std.mem.eql(u8, name, "potential") or
        std.mem.eql(u8, name, "flow");
}

fn parseSiReal(text: []const u8) f64 {
    if (text.len == 0) return 0.0;
    const last = text[text.len - 1];
    const num_part = text[0 .. text.len - 1];
    const base = std.fmt.parseFloat(f64, num_part) catch 0.0;
    const scale: f64 = switch (last) {
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
        else => 1.0,
    };
    return base * scale;
}
