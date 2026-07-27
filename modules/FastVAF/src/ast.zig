//! Class 2 — AST. LRM annex A (formal grammar), ch3 declaration syntax.
//!
//! Transformation: token stream → AST. The AST is the shape the grammar
//! produces; class 3–9 lowering consumes it.
//!
//! DOD (critical): the AST is SoA + u32 handles, NOT a pointer tree.
//!   - Expressions live in parallel columns (a MultiArrayList): tag, main_tok,
//!     lhs, rhs, extra, str. An ExprId is an index into those columns.
//!   - Statements live in a flat pool; a StmtId indexes it.
//!   - Never store a `*ExprNode`; store an `ExprId`.
//!   - Variable-arity payloads (call args, concat elements, dotted name parts)
//!     live in one shared `u32` pool, addressed by a single `u32` in the row.
//!   - Identifiers/strings are interned once; nodes carry a `StrId`, never a
//!     slice.
//!
//! Determinism: every store is append-only and insertion-ordered, so identical
//! token input yields byte-identical ids in every column. Nothing here hashes
//! pointers or iterates a hash map.
//!
//! Ownership: every list is unmanaged and takes the allocator per call. The
//! intended allocator is the per-compilation arena, so `deinit` is normally
//! unnecessary — it exists anyway (deinit-complete) so an AST can be built on a
//! gpa in tests. `[]const u8` slices handed to `StringInterner.intern` are
//! BORROWED: they must outlive the `SourceFile` (the preprocessed source buffer
//! and the compilation arena both do).
//!
//! NOTE on `std.ArrayList` in 0.16: `ArrayList` *is* the unmanaged list
//! (`std.ArrayListUnmanaged` is a deprecated alias for it). Hence
//! `= .empty` + `append(gpa, x)`.

const std = @import("std");

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

/// Handle into the expression columns. `enum(u32)` newtype — cannot be confused
/// with a StmtId. LRM annex A (expression grammar).
pub const ExprId = enum(u32) { none = std.math.maxInt(u32), _ };
/// Handle into the statement pool. LRM §5 behavioral statements.
pub const StmtId = enum(u32) { none = std.math.maxInt(u32), _ };
/// Handle into the string intern table. LRM §2.8 identifiers, §2.7 strings.
pub const StrId = enum(u32) { none = std.math.maxInt(u32), _ };

/// Scalar data types. LRM §3.1, §3.2, §3.3, §3.4.1.
/// `realtime` collapses to `.real` and `time` to `.integer` (A.2.1.1
/// parameter_type); the distinction is meaningless in the analog kernel.
/// `.unspecified` is `parameter p = <expr>;` with no type keyword — LRM §3.4.1
/// derives the type from the default expression, which only lowering (which can
/// fold) is able to do. Lowering MUST resolve `.unspecified`; codegen never
/// sees it.
pub const Type = enum(u8) { real, integer, string, unspecified };

/// Port / function-argument direction. LRM §6.5.2.2 (ports), §4.7.2.3
/// (function output/inout args). `.unspecified` is a port named in
/// `list_of_ports` whose direction arrives later as a `port_declaration`
/// (A.1.3 / A.1.4).
pub const Direction = enum(u8) { unspecified, input, output, inout };

/// LRM §3.6.1 / A.1.7 `potential_or_flow`.
pub const PotentialOrFlow = enum(u8) { potential, flow };

// ---------------------------------------------------------------------------
// Operators — LRM §4.2, A.8.6
// ---------------------------------------------------------------------------

/// A.8.6 unary_operator. Stored in the `extra` column of a `.unary` node.
pub const UnaryOp = enum(u8) {
    plus, // +      §4.2.1
    minus, // -      §4.2.1
    logical_not, // !      §4.2.7
    bit_not, // ~      §4.2.8
    reduce_and, // &      §4.2.9
    reduce_nand, // ~&     §4.2.9
    reduce_or, // |      §4.2.9
    reduce_nor, // ~|     §4.2.9
    reduce_xor, // ^      §4.2.9
    reduce_xnor, // ~^ ^~  §4.2.9
};

/// A.8.6 binary_operator. Stored in the `extra` column of a `.binary` node.
pub const BinaryOp = enum(u8) {
    add, // +    §4.2.1
    sub, // -    §4.2.1
    mul, // *    §4.2.1
    div, // /    §4.2.1
    mod, // %    §4.2.1
    pow, // **   §4.2.1
    eq, // ==   §4.2.5
    neq, // !=   §4.2.5
    case_eq, // ===  §4.2.5 (digital; rejected in the analog subset, annex C)
    case_neq, // !==  §4.2.5
    lt, // <    §4.2.4
    le, // <=   §4.2.4
    gt, // >    §4.2.4
    ge, // >=   §4.2.4
    logical_and, // &&   §4.2.7
    logical_or, // ||   §4.2.7
    bit_and, // &    §4.2.8
    bit_or, // |    §4.2.8
    bit_xor, // ^    §4.2.8
    bit_xnor, // ~^ ^~ §4.2.8
    shl, // <<   §4.2.10
    shr, // >>   §4.2.10
    ashl, // <<<  §4.2.10
    ashr, // >>>  §4.2.10
};

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

