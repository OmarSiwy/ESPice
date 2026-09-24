const Deck = @import("core").Deck;
const requests = @import("core").query;
const std = @import("std");
const validate = @import("../validate.zig").validate;
const validateDeck = @import("../validate.zig").validateDeck;

test "query boundary rejects nonfinite values and nonterminating sweeps" {
    const t = std.testing;
    try t.expectError(error.InvalidQueryOptions, validate(.{ .ac = .{ .sweep = .{ .f_start = 0, .f_stop = 1 } } }, 4));
    try t.expectError(error.InvalidQueryOptions, validate(.{ .dc = .{ .start = 0, .stop = 1, .step = -1 } }, 4));
    try t.expectError(error.InvalidQueryOptions, validate(.{ .tran = .{ .t_stop = std.math.inf(f64) } }, 4));
    try validate(.{ .tran = .{ .t_stop = 1e-6 } }, 4);
    try validate(.{ .temp = .{ .t_start = -40, .t_stop = -10 } }, 4);
}

test "query boundary checks derived frequencies, dimensions and nested controls" {
    const t = std.testing;
    const invalid = [_]requests.Query{
        .{ .ac = .{ .sweep = .{ .f_start = 1, .f_stop = 1e308 } } },
        .{ .hb = .{ .f0 = 1e3, .n_harmonics = 0 } },
        .{ .qpss = .{ .f1 = 1e3, .f2 = 2e3, .k1 = 65535, .k2 = 65535 } },
        .{ .pss = .{ .period = 1e-308, .n_samples = 65536 } },
        .{ .tran = .{ .t_stop = 1, .dt_min = 1e-320 } },
        .{ .four = .{ .f_fundamental = 1e-308 } },
        .{ .matex = .{ .t_stop = 1, .m_max = std.math.maxInt(u32) } },
        .{ .matex = .{ .t_stop = 1, .gamma = -1 } },
        .{ .mc = .{ .dc_options = .{ .tol = .{ .abstol = -1 } } } },
        .{ .temp = .{ .dc_options = .{ .step = 0 } } },
        .{ .temp = .{ .t_start = 100, .t_stop = 0, .t_step = -1 } },
        .{ .dc = .{ .start = 1e20, .stop = 1e20 + 1e6, .step = 1 } },
        .{ .envelope = .{ .t_carrier = 1e-3, .t_stop = 1, .max_outer_steps = std.math.maxInt(u32) } },
    };
    for (invalid) |query| try t.expectError(error.InvalidQueryOptions, validate(query, 4));
    try validate(.{ .op = .{} }, 4); // +inf dx_clamp means disabled.
    try validate(.{ .mc = .{} }, 4);
    try validate(.{ .hb = .{ .f0 = 1e3 } }, 4);
    try validate(.{ .qpss = .{ .f1 = 1e3, .f2 = 1414 } }, 4);
}

test "a dc sweep target resolves against the prepared card table, type included" {
    var deck: Deck = undefined;
    deck.cards = &.{
        .{ .type_name = "vsource", .index = 0, .name = "v1" },
        .{ .type_name = "isource", .index = 0, .name = "i1" },
        .{ .type_name = "resistor", .index = 1, .name = "r2" },
    };
    try validateDeck(.{ .dc = .{} }, 4, &deck);
    // Same ordinal, different device type: the two no longer alias.
    try validateDeck(.{ .dc = .{ .target = .{ .type_name = "isource", .index = 0 } } }, 4, &deck);
    try validateDeck(.{ .dc = .{ .target = .{ .type_name = "resistor", .index = 1, .param_name = "r" } } }, 4, &deck);
    try std.testing.expectError(error.DcSweepSourceNotFound, validateDeck(.{ .dc = .{ .target = .{ .index = 1 } } }, 4, &deck));
    try std.testing.expectError(error.DcSweepSourceNotFound, validateDeck(.{ .dc = .{ .target2 = .{ .type_name = "resistor", .index = 0 } } }, 4, &deck));
    // The temperature is not a card and is never looked up.
    try validateDeck(.{ .dc = .{ .target2 = .{ .is_temp = true } } }, 4, &deck);
}
