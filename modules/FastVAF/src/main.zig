//! `fastvaf` — the command-line driver.
//!
//! The engine is a library; this is the thin shell that makes its diagnostics
//! reachable from a terminal. It exists because the diagnostics themselves
//! advertise it: every rendered message ends with "run `fastvaf --explain
//! EXXXX`", and `--allow=`/`--deny=` are the documented way to tune the
//! finiteness warning (W0650).
//!
//! usage:
//!   fastvaf [options] FILE.va      compile (or lint) one Verilog-A source
//!   fastvaf --explain CODE         print the catalogue entry for a code
//!
//! It is also the BUILD-TIME generator: `--emit-zig -o OUT.zig` is what a
//! dependent build step runs once per `models/NAME.va`, which is why the
//! module-name check and the `@compileError` gate live here rather than in a
//! separate wrapper tool.
//!
//! options:
//!   --lint                 frontend only: parse, lower, prove. No codegen.
//!   --emit-zig             generate the device; write it to stdout or -o
//!   -o PATH                write the generated device.zig here instead
//!   --expect-module=NAME   fail unless the compiled module is called NAME
//!   --check                run the Zig compiler over the generated device and
//!                          fail HERE if it does not type-check, so a codegen
//!                          bug names the .va instead of surfacing three cache
//!                          steps downstream as an error in generated code
//!   --emit-so              go all the way: .va -> device.zig -> lib<name>.so
//!   --emit-exe             the OTHER artifact: .va -> a runnable testbench.
//!                          Same frontend and the same device.zig; ch9 display
//!                          tasks become real prints, and a generated runner
//!                          drives the module over the operating points the
//!                          source's `//!` lines declare (src/tb.zig). Prints
//!                          the binary's path.
//!   --run                  --emit-exe, then execute it and forward its status
//!   --display=drop|emit    ch9 display handling on its own. `drop` (the
//!                          default) is what a DEVICE gets: no text, no syscall
//!                          in the Newton loop, nothing that blocks a GPU
//!                          backend — and a W0850 naming every dropped call.
//!                          `emit` lowers them to `std.debug.print` and gives
//!                          the device a `display()` entry point.
//!   --contract PATH        root of the `contract` module (--check, --emit-so,
//!                          --emit-exe)
//!   --dyn PATH             root of the `dyn` module (--emit-so)
//!   --work-dir DIR         scratch + artifact directory (--emit-so)
//!   --zig PATH             the zig executable to drive (default: `zig`)
//!   -I DIR                 add an `include search directory (repeatable)
//!   --no-std-defs          do not prepend the annex D prelude
//!   --diagnostics=text     rendered snippets (default)
//!   --diagnostics=json     one JSON object per diagnostic, for a tool
//!   --color=auto|always|never
//!   --allow=CODE           silence a warning        (an error cannot be allowed)
//!   --warn=CODE            report but do not fail
//!   --deny=CODE            report and fail
//!   --forbid=CODE          like --deny, and refuse a later downgrade
//!   --unknown-bound=X      solver compliance limit, in volts/amps (see W0650)
//!
//! exit status: 0 on success (warnings do not fail), 1 on a diagnosed error,
//! 2 on a usage error.

const std = @import("std");
const fastvaf = @import("root.zig");
const diag = fastvaf.diag;
const Io = std.Io;

