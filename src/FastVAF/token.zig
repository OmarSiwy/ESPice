//! Class 1 — Lexical tokens. LRM ch2 (§2.5 operators, §2.6 numbers, §2.7
//! strings, §2.8 identifiers/keywords/system-names), annex B (keywords).
//!
//! DOD: a token stored is only `{tag: Tag, start: u32}` (5 bytes). The end
//! offset is RECOMPUTED on demand by re-lexing from `start` — never stored.
//! Token streams live in a MultiArrayList (SoA), owned by the lexer's arena.
//!
//! Layout invariant: `Tag` is ordered `invalid, eof, <literals>, <symbols>,
//! <keywords>` and the keyword block is CONTIGUOUS AND LAST. `isKeyword` is a
//! single `>=` compare because of that. Do not interleave.
//!
//! Naming invariant: every keyword tag is `kw_` ++ its exact source spelling.
//! `keyword_map` is derived from the enum at comptime, so a tag and its lexeme
//! can never drift apart — add the tag and the keyword is live.

const std = @import("std");

/// Every lexical token kind. LRM §2.5 (operators), §2.8.2/annex B (keywords).
///
/// Scope: the Verilog-A analog subset (annex C). Annex B reserves ~215
/// keywords; ~135 of them are in scope and get a tag here. The remaining
/// reserved-but-out-of-scope keywords (digital primitives, specify blocks,
/// config files, and the annex C.16 exclusion list) all lex to the single
/// `kw_reserved` tag: they are still reserved words (never identifiers, per
/// annex B), but the parser rejects them with one shared diagnostic.
pub const Tag = enum(u8) {
    invalid,
    eof,

    // ---- literals & identifiers — §2.6, §2.7, §2.8 --------------------------
    identifier, // §2.8
    escaped_identifier, // §2.8.1  (\literally.anything<ws>)
    system_identifier, // §2.8.3  ($name)
    int_literal, // §2.6.1  (incl. sized/based: 4'b1101, 'h1f)
    real_literal, // §2.6.2  (incl. exponent and SI scale suffix)
    string_literal, // §2.7

    // ---- operators — §2.5, table 4-1 ---------------------------------------
    // arithmetic §4.2.4
    plus,
    minus,
    star,
    slash,
    percent,
    star_star, // '**'  power §4.2.4
    // contribution §5.6 / assignment §5.5
    contribute, // '<+'
    assign_eq, // '='
    // relational §4.2.5
    lt,
    gt,
    lt_eq,
    gt_eq,
    // equality §4.2.7 / case equality §4.2.6 (lexed, rejected in Verilog-A per C.5)
    eq_eq,
    bang_eq,
    eq_eq_eq, // '==='
    bang_eq_eq, // '!=='
    // logical §4.2.8
    bang,
    amp_amp,
    pipe_pipe,
    // bitwise §4.2.9 / reduction §4.2.10 (same lexemes; distinguished by parse position)
    tilde,
    amp,
    pipe,
    caret,
    tilde_caret, // '~^'  xnor
    caret_tilde, // '^~'  xnor
    tilde_amp, // '~&'  reduction nand
    tilde_pipe, // '~|'  reduction nor
    // shifts §4.2.11
    lt_lt,
    gt_gt,
    lt_lt_lt, // '<<<' arithmetic shift (not legal in an analog block)
    gt_gt_gt, // '>>>'
    // conditional §4.2.12
    question,
    colon,

    // ---- punctuation -------------------------------------------------------
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace, // §4.2.13 concatenation / §5.x block delimiters are begin/end
    rbrace,
    semicolon,
    comma,
    dot, // hierarchical names §6.x, named port/param association
    at, // event control §5.10
    hash, // parameter override / delay §6.x
    apostrophe_lbrace, // "'{"  assignment pattern §4.2.14
    attr_open, // '(*'  attribute instance §2.9
    attr_close, // '*)'  §2.9

    // ---- the two directives the preprocessor hands to the parser — §10.6 ----
    // Every other compiler directive dies in the preprocessor. These two do
    // not: they select the reserved-keyword set for the design elements that
    // follow, and §10.6 requires them to sit outside a design element — a fact
    // only the parser can check. See `KeywordSet`.
    dir_begin_keywords, // '`begin_keywords'
    dir_end_keywords, // '`end_keywords'

    // ---- keywords — §2.8.2 / annex B ---------------------------------------
    // FIRST KEYWORD. Everything from here to the end of the enum is a keyword;
    // `isKeyword` depends on it. Tag name = "kw_" ++ source spelling, always.

    // module & source-text structure §6.2, §6.4, annex A.1
    kw_module,
    kw_macromodule,
    kw_endmodule,
    kw_paramset,
    kw_endparamset,
    kw_function,
    kw_endfunction,
    kw_analog, // §5.2
    kw_initial, // 'analog initial' §5.2
    kw_begin,
    kw_end,
    kw_generate, // §6.9
    kw_endgenerate,

    // declarations §3.x
    kw_parameter, // §3.4
    kw_localparam, // §3.4.4
    kw_aliasparam, // §3.4.5
    kw_integer, // §3.3
    kw_real,
    kw_string, // §3.3.3
    kw_realtime,
    kw_time,
    kw_reg,
    kw_event, // §3.3 named event (declared; analog events are @-driven)
    kw_genvar, // §3.11
    kw_branch, // §3.10 branch declaration

    // ports & net types §3.5, §6.5, annex A.2.1.3
    kw_input,
    kw_output,
    kw_inout,
    kw_wire,
    kw_tri,
    kw_tri0,
    kw_tri1,
    kw_triand,
    kw_trior,
    kw_trireg,
    kw_wand,
    kw_wor,
    kw_uwire,
    kw_supply0,
    kw_supply1,
    kw_signed,
    kw_unsigned,
    kw_scalared,
    kw_vectored,

    // disciplines & natures §3.6, §3.9, annex D
    kw_discipline,
    kw_enddiscipline,
    kw_nature,
    kw_endnature,
    kw_domain, // §3.6.2.2
    kw_continuous, // §3.6.2.2
    kw_discrete, // §3.6.2.2 — an error in Verilog-A (annex C.4), still lexed
    kw_potential, // §3.6.2.1
    kw_flow,
    kw_abstol, // §3.9.1
    kw_access,
    kw_units,
    kw_ddt_nature,
    kw_idt_nature,
    kw_ground, // §3.10.2

    // parameter value ranges §3.4.2
    kw_from,
    kw_exclude,
    kw_inf,

    // control flow §5.7, §5.8
    kw_if,
    kw_else,
    kw_case,
    kw_casex, // not supported in Verilog-A (annex C.7) — lexed, then rejected
    kw_casez, // ditto
    kw_endcase,
    kw_default,
    kw_for,
    kw_while,
    kw_repeat,
    kw_forever,
    kw_return, // §5.9 analog function return
    kw_break,
    kw_continue,
    kw_disable,

    // event expressions §5.10
    kw_or, // '@(a or b)' — event or; also the digital gate type
    kw_initial_step,
    kw_final_step,
    kw_cross, // §5.10.3
    kw_above, // §5.10.4
    kw_timer, // §5.10.5
    kw_absdelta, // §5.10.6

    // analog operators & filters §4.5
    kw_ddt,
    kw_ddx, // §4.5.9
    kw_idt,
    kw_idtmod,
    kw_absdelay, // §4.5.2
    kw_transition, // §4.5.3
    kw_slew, // §4.5.4
    kw_last_crossing, // §4.5.5
    kw_laplace_zd, // §4.5.6
    kw_laplace_zp,
    kw_laplace_nd,
    kw_laplace_np,
    kw_zi_zd, // §4.5.7
    kw_zi_zp,
    kw_zi_nd,
    kw_zi_np,
    // small-signal / noise sources §4.6
    kw_analysis,
    kw_ac_stim,
    kw_white_noise,
    kw_flicker_noise,
    kw_noise_table,
    kw_noise_table_log,

    // math functions §4.3.2 (with domain tables) / §4.3.3 transcendental
    kw_abs,
    kw_max,
    kw_min,
    kw_pow,
    kw_sqrt,
    kw_exp,
    kw_limexp, // §4.5.13 — bounded-derivative exp (a FILTER, A.8.2); never synthesized by us
    kw_ln,
    kw_log,
    kw_expm1,
    kw_ln1p,
    kw_hypot,
    kw_floor,
    kw_ceil,
    kw_sin,
    kw_cos,
    kw_tan,
    kw_asin,
    kw_acos,
    kw_atan,
    kw_atan2,
    kw_sinh,
    kw_cosh,
    kw_tanh,
    kw_asinh,
    kw_acosh,
    kw_atanh,

    /// Any annex B reserved keyword that is out of the analog subset's scope
    /// (digital primitives, specify/table, config files, and the annex C.16
    /// exclusions). Reserved — never an identifier — but not parseable. The
    /// spelling is not recoverable from the tag; slice the source at `start`.
    kw_reserved,

    /// First keyword tag. Keeps `isKeyword` a single compare (see file header).
    pub const first_keyword: Tag = .kw_module;

    /// Source spelling, for diagnostics. `null` when the text is not implied by
    /// the tag (identifiers, literals, `kw_reserved`) — slice the source then.
    pub fn lexeme(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .invalid, .eof, .kw_reserved => null,
            .identifier,
            .escaped_identifier,
            .system_identifier,
            .int_literal,
            .real_literal,
            .string_literal,
            => null,

            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .star_star => "**",
            .contribute => "<+",
            .assign_eq => "=",
            .lt => "<",
            .gt => ">",
            .lt_eq => "<=",
            .gt_eq => ">=",
            .eq_eq => "==",
            .bang_eq => "!=",
            .eq_eq_eq => "===",
            .bang_eq_eq => "!==",
            .bang => "!",
            .amp_amp => "&&",
            .pipe_pipe => "||",
            .tilde => "~",
            .amp => "&",
            .pipe => "|",
            .caret => "^",
            .tilde_caret => "~^",
            .caret_tilde => "^~",
            .tilde_amp => "~&",
            .tilde_pipe => "~|",
            .lt_lt => "<<",
            .gt_gt => ">>",
            .lt_lt_lt => "<<<",
            .gt_gt_gt => ">>>",
            .question => "?",
            .colon => ":",
            .lparen => "(",
            .rparen => ")",
            .lbracket => "[",
            .rbracket => "]",
            .lbrace => "{",
            .rbrace => "}",
            .semicolon => ";",
            .comma => ",",
            .dot => ".",
            .at => "@",
            .hash => "#",
            .apostrophe_lbrace => "'{",
            .attr_open => "(*",
            .attr_close => "*)",
            .dir_begin_keywords => "`begin_keywords",
            .dir_end_keywords => "`end_keywords",

            // Every keyword tag is "kw_" ++ its spelling (naming invariant).
            else => @tagName(tag)[3..],
        };
    }

    /// `lexeme` in backticks — what a diagnostic prints when it has to name the
    /// character the user must type. Derived from `lexeme` at comptime, through
    /// `inline else`, so the two spellings cannot drift apart and no second
    /// table exists to forget.
    pub fn quoted(tag: Tag) ?[]const u8 {
        return switch (tag) {
            inline else => |t| comptime blk: {
                const l = lexeme(t) orelse break :blk null;
                break :blk "`" ++ l ++ "`";
            },
        };
    }
};

