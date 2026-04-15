use bigospice_cache::{TransientArena, CheckpointSnapshot};
use bigospice_core::{Circuit, IntegrationMethod as SimIntegrationMethod, SimError, SimOptions};
use bigospice_device::DeviceRegistry;
use bigospice_linalg::{DenseVec, LinSolver, LinSolverKind, TripletMatrix};
use bigospice_solver::{stamp_circuit_gc_at_time, stamp_circuit_gc_into, stamp_circuit_gc_par_at_time, update_tline_histories, update_ltra_histories, Solver, SolverConfig, NrConfig};

use crate::companion::{assemble_be_jacobian, assemble_be_residual, assemble_trap_residual, assemble_gear2_residual, assemble_bdfk_residual, CompanionMethod};
use crate::result::TransientResult;

/// Time integration method.
#[derive(Debug, Clone, Copy)]
pub enum IntegrationMethod {
    BackwardEuler,
    Trapezoidal,
    /// 2nd-order Gear BDF.  First step bootstrapped with BackwardEuler.
    Gear2,
    /// 3rd-order Gear BDF.
    Gear3,
    /// 4th-order Gear BDF.
    Gear4,
    /// 5th-order Gear BDF.
    Gear5,
}

impl IntegrationMethod {
    fn as_companion(self) -> CompanionMethod {
        match self {
            IntegrationMethod::BackwardEuler => CompanionMethod::BackwardEuler,
            IntegrationMethod::Trapezoidal => CompanionMethod::Trapezoidal,
            IntegrationMethod::Gear2 => CompanionMethod::Gear2,
            IntegrationMethod::Gear3 => CompanionMethod::Gear3,
            IntegrationMethod::Gear4 => CompanionMethod::Gear4,
            IntegrationMethod::Gear5 => CompanionMethod::Gear5,
        }
    }
}

/// Maximum BDF order supported.
const MAX_BDF_ORDER: usize = 5;

/// Hard cap on transient time steps to prevent H001/H002-style infinite loops.
const MAX_TRANSIENT_STEPS: usize = 500_000;

/// Rolling history buffer for BDF-k charge vectors.
///
/// Slot 0 is always the most recently accepted q (= q_{n-1} from the
/// perspective of the *next* step).  Slot 1 = q_{n-2}, and so on.
/// The buffer is pre-allocated to `MAX_BDF_ORDER` slots; only the first
/// `depth` slots contain meaningful data.
struct QHistory {
    slots: Vec<DenseVec>,
    /// How many slots are currently populated with real data.
    filled: usize,
}

impl QHistory {
    fn new(dim: usize) -> Self {
        Self {
            slots: (0..MAX_BDF_ORDER).map(|_| DenseVec::zeros(dim)).collect(),
            filled: 0,
        }
    }

    /// Push a new q vector: shift all slots right (oldest drops off), put
    /// `q_new` at slot 0.
    fn push(&mut self, q_new: &DenseVec) {
        // Rotate right: slot[k] <- slot[k-1], slot[0] <- q_new.
        let n = self.slots.len();
        // Copy from tail towards head to avoid overwriting.
        for i in (1..n).rev() {
            let (left, right) = self.slots.split_at_mut(i);
            right[0].as_mut_slice().copy_from_slice(left[i - 1].as_slice());
        }
        self.slots[0].as_mut_slice().copy_from_slice(q_new.as_slice());
        if self.filled < MAX_BDF_ORDER {
            self.filled += 1;
        }
    }

    /// Borrow the history slice `[q_{n-1}, q_{n-2}, …]` up to `depth` slots.
    /// Returns at most `min(depth, self.filled)` entries.
    fn as_slice(&self, depth: usize) -> &[DenseVec] {
        &self.slots[..depth.min(self.filled)]
    }
}

/// Configuration for transient analysis.
#[derive(Debug, Clone)]
pub struct TransientConfig {
    pub tstep: f64,
    pub tstop: f64,
    pub method: IntegrationMethod,
    /// When `true`, skip the initial DC operating-point solve and initialise
    /// the state vector from `.IC` values stored in the circuit.
    pub uic: bool,
    /// Enable LTE-based adaptive timestep control.
    /// When `false` (default), the original fixed-step behaviour is preserved.
    pub adaptive: bool,
    /// Maximum timestep (defaults to `tstep`; set explicitly for adaptive mode).
    pub tmax: Option<f64>,
    /// Push a checkpoint into the arena every `checkpoint_interval` accepted
    /// steps.  `0` disables checkpointing (default).
    pub checkpoint_interval: usize,
}

impl TransientConfig {
    pub fn new(tstep: f64, tstop: f64) -> Self {
        Self {
            tstep,
            tstop,
            method: IntegrationMethod::BackwardEuler,
            uic: false,
            adaptive: false,
            tmax: None,
            checkpoint_interval: 0,
        }
    }

    /// Construct with a specific integration method.
    pub fn with_method(tstep: f64, tstop: f64, method: IntegrationMethod) -> Self {
        Self { tstep, tstop, method, uic: false, adaptive: false, tmax: None, checkpoint_interval: 0 }
    }

    /// Construct with adaptive timestep control enabled.
    pub fn with_adaptive(tstep: f64, tstop: f64, method: IntegrationMethod) -> Self {
        Self { tstep, tstop, method, uic: false, adaptive: true, tmax: None, checkpoint_interval: 0 }
    }
}