const usage_text =
    \\usage: fastvaf [options] FILE.va
    \\       fastvaf --explain CODE
    \\
    \\  --lint                  frontend only (parse, lower, prove); no codegen
    \\  --emit-zig              generate the device; to stdout unless -o is given
    \\  -o PATH                 write the generated device.zig here
    \\  --expect-module=NAME    fail unless the compiled module is called NAME
    \\  --check                 type-check the generated device with zig
    \\  --emit-so               build lib<name>.<gen>.so via the orchestrator
    \\  --emit-exe              build a runnable Verilog-A testbench; print its path
    \\  --run                   --emit-exe, then run it
    \\  --display=drop|emit     ch9 display tasks: void (device) or printed (exe)
    \\  --contract PATH         root of the `contract` module
    \\  --dyn PATH              root of the `dyn` module (--emit-so)
    \\  --work-dir DIR          scratch + artifact directory (--emit-so)
    \\  --zig PATH              zig executable to drive (default: zig)
    \\  -I DIR                  add an `include search directory
    \\  --no-std-defs           do not prepend the annex D prelude
    \\  --diagnostics=text|json how to report (default: text)
    \\  --color=auto|always|never
    \\  --allow/--warn/--deny/--forbid=CODE   per-code lint level
    \\  --unknown-bound=X       solver compliance limit (see --explain W0650)
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var stderr_buf: [1 << 16]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr.interface;
    defer err.flush() catch {};

    var levels: diag.Levels = .empty;
    defer levels.deinit(gpa);

    var include_dirs: std.ArrayList([]const u8) = .empty;
    defer include_dirs.deinit(gpa);

    var path: ?[]const u8 = null;
    var target: fastvaf.Target = .lint;
    var emit_zig = false;
    var json = false;
    var color: enum { auto, always, never } = .auto;
    var unknown_bound: ?f64 = null;
    var std_defs = true;
    var out_path: ?[]const u8 = null;
    var expect_module: ?[]const u8 = null;
    var check = false;
    var emit_so = false;
    var emit_exe = false;
    var run_exe = false;
    var display: fastvaf.codegen.Display = .drop;
    var contract_path: ?[]const u8 = null;
    var dyn_path: ?[]const u8 = null;
    var work_dir: ?[]const u8 = null;
    var zig_exe: []const u8 = "zig";

    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.writeAll(usage_text);
            return 0;
        } else if (std.mem.eql(u8, arg, "--explain")) {
            const name = args.next() orelse {
                try err.writeAll("error: --explain needs a code, e.g. --explain W0650\n");
                return 2;
            };
            const code = std.meta.stringToEnum(diag.Code, name) orelse {
                try err.print("error: unknown diagnostic code `{s}`\n", .{name});
                return 2;
            };
            try diag.explain(code, out, if (color == .never) .off else .on);
            return 0;
        } else if (std.mem.eql(u8, arg, "--lint")) {
            target = .lint;
        } else if (std.mem.eql(u8, arg, "--emit-zig")) {
            emit_zig = true;
            target = .release_fast;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check = true;
            target = .release_fast;
        } else if (std.mem.eql(u8, arg, "--emit-so")) {
            emit_so = true;
            target = .release_fast;
        } else if (std.mem.eql(u8, arg, "--emit-exe") or std.mem.eql(u8, arg, "--run")) {
            // The testbench IS the display output, so asking for one and then
            // dropping the prints would build an artifact with nothing to say.
            emit_exe = true;
            run_exe = run_exe or std.mem.eql(u8, arg, "--run");
            display = .emit;
            target = .release_fast;
        } else if (std.mem.eql(u8, arg, "--display=emit")) {
            display = .emit;
        } else if (std.mem.eql(u8, arg, "--display=drop")) {
            display = .drop;
        } else if (std.mem.eql(u8, arg, "--contract")) {
            contract_path = args.next() orelse return missing(err, "--contract", "a path");
        } else if (std.mem.eql(u8, arg, "--dyn")) {
            dyn_path = args.next() orelse return missing(err, "--dyn", "a path");
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            work_dir = args.next() orelse return missing(err, "--work-dir", "a directory");
        } else if (std.mem.eql(u8, arg, "--zig")) {
            zig_exe = args.next() orelse return missing(err, "--zig", "a path");
        } else if (std.mem.eql(u8, arg, "-o")) {
            out_path = args.next() orelse {
                try err.writeAll("error: -o needs a path\n");
                return 2;
            };
            emit_zig = true;
            target = .release_fast;
        } else if (std.mem.startsWith(u8, arg, "--expect-module=")) {
            expect_module = arg["--expect-module=".len..];
        } else if (std.mem.eql(u8, arg, "-I")) {
            try include_dirs.append(gpa, args.next() orelse {
                try err.writeAll("error: -I needs a directory\n");
                return 2;
            });
        } else if (std.mem.eql(u8, arg, "--no-std-defs")) {
            std_defs = false;
        } else if (std.mem.eql(u8, arg, "--diagnostics=json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--diagnostics=text")) {
            json = false;
        } else if (std.mem.eql(u8, arg, "--color=always")) {
            color = .always;
        } else if (std.mem.eql(u8, arg, "--color=never")) {
            color = .never;
        } else if (std.mem.eql(u8, arg, "--color=auto")) {
            color = .auto;
        } else if (std.mem.startsWith(u8, arg, "--unknown-bound=")) {
            unknown_bound = std.fmt.parseFloat(f64, arg["--unknown-bound=".len..]) catch {
                try err.print("error: `{s}` is not a number\n", .{arg});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // --allow=X / --warn=X / --deny=X / --forbid=X
            const applied = levels.parseFlag(gpa, arg[2..]) catch |e| switch (e) {
                error.CannotAllowError => {
                    try err.print(
                        "error: `{s}`: an error code cannot be allowed or warned away — " ++
                            "it is a statement about the program, not a preference\n",
                        .{arg},
                    );
                    return 2;
                },
                error.Forbidden => {
                    try err.print("error: `{s}`: this code was already --forbid'd\n", .{arg});
                    return 2;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (!applied) {
                try err.print("error: unknown option `{s}`\n", .{arg});
                return 2;
            }
        } else if (path == null) {
            path = arg;
        } else {
            try err.writeAll("error: more than one input file\n");
            return 2;
        }
    }

    const in_path = path orelse {
        try err.writeAll(usage_text);
        return 2;
    };

    const source = Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .limited(64 * 1024 * 1024)) catch |e| {
        try err.print("error: cannot read `{s}`: {t}\n", .{ in_path, e });
        return 2;
    };
    defer gpa.free(source);

    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    // Decided once: `isTty` can fail, and re-asking it on three error paths is
    // three more things that can go wrong while reporting an error.
    const use_color = switch (color) {
        .always => true,
        .never => false,
        .auto => (stderr.file.isTty(io) catch false),
    };

    var result = fastvaf.compileSourceOpts(gpa, source, target, .{
        .file_name = in_path,
        .include_dirs = include_dirs.items,
        .std_defs = std_defs,
        .diags = &bag,
        .lint = levels,
        .proof = .{ .unknown_bound = unknown_bound },
        .display = display,
    }) catch |e| switch (e) {
        // A diagnosed failure has already said everything useful; the Zig error
        // name would only add noise.
        error.CompileFailed, error.NoModule => {
            try report(&bag, err, json, use_color);
            return 1;
        },
        else => {
            try report(&bag, err, json, use_color);
            try err.print("error: {t}\n", .{e});
            return 1;
        },
    };
    defer result.deinit();

    // Diagnostics on a SUCCESSFUL compile — W0650 is the reason this path
    // exists. DEFERRED, because codegen is a diagnostic-producing stage too
    // (E0515: a §4.5 control argument that does not resolve is reported at the
    // `.va` line, not pasted into the generated Zig as an `@compileError`), and
    // `render` prints the whole bag — so there is exactly one call for every
    // exit below rather than one per return path.
    defer report(&bag, err, json, use_color) catch {};

    if (!emit_zig and !check and !emit_so and !emit_exe) return 0;

    // The catalogue that consumes the generated file keys devices by the name
    // the BUILD chose, while the netlist dispatch and the generated type name
    // come from the MODULE name. A mismatch silently breaks lookup, so it is
    // caught here rather than three cache steps downstream.
    //
    // NOTE: a vendored file declaring several modules (VBIC ships 4T/5T in one
    // file) trips this — FastVAF lowers one of them, not necessarily the one
    // the file is named after. A module selector is the fix.
    if (expect_module) |want| {
        if (!std.mem.eql(u8, result.mir.name, want)) {
            try err.print(
                "error: {s}: Verilog-A module is `{s}` but `{s}` was expected — rename one of them\n",
                .{ in_path, result.mir.name, want },
            );
            return 1;
        }
    }

    const device = result.generateDevice() catch |e| {
        try err.print("error: {s}: codegen failed: {t}\n", .{ in_path, e });
        return 1;
    };

    // A generated `@compileError` is a refusal by codegen. Writing the file
    // anyway defers the real message to whoever compiles it, by which point it
    // no longer names the .va that caused it.
    if (result.device_has_compile_error) {
        try err.print(
            "error: {s}: codegen refused a construct; the generated device contains @compileError\n",
            .{in_path},
        );
        return 1;
    }

    // --check: prove the generated Zig actually compiles, HERE, where the .va
    // that produced it is still in hand. Without this a codegen bug surfaces
    // as an error inside generated code in a build cache directory, with
    // nothing pointing back at the source model.
    if (check or emit_so) {
        const contract = contract_path orelse {
            try err.writeAll(
                "error: --check and --emit-so need --contract PATH (the root of the " ++
                    "`contract` module the generated device imports)\n",
            );
            return 2;
        };
        if (try typeCheck(gpa, io, err, zig_exe, contract, device, in_path)) |code| return code;
    }

    // --emit-exe: the OTHER artifact. Same frontend, same device.zig; what
    // changes is that the display tasks are real and a generated runner drives
    // the module over the operating points its `//!` lines declare.
    if (emit_exe) {
        const contract = contract_path orelse {
            try err.writeAll(
                "error: --emit-exe needs --contract PATH (the root of the `contract` " ++
                    "module the generated device imports)\n",
            );
            return 2;
        };
        const wd = work_dir orelse ".zig-cache/fastvaf-tb";
        // The directive tables and the runner text are a web of small slices
        // with one lifetime; an arena is the whole memory management here.
        var tb_arena: std.heap.ArenaAllocator = .init(gpa);
        defer tb_arena.deinit();
        const d = fastvaf.tb.parse(tb_arena.allocator(), source) catch |e| {
            try err.print("error: {s}: `//!` directive: {t}\n", .{ in_path, e });
            return 2;
        };
        const runner = try fastvaf.tb.renderRunner(tb_arena.allocator(), std.fs.path.stem(in_path), d);
        const built = fastvaf.tb.buildExe(gpa, io, device, runner, .{
            .work_dir = wd,
            .contract = contract,
            .name = result.mir.name,
            .out_path = out_path,
            .zig_exe = zig_exe,
        }) catch |e| {
            try err.print("error: {s}: building the testbench failed: {t}\n", .{ in_path, e });
            return 1;
        };
        defer built.deinit(gpa);
        const bin = switch (built) {
            .failed => |text| {
                try err.print(
                    "error: {s}: the generated testbench does not compile — this is an " ++
                        "engine bug, not a problem with the model:\n",
                    .{in_path},
                );
                try err.writeAll(text);
                return 1;
            },
            .ok => |p| p,
        };
        if (!run_exe) {
            try out.print("{s}\n", .{bin});
            try out.flush();
            return 0;
        }
        // --run: the transcript is the point, so inherit both streams and let
        // the testbench's exit status be ours.
        var child = try std.process.spawn(io, .{ .argv = &.{bin} });
        return switch (try child.wait(io)) {
            .exited => |c| c,
            else => 1,
        };
    }

    if (emit_so) {
        const wd = work_dir orelse {
            try err.writeAll("error: --emit-so needs --work-dir DIR\n");
            return 2;
        };
        const dyn = dyn_path orelse {
            try err.writeAll("error: --emit-so needs --dyn PATH\n");
            return 2;
        };
        const modules = [_]fastvaf.orchestrator.Module{
            .{ .name = "contract", .root = contract_path.? },
            .{ .name = "dyn", .root = dyn, .deps = &.{"contract"} },
        };
        var r = fastvaf.buildArtifact(gpa, io, &result, .{
            .work_dir = wd,
            .name = result.mir.name,
            .optimize = .ReleaseFast,
            .backend = .llvm,
            .modules = &modules,
            .zig_exe = zig_exe,
        }, 1, null) catch |e| {
            try err.print("error: {s}: building the device failed: {t}\n", .{ in_path, e });
            return 1;
        };
        defer r.deinit(gpa);
        switch (r) {
            .ok => |a| try out.print("{s}\n", .{a.so_path}),
            .failed => |bundle| {
                try err.print("error: {s}: the generated device did not compile:\n", .{in_path});
                try bundle.renderToWriter(.{}, err);
                return 1;
            },
        }
    }

    if (emit_zig) {
        if (out_path) |p| {
            Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = device }) catch |e| {
                try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
                return 1;
            };
        } else {
            try out.writeAll(device);
        }
    }
    return 0;
}

