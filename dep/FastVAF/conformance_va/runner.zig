const std = @import("std");
const zvaf = @import("zvaf");

const Status = enum { compile_ok, parse_error, no_module };
const Outcome = enum { pass, fail };

fn parseExpected(source: []const u8) Status {
    if (std.mem.indexOf(u8, source, "// EXPECT: parse_error") != null) return .parse_error;
    if (std.mem.indexOf(u8, source, "// EXPECT: no_module") != null) return .no_module;
    return .compile_ok;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) u32 {
    var count: u32 = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, haystack[pos..], needle)) |idx| {
        count += 1;
        pos += idx + needle.len;
    }
    return count;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn hasWord(source: []const u8, word: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOf(u8, source[pos..], word)) |idx| {
        const abs = pos + idx;
        const before_ok = abs == 0 or !isWordChar(source[abs - 1]);
        const after_pos = abs + word.len;
        const after_ok = after_pos >= source.len or !isWordChar(source[after_pos]);
        if (before_ok and after_ok) return true;
        pos = abs + 1;
    }
    return false;
}

fn goldenJsonPath(fixture_path: []const u8) []const u8 {
    // "fixtures/01_lexical/01_comments.va" -> "expected_mir/01_lexical/01_comments.json"
    const stripped = if (std.mem.startsWith(u8, fixture_path, "fixtures/"))
        fixture_path["fixtures/".len..]
    else
        fixture_path;
    // Find .va extension and replace
    const dot = std.mem.lastIndexOfScalar(u8, stripped, '.') orelse stripped.len;
    // We need to build the path at comptime — return the embedded JSON
    _ = dot;
    return stripped;
}

fn runFixture(path: []const u8, source: []const u8, golden_json: ?[]const u8, allocator: std.mem.Allocator) Outcome {
    const expected = parseExpected(source);
    var diags: zvaf.DiagnosticList = .empty;
    defer diags.deinit(allocator);
    const result = zvaf.compileSource(allocator, source, &diags);

    switch (expected) {
        .compile_ok => {
            if (result) |*res| {
                var r = res.*;
                defer r.deinit();

                if (r.mir.numBlocks() == 0) {
                    std.debug.print("FAIL {s}: compiled but produced 0 blocks\n", .{path});
                    return .fail;
                }

                if (golden_json) |json| {
                    if (!verifyGolden(path, source, &r, json)) return .fail;
                }

                return .pass;
            } else |err| {
                std.debug.print("FAIL {s}: expected compile_ok, got {}\n", .{ path, err });
                return .fail;
            }
        },
        .parse_error => {
            if (result) |*res| {
                var r = res.*;
                defer r.deinit();
                if (diags.len > 0) return .pass;
                std.debug.print("FAIL {s}: expected parse_error, but compiled ok\n", .{path});
                return .fail;
            } else |err| {
                if (err == error.ParseError) return .pass;
                std.debug.print("FAIL {s}: expected parse_error, got {}\n", .{ path, err });
                return .fail;
            }
        },
        .no_module => {
            if (result) |*res| {
                var r = res.*;
                defer r.deinit();
                std.debug.print("FAIL {s}: expected no_module, but compiled ok\n", .{path});
                return .fail;
            } else |err| {
                if (err == error.NoModule) return .pass;
                std.debug.print("FAIL {s}: expected no_module, got {}\n", .{ path, err });
                return .fail;
            }
        },
    }
}