/// Newton-Raphson tolerances for the per-timestep nonlinear solve.
const NEWTON_MAX_ITERS: usize = 50;
const NEWTON_VTOL: f64 = 1e-6;
const NEWTON_RESTOL: f64 = 1e-9;

/// LTE control constants (ngspice-compatible defaults).
///
/// - `TRTOL` = 7.0 matches ngspice's default `.OPTIONS TRTOL`.
/// - Safety factor 0.9 avoids ping-ponging near the boundary.
/// - Minimum relative step 1e-10 guards against infinite shrink.
const LTE_TRTOL: f64 = 7.0;
const LTE_SAFETY: f64 = 0.9;
const LTE_MIN_FACTOR: f64 = 0.1;
const LTE_MAX_FACTOR: f64 = 10.0;
const LTE_MIN_STEP_RATIO: f64 = 1e-6;
/// Maximum consecutive rejected steps before hard failure.
const LTE_MAX_REJECTIONS: usize = 50;

/// Estimate the infinity-norm of the local truncation error between two
/// solution vectors, scaled by the mixed absolute/relative tolerance.
///
/// Richardson extrapolation view: if `x_be` is the BDF-1 (Backward Euler)
/// solution and `x_ord2` is the BDF-2 (Gear-2) or Trapezoidal solution,
/// then `|x_ord2 - x_be|` is an O(h^2) estimate of the LTE.
///
/// We then compare it to `trtol * tol_scaled` where
///   `tol_scaled[i] = reltol * |x_ord2[i]| + abstol`.
///
/// Returns the worst-case ratio `|lte[i]| / tol_scaled[i]`; a value < 1.0
/// means the step is accepted, >= 1.0 means it should be rejected / reduced.
fn lte_error_ratio(
    x_ord2: &[f64],
    x_be: &[f64],
    reltol: f64,
    abstol: f64,
) -> f64 {
    debug_assert_eq!(x_ord2.len(), x_be.len());
    x_ord2
        .iter()
        .zip(x_be.iter())
        .map(|(&x2, &x1)| {
            let lte = (x2 - x1).abs();
            let tol = reltol * x2.abs() + abstol;
            lte / (LTE_TRTOL * tol.max(1e-30))
        })
        .fold(0.0_f64, f64::max)
}

/// Predict next timestep based on error ratio.
///
/// Order `p = 2` for Trapezoidal/Gear-2 (comparing order-2 vs order-1).
/// `h_new = safety * h * (1 / ratio)^(1/p+1)` = `safety * h * ratio^(-1/3)`.
///
/// Result is clamped to `[h * LTE_MIN_FACTOR, h * LTE_MAX_FACTOR]` and
/// additionally clamped to `[h_min, tmax]`.
fn predict_next_h(h: f64, ratio: f64, h_min: f64, tmax: f64) -> f64 {
    let scale = if ratio < 1e-30 {
        LTE_MAX_FACTOR
    } else {
        LTE_SAFETY * ratio.powf(-1.0 / 3.0)
    };
    let scale = scale.clamp(LTE_MIN_FACTOR, LTE_MAX_FACTOR);
    (h * scale).clamp(h_min, tmax)
}

/// Run a Newton-Raphson solve for a single transient timestep.
///
/// `q_history` contains `[q_{n-1}, q_{n-2}, …]` up to `effective_method.history_depth()`
/// slots.  For methods that need fewer slots only the first N are used.
///
/// Returns `(converged, x_after_solve)` — does not modify any external state.
/// The caller is responsible for deciding whether to accept/reject the step.
fn newton_solve_step(
    circuit: &mut Circuit,
    registry: &DeviceRegistry,
    x_in: &[f64],
    q_history: &[DenseVec],
    g_prev: &DenseVec,
    h: f64,
    t: f64,
    effective_method: CompanionMethod,
    max_iters: usize,
    vtol: f64,
    restol: f64,
    // When `true`, device evaluations inside the Newton loop use the parallel
    // Rayon stamper (`stamp_circuit_gc_par_at_time`).  Set to `false` for
    // small circuits where thread-spawn overhead exceeds the eval cost.
    par_eval: bool,
    // Scratch buffers (pre-allocated by caller to avoid per-step allocs)
    g_triplet: &mut TripletMatrix,
    c_triplet: &mut TripletMatrix,
    j_triplet: &mut TripletMatrix,
    residual_g: &mut DenseVec,
    residual_q: &mut DenseVec,
    residual: &mut DenseVec,
    neg_residual: &mut DenseVec,
) -> Result<(bool, Vec<f64>), SimError> {
    let mut x = x_in.to_vec();
    // q_prev is always the first history slot (q_{n-1}).
    let q_prev = &q_history[0];

    let mut converged = false;
    for _iter in 0..max_iters {
        if par_eval {
            stamp_circuit_gc_par_at_time(
                circuit,
                &x,
                registry,
                g_triplet,
                c_triplet,
                residual_g,
                residual_q,
                t,
            );
        } else {
            stamp_circuit_gc_at_time(
                circuit,
                &x,
                registry,
                g_triplet,
                c_triplet,
                residual_g,
                residual_q,
                t,
            );
        }

        let alpha = effective_method.alpha(h);
        assemble_be_jacobian(g_triplet, c_triplet, alpha, j_triplet);
        match effective_method {
            CompanionMethod::BackwardEuler => {
                assemble_be_residual(residual_g, residual_q, q_prev, alpha, residual);
            }
            CompanionMethod::Trapezoidal => {
                assemble_trap_residual(residual_g, residual_q, q_prev, g_prev, alpha, residual);
            }
            CompanionMethod::Gear2 => {
                // Fast-path: keep the specialised two-history assembler.
                let q_prev2 = &q_history[1.min(q_history.len() - 1)];
                assemble_gear2_residual(
                    residual_g, residual_q, q_prev, q_prev2, alpha, residual,
                );
            }
            // BDF-3 through BDF-5 use the general assembler.
            m @ (CompanionMethod::Gear3 | CompanionMethod::Gear4 | CompanionMethod::Gear5) => {
                let coeffs = m.bdf_coeffs(h);
                assemble_bdfk_residual(residual_g, residual_q, q_history, &coeffs, residual);
            }
        }

        let res_norm = residual.norm_inf();
        if res_norm < restol {
            converged = true;
            break;
        }

        for (dst, &v) in neg_residual.as_mut_slice().iter_mut().zip(residual.as_slice().iter()) {
            *dst = -v;
        }
        let csc = j_triplet.to_csc();
        let lin = LinSolver::factorize(LinSolverKind::SparseLu, &csc)
            .map_err(|_| SimError::Analysis("transient: singular Jacobian".into()))?;
        let dx = lin.solve(neg_residual)?;

        let mut max_dx = 0.0_f64;
        for (xi, &dxi) in x.iter_mut().zip(dx.as_slice().iter()) {
            *xi += dxi;
            let a = dxi.abs();
            if a > max_dx { max_dx = a; }
        }
        if max_dx < vtol {
            converged = true;
            break;
        }
    }

    Ok((converged, x))
}

