//! Class 2 — Parsing. LRM annex A (normative grammar), ch3 declaration syntax,
//! §4.2.2 operator precedence, §6.8 scope rules.
//!
//! Transformation: token stream → ast.SourceFile (SoA stores).
//!
//! DOD: append nodes into the SoA ExprStore / statement pool and return u32
//! handles (ExprId/StmtId). Recursive-descent + precedence climbing for exprs.
//! No pointer tree is ever built.
//!
//! Ownership: everything (AST stores, decl slices) is allocated from `arena`
//! and freed by `arena.deinit()`. `src`, `tags` and `starts` are BORROWED and
//! must outlive the produced `Ast.SourceFile` — every interned name is a
//! substring of `src`.
//!
//! Diagnostics: errors are COLLECTED into the shared `diag.Bag`, not thrown.
//! `error.ParseError` is the internal unwind signal to the nearest recovery
//! point (module item / statement / top-level declaration); each recovery point
//! resynchronizes on `;` or a closing keyword and keeps parsing.
//! `parseSourceFile` returns `error.ParseError` at the end iff anything was
//! reported — the AST is then partial and MUST NOT be lowered.
//!
//! Token text: `token.Stored` carries only {tag,start} (end is recomputed, not
//! stored), so this file re-scans identifier/number/string lexemes from `start`.
//! It has to anyway: literal *values* (§2.6 bases, SI scale factors) are the
//! parser's job.

const std = @import("std");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const Ast = @import("ast.zig");
const diag = @import("diag.zig");

pub const Error = error{ OutOfMemory, ParseError };

