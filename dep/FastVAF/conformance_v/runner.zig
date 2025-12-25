const std = @import("std");
const zvf = @import("zvf");
const conf_opts = @import("conf_opts");

const Outcome = enum { pass, fail, skip };

fn findKeyEnd(json: []const u8, key: []const u8) ?usize {
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

fn countOccurrences(haystack: []const u8, needle: []const u8) u32 {
    var count: u32 = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, haystack[pos..], needle)) |idx| {
        count += 1;
        pos += idx + needle.len;
    }
    return count;
}

/// Compile the generated device against the real devices contract.
/// This is the actual conformance proof: contract.validate(Self) runs at
/// comptime, and the whole file (including the zpicey_* exports) is analyzed.
fn compileCheck(path: []const u8, generated: []const u8, allocator: std.mem.Allocator) !bool {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var buf: [128]u8 = undefined;
    const hash = std.hash.Wyhash.hash(0, path);
    const tmp_path = std.fmt.bufPrint(&buf, "/tmp/zvf_conf_{x}.zig", .{hash}) catch unreachable;

    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = generated });
    defer cwd.deleteFile(io, tmp_path) catch {};

    var root_arg_buf: [160]u8 = undefined;
    const root_arg = std.fmt.bufPrint(&root_arg_buf, "-Mroot={s}", .{tmp_path}) catch unreachable;

    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            conf_opts.zig_exe,          "build-obj",
            "-fno-emit-bin",            "--cache-dir",
            "/tmp/zvf_conf_cache",      "--dep",
            "contract",                 root_arg,
            "-Mcontract=" ++ conf_opts.contract_path,
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("FAIL {s}: generated code does not compile against contract:\n{s}\n", .{ path, result.stderr });
    }
    return ok;
}

fn runFixture(path: []const u8, source: []const u8, golden: []const u8, allocator: std.mem.Allocator) Outcome {
    const expected_status = findJsonString(golden, "status") orelse "compile_ok";
    const expect_error = !std.mem.eql(u8, expected_status, "compile_ok");

    const result = zvf.fromVerilog(allocator, std.testing.io, source) catch |err| {
        if (err == error.FileNotFound) return .skip;
        if (expect_error) return .pass;
        std.debug.print("FAIL {s}: fromVerilog error: {}\n", .{ path, err });
        return .fail;
    };
    defer allocator.free(result);

    if (expect_error) {
        std.debug.print("FAIL {s}: expected error but compiled ok\n", .{path});
        return .fail;
    }

    var ok = true;

    if (std.mem.indexOf(u8, result, "contract.validate(Self)") == null) {
        std.debug.print("FAIL {s}: missing contract.validate(Self)\n", .{path});
        ok = false;
    }

    if (findJsonInt(golden, "input_count")) |expected| {
        const actual = countPins(result, true);
        if (actual != expected) {
            std.debug.print("FAIL {s}: input_count: expected {d}, got {d}\n", .{ path, expected, actual });
            ok = false;
        }
    }

    if (findJsonInt(golden, "output_count")) |expected| {
        const actual = countPins(result, false);
        if (actual != expected) {
            std.debug.print("FAIL {s}: output_count: expected {d}, got {d}\n", .{ path, expected, actual });
            ok = false;
        }
    }

    if (findJsonBool(golden, "is_sequential")) |expected| {
        const has_prev_clk = std.mem.indexOf(u8, result, "prev_clk_") != null;
        if (has_prev_clk != expected) {
            std.debug.print("FAIL {s}: is_sequential: expected {}, got {}\n", .{ path, expected, has_prev_clk });
            ok = false;
        }
    }

    if (std.mem.indexOf(u8, result, "pub fn eval(comptime S: type") == null) {
        std.debug.print("FAIL {s}: missing value-form eval function\n", .{path});
        ok = false;
    }

    const compiled = compileCheck(path, result, allocator) catch |err| blk: {
        std.debug.print("FAIL {s}: compile check errored: {}\n", .{ path, err });
        break :blk false;
    };
    if (!compiled) ok = false;

    if (ok) return .pass else return .fail;
}

fn countPins(source: []const u8, comptime inputs: bool) i64 {
    const n_voltage: i64 = @intCast(countOccurrences(source, ".voltage,"));
    const n_current: i64 = @intCast(countOccurrences(source, ".current,"));
    if (inputs) return n_voltage - n_current;
    return n_current;
}

const FixtureEntry = struct {
    path: []const u8,
    source: []const u8,
    golden: []const u8,
};