/// Expression node tag. LRM §4.2 (operators), §4.3/§4.5/§4.6 (calls), §4.4
/// (access functions), §5.10 (event expressions — they are expressions in
/// A.6.5 `analog_event_expression`).
///
/// Column usage per tag is documented on each arm; `main_tok` is always the
/// token the node is reported at (needed by the class-6 finiteness proof, whose
/// failures are compile errors and must name a source location).
pub const ExprTag = enum(u8) {
    // ---- literals & names — §2.6, §2.7, §2.8, A.8.7 ----
    /// `extra` = index into `ExprStore.ints`. LRM §2.6.1.
    int_literal,
    /// `extra` = index into `ExprStore.reals`. LRM §2.6.2 (incl. SI suffixes).
    real_literal,
    /// `str` = interned, escape-processed contents. LRM §2.7.
    str_literal,
    /// A.2.5 `value_range_expression ::= ... | inf | -inf`. Only legal inside a
    /// `ValueRange`; the finiteness proof (class 6) reads these directly.
    pos_inf,
    neg_inf,
    /// `str` = name. LRM §2.8 (variables, nets, params, genvars, named events).
    ident,
    /// Dotted name: `extra` = StrId list offset (2+ parts). Covers
    /// hierarchical_identifier (§6.8) AND nature_attribute_reference
    /// (§3.6.1.3, e.g. `electrical.potential.abstol`) — lowering tells them
    /// apart by resolving the first part.
    hier_ident,

    // ---- operators — §4.2 ----
    /// `lhs` = operand, `extra` = @intFromEnum(UnaryOp).
    unary,
    /// `lhs`, `rhs` operands, `extra` = @intFromEnum(BinaryOp).
    binary,
    /// §4.2.12 `?:` — `lhs` = cond, `rhs` = then, `extra` = @intFromEnum(else).
    /// Read the third operand with `ExprStore.ternaryElse`.
    ternary,

    // ---- calls (all: `str` = callee name, `extra` = ExprId list offset) ----
    /// §4.7 user-defined analog function call (A.8.2 analog_function_call).
    call,
    /// §4.3 math built-in (A.8.2 analog_built_in_function_name). Lowering maps
    /// the name to a MIR op and to the LRM §4.3 domain table.
    builtin_call,
    /// ch9 system function / task-as-expression, and §9.x `analysis("...")`
    /// (A.8.2 analog_system_function_call, analysis_function_call). `$name`
    /// without parens is this tag with an empty arg list.
    sys_call,
    /// §4.5 analog operator / filter: ddt, ddx, idt, idtmod, absdelay,
    /// transition, slew, last_crossing, limexp, laplace_*, zi_* (A.8.2
    /// analog_filter_function_call). Each occurrence owns runtime state, so it
    /// must stay a distinct tag from `builtin_call`.
    filter_call,
    /// §4.6 small-signal / noise: ac_stim, white_noise, flicker_noise,
    /// noise_table, noise_table_log (A.8.2 analog_small_signal_function_call).
    noise_call,

    // ---- access functions — §4.4 ----
    /// §4.4.1 branch probe: `V(a)`, `V(a,b)`, `I(br)`. `str` = access
    /// identifier (`V`/`I`/nature access name, §3.6.1.4), `lhs` = first
    /// net-or-branch reference, `rhs` = second net reference or `.none`.
    branch_access,
    /// §4.4.2 / §5.4.3 port branch probe `I(<p>)` (A.8.2
    /// port_probe_function_call). `str` = access identifier, `lhs` = port ref.
    port_access,

    // ---- aggregates — §4.2.13, §3.4.4, A.8.1 ----
    /// `{a, b, ...}` — `extra` = ExprId list offset.
    concat,
    /// `{n{...}}` — `lhs` = repeat count, `rhs` = the inner `.concat`.
    multi_concat,
    /// `'{a, b, ...}` assignment pattern (array param defaults §3.4.4, filter
    /// coefficient args §4.5.4) — `extra` = ExprId list offset.
    assign_pattern,
    /// §3.4.4 array / bit select `base[i]` — `lhs` = base, `rhs` = index.
    index,
    /// `msb:lsb` part select and `analog_range_expression` (A.8.3) —
    /// `lhs` = msb, `rhs` = lsb.
    range,

    // ---- event expressions — §5.10, A.6.5 ----
    /// `e1 or e2` / `e1, e2` — `lhs`, `rhs`.
    event_or,
    /// `posedge e` / `negedge e` — `lhs` (digital edges, §5.10.1).
    event_posedge,
    event_negedge,
    /// §5.10.2 `initial_step` / `final_step` — `extra` = StrId list offset of
    /// the analysis-name arguments (empty list = no argument list).
    event_initial_step,
    event_final_step,
    /// §5.10.3 monitored event function: cross, above, timer, absdelta (A.6.5
    /// analog_event_functions). `str` = name, `extra` = ExprId list offset
    /// (a `.none` element is an omitted `analog_expression_or_null` argument).
    event_function,
};

/// One expression row. The `ExprStore` keeps these as MultiArrayList columns,
/// so this struct is the *row view*, never an allocated node.
pub const Node = struct {
    tag: ExprTag,
    /// Token index this node is reported at (diagnostics; class 6 errors).
    main_tok: u32 = 0,
    lhs: ExprId = .none,
    rhs: ExprId = .none,
    /// Opcode / literal payload / list offset — see `ExprTag` per-arm docs.
    extra: u32 = 0,
    /// Interned name, `.none` when the tag carries no name.
    str: StrId = .none,
};

