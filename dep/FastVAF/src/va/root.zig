pub const Mir = @import("ir/Mir.zig");
pub const SsaBuilder = @import("ir/SsaBuilder.zig");
pub const Lower = @import("ir/Lower.zig");
pub const print_mir = @import("ir/print.zig");

pub const Lexer = @import("frontend/Lexer.zig");
pub const Token = @import("frontend/Token.zig");
pub const Parser = @import("frontend/Parser.zig");
pub const Ast = @import("frontend/Ast.zig");
pub const Preprocessor = @import("frontend/Preprocessor.zig");

pub const codegen = @import("backend/codegen.zig");

const std = @import("std");
const Buf = @import("emit").Buf;

/// Growable diagnostic sink callers pass to `compileSource`.
pub const DiagnosticList = Buf(Diagnostic);

pub const CompileResult = struct {
    mir: Mir,
    lower: Lower,
    _arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CompileResult) void {
        self.mir.deinit();
        self._arena.deinit();
    }
};

pub const Diagnostic = struct {
    line: u32,
    col: u32,
    message: []const u8,
    found: []const u8,
    source_line: []const u8,
};

pub const CompileError = error{
    ParseError,
    NoModule,
    OutOfMemory,
};

fn reportErrors(parser: *Parser, preprocessed: []const u8, allocator: std.mem.Allocator, errors_out: ?*DiagnosticList) void {
    if (errors_out) |diags| {
        for (parser.errors.slice()) |err| {
            const loc = parser.sourceLocation(err.token_pos);
            const found = if (err.token_pos < parser.tokens.len)
                parser.tokenText(err.token_pos)
            else
                "EOF";
            const src_line = if (loc.line_start < loc.line_end)
                preprocessed[loc.line_start..loc.line_end]
            else
                "";
            diags.append(allocator, .{
                .line = loc.line,
                .col = loc.col,
                .message = err.msg,
                .found = found,
                .source_line = src_line,
            }) catch {};
        }
    } else {
        for (parser.errors.slice()) |err| {
            const loc = parser.sourceLocation(err.token_pos);
            const found = if (err.token_pos < parser.tokens.len)
                parser.tokenText(err.token_pos)
            else
                "EOF";
            std.debug.print("{d}:{d}: error: expected {s}, got '{s}'\n", .{ loc.line, loc.col, err.msg, found });
        }
    }
}

pub const CompileOpts = struct {
    /// Needed to resolve non-standard `` `include `` files.
    io: ?std.Io = null,
    /// Directories local `` `include `` paths resolve against (typically the
    /// dir of the .va file itself).
    include_dirs: []const []const u8 = &.{},
};

pub fn compileSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    errors_out: ?*DiagnosticList,
) CompileError!CompileResult {
    return compileSourceOpts(allocator, source, errors_out, .{});
}

pub fn compileSourceOpts(
    allocator: std.mem.Allocator,
    source: []const u8,
    errors_out: ?*DiagnosticList,
    opts: CompileOpts,
) CompileError!CompileResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const preprocessed = Preprocessor.processWithIncludes(arena_alloc, source, opts.io, opts.include_dirs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.debug.print("zvaf: preprocessor error: {t}\n", .{err});
            return error.ParseError;
        },
    };

    var parser = try Parser.init(arena_alloc, preprocessed);

    if (parser.has_unclosed_comment) {
        std.debug.print("error: unclosed block comment\n", .{});
        return error.ParseError;
    }

    const file = parser.parseSourceFile() catch {
        reportErrors(&parser, preprocessed, allocator, errors_out);
        return error.ParseError;
    };

    if (parser.errors.len > 0) {
        reportErrors(&parser, preprocessed, allocator, errors_out);
    }

    if (file.modules.len == 0) return error.NoModule;

    const module = &file.modules[file.modules.len - 1];
    var mir = Mir.init(allocator, module.name);
    var lower = try Lower.init(arena_alloc, &mir, file.stmts, file.expr_tags, file.expr_lhs, file.expr_rhs, file.extra_data, file.str_refs);
    try lower.lowerModule(module);

    for (file.paramsets) |ps| {
        for (ps.params) |*pd| {
            try lower.lowerParamDecl(pd);
        }
    }

    lower.builder.deinit();
    return .{ .mir = mir, .lower = lower, ._arena = arena };
}

test {
    _ = @import("frontend/Lexer.zig");
    _ = @import("frontend/Token.zig");
    _ = @import("frontend/Parser.zig");
    _ = @import("frontend/Ast.zig");
    _ = @import("frontend/Preprocessor.zig");
    _ = @import("ir/Mir.zig");
    _ = @import("ir/SsaBuilder.zig");
    _ = @import("ir/Lower.zig");
    _ = @import("ir/print.zig");
    _ = @import("backend/codegen.zig");
}
