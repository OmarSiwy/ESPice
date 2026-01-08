//! FastVF conformance: every fixture is translated, compiled against the real
//! devices contract, and then *executed* against hand-written truth-table
//! vectors. The vectors are the point — a static shape check would happily
//! accept an `and2` that emits `a | b`.
//!
//! Golden schema (tests/expected_v/<name>.json):
//!   status        "compile_ok" | anything else meaning "must fail to translate"
//!   input_count   total input BITS   (sum of input port widths)
//!   output_count  total output BITS
//!   is_sequential whether a clocked always block is expected
//!   ports         [{name, dir:"in"|"out", width}] in module declaration order
//!   vectors       [{<port>: <int>, ...}] applied IN ORDER, state persists
//!                 across vectors so sequential fixtures can be clocked.

const std = @import("std");
const zvf = @import("zvf");
const conf_opts = @import("conf_opts");

const Outcome = enum { pass, fail, skip };

const Port = struct {
    name: []const u8,
    is_input: bool,
    width: u16,
};

// ============================================================================
// Generated-device harness: drive updateState with the golden vectors
// ============================================================================

/// Emit the U-enum member name for one bit of a port, matching codegen's
/// `emitPinName`: scalar ports keep their bare name, vectors get `_<bit>`.
fn writePin(w: *std.Io.Writer, name: []const u8, width: u16, bit: u16) !void {
    if (width == 1) try w.writeAll(name) else try w.print("{s}_{d}", .{ name, bit });
}

/// Build a self-contained Zig test that imports the generated device and walks
/// the vectors. Inputs are driven as voltages (0 V / 3.3 V, either side of the
/// default 1.4 V threshold); outputs are read back out of the logic state.
///
/// `state.outputs` is indexed by output-bit offset, and the U enum lays out all
/// input bits before all output bits, so the offset of output pin P is
/// `@intFromEnum(U.P) - total_in`. Both totals come from the device itself:
/// n_u = total_in + 2*total_out and num_ports = total_in + total_out.
fn buildHarness(gpa: std.mem.Allocator, ports: []const Port, vectors: []const std.json.Value) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\const std = @import("std");
        \\const dev = @import("dev");
        \\const contract = @import("contract");
        \\
        \\test "golden vectors" {
        \\    const U = dev.U;
        \\    const n_u = contract.nU(dev);
        \\    const total_out = n_u - dev.num_ports;
        \\    const total_in = dev.num_ports - total_out;
        \\
        \\    var model = dev.Model{};
        \\    var inst = dev.Instance{};
        \\    var state = dev.initState(&model, &inst);
        \\    var x = [_]f64{0} ** n_u;
        \\
        \\
    );

    for (vectors, 0..) |vec_val, vi| {
        const vec = vec_val.object;
        try w.print("    // ---- vector {d} ----\n", .{vi});

        // Drive every input the vector mentions, then settle the logic once.
        for (ports) |p| {
            if (!p.is_input) continue;
            const entry = vec.get(p.name) orelse continue;
            const value: u64 = @bitCast(entry.integer);
            for (0..p.width) |bit| {
                const on = (value >> @intCast(bit)) & 1 != 0;
                try w.writeAll("    x[@intFromEnum(U.");
                try writePin(w, p.name, p.width, @intCast(bit));
                try w.print(")] = {s};\n", .{if (on) "3.3" else "0.0"});
            }
        }
        try w.writeAll("    _ = dev.updateState(&model, &inst, x, &state);\n");

        for (ports) |p| {
            if (p.is_input) continue;
            const entry = vec.get(p.name) orelse continue;
            const value: u64 = @bitCast(entry.integer);
            for (0..p.width) |bit| {
                const on = (value >> @intCast(bit)) & 1 != 0;
                try w.writeAll("    std.testing.expect(state.outputs[@intFromEnum(U.");
                try writePin(w, p.name, p.width, @intCast(bit));
                try w.print(") - total_in] == {s}) catch |e| {{\n", .{if (on) "true" else "false"});
                try w.print("        std.debug.print(\"vector {d}: pin ", .{vi});
                try writePin(w, p.name, p.width, @intCast(bit));
                try w.print(" expected {s}\\n\", .{{}});\n", .{if (on) "1" else "0"});
                try w.writeAll("        return e;\n    };\n");
            }
        }
        try w.writeAll("\n");
    }

    try w.writeAll("}\n");
    return aw.toOwnedSlice();
}