/// SoA row. Keep it 5 bytes; do not add fields (recompute, don't store).
pub const Stored = struct {
    tag: Tag,
    start: u32,
};

/// Keyword lookup. LRM §2.8.2 / annex B. Comptime-built, O(1), no allocation.
/// Derived from `Tag` — see the naming invariant in the file header.
pub const keyword_map = std.StaticStringMap(Tag).initComptime(keyword_kvs);

// ---- §10.6 `begin_keywords: which words are RESERVED ----------------------

/// LRM §10.6 version_specifier: "specifies the valid set of reserved keywords
/// in effect when a design unit is parsed". The five specifiers an
/// implementation "must also support" form a chain, oldest first:
///
///     1364-1995 ⊂ 1364-2001 ⊂ 1364-2005 ⊂ VAMS-2.3 ⊂ VAMS-2023
///
/// so one `introducedIn` datum per keyword decides membership in all five:
/// a word is reserved in set `s` iff it was introduced no later than `s`.
///
/// SCOPE (§10.6, verbatim): "The `begin_keywords and `end_keywords directives
/// only specify the set of identifiers that are reserved as keywords. The
/// directives do not affect the semantics, tokens, and other aspects of the
/// Verilog-AMS language." So the LEXER IS UNAFFECTED — `sin` keeps lexing to
/// `kw_sin` under every set. What changes is whether the parser will accept
/// that token where an identifier is expected (`Parser.identLike`). That is
/// also the only reading under which the §10.6 worked example composes: a
/// module using `analog` (a VAMS-only annex B keyword) under
/// `begin_keywords "1364-2005" still parses, while `input sin;` becomes legal.
pub const KeywordSet = enum(u8) {
    v1364_1995,
    v1364_2001,
    v1364_2005,
    vams_2_3,
    vams_2023,

    /// §10.6 version_specifier string → set. `null` for anything else; the LRM
    /// names exactly these five, so an unknown specifier is an error.
    pub fn fromSpecifier(text: []const u8) ?KeywordSet {
        return specifier_map.get(text);
    }
};