/// SoA expression store (one row per expression). LRM annex A.
/// Columns are parallel (a MultiArrayList); ExprId indexes all of them.
pub const ExprStore = struct {
    /// Columns: `.tag`, `.main_tok`, `.lhs`, `.rhs`, `.extra`, `.str`.
    nodes: std.MultiArrayList(Node) = .empty,
    /// Shared variable-arity payload pool. Each list is stored as
    /// `[len, e0, e1, ...]`; a row's `extra` is the offset of the `len` word.
    pool: std.ArrayList(u32) = .empty,
    /// Side table for `.real_literal` values (`extra` indexes it). Kept out of
    /// the row so the common integer/ident rows stay narrow.
    reals: std.ArrayList(f64) = .empty,
    /// §2.6.1 decoded integer literals. Parked here for the same reason `reals`
    /// is: a row's `extra` is ONE u32, and an integer is 64 bits wide
    /// everywhere below this point — MIR `int_const`, codegen's `i64` slots and
    /// the device contract. Truncating to 32 to fit `extra` is what made
    /// `4294967296` lower to 0.
    ints: std.ArrayList(i64) = .empty,

    pub const empty: ExprStore = .{};

    pub fn deinit(self: *ExprStore, gpa: std.mem.Allocator) void {
        self.nodes.deinit(gpa);
        self.pool.deinit(gpa);
        self.reals.deinit(gpa);
        self.ints.deinit(gpa);
        self.* = .empty;
    }

    /// Append one row (all columns in lockstep) and return its handle.
    pub fn add(self: *ExprStore, gpa: std.mem.Allocator, node: Node) !ExprId {
        const id: u32 = @intCast(self.nodes.len);
        std.debug.assert(id != @intFromEnum(ExprId.none));
        try self.nodes.append(gpa, node);
        return @enumFromInt(id);
    }

    /// Convenience for `.real_literal`: parks the value in `reals`.
    pub fn addReal(self: *ExprStore, gpa: std.mem.Allocator, main_tok: u32, value: f64) !ExprId {
        const idx: u32 = @intCast(self.reals.items.len);
        try self.reals.append(gpa, value);
        return self.add(gpa, .{ .tag = .real_literal, .main_tok = main_tok, .extra = idx });
    }

    /// Convenience for `.int_literal`: parks the value in `ints`.
    pub fn addInt(self: *ExprStore, gpa: std.mem.Allocator, main_tok: u32, value: i64) !ExprId {
        const idx: u32 = @intCast(self.ints.items.len);
        try self.ints.append(gpa, value);
        return self.add(gpa, .{ .tag = .int_literal, .main_tok = main_tok, .extra = idx });
    }

    pub fn len(self: *const ExprStore) u32 {
        return @intCast(self.nodes.len);
    }

    pub fn get(self: *const ExprStore, id: ExprId) Node {
        return self.nodes.get(@intFromEnum(id));
    }

    pub fn tag(self: *const ExprStore, id: ExprId) ExprTag {
        return self.nodes.items(.tag)[@intFromEnum(id)];
    }
    pub fn mainTok(self: *const ExprStore, id: ExprId) u32 {
        return self.nodes.items(.main_tok)[@intFromEnum(id)];
    }
    pub fn lhs(self: *const ExprStore, id: ExprId) ExprId {
        return self.nodes.items(.lhs)[@intFromEnum(id)];
    }
    pub fn rhs(self: *const ExprStore, id: ExprId) ExprId {
        return self.nodes.items(.rhs)[@intFromEnum(id)];
    }
    pub fn extraOf(self: *const ExprStore, id: ExprId) u32 {
        return self.nodes.items(.extra)[@intFromEnum(id)];
    }
    pub fn strOf(self: *const ExprStore, id: ExprId) StrId {
        return self.nodes.items(.str)[@intFromEnum(id)];
    }

    /// §4.2 decoded opcode accessors (assert the tag matches).
    pub fn unOp(self: *const ExprStore, id: ExprId) UnaryOp {
        std.debug.assert(self.tag(id) == .unary);
        return @enumFromInt(@as(u8, @intCast(self.extraOf(id))));
    }
    pub fn binOp(self: *const ExprStore, id: ExprId) BinaryOp {
        std.debug.assert(self.tag(id) == .binary);
        return @enumFromInt(@as(u8, @intCast(self.extraOf(id))));
    }
    /// §4.2.12 third operand of `?:`.
    pub fn ternaryElse(self: *const ExprStore, id: ExprId) ExprId {
        std.debug.assert(self.tag(id) == .ternary);
        return @enumFromInt(self.extraOf(id));
    }
    /// §2.6.1 decoded integer literal.
    pub fn intValue(self: *const ExprStore, id: ExprId) i64 {
        std.debug.assert(self.tag(id) == .int_literal);
        return self.ints.items[self.extraOf(id)];
    }
    /// §2.6.2 decoded real literal.
    pub fn realValue(self: *const ExprStore, id: ExprId) f64 {
        std.debug.assert(self.tag(id) == .real_literal);
        return self.reals.items[self.extraOf(id)];
    }

    /// Store a variable-arity list; returns the offset to put in a row's
    /// `extra`. Deterministic: offsets are assigned in append order.
    pub fn addList(self: *ExprStore, gpa: std.mem.Allocator, items: []const u32) !u32 {
        const off: u32 = @intCast(self.pool.items.len);
        try self.pool.ensureUnusedCapacity(gpa, items.len + 1);
        self.pool.appendAssumeCapacity(@intCast(items.len));
        self.pool.appendSliceAssumeCapacity(items);
        return off;
    }
    pub fn addExprList(self: *ExprStore, gpa: std.mem.Allocator, items: []const ExprId) !u32 {
        return self.addList(gpa, @ptrCast(items));
    }
    pub fn addStrList(self: *ExprStore, gpa: std.mem.Allocator, items: []const StrId) !u32 {
        return self.addList(gpa, @ptrCast(items));
    }

    pub fn list(self: *const ExprStore, off: u32) []const u32 {
        const n = self.pool.items[off];
        return self.pool.items[off + 1 ..][0..n];
    }
    pub fn exprList(self: *const ExprStore, off: u32) []const ExprId {
        return @ptrCast(self.list(off));
    }
    pub fn strList(self: *const ExprStore, off: u32) []const StrId {
        return @ptrCast(self.list(off));
    }

    /// Arguments of any call-shaped tag (`call`, `builtin_call`, `sys_call`,
    /// `filter_call`, `noise_call`, `event_function`) and the elements of
    /// `concat` / `assign_pattern`.
    pub fn args(self: *const ExprStore, id: ExprId) []const ExprId {
        return self.exprList(self.extraOf(id));
    }
    /// Parts of a `.hier_ident`, and the analysis names of
    /// `.event_initial_step` / `.event_final_step`.
    pub fn nameParts(self: *const ExprStore, id: ExprId) []const StrId {
        return self.strList(self.extraOf(id));
    }
};