pub const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    tags: []const token.Tag,
    starts: []const u32,
    pos: u32 = 0,
    file: Ast.SourceFile = .empty,
    /// Shared collector. The cap, the dedupe and the rendering all live there.
    bag: *diag.Bag,
    /// Did THIS parse report anything? The bag is shared across stages and
    /// drops entries to the cap and the dedupe set, so its length cannot answer.
    failed: bool = false,
    /// §3.6.1.4 nature `access` names. `name(...)` is a branch probe (§4.4.1)
    /// iff the name is in here, otherwise it is a user function call (§4.7).
    /// Seeded with V/I (disciplines.vams, annex D) and grown by every
    /// `access = X;` nature attribute parsed ahead of the module.
    access_names: std.StringHashMapUnmanaged(void) = .empty,
    /// §10.6 reserved-keyword set in effect, and the open `begin_keywords
    /// directives it was pushed by. See `keywordsDirective` / `identLike`.
    kw_set: token.KeywordSet = token.default_keyword_set,
    kw_stack: std.ArrayList(struct { tok: u32, prev: token.KeywordSet }) = .empty,

    pub fn init(
        arena: std.mem.Allocator,
        src: []const u8,
        tags: []const token.Tag,
        starts: []const u32,
        bag: *diag.Bag,
    ) Parser {
        std.debug.assert(tags.len == starts.len);
        std.debug.assert(tags.len > 0 and tags[tags.len - 1] == .eof);
        return .{
            .arena = arena,
            .src = src,
            .tags = tags,
            .starts = starts,
            .bag = bag,
        };
    }

    // -----------------------------------------------------------------------
    // A.1.2 source_text
    // -----------------------------------------------------------------------

    /// Top of grammar. LRM annex A source_text.
    pub fn parseSourceFile(self: *Parser) Error!Ast.SourceFile {
        try self.access_names.put(self.arena, "V", {});
        try self.access_names.put(self.arena, "I", {});

        var modules: std.ArrayList(Ast.ModuleDecl) = .empty;
        var disciplines: std.ArrayList(Ast.DisciplineDecl) = .empty;
        var natures: std.ArrayList(Ast.NatureDecl) = .empty;

        while (true) {
            self.skipAttributes();
            const before = self.pos;
            switch (self.peek()) {
                .eof => break,
                // §10.6: legal ONLY here — "outside of a design element".
                .dir_begin_keywords, .dir_end_keywords => self.keywordsDirective() catch |e| {
                    try self.rethrowOom(e);
                    self.recoverTopLevel(before);
                },
                .kw_module => {
                    const m = self.parseModule() catch |e| {
                        try self.rethrowOom(e);
                        self.recoverTopLevel(before);
                        continue;
                    };
                    try modules.append(self.arena, m);
                },
                .kw_discipline => {
                    const d = self.parseDiscipline() catch |e| {
                        try self.rethrowOom(e);
                        self.recoverTopLevel(before);
                        continue;
                    };
                    try disciplines.append(self.arena, d);
                },
                .kw_nature => {
                    const n = self.parseNature() catch |e| {
                        try self.rethrowOom(e);
                        self.recoverTopLevel(before);
                        continue;
                    };
                    try natures.append(self.arena, n);
                },
                else => {
                    // §6.4 paramsets, macromodules, UDPs, config/library files
                    // and connectrules are all out of the annex C subset.
                    _ = self.failAt(self.pos, .E0201, "`{s}`", .{self.found(self.pos)}) catch {};
                    self.recoverTopLevel(before);
                },
            }
        }

        // §10.6: `begin_keywords "affects all source code that follows the
        // directive, even across source code file boundaries, until the
        // matching `end_keywords directive is encountered" — so a missing one
        // is an error, exactly like the preprocessor's unterminated `ifdef.
        if (self.kw_stack.items.len != 0) {
            _ = self.failAt(
                self.kw_stack.items[self.kw_stack.items.len - 1].tok,
                .E0137,
                "missing `end_keywords",
                .{},
            ) catch {};
        }

        self.file.modules = modules.items;
        self.file.disciplines = disciplines.items;
        self.file.natures = natures.items;
        if (self.failed) return error.ParseError;
        return self.file;
    }

    /// LRM §10.6 `begin_keywords "<version_specifier>" … `end_keywords.
    /// Selects which annex B words are reserved for the design elements that
    /// follow (see `identLike`). The directives nest, so the previous set is
    /// stacked rather than reset.
    fn keywordsDirective(self: *Parser) Error!void {
        const tok = self.pos;
        self.pos += 1;
        if (self.tags[tok] == .dir_end_keywords) {
            const open = self.kw_stack.pop() orelse
                return self.failAt(tok, .E0136, "", .{});
            self.kw_set = open.prev;
            return;
        }
        const str = try self.expect(.string_literal);
        const raw = self.tokenText(str);
        const spec = if (raw.len >= 2) raw[1 .. raw.len - 1] else "";
        const set = token.KeywordSet.fromSpecifier(spec) orelse return self.failAt(
            str,
            .E0135,
            "`{s}`",
            .{spec},
        );
        try self.kw_stack.append(self.arena, .{ .tok = tok, .prev = self.kw_set });
        self.kw_set = set;
    }

    /// Skip to the next thing that can start a top-level description (A.1.2),
    /// past any `end*` keyword that closes the construct we bailed out of.
    fn recoverTopLevel(self: *Parser, before: u32) void {
        if (self.pos == before) self.pos += 1;
        while (true) : (self.pos += 1) switch (self.peek()) {
            .eof => return,
            .kw_module, .kw_discipline, .kw_nature => return,
            .kw_endmodule, .kw_enddiscipline, .kw_endnature, .kw_endparamset => {
                self.pos += 1;
                return;
            },
            else => {},
        };
    }

    // -----------------------------------------------------------------------
    // A.1.2 module_declaration — LRM §6.2
    // -----------------------------------------------------------------------

    /// LRM §6.2: header (name + ports §6.5), then module items.
    ///
    /// ponytail: no `module_parameter_port_list` (`#(...)`, A.1.3). The header
    /// expects `;` after the port list, so `#` reports "expected semicolon" —
    /// which is what the fixtures pin. Add it here if a model needs it.
    pub fn parseModule(self: *Parser) Error!Ast.ModuleDecl {
        const main_tok = self.pos;
        self.pos += 1; // 'module'
        const name = try self.expectIdent();

        var b: Body = .{};
        if (self.peek() == .lparen) try self.parsePortList(&b);
        _ = try self.expect(.semicolon);
        try self.parseModuleItems(&b, .kw_endmodule, false);
        _ = try self.expect(.kw_endmodule);

        return .{
            .name = name,
            .main_tok = main_tok,
            .ports = b.ports.items,
            .params = b.params.items,
            .aliasparams = b.aliasparams.items,
            .vars = b.vars.items,
            .nets = b.nets.items,
            .branches = b.branches.items,
            .genvars = b.genvars.items,
            .functions = b.functions.items,
            .analog = b.analog.items,
        };
    }

    /// Accumulators for one module body. Arena-owned; `.items` becomes the
    /// ModuleDecl's slices (append-only ⇒ source order is preserved).
    const Body = struct {
        ports: std.ArrayList(Ast.Port) = .empty,
        params: std.ArrayList(Ast.ParamDecl) = .empty,
        aliasparams: std.ArrayList(Ast.AliasParam) = .empty,
        vars: std.ArrayList(Ast.VarDecl) = .empty,
        nets: std.ArrayList(Ast.NetDecl) = .empty,
        branches: std.ArrayList(Ast.BranchDecl) = .empty,
        genvars: std.ArrayList(Ast.StrId) = .empty,
        functions: std.ArrayList(Ast.FuncDecl) = .empty,
        analog: std.ArrayList(Ast.AnalogBlock) = .empty,
    };

    /// A.1.3 list_of_ports / list_of_port_declarations (§6.5). Both styles fall
    /// out of one loop: a direction keyword starts a new declaration and its
    /// direction+discipline stick to the following comma-separated names.
    fn parsePortList(self: *Parser, b: *Body) Error!void {
        _ = try self.expect(.lparen);
        if (self.eat(.rparen)) return;
        var dir: Ast.Direction = .unspecified;
        var disc: Ast.StrId = .none;
        while (true) {
            self.skipAttributes();
            if (token.isPortDirection(self.peek())) {
                dir = self.portDirection(self.peek());
                self.pos += 1;
                disc = try self.optDiscipline();
            }
            const tok = self.pos;
            const name = try self.expectIdent();
            try b.ports.append(self.arena, .{
                .name = name,
                .direction = dir,
                .discipline = disc,
                .main_tok = tok,
            });
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
    }

    fn portDirection(self: *Parser, tag: token.Tag) Ast.Direction {
        _ = self;
        return switch (tag) {
            .kw_input => .input,
            .kw_output => .output,
            else => .inout,
        };
    }

    /// A.2.1.2 `[ discipline_identifier ] [ net_type ] [ signed ]` prefix of a
    /// port declaration. A discipline is an identifier followed by another
    /// identifier (the first port name), so one token of lookahead decides.
    fn optDiscipline(self: *Parser) Error!Ast.StrId {
        var disc: Ast.StrId = .none;
        if (self.peek() == .identifier and self.identLike(self.pos + 1)) {
            disc = try self.internTok(self.pos);
            self.pos += 1;
        }
        if (token.isNetType(self.peek())) self.pos += 1;
        _ = self.eat(.kw_signed);
        return disc;
    }

    // -----------------------------------------------------------------------
    // A.1.4 module_item — LRM §6.2, ch3
    // -----------------------------------------------------------------------

    fn parseModuleItems(self: *Parser, b: *Body, end: token.Tag, in_generate: bool) Error!void {
        while (true) {
            self.skipAttributes();
            const t = self.peek();
            if (t == end or t == .eof or t == .kw_endmodule) return;
            const before = self.pos;
            self.parseModuleItem(b, in_generate) catch |e| {
                try self.rethrowOom(e);
                if (self.pos == before) self.pos += 1;
                self.recoverStatement();
            };
        }
    }

    fn parseModuleItem(self: *Parser, b: *Body, in_generate: bool) Error!void {
        switch (self.peek()) {
            // §10.6: "can only be specified outside of a design element".
            .dir_begin_keywords, .dir_end_keywords => return self.failAt(
                self.pos,
                .E0202,
                "{s} inside a module",
                .{token.Tag.lexeme(self.peek()).?},
            ),
            // A.4.2 loop / conditional generate and generate_block. Their
            // bodies are analog statements, so they become analog constructs:
            // `for` over a genvar is exactly the §5.9.2 form lowering already
            // unrolls (see `Ast.Stmt.for_stmt`), and `if` over a constant is
            // folded there too.
            .kw_for, .kw_if, .kw_begin => {
                if (!in_generate) return self.unsupportedItem();
                const tok = self.pos;
                const body = try self.parseStmt();
                try b.analog.append(self.arena, .{ .body = body, .main_tok = tok });
            },
            // §3.4 parameter / localparam (A.2.1.1)
            .kw_parameter, .kw_localparam => {
                try self.parseParamDecl(&b.params);
                _ = try self.expect(.semicolon);
            },
            // §3.4.6 aliasparam (A.2.1.1)
            .kw_aliasparam => {
                self.pos += 1;
                const alias = try self.expectIdent();
                _ = try self.expect(.assign_eq);
                const target = try self.expectIdent();
                _ = try self.expect(.semicolon);
                try b.aliasparams.append(self.arena, .{ .alias = alias, .target = target });
            },
            // §3.2/§3.3 variable declarations (A.2.1.3)
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                try self.parseVarDecl(&b.vars);
                _ = try self.expect(.semicolon);
            },
            // §3.5 genvar (A.4.2)
            .kw_genvar => {
                self.pos += 1;
                while (true) {
                    try b.genvars.append(self.arena, try self.expectIdent());
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            },
            // A.2.1.3 event_declaration (§5.10.4). Named events ARE part of the
            // Verilog-A subset — §5.10 lists them as one of the three kinds of
            // ANALOG event and §5.10.4's own example triggers and detects one
            // entirely inside an `analog` block; annex C.7 excludes only DIGITAL
            // behavior and events. FastVAF does not implement them yet, and says
            // so here rather than accepting the declaration and turning `@(ev)`
            // into a guard that is silently never true.
            .kw_event => return self.failAt(self.pos, .E0203, "", .{}),
            // §3.12 branch declaration (A.2.1.3)
            .kw_branch => try self.parseBranchDecl(b),
            // §3.6.4 ground declaration (A.2.1.3 net_declaration)
            .kw_ground => {
                self.pos += 1;
                const disc = try self.optDiscipline();
                try self.parseNetNames(b, disc, true);
            },
            // §6.5.2 non-ANSI port declarations
            .kw_input, .kw_output, .kw_inout => try self.parsePortDecl(b),
            // A.2.1.3 net_declaration with an explicit net type
            .kw_wire,
            .kw_tri,
            .kw_tri0,
            .kw_tri1,
            .kw_triand,
            .kw_trior,
            .kw_trireg,
            .kw_wand,
            .kw_wor,
            .kw_uwire,
            .kw_supply0,
            .kw_supply1,
            => {
                self.pos += 1;
                const disc = try self.optDiscipline();
                try self.parseNetNames(b, disc, false);
            },
            // §5.2 analog construct / §4.7.1 analog function
            .kw_analog => try self.parseAnalog(b),
            // A.4.2 generate_region — transparent: the items inside are plain
            // module items. Loop/conditional generate is not implemented, so a
            // `for`/`if`/`case` here lands on the unsupported-item diagnostic.
            .kw_generate => {
                self.pos += 1;
                try self.parseModuleItems(b, .kw_endgenerate, true);
                _ = try self.expect(.kw_endgenerate);
            },
            // A.2.1.3 `discipline_identifier list_of_net_identifiers ;`
            // vs A.4.1 module_instantiation — both start with an identifier.
            .identifier, .escaped_identifier => {
                if (self.peekAt(1) == .hash or
                    ((self.peekAt(1) == .identifier or self.peekAt(1) == .escaped_identifier) and
                        self.peekAt(2) == .lparen))
                {
                    var d = self.failWith(self.pos, .E0204);
                    d.help("compile the child as its own device and instantiate it in the netlist", .{});
                    try d.emit();
                    return error.ParseError;
                }
                // `discipline [range] names ;` — a vector net's range is
                // rejected by the name list ("expected identifier"), which is
                // the wording the fixtures pin.
                if (!self.identLike(self.pos + 1) and self.peekAt(1) != .lbracket) {
                    return self.unsupportedItem();
                }
                const disc = try self.internTok(self.pos);
                self.pos += 1;
                try self.parseNetNames(b, disc, false);
            },
            else => return self.unsupportedItem(),
        }
    }

    /// One shared diagnostic for everything annex C leaves out of the analog
    /// subset at module scope: digital `initial`/`always`, gate and UDP
    /// instantiations, `defparam`, `task`, `specify`, `reg`, generate-case …
    fn unsupportedItem(self: *Parser) Error {
        return self.failAt(self.pos, .E0205, "found {s}", .{self.found(self.pos)});
    }

    /// §6.5.2 body port declaration: it re-declares a header port's direction
    /// and discipline, it does not introduce a new terminal.
    fn parsePortDecl(self: *Parser, b: *Body) Error!void {
        const dir = self.portDirection(self.peek());
        self.pos += 1;
        const disc = try self.optDiscipline();
        while (true) {
            const tok = self.pos;
            const name = try self.expectIdent();
            if (self.findPort(b, name)) |p| {
                p.direction = dir;
                if (disc != .none) p.discipline = disc;
            } else {
                _ = self.failAt(tok, .E0206, "`{s}`", .{self.file.str(name)}) catch {};
            }
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }

    fn findPort(self: *Parser, b: *Body, name: Ast.StrId) ?*Ast.Port {
        _ = self;
        for (b.ports.items) |*p| if (p.name == name) return p;
        return null;
    }

    /// A.2.1.3 `list_of_net_identifiers ;` (§3.6.3). A net that names a header
    /// port binds the discipline to that port instead of declaring a new net,
    /// so lowering sees one object per terminal.
    ///
    /// ponytail: no vector nets (`electrical [3:0] p;`) and no
    /// net_decl_assignment (`electrical n = 5.0;`) — both report through the
    /// normal identifier/`;` expectations, which is what the fixtures pin.
    fn parseNetNames(self: *Parser, b: *Body, disc: Ast.StrId, is_ground: bool) Error!void {
        while (true) {
            const tok = self.pos;
            const name = try self.expectIdent();
            if (!is_ground and self.findPort(b, name) != null) {
                self.findPort(b, name).?.discipline = disc;
            } else {
                try b.nets.append(self.arena, .{
                    .name = name,
                    .discipline = disc,
                    .is_ground = is_ground,
                    .main_tok = tok,
                });
            }
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }

    /// LRM §3.12 / A.2.1.3 `branch ( a [, b] ) name {, name} ;`
    ///
    /// ponytail: port branches `branch (<p>)` are rejected (the `<` is not a
    /// net identifier). `Ast.BranchDecl.is_port_branch` is ready when one is
    /// needed.
    fn parseBranchDecl(self: *Parser, b: *Body) Error!void {
        const main_tok = self.pos;
        self.pos += 1; // 'branch'
        _ = try self.expect(.lparen);
        const hi = try self.parseNetRef();
        var lo: Ast.ExprId = .none;
        if (self.eat(.comma)) lo = try self.parseNetRef();
        _ = try self.expect(.rparen);
        while (true) {
            const name = try self.expectIdent();
            try b.branches.append(self.arena, .{
                .name = name,
                .hi = hi,
                .lo = lo,
                .main_tok = main_tok,
            });
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }

    // -----------------------------------------------------------------------
    // A.2.1.1 parameter declarations — LRM §3.4
    // -----------------------------------------------------------------------

    /// Parameter declaration incl. ranges. LRM §3.4, §3.4.1, §3.4.2, §3.4.5.
    ///
    /// Deviates from the stub signature: `parameter real a = 1, b = 2;` is one
    /// declaration but N `ParamDecl`s, so the list is an out-parameter.
    pub fn parseParamDecl(self: *Parser, out: *std.ArrayList(Ast.ParamDecl)) Error!void {
        const is_local = self.peek() == .kw_localparam;
        self.pos += 1;
        _ = self.eat(.kw_signed);
        const ty: Ast.Type = switch (self.peek()) {
            .kw_integer, .kw_time => .integer, // §3.4.1: time folds to integer
            .kw_real, .kw_realtime => .real,
            .kw_string => .string,
            else => .unspecified, // §3.4.1 — inferred from the default by lowering
        };
        if (ty != .unspecified) self.pos += 1;

        while (true) {
            const tok = self.pos;
            const name = try self.expectIdent();
            var dims: []const Ast.Dim = &.{};
            if (self.peek() == .lbracket) {
                const d = try self.parseDim();
                const one = try self.arena.alloc(Ast.Dim, 1);
                one[0] = d;
                dims = one;
            }
            _ = try self.expect(.assign_eq);
            const default = try self.parseExpr();

            var ranges: std.ArrayList(Ast.ValueRange) = .empty;
            while (self.peek() == .kw_from or self.peek() == .kw_exclude) {
                try ranges.append(self.arena, try self.parseRange());
            }
            try out.append(self.arena, .{
                .name = name,
                .ty = ty,
                .default = default,
                .is_local = is_local,
                .dims = dims,
                .ranges = ranges.items,
                .main_tok = tok,
            });
            if (!self.eat(.comma)) break;
        }
    }

    /// LRM §3.4.2 / A.2.5 value_range. CRITICAL: this is the only bound
    /// evidence class 6 (proof.zig) gets — it must reach `ParamDecl.ranges`.
    pub fn parseRange(self: *Parser) Error!Ast.ValueRange {
        const kind: Ast.ValueRange.Kind = if (self.peek() == .kw_from) .from else .exclude;
        self.pos += 1;

        // `from '{"a", "b"}` — string-set range (§3.4.2).
        if (self.peek() == .apostrophe_lbrace) {
            self.pos += 1;
            var names: std.ArrayList(Ast.StrId) = .empty;
            if (self.peek() != .rbrace) while (true) {
                const tok = try self.expect(.string_literal);
                try names.append(self.arena, try self.internString(tok));
                if (!self.eat(.comma)) break;
            };
            _ = try self.expect(.rbrace);
            const off = try self.file.exprs.addStrList(self.arena, names.items);
            return .{ .kind = kind, .lo = .none, .strings = off };
        }

        // `exclude constant_expression`
        if (self.peek() != .lparen and self.peek() != .lbracket) {
            std.debug.assert(kind == .exclude);
            return .{ .kind = kind, .lo = try self.parseValueRangeExpr() };
        }

        const lo_inclusive = self.peek() == .lbracket;
        self.pos += 1;
        const lo = try self.parseValueRangeExpr();
        // `exclude ( expr )` — a parenthesized single value, not a range.
        if (self.peek() != .colon) {
            _ = try self.expect(.rparen);
            return .{ .kind = kind, .lo = lo };
        }
        self.pos += 1;
        const hi = try self.parseValueRangeExpr();
        const hi_inclusive = switch (self.peek()) {
            .rbracket => true,
            .rparen => false,
            else => return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)}),
        };
        self.pos += 1;
        return .{
            .kind = kind,
            .lo = lo,
            .hi = hi,
            .lo_inclusive = lo_inclusive,
            .hi_inclusive = hi_inclusive,
        };
    }

    /// A.2.5 value_range_expression ::= constant_expression | -inf | inf
    fn parseValueRangeExpr(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        if (self.peek() == .minus and self.peekAt(1) == .kw_inf) {
            self.pos += 2;
            return self.addExpr(.{ .tag = .neg_inf, .main_tok = tok });
        }
        if (self.peek() == .kw_inf) {
            self.pos += 1;
            return self.addExpr(.{ .tag = .pos_inf, .main_tok = tok });
        }
        return self.parseExpr();
    }

    /// A.2.1.3 integer/real/string declaration (§3.2, §3.3). One VarDecl per
    /// name; `variable_type ::= id { dimension } [ = expr ]` (A.2.2.1).
    fn parseVarDecl(self: *Parser, out: *std.ArrayList(Ast.VarDecl)) Error!void {
        const ty: Ast.Type = switch (self.peek()) {
            .kw_integer, .kw_time => .integer,
            .kw_string => .string,
            else => .real, // real, realtime
        };
        self.pos += 1;
        while (true) {
            const tok = self.pos;
            const name = try self.expectIdent();
            var dims: []const Ast.Dim = &.{};
            if (self.peek() == .lbracket) {
                const d = try self.parseDim();
                const one = try self.arena.alloc(Ast.Dim, 1);
                one[0] = d;
                dims = one;
            }
            var init_expr: Ast.ExprId = .none;
            if (self.eat(.assign_eq)) init_expr = try self.parseExpr();
            try out.append(self.arena, .{
                .name = name,
                .ty = ty,
                .dims = dims,
                .init = init_expr,
                .main_tok = tok,
            });
            if (!self.eat(.comma)) break;
        }
    }

    /// A.2.5 `dimension ::= [ expr : expr ]` (§3.2.2, §3.4.4).
    fn parseDim(self: *Parser) Error!Ast.Dim {
        _ = try self.expect(.lbracket);
        const msb = try self.parseExpr();
        _ = try self.expect(.colon);
        const lsb = try self.parseExpr();
        _ = try self.expect(.rbracket);
        return .{ .msb = msb, .lsb = lsb };
    }

    // -----------------------------------------------------------------------
    // A.2.6 analog_function_declaration — LRM §4.7.1 · A.6.2 analog_construct
    // -----------------------------------------------------------------------

    fn parseAnalog(self: *Parser, b: *Body) Error!void {
        const main_tok = self.pos;
        self.pos += 1; // 'analog'
        if (self.peek() == .kw_function) return self.parseFuncDecl(b, main_tok);
        // §5.2.1 `analog initial analog_function_statement`
        const is_initial = self.eat(.kw_initial);
        const body = try self.parseStmt();
        try b.analog.append(self.arena, .{
            .is_initial = is_initial,
            .body = body,
            .main_tok = main_tok,
        });
    }

    /// LRM §4.7.1: `analog function [type] name ; items stmt endfunction`.
    /// Argument types come either from the declaration itself (`input real x;`)
    /// or from a matching variable declaration (`input x; real x;`, A.2.6).
    fn parseFuncDecl(self: *Parser, b: *Body, main_tok: u32) Error!void {
        self.pos += 1; // 'function'
        const ret_ty: Ast.Type = switch (self.peek()) {
            .kw_integer => .integer,
            .kw_real => .real,
            .kw_string => .string,
            else => .real, // §4.7.1 default
        };
        if (self.peek() == .kw_integer or self.peek() == .kw_real or self.peek() == .kw_string) {
            self.pos += 1;
        }
        const name = try self.expectIdent();
        _ = try self.expect(.semicolon);

        var args: std.ArrayList(Ast.FuncArg) = .empty;
        var params: std.ArrayList(Ast.ParamDecl) = .empty;
        var vars: std.ArrayList(Ast.VarDecl) = .empty;
        var body: std.ArrayList(Ast.StmtId) = .empty;

        while (true) {
            self.skipAttributes();
            switch (self.peek()) {
                .eof, .kw_endfunction => break,
                .kw_input, .kw_output, .kw_inout => {
                    const dir = self.portDirection(self.peek());
                    self.pos += 1;
                    // `input real x;` (A.2.7 task_port_type) or bare `input x;`
                    const ty: Ast.Type = switch (self.peek()) {
                        .kw_integer, .kw_time => .integer,
                        .kw_real, .kw_realtime => .real,
                        .kw_string => .string,
                        else => .unspecified,
                    };
                    if (ty != .unspecified) self.pos += 1 else _ = try self.optDiscipline();
                    while (true) {
                        try args.append(self.arena, .{
                            .name = try self.expectIdent(),
                            .ty = ty,
                            .direction = dir,
                        });
                        if (!self.eat(.comma)) break;
                    }
                    _ = try self.expect(.semicolon);
                },
                .kw_parameter, .kw_localparam => {
                    try self.parseParamDecl(&params);
                    _ = try self.expect(.semicolon);
                },
                .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                    const first = vars.items.len;
                    try self.parseVarDecl(&vars);
                    _ = try self.expect(.semicolon);
                    // A variable that re-declares an argument only types it.
                    var i = vars.items.len;
                    while (i > first) {
                        i -= 1;
                        for (args.items) |*a| {
                            if (a.name != vars.items[i].name) continue;
                            if (a.ty == .unspecified) a.ty = vars.items[i].ty;
                            _ = vars.orderedRemove(i);
                            break;
                        }
                    }
                },
                else => {
                    const before = self.pos;
                    const s = self.parseStmt() catch |e| {
                        try self.rethrowOom(e);
                        if (self.pos == before) self.pos += 1;
                        self.recoverStatement();
                        continue;
                    };
                    try body.append(self.arena, s);
                },
            }
        }
        _ = try self.expect(.kw_endfunction);

        for (args.items) |*a| if (a.ty == .unspecified) {
            a.ty = .real; // §4.7.2 default
        };
        const body_id: Ast.StmtId = if (body.items.len == 1)
            body.items[0]
        else
            try self.addStmt(.{ .block = .{ .body = body.items } }, main_tok);

        try b.functions.append(self.arena, .{
            .name = name,
            .ret_ty = ret_ty,
            .args = args.items,
            .params = params.items,
            .vars = vars.items,
            .body = body_id,
            .main_tok = main_tok,
        });
    }

    // -----------------------------------------------------------------------
    // A.1.6 nature_declaration / A.1.7 discipline_declaration — LRM §3.6
    // -----------------------------------------------------------------------

    /// LRM §3.6.1 (A.1.6). Base natures must declare `abstol` and `access`;
    /// that check is lowering's, not the grammar's.
    pub fn parseNature(self: *Parser) Error!Ast.NatureDecl {
        const main_tok = self.pos;
        self.pos += 1; // 'nature'
        const name = try self.expectIdent();
        var parent: Ast.StrId = .none;
        var parent_access: ?Ast.PotentialOrFlow = null;
        if (self.eat(.colon)) {
            parent = try self.expectIdent();
            // A.1.6 `discipline_identifier . potential_or_flow`
            if (self.eat(.dot)) {
                parent_access = switch (self.peek()) {
                    .kw_potential => .potential,
                    .kw_flow => .flow,
                    else => return self.failAt(self.pos, .E0211, "found {s}", .{self.found(self.pos)}),
                };
                self.pos += 1;
            }
        }
        _ = self.eat(.semicolon);

        var attrs: std.ArrayList(Ast.NatureAttr) = .empty;
        while (self.peek() != .kw_endnature and self.peek() != .eof) {
            const attr = try self.parseNatureAttr();
            // §3.6.1.4: this is where the branch-probe names come from.
            if (self.file.strings.eql(attr.name, "access") and
                self.file.exprs.tag(attr.value) == .ident)
            {
                const access = self.file.str(self.file.exprs.strOf(attr.value));
                try self.access_names.put(self.arena, access, {});
            }
            try attrs.append(self.arena, attr);
        }
        _ = try self.expect(.kw_endnature);
        return .{
            .name = name,
            .parent = parent,
            .parent_access = parent_access,
            .attrs = attrs.items,
            .main_tok = main_tok,
        };
    }

    /// A.1.6 `nature_attribute ::= identifier = nature_attribute_expression ;`.
    /// The LRM-defined attribute names (§3.6.1.2 abstol, §3.6.1.3 units,
    /// §3.6.1.4 access, §3.6.1.5/6 idt_nature/ddt_nature) are keywords.
    fn parseNatureAttr(self: *Parser) Error!Ast.NatureAttr {
        const tok = self.pos;
        const name: Ast.StrId = switch (self.peek()) {
            .identifier, .escaped_identifier => try self.expectIdent(),
            .kw_abstol, .kw_access, .kw_units, .kw_ddt_nature, .kw_idt_nature => blk: {
                const s = try self.file.intern(self.arena, self.tokenText(self.pos));
                self.pos += 1;
                break :blk s;
            },
            else => return self.failAt(self.pos, .E0208, "found {s}", .{self.found(self.pos)}),
        };
        _ = try self.expect(.assign_eq);
        const value = try self.parseExpr();
        _ = try self.expect(.semicolon);
        return .{ .name = name, .value = value, .main_tok = tok };
    }

    /// LRM §3.6.2 (A.1.7).
    pub fn parseDiscipline(self: *Parser) Error!Ast.DisciplineDecl {
        const main_tok = self.pos;
        self.pos += 1; // 'discipline'
        const name = try self.expectIdent();
        _ = self.eat(.semicolon);

        var d: Ast.DisciplineDecl = .{ .name = name, .main_tok = main_tok };
        var overrides: std.ArrayList(Ast.DisciplineDecl.Override) = .empty;
        while (self.peek() != .kw_enddiscipline and self.peek() != .eof) {
            switch (self.peek()) {
                // §3.6.2.1 nature_binding / §3.6.2.3 nature_attribute_override
                .kw_potential, .kw_flow => {
                    const which: Ast.PotentialOrFlow =
                        if (self.peek() == .kw_potential) .potential else .flow;
                    self.pos += 1;
                    if (self.eat(.dot)) {
                        try overrides.append(self.arena, .{
                            .which = which,
                            .attr = try self.parseNatureAttr(),
                        });
                    } else {
                        const nature = try self.expectIdent();
                        _ = try self.expect(.semicolon);
                        if (which == .potential) d.potential = nature else d.flow = nature;
                    }
                },
                // §3.6.2.2 domain binding
                .kw_domain => {
                    self.pos += 1;
                    d.domain = switch (self.peek()) {
                        .kw_continuous => .continuous,
                        .kw_discrete => .discrete,
                        else => return self.failAt(self.pos, .E0212, "found {s}", .{self.found(self.pos)}),
                    };
                    self.pos += 1;
                    _ = try self.expect(.semicolon);
                },
                else => return self.failAt(self.pos, .E0213, "found {s}", .{self.found(self.pos)}),
            }
        }
        _ = try self.expect(.kw_enddiscipline);
        d.overrides = overrides.items;
        return d;
    }

    // -----------------------------------------------------------------------
    // A.6.4 analog_statement — LRM ch5
    // -----------------------------------------------------------------------

    /// One analog statement (A.6.4). `casex`/`casez` (annex C.7), digital
    /// `initial`/`always`, `fork`/`join`, `->`, `wait` and the procedural
    /// continuous assignments are NOT dispatched here: they fall through to the
    /// expression statement and report "expected expression", which is the
    /// annex C answer — they are not analog statements.
    pub fn parseStmt(self: *Parser) Error!Ast.StmtId {
        self.skipAttributes();
        const tok = self.pos;
        switch (self.peek()) {
            .semicolon => {
                self.pos += 1;
                return self.addStmt(.empty, tok);
            },
            .kw_begin => return self.parseSeqBlock(),
            .kw_if => { // §5.8 / A.6.6
                self.pos += 1;
                _ = try self.expect(.lparen);
                const cond = try self.parseExpr();
                _ = try self.expect(.rparen);
                const then_s = try self.parseStmt();
                const else_s: Ast.StmtId = if (self.eat(.kw_else))
                    try self.parseStmt()
                else
                    .none;
                return self.addStmt(
                    .{ .if_stmt = .{ .cond = cond, .then_s = then_s, .else_s = else_s } },
                    tok,
                );
            },
            .kw_case => return self.parseCase(), // §5.8.3 / A.6.7
            .kw_for => { // §5.9.2 / A.6.8 (also A.4.2 loop generate)
                self.pos += 1;
                _ = try self.expect(.lparen);
                const init_s = try self.parseAssignNoSemi();
                _ = try self.expect(.semicolon);
                const cond = try self.parseExpr();
                _ = try self.expect(.semicolon);
                const step = try self.parseAssignNoSemi();
                _ = try self.expect(.rparen);
                const body = try self.parseStmt();
                return self.addStmt(.{ .for_stmt = .{
                    .init = init_s,
                    .cond = cond,
                    .step = step,
                    .body = body,
                } }, tok);
            },
            .kw_while => { // §5.9.1
                self.pos += 1;
                _ = try self.expect(.lparen);
                const cond = try self.parseExpr();
                _ = try self.expect(.rparen);
                const body = try self.parseStmt();
                return self.addStmt(.{ .while_stmt = .{ .cond = cond, .body = body } }, tok);
            },
            .kw_repeat => { // §5.9
                self.pos += 1;
                _ = try self.expect(.lparen);
                const count = try self.parseExpr();
                _ = try self.expect(.rparen);
                const body = try self.parseStmt();
                return self.addStmt(.{ .repeat_stmt = .{ .count = count, .body = body } }, tok);
            },
            .at => return self.parseEventControl(), // §5.10 / A.6.5
            .kw_disable => { // §5.11
                self.pos += 1;
                const name = try self.expectIdent();
                _ = try self.expect(.semicolon);
                return self.addStmt(.{ .disable = .{ .name = name } }, tok);
            },
            .kw_return => { // A.6.5 jump_statement (§4.7.1)
                self.pos += 1;
                const value: Ast.ExprId = if (self.peek() == .semicolon)
                    .none
                else
                    try self.parseExpr();
                _ = try self.expect(.semicolon);
                return self.addStmt(.{ .jump = .{ .kind = .ret, .value = value } }, tok);
            },
            .kw_break, .kw_continue => {
                const kind: Ast.Stmt.JumpKind = if (self.peek() == .kw_break) .brk else .cont;
                self.pos += 1;
                _ = try self.expect(.semicolon);
                return self.addStmt(.{ .jump = .{ .kind = kind } }, tok);
            },
            // A.6.9 analog_system_task_enable (§5.12, ch9)
            .system_identifier => return self.parseSysTask(),
            else => return self.parseExprOrContributeStmt(),
        }
    }

    /// §5.3.2 / A.6.3 analog_seq_block. Local declarations are only legal on a
    /// named block; accepting them either way costs nothing and keeps the
    /// diagnostic for the real error (an undeclared name) in lowering.
    fn parseSeqBlock(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        self.pos += 1; // 'begin'
        var blk: Ast.SeqBlock = .{};
        if (self.eat(.colon)) blk.name = try self.expectIdent();

        var params: std.ArrayList(Ast.ParamDecl) = .empty;
        var vars: std.ArrayList(Ast.VarDecl) = .empty;
        while (true) {
            self.skipAttributes();
            switch (self.peek()) {
                .kw_parameter, .kw_localparam => {
                    try self.parseParamDecl(&params);
                    _ = try self.expect(.semicolon);
                },
                .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                    try self.parseVarDecl(&vars);
                    _ = try self.expect(.semicolon);
                },
                else => break,
            }
        }

        var body: std.ArrayList(Ast.StmtId) = .empty;
        while (self.peek() != .kw_end and self.peek() != .eof) {
            const before = self.pos;
            const s = self.parseStmt() catch |e| {
                try self.rethrowOom(e);
                if (self.pos == before) self.pos += 1;
                self.recoverStatement();
                continue;
            };
            try body.append(self.arena, s);
        }
        _ = try self.expect(.kw_end);

        blk.params = params.items;
        blk.vars = vars.items;
        blk.body = body.items;
        return self.addStmt(.{ .block = blk }, tok);
    }

    /// §5.8.3 / A.6.7 analog_case_statement. `casex`/`casez` are out of the
    /// analog subset (annex C.7) and never reach here.
    fn parseCase(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        self.pos += 1; // 'case'
        _ = try self.expect(.lparen);
        const scrutinee = try self.parseExpr();
        _ = try self.expect(.rparen);

        var arms: std.ArrayList(Ast.CaseArm) = .empty;
        while (self.peek() != .kw_endcase and self.peek() != .eof) {
            self.skipAttributes();
            var labels: std.ArrayList(Ast.ExprId) = .empty;
            if (self.eat(.kw_default)) {
                _ = self.eat(.colon); // A.6.7: `default [ : ]`
            } else {
                while (true) {
                    try labels.append(self.arena, try self.parseExpr());
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.colon);
            }
            const body = try self.parseStmt();
            try arms.append(self.arena, .{ .labels = labels.items, .body = body });
        }
        _ = try self.expect(.kw_endcase);
        return self.addStmt(
            .{ .case_stmt = .{ .scrutinee = scrutinee, .arms = arms.items } },
            tok,
        );
    }

    /// A.6.5 analog_event_control_statement (§5.10).
    fn parseEventControl(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        self.pos += 1; // '@'
        const event = if (self.eat(.lparen)) blk: {
            const e = try self.parseEventExpr();
            _ = try self.expect(.rparen);
            break :blk e;
        } else blk: {
            // `@ hierarchical_event_identifier`
            const id_tok = self.pos;
            const name = try self.expectIdent();
            break :blk try self.addExpr(.{ .tag = .ident, .main_tok = id_tok, .str = name });
        };
        const body = try self.parseStmt();
        return self.addStmt(.{ .event_control = .{ .event = event, .body = body } }, tok);
    }

    /// A.6.5 analog_event_expression — `or` and `,` both build `.event_or`
    /// (§4.2.2 puts them at the `||` precedence level, below everything else).
    fn parseEventExpr(self: *Parser) Error!Ast.ExprId {
        var lhs = try self.parseEventTerm();
        while (self.peek() == .kw_or or self.peek() == .comma) {
            const tok = self.pos;
            self.pos += 1;
            const rhs = try self.parseEventTerm();
            lhs = try self.addExpr(.{
                .tag = .event_or,
                .main_tok = tok,
                .lhs = lhs,
                .rhs = rhs,
            });
        }
        return lhs;
    }

    /// §5.10.2 step events carry a list of *analysis name strings*, not
    /// expressions (A.6.5); everything else is an ordinary expression —
    /// `cross`/`above`/`timer`/`absdelta` become `.event_function` in
    /// `parsePrimary`.
    fn parseEventTerm(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        const tag: Ast.ExprTag = switch (self.peek()) {
            .kw_initial_step => .event_initial_step,
            .kw_final_step => .event_final_step,
            else => return self.parseExpr(),
        };
        self.pos += 1;
        var names: std.ArrayList(Ast.StrId) = .empty;
        if (self.eat(.lparen)) {
            if (self.peek() != .rparen) while (true) {
                const s = try self.expect(.string_literal);
                try names.append(self.arena, try self.internString(s));
                if (!self.eat(.comma)) break;
            };
            _ = try self.expect(.rparen);
        }
        const off = try self.file.exprs.addStrList(self.arena, names.items);
        return self.addExpr(.{ .tag = tag, .main_tok = tok, .extra = off });
    }

    /// A.6.9 `$task [ ( [expr] {, [expr]} ) ] ;` — ch9 system tasks. The name
    /// keeps its `$` so lowering reports it the way the user wrote it.
    fn parseSysTask(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        const name = try self.internTok(tok);
        self.pos += 1;
        var args: []const Ast.ExprId = &.{};
        if (self.peek() == .lparen) args = try self.parseCallArgs();
        _ = try self.expect(.semicolon);
        return self.addStmt(.{ .sys_task = .{ .name = name, .args = args } }, tok);
    }

    /// Contribution vs procedural-assignment disambiguation. LRM §5.6, §5.7.
    /// One expression is parsed first (`<+`, `=` and `:` all bind looser than
    /// every operator in Table 4-3), then the operator decides the statement.
    pub fn parseExprOrContributeStmt(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        const lhs = try self.parseExpr();
        switch (self.peek()) {
            .contribute => { // §5.6 / A.6.10
                self.pos += 1;
                const rhs = try self.parseExpr();
                _ = try self.expect(.semicolon);
                return self.addStmt(.{ .contribute = .{ .lhs = lhs, .rhs = rhs } }, tok);
            },
            .assign_eq => { // §5.7 / A.6.2
                self.pos += 1;
                const value = try self.parseExpr();
                _ = try self.expect(.semicolon);
                return self.addStmt(.{ .assign = .{ .target = lhs, .value = value } }, tok);
            },
            .colon => { // §5.6.7 / A.6.10 indirect contribution
                self.pos += 1;
                const probe = try self.parsePrimary();
                _ = try self.expect(.eq_eq);
                const eqn = try self.parseExpr();
                _ = try self.expect(.semicolon);
                return self.addStmt(
                    .{ .indirect = .{ .lhs = lhs, .probe = probe, .eqn = eqn } },
                    tok,
                );
            },
            else => return self.failAt(self.pos, .E0214, "found {s}", .{self.found(self.pos)}),
        }
    }

    /// A.6.8 `for` header assignment — an analog_variable_assignment with no
    /// terminating `;`.
    fn parseAssignNoSemi(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        const target = try self.parseExpr();
        _ = try self.expect(.assign_eq);
        const value = try self.parseExpr();
        return self.addStmt(.{ .assign = .{ .target = target, .value = value } }, tok);
    }

    // -----------------------------------------------------------------------
    // A.8.3 expressions — LRM §4.1, §4.2 (precedence climbing)
    // -----------------------------------------------------------------------

    /// Full expression, conditional operator included. LRM §4.1, §4.2.
    pub fn parseExpr(self: *Parser) Error!Ast.ExprId {
        return self.parseExprPrec(prec_ternary);
    }

    /// Precedence climbing over LRM Table 4-3 (§4.2.2). Everything associates
    /// left to right except `?:` (§4.2.12) and `**`, which are right-assoc.
    fn parseExprPrec(self: *Parser, min_prec: u8) Error!Ast.ExprId {
        var lhs = try self.parseUnary();
        while (true) {
            const t = self.peek();
            // §4.2.12 conditional — lowest precedence, right associative.
            if (t == .question and min_prec <= prec_ternary) {
                const tok = self.pos;
                self.pos += 1;
                self.skipAttributes();
                const then_e = try self.parseExpr();
                _ = try self.expect(.colon);
                const else_e = try self.parseExprPrec(prec_ternary);
                lhs = try self.addExpr(.{
                    .tag = .ternary,
                    .main_tok = tok,
                    .lhs = lhs,
                    .rhs = then_e,
                    .extra = @intFromEnum(else_e),
                });
                continue;
            }
            const prec = binopPrec(t);
            if (prec == 0 or prec < min_prec) return lhs;
            const tok = self.pos;
            self.pos += 1;
            self.skipAttributes(); // A.8.3 `binary_operator { attribute_instance }`
            // §4.2.2: "All operators associate left to right with the exception
            // of the conditional operator which associates right to left."
            // There is no `**` carve-out — §4.2.12 names `?:` as the only
            // right-associative operator, and `?:` is handled above, not here.
            // `**` used to be excepted, which made `2**3**2` 512 instead of 64.
            const rhs = try self.parseExprPrec(prec + 1);
            lhs = try self.addExpr(.{
                .tag = .binary,
                .main_tok = tok,
                .lhs = lhs,
                .rhs = rhs,
                .extra = @intFromEnum(binOp(t)),
            });
        }
    }

    /// A.8.6 unary_operator (§4.2.1, §4.2.7–§4.2.10). Unary binds tighter than
    /// every binary operator (Table 4-3, top row).
    fn parseUnary(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        const op: Ast.UnaryOp = switch (self.peek()) {
            .plus => .plus,
            .minus => .minus,
            .bang => .logical_not,
            .tilde => .bit_not,
            .amp => .reduce_and,
            .tilde_amp => .reduce_nand,
            .pipe => .reduce_or,
            .tilde_pipe => .reduce_nor,
            // §4.2.10 reduction xor has no analog meaning and `^` is also the
            // binary xor lexeme; reject it where it is written.
            .caret, .tilde_caret, .caret_tilde => return self.failAt(
                self.pos,
                .E0215,
                "found {s}",
                .{self.found(self.pos)},
            ),
            else => return self.parsePostfix(),
        };
        self.pos += 1;
        self.skipAttributes(); // A.8.3 `unary_operator { attribute_instance }`
        const operand = try self.parseUnary();
        return self.addExpr(.{
            .tag = .unary,
            .main_tok = tok,
            .lhs = operand,
            .extra = @intFromEnum(op),
        });
    }

    /// §3.2.2/§3.4.4 array and part selects: `base[i]`, `base[msb:lsb]`.
    fn parsePostfix(self: *Parser) Error!Ast.ExprId {
        var e = try self.parsePrimary();
        while (self.peek() == .lbracket) {
            const tok = self.pos;
            self.pos += 1;
            var idx = try self.parseExpr();
            if (self.eat(.colon)) { // A.8.3 analog_range_expression
                const lsb = try self.parseExpr();
                idx = try self.addExpr(.{
                    .tag = .range,
                    .main_tok = tok,
                    .lhs = idx,
                    .rhs = lsb,
                });
            }
            _ = try self.expect(.rbracket);
            e = try self.addExpr(.{ .tag = .index, .main_tok = tok, .lhs = e, .rhs = idx });
        }
        return e;
    }

    /// A.8.4 analog_primary.
    pub fn parsePrimary(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        // §10.6: a keyword the active set does not reserve is just a name, so
        // `sin` under "1364-2005" reads as a variable, not as §4.3.2's builtin.
        // (`tokenText` still switches on the real tag, so the spelling is exact.)
        const t = if (self.identLike(tok)) token.Tag.identifier else self.peek();
        switch (t) {
            .int_literal, .real_literal => return self.parseNumber(),
            .string_literal => { // §2.7
                const s = try self.internString(tok);
                self.pos += 1;
                return self.addExpr(.{ .tag = .str_literal, .main_tok = tok, .str = s });
            },
            .lparen => {
                self.pos += 1;
                const e = try self.parseExpr();
                _ = try self.expect(.rparen);
                return e;
            },
            // §4.2.13 / A.8.1 analog_concatenation
            .lbrace => {
                self.pos += 1;
                var items: std.ArrayList(Ast.ExprId) = .empty;
                if (self.peek() != .rbrace) while (true) {
                    try items.append(self.arena, try self.parseExpr());
                    if (!self.eat(.comma)) break;
                };
                // ponytail: `{n{...}}` (analog_multiple_concatenation) is not
                // in the analog subset — `Ast.ExprTag.multi_concat` is ready if
                // that ever changes.
                _ = try self.expect(.rbrace);
                if (try self.foldBitConcat(tok, items.items)) |folded| return folded;
                const off = try self.file.exprs.addExprList(self.arena, items.items);
                return self.addExpr(.{ .tag = .concat, .main_tok = tok, .extra = off });
            },
            // A.8.1 assignment_pattern `'{ ... }` (§3.4.4 array defaults,
            // §4.5.6 filter coefficient args)
            .apostrophe_lbrace => {
                self.pos += 1;
                var items: std.ArrayList(Ast.ExprId) = .empty;
                if (self.peek() != .rbrace) while (true) {
                    try items.append(self.arena, try self.parseExpr());
                    if (!self.eat(.comma)) break;
                };
                _ = try self.expect(.rbrace);
                const off = try self.file.exprs.addExprList(self.arena, items.items);
                return self.addExpr(.{ .tag = .assign_pattern, .main_tok = tok, .extra = off });
            },
            .identifier, .escaped_identifier => {
                const text = self.tokenText(tok);
                const name = try self.file.intern(self.arena, text);
                self.pos += 1;
                if (self.peek() == .lparen) {
                    // §4.4 branch probe vs §4.7 user function: only a declared
                    // nature access name (§3.6.1.4) probes a branch.
                    if (self.access_names.contains(text)) {
                        return self.parseAccess(name, tok);
                    }
                    const args = try self.parseCallArgs();
                    const off = try self.file.exprs.addExprList(self.arena, args);
                    return self.addExpr(.{
                        .tag = .call,
                        .main_tok = tok,
                        .extra = off,
                        .str = name,
                    });
                }
                return self.addExpr(.{ .tag = .ident, .main_tok = tok, .str = name });
            },
            // §2.8.3 / A.8.2 analog_system_function_call (ch9). `$name` with no
            // argument list is the same tag with an empty list.
            .system_identifier => {
                const name = try self.internTok(tok);
                self.pos += 1;
                const args: []const Ast.ExprId = if (self.peek() == .lparen)
                    try self.parseCallArgs()
                else
                    &.{};
                const off = try self.file.exprs.addExprList(self.arena, args);
                return self.addExpr(.{
                    .tag = .sys_call,
                    .main_tok = tok,
                    .extra = off,
                    .str = name,
                });
            },
            // A.2.5 value_range_expression `inf` (only meaningful in §3.4.2).
            .kw_inf => {
                self.pos += 1;
                return self.addExpr(.{ .tag = .pos_inf, .main_tok = tok });
            },
            else => {},
        }

        // Keyword-named calls. The four groups are disjoint by construction
        // (token.zig's annex A.8.2/A.6.5 test) and map 1:1 onto ExprTag.
        const call_tag: Ast.ExprTag = if (token.isMathFunction(t))
            .builtin_call // §4.3
        else if (token.isFilterFunction(t))
            .filter_call // §4.5
        else if (token.isSmallSignalFunction(t))
            .noise_call // §4.6
        else if (token.isEventFunction(t))
            .event_function // §5.10.3
        else if (t == .kw_analysis)
            .sys_call // §4.6.1 analysis_function_call
        else if (t == .kw_initial_step or t == .kw_final_step)
            return self.parseEventTerm() // §5.10.2
        else
            return self.failAt(self.pos, .E0209, "found {s}", .{self.found(self.pos)});

        const name = try self.file.intern(self.arena, token.Tag.lexeme(t).?);
        self.pos += 1;
        const args = try self.parseCallArgs();
        const off = try self.file.exprs.addExprList(self.arena, args);
        return self.addExpr(.{
            .tag = call_tag,
            .main_tok = tok,
            .extra = off,
            .str = name,
        });
    }

    /// §4.4.1 branch_probe_function_call / §4.4.2 port_probe_function_call
    /// (A.8.2). `V(a)`, `V(a,b)`, `I(br)`, `I(<p>)`.
    fn parseAccess(self: *Parser, name: Ast.StrId, tok: u32) Error!Ast.ExprId {
        _ = try self.expect(.lparen);
        if (self.eat(.lt)) { // §5.4.3 port branch `I(<p>)`
            const port = try self.parseNetRef();
            _ = try self.expect(.gt);
            _ = try self.expect(.rparen);
            return self.addExpr(.{
                .tag = .port_access,
                .main_tok = tok,
                .lhs = port,
                .str = name,
            });
        }
        const hi = try self.parseNetRef();
        var lo: Ast.ExprId = .none;
        if (self.eat(.comma)) lo = try self.parseNetRef();
        _ = try self.expect(.rparen);
        return self.addExpr(.{
            .tag = .branch_access,
            .main_tok = tok,
            .lhs = hi,
            .rhs = lo,
            .str = name,
        });
    }

    /// A.8.9 / A.2.1.3 branch terminal: a plain net or branch identifier.
    ///
    /// ponytail: no hierarchical (`u.n`), `$root`, nature-attribute
    /// (`p.potential.abstol`) or vector (`p[0]`) references — all of them need
    /// an elaborated instance tree or vector nets, neither of which exists.
    /// `Ast.ExprTag.hier_ident` is the shape to fill when they do.
    fn parseNetRef(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        const name = try self.expectIdent();
        return self.addExpr(.{ .tag = .ident, .main_tok = tok, .str = name });
    }

    /// A.8.2 / A.6.9 argument list. An omitted argument (`f(a, , c)`, and the
    /// empty filter/task slots the grammar allows) becomes `.none`, so lowering
    /// can apply the per-function defaults instead of guessing arity.
    fn parseCallArgs(self: *Parser) Error![]const Ast.ExprId {
        _ = try self.expect(.lparen);
        var items: std.ArrayList(Ast.ExprId) = .empty;
        if (self.peek() != .rparen) {
            while (true) {
                if (self.peek() == .comma or self.peek() == .rparen) {
                    try items.append(self.arena, .none);
                } else {
                    try items.append(self.arena, try self.parseExpr());
                }
                if (!self.eat(.comma)) break;
            }
        }
        _ = try self.expect(.rparen);
        return items.items;
    }

    /// Operator precedence. LRM §4.2.2 Table 4-3, highest binds tightest.
    /// 0 = not a binary operator.
    fn binopPrec(tag: token.Tag) u8 {
        return switch (tag) {
            .star_star => 12,
            .star, .slash, .percent => 11,
            .plus, .minus => 10,
            .lt_lt, .gt_gt, .lt_lt_lt, .gt_gt_gt => 9,
            .lt, .lt_eq, .gt, .gt_eq => 8,
            .eq_eq, .bang_eq, .eq_eq_eq, .bang_eq_eq => 7,
            .amp => 6,
            .caret, .caret_tilde, .tilde_caret => 5,
            .pipe => 4,
            .amp_amp => 3,
            .pipe_pipe => 2,
            else => 0,
        };
    }

    /// §4.2.12 `?:` sits below every binary operator (Table 4-3, last row).
    const prec_ternary: u8 = 1;

    /// A.8.6 binary_operator → `Ast.BinaryOp`. `===`/`!==`/`<<<`/`>>>` are
    /// mapped, not rejected: annex C.5 rejection is lowering's message.
    fn binOp(tag: token.Tag) Ast.BinaryOp {
        return switch (tag) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            .star_star => .pow,
            .eq_eq => .eq,
            .bang_eq => .neq,
            .eq_eq_eq => .case_eq,
            .bang_eq_eq => .case_neq,
            .lt => .lt,
            .lt_eq => .le,
            .gt => .gt,
            .gt_eq => .ge,
            .amp_amp => .logical_and,
            .pipe_pipe => .logical_or,
            .amp => .bit_and,
            .pipe => .bit_or,
            .caret => .bit_xor,
            .caret_tilde, .tilde_caret => .bit_xnor,
            .lt_lt => .shl,
            .gt_gt => .shr,
            .lt_lt_lt => .ashl,
            .gt_gt_gt => .ashr,
            else => unreachable,
        };
    }

    // -----------------------------------------------------------------------
    // Literals — LRM §2.6 numbers, §2.7 strings, §2.8 identifiers
    // -----------------------------------------------------------------------

    /// §2.6.1 integer (incl. sized/based) and §2.6.2 real (exponent + SI scale
    /// factor) literals. Values are computed here because the token stream
    /// stores only {tag,start}.
    fn parseNumber(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        const text = self.tokenText(tok);
        self.pos += 1;

        if (self.tags[tok] == .int_literal) {
            // §2.6.1 decoding — size truncation, the `s` two's-complement form
            // and `_` — lives in `lexer.parseInt` so there is exactly ONE
            // decoder. A second one here silently returned 65535 for `8'hFFFF`
            // and 15 for `4'shf`.
            const lit = lexer.parseInt(text) catch |e| return switch (e) {
                error.FourStateDigit => blk: {
                    var d = self.failWith(tok, .E0130);
                    d.msg("`{s}`", .{text});
                    d.help("the analog subset has no four-state value to hold x or z", .{});
                    try d.emit();
                    break :blk error.ParseError;
                },
                error.MissingBase => self.failAt(tok, .E0131, "`{s}`", .{text}),
                error.MissingDigits => self.failAt(tok, .E0132, "`{s}`", .{text}),
                else => self.failAt(tok, .E0133, "`{s}`", .{text}),
            };
            // `lexer.parseInt` already applied the constant's own width (§2.6.1)
            // — a sized literal is masked to its `size`, an unsized one to the
            // implementation's integer width. Re-truncating to 32 here is what
            // made `4294967296` lower to 0 while the MIR, codegen and the device
            // contract all carry an `i64`; §2.5.1 only requires "at least 32".
            // Pinned by tests/fixtures/exhaustive/122_bit_conversions.va.
            return self.file.exprs.addInt(self.arena, tok, lit.value);
        }

        var buf: [128]u8 = undefined;
        if (text.len > buf.len) {
            return self.failAt(tok, .E0134, "", .{});
        }
        // §2.6: underscores are ignored everywhere in a number.
        var n: usize = 0;
        for (text) |c| {
            if (c == '_') continue;
            buf[n] = c;
            n += 1;
        }
        const clean = buf[0..n];

        // §2.6.2 real: optional trailing scale factor.
        var mantissa = clean;
        var scale: f64 = 1.0;
        if (n > 0) if (siScale(clean[n - 1])) |s| {
            scale = s;
            mantissa = clean[0 .. n - 1];
        };
        const v = std.fmt.parseFloat(f64, mantissa) catch
            return self.failAt(tok, .E0133, "`{s}`", .{text});
        return self.file.exprs.addReal(self.arena, tok, v * scale);
    }

    /// §4.2.13 integer concatenation. "Unsized constant numbers shall not be
    /// allowed in concatenations. This is because the size of each operand in
    /// the concatenation is needed to calculate the complete size" — so the
    /// operation is only defined for operands that carry a width, and the ONLY
    /// Verilog-A expression that carries one is a §2.6.1 sized constant. (A
    /// variable could not help: §3.2.1 makes `integer` 32 bits, so two of them
    /// already overflow the result type.) Widths exist only here — the AST
    /// keeps a decoded value, not a literal's size — so the join happens here
    /// and the folded constant is what lowering sees.
    ///
    /// Returns null when no operand is sized, which leaves `{a, b}` as a
    /// `.concat` node for the paths that (mis)use brace lists for §4.5.11
    /// filter coefficients and §3.2.2 array assignment, and for the §3.3
    /// Table 3-3 string form that lowering folds.
    fn foldBitConcat(self: *Parser, tok: u32, items: []const Ast.ExprId) Error!?Ast.ExprId {
        const ex = &self.file.exprs;
        var any_sized = false;
        for (items) |it| {
            if (ex.tag(it) != .int_literal) continue;
            if (self.sizedLit(ex.mainTok(it)) != null) any_sized = true;
        }
        if (!any_sized) return null;

        var acc: u64 = 0;
        var total: u64 = 0;
        for (items) |it| {
            const lit = if (ex.tag(it) == .int_literal)
                self.sizedLit(ex.mainTok(it))
            else
                null;
            const l = lit orelse {
                var d = self.failWith(ex.mainTok(it), .E0216);
                d.help("give the operand a width, e.g. `8'd5`", .{});
                try d.emit();
                return error.ParseError;
            };
            total += l.width;
            // §3.2.1: the result is an integer, which is 32-bit. Wrapping it
            // silently would corrupt the value, so it is diagnosed.
            if (total > 32) return self.failAt(tok, .E0217, "at least {d} bits wide", .{total});
            const mask: u64 = (@as(u64, 1) << @intCast(l.width)) - 1;
            acc = (acc << @intCast(l.width)) | (@as(u64, @bitCast(l.value)) & mask);
        }
        return try ex.addInt(self.arena, tok, @bitCast(acc));
    }

    /// The §2.6.1 decode of `tok` when it is a SIZED constant, else null.
    /// `parseNumber` already reported any malformed literal, so a decode error
    /// here just means "not usable as a concatenation operand".
    fn sizedLit(self: *const Parser, tok: u32) ?lexer.IntLiteral {
        if (self.tags[tok] != .int_literal) return null;
        const lit = lexer.parseInt(self.tokenText(tok)) catch return null;
        return if (lit.width == 0) null else lit;
    }

    /// §2.7 string literal contents, with escapes processed. Only allocates
    /// when the literal actually contains a backslash.
    fn internString(self: *Parser, tok: u32) Error!Ast.StrId {
        const raw = self.tokenText(tok);
        const body = if (raw.len >= 2) raw[1 .. raw.len - 1] else "";
        if (std.mem.indexOfScalar(u8, body, '\\') == null) {
            return self.file.intern(self.arena, body);
        }
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] != '\\' or i + 1 == body.len) {
                try out.append(self.arena, body[i]);
                continue;
            }
            i += 1;
            try out.append(self.arena, switch (body[i]) {
                'n' => '\n',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                else => body[i],
            });
        }
        return self.file.intern(self.arena, out.items);
    }

    /// Source text of a token. `token.Stored` has no length (DOD: recompute,
    /// don't store), so the lexeme is re-scanned from `start` — the tag says
    /// which scanner to use, so this is a switch, not a re-lex.
    fn tokenText(self: *const Parser, i: u32) []const u8 {
        const start = self.starts[i];
        const src = self.src;
        return switch (self.tags[i]) {
            // §2.8 / §2.8.3
            .identifier, .system_identifier, .kw_reserved => src[start..scanIdentEnd(src, start)],
            // §2.8.1 escaped identifier: `\` then non-whitespace; the `\` is
            // not part of the name.
            .escaped_identifier => blk: {
                var e = start + 1;
                while (e < src.len and !std.ascii.isWhitespace(src[e])) e += 1;
                break :blk src[start + 1 .. e];
            },
            .int_literal, .real_literal => src[start..scanNumberEnd(src, start)],
            .string_literal => blk: {
                var e = start + 1;
                while (e < src.len and src[e] != '"') : (e += 1) {
                    if (src[e] == '\\' and e + 1 < src.len) e += 1;
                }
                break :blk src[start..@min(e + 1, src.len)];
            },
            else => |t| token.Tag.lexeme(t) orelse src[start..@min(start + 1, src.len)],
        };
    }

    // -----------------------------------------------------------------------
    // Token access — LRM §2.2 (the stream), §2.8 (identifiers)
    // -----------------------------------------------------------------------

    fn peek(self: *const Parser) token.Tag {
        return self.tags[self.pos];
    }

    fn peekAt(self: *const Parser, n: u32) token.Tag {
        const i = self.pos + n;
        return self.tags[@min(i, self.tags.len - 1)];
    }

    fn eat(self: *Parser, t: token.Tag) bool {
        if (self.peek() != t) return false;
        self.pos += 1;
        return true;
    }

    /// Byte just past the previous token: where a missing terminator has to be
    /// typed, and so where `expect`'s machine-applicable insertion is anchored.
    ///
    /// `token.Stored` carries no length (DOD: recompute, don't store), so the
    /// lexeme is measured. Two tags need care: `tokenText` strips the `\` of an
    /// escaped identifier from the NAME though it is part of the source span,
    /// and `.eof` has no text at all.
    fn endOfPrev(self: *const Parser) u32 {
        if (self.pos == 0) return self.starts[0];
        const i = self.pos - 1;
        if (self.tags[i] == .eof) return self.starts[i];
        const backslash: u32 = @intFromBool(self.tags[i] == .escaped_identifier);
        return self.starts[i] + backslash + @as(u32, @intCast(self.tokenText(i).len));
    }

    fn expect(self: *Parser, t: token.Tag) Error!u32 {
        if (self.peek() != t) {
            // The title is only "unexpected token", so the caret carries what
            // the grammar wanted here.
            var d = self.failWith(self.pos, .E0207);
            d.msg("found {s}", .{self.found(self.pos)});
            d.point("expected {s}", .{tagDesc(t)});
            // A missing TERMINATOR is never missing where it is reported: the
            // previous construct ended, nobody wrote the token, and the caret
            // lands on whatever came next — often on the following line. E0207's
            // own `--explain` says so ("look at the end of the previous
            // statement first"); the machine-applicable fix says it in the one
            // place a reader is already looking, and points at the column where
            // the character has to be typed.
            if (isTerminator(t)) if (token.Tag.lexeme(t)) |text| {
                const at = self.endOfPrev();
                d.suggest(
                    .{ .span = .{ .start = at, .end = at }, .replacement = text },
                    "insert `{s}` after the previous {s}",
                    .{ text, if (t == .semicolon) "statement" else "item" },
                );
            };
            try d.emit();
            return error.ParseError;
        }
        const i = self.pos;
        self.pos += 1;
        return i;
    }

    /// Can the token at `i` stand where the grammar wants an identifier?
    ///
    /// §2.8/§2.8.1 identifiers always can. So can a KEYWORD that the active
    /// §10.6 keyword set does not reserve: "the version_specifier specifies
    /// the valid set of reserved keywords in effect when a design unit is
    /// parsed", and §10.6's worked example turns exactly on this — under
    /// `begin_keywords "1364-2005", `input sin;` is "OK since sin is not a
    /// keyword in 1364-2005". §10.6 also says the directive does "not affect
    /// the … tokens", which is why this is a parser rule and not a lexer one:
    /// `analog` stays `kw_analog` in the very same module.
    ///
    /// Escaped identifiers (§2.8.1) never reach `keyword_map` in the first
    /// place, so nothing is applied to them twice.
    fn identLike(self: *const Parser, i: u32) bool {
        const j = @min(i, self.tags.len - 1);
        return switch (self.tags[j]) {
            .identifier, .escaped_identifier => true,
            // Default set ⇒ every keyword is reserved: no text to fetch.
            else => |t| self.kw_set != token.default_keyword_set and
                token.isKeyword(t) and
                !token.isReserved(self.tokenText(j), self.kw_set),
        };
    }

    /// §2.8/§2.8.1 identifier or escaped identifier, interned.
    fn expectIdent(self: *Parser) Error!Ast.StrId {
        if (!self.identLike(self.pos))
            return self.failAt(self.pos, .E0208, "found {s}", .{self.found(self.pos)});
        const s = try self.internTok(self.pos);
        self.pos += 1;
        return s;
    }

    fn internTok(self: *Parser, i: u32) Error!Ast.StrId {
        return self.file.intern(self.arena, self.tokenText(i));
    }

    fn addExpr(self: *Parser, node: Ast.Node) Error!Ast.ExprId {
        return self.file.exprs.add(self.arena, node);
    }

    fn addStmt(self: *Parser, s: Ast.Stmt, main_tok: u32) Error!Ast.StmtId {
        return self.file.addStmt(self.arena, s, main_tok);
    }

    /// §2.9 attribute_instance. Parsed and skipped; `Ast.NatureAttr` is the
    /// shape to capture into if desc/units ever need to reach the host.
    fn skipAttributes(self: *Parser) void {
        while (self.peek() == .attr_open) {
            self.pos += 1;
            while (true) : (self.pos += 1) switch (self.peek()) {
                .eof => return,
                .attr_close => {
                    self.pos += 1;
                    break;
                },
                else => {},
            };
        }
    }

    /// Resynchronize after a bad statement or module item: past the next `;`,
    /// or up to a keyword that closes the enclosing construct.
    fn recoverStatement(self: *Parser) void {
        while (true) : (self.pos += 1) switch (self.peek()) {
            .eof,
            .kw_end,
            .kw_endmodule,
            .kw_endfunction,
            .kw_endgenerate,
            .kw_endcase,
            .kw_endnature,
            .kw_enddiscipline,
            .kw_analog,
            => return,
            .semicolon => {
                self.pos += 1;
                return;
            },
            else => {},
        };
    }

    // -----------------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------------

    fn failAt(self: *Parser, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error {
        self.failed = true;
        const span = lexer.tokenSpan(self.src, self.starts, tok);
        if (tok < self.tags.len and self.tags[tok] == .invalid) {
            if (try self.failRunawayString(span)) return error.ParseError;
        }
        try self.bag.add(.parse, code, span, fmt, args);
        return error.ParseError;
    }

    /// §2.7: a string that runs off its line reaches the parser as one
    /// `.invalid` token, and whichever context happens to catch it says only
    /// "found invalid token" — naming neither the rule nor the fix. Handled in
    /// the funnel rather than at the `.E0209` call site because the same token
    /// is equally reachable from statement and module-item position.
    /// Returns true when it emitted; the classification lives in
    /// `lexer.stringRunaway`.
    fn failRunawayString(self: *Parser, span: diag.Span) Error!bool {
        const kind = lexer.stringRunaway(self.src, span);
        if (kind == .none) return false;

        var d = self.bag.build(.parse, .E0138, span);
        d.point("this literal is still open at the end of the line", .{});
        if (kind == .line_continuation) {
            d.note(
                "the trailing `\\` is an IEEE 1800 SystemVerilog continuation (§5.9); " ++
                    "Verilog-AMS derives from IEEE 1364-2005, which has no such escape",
                .{},
            );
        }
        d.help("keep the literal on one line — `\\n` inside it is what breaks the output", .{});
        try d.emit();
        return true;
    }

    /// Same diagnostic, opened for a label / note / suggestion. The call site
    /// still has to `return error.ParseError` after `emit`.
    fn failWith(self: *Parser, tok: u32, code: diag.Code) diag.Builder {
        self.failed = true;
        return self.bag.build(.parse, code, lexer.tokenSpan(self.src, self.starts, tok));
    }

    /// OOM is never recoverable; ParseError is. Used at every recovery point.
    fn rethrowOom(self: *Parser, e: Error) Error!void {
        _ = self;
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => {},
        }
    }

    /// Human name of the token at `i`, for the "found ..." half of a message.
    fn found(self: *const Parser, i: u32) []const u8 {
        return switch (self.tags[i]) {
            .eof => "end of file",
            .invalid => "invalid token",
            .identifier,
            .escaped_identifier,
            .system_identifier,
            .int_literal,
            .real_literal,
            .string_literal,
            .kw_reserved,
            => self.tokenText(i),
            else => |t| tagDesc(t),
        };
    }
};