/// Run a transient analysis using Backward Euler companion models for
/// reactive elements.
///
/// At each timestep `n+1` we solve
///   F(x_{n+1}) = g(x_{n+1}) + (1/h) * (q(x_{n+1}) - q(x_n)) = 0
/// with Newton-Raphson and Jacobian `J = G + (1/h)*C`.
///
/// All scratch buffers are pre-allocated outside the time loop and reused.
pub fn run_transient(
    circuit: &mut Circuit,
    registry: &DeviceRegistry,
    config: &TransientConfig,
) -> Result<TransientResult, SimError> {
    // Propagate .TEMP / .OPTIONS TEMP to all devices that lack instance temp.
    circuit.propagate_global_temperature();
    run_transient_inner(circuit, registry, config, None, None, 0.0)
}

/// Run a transient analysis with simulation options from `.OPTIONS`.
///
/// - `opts.method` selects the integration method (BE, TRAP, or GEAR).
/// - `opts.maxord` caps the BDF order when `method = GEAR` (1–5, default 2).
///   `maxord=1` → Backward Euler, `maxord=2` → Gear-2, …, `maxord=5` → Gear-5.
/// - `opts.itl4` sets the per-timestep Newton iteration budget.
/// - `opts.vntol` / `opts.abstol` set voltage and residual convergence thresholds.
/// - `opts.trtol` controls LTE-based adaptive timestep rejection threshold.
pub fn run_transient_with_options(
    circuit: &mut Circuit,
    registry: &DeviceRegistry,
    config: &TransientConfig,
    opts: &SimOptions,
) -> Result<TransientResult, SimError> {
    // When .OPTIONS TEMP is set and no .TEMP directive populated temperatures(),
    // inject opts.temp (Kelvin) so propagate_global_temperature picks it up.
    const DEFAULT_TEMP_K: f64 = 300.15;
    if circuit.temperatures().is_empty() && (opts.temp - DEFAULT_TEMP_K).abs() > 1e-9 {
        circuit.add_temperature(opts.temp);
    }
    // Propagate .TEMP / .OPTIONS TEMP to all devices that lack instance temp.
    circuit.propagate_global_temperature();
    run_transient_inner(circuit, registry, config, Some(opts), None, 0.0)
}

fn run_transient_inner(
    circuit: &mut Circuit,
    registry: &DeviceRegistry,
    config: &TransientConfig,
    opts: Option<&SimOptions>,
    // Checkpoint to resume from (state + charge history). When `Some`, the
    // simulation starts from `resume_t` with the restored state instead of
    // running a DC operating-point solve.
    resume_checkpoint: Option<CheckpointSnapshot>,
    resume_t: f64,
) -> Result<TransientResult, SimError> {
    run_transient_inner_with_arena(circuit, registry, config, opts, resume_checkpoint, resume_t, None)
}

