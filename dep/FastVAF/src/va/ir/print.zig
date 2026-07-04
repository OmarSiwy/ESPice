//! Debug printer for MIR — human-readable dump of blocks, instructions and
//! phi edges (used by the conformance golden generator and by hand).

const std = @import("std");
const Mir = @import("Mir.zig"); // sibling

pub fn printMir(mir: *const Mir, writer: anytype) !void {
    try writer.print("function @{s} {{\n", .{mir.name});

    var block_iter = mir.blockIter();
    while (block_iter.next()) |block| {
        try writer.print("\n  block{d}:", .{block.id()});

        try writer.writeAll("  ; preds:");
        var has_pred = false;
        var scan_iter = mir.blockIter();
        while (scan_iter.next()) |other| {
            var inst_iter = mir.blockInsts(other);
            while (inst_iter.next()) |inst| {
                switch (mir.instData(inst)) {
                    .branch => |br| {
                        if (br.then_dst == block or br.else_dst == block) {
                            try writer.print(" block{d}", .{other.id()});
                            has_pred = true;
                        }
                    },
                    .jump => |j| {
                        if (j.destination == block) {
                            try writer.print(" block{d}", .{other.id()});
                            has_pred = true;
                        }
                    },
                    else => {},
                }
            }
        }
        if (!has_pred) try writer.writeAll(" (entry)");
        try writer.writeByte('\n');

        var inst_iter = mir.blockInsts(block);
        while (inst_iter.next()) |inst| {
            try printInst(mir, inst, writer);
        }
    }

    try writer.writeAll("}\n");
}

fn printInst(mir: *const Mir, inst: Mir.Inst, writer: anytype) !void {
    const data = mir.instData(inst);
    const result = mir.instResult(inst);

    try writer.writeAll("    ");

    if (result != .undef and data.opcode().hasResult()) {
        try printValue(result, writer);
        try writer.writeAll(" = ");
    }

    switch (data) {
        .unary => |u| {
            try writer.print("{s} ", .{u.opcode.name()});
            try printValue(u.arg, writer);
        },
        .binary => |b| {
            try writer.print("{s} ", .{b.opcode.name()});
            try printValue(b.args[0], writer);
            try writer.writeAll(", ");
            try printValue(b.args[1], writer);
        },
        .ternary => |t| {
            try writer.print("{s} ", .{t.opcode.name()});
            try printValue(t.args[0], writer);
            try writer.writeAll(", ");
            try printValue(t.args[1], writer);
            try writer.writeAll(", ");
            try printValue(t.args[2], writer);
        },
        .branch => |br| {
            try writer.writeAll("br ");
            try printValue(br.cond, writer);
            try writer.print(", block{d}, block{d}", .{ br.then_dst.id(), br.else_dst.id() });
            if (br.loop_entry) try writer.writeAll(" [loop]");
        },
        .jump => |j| {
            try writer.print("jmp block{d}", .{j.destination.id()});
        },
        .call => |c| {
            try writer.print("call @{s}(", .{mir.callName(c.func_ref)});
            const args = mir.getExtraValues(c.args_start, c.args_len);
            for (args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try printValue(arg, writer);
            }
            try writer.writeByte(')');
        },
        .phi => |p| {
            try writer.writeAll("phi ");
            for (0..p.len) |i| {
                if (i > 0) try writer.writeAll(", ");
                const pair = mir.phiPair(p.pairs_start, @intCast(i));
                try writer.print("[block{d}: ", .{pair.block.id()});
                try printValue(pair.value, writer);
                try writer.writeByte(']');
            }
        },
    }

    try writer.writeByte('\n');
}

fn printValue(val: Mir.Value, writer: anytype) !void {
    switch (val) {
        .undef => try writer.writeAll("undef"),
        .false_ => try writer.writeAll("false"),
        .true_ => try writer.writeAll("true"),
        .f_zero => try writer.writeAll("0.0"),
        .zero => try writer.writeAll("0"),
        .one => try writer.writeAll("1"),
        .f_one => try writer.writeAll("1.0"),
        .f_neg_one => try writer.writeAll("-1.0"),
        .f_two => try writer.writeAll("2.0"),
        .f_ten => try writer.writeAll("10.0"),
        .neg_one => try writer.writeAll("-1"),
        .f_inf => try writer.writeAll("inf"),
        _ => try writer.print("v{d}", .{@intFromEnum(val)}),
    }
}