/// Name of an expected token in a diagnostic.
///
/// Punctuation is spelled as the CHARACTER the user has to type, in backticks:
/// "expected `)`" is a repair instruction, "expected r_paren" is a puzzle about
/// our `token.Tag` field names. The categories that have no fixed spelling stay
/// prose. `token.Tag.lexeme` is the single source for every spelling, so an
/// operator added there needs no entry here.
fn tagDesc(t: token.Tag) []const u8 {
    return switch (t) {
        .eof => "end of file",
        .invalid => "invalid token",
        .identifier, .escaped_identifier => "an identifier",
        .system_identifier => "a system task or function name",
        .int_literal => "an integer literal",
        .real_literal => "a real literal",
        .string_literal => "a string literal",
        .kw_reserved => "a reserved keyword",
        else => token.Tag.quoted(t) orelse @tagName(t),
    };
}

/// Tokens that CLOSE something: when one is missing, the place to type it is
/// the end of the construct before it, not the token the parser choked on.
/// Drives the machine-applicable insertion in `expect`.
fn isTerminator(t: token.Tag) bool {
    return switch (t) {
        .semicolon, .comma, .rparen, .rbracket, .rbrace => true,
        else => false,
    };
}

/// §2.8 identifier body: letters, digits, `_` and `$`.
fn scanIdentEnd(src: []const u8, start: u32) u32 {
    var i = start;
    if (i < src.len and (src[i] == '$' or src[i] == '`')) i += 1;
    while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_' or src[i] == '$')) {
        i += 1;
    }
    return i;
}