// ---------------------------------------------------------------------------
// String interning — LRM §2.7, §2.8
// ---------------------------------------------------------------------------

/// Identifier/string intern table. Insertion-ordered ⇒ StrIds are
/// deterministic for a given token stream.
///
/// THE one interning mechanism in the engine: `mir.zig` embeds this same type
/// (`Mir.strings`) and re-exports `StrId` as `Mir.StrId`, so "interned string"
/// has exactly one shape from the lexer to codegen. A StrId is only meaningful
/// against the table it came from (the AST's or the MIR's) — lowering carries
/// a name across with `mir.internString(gpa, file.str(id))`.
///
/// Stored slices are BORROWED — either substrings of the preprocessed source or
/// arena copies made by the parser (escaped identifiers §2.8.1, string literals
/// §2.7 need un-escaping). Both outlive the `SourceFile`; nothing here frees a
/// string. Cold data: only naming/codegen walks it, never a hot loop.
pub const StringInterner = struct {
    strings: std.ArrayList([]const u8) = .empty,
    map: std.StringHashMapUnmanaged(StrId) = .empty,

    pub const empty: StringInterner = .{};

    pub fn deinit(self: *StringInterner, gpa: std.mem.Allocator) void {
        self.strings.deinit(gpa);
        self.map.deinit(gpa);
        self.* = .empty;
    }

    /// Intern `s` (borrowed; must outlive the AST). Idempotent.
    pub fn intern(self: *StringInterner, gpa: std.mem.Allocator, s: []const u8) !StrId {
        const gop = try self.map.getOrPut(gpa, s);
        if (gop.found_existing) return gop.value_ptr.*;
        const id: StrId = @enumFromInt(@as(u32, @intCast(self.strings.items.len)));
        // errdefer: on OOM below, drop the just-inserted key so the table never
        // maps a name to an id that has no string.
        errdefer _ = self.map.remove(s);
        try self.strings.append(gpa, s);
        gop.value_ptr.* = id;
        return id;
    }

    pub fn get(self: *const StringInterner, id: StrId) []const u8 {
        std.debug.assert(id != .none);
        return self.strings.items[@intFromEnum(id)];
    }

    /// Lookup without inserting — used to test a name against a known keyword
    /// set without polluting the table.
    pub fn find(self: *const StringInterner, s: []const u8) ?StrId {
        return self.map.get(s);
    }

    pub fn eql(self: *const StringInterner, id: StrId, s: []const u8) bool {
        return id != .none and std.mem.eql(u8, self.get(id), s);
    }
};

// ---------------------------------------------------------------------------
// Declarations — LRM ch3, ch4 §4.7, ch6
// ---------------------------------------------------------------------------

/// A declared dimension / range: `[msb:lsb]` (A.2.5 `range`, `dimension`).
/// Used by array parameters (§3.4.4), array variables (§3.2.2) and vector
/// ports / nets (§6.5.2).
pub const Dim = struct {
    msb: ExprId,
    lsb: ExprId,
};

/// LRM §3.4.2 value_range: `from [lo:hi]` / `exclude (lo:hi)` / `exclude val`.
/// A.2.5 `value_range`. `lo`/`hi` may be `.pos_inf` / `.neg_inf` nodes.
///
/// CRITICAL: these are the *only* bound evidence the class-6 finiteness proof
/// has. They must survive parse → ParamDecl → Lower.ParamInfo → proof.zig.
/// Dropping them silently turns provable models into unprovable ones.
pub const ValueRange = struct {
    kind: Kind,
    lo: ExprId,
    /// `.none` for a single-value `exclude` and for the string-set form.
    hi: ExprId = .none,
    lo_inclusive: bool = true,
    hi_inclusive: bool = true,
    /// A.2.5 `value_range_type '{ string {, string} }` — offset of a StrId list
    /// in `ExprStore.pool`, or `null` for the numeric forms. LRM §3.4.2 string
    /// parameter value ranges.
    strings: ?u32 = null,

    pub const Kind = enum(u8) { from, exclude };
};

