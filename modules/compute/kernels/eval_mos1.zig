//! GPU kernel: MOS Level 1 (Shichman-Hodges) instance evaluation.
//! One thread per MOSFET instance. Scalar (non-AD) path: computes drain
//! current and its derivatives analytically, then stamps into rhs + g_vals
//! via atomicAdd.
//!
//! This replicates the physics from modules/devices/src/mos1.zig evalFromPrep
//! for the DC core (no Meyer charges, no junction caps — those are handled
//! by the charge plane separately on the CPU side for now).
//!
//! Layout:
//!   gath[6*id+0..5] = node indices for {drain, gate, source, bulk, d_prime, s_prime}
//!   rhs_idx[6*id+0..5] = rhs row indices (same order)
//!   For the conductance stamp, we need the 18 g_pattern entries per instance.
//!   g_slots[18*id+0..17] = g_vals slot indices matching g_pattern_override order
//!   params[id] = DcParamsGpu struct (SoA-packed separately)
//!
//! Since hand-rolling exp() is needed on nvptx (no libcall), we use a
//! polynomial approximation.

/// Hand-rolled exp(x) for nvptx: range-reduced polynomial.
/// Accurate to ~1e-7 relative error for |x| < 88.
fn gpu_exp(x_in: f64) f64 {
    // Clamp to avoid overflow/underflow
    const x = if (x_in > 88.0) @as(f64, 88.0) else if (x_in < -88.0) @as(f64, -88.0) else x_in;

    // Range reduction: exp(x) = 2^k * exp(r) where x = k*ln2 + r
    const ln2: f64 = 0.6931471805599453;
    const inv_ln2: f64 = 1.4426950408889634;

    // k = round(x / ln2)
    const kf = x * inv_ln2;
    // Round to nearest integer
    const k_round = if (kf >= 0) kf + 0.5 else kf - 0.5;
    // Truncate to integer
    const k_int: i32 = @intFromFloat(k_round);
    const k: f64 = @floatFromInt(k_int);
    const r = x - k * ln2;

    // Minimax polynomial for exp(r), |r| <= ln2/2
    // exp(r) ~ 1 + r + r^2/2 + r^3/6 + r^4/24 + r^5/120 + r^6/720
    const r2 = r * r;
    const r3 = r2 * r;
    const p = 1.0 + r + r2 * 0.5 + r3 * (1.0 / 6.0) + r2 * r2 * (1.0 / 24.0) + r2 * r3 * (1.0 / 120.0) + r3 * r3 * (1.0 / 720.0);

    // Multiply by 2^k using bit manipulation on the exponent
    // ldexp(p, k) = p * 2^k
    // For GPU, construct the power of 2 via integer arithmetic on the f64 bits
    if (k_int == 0) return p;
    const bias: i64 = 1023;
    const exp_bits: u64 = @bitCast(@as(i64, k_int + bias));
    const pow2: f64 = @bitCast(exp_bits << 52);
    return p * pow2;
}

/// Precomputed DC parameters for one MOS1 instance (GPU-side).
/// Matches the DcParams struct from mos1.zig but laid out for GPU.
const DcParamsGpu = extern struct {
    type_f: f64,
    vt: f64,
    vto: f64,
    gamma: f64,
    phi: f64,
    sqrt_phi: f64,
    lambda: f64,
    beta: f64,
    is_bd: f64,
    is_bs: f64,
    g_rd: f64,
    g_rs: f64,
    m_mult: f64,
};