/// §2.6.1 / §2.6.2 number lexeme end: `[size] ' [s] base digits`, or decimal
/// with an optional fraction and an optional exponent OR SI scale factor.
fn scanNumberEnd(src: []const u8, start: u32) u32 {
    var i = start;
    while (i < src.len and (std.ascii.isDigit(src[i]) or src[i] == '_')) i += 1;
    if (i < src.len and src[i] == '\'') {
        i += 1;
        if (i < src.len and (src[i] == 's' or src[i] == 'S')) i += 1;
        if (i < src.len) i += 1; // base character
        while (i < src.len and (std.ascii.isHex(src[i]) or src[i] == '_' or
            src[i] == 'x' or src[i] == 'X' or src[i] == 'z' or src[i] == 'Z' or src[i] == '?'))
        {
            i += 1;
        }
        return i;
    }
    if (i + 1 < src.len and src[i] == '.' and std.ascii.isDigit(src[i + 1])) {
        i += 1;
        while (i < src.len and (std.ascii.isDigit(src[i]) or src[i] == '_')) i += 1;
    }
    if (i < src.len and (src[i] == 'e' or src[i] == 'E')) {
        var j = i + 1;
        if (j < src.len and (src[j] == '+' or src[j] == '-')) j += 1;
        if (j < src.len and std.ascii.isDigit(src[j])) {
            while (j < src.len and std.ascii.isDigit(src[j])) j += 1;
            return j;
        }
    }
    if (i < src.len and siScale(src[i]) != null) i += 1;
    return i;
}

