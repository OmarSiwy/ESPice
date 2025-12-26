//! GPU-resident Newton loop orchestration.
//!
//! Mirrors converger.solve but with everything on device. Owns device
//! buffers for: x, dx, rhs, g_vals, c_vals, q_vec, gather/scatter tapes,
//! model/instance SoA params, diag_slots.
//!
//! Upload ONCE at analysis start. Then loop:
//!   1. Launch zero_planes kernel
//!   2. Launch eval_<model> kernels (one per batch type)
//!   3. Launch gmin_diag kernel
//!   4. For JFNK: GMRES entirely on device (J·v via eval kernels)
//!      For direct Newton on GPU: needs batched block LU — OUT OF SCOPE
//!   5. Launch update_x kernel
//!   6. Launch max_dx_reduce → readback ONE f64 (convergence flag)
//!   7. If converged, break; else goto 1.
//!
//! Download ONCE at analysis end: solution x.
//!
//! STATUS: Skeleton / TODO. The JFNK-CPU path (converger.jfnk) is the
//! primary deliverable for Phase 4. This module is the GPU orchestration
//! substrate for Phase 5 when the kernel pipeline is proven on more
//! device types and the host↔device buffer management is validated.

const std = @import("std");
const root = @import("root.zig");
const converger = @import("converger.zig");

/// GPU-supported device types. A circuit is GPU-eligible only if every
/// batch is in this whitelist.
const gpu_supported_types = [_][]const u8{
    "resistor",
    "mos1",
    "capacitor",
    "vsource",
    "isource",
};

/// Check whether a circuit is eligible for GPU-resident Newton.
pub fn isGpuEligible(ckt: *const root.Circuit, min_instances: u32) bool {
    var total: u32 = 0;
    for (ckt.batches) |batch| {
        var found = false;
        for (gpu_supported_types) |name| {
            if (std.mem.eql(u8, batch.type_name, name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
        total += batch.count;
    }
    return total >= min_instances;
}

/// Result from GPU-resident Newton.
pub const GpuResult = struct {
    converged: bool,
    iterations: u16,
    max_dx: f64,
};

/// GPU Newton context. Placeholder for device buffer ownership.
/// TODO Phase 5: allocate device buffers, upload tapes, implement
/// the kernel launch loop.
pub const GpuNewton = struct {
    // Device buffers would go here:
    // d_x, d_dx, d_rhs, d_g_vals, d_c_vals, d_q_vec,
    // d_gath, d_rhs_idx, d_slots, d_diag_slots,
    // d_params (per device type), d_dx_abs, d_max_dx

    /// Initialize GPU Newton context.
    /// Returns error.GpuNotAvailable if the GPU path cannot be used.
    pub fn init(
        _: std.mem.Allocator,
        _: *const root.Circuit,
    ) error{GpuNotAvailable}!GpuNewton {
        // TODO Phase 5: probe GPU, allocate device buffers, upload tapes
        return error.GpuNotAvailable;
    }

    /// Run the GPU-resident Newton loop. Falls back to CPU JFNK on error.
    pub fn solve(
        _: *GpuNewton,
        ckt: *root.Circuit,
        x: []f64,
        _: converger.Options,
        gpa: std.mem.Allocator,
    ) !GpuResult {
        // TODO Phase 5: implement GPU kernel launch loop
        // For now, fall back to CPU JFNK which is the same algorithm
        // (Jacobian-free Newton-Krylov) just on the host.
        const dx = try gpa.alloc(f64, ckt.n);
        defer gpa.free(dx);
        const x_old = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x_old);

        const ws = try converger.Workspace.init(gpa, ckt);
        defer @constCast(&ws).deinit(gpa);

        const r = try converger.jfnk(
            ckt,
            @constCast(&ws.slv),
            x,
            dx,
            x_old,
            0,
            .{},
            converger.EvalHook{},
            gpa,
        );
        return .{
            .converged = r.converged,
            .iterations = r.iterations,
            .max_dx = r.max_dx,
        };
    }

    pub fn deinit(_: *GpuNewton) void {
        // TODO Phase 5: free device buffers
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isGpuEligible: empty circuit is not eligible" {
    // A circuit with no batches has 0 instances < any threshold
    var ckt: root.Circuit = undefined;
    ckt.batches = &.{};
    try testing.expect(!isGpuEligible(&ckt, 10000));
}

test "GpuNewton.init returns GpuNotAvailable (stub)" {
    // The stub always returns error.GpuNotAvailable
    var ckt: root.Circuit = undefined;
    ckt.batches = &.{};
    try testing.expectError(error.GpuNotAvailable, GpuNewton.init(testing.allocator, &ckt));
}