/// The implementation's default set when no `begin_keywords is in effect
/// (§10.6: "the implementation's default set of reserved keywords").
pub const default_keyword_set: KeywordSet = .vams_2023;

const specifier_map = std.StaticStringMap(KeywordSet).initComptime(.{
    .{ "1364-1995", KeywordSet.v1364_1995 },
    .{ "1364-2001", KeywordSet.v1364_2001 },
    .{ "1364-2005", KeywordSet.v1364_2005 },
    .{ "VAMS-2.3", KeywordSet.vams_2_3 },
    .{ "VAMS-2023", KeywordSet.vams_2023 },
});

/// LRM §10.6 / annex B. Is the keyword spelled `name` a reserved word under
/// `set`? Only meaningful for a spelling that is in `keyword_map` at all.
pub fn isReserved(name: []const u8, set: KeywordSet) bool {
    return @intFromEnum(introducedIn(name)) <= @intFromEnum(set);
}

/// Oldest keyword set in which `name` is reserved. Everything not on one of
/// the IEEE 1364 lists below is a Verilog-AMS keyword, and annex G dates the
/// handful that arrived after VAMS-2.3.
fn introducedIn(name: []const u8) KeywordSet {
    return keyword_intro.get(name) orelse .vams_2_3;
}

// ---- predicates the lexer/parser want ------------------------------------