/// §2.6.2 scale_factor ::= T | G | M | K | k | m | u | n | p | f | a
fn siScale(c: u8) ?f64 {
    return switch (c) {
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
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Self-check. A throwaway lexer (enough of §2.5–§2.8 for these sources) drives
// the real parser, so the check exercises the grammar, not a mock.
// ---------------------------------------------------------------------------

const TestLex = struct {
    tags: std.ArrayList(token.Tag) = .empty,
    starts: std.ArrayList(u32) = .empty,

    /// Longest-match symbol table, derived from `Tag.lexeme` so it can never
    /// drift from token.zig.
    const symbols = blk: {
        @setEvalBranchQuota(20_000);
        const fields = @typeInfo(token.Tag).@"enum".fields;
        var list: [fields.len]struct { []const u8, token.Tag } = undefined;
        var n = 0;
        for (fields) |f| {
            const t: token.Tag = @enumFromInt(f.value);
            if (token.isKeyword(t)) continue;
            const lex = token.Tag.lexeme(t) orelse continue;
            list[n] = .{ lex, t };
            n += 1;
        }
        // Longest first, so `<+` beats `<` and `**` beats `*`.
        var out = list[0..n].*;
        for (0..out.len) |a| for (a + 1..out.len) |b| {
            if (out[b][0].len > out[a][0].len) {
                const tmp = out[a];
                out[a] = out[b];
                out[b] = tmp;
            }
        };
        const frozen = out;
        break :blk frozen;
    };

    fn run(gpa: std.mem.Allocator, src: []const u8) !TestLex {
        var self: TestLex = .{};
        var i: u32 = 0;
        outer: while (i < src.len) {
            if (std.ascii.isWhitespace(src[i])) {
                i += 1;
                continue;
            }
            if (std.mem.startsWith(u8, src[i..], "//")) {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (std.mem.startsWith(u8, src[i..], "/*")) {
                i += 2;
                while (i + 1 < src.len and !std.mem.startsWith(u8, src[i..], "*/")) i += 1;
                i = @min(i + 2, @as(u32, @intCast(src.len)));
                continue;
            }
            if (src[i] == '\\') { // §2.8.1 escaped identifier
                const esc = i;
                i += 1;
                while (i < src.len and !std.ascii.isWhitespace(src[i])) i += 1;
                try self.push(gpa, .escaped_identifier, esc);
                continue;
            }
            const start = i;
            if (std.ascii.isDigit(src[i])) {
                i = scanNumberEnd(src, i);
                const text = src[start..i];
                const is_real = std.mem.indexOfScalar(u8, text, '\'') == null and
                    (std.mem.indexOfAny(u8, text, ".eE") != null or siScale(text[text.len - 1]) != null);
                try self.push(gpa, if (is_real) .real_literal else .int_literal, start);
                continue;
            }
            if (std.ascii.isAlphabetic(src[i]) or src[i] == '_') {
                i = scanIdentEnd(src, i);
                const tag = token.keyword_map.get(src[start..i]) orelse .identifier;
                try self.push(gpa, tag, start);
                continue;
            }
            if (src[i] == '$') {
                i = scanIdentEnd(src, i);
                try self.push(gpa, .system_identifier, start);
                continue;
            }
            if (src[i] == '"') {
                i += 1;
                while (i < src.len and src[i] != '"') : (i += 1) {
                    if (src[i] == '\\') i += 1;
                }
                i += 1;
                try self.push(gpa, .string_literal, start);
                continue;
            }
            for (symbols) |sym| {
                if (std.mem.startsWith(u8, src[i..], sym[0])) {
                    try self.push(gpa, sym[1], start);
                    i += @intCast(sym[0].len);
                    continue :outer;
                }
            }
            try self.push(gpa, .invalid, start);
            i += 1;
        }
        try self.push(gpa, .eof, @intCast(src.len));
        return self;
    }

    fn push(self: *TestLex, gpa: std.mem.Allocator, tag: token.Tag, start: u32) !void {
        try self.tags.append(gpa, tag);
        try self.starts.append(gpa, start);
    }
};

const TestResult = struct {
    file: Ast.SourceFile,
    bag: *diag.Bag,

    fn count(self: TestResult) usize {
        return self.bag.count();
    }

    fn code(self: TestResult, i: usize) diag.Code {
        return self.bag.at(i).code;
    }

    fn msg(self: TestResult, i: usize) []const u8 {
        return self.bag.at(i).message;
    }
};

fn newBag(arena: std.mem.Allocator, src: []const u8) !*diag.Bag {
    const bag = try arena.create(diag.Bag);
    bag.* = diag.Bag.init(arena);
    try bag.setSingleFile("test.va", src, 0);
    return bag;
}

fn parseForTest(arena: std.mem.Allocator, src: []const u8) !TestResult {
    const lx = try TestLex.run(arena, src);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, lx.tags.items, lx.starts.items, bag);
    const file = p.parseSourceFile() catch |e| switch (e) {
        error.ParseError => p.file,
        else => return e,
    };
    return .{ .file = file, .bag = bag };
}

/// Same, but through the REAL lexer — `TestLex` has no §10.6 directive tokens
/// and no §2.6.1 number scanner.
fn lexParseForTest(arena: std.mem.Allocator, src: []const u8) !TestResult {
    var list = try lexer.Lexer.tokenize(arena, src);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);
    const file = p.parseSourceFile() catch |e| switch (e) {
        error.ParseError => p.file,
        else => return e,
    };
    return .{ .file = file, .bag = bag };
}

test "§10.6 begin_keywords picks which annex B words are reserved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // LRM §10.6 worked example: `sin` is a port name under 1364-2005. Note the
    // module body still uses `analog` — a VAMS-only annex B keyword — because
    // §10.6 changes reserving, not tokens.
    const ok =
        \\`begin_keywords "1364-2005"
        \\module m2(sin, n);
        \\  inout sin, n;
        \\  electrical sin, n;
        \\  analog I(sin,n) <+ V(sin,n) + sin;
        \\endmodule
        \\`end_keywords
    ;
    const a = try lexParseForTest(arena, ok);
    try std.testing.expectEqual(@as(usize, 0), a.count());
    try std.testing.expectEqualStrings("sin", a.file.str(a.file.modules[0].ports[0].name));

    // Same code, VAMS keywords: "shall result in an error".
    const bad =
        \\`begin_keywords "VAMS-2023"
        \\module m2(sin, n);
        \\  inout sin, n;
        \\endmodule
        \\`end_keywords
    ;
    const b = try lexParseForTest(arena, bad);
    try std.testing.expect(b.count() > 0);
    try std.testing.expectEqual(diag.Code.E0208, b.code(0));
    try std.testing.expectEqualStrings("found `sin`", b.msg(0));

    // The set is restored by `end_keywords, so `sin` is reserved again after.
    const c = try lexParseForTest(arena,
        \\`begin_keywords "1364-1995"
        \\`end_keywords
        \\module m(sin);
        \\endmodule
    );
    try std.testing.expect(c.count() > 0);

    // §10.6: only these five specifiers exist.
    const d = try lexParseForTest(arena, "`begin_keywords \"1800-2017\"\n`end_keywords\n");
    try std.testing.expectEqual(diag.Code.E0135, d.code(0));
    try std.testing.expectEqualStrings("`1800-2017`", d.msg(0));

    // Unbalanced, both ways.
    const e = try lexParseForTest(arena, "`begin_keywords \"VAMS-2.3\"\nmodule m; endmodule\n");
    try std.testing.expectEqual(diag.Code.E0137, e.code(0));
    const f = try lexParseForTest(arena, "`end_keywords\n");
    try std.testing.expectEqual(diag.Code.E0136, f.code(0));

    // §10.6: "can only be specified outside of a design element".
    const g = try lexParseForTest(arena,
        \\module m;
        \\`begin_keywords "1364-2005"
        \\endmodule
        \\`end_keywords
    );
    try std.testing.expectEqual(diag.Code.E0202, g.code(0));
    try std.testing.expectEqualStrings("`begin_keywords inside a module", g.msg(0));
}

