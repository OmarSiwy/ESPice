//! GPU problem ABI — the blob layout shared by the host packer
//! (problem.zig) and the nvptx megakernel (modules/compute/kernels/
//! megakernel.zig). MUST stay dependency-free: extern structs + pure
//! comptime helpers only, so the nvptx compilation unit can import it.
//!
//! One contiguous arena, one upload of the prefix [0, off_ws), device-only
//! workspace after. All offsets are byte offsets from blob base, 8-aligned.
//! The kernel takes exactly one argument: the blob base pointer.

/// Newton/JFNK controls the kernel needs. Mirrors converger.Options.
pub const Tol = extern struct {
    reltol: f64,
    abstol: f64,
    vntol: f64,
    residual_tol: f64,
    gmin: f64,
    dx_clamp: f64,
    max_iter: u32,
    gmres_m: u32,
};

/// One device-type batch: SoA tapes + params, all offsets into the blob.
pub const BatchDesc = extern struct {
    kind_id: u32, // fnv1a32(@typeName(D)) — same type both sides, no registry
    count: u32,
    n_u: u32,
    has_q: u32, // bool; extern-struct friendly
    off_gath: u32, // count*n_u u32: x gather indices
    off_rhs_idx: u32, // count*n_u u32: residual scatter rows (ground -> n)
    off_models: u32,
    off_instances: u32,
    off_prep_cache: u32, // 0 = none
    off_prep_group: u32,
    /// count*n_u f64 device-private limited eval points (pnjlim/fetlim
    /// state, device-only region). 0 = device type has no limit fn.
    off_lim: u32 = 0,
};

pub const Header = extern struct {
    magic: u32, // 'ARPG'
    n: u32,
    n_batches: u32,
    n_blocks: u32, // grid size of the cooperative launch
    tol: Tol,
    t: f64,
    // -- sections (byte offsets from blob base) --
    off_batch_table: u32, // n_batches * BatchDesc
    off_current_row: u32, // n u8: 1 = branch-current row (abstol)
    off_x: u32, // n f64, seeded by host — last uploaded section
    off_ws: u32, // device-only workspace from here
    off_result: u32,
    total_bytes: u32,
    // -- transient (arp_tran entry; sizes 0 / values ignored for arp_solve,
    // hence the zero defaults) --
    method: u32 = 0, // 0 = BE, 1 = trap, 2 = gear2
    tran_reset: u32 = 0, // 1 = first chunk: kernel initializes tran state in ws
    n_probes: u32 = 0,
    n_breakpoints: u32 = 0,
    max_steps_chunk: u32 = 0, // accepted steps per launch (watchdog bound)
    wave_capacity: u32 = 0, // points; one point = (1 + n_probes) f64
    off_probes: u32 = 0, // n_probes u32 (x indices)
    off_breakpoints: u32 = 0, // n_breakpoints f64, sorted ascending, < t_stop
    off_wave: u32 = 0, // wave_capacity*(1+n_probes) f64, device-written
    _pad: u32 = 0,
    t_stop: f64 = 0,
    dt_init: f64 = 0,
    dt_min: f64 = 0,
    dt_max: f64 = 0, // host pre-clamps (t_stop/50 heuristic applied)
    chgtol: f64 = 0,
    trtol: f64 = 0,
};

pub const ResultHeader = extern struct {
    status: u32, // solve: 0 running, 1 converged, 2 not converged
    // tran: 0 chunk done (relaunch), 1 t_stop reached, 3 dt underflow
    iterations: u32, // last Newton solve's iterations
    max_dx: f64,
    // -- transient chunk results --
    steps: u32, // accepted steps this chunk
    wave_len: u32, // waveform points written this chunk
    t_final: f64,
    dt_next: f64,
};

pub const status_running: u32 = 0;
pub const status_done: u32 = 1;
pub const status_no_conv: u32 = 2;
pub const status_dt_underflow: u32 = 3;

pub const magic: u32 = 0x47505241; // "ARPG" little-endian

/// Max cooperative grid the workspace supports (per-block reduction slots).
pub const max_blocks = 1024;

/// Device workspace layout (f64 slots from off_ws), n = unknowns, m = gmres_m:
///   v_basis (m+1)*n | h (m+1)*m | cs m | sn m | g m+1 | y m
///   r n | w n | x_pert n | f0 n | f0_shift n | diag n | x_old n | rhs n+1
///   -- transient state (persists across chunk launches; solve ignores) --
///   x_try n | i_prev n | cvec n | q_hist 4*(n+1) | tstate 16
///   -- control tail (must stay last; host zeroes ws once at init) --
///   scalars 16 (reduction results + control flags, thread-0 owned)
///   partials max_blocks (per-block reduction slots)
///   barrier 1 (count/generation u32 pair)
/// Per-batch lim_x sections (BatchDesc.off_lim) follow the workspace; they
/// are sized by the packer (count*n_u per limited batch), not here.
pub fn wsF64Count(n: usize, m: usize) usize {
    return (m + 1) * n + (m + 1) * m + m + m + (m + 1) + m + 7 * n + (n + 1) +
        3 * n + 4 * (n + 1) + 16 +
        16 + max_blocks + 1;
}

pub fn fnv1a32(comptime s: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (s) |c| {
        h ^= c;
        h *%= 0x01000193;
    }
    return h;
}

pub fn kindId(comptime D: type) u32 {
    return comptime fnv1a32(@typeName(D));
}

pub fn alignUp(x: usize, comptime a: usize) usize {
    return (x + a - 1) & ~@as(usize, a - 1);
}
