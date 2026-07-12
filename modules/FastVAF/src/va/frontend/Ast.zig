const std = @import("std");

// ── Arena indices — u32, no raw pointers between AST nodes ────────────

pub const ExprId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn valid(self: ExprId) bool {
        return self != .none;
    }
};

pub const StmtId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn valid(self: StmtId) bool {
        return self != .none;
    }
};

// ── Expression tags (SoA layout) ─────────────────────────────────────
//
// Encoding per tag (lhs/rhs refer to expr_lhs[i], expr_rhs[i]):
//
//   literal_int_small : lhs = @bitCast(u32, @as(i32, val)),  rhs = 0
//   literal_int_large : lhs = extra_idx (2× u32 → i64 bits)
//   literal_real      : lhs = extra_idx (2× u32 → f64 bits)
//   literal_string    : lhs = str_ref_idx
//   literal_inf       : (no payload)
//   ident             : lhs = str_ref_idx
//   port_flow         : lhs = str_ref_idx
//   paren             : lhs = inner ExprId (as u32)
//
//   Unary ops         : lhs = operand ExprId
//   Binary ops        : lhs = left ExprId, rhs = right ExprId
//
//   ternary           : lhs = extra_idx (3× u32: cond, then, else ExprIds)
//   func_call         : lhs = str_ref_idx (name),
//                       rhs = extra_idx (extra[rhs] = arg_count,
//                                        extra[rhs+1..] = arg ExprIds)
//   system_call       : same as func_call
//   nature_access     : same as func_call
//   array             : lhs = extra_idx, rhs = element count
//
pub const ExprTag = enum(u8) {
    // ── literals ─────────────────────────────────────────────────────
    literal_int_small,
    literal_int_large,
    literal_real,
    literal_string,
    literal_inf,

    // ── references ───────────────────────────────────────────────────
    ident,
    port_flow,

    // ── grouping ─────────────────────────────────────────────────────
    paren,

    // ── unary ops ────────────────────────────────────────────────────
    negate,
    bit_not,
    logic_not,
    u_plus,

    // ── binary ops ───────────────────────────────────────────────────
    add,
    sub,
    mul,
    div,
    modulo,
    power,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    logic_and,
    logic_or,
    bit_and,
    bit_or,
    bit_xor,
    bit_nxor,
    shl,
    shr,
    ashl,
    ashr,

    // ── compound ─────────────────────────────────────────────────────
    ternary,
    func_call,
    system_call,
    nature_access,
    array,

    pub fn isBinary(self: ExprTag) bool {
        return @intFromEnum(self) >= @intFromEnum(ExprTag.add) and
            @intFromEnum(self) <= @intFromEnum(ExprTag.ashr);
    }

    pub fn isUnary(self: ExprTag) bool {
        return @intFromEnum(self) >= @intFromEnum(ExprTag.negate) and
            @intFromEnum(self) <= @intFromEnum(ExprTag.u_plus);
    }
};

// ── Top-level file ────────────────────────────────────────────────────

pub const SourceFile = struct {
    modules: []const ModuleDecl,
    disciplines: []const DisciplineDecl,
    natures: []const NatureDecl,
    paramsets: []const ParamsetDecl,
    stmts: []const Stmt,

    // ── SoA expression storage (9 bytes/node) ────────────────────────
    expr_tags: []const ExprTag = &.{},
    expr_lhs: []const u32 = &.{},
    expr_rhs: []const u32 = &.{},
    extra_data: []const u32 = &.{},
    str_refs: []const []const u8 = &.{},
};

// ── Disciplines & Natures ─────────────────────────────────────────────

pub const DisciplineDecl = struct {
    name: []const u8,
    potential_nature: ?[]const u8 = null,
    flow_nature: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    attrs: []const DisciplineAttr,
};

pub const DisciplineAttr = struct {
    name: []const u8,
    value: []const u8,
};

pub const NatureDecl = struct {
    name: []const u8,
    parent: ?[]const u8 = null,
    attrs: []const NatureAttr,
};

pub const NatureAttr = struct {
    name: []const u8,
    value: ExprId,
};

// ── Module ────────────────────────────────────────────────────────────

pub const ModuleDecl = struct {
    name: []const u8,
    ports: []const Port,
    items: []const ModuleItem,
};

pub const Port = struct {
    name: []const u8,
    direction: Direction = .inout,
};

pub const Direction = enum { input, output, inout };

pub const ModuleItem = union(enum) {
    port_decl: PortDecl,
    net_decl: NetDecl,
    branch_decl: BranchDecl,
    param_decl: ParamDecl,
    var_decl: VarDecl,
    alias_param: AliasParam,
    analog_block: AnalogBlock,
    analog_initial: AnalogBlock,
    func_decl: FuncDecl,
};

pub const PortDecl = struct {
    direction: Direction,
    discipline: ?[]const u8 = null,
    names: []const []const u8,
};

pub const NetDecl = struct {
    discipline: []const u8,
    names: []const []const u8,
};

pub const BranchDecl = struct {
    name: []const u8,
    node_a: []const u8,
    node_b: ?[]const u8 = null,
};

pub const ParamDecl = struct {
    is_local: bool = false,
    ty: Type,
    name: []const u8,
    default: ExprId = .none,
    ranges: []const Range,
};

pub const AliasParam = struct {
    name: []const u8,
    target: []const u8,
};

pub const ParamsetDecl = struct {
    name: []const u8,
    base_module: []const u8,
    params: []const ParamDecl,
};

pub const VarDecl = struct {
    ty: Type,
    names: []const []const u8,
    init_values: []const ExprId,
};

pub const FuncDecl = struct {
    return_type: Type,
    name: []const u8,
    args: []const FuncArg,
    body: StmtId,
};

pub const FuncArg = struct {
    direction: Direction,
    ty: Type,
    name: []const u8,
};

pub const AnalogBlock = struct {
    is_initial: bool = false,
    stmt: StmtId,
};

// ── Types & Ranges ────────────────────────────────────────────────────

pub const Type = enum { real, integer, string };

pub const Range = struct {
    kind: enum { from, exclude },
    lo_inclusive: bool,
    lo: ExprId,
    hi: ExprId,
    hi_inclusive: bool,
};

// ── Statements (arena-indexed via StmtId) ─────────────────────────────

pub const Stmt = union(enum) {
    empty,
    expr_stmt: ExprId,
    assign: struct { target: ExprId, value: ExprId },
    contribute: struct { kind: ContributeKind, branch: ExprId, rhs: ExprId },
    block: struct { name: ?[]const u8 = null, stmts: []const StmtId, local_vars: []const VarDecl, local_params: []const ParamDecl },
    if_stmt: struct { cond: ExprId, then_branch: StmtId, else_branch: StmtId },
    while_stmt: struct { cond: ExprId, body: StmtId },
    for_stmt: ForStmt,
    case_stmt: struct { discriminant: ExprId, arms: []const CaseArm },
    event_control: struct { event: ExprId, body: StmtId },
    disable: []const u8,
};

pub const ContributeKind = enum { potential, flow };

pub const ForStmt = struct {
    init_target: ExprId,
    init_value: ExprId,
    cond: ExprId,
    incr_target: ExprId,
    incr_value: ExprId,
    body: StmtId,
};

pub const CaseArm = struct {
    values: []const ExprId,
    body: StmtId,
};

pub const UnaryOp = enum { negate, bit_not, logic_not, plus };

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    modulo,
    power,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    logic_and,
    logic_or,
    bit_and,
    bit_or,
    bit_xor,
    bit_nxor,
    shl,
    shr,
    ashl,
    ashr,
};