test "§2.6.1 based literals decode to the right VALUE, not just to a token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module m;
        \\  integer a, b, c, d;
        \\  analog begin
        \\    a = 8'hFFFF;
        \\    b = 4'shf;
        \\    c = 'h837ff;
        \\    d = 16'b0011_0101;
        \\  end
        \\endmodule
    ;
    const res = try lexParseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const body = res.file.modules[0].analog[0].body;
    const stmts = switch (res.file.stmt(body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // These are the regression pins: the parser's old private decoder ignored
    // the size (65535) and skipped the `s` designator (15).
    const want = [_]i32{ 255, -1, 0x837ff, 0x35 };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a2| a2.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }
}

test "§4.2.13 a sized-constant concatenation joins BITS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try lexParseForTest(arena,
        \\module m;
        \\  integer a, b, c;
        \\  analog begin
        \\    a = {4'b1010, 4'b0101};
        \\    b = {1'b1, 3'b101};
        \\    c = {4'shf, 4'b0001};
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const stmts = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // 0xA5; §4.2.13's own example `{1'b1, 3'b101}` == 4'b1101; and a signed
    // operand contributes its BITS (4'shf is -1, i.e. 1111), not its value.
    const want = [_]i32{ 165, 0b1101, 0xf1 };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a| a.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }

    // "Unsized constant numbers shall not be allowed in concatenations."
    const unsized = try lexParseForTest(arena, "module m; integer a; analog a = {1'b1, 3}; endmodule");
    try std.testing.expectEqual(diag.Code.E0216, unsized.code(0));
    // §3.2.1: 33 bits does not fit an integer, and must not wrap silently.
    const wide = try lexParseForTest(arena, "module m; integer a; analog a = {16'h0, 16'h0, 1'b1}; endmodule");
    try std.testing.expectEqual(diag.Code.E0217, wide.code(0));
    try std.testing.expectEqualStrings("at least 33 bits wide", wide.msg(0));
    // A brace list with no sized operand stays a `.concat` (§4.5.11 filter
    // coefficients spell their vector that way).
    const coeffs = try lexParseForTest(arena, "module m; real a; analog a = laplace_nd(1.0, {1,0}, {1,1}); endmodule");
    try std.testing.expectEqual(@as(usize, 0), coeffs.count());
}