const fixture_entries = blk: {
    const paths = [_][]const u8{
        // 01_gates
        "fixtures/01_gates/01_and2.v",
        "fixtures/01_gates/02_or2.v",
        "fixtures/01_gates/03_not.v",
        "fixtures/01_gates/04_nand2.v",
        "fixtures/01_gates/05_xor2.v",
        "fixtures/01_gates/06_and3.v",
        "fixtures/01_gates/07_xnor2.v",
        "fixtures/01_gates/08_buf.v",
        // 02_multibit
        "fixtures/02_multibit/01_adder4.v",
        "fixtures/02_multibit/02_mux2.v",
        "fixtures/02_multibit/03_comparator.v",
        "fixtures/02_multibit/04_decoder.v",
        // 03_sequential
        "fixtures/03_sequential/01_dff.v",
        "fixtures/03_sequential/02_register8.v",
        "fixtures/03_sequential/03_dff_negedge.v",
        // 04_operators
        "fixtures/04_operators/01_shifts.v",
        "fixtures/04_operators/02_concat.v",
        "fixtures/04_operators/03_ternary.v",
        "fixtures/04_operators/04_reduction.v",
        "fixtures/04_operators/05_arithmetic.v",
        // 05_edge_cases
        "fixtures/05_edge_cases/01_passthrough.v",
        "fixtures/05_edge_cases/02_constant.v",
        "fixtures/05_edge_cases/03_multi_output.v",
        "fixtures/05_edge_cases/04_case_mux.v",
    };

    var entries: [paths.len]FixtureEntry = undefined;
    for (paths, 0..) |p, i| {
        const stripped = p["fixtures/".len..];
        const dot = std.mem.lastIndexOfScalar(u8, stripped, '.').?;
        const json_path = "expected/" ++ stripped[0..dot] ++ ".json";
        entries[i] = .{
            .path = p,
            .source = @embedFile(p),
            .golden = @embedFile(json_path),
        };
    }
    break :blk entries;
};

// Semantic check of the value-form contract: statically @import the generated
// device (no .so, no ABI, no verilator), drive the logic state machine with
// updateState on plain f64, and evaluate the residual with contract.Value.
// The AND logic must pull the output branch toward vhi when both inputs are high.
const contract_harness =
    \\const std = @import("std");
    \\const dev = @import("dev");
    \\const contract = @import("contract");
    \\
    \\test "logic drives residual through value-form eval" {
    \\    const U = dev.U;
    \\    const n_u = contract.nU(dev);
    \\    var model = dev.Model{};
    \\    var inst = dev.Instance{};
    \\    var state = dev.initState(&model, &inst);
    \\
    \\    // and2 unknowns: a, b, y, y_branch. Drive a=b high; update the logic.
    \\    var x = [_]f64{0} ** n_u;
    \\    x[@intFromEnum(U.a)] = 2.5;
    \\    x[@intFromEnum(U.b)] = 2.5;
    \\    _ = dev.updateState(&model, &inst, x, &state);
    \\
    \\    // updateState must have raised the output bit and set the drive target.
    \\    try std.testing.expect(state.outputs[0]);
    \\    try std.testing.expectApproxEqAbs(@as(f64, model.vhi), @as(f64, inst.drive[0]), 1e-6);
    \\
    \\    // Residual at V_y = 0, I_branch = 0: F_branch = V_y - vhi + I/g = -vhi.
    \\    var xs: [n_u]contract.Value = undefined;
    \\    inline for (0..n_u) |u| xs[u] = contract.Value.con(x[u]);
    \\    const res = dev.eval(contract.Value, xs, &model, &inst, 0.0);
    \\    try std.testing.expectApproxEqAbs(-@as(f64, model.vhi), res[@intFromEnum(U.y_branch)].val(), 1e-6);
    \\
    \\    // Now drive an input low: AND output must fall, drive target -> vlo.
    \\    x[@intFromEnum(U.b)] = 0.0;
    \\    _ = dev.updateState(&model, &inst, x, &state);
    \\    try std.testing.expect(!state.outputs[0]);
    \\    try std.testing.expectApproxEqAbs(@as(f64, model.vlo), @as(f64, inst.drive[0]), 1e-6);
    \\}
;

test "value-form contract semantics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const dev_source = try zvf.codegen.generateDevice(allocator, .{
        .name = "and2",
        .ports = &.{
            .{ .name = "a", .direction = .input },
            .{ .name = "b", .direction = .input },
            .{ .name = "y", .direction = .output },
        },
        .eval_stmts = "    const _y: u64 = a & b;\n",
    });
    defer allocator.free(dev_source);

    try cwd.writeFile(io, .{ .sub_path = "/tmp/zvf_cf_dev.zig", .data = dev_source });
    defer cwd.deleteFile(io, "/tmp/zvf_cf_dev.zig") catch {};
    try cwd.writeFile(io, .{ .sub_path = "/tmp/zvf_cf_harness.zig", .data = contract_harness });
    defer cwd.deleteFile(io, "/tmp/zvf_cf_harness.zig") catch {};

    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            conf_opts.zig_exe,       "test",
            "--cache-dir",           "/tmp/zvf_conf_cache",
            "--dep",                 "dev",
            "--dep",                 "contract",
            "-Mroot=/tmp/zvf_cf_harness.zig",
            "--dep",                 "contract",
            "-Mdev=/tmp/zvf_cf_dev.zig",
            "-Mcontract=" ++ conf_opts.contract_path,
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) std.debug.print("contract harness failed:\n{s}\n", .{result.stderr});
    try std.testing.expect(ok);
}

test "VF conformance" {
    const allocator = std.testing.allocator;

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    for (fixture_entries) |entry| {
        const outcome = runFixture(entry.path, entry.source, entry.golden, allocator);
        switch (outcome) {
            .pass => passed += 1,
            .skip => skipped += 1,
            .fail => failed += 1,
        }
    }

    const total = passed + failed + skipped;
    std.debug.print("\n--- VF Conformance Results ---\n", .{});
    std.debug.print("Passed:  {d}/{d}\n", .{ passed, total });
    std.debug.print("Failed:  {d}/{d}\n", .{ failed, total });
    std.debug.print("Skipped: {d}/{d}\n", .{ skipped, total });

    if (skipped == total) {
        std.debug.print("\nAll skipped — verilator not found on PATH.\n", .{});
        return;
    }

    try std.testing.expect(failed == 0);
}
