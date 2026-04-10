// BLAS-1 compute shaders for GPU-accelerated vector operations.
// Each dispatch covers one operation; the host selects via pipeline.

struct Params {
    n: u32,
    alpha: f32,    // wgpu doesn't support f64 by default; we pack f64 as 2×u32
    alpha_hi: u32, // high 32 bits of f64 alpha
    alpha_lo: u32, // low 32 bits of f64 alpha
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> x: array<u32>;  // f64 as 2×u32
@group(0) @binding(2) var<storage, read> y: array<u32>;         // f64 as 2×u32
@group(0) @binding(3) var<storage, read_write> result: array<u32>; // partial sums

// Workgroup size: 256 threads for good occupancy.
const WG_SIZE: u32 = 256u;

// --- axpy: x[i] += alpha * y[i] ---
@compute @workgroup_size(WG_SIZE)
fn axpy(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x;
    if (i >= params.n) {
        return;
    }
    // f64 packed as two u32s at indices 2*i and 2*i+1
    let xi_lo = x[2u * i];
    let xi_hi = x[2u * i + 1u];
    let yi_lo = y[2u * i];
    let yi_hi = y[2u * i + 1u];

    // Bitcast to f32 pairs for approximate computation.
    // Full f64 support requires the f64 extension.
    let xi = bitcast<f32>(xi_lo);
    let yi = bitcast<f32>(yi_lo);
    let alpha_f32 = params.alpha;
    let res = xi + alpha_f32 * yi;
    x[2u * i] = bitcast<u32>(res);
}

// --- scale: x[i] *= alpha ---
@compute @workgroup_size(WG_SIZE)
fn scale(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x;
    if (i >= params.n) {
        return;
    }
    let xi = bitcast<f32>(x[2u * i]);
    let res = params.alpha * xi;
    x[2u * i] = bitcast<u32>(res);
}

// --- dot product partial sums (reduction step 1) ---
var<workgroup> shared_sums: array<f32, WG_SIZE>;

@compute @workgroup_size(WG_SIZE)
fn dot_partial(
    @builtin(global_invocation_id) gid: vec3<u32>,
    @builtin(local_invocation_id) lid: vec3<u32>,
    @builtin(workgroup_id) wid: vec3<u32>,
) {
    let i = gid.x;
    if (i < params.n) {
        let xi = bitcast<f32>(x[2u * i]);
        let yi = bitcast<f32>(y[2u * i]);
        shared_sums[lid.x] = xi * yi;
    } else {
        shared_sums[lid.x] = 0.0;
    }

    workgroupBarrier();

    // Tree reduction within workgroup.
    var stride = WG_SIZE / 2u;
    loop {
        if (stride == 0u) {
            break;
        }
        if (lid.x < stride) {
            shared_sums[lid.x] = shared_sums[lid.x] + shared_sums[lid.x + stride];
        }
        workgroupBarrier();
        stride = stride / 2u;
    }

    if (lid.x == 0u) {
        result[wid.x] = bitcast<u32>(shared_sums[0]);
    }
}

// --- norm_inf partial maxes (reduction step 1) ---
var<workgroup> shared_maxes: array<f32, WG_SIZE>;

@compute @workgroup_size(WG_SIZE)
fn norm_inf_partial(
    @builtin(global_invocation_id) gid: vec3<u32>,
    @builtin(local_invocation_id) lid: vec3<u32>,
    @builtin(workgroup_id) wid: vec3<u32>,
) {
    let i = gid.x;
    if (i < params.n) {
        let xi = bitcast<f32>(x[2u * i]);
        shared_maxes[lid.x] = abs(xi);
    } else {
        shared_maxes[lid.x] = 0.0;
    }

    workgroupBarrier();

    var stride = WG_SIZE / 2u;
    loop {
        if (stride == 0u) {
            break;
        }
        if (lid.x < stride) {
            shared_maxes[lid.x] = max(shared_maxes[lid.x], shared_maxes[lid.x + stride]);
        }
        workgroupBarrier();
        stride = stride / 2u;
    }

    if (lid.x == 0u) {
        result[wid.x] = bitcast<u32>(shared_maxes[0]);
    }
}