/// LRM §2.8.2 / annex B. Escaped identifiers are never keywords (§2.8.1); the
/// lexer must not consult `keyword_map` for them.
pub fn isKeyword(tag: Tag) bool {
    return @intFromEnum(tag) >= @intFromEnum(Tag.first_keyword);
}

/// LRM §3.5 / §6.5 port direction.
pub fn isPortDirection(tag: Tag) bool {
    return switch (tag) {
        .kw_input, .kw_output, .kw_inout => true,
        else => false,
    };
}

/// LRM §3.7 / annex A.2.1.3 net type (optional prefix on a discipline decl).
pub fn isNetType(tag: Tag) bool {
    return switch (tag) {
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
        => true,
        else => false,
    };
}

/// LRM §3.3 variable/parameter base type keyword.
pub fn isDataType(tag: Tag) bool {
    return switch (tag) {
        .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time, .kw_reg => true,
        else => false,
    };
}

/// LRM §4.3.2/§4.3.3 — built-in math functions. EXACTLY annex A.8.2
/// `analog_built_in_function_name` (26 names); the parser turns these into
/// `Ast.ExprTag.builtin_call`. These are the tags whose domains `proof.zig`
/// must discharge at compile time (invariant 5).
///
/// NOTE `limexp` is NOT here: A.8.2 lists it under
/// `analog_filter_function_call` (§4.5.13), so it is a filter function —
/// see `isFilterFunction`.
pub fn isMathFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_abs,
        .kw_max,
        .kw_min,
        .kw_pow,
        .kw_sqrt,
        .kw_exp,
        .kw_ln,
        .kw_log,
        .kw_expm1,
        .kw_ln1p,
        .kw_hypot,
        .kw_floor,
        .kw_ceil,
        .kw_sin,
        .kw_cos,
        .kw_tan,
        .kw_asin,
        .kw_acos,
        .kw_atan,
        .kw_atan2,
        .kw_sinh,
        .kw_cosh,
        .kw_tanh,
        .kw_asinh,
        .kw_acosh,
        .kw_atanh,
        => true,
        else => false,
    };
}