test "a resistor parses into ports, ranged parameters and a contribution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1k from (0:inf) exclude 0;
        \\  real g;
        \\  analog begin : body
        \\    g = 1.0 / r;
        \\    if (V(p, n) > 0.0) g = g * 2;
        \\    I(p, n) <+ g * V(p, n) + ddt(V(p, n)) - $temperature;
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.modules.len);

    const m = res.file.modules[0];
    try std.testing.expectEqualStrings("res", res.file.str(m.name));
    try std.testing.expectEqual(@as(usize, 2), m.ports.len);
    try std.testing.expectEqual(Ast.Direction.inout, m.ports[0].direction);
    // `electrical p, n;` binds the discipline to the port, not a second net.
    try std.testing.expectEqualStrings("electrical", res.file.str(m.ports[1].discipline));
    try std.testing.expectEqual(@as(usize, 0), m.nets.len);

    // §3.4.2 ranges must survive to proof.zig.
    try std.testing.expectEqual(@as(usize, 1), m.params.len);
    const p0 = m.params[0];
    try std.testing.expectEqual(Ast.Type.real, p0.ty);
    try std.testing.expectEqual(@as(f64, 1000.0), res.file.exprs.realValue(p0.default));
    try std.testing.expectEqual(@as(usize, 2), p0.ranges.len);
    try std.testing.expect(!p0.ranges[0].lo_inclusive);
    try std.testing.expectEqual(Ast.ExprTag.pos_inf, res.file.exprs.tag(p0.ranges[0].hi));
    try std.testing.expectEqual(Ast.ValueRange.Kind.exclude, p0.ranges[1].kind);

    try std.testing.expectEqual(@as(usize, 1), m.analog.len);
    const blk = switch (res.file.stmt(m.analog[0].body)) {
        .block => |b| b,
        else => return error.WrongTag,
    };
    try std.testing.expectEqualStrings("body", res.file.str(blk.name));
    try std.testing.expectEqual(@as(usize, 3), blk.body.len);
    const contrib = switch (res.file.stmt(blk.body[2])) {
        .contribute => |c| c,
        else => return error.WrongTag,
    };
    // `I(p,n)` is a branch probe because `I` is a nature access name (§4.4.1).
    try std.testing.expectEqual(Ast.ExprTag.branch_access, res.file.exprs.tag(contrib.lhs));
    // §4.2.2: `a*b + f(x) - $t` parses as `(a*b + f(x)) - $t`.
    try std.testing.expectEqual(Ast.BinaryOp.sub, res.file.exprs.binOp(contrib.rhs));
}

