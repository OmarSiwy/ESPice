//! Synthetic circuit builder for analysis tests. Wraps batch.freeze() +
//! testdev devices so any test can construct a real Circuit without the
//! engine's parser/builder pipeline.
const std = @import("std");
const root = @import("analysis");
// `analysis.problem` was renamed out from under this file, which is why it
// stopped compiling and, being reachable from no test root, said nothing.
// Proto/ProtoStore live with the device engine; freeze is Circuit.init.
const batch = root.devices.batch;
const testdev = @import("testdev.zig");

const Circuit = root.Circuit;
const Proto = batch.Proto;

fn protoFor(comptime D: type, store: *batch.ProtoStore(D)) Proto {
    return .{
        .ctx = store,
        .type_name = @typeName(D),
        .pattern = batch.ProtoStore(D).addPattern,
        .finalize = batch.ProtoStore(D).finalize,
        .destroy = batch.ProtoStore(D).destroy,
        .apply_perm = batch.ProtoStore(D).applyPerm,
    };
}

pub fn build(gpa: std.mem.Allocator) !Circuit {
    var protos: std.ArrayList(Proto) = .empty;
    defer protos.deinit(gpa);

    // Through ProtoStore.append, NOT the three ArrayLists behind it: those
    // allocate from `staging_gpa`, and finalize deinits them against
    // `staging_gpa`. Filling them with the caller's allocator leaked four
    // blocks per test and freed testing.allocator memory through the wrong
    // allocator — which is what this file did before it was wired in.
    const resistors = try gpa.create(batch.ProtoStore(testdev.R));
    resistors.* = .{};
    for ([_][2]u32{ .{ 1, 2 }, .{ 2, 0 } }) |nodes| {
        try resistors.append(.{ .r = 1000 }, .{}, nodes);
    }
    try protos.append(gpa, protoFor(testdev.R, resistors));

    const source = try gpa.create(batch.ProtoStore(testdev.V));
    source.* = .{};
    try source.append(.{ .dc = 10.0 }, .{}, .{ 1, 0, 3 });
    try protos.append(gpa, protoFor(testdev.V, source));

    // Node 0 is ground; n3 is the source branch. Freeze owns both slices.
    const intern_bytes = try gpa.dupe(u8, "0n1n2n3");
    const intern_offs = try gpa.dupe(u32, &.{ 0, 1, 3, 5, 7 });
    return root.freeze(gpa, 4, intern_bytes, intern_offs, protos.items, null);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const op = root.op;

/// Value of the assembled entry at (row, col), or null when the pattern has no
/// slot for that pair. Linear scan of one column — the fixture is 4x4, and a
/// test that mirrors the CSC walk it is checking proves less than one that
/// reads the pattern the plain way.
fn entry(ckt: *const Circuit, plane: []const f64, row: u32, col: u32) ?f64 {
    var k = ckt.col_ptr[col];
    while (k < ckt.col_ptr[col + 1]) : (k += 1) {
        if (ckt.row_idx[k] == row) return plane[k];
    }
    return null;
}

// ===========================================================================
// Seam 1: freeze/init — the layout contract every downstream reader assumes.
// These are invariants of CSC and of MNA, not a transcript of today's output.
// ===========================================================================

test "freeze: CSC pattern is well formed" {
    var ckt = try build(testing.allocator);
    defer ckt.deinit();

    try testing.expectEqual(@as(usize, ckt.n + 1), ckt.col_ptr.len);
    try testing.expectEqual(@as(u32, 0), ckt.col_ptr[0]);
    try testing.expectEqual(ckt.nnz, ckt.col_ptr[ckt.n]);

    for (0..ckt.n) |j| {
        const lo = ckt.col_ptr[j];
        const hi = ckt.col_ptr[j + 1];
        try testing.expect(lo <= hi); // monotone
        var k = lo;
        while (k < hi) : (k += 1) {
            try testing.expect(ckt.row_idx[k] < ckt.n); // in range
            // Strictly ascending: sorted AND no duplicate slot for one pair,
            // which is what makes a single stamp per (row,col) well defined.
            if (k + 1 < hi) try testing.expect(ckt.row_idx[k] < ckt.row_idx[k + 1]);
        }
    }
}

test "freeze: ground stamps land in the trash slot past nnz" {
    var ckt = try build(testing.allocator);
    defer ckt.deinit();

    try testing.expectEqual(ckt.nnz, ckt.trash_slot);
    // The planes must carry the extra slot, or every ground stamp is an
    // out-of-bounds write rather than a discarded one.
    try testing.expect(ckt.g_vals.len > ckt.trash_slot);
    try testing.expect(ckt.c_vals.len > ckt.trash_slot);
}

test "freeze: diag_slots points at the diagonal of its own column" {
    var ckt = try build(testing.allocator);
    defer ckt.deinit();

    try testing.expectEqual(@as(usize, ckt.n), ckt.diag_slots.len);
    for (0..ckt.n) |j| {
        const slot = ckt.diag_slots[j];
        if (slot == ckt.trash_slot) continue; // no diagonal in the pattern
        try testing.expect(slot < ckt.nnz);
        try testing.expectEqual(@as(u32, @intCast(j)), ckt.row_idx[slot]);
        try testing.expect(slot >= ckt.col_ptr[j] and slot < ckt.col_ptr[j + 1]);
    }
}

test "freeze: current-row marking is opt-in, and defaults to none" {
    var ckt = try build(testing.allocator);
    defer ckt.deinit();

    try testing.expectEqual(@as(usize, ckt.n), ckt.current_row.len);
    // Circuit.init memsets this false and then only lets batches whose device
    // declares `u_kinds` mark into it (engine.zig:1646 gates the hook on
    // @hasDecl). testdev.V declares none, so every row reads as a voltage row
    // even though unknown 3 IS its branch current.
    //
    // That gap is the fixture's, not Circuit's: real VerA devices emit
    // `u_kinds`, so they mark and the converger gives the branch row its
    // current tolerance. Giving testdev.V a `u_kinds` would change the
    // tolerance every existing test using it converges under, so it is a
    // separate change, not a rider on this one.
    for (ckt.current_row) |is_current| try testing.expect(!is_current);
}

test "freeze: the intern table round-trips every node name" {
    var ckt = try build(testing.allocator);
    defer ckt.deinit();

    try testing.expectEqual(@as(usize, ckt.n + 1), ckt.intern_offs.len);
    try testing.expectEqualStrings("n1", ckt.nodeName(1));
    try testing.expectEqualStrings("n2", ckt.nodeName(2));
    try testing.expectEqualStrings("n3", ckt.nodeName(3));
}

// ===========================================================================
// Seam 2: eval/stamp — the assembled system for a known circuit.
// n1 --R(1k)-- n2 --R(1k)-- gnd, with V=10 across n1..gnd on branch 3.
// ===========================================================================

test "eval: the divider assembles the conductances MNA says it should" {
    var ckt = try build(testing.allocator);
    defer ckt.deinit();

    const x = try testing.allocator.alloc(f64, ckt.n + 1);
    defer testing.allocator.free(x);
    @memset(x, 0);
    ckt.eval(x, 0);

    const g = 1.0 / 1000.0;
    const tol = 1e-12;

    // n1 touches one resistor; n2 is between both, so its diagonal is 2g.
    try testing.expectApproxEqAbs(g, entry(&ckt, ckt.g_vals, 1, 1).?, tol);
    try testing.expectApproxEqAbs(2 * g, entry(&ckt, ckt.g_vals, 2, 2).?, tol);
    // Off-diagonals of a floating resistor are the negated conductance, and
    // the pair is symmetric for a reciprocal element.
    try testing.expectApproxEqAbs(-g, entry(&ckt, ckt.g_vals, 1, 2).?, tol);
    try testing.expectApproxEqAbs(-g, entry(&ckt, ckt.g_vals, 2, 1).?, tol);
}

test "eval: the voltage source contributes its MNA incidence pair" {
    var ckt = try build(testing.allocator);
    defer ckt.deinit();

    const x = try testing.allocator.alloc(f64, ckt.n + 1);
    defer testing.allocator.free(x);
    @memset(x, 0);
    ckt.eval(x, 0);

    // V's branch couples node 1 to unknown 3 both ways: the KCL row gains the
    // branch current, the KVL row reads the node voltage. Magnitude 1 each —
    // an incidence, not a conductance — and that is what makes the block
    // symmetric-indefinite rather than SPD.
    const a = entry(&ckt, ckt.g_vals, 1, 3).?;
    const b = entry(&ckt, ckt.g_vals, 3, 1).?;
    try testing.expectApproxEqAbs(@as(f64, 1.0), @abs(a), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), @abs(b), 1e-12);
}