/// LRM §4.5 — analog filter operators. EXACTLY annex A.8.2
/// `analog_filter_function_call` (17 names, `limexp` included); the parser
/// turns these into `Ast.ExprTag.filter_call`. Each occurrence owns runtime
/// state (§4.5.1).
pub fn isFilterFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_ddt,
        .kw_ddx,
        .kw_idt,
        .kw_idtmod,
        .kw_absdelay,
        .kw_transition,
        .kw_slew,
        .kw_last_crossing,
        .kw_limexp, // §4.5.13 — A.8.2 lists it here, not with the math builtins
        .kw_laplace_zd,
        .kw_laplace_zp,
        .kw_laplace_nd,
        .kw_laplace_np,
        .kw_zi_zd,
        .kw_zi_zp,
        .kw_zi_nd,
        .kw_zi_np,
        => true,
        else => false,
    };
}

/// LRM §4.6 — small-signal / noise sources. EXACTLY annex A.8.2
/// `analog_small_signal_function_call` minus `analysis` (which A.8.2 gives its
/// own production and which the parser folds into `Ast.ExprTag.sys_call`).
/// These become `Ast.ExprTag.noise_call`.
pub fn isSmallSignalFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_ac_stim,
        .kw_white_noise,
        .kw_flicker_noise,
        .kw_noise_table,
        .kw_noise_table_log,
        => true,
        else => false,
    };
}

/// LRM §4.5/§4.6 — everything that carries per-instance runtime state, so it
/// may not appear in a conditional/loop whose controlling expression is not
/// constant (§4.5.1, §5.8.4). Union of the two groups above.
pub fn isAnalogOperator(tag: Tag) bool {
    return isFilterFunction(tag) or isSmallSignalFunction(tag);
}

/// LRM §5.10.3 — EXACTLY annex A.6.5 `analog_event_functions` (4 names), legal
/// only inside an `@( ... )` event control. These become
/// `Ast.ExprTag.event_function`.
///
/// NOTE `initial_step`/`final_step` are NOT here: A.6.5 gives them their own
/// `analog_event_expression` alternatives (an optional list of *string*
/// analysis names, not expressions) and the AST gives them their own tags
/// `event_initial_step` / `event_final_step`.
pub fn isEventFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_cross,
        .kw_above,
        .kw_timer,
        .kw_absdelta,
        => true,
        else => false,
    };
}

/// A keyword that starts a call-like expression: `name ( args )`. Union of the
/// math (§4.3), filter (§4.5), small-signal (§4.6) and event (§5.10.3) groups
/// plus `analysis` (§4.6.1) and the §5.10.2 step events.
pub fn isBuiltinFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_analysis, .kw_initial_step, .kw_final_step => true,
        else => isMathFunction(tag) or isAnalogOperator(tag) or isEventFunction(tag),
    };
}

// ---- keyword table construction ------------------------------------------

const KV = struct { []const u8, Tag };

