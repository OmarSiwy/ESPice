//! The fastvf CLI: Verilog / SystemVerilog / VHDL → a contract-shaped Zig
//! device. Deliberately mirrors `fastvaf`'s flags, because `modules/devices`
//! drives both from one build loop and the two generators have to be
//! interchangeable at the call site.
//!
//! usage: fastvf [-o OUT.zig] [--expect-module=NAME] FILE.{v,sv,vhd,vhdl}
//!
//! Front end is picked from the extension: `.sv` goes through sv2v, `.vhd` /
//! `.vhdl` through `ghdl synth`, everything else straight to verilator.
//!
//! Exits 2 on a usage error, 1 on a translation failure.

const std = @import("std");
const zvf = @import("zvf");

const usage_text =
    \\usage: fastvf [options] FILE.{v,sv,vhd,vhdl}
    \\
    \\options:
    \\  -o PATH                 write the generated device to PATH (default: stdout)
    \\  --expect-module=NAME    fail unless the translated module is called NAME
    \\  -h, --help              show this message
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr.interface;
    defer err.flush() catch {};

    var path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var expect_module: ?[]const u8 = null;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try err.writeAll(usage_text);
            return 0;
        } else if (std.mem.eql(u8, arg, "-o")) {
            out_path = args.next() orelse {
                try err.writeAll("error: -o needs a path\n");
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--expect-module=")) {
            expect_module = arg["--expect-module=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try err.print("error: unknown option `{s}`\n", .{arg});
            return 2;
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

    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(io, in_path, gpa, .unlimited) catch |e| {
        try err.print("error: cannot read `{s}`: {t}\n", .{ in_path, e });
        return 2;
    };
    defer gpa.free(source);

    const generated = translate(gpa, io, in_path, source) catch |e| {
        // The front ends shell out to verilator/sv2v/ghdl, so a missing tool is
        // the likeliest failure on a fresh machine and deserves to say so
        // rather than surface as a bare `error.FileNotFound`.
        try err.print("error: {s}: {t}\n", .{ in_path, e });
        if (e == error.FileNotFound)
            try err.writeAll("note: fastvf shells out to `verilator` (and `sv2v` / `ghdl` for .sv / .vhd) — is it on PATH?\n");
        return 1;
    };
    defer gpa.free(generated);

    // The devices catalog keys on the FILE stem while the generated type name
    // comes from the MODULE name; a mismatch would silently register the device
    // under the wrong key, so the build passes --expect-module and we fail here.
    if (expect_module) |want| {
        if (!declaresModule(generated, want)) {
            try err.print(
                "error: {s}: expected module `{s}`, but the translated module is not named that\n",
                .{ in_path, want },
            );
            return 1;
        }
    }

    if (out_path) |p| {
        try cwd.writeFile(io, .{ .sub_path = p, .data = generated });
    } else {
        var buf: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &buf);
        try out.interface.writeAll(generated);
        try out.interface.flush();
    }
    return 0;
}

fn translate(gpa: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, path, ".sv")) return zvf.fromSystemVerilog(gpa, io, source);
    if (std.mem.endsWith(u8, path, ".vhd") or std.mem.endsWith(u8, path, ".vhdl"))
        return zvf.fromVhdl(gpa, io, source);
    return zvf.fromVerilog(gpa, io, source);
}

/// Reads back the `//! Generated from Verilog module \`NAME\`.` header codegen
/// stamps as its first line.
fn declaresModule(generated: []const u8, want: []const u8) bool {
    var buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "//! Generated from Verilog module `{s}`.\n", .{want}) catch return false;
    return std.mem.startsWith(u8, generated, header);
}

test declaresModule {
    try std.testing.expect(declaresModule("//! Generated from Verilog module `and2`.\nconst std", "and2"));
    try std.testing.expect(!declaresModule("//! Generated from Verilog module `and2`.\nconst std", "or2"));
    try std.testing.expect(!declaresModule("const std", "and2"));
}