/// Compile+run the harness against the generated device. Returns false and
/// prints the compiler/test output on failure.
fn runHarness(
    name: []const u8,
    device_source: []const u8,
    harness_source: []const u8,
    gpa: std.mem.Allocator,
) !bool {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var dev_buf: [128]u8 = undefined;
    var har_buf: [128]u8 = undefined;
    const dev_path = try std.fmt.bufPrint(&dev_buf, "/tmp/zvf_dev_{s}.zig", .{name});
    const har_path = try std.fmt.bufPrint(&har_buf, "/tmp/zvf_har_{s}.zig", .{name});

    try cwd.writeFile(io, .{ .sub_path = dev_path, .data = device_source });
    defer cwd.deleteFile(io, dev_path) catch {};
    try cwd.writeFile(io, .{ .sub_path = har_path, .data = harness_source });
    defer cwd.deleteFile(io, har_path) catch {};

    var root_buf: [160]u8 = undefined;
    var mdev_buf: [160]u8 = undefined;
    const root_arg = try std.fmt.bufPrint(&root_buf, "-Mroot={s}", .{har_path});
    const mdev_arg = try std.fmt.bufPrint(&mdev_buf, "-Mdev={s}", .{dev_path});

    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            conf_opts.zig_exe, "test",
            "--cache-dir",     "/tmp/zvf_conf_cache",
            "--dep",           "dev",
            "--dep",           "contract",
            root_arg,          "--dep",
            "contract",        mdev_arg,
            "-Mcontract=" ++ conf_opts.contract_path,
        },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) std.debug.print("FAIL {s}: vectors did not pass:\n{s}\n", .{ name, result.stderr });
    return ok;
}

// ============================================================================
// Static checks — cheap shape gates that run before the vectors
// ============================================================================

fn countOccurrences(haystack: []const u8, needle: []const u8) u32 {
    var count: u32 = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, haystack[pos..], needle)) |idx| {
        count += 1;
        pos += idx + needle.len;
    }
    return count;
}

/// Input bits = voltage unknowns minus output bits; output bits = current
/// unknowns (one branch per output bit).
fn countPins(source: []const u8, comptime inputs: bool) i64 {
    const n_voltage: i64 = @intCast(countOccurrences(source, ".voltage,"));
    const n_current: i64 = @intCast(countOccurrences(source, ".current,"));
    if (inputs) return n_voltage - n_current;
    return n_current;
}

fn parsePorts(gpa: std.mem.Allocator, golden: std.json.Value) !?[]Port {
    const arr = (golden.object.get("ports") orelse return null).array;
    const ports = try gpa.alloc(Port, arr.items.len);
    errdefer gpa.free(ports);
    for (arr.items, 0..) |p_val, i| {
        const p = p_val.object;
        ports[i] = .{
            .name = (p.get("name") orelse return error.BadGolden).string,
            .is_input = std.mem.eql(u8, (p.get("dir") orelse return error.BadGolden).string, "in"),
            .width = @intCast((p.get("width") orelse return error.BadGolden).integer),
        };
    }
    return ports;
}

fn runFixture(name: []const u8, lang: Lang, source: []const u8, golden_text: []const u8, gpa: std.mem.Allocator) Outcome {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, golden_text, .{}) catch |err| {
        std.debug.print("FAIL {s}: bad golden json: {}\n", .{ name, err });
        return .fail;
    };
    defer parsed.deinit();
    const golden = parsed.value.object;

    const expected_status = if (golden.get("status")) |s| s.string else "compile_ok";
    const expect_error = !std.mem.eql(u8, expected_status, "compile_ok");

    const generated = switch (lang) {
        .verilog => zvf.fromVerilog(gpa, std.testing.io, source),
        .system_verilog => zvf.fromSystemVerilog(gpa, std.testing.io, source),
        .vhdl => zvf.fromVhdl(gpa, std.testing.io, source),
    } catch |err| {
        if (err == error.FileNotFound) return .skip; // converter absent
        if (expect_error) return .pass;
        std.debug.print("FAIL {s}: translation error: {}\n", .{ name, err });
        return .fail;
    };
    defer gpa.free(generated);

    if (expect_error) {
        std.debug.print("FAIL {s}: expected translation to fail, but it succeeded\n", .{name});
        return .fail;
    }

    var ok = true;

    if (std.mem.indexOf(u8, generated, "contract.validate(@This())") == null) {
        std.debug.print("FAIL {s}: missing contract.validate(@This())\n", .{name});
        ok = false;
    }
    if (std.mem.indexOf(u8, generated, "pub fn eval(comptime S: type") == null) {
        std.debug.print("FAIL {s}: missing value-form eval\n", .{name});
        ok = false;
    }
    if (golden.get("input_count")) |e| {
        const actual = countPins(generated, true);
        if (actual != e.integer) {
            std.debug.print("FAIL {s}: input_count expected {d}, got {d}\n", .{ name, e.integer, actual });
            ok = false;
        }
    }
    if (golden.get("output_count")) |e| {
        const actual = countPins(generated, false);
        if (actual != e.integer) {
            std.debug.print("FAIL {s}: output_count expected {d}, got {d}\n", .{ name, e.integer, actual });
            ok = false;
        }
    }
    if (golden.get("is_sequential")) |e| {
        const actual = std.mem.indexOf(u8, generated, "prev_clk_") != null;
        if (actual != e.bool) {
            std.debug.print("FAIL {s}: is_sequential expected {}, got {}\n", .{ name, e.bool, actual });
            ok = false;
        }
    }

    // The real gate: execute the golden vectors.
    const ports = parsePorts(gpa, parsed.value) catch |err| {
        std.debug.print("FAIL {s}: bad ports in golden: {}\n", .{ name, err });
        return .fail;
    };
    if (ports) |port_list| {
        defer gpa.free(port_list);
        if (golden.get("vectors")) |vecs| {
            const harness = buildHarness(gpa, port_list, vecs.array.items) catch |err| {
                std.debug.print("FAIL {s}: harness build: {}\n", .{ name, err });
                return .fail;
            };
            defer gpa.free(harness);
            const passed = runHarness(name, generated, harness, gpa) catch |err| blk: {
                std.debug.print("FAIL {s}: harness run: {}\n", .{ name, err });
                break :blk false;
            };
            if (!passed) ok = false;
        }
    } else {
        std.debug.print("FAIL {s}: golden has no \"ports\" — vectors cannot run\n", .{name});
        ok = false;
    }

    return if (ok) .pass else .fail;
}