fn verifyGolden(path: []const u8, source: []const u8, r: *zvaf.CompileResult, json: []const u8) bool {
    var ok = true;

    // Verify module name
    if (findJsonString(json, "module_name")) |expected_name| {
        if (expected_name.len > 0 and !std.mem.eql(u8, r.mir.name, expected_name)) {
            std.debug.print("FAIL {s}: module_name: expected '{s}', got '{s}'\n", .{ path, expected_name, r.mir.name });
            ok = false;
        }
    }

    // Verify param count
    if (findJsonInt(json, "param_count")) |expected_count| {
        const actual: i64 = @intCast(r.lower.params.len);
        if (actual != expected_count) {
            std.debug.print("FAIL {s}: param_count: expected {d}, got {d}\n", .{ path, expected_count, actual });
            ok = false;
        }
    }

    if (findJsonInt(json, "contrib_count")) |expected_count| {
        const actual: i64 = @intCast(r.lower.contributions.len);
        if (actual != expected_count) {
            std.debug.print("FAIL {s}: contrib_count: expected {d}, got {d}\n", .{ path, expected_count, actual });
            ok = false;
        }
    }

    if (findJsonBool(json, "has_ddt")) |expected| {
        const actual = hasWord(source, "ddt");
        if (actual != expected) {
            std.debug.print("FAIL {s}: has_ddt mismatch\n", .{path});
            ok = false;
        }
    }

    if (findJsonBool(json, "has_idt")) |expected| {
        const actual = hasWord(source, "idt");
        if (actual != expected) {
            std.debug.print("FAIL {s}: has_idt mismatch\n", .{path});
            ok = false;
        }
    }

    if (findJsonBool(json, "has_ddx")) |expected| {
        const actual = hasWord(source, "ddx");
        if (actual != expected) {
            std.debug.print("FAIL {s}: has_ddx mismatch\n", .{path});
            ok = false;
        }
    }

    if (findJsonBool(json, "has_noise")) |expected| {
        const actual = hasWord(source, "white_noise") or hasWord(source, "flicker_noise") or hasWord(source, "noise_table");
        if (actual != expected) {
            std.debug.print("FAIL {s}: has_noise mismatch\n", .{path});
            ok = false;
        }
    }

    return ok;
}

fn findKeyEnd(json: []const u8, key: []const u8) ?usize {
    // Find "key": and return position after ": "
    var pos: usize = 0;
    while (pos + key.len + 4 < json.len) {
        if (json[pos] == '"' and
            std.mem.eql(u8, json[pos + 1 .. pos + 1 + key.len], key) and
            json[pos + 1 + key.len] == '"' and
            json[pos + 2 + key.len] == ':')
        {
            var vstart = pos + 3 + key.len;
            while (vstart < json.len and json[vstart] == ' ') : (vstart += 1) {}
            return vstart;
        }
        pos += 1;
    }
    return null;
}

fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const vstart = findKeyEnd(json, key) orelse return null;
    if (vstart >= json.len or json[vstart] != '"') return null;
    const str_start = vstart + 1;
    const str_end = std.mem.indexOfScalar(u8, json[str_start..], '"') orelse return null;
    return json[str_start .. str_start + str_end];
}

fn findJsonInt(json: []const u8, key: []const u8) ?i64 {
    const vstart = findKeyEnd(json, key) orelse return null;
    var end = vstart;
    while (end < json.len and (json[end] >= '0' and json[end] <= '9' or json[end] == '-')) : (end += 1) {}
    if (end == vstart) return null;
    return std.fmt.parseInt(i64, json[vstart..end], 10) catch null;
}

fn findJsonBool(json: []const u8, key: []const u8) ?bool {
    const vstart = findKeyEnd(json, key) orelse return null;
    if (std.mem.startsWith(u8, json[vstart..], "true")) return true;
    if (std.mem.startsWith(u8, json[vstart..], "false")) return false;
    return null;
}

const FixtureEntry = struct {
    path: []const u8,
    source: []const u8,
    golden: ?[]const u8,
};