test "Table 4-3 precedence: ?: is the ONLY right-associative operator (§4.2.2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module m(p);
        \\  inout p;
        \\  electrical p;
        \\  analog I(p) <+ 1 + 2 * 3 ** 2 ** 3 > 4 ? V(p) : 2 ? 3 : 4;
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    const e = &res.file.exprs;
    const rhs = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .contribute => |c| c.rhs,
        else => return error.WrongTag,
    };
    // `?:` is lowest and right-associative: cond ? V(p) : (2 ? 3 : 4)
    try std.testing.expectEqual(Ast.ExprTag.ternary, e.tag(rhs));
    try std.testing.expectEqual(Ast.ExprTag.ternary, e.tag(e.ternaryElse(rhs)));
    // §4.2.2: "All operators associate left to right with the exception of
    // the conditional operator which associates right to left." So the cond is
    // `(1 + (2 * ((3 ** 2) ** 3))) > 4` — `**` groups on the LEFT like every
    // other binary operator, and the nested pow hangs off `lhs`, not `rhs`.
    // Reading `**` as right-associative (the IEEE 1800 rule, not this one) made
    // `2**3**2` evaluate to 512 where §4.2.2 requires 64.
    const cond = e.lhs(rhs);
    try std.testing.expectEqual(Ast.BinaryOp.gt, e.binOp(cond));
    const add = e.lhs(cond);
    try std.testing.expectEqual(Ast.BinaryOp.add, e.binOp(add));
    const mul = e.rhs(add);
    try std.testing.expectEqual(Ast.BinaryOp.mul, e.binOp(mul));
    const pow = e.rhs(mul);
    try std.testing.expectEqual(Ast.BinaryOp.pow, e.binOp(pow));
    try std.testing.expectEqual(Ast.BinaryOp.pow, e.binOp(e.lhs(pow)));
    try std.testing.expectEqual(Ast.ExprTag.int_literal, e.tag(e.rhs(pow)));
}

test "errors are collected with locations and parsing continues" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module bad(p);
        \\  inout p;
        \\  electrical p;
        \\  child u(p);
        \\  always @(p) x = 1;
        \\  analog I(p) <+ V(p);
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 2), res.count());
    try std.testing.expectEqual(diag.Code.E0204, res.code(0));
    try std.testing.expectEqual(diag.Code.E0205, res.code(1));
    try std.testing.expectEqualStrings("found always", res.msg(1));

    // The spans still point at the offending tokens, on lines 4 and 5.
    const idx = try diag.LineIndex.build(arena, src);
    try std.testing.expectEqual(@as(u32, 4), idx.loc(res.bag.at(0).span.start).line);
    try std.testing.expectEqual(@as(u32, 5), idx.loc(res.bag.at(1).span.start).line);
    // Recovery kept going: the analog block after the bad items still parsed.
    try std.testing.expectEqual(@as(usize, 1), res.file.modules[0].analog.len);
}

test "annex C rejections keep their pinned wording" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { src: []const u8, code: diag.Code, point: []const u8 = "" }{
        // annex C.7 casex is not an analog statement
        .{ .src = "module m; integer s; analog casex (s) 0: s = 1; endcase endmodule", .code = .E0209 },
        // §4.2.10 reduction xor
        .{ .src = "module m; integer b, q; analog q = ^b; endmodule", .code = .E0215 },
        // §2.6.1 x/z digits are not in the analog subset
        .{ .src = "module m; integer v; analog v = 4'b01xz; endmodule", .code = .E0130 },
        // §6.4 paramsets
        .{ .src = "paramset ps mod; endparamset", .code = .E0201 },
        // A.1.3 module_parameter_port_list
        .{ .src = "module m #(parameter real a = 1) (p); endmodule", .code = .E0207, .point = "expected `;`" },
        // §3.6.3 vector nets / §6.5.2 vector ports
        .{ .src = "module m(p); inout p; electrical [3:0] p; endmodule", .code = .E0208 },
        // hierarchical net reference inside a probe (§6.8)
        .{ .src = "module m(p); inout p; electrical p; analog I(p) <+ V(u.n); endmodule", .code = .E0207, .point = "expected `)`" },
        // A.8.1 multiple concatenation
        .{ .src = "module m; integer b; analog b = {2{1}}; endmodule", .code = .E0207, .point = "expected `}`" },
    };
    for (cases) |c| {
        const res = try parseForTest(arena, c.src);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(c.code, res.code(0));
        // E0207's title is only "unexpected token": what was wanted rides on
        // the caret, so that is what the fixtures pin.
        if (c.point.len != 0)
            try std.testing.expectEqualStrings(c.point, res.bag.at(0).point);
    }
}

test "a missing terminator suggests inserting it after the PREVIOUS token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The caret lands on `end`, one line after the mistake. What makes the
    // message actionable is the fix: a zero-width insertion at the end of the
    // contribution, which is where a person has to type the `;`.
    const src =
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ V(p, n)
        \\  end
        \\endmodule
    ;
    const res = try lexParseForTest(arena, src);
    try std.testing.expectEqual(diag.Code.E0207, res.code(0));

    var nbuf: [diag.max_children]diag.Note = undefined;
    const notes = res.bag.notes(res.bag.at(0), &nbuf);
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    const fix = notes[0].fix orelse return error.TestExpectedFix;
    try std.testing.expectEqualStrings(";", fix.replacement);
    // Zero width: an insertion, not a replacement.
    try std.testing.expectEqual(fix.span.start, fix.span.end);
    // ...and it is anchored just past `)`, not at the `end` the caret is under.
    try std.testing.expectEqualStrings("V(p, n)", src[fix.span.start - 7 .. fix.span.start]);

    // A terminator is the only shape that earns an insertion: E0208 wants a
    // NAME, and no fix can invent one.
    const named = try lexParseForTest(arena, "module m(p); inout p; electrical [3:0] p; endmodule");
    try std.testing.expectEqual(diag.Code.E0208, named.code(0));
    try std.testing.expectEqual(@as(u32, 0), named.bag.at(0).n_notes);
}

// Needs the REAL lexer: `TestLex` has no §2.7 string scanner, so it never
// produces the `.invalid` token this diagnostic is built from.
test "§2.7 a string may not span lines, however it is continued" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The IEEE 1800 §5.9 continuation bsim4va's $strobe uses, and a plain
    // runaway. Both are E0138; only the first earns the SystemVerilog note.
    const cases = [_]struct { src: []const u8, notes: u32 }{
        .{ .src = "module m; analog $strobe(\"a\\\nb\"); endmodule", .notes = 2 },
        .{ .src = "module m; analog $strobe(\"a\nb\"); endmodule", .notes = 1 },
    };
    for (cases) |c| {
        const res = try lexParseForTest(arena, c.src);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(diag.Code.E0138, res.code(0));
        try std.testing.expectEqualStrings(
            "this literal is still open at the end of the line",
            res.bag.at(0).point,
        );
        try std.testing.expectEqual(c.notes, res.bag.at(0).n_notes);
    }
}

test "analog functions, events, case and indirect contributions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\nature Voltage;
        \\  units = "V";
        \\  access = Pot;
        \\  abstol = 1e-6;
        \\endnature
        \\discipline el;
        \\  potential Voltage;
        \\  potential.abstol = 1e-9;
        \\  domain continuous;
        \\enddiscipline
        \\module m(p, n);
        \\  inout p, n;
        \\  el p, n;
        \\  branch (p, n) br;
        \\  real x[0:1];
        \\  integer k;
        \\  analog function real half;
        \\    input v;
        \\    real v;
        \\    half = v / 2.0;
        \\  endfunction
        \\  analog begin
        \\    @(initial_step("dc", "tran")) x[0] = 0.0;
        \\    @(cross(Pot(p, n), +1) or timer(1n, 1n)) x[1] = 1.0;
        \\    for (k = 0; k < 2; k = k + 1) x[0] = x[0] + half(Pot(br));
        \\    case (k)
        \\      0, 1: $strobe("k=%d", k);
        \\      default: ;
        \\    endcase
        \\    Pot(p, n) : Pot(p) == 2.0 * x[0];
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.natures.len);
    try std.testing.expectEqual(@as(usize, 1), res.file.disciplines.len);
    const d = res.file.disciplines[0];
    try std.testing.expectEqualStrings("Voltage", res.file.str(d.potential));
    try std.testing.expectEqual(Ast.DisciplineDecl.Domain.continuous, d.domain);
    try std.testing.expectEqual(@as(usize, 1), d.overrides.len);

    const m = res.file.modules[0];
    try std.testing.expectEqual(@as(usize, 1), m.branches.len);
    try std.testing.expectEqual(@as(usize, 1), m.functions.len);
    // `input v; real v;` types the argument and does not leave a local.
    try std.testing.expectEqual(@as(usize, 1), m.functions[0].args.len);
    try std.testing.expectEqual(Ast.Type.real, m.functions[0].args[0].ty);
    try std.testing.expectEqual(@as(usize, 0), m.functions[0].vars.len);

    const body = switch (res.file.stmt(m.analog[0].body)) {
        .block => |b| b.body,
        else => return error.WrongTag,
    };
    try std.testing.expectEqual(@as(usize, 5), body.len);
    const ev = switch (res.file.stmt(body[0])) {
        .event_control => |c| c.event,
        else => return error.WrongTag,
    };
    // §5.10.2: the argument list is analysis-name strings, not expressions.
    try std.testing.expectEqual(Ast.ExprTag.event_initial_step, res.file.exprs.tag(ev));
    try std.testing.expectEqual(@as(usize, 2), res.file.exprs.nameParts(ev).len);
    try std.testing.expectEqualStrings("dc", res.file.str(res.file.exprs.nameParts(ev)[0]));

    const ev2 = switch (res.file.stmt(body[1])) {
        .event_control => |c| c.event,
        else => return error.WrongTag,
    };
    try std.testing.expectEqual(Ast.ExprTag.event_or, res.file.exprs.tag(ev2));
    try std.testing.expectEqual(
        Ast.ExprTag.event_function,
        res.file.exprs.tag(res.file.exprs.lhs(ev2)),
    );
    // §5.6.7 indirect contribution survives parsing (lowering may reject it).
    switch (res.file.stmt(body[4])) {
        .indirect => |ind| try std.testing.expectEqual(
            Ast.ExprTag.branch_access,
            res.file.exprs.tag(ind.probe),
        ),
        else => return error.WrongTag,
    }
}