// ============================================================================
// Fixture table
// ============================================================================

const Lang = enum {
    verilog,
    system_verilog,
    vhdl,

    fn ext(self: Lang) []const u8 {
        return switch (self) {
            .verilog => ".v",
            .system_verilog => ".sv",
            .vhdl => ".vhd",
        };
    }
};

const Fixture = struct { name: []const u8, lang: Lang, source: []const u8, golden: []const u8 };

/// Every fixture is one construct the translator has to get right; the list is
/// deliberately free of near-duplicates.
const fixture_names = [_]struct { []const u8, Lang }{
    // combinational gates
    .{ "and2", .verilog },            .{ "or2", .verilog },
    .{ "not", .verilog },             .{ "nand2", .verilog },
    .{ "xor2", .verilog },            .{ "and3", .verilog },
    .{ "xnor2", .verilog },           .{ "buf", .verilog },
    // multi-bit datapath
    .{ "adder4", .verilog },          .{ "mux2", .verilog },
    .{ "comparator", .verilog },      .{ "decoder", .verilog },
    // sequential
    .{ "dff", .verilog },             .{ "register8", .verilog },
    .{ "dff_negedge", .verilog },
    // if-statement lowering: reset, enable/hold, priority chains
    .{ "dff_sync_reset", .verilog },  .{ "counter_en", .verilog },
    .{ "dff_reset_multi", .verilog }, .{ "priority_encoder", .verilog },
    // asynchronous reset: multi-edge sensitivity list
    .{ "dff_async_reset", .verilog }, .{ "dff_arst_n", .verilog },
    // internal wires: dataflow ordering between blocks
    .{ "wire_chain", .verilog },
    // inferred latch: incomplete combinational assignment holds its value
    .{ "latch_en", .verilog },
    // operators
    .{ "shifts", .verilog },          .{ "concat", .verilog },
    .{ "ternary", .verilog },         .{ "reduction", .verilog },
    .{ "arithmetic", .verilog },
    // edge cases
    .{ "passthrough", .verilog },     .{ "constant", .verilog },
    .{ "multi_output", .verilog },    .{ "case_mux", .verilog },
    // SystemVerilog via sv2v
    .{ "sv_always_comb", .system_verilog }, .{ "sv_logic_ff", .system_verilog },
    // VHDL via ghdl synth
    .{ "vhd_and2", .vhdl },           .{ "vhd_dff", .vhdl },
};

const fixtures = blk: {
    var out: [fixture_names.len]Fixture = undefined;
    for (fixture_names, 0..) |entry, i| {
        const n, const lang = entry;
        out[i] = .{
            .name = n,
            .lang = lang,
            .source = @embedFile("fixtures/" ++ n ++ lang.ext()),
            .golden = @embedFile("expected_v/" ++ n ++ ".json"),
        };
    }
    break :blk out;
};

test "VF conformance" {
    const gpa = std.testing.allocator;

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    for (fixtures) |f| {
        switch (runFixture(f.name, f.lang, f.source, f.golden, gpa)) {
            .pass => passed += 1,
            .skip => skipped += 1,
            .fail => failed += 1,
        }
    }

    const total = passed + failed + skipped;
    std.debug.print("\n--- VF Conformance ---\nPassed:  {d}/{d}\nFailed:  {d}/{d}\nSkipped: {d}/{d}\n", .{ passed, total, failed, total, skipped, total });

    if (skipped == total) {
        std.debug.print("\nAll skipped — verilator not found on PATH.\n", .{});
        return;
    }
    try std.testing.expect(failed == 0);
}