fn evalMos1Impl(
    n_instances: u32,
    x: [*]addrspace(.global) const f64,
    gath: [*]addrspace(.global) const u32,
    rhs_idx: [*]addrspace(.global) const u32,
    g_slots: [*]addrspace(.global) const u32,
    params: [*]addrspace(.global) const DcParamsGpu,
    rhs: [*]addrspace(.global) f64,
    g_vals: [*]addrspace(.global) f64,
) callconv(.kernel) void {
    const id = @workGroupId(0) * @workGroupSize(0) + @workItemId(0);
    if (id >= n_instances) return;

    // Gather terminal voltages
    const base6 = 6 * id;
    const v_drain = x[gath[base6 + 0]];
    const v_gate = x[gath[base6 + 1]];
    const v_source = x[gath[base6 + 2]];
    const v_bulk = x[gath[base6 + 3]];
    const v_dp = x[gath[base6 + 4]];
    const v_sp = x[gath[base6 + 5]];

    const p = params[id];
    const gmin: f64 = 1.0e-12;

    // --- Raw terminal voltages with PMOS sign flip ---
    const vgs_raw = (v_gate - v_sp) * p.type_f;
    const vds_raw = (v_dp - v_sp) * p.type_f;
    const vbs_raw = (v_bulk - v_sp) * p.type_f;

    // --- Source-drain reversal (branchless) ---
    const vds_abs = if (vds_raw >= 0) vds_raw else -vds_raw;
    const vds_eff = vds_abs;
    const vds_neg = if (vds_raw < 0) vds_raw else @as(f64, 0.0);
    const vgs_eff = vgs_raw - vds_neg;
    const vbs_eff = vbs_raw - vds_neg;

    // Mode for current direction
    const mode = if (vds_eff > 1e-30) vds_raw / vds_eff else @as(f64, 1.0);

    // --- Body effect and threshold voltage ---
    var sarg: f64 = undefined;
    if (vbs_eff <= 0.0) {
        const arg = -vbs_eff + p.phi;
        const clamped = if (arg > 1e-30) arg else @as(f64, 1e-30);
        sarg = @sqrt(clamped);
    } else {
        const val = -vbs_eff / (2.0 * p.sqrt_phi) + p.sqrt_phi;
        sarg = if (val > 0.0) val else @as(f64, 0.0);
    }
    const vth = p.gamma * (sarg - p.sqrt_phi) + p.vto;

    // --- Gate overdrive ---
    const vgst = vgs_eff - vth;
    const vgst_pos = if (vgst > 0) vgst else @as(f64, 0.0);

    // --- Drain current (Shichman-Hodges) ---
    const vdsat = vgst_pos;
    const vds_ch = if (vds_eff < vdsat) vds_eff else vdsat;
    const id_val = p.beta * (vgst_pos - 0.5 * vds_ch) * vds_ch * (1.0 + p.lambda * vds_eff);
    const id_scaled = id_val * p.m_mult;

    // --- Bulk junction diode currents ---
    const vbd = vbs_raw - vds_raw;
    const vbs_junc = vbs_raw;

    const arg_bd = vbd / p.vt;
    const arg_bd_c = if (arg_bd < 80.0) arg_bd else @as(f64, 80.0);
    const i_bd = p.is_bd * (gpu_exp(arg_bd_c) - 1.0) + gmin * vbd;

    const arg_bs = vbs_junc / p.vt;
    const arg_bs_c = if (arg_bs < 80.0) arg_bs else @as(f64, 80.0);
    const i_bs = p.is_bs * (gpu_exp(arg_bs_c) - 1.0) + gmin * vbs_junc;

    const i_bd_s = i_bd * p.m_mult;
    const i_bs_s = i_bs * p.m_mult;

    // --- KCL terminal currents ---
    const i_dp = (mode * id_scaled - i_bd_s) * p.type_f;
    const i_sp = (-mode * id_scaled - i_bs_s) * p.type_f;
    const i_bulk = (i_bd_s + i_bs_s) * p.type_f;

    // --- Series resistances ---
    const i_rd = (v_drain - v_dp) * p.g_rd;
    const i_rs = (v_source - v_sp) * p.g_rs;

    // --- Stamp to rhs ---
    _ = @atomicRmw(f64, &rhs[rhs_idx[base6 + 0]], .Add, i_rd, .monotonic);
    _ = @atomicRmw(f64, &rhs[rhs_idx[base6 + 1]], .Add, 0.0, .monotonic); // gate: no DC current
    _ = @atomicRmw(f64, &rhs[rhs_idx[base6 + 2]], .Add, i_rs, .monotonic);
    _ = @atomicRmw(f64, &rhs[rhs_idx[base6 + 3]], .Add, i_bulk, .monotonic);
    _ = @atomicRmw(f64, &rhs[rhs_idx[base6 + 4]], .Add, i_dp - i_rd, .monotonic);
    _ = @atomicRmw(f64, &rhs[rhs_idx[base6 + 5]], .Add, i_sp - i_rs, .monotonic);

    // --- Conductance stamp (linearized derivatives) ---
    // For the conductance stamp, we compute the local derivatives numerically
    // via the relationship between current and voltage at this operating point.
    // The 18-entry g_pattern_override maps to the slots array.
    //
    // Series resistance stamps (exact):
    const base18 = 18 * id;
    // RD: drain--d_prime
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 0]], .Add, p.g_rd, .monotonic); // (drain,drain)
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 1]], .Add, -p.g_rd, .monotonic); // (drain,d_prime)
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 2]], .Add, -p.g_rd, .monotonic); // (d_prime,drain)
    // RS: source--s_prime
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 3]], .Add, p.g_rs, .monotonic); // (source,source)
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 4]], .Add, -p.g_rs, .monotonic); // (source,s_prime)
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 5]], .Add, -p.g_rs, .monotonic); // (s_prime,source)

    // Channel + junction conductances (linearized at operating point)
    // gds = d(id)/d(vds), gm = d(id)/d(vgs), gmbs = d(id)/d(vbs)
    var gds: f64 = 0;
    var gm: f64 = 0;
    var gmbs: f64 = 0;
    if (vgst > 0) {
        if (vds_eff < vdsat) {
            // Linear region
            gds = p.beta * p.m_mult * (vgst_pos - vds_eff) * (1.0 + p.lambda * vds_eff) + p.beta * p.m_mult * (vgst_pos - 0.5 * vds_eff) * vds_eff * p.lambda;
            gm = p.beta * p.m_mult * vds_eff * (1.0 + p.lambda * vds_eff);
        } else {
            // Saturation region
            gds = p.beta * p.m_mult * 0.5 * vgst_pos * vgst_pos * p.lambda;
            gm = p.beta * p.m_mult * vgst_pos * (1.0 + p.lambda * vds_eff);
        }
        // Body effect: gmbs = gm * gamma / (2 * sqrt(phi - vbs_eff))
        if (p.gamma > 0 and sarg > 1e-30) {
            gmbs = gm * p.gamma / (2.0 * sarg);
        }
    }

    // Junction conductances
    const gbd = p.is_bd / p.vt * gpu_exp(arg_bd_c) * p.m_mult + gmin * p.m_mult;
    const gbs = p.is_bs / p.vt * gpu_exp(arg_bs_c) * p.m_mult + gmin * p.m_mult;

    // Apply mode sign and type_f to get physical conductances
    const gds_p = gds * p.type_f * mode;
    const gm_p = gm * p.type_f * mode;
    const gmbs_p = gmbs * p.type_f * mode;

    // Stamp channel + junction into g_vals
    // (d_prime, d_prime) += gds + gbd
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 6]], .Add, p.g_rd + gds_p + gbd, .monotonic);
    // (d_prime, s_prime) += -gds
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 7]], .Add, -gds_p, .monotonic);
    // (s_prime, d_prime) += -gds
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 8]], .Add, -gds_p, .monotonic);
    // (s_prime, s_prime) += gds + gbs
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 9]], .Add, p.g_rs + gds_p + gbs, .monotonic);
    // (d_prime, gate) += gm
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 10]], .Add, gm_p, .monotonic);
    // (s_prime, gate) += -gm
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 11]], .Add, -gm_p, .monotonic);
    // (d_prime, bulk) += gmbs - gbd
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 12]], .Add, gmbs_p - gbd, .monotonic);
    // (s_prime, bulk) += -gmbs - gbs
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 13]], .Add, -gmbs_p - gbs, .monotonic);
    // (bulk, bulk) += gbd + gbs
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 14]], .Add, gbd + gbs, .monotonic);
    // (bulk, d_prime) += -gbd
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 15]], .Add, -gbd, .monotonic);
    // (bulk, s_prime) += -gbs
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 16]], .Add, -gbs, .monotonic);
    // (gate, gate) += 0 (no DC gate current)
    _ = @atomicRmw(f64, &g_vals[g_slots[base18 + 17]], .Add, 0.0, .monotonic);
}

comptime {
    @export(&evalMos1Impl, .{ .name = "eval_mos1" });
}
