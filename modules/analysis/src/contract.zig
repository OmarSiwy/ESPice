const root = @import("root.zig");

/// Comptime validation: every analysis module is one pure transformation,
///
///   run: (*const root.RunCtx, T.Options) !root.Result
///
/// Options in, Result out, no other entry points required. Checked by shape
/// so a drifted signature fails here with a readable error instead of deep
/// in root.zig's dispatch switch.
pub fn validate(comptime T: type) void {
    const name = @typeName(T);

    if (!@hasDecl(T, "Options"))
        @compileError(name ++ ": contract requires `pub const Options`");
    if (@typeInfo(T.Options) != .@"struct")
        @compileError(name ++ ".Options must be a struct");

    if (!@hasDecl(T, "run"))
        @compileError(name ++ ": contract requires `pub fn run(*const root.RunCtx, T.Options) !root.Result`");

    const info = @typeInfo(@TypeOf(T.run));
    if (info != .@"fn")
        @compileError(name ++ ".run must be a function");
    const f = info.@"fn";
    if (f.params.len != 2 or
        f.params[0].type != *const root.RunCtx or
        f.params[1].type != T.Options)
        @compileError(name ++ ".run: expected params (*const root.RunCtx, " ++ name ++ ".Options)");

    const ret = @typeInfo(f.return_type.?);
    if (ret != .error_union or ret.error_union.payload != root.Result)
        @compileError(name ++ ".run must return !root.Result");
}
