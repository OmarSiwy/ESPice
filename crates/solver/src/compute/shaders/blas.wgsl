// BLAS compute shaders (stub).
//
// WARNING: WebGPU only guarantees f32 precision.
// For f64 accuracy, use two-pass f32 or software emulation.
// Current implementation uses f32 — results may differ from CPU by ~1e-6 relative error.
//
// TODO: implement axpy, scale, dot_partial, and norm_inf_partial kernels.
// The CPU fallback path is used until these are implemented and validated.

struct Params {
    n:        u32,
    alpha:    f32,
    alpha_hi: u32,
    alpha_lo: u32,
}

@group(0) @binding(0) var<uniform>  params    : Params;
@group(0) @binding(1) var<storage, read_write> x_buf : array<f32>;
@group(0) @binding(2) var<storage, read>       y_buf : array<f32>;
@group(0) @binding(3) var<storage, read_write> out   : array<f32>;

// Placeholder entry points — all are no-ops until the kernels are written.

@compute @workgroup_size(256)
fn axpy(@builtin(global_invocation_id) gid: vec3<u32>) {
    // TODO: x_buf[i] += alpha * y_buf[i]
}

@compute @workgroup_size(256)
fn scale(@builtin(global_invocation_id) gid: vec3<u32>) {
    // TODO: x_buf[i] *= alpha
}

@compute @workgroup_size(256)
fn dot_partial(@builtin(global_invocation_id) gid: vec3<u32>) {
    // TODO: partial dot product reduction
}

@compute @workgroup_size(256)
fn norm_inf_partial(@builtin(global_invocation_id) gid: vec3<u32>) {
    // TODO: partial infinity-norm reduction
}