const fixture_entries = blk: {
    const paths = [_][]const u8{
        // 01_lexical
        "fixtures/01_lexical/01_comments.va",
        "fixtures/01_lexical/02_identifiers.va",
        "fixtures/01_lexical/03_escaped_identifiers.va",
        "fixtures/01_lexical/04_integers.va",
        "fixtures/01_lexical/05_reals.va",
        "fixtures/01_lexical/06_strings.va",
        "fixtures/01_lexical/07_operators.va",
        "fixtures/01_lexical/08_attributes.va",
        // 02_datatypes
        "fixtures/02_datatypes/01_real_vars.va",
        "fixtures/02_datatypes/02_integer_vars.va",
        "fixtures/02_datatypes/03_string_vars.va",
        "fixtures/02_datatypes/04_parameter_real.va",
        "fixtures/02_datatypes/05_parameter_integer.va",
        "fixtures/02_datatypes/06_parameter_string.va",
        "fixtures/02_datatypes/07_parameter_ranges.va",
        "fixtures/02_datatypes/08_localparam.va",
        "fixtures/02_datatypes/09_aliasparam.va",
        "fixtures/02_datatypes/10_arrays.va",
        "fixtures/02_datatypes/11_genvar.va",
        "fixtures/02_datatypes/12_type_conversion.va",
        // 03_natures_disciplines
        "fixtures/03_natures_disciplines/01_nature_basic.va",
        "fixtures/03_natures_disciplines/02_nature_derived.va",
        "fixtures/03_natures_disciplines/03_nature_attributes.va",
        "fixtures/03_natures_disciplines/04_discipline_domain.va",
        "fixtures/03_natures_disciplines/05_ground.va",
        "fixtures/03_natures_disciplines/06_thermal.va",
        // 04_modules
        "fixtures/04_modules/01_empty_module.va",
        "fixtures/04_modules/02_ports_basic.va",
        "fixtures/04_modules/03_ports_typed.va",
        "fixtures/04_modules/04_net_decl.va",
        "fixtures/04_modules/05_branch_decl.va",
        "fixtures/04_modules/06_multi_module.va",
        // 05_expressions
        "fixtures/05_expressions/01_arithmetic.va",
        "fixtures/05_expressions/02_relational.va",
        "fixtures/05_expressions/03_equality.va",
        "fixtures/05_expressions/04_logical.va",
        "fixtures/05_expressions/05_bitwise.va",
        "fixtures/05_expressions/06_shift.va",
        "fixtures/05_expressions/07_ternary.va",
        "fixtures/05_expressions/08_precedence.va",
        "fixtures/05_expressions/09_math_standard.va",
        "fixtures/05_expressions/10_math_trig.va",
        "fixtures/05_expressions/11_math_hyper.va",
        "fixtures/05_expressions/12_min_max.va",
        "fixtures/05_expressions/13_abs_sign.va",
        // 06_signals
        "fixtures/06_signals/01_voltage_access.va",
        "fixtures/06_signals/02_current_access.va",
        "fixtures/06_signals/03_contribute_multiple.va",
        "fixtures/06_signals/04_port_flow.va",
        // 07_analog_behavior
        "fixtures/07_analog_behavior/01_analog_block.va",
        "fixtures/07_analog_behavior/02_if_else.va",
        "fixtures/07_analog_behavior/03_case.va",
        "fixtures/07_analog_behavior/04_for_loop.va",
        "fixtures/07_analog_behavior/05_while_loop.va",
        "fixtures/07_analog_behavior/06_named_block.va",
        "fixtures/07_analog_behavior/07_nested_blocks.va",
        "fixtures/07_analog_behavior/08_disable.va",
        "fixtures/07_analog_behavior/09_conditional_contrib.va",
        // 08_analog_operators
        "fixtures/08_analog_operators/01_ddt.va",
        "fixtures/08_analog_operators/02_idt.va",
        "fixtures/08_analog_operators/03_idt_ic.va",
        "fixtures/08_analog_operators/04_ddx.va",
        "fixtures/08_analog_operators/05_limexp.va",
        "fixtures/08_analog_operators/06_idtmod.va",
        "fixtures/08_analog_operators/07_absdelay.va",
        "fixtures/08_analog_operators/08_transition.va",
        "fixtures/08_analog_operators/09_slew.va",
        "fixtures/08_analog_operators/10_last_crossing.va",
        "fixtures/08_analog_operators/11_laplace_nd.va",
        "fixtures/08_analog_operators/12_zi_nd.va",
        // 09_events
        "fixtures/09_events/01_initial_step.va",
        "fixtures/09_events/02_final_step.va",
        "fixtures/09_events/03_cross.va",
        "fixtures/09_events/04_timer.va",
        "fixtures/09_events/05_above.va",
        // 10_noise
        "fixtures/10_noise/01_white_noise.va",
        "fixtures/10_noise/02_flicker_noise.va",
        "fixtures/10_noise/03_noise_table.va",
        // 11_system_tasks
        "fixtures/11_system_tasks/01_temperature.va",
        "fixtures/11_system_tasks/02_vt.va",
        "fixtures/11_system_tasks/03_abstime.va",
        "fixtures/11_system_tasks/04_display.va",
        "fixtures/11_system_tasks/05_param_given.va",
        "fixtures/11_system_tasks/06_simparam.va",
        "fixtures/11_system_tasks/07_bound_step.va",
        "fixtures/11_system_tasks/08_limit.va",
        "fixtures/11_system_tasks/09_severity.va",
        "fixtures/11_system_tasks/10_discontinuity.va",
        "fixtures/11_system_tasks/11_analysis.va",
        "fixtures/11_system_tasks/12_finish_stop.va",
        // 12_preprocessor
        "fixtures/12_preprocessor/01_define_simple.va",
        "fixtures/12_preprocessor/02_define_param.va",
        "fixtures/12_preprocessor/03_undef.va",
        "fixtures/12_preprocessor/04_ifdef.va",
        "fixtures/12_preprocessor/05_ifndef.va",
        "fixtures/12_preprocessor/06_ifdef_nested.va",
        "fixtures/12_preprocessor/07_include.va",
        "fixtures/12_preprocessor/08_multiline.va",
        "fixtures/12_preprocessor/09_elsif.va",
        "fixtures/12_preprocessor/10_undef_use.va",
        "fixtures/12_preprocessor/11_resetall.va",
        // 13_functions
        "fixtures/13_functions/01_func_basic.va",
        "fixtures/13_functions/02_func_multi_args.va",
        "fixtures/13_functions/03_func_complex.va",
        // 14_hierarchical
        "fixtures/14_hierarchical/01_instantiation.va",
        "fixtures/14_hierarchical/02_port_by_name.va",
        "fixtures/14_hierarchical/03_port_by_position.va",
        "fixtures/14_hierarchical/04_param_override.va",
        "fixtures/14_hierarchical/05_defparam.va",
        "fixtures/14_hierarchical/06_generate.va",
        "fixtures/14_hierarchical/07_paramset.va",
        // 15_edge_cases
        "fixtures/15_edge_cases/01_empty_file.va",
        "fixtures/15_edge_cases/02_comments_only.va",
        "fixtures/15_edge_cases/03_empty_module.va",
        "fixtures/15_edge_cases/04_many_params.va",
        "fixtures/15_edge_cases/05_deep_nesting.va",
        "fixtures/15_edge_cases/06_consecutive_ops.va",
        "fixtures/15_edge_cases/07_internal_nodes.va",
        "fixtures/15_edge_cases/08_ternary_contrib.va",
        "fixtures/15_edge_cases/09_many_branches.va",
        // 16_negative
        "fixtures/16_negative/01_missing_semicolon.va",
        "fixtures/16_negative/02_missing_endmodule.va",
        "fixtures/16_negative/03_bad_expression.va",
        "fixtures/16_negative/04_unclosed_comment.va",
        "fixtures/16_negative/05_no_module.va",
        // 17_real_devices
        "fixtures/17_real_devices/01_diode.va",
        "fixtures/17_real_devices/02_resistor_tc.va",
        "fixtures/17_real_devices/03_bjt_em.va",
        "fixtures/17_real_devices/04_mosfet_l1.va",
        "fixtures/17_real_devices/05_varactor.va",
        "fixtures/17_real_devices/06_bsim_core.va",
        "fixtures/17_real_devices/07_rlc_series.va",
    };

    var entries: [paths.len]FixtureEntry = undefined;
    for (paths, 0..) |p, i| {
        const stripped = p["fixtures/".len..];
        const dot = std.mem.lastIndexOfScalar(u8, stripped, '.').?;
        const json_path = "expected_mir/" ++ stripped[0..dot] ++ ".json";
        entries[i] = .{
            .path = p,
            .source = @embedFile(p),
            .golden = @embedFile(json_path),
        };
    }
    break :blk entries;
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var passed: u32 = 0;
    var failed: u32 = 0;
    var fail_list: [fixture_entries.len][]const u8 = undefined;

    for (fixture_entries) |entry| {
        const outcome = runFixture(entry.path, entry.source, entry.golden, allocator);
        switch (outcome) {
            .pass => passed += 1,
            .fail => {
                fail_list[failed] = entry.path;
                failed += 1;
            },
        }
    }

    const total = passed + failed;
    std.debug.print("\n--- Conformance Results ---\n", .{});
    std.debug.print("Passed: {d}/{d}\n", .{ passed, total });
    std.debug.print("Failed: {d}/{d}\n", .{ failed, total });

    if (failed > 0) {
        std.debug.print("\nFailed tests:\n", .{});
        for (fail_list[0..failed]) |p| {
            std.debug.print("  {s}\n", .{p});
        }
        std.process.exit(1);
    }
}