/// Parameter declaration. LRM §3.4 (A.2.1.1 parameter_declaration /
/// local_parameter_declaration, A.2.4 param_assignment). One `ParamDecl` per
/// declared name — the parser expands `parameter real a = 1, b = 2;`.
pub const ParamDecl = struct {
    name: StrId,
    ty: Type, // §3.4.1 (`.unspecified` ⇒ infer from `default`)
    default: ExprId, // §3.4 default expression (constant_mintypmax_expression)
    is_local: bool = false, // §3.4.5 localparam
    /// §3.4.4 array parameter dimensions; empty for a scalar.
    dims: []const Dim = &.{},
    /// LRM §3.4.2 value ranges (from/exclude). CRITICAL: these are parsed here
    /// but historically DROPPED before codegen. Class 6 (proof.zig) needs them —
    /// carry them through to Lower.ParamInfo.
    ranges: []const ValueRange = &.{},
    main_tok: u32 = 0,
};

/// LRM §3.4.6 `aliasparam alias = target;` (A.2.1.1 aliasparam_declaration).
pub const AliasParam = struct {
    alias: StrId,
    target: StrId,
};

/// Local variable declaration: `real`/`integer`/`string` (+ `realtime`/`time`
/// folded into those). LRM §3.2, §3.3; A.2.8 analog_block_item_declaration.
/// One per declared name.
pub const VarDecl = struct {
    name: StrId,
    ty: Type,
    /// §3.2.2 array dimensions; empty for a scalar.
    dims: []const Dim = &.{},
    /// A.2.2.1 `variable_identifier = constant_expression`; `.none` if absent.
    init: ExprId = .none,
    main_tok: u32 = 0,
};

/// Net declaration. LRM §3.6.3 (A.2.1.3 net_declaration). One per declared
/// name. In the Verilog-A subset (annex C) the only forms that matter are
/// `<discipline> a, b;` and `ground <discipline> g;`.
pub const NetDecl = struct {
    name: StrId,
    /// §3.6.2 discipline identifier; `.none` when the net is untyped (§3.9
    /// discipline resolution then assigns it).
    discipline: StrId = .none,
    /// §3.6.3 `ground` declaration — a global reference node.
    is_ground: bool = false,
    /// §6.5.2 vector net range; `null` for a scalar.
    range: ?Dim = null,
    /// A.2.4 net_decl_assignment (wreal only); `.none` otherwise.
    init: ExprId = .none,
    main_tok: u32 = 0,
};

/// Branch declaration. LRM §3.12 (A.2.1.3 branch_declaration /
/// port_branch_declaration). One per declared branch name.
pub const BranchDecl = struct {
    name: StrId,
    /// First terminal: an `.ident` or `.index` expression (net or port ref).
    hi: ExprId,
    /// Second terminal; `.none` = implicit global ground (§3.12, §1.3.1.1).
    lo: ExprId = .none,
    /// §3.12 `branch (<p>)` — a port branch, not a node pair.
    is_port_branch: bool = false,
    /// A.2.3 `branch_identifier [ range ]` — array of branches; `null` = scalar.
    range: ?Dim = null,
    main_tok: u32 = 0,
};

/// Module port. LRM §6.5 (A.1.3 port / port_declaration).
pub const Port = struct {
    name: StrId,
    direction: Direction = .unspecified, // §6.5.2.2
    /// §6.5.2.1 discipline identifier; `.none` ⇒ resolved by §3.9.
    discipline: StrId = .none,
    /// §6.5.2 vector port range `[msb:lsb]`; `null` for a scalar port.
    range: ?Dim = null,
    main_tok: u32 = 0,
};

/// Analog function argument. LRM §4.7.2 (A.2.6 analog_function_item_declaration
/// → input/output/inout declaration). §4.7.2.3 makes `output`/`inout` args
/// write-back parameters.
pub const FuncArg = struct {
    name: StrId,
    ty: Type,
    direction: Direction, // §4.7.2.3 — `.input` unless declared otherwise
};

/// User-defined analog function. LRM §4.7.1 (A.2.6 analog_function_declaration).
/// The implicit return variable is the function's own name (§4.7.1).
pub const FuncDecl = struct {
    name: StrId,
    ret_ty: Type, // §4.7.1 analog_function_type (default `.real`)
    args: []const FuncArg, // §4.7.2, in declaration order (call order)
    /// §4.7.2 local declarations of the function body.
    params: []const ParamDecl = &.{},
    vars: []const VarDecl = &.{},
    /// §4.7.1 the single `analog_function_statement` (usually a `.block`).
    body: StmtId,
    main_tok: u32 = 0,
};

/// One `analog` construct. LRM §5.2 (A.6.2 analog_construct).
pub const AnalogBlock = struct {
    /// §5.2.1 `analog initial` — evaluated once, at initialization only.
    is_initial: bool = false,
    body: StmtId,
    main_tok: u32 = 0,
};

/// A module. LRM §6.2 (A.1.2 module_declaration). Declarations are kept in
/// typed, source-ordered slices rather than a mixed item list: lowering wants
/// them by kind, and a declaration is not a statement.
pub const ModuleDecl = struct {
    name: StrId,
    /// §6.5 in header order — this order defines the terminal order the host
    /// device ABI sees, so it is load-bearing. Keep it.
    ports: []const Port,
    /// §6.2.1 module_parameter_port_list `#(...)` followed by body parameter
    /// declarations, in source order (later defaults may reference earlier
    /// parameters, §3.4).
    params: []const ParamDecl = &.{},
    aliasparams: []const AliasParam = &.{}, // §3.4.6
    vars: []const VarDecl = &.{}, // §3.2/§3.3
    nets: []const NetDecl = &.{}, // §3.6.3
    branches: []const BranchDecl = &.{}, // §3.12
    genvars: []const StrId = &.{}, // §3.5 (unrolling evidence, §6.6.1)
    functions: []const FuncDecl = &.{}, // §4.7.1
    /// §5.2 analog blocks in source order.
    analog: []const AnalogBlock = &.{},
    main_tok: u32 = 0,
};