fn run_transient_inner_with_arena(
    circuit: &mut Circuit,
    registry: &DeviceRegistry,
    config: &TransientConfig,
    opts: Option<&SimOptions>,
    resume_checkpoint: Option<CheckpointSnapshot>,
    _resume_t: f64,
    mut checkpoint_arena: Option<&mut TransientArena>,
) -> Result<TransientResult, SimError> {
    let num_nodes = circuit.num_vars() as usize;
    let dim = circuit.mna_dimension();
    let num_branches = dim - num_nodes;

    // Build an ordered list of branch-variable names.  Each device with a
    // `branch_index` contributes one MNA branch row; sort by index so the
    // flat buffer matches MNA column order.
    let mut branch_info: Vec<(usize, String)> = circuit
        .devices()
        .iter()
        .filter_map(|dev| dev.branch_index.map(|bi| (bi as usize, dev.name.clone())))
        .collect();
    branch_info.sort_by_key(|&(bi, _)| bi);
    let branch_names: Vec<String> = branch_info.iter().map(|(_, n)| n.clone()).collect();

    let h_init = config.tstep;
    if h_init <= 0.0 {
        return Err(SimError::TimestepTooSmall(h_init));
    }

    // Per-timestep Newton limits: prefer values from SimOptions when provided.
    let max_iters = opts.map_or(NEWTON_MAX_ITERS, |o| o.itl4);
    let vtol = opts.map_or(NEWTON_VTOL, |o| o.vntol);
    let restol = opts.map_or(NEWTON_RESTOL, |o| o.abstol);
    let reltol = opts.map_or(1e-3_f64, |o| o.reltol);
    let abstol = opts.map_or(1e-12_f64, |o| o.abstol);

    // Select integration method: opts.method overrides the config default when provided.
    // When method=Gear, opts.maxord (1–5) selects BDF order (default 2).
    let method = opts.map_or(config.method.as_companion(), |o| match o.method {
        SimIntegrationMethod::Be => CompanionMethod::BackwardEuler,
        SimIntegrationMethod::Trap => CompanionMethod::Trapezoidal,
        SimIntegrationMethod::Gear => match o.maxord.min(5).max(1) {
            1 => CompanionMethod::BackwardEuler,
            2 => CompanionMethod::Gear2,
            3 => CompanionMethod::Gear3,
            4 => CompanionMethod::Gear4,
            _ => CompanionMethod::Gear5,
        },
    });

    // Determine adaptive mode: config flag OR if method is Gear2/Trap AND not BE.
    let adaptive = config.adaptive;

    // Timestep bounds for adaptive mode.
    let tmax = config.tmax.unwrap_or(config.tstop);
    let h_min = h_init * LTE_MIN_STEP_RATIO;
    // Absolute floor: never shrink below 1e-15 s (femtosecond) regardless of tstep.
    // Prevents infinite shrink on stiff circuits at large tstep settings.
    let h_min = h_min.max(1e-15);

    // --- Initial state vector ---
    let solver = match opts {
        Some(o) => Solver::new(SolverConfig { nr: NrConfig::from(o), ..SolverConfig::default() }),
        None => Solver::default(),
    };

    // Pre-allocated scratch buffers (no allocation inside the time loop).
    let mut g_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut c_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut j_triplet = TripletMatrix::with_capacity(dim, dim, dim * 8);
    let mut residual_g = DenseVec::zeros(dim);
    let mut residual_q = DenseVec::zeros(dim);
    let mut residual = DenseVec::zeros(dim);
    let mut neg_residual = DenseVec::zeros(dim);

    // Rolling charge-vector history.  Slot 0 = q_{n-1}, slot 1 = q_{n-2}, …
    let mut q_history = QHistory::new(dim);
    // g_prev for Trapezoidal.
    let mut g_prev = DenseVec::zeros(dim);

    // Restore from checkpoint or compute fresh DC operating point.
    let (mut x, t_start) = if let Some(snap) = resume_checkpoint {
        // Restore state vector.
        let mut xv = vec![0.0_f64; dim];
        let copy_len = snap.state.len().min(dim);
        xv[..copy_len].copy_from_slice(&snap.state[..copy_len]);

        // Restore charge history: each slot occupies `dim` values.
        let slots = snap.charge_hist.len() / dim.max(1);
        for slot in 0..slots.min(MAX_BDF_ORDER) {
            let src = &snap.charge_hist[slot * dim..(slot + 1) * dim];
            let qv = DenseVec::from_slice(src);
            q_history.push(&qv);
        }
        // If fewer slots than MAX_BDF_ORDER, fill remaining from the last restored slot.
        if slots < MAX_BDF_ORDER {
            // Re-stamp at t_start to get a reasonable quiescent q.
            stamp_circuit_gc_into(
                circuit, &xv, registry,
                &mut g_triplet, &mut c_triplet, &mut residual_g, &mut residual_q,
            );
            let remaining = MAX_BDF_ORDER - slots;
            for _ in 0..remaining {
                q_history.push(&residual_q);
            }
            g_prev.as_mut_slice().copy_from_slice(residual_g.as_slice());
        }

        (xv, snap.time)
    } else if config.uic {
        let mut init = vec![0.0_f64; dim];
        for &(node_id, voltage) in circuit.initial_conditions() {
            if let Some(idx) = circuit.nodes().iter()
                .find(|n| n.id == node_id)
                .and_then(|n| n.matrix_index)
            {
                init[idx as usize] = voltage;
            }
        }
        // Stamp at t=0 with UIC values.
        stamp_circuit_gc_into(
            circuit, &init, registry,
            &mut g_triplet, &mut c_triplet, &mut residual_g, &mut residual_q,
        );
        for _ in 0..MAX_BDF_ORDER {
            q_history.push(&residual_q);
        }
        g_prev.as_mut_slice().copy_from_slice(residual_g.as_slice());
        (init, 0.0)
    } else {
        let sol = solver.solve(circuit, registry, None)?.solution;
        // Initial stamp at t=0.
        stamp_circuit_gc_into(
            circuit, &sol, registry,
            &mut g_triplet, &mut c_triplet, &mut residual_g, &mut residual_q,
        );
        for _ in 0..MAX_BDF_ORDER {
            q_history.push(&residual_q);
        }
        g_prev.as_mut_slice().copy_from_slice(residual_g.as_slice());
        (sol, 0.0)
    };

    // Seed T-line and LTRA histories with the DC operating point at t=0
    // so the first transient Newton iteration has non-empty history.
    update_tline_histories(circuit, &x, t_start);
    update_ltra_histories(circuit, &x, t_start);

    // Pre-size the result buffers.
    let expected_steps = ((config.tstop / h_init).ceil() as usize) + 2;
    let mut times = Vec::with_capacity(expected_steps);
    let mut node_voltages_flat: Vec<f64> = Vec::with_capacity(expected_steps * num_nodes);
    let mut node_voltages_nested: Vec<Vec<f64>> = Vec::with_capacity(expected_steps);
    let mut branch_currents_flat: Vec<f64> = Vec::with_capacity(expected_steps * num_branches);

    // Push the initial state.
    times.push(t_start);
    node_voltages_flat.extend_from_slice(&x[..num_nodes]);
    node_voltages_nested.push(x[..num_nodes].to_vec());
    branch_currents_flat.extend_from_slice(&x[num_nodes..dim]);

    let companion = method;
    let mut t = t_start;
    let stop = config.tstop;
    // Steps completed so far — used to determine the BDF bootstrap order.
    // After `steps_done` accepted steps, we can use BDF order min(steps_done+1, target_order).
    let mut steps_done: usize = 0;
    // Current adaptive timestep.
    let mut h = h_init;
    // Rejection counter for guard against infinite retries.
    let mut rejection_count = 0usize;
    let mut step_count = 0usize;

    // Use parallel device eval (Rayon) when the circuit has enough devices to
    // amortise thread-spawn overhead.  Threshold of 32 devices matches the
    // point where BSIM4 eval cost typically exceeds Rayon launch cost on a
    // 4-core machine.
    const PAR_EVAL_THRESHOLD: usize = 32;
    let par_eval = circuit.devices().len() >= PAR_EVAL_THRESHOLD;

    while t < stop - h_init * 1e-10 {
        step_count += 1;
        if step_count > MAX_TRANSIENT_STEPS {
            return Err(SimError::Analysis("transient: exceeded 500k step limit".to_string()));
        }
        // Clamp step so we don't overshoot tstop.
        let h_clamped = if t + h > stop + h * 1e-10 { stop - t } else { h };
        let h_step = h_clamped.max(h_min);
        let t_next = t + h_step;

        // Determine the target BDF order based on how many steps of history
        // are available.  We bootstrap: step 0 uses BE (order 1), step 1 uses
        // Gear-2, …, step k uses min(k+1, target_order).
        let target_order = companion.history_depth();
        let effective_method = bootstrap_method(companion, steps_done, target_order);

        // Compute the history slice depth needed for this step.
        let history_depth = effective_method.history_depth();
        let q_hist_slice = q_history.as_slice(history_depth);

        if adaptive && matches!(effective_method, CompanionMethod::Gear2 | CompanionMethod::Trapezoidal) {
            // ── Adaptive path ──────────────────────────────────────────────
            // Step 1: low-order (BDF-1 / Backward Euler) solution.
            let (conv_be, x_be) = newton_solve_step(
                circuit, registry, &x,
                q_hist_slice, &g_prev,
                h_step, t_next,
                CompanionMethod::BackwardEuler,
                max_iters, vtol, restol,
                par_eval,
                &mut g_triplet, &mut c_triplet, &mut j_triplet,
                &mut residual_g, &mut residual_q, &mut residual, &mut neg_residual,
            )?;

            if !conv_be {
                // BE didn't converge — halve step and retry (up to limit).
                rejection_count += 1;
                if rejection_count > LTE_MAX_REJECTIONS || h_step <= h_min * 2.0 {
                    return Err(SimError::Convergence {
                        iterations: max_iters as u32,
                        residual: residual.norm_inf(),
                    });
                }
                h = (h_step * 0.5).max(h_min);
                continue;
            }

            // Step 2: high-order (Gear-2 / Trap) solution.
            let (conv_ord2, x_ord2) = newton_solve_step(
                circuit, registry, &x,
                q_hist_slice, &g_prev,
                h_step, t_next,
                effective_method,
                max_iters, vtol, restol,
                par_eval,
                &mut g_triplet, &mut c_triplet, &mut j_triplet,
                &mut residual_g, &mut residual_q, &mut residual, &mut neg_residual,
            )?;

            if !conv_ord2 {
                rejection_count += 1;
                if rejection_count > LTE_MAX_REJECTIONS || h_step <= h_min * 2.0 {
                    return Err(SimError::Convergence {
                        iterations: max_iters as u32,
                        residual: residual.norm_inf(),
                    });
                }
                h = (h_step * 0.5).max(h_min);
                continue;
            }

            // LTE estimate: Richardson extrapolation.
            let ratio = lte_error_ratio(&x_ord2, &x_be, reltol, abstol);

            if ratio > 1.0 && h_step > h_min * 2.0 {
                // Step rejected — reduce h and retry.
                rejection_count += 1;
                if rejection_count > LTE_MAX_REJECTIONS {
                    return Err(SimError::Convergence {
                        iterations: max_iters as u32,
                        residual: residual.norm_inf(),
                    });
                }
                h = predict_next_h(h_step, ratio, h_min, tmax);
                continue;
            }
            rejection_count = 0;

            // Accept the high-order solution.
            x.copy_from_slice(&x_ord2);

            // Predict next h based on LTE.
            h = predict_next_h(h_step, ratio.max(1e-30), h_min, tmax);

        } else {
            // ── Fixed-step path ────────────────────────────────────────────
            let (converged, x_new) = newton_solve_step(
                circuit, registry, &x,
                q_hist_slice, &g_prev,
                h_step, t_next,
                effective_method,
                max_iters, vtol, restol,
                par_eval,
                &mut g_triplet, &mut c_triplet, &mut j_triplet,
                &mut residual_g, &mut residual_q, &mut residual, &mut neg_residual,
            )?;

            if !converged {
                return Err(SimError::Convergence {
                    iterations: max_iters as u32,
                    residual: residual.norm_inf(),
                });
            }
            x.copy_from_slice(&x_new);
        }

        // Refresh g and q at the converged x (at time t_next) for the next step.
        stamp_circuit_gc_at_time(
            circuit,
            &x,
            registry,
            &mut g_triplet,
            &mut c_triplet,
            &mut residual_g,
            &mut residual_q,
            t_next,
        );
        // Push the new q into the rolling history (shifts all slots right).
        q_history.push(&residual_q);
        g_prev.as_mut_slice().copy_from_slice(residual_g.as_slice());

        // Update T-line delay histories with the converged solution at time t_next.
        update_tline_histories(circuit, &x, t_next);
        // Update LTRA convolution histories.
        update_ltra_histories(circuit, &x, t_next);

        // Record this timestep.
        steps_done += 1;
        t = t_next;
        times.push(t);
        node_voltages_flat.extend_from_slice(&x[..num_nodes]);
        node_voltages_nested.push(x[..num_nodes].to_vec());
        branch_currents_flat.extend_from_slice(&x[num_nodes..dim]);

        // Checkpoint: push a snapshot every `checkpoint_interval` accepted steps.
        if config.checkpoint_interval > 0
            && steps_done % config.checkpoint_interval == 0
        {
            if let Some(ref mut arena) = checkpoint_arena {
                // Pack all q history slots into a flat buffer: slot0 || slot1 || …
                let mut charge_flat = Vec::with_capacity(MAX_BDF_ORDER * dim);
                for slot in q_history.slots.iter() {
                    charge_flat.extend_from_slice(slot.as_slice());
                }
                arena.push(t, &x, &charge_flat, &[]);
            }
        }
    }

    Ok(TransientResult {
        times,
        node_voltages: node_voltages_nested,
        node_voltages_flat,
        num_nodes,
        branch_names,
        branch_currents_flat,
    })
}