/// Annex B keywords that are reserved but out of the analog subset's scope:
/// IEEE 1364 digital primitives/gates, specify + table, config-file keywords,
/// and the annex C.16 "not used by Verilog-A" list. All lex to `.kw_reserved`.
/// Keeping them in the map is what makes them unusable as identifiers (annex B).
const reserved_keywords = [_][]const u8{
    // annex C.16 — not used by Verilog-A
    "connect",            "connectmodule", "connectrules", "driver_update",
    "endconnectrules",    "merged",        "resolveto",    "split",
    "wreal",
    // digital behavior / structural §IEEE1364
                 "always",        "and",          "assign",
    "automatic",          "buf",           "bufif0",       "bufif1",
    "cmos",               "deassign",      "defparam",     "edge",
    "endprimitive",       "endspecify",    "endtable",     "endtask",
    "force",              "fork",          "highz0",       "highz1",
    "ifnone",             "join",          "large",        "medium",
    "nand",               "negedge",       "nmos",         "nor",
    "noshowcancelled",    "not",           "notif0",       "notif1",
    "pmos",               "posedge",       "primitive",    "pull0",
    "pull1",              "pulldown",      "pullup",       "pulsestyle_ondetect",
    "pulsestyle_onevent", "rcmos",         "release",      "rnmos",
    "rpmos",              "rtran",         "rtranif0",     "rtranif1",
    "showcancelled",      "small",         "specify",      "specparam",
    "strong0",            "strong1",       "table",        "task",
    "tran",               "tranif0",       "tranif1",      "wait",
    "weak0",              "weak1",         "xnor",         "xor",
    // configuration / library (IEEE 1364 clause 13)
    "cell",               "config",        "design",       "endconfig",
    "incdir",             "include",       "instance",     "liblist",
    "library",            "use",
};

/// IEEE Std 1364-1995 reserved words (102). The oldest set §10.6 names, and a
/// subset of every later one.
const kw_1364_1995 = [_][]const u8{
    "always",    "and",          "assign",     "begin",
    "buf",       "bufif0",       "bufif1",     "case",
    "casex",     "casez",        "cmos",       "deassign",
    "default",   "defparam",     "disable",    "edge",
    "else",      "end",          "endcase",    "endfunction",
    "endmodule", "endprimitive", "endspecify", "endtable",
    "endtask",   "event",        "for",        "force",
    "forever",   "fork",         "function",   "highz0",
    "highz1",    "if",           "ifnone",     "initial",
    "inout",     "input",        "integer",    "join",
    "large",     "macromodule",  "medium",     "module",
    "nand",      "negedge",      "nmos",       "nor",
    "not",       "notif0",       "notif1",     "or",
    "output",    "parameter",    "pmos",       "posedge",
    "primitive", "pull0",        "pull1",      "pulldown",
    "pullup",    "rcmos",        "real",       "realtime",
    "reg",       "release",      "repeat",     "rnmos",
    "rpmos",     "rtran",        "rtranif0",   "rtranif1",
    "scalared",  "small",        "specify",    "specparam",
    "strong0",   "strong1",      "supply0",    "supply1",
    "table",     "task",         "time",       "tran",
    "tranif0",   "tranif1",      "tri",        "tri0",
    "tri1",      "triand",       "trior",      "trireg",
    "vectored",  "wait",         "wand",       "weak0",
    "weak1",     "while",        "wire",       "wor",
    "xnor",      "xor",
};

/// Added by IEEE Std 1364-2001 (21): generate/config/library and signedness.
const kw_1364_2001 = [_][]const u8{
    "automatic",          "cell",          "config",          "design",
    "endconfig",          "endgenerate",   "generate",        "genvar",
    "incdir",             "include",       "instance",        "liblist",
    "library",            "localparam",    "noshowcancelled", "pulsestyle_ondetect",
    "pulsestyle_onevent", "showcancelled", "signed",          "unsigned",
    "use",
};

/// Added by IEEE Std 1364-2005 (1).
const kw_1364_2005 = [_][]const u8{"uwire"};

/// Verilog-AMS keywords that postdate the "VAMS-2.3" specifier, per annex G
/// tables G.6 (v2.3.1→v2.4) and G.7 (v2.4→VAMS-2023): `$noise_table_log`
/// (G.6 item 4349), `absdelta` (G.6 item 4803), `return`/`break`/`continue`
/// (G.7 item 830) and `expm1`/`ln1p` (G.7 item 7780). Every other VAMS keyword
/// defaults to `.vams_2_3` — see `introducedIn`.
const kw_vams_2023 = [_][]const u8{
    "absdelta", "break", "continue", "expm1", "ln1p", "noise_table_log", "return",
};

