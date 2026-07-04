//! GPU kernel: resistor instance evaluation.
//! One thread per resistor instance.
//!
//! Reads terminal voltages via gather indices, computes ir = (vp-vn)/r,
//! atomically scatters into rhs and g_vals.
//!
//! Layout:
//!   gath[2*id+0] = node index for port p
//!   gath[2*id+1] = node index for port n
//!   rhs_idx[2*id+0] = rhs row for port p
//!   rhs_idx[2*id+1] = rhs row for port n
//!   slots[4*id+0..3] = g_vals slots for the 2x2 stamp:
//!     [0] = diag(p,p), [1] = off(p,n), [2] = off(n,p), [3] = diag(n,n)
//!   conductance[id] = 1/R for this instance

fn evalResistorImpl(
    n_instances: u32,
    x: [*]addrspace(.global) const f64,
    gath: [*]addrspace(.global) const u32,
    rhs_idx: [*]addrspace(.global) const u32,
    slots: [*]addrspace(.global) const u32,
    conductance: [*]addrspace(.global) const f64,
    rhs: [*]addrspace(.global) f64,
    g_vals: [*]addrspace(.global) f64,
) callconv(.kernel) void {
    const id = @workGroupId(0) * @workGroupSize(0) + @workItemId(0);
    if (id >= n_instances) return;

    const np = gath[2 * id + 0];
    const nn = gath[2 * id + 1];
    const vp = x[np];
    const vn = x[nn];
    const g = conductance[id];
    const ir = g * (vp - vn);

    // Scatter to rhs (atomicAdd for concurrent writes)
    const rp = rhs_idx[2 * id + 0];
    const rn = rhs_idx[2 * id + 1];
    _ = @atomicRmw(f64, &rhs[rp], .Add, ir, .monotonic);
    _ = @atomicRmw(f64, &rhs[rn], .Add, -ir, .monotonic);

    // Scatter conductance stamp to g_vals
    const s0 = slots[4 * id + 0]; // (p,p) += g
    const s1 = slots[4 * id + 1]; // (p,n) += -g
    const s2 = slots[4 * id + 2]; // (n,p) += -g
    const s3 = slots[4 * id + 3]; // (n,n) += g
    _ = @atomicRmw(f64, &g_vals[s0], .Add, g, .monotonic);
    _ = @atomicRmw(f64, &g_vals[s1], .Add, -g, .monotonic);
    _ = @atomicRmw(f64, &g_vals[s2], .Add, -g, .monotonic);
    _ = @atomicRmw(f64, &g_vals[s3], .Add, g, .monotonic);
}

comptime {
    @export(&evalResistorImpl, .{ .name = "eval_resistor" });
}