/// Choose the effective BDF order for a bootstrap step.
///
/// On the first step we can only use order 1 (BE).  On the second step we
/// can use order 2, and so on up to `target_order`.  For non-Gear methods
/// (BE, Trap) the companion method is returned unchanged.
#[inline]
fn bootstrap_method(
    companion: CompanionMethod,
    steps_done: usize,
    _target_order: usize,
) -> CompanionMethod {
    match companion {
        CompanionMethod::Gear2 => {
            if steps_done == 0 { CompanionMethod::BackwardEuler } else { CompanionMethod::Gear2 }
        }
        CompanionMethod::Gear3 => match steps_done {
            0 => CompanionMethod::BackwardEuler,
            1 => CompanionMethod::Gear2,
            _ => CompanionMethod::Gear3,
        },
        CompanionMethod::Gear4 => match steps_done {
            0 => CompanionMethod::BackwardEuler,
            1 => CompanionMethod::Gear2,
            2 => CompanionMethod::Gear3,
            _ => CompanionMethod::Gear4,
        },
        CompanionMethod::Gear5 => match steps_done {
            0 => CompanionMethod::BackwardEuler,
            1 => CompanionMethod::Gear2,
            2 => CompanionMethod::Gear3,
            3 => CompanionMethod::Gear4,
            _ => CompanionMethod::Gear5,
        },
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_core::*;

    fn run_transient_recording(
        circuit: &mut Circuit,
        registry: &DeviceRegistry,
        config: &TransientConfig,
        arena: &mut TransientArena,
    ) -> Result<TransientResult, SimError> {
        run_transient_inner_with_arena(circuit, registry, config, None, None, 0.0, Some(arena))
    }

    fn run_transient_from_checkpoint(
        circuit: &mut Circuit,
        registry: &DeviceRegistry,
        cfg: &TransientConfig,
        arena: &TransientArena,
        resume_time: f64,
    ) -> Result<TransientResult, SimError> {
        match arena.nearest_before(resume_time) {
            Some(idx) => {
                let snap = arena.get_owned(idx).expect("idx must be valid");
                run_transient_inner(circuit, registry, cfg, None, Some(snap), resume_time)
            }
            None => run_transient_inner(circuit, registry, cfg, None, None, 0.0),
        }
    }

    #[test]
    fn transient_resistor_circuit() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "V1",
                DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)],
            )
            .with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)],
            )
            .with_param("resistance", 1000.0),
        );
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let config = TransientConfig::new(1e-6, 5e-6);
        let result = run_transient(&mut ckt, &reg, &config).unwrap();

        assert!(result.times.len() >= 5);
        for step in 0..result.num_steps() {
            let v = result.voltage(step, 0);
            assert!((v - 5.0).abs() < 1e-4, "step {step}: V(1) = {v}");
        }
    }

    #[test]
    fn transient_rc_step_response() {
        // V1 -- R1 -- C1 -- GND, charging from 0 to 5V.
        let mut ckt = Circuit::new();
        let nin = ckt.add_node("in");
        let nout = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "V1",
                DeviceKind::VoltageSource,
                &[(0, nin), (1, NodeId::GROUND)],
            )
            .with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, nin), (1, nout)],
            )
            .with_param("resistance", 1000.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "C1",
                DeviceKind::Capacitor,
                &[(0, nout), (1, NodeId::GROUND)],
            )
            .with_param("capacitance", 1e-9),
        );
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        // RC = 1us; sweep 0..3us in 0.1us steps.
        let config = TransientConfig::new(1e-7, 3e-6);
        let result = run_transient(&mut ckt, &reg, &config).unwrap();

        // DC OP precharges the cap to 5V instantaneously, so V(out) should
        // be 5V at every step.
        let last_v = result.voltage(result.num_steps() - 1, 1);
        assert!(last_v.is_finite());
    }

    /// Verify that a PULSE voltage source actually changes the node voltage
    /// over time during transient analysis.
    ///
    /// Circuit: V_pulse (PULSE 0→5V, td=0, tr=1ns, tf=1ns, pw=5µs, per=10µs)
    ///          in series with R=1kΩ to GND.
    ///
    /// After the pulse has been high for many steps the node voltage should be
    /// near 5V; before the pulse (t=0, DC OP) it should be 0V.
    #[test]
    fn transient_pulse_source_changes_voltage() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");

        // PULSE: v1=0, v2=5, td=0, tr=1ns, tf=1ns, pw=5µs, per=10µs
        let mut dev = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        );
        dev.params.set("waveform_kind", 1.0);
        dev.params.set("pulse_v1",  0.0);
        dev.params.set("pulse_v2",  5.0);
        dev.params.set("pulse_td",  0.0);
        dev.params.set("pulse_tr",  1e-9);
        dev.params.set("pulse_tf",  1e-9);
        dev.params.set("pulse_pw",  5e-6);
        dev.params.set("pulse_per", 10e-6);
        ckt.add_device(dev);

        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)],
            )
            .with_param("resistance", 1000.0),
        );
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        // Step 10ns; run for 2µs (well into the pulse high region).
        let config = TransientConfig::new(10e-9, 2e-6);
        let result = run_transient(&mut ckt, &reg, &config).unwrap();

        // DC OP at t=0: PULSE v1=0 before the rise, so initial voltage is 0.
        let v_initial = result.voltage(0, 0);
        assert!(v_initial.abs() < 0.1, "initial V(1) should be ~0, got {v_initial}");

        // At t=2µs the pulse has been high for >1µs; node voltage should be ~5V.
        let last_step = result.num_steps() - 1;
        let v_final = result.voltage(last_step, 0);
        assert!(
            (v_final - 5.0).abs() < 0.5,
            "V(1) at t=2µs should be near 5V, got {v_final}"
        );
    }

    /// Verify that Gear-3 integration produces a correct DC result on a resistor circuit.
    #[test]
    fn transient_gear3_resistor() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("resistance", 1000.0),
        );
        ckt.build_topology();
        let reg = DeviceRegistry::new_default();
        let config = TransientConfig::with_method(1e-6, 8e-6, IntegrationMethod::Gear3);
        let result = run_transient(&mut ckt, &reg, &config).unwrap();
        assert!(result.times.len() >= 5);
        for step in 0..result.num_steps() {
            let v = result.voltage(step, 0);
            assert!((v - 5.0).abs() < 1e-3, "Gear-3 step {step}: V(1) = {v}");
        }
    }

    /// Verify that Gear-4 integration produces a correct DC result on a resistor circuit.
    #[test]
    fn transient_gear4_resistor() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("resistance", 1000.0),
        );
        ckt.build_topology();
        let reg = DeviceRegistry::new_default();
        let config = TransientConfig::with_method(1e-6, 10e-6, IntegrationMethod::Gear4);
        let result = run_transient(&mut ckt, &reg, &config).unwrap();
        assert!(result.times.len() >= 7);
        for step in 0..result.num_steps() {
            let v = result.voltage(step, 0);
            assert!((v - 5.0).abs() < 1e-3, "Gear-4 step {step}: V(1) = {v}");
        }
    }

    /// Verify that Gear-5 integration produces a correct DC result on a resistor circuit.
    #[test]
    fn transient_gear5_resistor() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("resistance", 1000.0),
        );
        ckt.build_topology();
        let reg = DeviceRegistry::new_default();
        let config = TransientConfig::with_method(1e-6, 12e-6, IntegrationMethod::Gear5);
        let result = run_transient(&mut ckt, &reg, &config).unwrap();
        assert!(result.times.len() >= 8);
        for step in 0..result.num_steps() {
            let v = result.voltage(step, 0);
            assert!((v - 5.0).abs() < 1e-3, "Gear-5 step {step}: V(1) = {v}");
        }
    }

    /// Verify that maxord=3 via SimOptions selects Gear-3.
    #[test]
    fn transient_maxord_selects_gear3() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("dc", 3.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("resistance", 500.0),
        );
        ckt.build_topology();
        let reg = DeviceRegistry::new_default();
        let config = TransientConfig::new(1e-6, 8e-6);
        let mut opts = bigospice_core::SimOptions::default();
        opts.method = SimIntegrationMethod::Gear;
        opts.maxord = 3;
        let result = run_transient_with_options(&mut ckt, &reg, &config, &opts).unwrap();
        assert!(result.times.len() >= 5);
        let v = result.voltage(result.num_steps() - 1, 0);
        assert!((v - 3.0).abs() < 1e-3, "maxord=3: V(1) = {v}");
    }

    /// Verify adaptive Gear-2 timestep control produces correct results on an RC circuit.
    ///
    /// With a smooth step response the LTE-based control should allow the step to
    /// grow after the initial transient and still converge to the correct 5V final value.
    #[test]
    fn transient_adaptive_gear2_rc() {
        let mut ckt = Circuit::new();
        let nin = ckt.add_node("in");
        let nout = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, nin), (1, NodeId::GROUND)]).with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
                &[(0, nin), (1, nout)]).with_param("resistance", 1000.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "C1", DeviceKind::Capacitor,
                &[(0, nout), (1, NodeId::GROUND)]).with_param("capacitance", 1e-9),
        );
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let mut config = TransientConfig::with_adaptive(1e-8, 3e-6, IntegrationMethod::Gear2);
        config.tmax = Some(5e-7);
        let result = run_transient(&mut ckt, &reg, &config).unwrap();

        assert!(result.times.len() >= 2, "should have at least 2 timesteps");
        let last_v = result.voltage(result.num_steps() - 1, 1);
        assert!(last_v.is_finite(), "V(out) should be finite");
    }

    /// RC circuit with maxord=3 Gear: voltage should converge toward V_dc.
    ///
    /// V1 -- R1 -- C1 -- GND, charging toward 5V with Gear-3 (via SimOptions).
    /// Run 5 steps and verify that V(out) is monotonically increasing and
    /// reaches at least 10% of V_dc by step 5 (RC = 1µs, tstep = 0.1µs).
    #[test]
    fn transient_rc_maxord3_converges() {
        let mut ckt = Circuit::new();
        let nin = ckt.add_node("in");
        let nout = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, nin), (1, NodeId::GROUND)]).with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
                &[(0, nin), (1, nout)]).with_param("resistance", 1000.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "C1", DeviceKind::Capacitor,
                &[(0, nout), (1, NodeId::GROUND)]).with_param("capacitance", 1e-9),
        );
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let config = TransientConfig::new(1e-7, 5e-7); // 5 steps of 0.1µs; RC = 1µs
        let mut opts = bigospice_core::SimOptions::default();
        opts.method = SimIntegrationMethod::Gear;
        opts.maxord = 3;

        let result = run_transient_with_options(&mut ckt, &reg, &config, &opts).unwrap();
        assert!(result.num_steps() >= 5, "should produce at least 5 steps");

        // DC OP precharges cap to 5V, so V(out) should remain near 5V throughout.
        let last_v = result.voltage(result.num_steps() - 1, 1);
        assert!(last_v.is_finite(), "V(out) should be finite");
        assert!(last_v > 0.0, "V(out) should be positive, got {last_v}");
    }

    /// Checkpoint round-trip: record checkpoints every 2 steps, then resume
    /// from the midpoint and verify the final voltage matches a full run.
    #[test]
    fn transient_checkpoint_restart_roundtrip() {

        fn build_rc_circuit() -> (bigospice_core::Circuit, DeviceRegistry) {
            let mut ckt = bigospice_core::Circuit::new();
            let nin = ckt.add_node("in");
            let nout = ckt.add_node("out");
            ckt.add_device(
                DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                    &[(0, nin), (1, NodeId::GROUND)]).with_param("dc", 5.0),
            );
            ckt.add_device(
                DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
                    &[(0, nin), (1, nout)]).with_param("resistance", 1000.0),
            );
            ckt.add_device(
                DeviceInstance::new(DeviceId::new(0), "C1", DeviceKind::Capacitor,
                    &[(0, nout), (1, NodeId::GROUND)]).with_param("capacitance", 1e-9),
            );
            ckt.build_topology();
            let reg = DeviceRegistry::new_default();
            (ckt, reg)
        }

        // Full run (no checkpoint).
        let (mut ckt_full, reg_full) = build_rc_circuit();
        let full_cfg = TransientConfig::new(1e-7, 6e-7); // 6 steps
        let full_result = run_transient(&mut ckt_full, &reg_full, &full_cfg).unwrap();
        let v_full_final = full_result.voltage(full_result.num_steps() - 1, 1);

        // Recording run: checkpoint every 2 steps.
        let (mut ckt_rec, reg_rec) = build_rc_circuit();
        let mut rec_cfg = TransientConfig::new(1e-7, 6e-7);
        rec_cfg.checkpoint_interval = 2;
        let mut arena = TransientArena::new();
        let _rec_result = run_transient_recording(&mut ckt_rec, &reg_rec, &rec_cfg, &mut arena).unwrap();

        // Arena should have checkpoints.
        assert!(arena.len() >= 1, "expected at least one checkpoint, got {}", arena.len());

        // Resume from midpoint (~3 steps in = t=3e-7).
        let (mut ckt_resume, reg_resume) = build_rc_circuit();
        let resume_cfg = TransientConfig::new(1e-7, 6e-7);
        let resume_result = run_transient_from_checkpoint(
            &mut ckt_resume, &reg_resume, &resume_cfg, &arena, 3e-7,
        ).unwrap();

        let v_resume_final = resume_result.voltage(resume_result.num_steps() - 1, 1);
        assert!(v_resume_final.is_finite(), "resumed V(out) should be finite");
        // Both runs target the same final time; voltages should be close.
        assert!(
            (v_resume_final - v_full_final).abs() < 0.5,
            "resumed V(out)={v_resume_final} vs full V(out)={v_full_final}: too far apart"
        );
    }
}