fn missing(w: *Io.Writer, flag: []const u8, what: []const u8) !u8 {
    try w.print("error: {s} needs {s}\n", .{ flag, what });
    return 2;
}

/// Run `zig build-obj` over the generated device with the `contract` module on
/// the command line. Returns null when it type-checks, or the exit code to use.
///
/// `build-obj`, not `build-lib`: this only has to prove the code is valid, and
/// object emission skips linking entirely.
fn typeCheck(
    gpa: std.mem.Allocator,
    io: Io,
    err: *Io.Writer,
    zig_exe: []const u8,
    contract: []const u8,
    device_zig: []const u8,
    in_path: []const u8,
) !?u8 {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, ".zig-cache/fastvaf-check");
    var tmp = try cwd.openDir(io, ".zig-cache/fastvaf-check", .{});
    defer tmp.close(io);

    const stem = std.fs.path.stem(in_path);
    const dev_name = try std.fmt.allocPrint(gpa, "{s}.device.zig", .{stem});
    defer gpa.free(dev_name);
    try tmp.writeFile(io, .{ .sub_path = dev_name, .data = device_zig });

    const dev_path = try std.fmt.allocPrint(gpa, ".zig-cache/fastvaf-check/{s}", .{dev_name});
    defer gpa.free(dev_path);
    const contract_arg = try std.fmt.allocPrint(gpa, "-Mcontract={s}", .{contract});
    defer gpa.free(contract_arg);
    const root_arg = try std.fmt.allocPrint(gpa, "-Mroot={s}", .{dev_path});
    defer gpa.free(root_arg);

    // `--dep` applies to the NEXT `-M`, and the FIRST `-M` is the root module —
    // same ordering rule buildArgv() in orchestrator.zig follows.
    const argv = [_][]const u8{
        zig_exe,      "build-obj",   "-fno-emit-bin",
        "--dep",      "contract",    root_arg,
        contract_arg, "--cache-dir", ".zig-cache",
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });

    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var out_text: std.ArrayList(u8) = .empty;
    defer out_text.deinit(gpa);
    var aw: Io.Writer.Allocating = .fromArrayList(gpa, &out_text);
    defer out_text = aw.toArrayList();
    _ = reader.interface.streamRemaining(&aw.writer) catch {};

    const term = try child.wait(io);
    const failed = switch (term) {
        .exited => |c| c != 0,
        else => true,
    };
    if (!failed) return null;

    try err.print(
        "error: {s}: codegen produced Zig that does not compile — this is an engine bug, " ++
            "not a problem with the model:\n",
        .{in_path},
    );
    try err.writeAll(aw.writer.buffered());
    return 1;
}

fn report(bag: *diag.Bag, w: *Io.Writer, json: bool, color: bool) !void {
    if (bag.isEmpty()) return;
    if (json) {
        try diag.renderJson(bag, w);
    } else {
        try diag.render(bag, w, .{ .palette = if (color) .on else .off });
    }
    try w.flush();
}