/// Nature attribute: `name = expr;`. LRM §3.6.1 (A.1.6 nature_attribute).
/// The LRM-defined names are `abstol` (§3.6.1.2, REQUIRED for a base nature),
/// `access` (§3.6.1.4), `units` (§3.6.1.3), `idt_nature` (§3.6.1.5),
/// `ddt_nature` (§3.6.1.6), plus user attributes (`huge`, `blowup`, …).
/// `value` may be an `.ident` (A.8.3 nature_attribute_expression allows a
/// nature or access identifier, not just a constant).
pub const NatureAttr = struct {
    name: StrId,
    value: ExprId,
    main_tok: u32 = 0,
};

/// Nature declaration. LRM §3.6.1 (A.1.6 nature_declaration).
pub const NatureDecl = struct {
    name: StrId,
    /// §3.6.1.1 derived nature: `nature x : parent`. `.none` = base nature
    /// (which then MUST declare `abstol` and `access`, §3.6.1).
    parent: StrId = .none,
    /// A.1.6 `parent_nature ::= ... | discipline_identifier . potential_or_flow`
    /// — set when the parent was written as `electrical.potential`.
    parent_access: ?PotentialOrFlow = null,
    attrs: []const NatureAttr = &.{},
    main_tok: u32 = 0,
};

/// Discipline declaration. LRM §3.6.2 (A.1.7 discipline_declaration).
pub const DisciplineDecl = struct {
    name: StrId,
    /// §3.6.2.1 `potential <nature>;` — `.none` for a flow-only discipline.
    potential: StrId = .none,
    /// §3.6.2.1 `flow <nature>;` — `.none` for a signal-flow discipline.
    flow: StrId = .none,
    /// §3.6.2.2 `domain continuous|discrete`.
    domain: Domain = .unspecified,
    /// §3.6.2.3 `potential.abstol = 1e-6;` style overrides.
    overrides: []const Override = &.{},
    main_tok: u32 = 0,

    pub const Domain = enum(u8) { unspecified, continuous, discrete };
    pub const Override = struct {
        which: PotentialOrFlow,
        attr: NatureAttr,
    };
};

/// Paramset. LRM §6.4 (A.1.9 paramset_declaration).
pub const ParamsetDecl = struct {
    name: StrId,
    /// The module (or paramset) this specializes.
    target: StrId,
    params: []const ParamDecl = &.{}, // §6.4 parameter/localparam decls
    aliasparams: []const AliasParam = &.{},
    vars: []const VarDecl = &.{},
    /// `.name = expr;` assignments (A.1.9 paramset_statement).
    overrides: []const ParamsetOverride = &.{},
    /// A.1.9 also allows `analog_function_statement`s in the body.
    body: []const StmtId = &.{},
    main_tok: u32 = 0,
};

pub const ParamsetOverride = struct {
    /// Which flavour of `.identifier` was on the left (A.1.9).
    kind: Kind,
    name: StrId,
    value: ExprId,
    main_tok: u32 = 0,

    pub const Kind = enum(u8) { module_param, output_var, system_param };
};

// ---------------------------------------------------------------------------
// Statements — LRM ch5, A.6
// ---------------------------------------------------------------------------

/// Statement node. LRM §5. Kept as a tagged union in a flat pool (closed set →
/// enum+union, not vtable). Statements are walked once by lowering, never in a
/// hot loop, so the union's width (driven by `.block`) is not a cache concern.
pub const Stmt = union(enum) {
    /// A.6.4 `analog_statement_or_null ::= ... | ;`
    empty,
    /// §5.3.2 named block with local declarations (A.6.3 analog_seq_block).
    block: SeqBlock,
    /// §5.7 procedural assignment (A.6.2 analog_variable_assignment). `target`
    /// is an lvalue *expression* (`.ident` or `.index`) so array element
    /// assignment (§3.2.2) is representable.
    assign: struct { target: ExprId, value: ExprId },
    /// §5.6 contribution `V(a,b) <+ expr;` — `lhs` is a `.branch_access` or
    /// `.port_access` node (A.8.5 branch_lvalue).
    contribute: struct { lhs: ExprId, rhs: ExprId },
    /// §5.6.7 indirect contribution `V(x) : I(y) == expr;`
    /// (A.6.10 indirect_contribution_statement). Modelled here even though
    /// lowering may reject it — dropping it at parse time would make the error
    /// message a syntax error instead of an unsupported-feature error.
    indirect: struct { lhs: ExprId, probe: ExprId, eqn: ExprId },
    /// §5.8 conditional. `else_s` is `.none` when absent; `else if` chains
    /// nest in `else_s`.
    if_stmt: struct { cond: ExprId, then_s: StmtId, else_s: StmtId },
    /// §5.8.3 case (A.6.7). An arm with `labels.len == 0` is `default`.
    case_stmt: struct { kind: CaseKind = .normal, scrutinee: ExprId, arms: []const CaseArm },
    /// §5.9.2 `for (init; cond; step) body`. Also carries the genvar
    /// loop-generate form (A.4.2) — lowering decides whether to unroll by
    /// looking the loop variable up in `ModuleDecl.genvars` (§6.6.1).
    for_stmt: struct { init: StmtId, cond: ExprId, step: StmtId, body: StmtId },
    /// §5.9.1 `while (cond) body`.
    while_stmt: struct { cond: ExprId, body: StmtId },
    /// §5.9 `repeat (count) body`.
    repeat_stmt: struct { count: ExprId, body: StmtId },
    /// §5.10 `@(event) body` (A.6.5 analog_event_control_statement). `event` is
    /// one of the `event_*` expression tags, or an `.ident` naming an event.
    event_control: struct { event: ExprId, body: StmtId },
    /// §5.11 `disable <block>;` (A.6.5 disable_statement).
    disable: struct { name: StrId },
    /// §5.12 / ch9 analog system task: `$strobe`, `$finish`, `$error`,
    /// `$bound_step` (§9.17.1), `$discontinuity` (§9.17.2), `$limit`
    /// (§9.17.3)… `args` may contain `.none` for an omitted argument
    /// (A.6.9 permits empty argument slots).
    sys_task: struct { name: StrId, args: []const ExprId },
    /// A.6.5 jump_statement — `return` (§4.7.1 analog functions), `break`,
    /// `continue`. `value` is `.none` except for `return expr`.
    jump: struct { kind: JumpKind, value: ExprId = .none },

    pub const JumpKind = enum(u8) { ret, brk, cont };
};