const keyword_intro = std.StaticStringMap(KeywordSet).initComptime(intro_kvs);

const IntroKV = struct { []const u8, KeywordSet };

const intro_kvs = kvs: {
    @setEvalBranchQuota(20_000);
    const n = kw_1364_1995.len + kw_1364_2001.len + kw_1364_2005.len + kw_vams_2023.len;
    var out: [n]IntroKV = undefined;
    var i: usize = 0;
    for (kw_1364_1995) |name| {
        out[i] = .{ name, .v1364_1995 };
        i += 1;
    }
    for (kw_1364_2001) |name| {
        out[i] = .{ name, .v1364_2001 };
        i += 1;
    }
    for (kw_1364_2005) |name| {
        out[i] = .{ name, .v1364_2005 };
        i += 1;
    }
    for (kw_vams_2023) |name| {
        out[i] = .{ name, .vams_2023 };
        i += 1;
    }
    const frozen = out;
    break :kvs frozen;
};

const keyword_kvs = kvs: {
    @setEvalBranchQuota(20_000);
    const fields = @typeInfo(Tag).@"enum".fields;

    var n: usize = reserved_keywords.len;
    for (fields) |f| {
        if (std.mem.startsWith(u8, f.name, "kw_") and !std.mem.eql(u8, f.name, "kw_reserved")) n += 1;
    }

    var out: [n]KV = undefined;
    var i: usize = 0;
    for (fields) |f| {
        if (!std.mem.startsWith(u8, f.name, "kw_")) continue;
        if (std.mem.eql(u8, f.name, "kw_reserved")) continue;
        out[i] = .{ f.name[3..], @field(Tag, f.name) };
        i += 1;
    }
    for (reserved_keywords) |name| {
        out[i] = .{ name, .kw_reserved };
        i += 1;
    }
    const frozen = out;
    break :kvs frozen;
};

// ---- checks ---------------------------------------------------------------

test "layout invariant: keyword block is contiguous and last" {
    // Every kw_* tag is >= first_keyword, and nothing before it is a keyword.
    @setEvalBranchQuota(20_000);
    inline for (@typeInfo(Tag).@"enum".fields) |f| {
        const is_kw_name = comptime std.mem.startsWith(u8, f.name, "kw_");
        try std.testing.expectEqual(is_kw_name, isKeyword(@field(Tag, f.name)));
    }
    try std.testing.expect(!isKeyword(.eof));
    try std.testing.expect(!isKeyword(.attr_close));
    // Tag must stay in u8 (enum(u8)); this fails loudly if the set outgrows it.
    try std.testing.expect(@typeInfo(Tag).@"enum".fields.len <= 256);
}

test "keyword_map: spelling round-trips through lexeme" {
    for (keyword_map.keys(), keyword_map.values()) |key, tag| {
        if (tag == .kw_reserved) continue;
        try std.testing.expectEqualStrings(key, Tag.lexeme(tag).?);
    }
    try std.testing.expectEqual(Tag.kw_module, keyword_map.get("module").?);
    try std.testing.expectEqual(Tag.kw_initial_step, keyword_map.get("initial_step").?);
    try std.testing.expectEqual(Tag.kw_reserved, keyword_map.get("posedge").?);
    // Not keywords: system function names (§2.8.3) and ordinary identifiers.
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("temperature"));
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("V"));
}