test "test_circuit: resistor divider OP" {
    var ckt = try build(testing.allocator);
    defer ckt.deinit();

    const x = try testing.allocator.alloc(f64, ckt.n);
    defer testing.allocator.free(x);
    const result = try op.solve(&ckt, x, .{});
    try testing.expect(result.converged);
    try testing.expectApproxEqAbs(@as(f64, 5.0), x[2], 1e-6);
}

// The memo keys on x_op's POINTER, and x_op is one stable arena slice — so a
// direct eval at a different x must clear it, or the next linearize(x_op)
// false-hits on planes that hold someone else's operating point. disto,
// matex, qpss, pss, pnoise, pac, pxf and tran_noise all eval directly.
test "LinCache: a direct eval at another x invalidates the memo" {
    var ckt = try build(testing.allocator);
    defer ckt.deinit();

    const x_op = try testing.allocator.alloc(f64, ckt.n + 1);
    defer testing.allocator.free(x_op);
    @memset(x_op, 0);

    ckt.linearize(x_op);
    try testing.expect(ckt.lin.valid);

    const x_other = try testing.allocator.alloc(f64, ckt.n + 1);
    defer testing.allocator.free(x_other);
    @memset(x_other, 1.0);
    ckt.eval(x_other, 0);
    try testing.expect(!ckt.lin.valid);

    // Same pointer as the first call: must re-evaluate, not hit the memo.
    ckt.linearize(x_op);
    try testing.expect(ckt.lin.valid);
}