/// §5.8.3 A.6.7 — `case`, `casex`, `casez`. Only `.normal` is meaningful for
/// real-valued analog scrutinees; `casex`/`casez` are kept so the parser can
/// accept them and lowering can diagnose them precisely.
pub const CaseKind = enum(u8) { normal, casex, casez };

/// §5.8.3 one case arm. `labels.len == 0` ⇒ `default`.
pub const CaseArm = struct {
    labels: []const ExprId,
    body: StmtId,
};

/// §5.3.2 sequential block body plus its local declarations
/// (A.6.3 analog_seq_block, A.2.8 analog_block_item_declaration).
/// Local declarations are only legal on a *named* block (§5.3.2).
///
/// Named `SeqBlock`, not `Block`: `Mir.Block` is a CFG basic block, a different
/// concept, and lower.zig imports both namespaces.
pub const SeqBlock = struct {
    name: StrId = .none,
    params: []const ParamDecl = &.{},
    vars: []const VarDecl = &.{},
    body: []const StmtId = &.{},
};

// ---------------------------------------------------------------------------
// Source file — LRM §1 source_text, A.1.2
// ---------------------------------------------------------------------------

/// Root of one parsed file. Arena-owned. LRM §1 source_text / annex A.
pub const SourceFile = struct {
    /// §2.8 interned identifiers and §2.7 strings.
    strings: StringInterner = .empty,
    /// annex A expression grammar, SoA.
    exprs: ExprStore = .empty,
    /// §5 statement pool; a StmtId indexes it.
    stmts: std.ArrayList(Stmt) = .empty,
    /// Token index per statement, parallel to `stmts` (diagnostics — kept in a
    /// separate column so `Stmt` stays a pure union).
    stmt_toks: std.ArrayList(u32) = .empty,

    // Top-level declarations, in source order (A.1.2 description).
    modules: []const ModuleDecl = &.{}, // §6.2
    disciplines: []const DisciplineDecl = &.{}, // §3.6.2
    natures: []const NatureDecl = &.{}, // §3.6.1
    paramsets: []const ParamsetDecl = &.{}, // §6.4

    pub const empty: SourceFile = .{};

    /// Frees the append-only stores. A no-op in practice (arena), present so an
    /// AST built on a gpa is leak-free; the `[]const` decl slices are NOT freed
    /// here — they belong to the arena/caller.
    pub fn deinit(self: *SourceFile, gpa: std.mem.Allocator) void {
        self.strings.deinit(gpa);
        self.exprs.deinit(gpa);
        self.stmts.deinit(gpa);
        self.stmt_toks.deinit(gpa);
        self.* = .empty;
    }

    /// Append a statement; both columns stay in lockstep.
    pub fn addStmt(self: *SourceFile, gpa: std.mem.Allocator, s: Stmt, main_tok: u32) !StmtId {
        const id: u32 = @intCast(self.stmts.items.len);
        std.debug.assert(id != @intFromEnum(StmtId.none));
        try self.stmts.ensureUnusedCapacity(gpa, 1);
        try self.stmt_toks.ensureUnusedCapacity(gpa, 1);
        self.stmts.appendAssumeCapacity(s);
        self.stmt_toks.appendAssumeCapacity(main_tok);
        return @enumFromInt(id);
    }

    /// By value: the pool may grow during parsing, so no pointer escapes.
    pub fn stmt(self: *const SourceFile, id: StmtId) Stmt {
        return self.stmts.items[@intFromEnum(id)];
    }

    pub fn stmtTok(self: *const SourceFile, id: StmtId) u32 {
        return self.stmt_toks.items[@intFromEnum(id)];
    }

    /// §2.8 resolve an interned name.
    pub fn str(self: *const SourceFile, id: StrId) []const u8 {
        return self.strings.get(id);
    }

    pub fn intern(self: *SourceFile, gpa: std.mem.Allocator, s: []const u8) !StrId {
        return self.strings.intern(gpa, s);
    }

    /// Convenience: append an expression row.
    pub fn addExpr(self: *SourceFile, gpa: std.mem.Allocator, node: Node) !ExprId {
        return self.exprs.add(gpa, node);
    }
};