test "§10.6 keyword sets nest, and the intro table cannot drift from annex B" {
    // Anti-drift: every name that has an introduction date must actually be a
    // keyword. A typo here would silently un-reserve nothing at all.
    for (keyword_intro.keys()) |name| {
        if (keyword_map.get(name) == null) {
            std.debug.print("keyword_intro names a non-keyword: {s}\n", .{name});
            return error.NotAKeyword;
        }
    }
    // Counts straight from the standards (see the array doc comments).
    try std.testing.expectEqual(102, kw_1364_1995.len);
    try std.testing.expectEqual(21, kw_1364_2001.len);

    // The five sets are a chain: reserved in an older set ⇒ reserved in every
    // newer one. `sin` is the LRM §10.6 worked example.
    for (keyword_map.keys()) |name| {
        var prev = false;
        for ([_]KeywordSet{ .v1364_1995, .v1364_2001, .v1364_2005, .vams_2_3, .vams_2023 }) |s| {
            const now = isReserved(name, s);
            try std.testing.expect(!prev or now); // monotone
            prev = now;
        }
        try std.testing.expect(isReserved(name, .vams_2023)); // annex B is the union
    }
    try std.testing.expect(!isReserved("sin", .v1364_2005));
    try std.testing.expect(isReserved("sin", .vams_2_3));
    try std.testing.expect(isReserved("module", .v1364_1995));
    try std.testing.expect(!isReserved("localparam", .v1364_1995));
    try std.testing.expect(isReserved("localparam", .v1364_2001));
    try std.testing.expect(!isReserved("uwire", .v1364_2001));
    try std.testing.expect(isReserved("uwire", .v1364_2005));
    try std.testing.expect(!isReserved("ln1p", .vams_2_3)); // annex G.7 item 7780
    try std.testing.expect(isReserved("ln1p", .vams_2023));
    // §10.6 version_specifier strings, all five of them.
    try std.testing.expectEqual(KeywordSet.v1364_1995, KeywordSet.fromSpecifier("1364-1995").?);
    try std.testing.expectEqual(KeywordSet.v1364_2001, KeywordSet.fromSpecifier("1364-2001").?);
    try std.testing.expectEqual(KeywordSet.v1364_2005, KeywordSet.fromSpecifier("1364-2005").?);
    try std.testing.expectEqual(KeywordSet.vams_2_3, KeywordSet.fromSpecifier("VAMS-2.3").?);
    try std.testing.expectEqual(KeywordSet.vams_2023, KeywordSet.fromSpecifier("VAMS-2023").?);
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier("1800-2017"));
}

test "call groups match annex A.8.2/A.6.5 exactly and are disjoint" {
    // One group per Ast.ExprTag the parser produces. Counts come straight from
    // the grammar: analog_built_in_function_name = 26, analog_filter_function_
    // call = 17, analog_small_signal_function_call = 5, analog_event_functions
    // = 4. If a tag lands in two groups the parser would pick the wrong tag.
    var counts = [_]u32{ 0, 0, 0, 0 };
    inline for (@typeInfo(Tag).@"enum".fields) |f| {
        const t: Tag = @field(Tag, f.name);
        var n: u32 = 0;
        if (isMathFunction(t)) {
            counts[0] += 1;
            n += 1;
        }
        if (isFilterFunction(t)) {
            counts[1] += 1;
            n += 1;
        }
        if (isSmallSignalFunction(t)) {
            counts[2] += 1;
            n += 1;
        }
        if (isEventFunction(t)) {
            counts[3] += 1;
            n += 1;
        }
        try std.testing.expect(n <= 1);
        if (n == 1) try std.testing.expect(isBuiltinFunction(t));
    }
    try std.testing.expectEqual([_]u32{ 26, 17, 5, 4 }, counts);
    // §4.5.13: limexp is a filter, never a math builtin (proof.zig must not
    // put a domain on it, codegen must give it state).
    try std.testing.expect(isFilterFunction(.kw_limexp) and !isMathFunction(.kw_limexp));
    // §5.10.2 step events are their own Ast tags, not `event_function`s.
    try std.testing.expect(!isEventFunction(.kw_initial_step) and isBuiltinFunction(.kw_initial_step));
}

test "Stored stays 5 bytes of payload (SoA columns, no len field)" {
    try std.testing.expectEqual(2, @typeInfo(Stored).@"struct".fields.len);
    try std.testing.expectEqual(1, @sizeOf(Tag));
    try std.testing.expectEqual(4, @sizeOf(u32));
}
