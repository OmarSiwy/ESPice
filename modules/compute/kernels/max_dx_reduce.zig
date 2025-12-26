//! Warp-level tree reduction to find max |dx|.
//! One block, BLOCK_SIZE threads. Each thread reads a strided slice of dx_abs.
//! Result written to out[0].

const BLOCK_SIZE: u32 = 256;

fn maxDxReduceImpl(
    n: u32,
    dx_abs: [*]addrspace(.global) const f64,
    out: [*]addrspace(.global) f64,
) callconv(.kernel) void {
    const tid = @workItemId(0);

    // Each thread finds max over its strided chunk
    var local_max: f64 = 0.0;
    var i: u32 = tid;
    while (i < n) : (i += BLOCK_SIZE) {
        const v = dx_abs[i];
        if (v > local_max) local_max = v;
    }

    // Warp-level reduction via shuffle. On nvptx, warp size = 32.
    // Use butterfly reduction pattern.
    var offset: u32 = 16;
    while (offset >= 1) : (offset >>= 1) {
        const other = @shuffleDown(f64, local_max, offset);
        if (other > local_max) local_max = other;
    }

    // Lane 0 of each warp writes to shared memory via atomicMax.
    // Since CUDA doesn't have f64 atomicMax, we use a simple strategy:
    // warp lane 0 atomics to out[0].
    if (tid % 32 == 0) {
        // Spin-free atomic max via CAS loop on the output
        atomicMaxF64(&out[0], local_max);
    }
}

fn atomicMaxF64(ptr: *addrspace(.global) f64, val: f64) void {
    // AtomicRmw doesn't support Max for f64 on all targets.
    // Use compare-and-swap loop.
    var current = @atomicLoad(f64, ptr, .monotonic);
    while (val > current) {
        const result = @cmpxchgWeak(f64, ptr, current, val, .monotonic, .monotonic);
        if (result) |r| {
            current = r;
        } else {
            break;
        }
    }
}

comptime {
    @export(&maxDxReduceImpl, .{ .name = "max_dx_reduce" });
}