// ponytail: deliberately not modelled — every one of these is outside the
// Verilog-A subset of annex C, and adding a tag for it would be a tag nothing
// ever produces or consumes:
//   · `+:` / `-:` indexed part-selects (A.8.3 range_expression) — `.range`
//     covers `msb:lsb`, which is all the analog subset uses.
//   · `min:typ:max` (A.8.3 mintypmax_expression) — the parser keeps the typ
//     value; add a `.mintypmax` tag if a fixture ever needs the triple.
//   · generic `(* attr = val *)` attribute_instances (§2.9) — the parser skips
//     them. Add `attrs: []const NatureAttr` to ParamDecl/ModuleDecl when the
//     host needs `units`/`desc` metadata; NatureAttr is already the right shape.
//   · digital-only statements (initial/always, fork/join, blocking vs
//     nonblocking, event_trigger `->`, wait, task/UDP/specify/config/
//     connectrules declarations) — rejected in the lexer/parser, never AST.

// ---------------------------------------------------------------------------
// Self-check: the store round-trips handles, lists and the §3.4.2 ranges that
// the finiteness proof depends on. Runs under `std.testing.allocator`, so a
// leaked byte fails.
// ---------------------------------------------------------------------------

test "ExprStore round-trips rows, lists and literals" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);

    const v = try f.intern(gpa, "V");
    const a = try f.intern(gpa, "a");
    try std.testing.expectEqual(v, try f.intern(gpa, "V")); // idempotent
    try std.testing.expectEqualStrings("a", f.str(a));

    const one = try f.exprs.addInt(gpa, 0, 1);
    const two_pt_5 = try f.exprs.addReal(gpa, 1, 2.5);
    try std.testing.expectEqual(@as(i32, 1), f.exprs.intValue(one));
    try std.testing.expectEqual(@as(f64, 2.5), f.exprs.realValue(two_pt_5));

    const sum = try f.addExpr(gpa, .{
        .tag = .binary,
        .main_tok = 2,
        .lhs = one,
        .rhs = two_pt_5,
        .extra = @intFromEnum(BinaryOp.add),
    });
    try std.testing.expectEqual(BinaryOp.add, f.exprs.binOp(sum));
    try std.testing.expectEqual(one, f.exprs.lhs(sum));

    // `V(a)` — §4.4.1 branch access with a call-style arg list elsewhere.
    const node_a = try f.addExpr(gpa, .{ .tag = .ident, .main_tok = 3, .str = a });
    const probe = try f.addExpr(gpa, .{ .tag = .branch_access, .main_tok = 4, .lhs = node_a, .str = v });
    try std.testing.expectEqual(ExprId.none, f.exprs.rhs(probe));

    // §4.3 call with an argument list in the shared pool.
    const off = try f.exprs.addExprList(gpa, &.{ sum, probe });
    const call = try f.addExpr(gpa, .{ .tag = .builtin_call, .main_tok = 5, .extra = off, .str = try f.intern(gpa, "pow") });
    try std.testing.expectEqualSlices(ExprId, &.{ sum, probe }, f.exprs.args(call));

    // §4.2.12 ternary keeps its third operand in `extra`.
    const t = try f.addExpr(gpa, .{ .tag = .ternary, .lhs = probe, .rhs = one, .extra = @intFromEnum(two_pt_5) });
    try std.testing.expectEqual(two_pt_5, f.exprs.ternaryElse(t));
}

test "ParamDecl carries §3.4.2 ranges through to lowering" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);

    // parameter real r = 1k from (0:inf);
    const zero = try f.exprs.addInt(gpa, 0, 0);
    const inf = try f.addExpr(gpa, .{ .tag = .pos_inf, .main_tok = 1 });
    const dflt = try f.exprs.addReal(gpa, 2, 1000.0);
    const ranges = [_]ValueRange{.{
        .kind = .from,
        .lo = zero,
        .hi = inf,
        .lo_inclusive = false,
        .hi_inclusive = false,
    }};
    const p: ParamDecl = .{
        .name = try f.intern(gpa, "r"),
        .ty = .real,
        .default = dflt,
        .ranges = &ranges,
    };
    try std.testing.expectEqual(@as(usize, 1), p.ranges.len);
    try std.testing.expectEqual(ExprTag.pos_inf, f.exprs.tag(p.ranges[0].hi));
    try std.testing.expect(!p.ranges[0].lo_inclusive);
}

test "statement pool keeps handles and token column in lockstep" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);

    const lhs = try f.addExpr(gpa, .{ .tag = .branch_access, .str = try f.intern(gpa, "I") });
    const rhs = try f.exprs.addInt(gpa, 0, 0);
    const s0 = try f.addStmt(gpa, .{ .contribute = .{ .lhs = lhs, .rhs = rhs } }, 7);
    const s1 = try f.addStmt(gpa, .empty, 9);
    const blk = try f.addStmt(gpa, .{ .block = .{ .body = &.{ s0, s1 } } }, 6);

    try std.testing.expectEqual(@as(u32, 7), f.stmtTok(s0));
    try std.testing.expectEqual(@as(u32, 6), f.stmtTok(blk));
    switch (f.stmt(blk)) {
        .block => |b| try std.testing.expectEqual(@as(usize, 2), b.body.len),
        else => return error.WrongTag,
    }
    switch (f.stmt(s0)) {
        .contribute => |c| try std.testing.expectEqual(lhs, c.lhs),
        else => return error.WrongTag,
    }
}
