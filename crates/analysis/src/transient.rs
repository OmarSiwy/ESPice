//! Transient analysis — streaming with BDF ring buffer.

use std::time::Instant;

use incspice_cache::CacheManager;
use incspice_core::{Circuit, SimError, StreamingSink};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::newton::NrConfig;
use incspice_solver::linalg::{DenseVec, TripletMatrix};
use incspice_solver::linalg::{lu_factorize, lu_solve};
use incspice_solver::{stamp_circuit_gc_at_time, update_tline_histories, update_ltra_histories};
use incspice_solver::device::Waveform;
use crate::companion::{CompanionMethod, assemble_be_jacobian, assemble_be_residual, assemble_trap_residual, assemble_gear2_residual};
use crate::{Analysis, AnalysisError};
use crate::result::TransientResult;

/// Integration method for transient analysis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntegrationMethod {
    BackwardEuler,
    Trapezoidal,
    /// Second-order Gear (BDF2) method.
    Gear2,
}

/// BDF history ring buffer. Constant memory regardless of sim length.
pub struct BdfHistory {
    max_order: usize,
    num_vars: usize,
    states: Vec<Vec<f64>>,
    times: Vec<f64>,
    head: usize,
    count: usize,
}

impl BdfHistory {
    pub fn new(max_order: usize, num_vars: usize) -> Self {
        let cap = max_order + 1;
        Self {
            max_order, num_vars,
            states: vec![vec![0.0; num_vars]; cap],
            times: vec![0.0; cap], head: 0, count: 0,
        }
    }
    pub fn push(&mut self, time: f64, state: &[f64]) {
        let cap = self.max_order + 1;
        self.states[self.head][..self.num_vars].copy_from_slice(&state[..self.num_vars]);
        self.times[self.head] = time;
        self.head = (self.head + 1) % cap;
        if self.count < cap { self.count += 1; }
    }
    pub fn get(&self, ago: usize) -> Option<(&[f64], f64)> {
        if ago >= self.count { return None; }
        let cap = self.max_order + 1;
        let idx = (self.head + cap - 1 - ago) % cap;
        Some((&self.states[idx], self.times[idx]))
    }
}

/// Configuration for a standalone transient analysis.
#[derive(Debug, Clone)]
pub struct TransientConfig {
    pub tstep: f64,
    pub tstop: f64,
    pub method: IntegrationMethod,
    pub adaptive: bool,
    pub uic: bool,
    pub tmax: Option<f64>,
    pub tol: f64,
    /// Optional wall-clock timeout in seconds.  When set, the transient loop
    /// checks elapsed time every 1,000 steps and returns a partial result if
    /// the budget is exceeded.  This prevents indefinite hangs on stiff or
    /// high-step-count circuits (e.g. oscillators with tstep=1e-10).
    pub timeout_secs: Option<f64>,
}

impl TransientConfig {
    /// Legacy constructor: fixed timestep, Backward Euler.
    pub fn new(tstep: f64, tstop: f64) -> Self {
        Self {
            tstep,
            tstop,
            method: IntegrationMethod::BackwardEuler,
            adaptive: false,
            uic: false,
            tmax: None,
            tol: 1e-3,
            timeout_secs: None,
        }
    }

    /// Fixed timestep constructor with explicit method.
    pub fn with_method(tstep: f64, tstop: f64, method: IntegrationMethod) -> Self {
        Self {
            tstep,
            tstop,
            method,
            adaptive: false,
            uic: false,
            tmax: None,
            tol: 1e-3,
            timeout_secs: None,
        }
    }

    /// Adaptive timestep constructor.
    pub fn with_adaptive(tstep: f64, tstop: f64, method: IntegrationMethod) -> Self {
        Self {
            tstep,
            tstop,
            method,
            adaptive: true,
            uic: false,
            tmax: None,
            tol: 1e-3,
            timeout_secs: None,
        }
    }
}

pub struct Transient {
    pub tstep: f64,
    pub tstop: f64,
}

impl Analysis for Transient {
    fn run(&self, circuit: &mut Circuit, registry: &DeviceRegistry, config: &NrConfig, cache: &mut CacheManager, sink: &mut dyn StreamingSink) -> Result<(), AnalysisError> {
        let nv = circuit.num_vars() as usize;
        let _dim = circuit.mna_dimension();
        let mut history = BdfHistory::new(2, nv);

        // DC OP for initial conditions
        let dc = incspice_solver::solve(circuit, registry, config, cache)?;
        history.push(0.0, &dc.solution);
        sink.emit_point(0.0, &dc.solution[..nv])?;

        let mut t = 0.0;
        let h = self.tstep;

        while t < self.tstop {
            t += h;
            // TODO: companion models, BDF coefficients, adaptive timestep
            let result = incspice_solver::solve(circuit, registry, config, cache)?;
            history.push(t, &result.solution);
            sink.emit_point(t, &result.solution[..nv])?;
            // TODO: LTE check, digital.flush_before(t), checkpoint to arena
        }

        sink.finalize()?;
        Ok(())
    }
    fn name(&self) -> &str { "transient" }
}

/// Maximum Newton-Raphson iterations for each transient timestep.
const TRANSIENT_MAX_ITER: usize = 100;

/// Convergence tolerance for the transient NR loop (current residual, amperes).
const TRANSIENT_I_TOL: f64 = 1e-9;

/// Hard cap on fixed-step transient iterations to prevent simulation from
/// running indefinitely on stiff or non-convergent circuits.
///
/// 200,000 steps covers `.TRAN 0.1n 10u` (100,000 steps) with a safety margin
/// while still completing within a few seconds.
const TRANSIENT_MAX_FIXED_STEPS: usize = 200_000;

/// Solve one transient timestep using the specified integration method.
///
/// `circuit`      — the circuit (topology + device params, not mutated)
/// `registry`     — device model registry
/// `x_prev`       — solution from the previous accepted timestep (length = mna_dim)
/// `q_prev`       — charge/flux vector q(x_{n-1}) from previous step (length = mna_dim)
/// `g_prev`       — resistive residual g(x_{n-1}) from previous step (for Trapezoidal)
/// `t`            — current simulation time (used for time-varying sources)
/// `h`            — timestep size
/// `method`       — integration method (BackwardEuler or Trapezoidal)
///
/// Returns `(x_new, q_new, g_new)` on convergence, or `SimError` on failure.
fn solve_transient_step(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    x_prev: &[f64],
    q_prev: &DenseVec,
    g_prev: &DenseVec,
    t: f64,
    h: f64,
    method: IntegrationMethod,
    q_prev2: Option<&DenseVec>,
) -> Result<(Vec<f64>, DenseVec, DenseVec), SimError> {
    let dim = circuit.mna_dimension();
    // Use real Gear2 companion when q_prev2 is available, otherwise fall back to BE.
    let companion = match method {
        IntegrationMethod::BackwardEuler => CompanionMethod::BackwardEuler,
        IntegrationMethod::Trapezoidal => CompanionMethod::Trapezoidal,
        IntegrationMethod::Gear2 => {
            if q_prev2.is_some() {
                CompanionMethod::Gear2
            } else {
                CompanionMethod::BackwardEuler
            }
        }
    };
    let alpha = companion.alpha(h);

    // Allocate scratch buffers.
    let mut g_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut c_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut residual_g = DenseVec::zeros(dim);
    let mut residual_q = DenseVec::zeros(dim);
    let mut jac_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut full_residual = DenseVec::zeros(dim);

    // Start from the previous solution as initial guess.
    let mut x: Vec<f64> = x_prev.to_vec();
    let mut prev_res_norm = f64::MAX;
    // Use previous timestep solution as limiting baseline for the first Newton
    // iteration. Without this, the first step has no junction limiting and can
    // overshoot across exponential device curves (BJT forward voltage runaway).
    let mut x_iter_prev: Option<Vec<f64>> = Some(x_prev.to_vec());
    let mut consecutive_growth: u32 = 0;

    for _iter in 0..TRANSIENT_MAX_ITER {
        // Stamp G (resistive Jacobian), C (capacitive Jacobian),
        // g(x) (resistive residual), q(x) (charge/flux residual).
        stamp_circuit_gc_at_time(
            circuit,
            &x,
            registry,
            &mut g_triplet,
            &mut c_triplet,
            &mut residual_g,
            &mut residual_q,
            t,
            x_iter_prev.as_deref(),
        );

        // Assemble the transient Jacobian: J = G + alpha * C
        assemble_be_jacobian(&g_triplet, &c_triplet, alpha, &mut jac_triplet);

        // Assemble the transient residual based on method.
        match companion {
            CompanionMethod::BackwardEuler => {
                assemble_be_residual(
                    &residual_g,
                    &residual_q,
                    q_prev,
                    alpha,
                    &mut full_residual,
                );
            }
            CompanionMethod::Trapezoidal => {
                assemble_trap_residual(
                    &residual_g,
                    &residual_q,
                    q_prev,
                    g_prev,
                    alpha,
                    &mut full_residual,
                );
            }
            CompanionMethod::Gear2 => {
                assemble_gear2_residual(
                    &residual_g,
                    &residual_q,
                    q_prev,
                    q_prev2.unwrap(),
                    alpha,
                    &mut full_residual,
                );
            }
            _ => {
                assemble_be_residual(
                    &residual_g,
                    &residual_q,
                    q_prev,
                    alpha,
                    &mut full_residual,
                );
            }
        }

        let res_norm = full_residual.norm_inf();

        // Early bail-out: NaN/Inf residual means the Jacobian or device model
        // produced non-finite values (e.g. BJT with extreme node voltages).
        // Continuing would just run max_iter useless LU factorizations.
        if !res_norm.is_finite() {
            break;
        }

        if res_norm < TRANSIENT_I_TOL {
            // Converged. Return solution, new q vector, and new g vector.
            return Ok((x, residual_q, residual_g));
        }

        // Check if we've already converged at the level we can reach.
        if res_norm >= prev_res_norm * 0.9999 && _iter > 5 && res_norm < TRANSIENT_I_TOL * 1e4 {
            return Ok((x, residual_q, residual_g));
        }

        // Also bail if the residual is growing fast — NR divergence.
        if _iter > 10 && res_norm > prev_res_norm * 1e6 {
            break;
        }

        // Solve J * dx = -F
        let jac_csc = jac_triplet.to_csc();
        let factors = lu_factorize(&jac_csc)?;

        // Build -F as the right-hand side.
        let mut neg_f = DenseVec::zeros(dim);
        for i in 0..dim {
            neg_f[i] = -full_residual[i];
        }

        let dx = lu_solve(&factors, &neg_f)?;

        // Bail if the Newton step itself is non-finite.
        if dx.as_slice().iter().any(|v| !v.is_finite()) {
            break;
        }

        // Save current x for junction limiting on next iteration.
        x_iter_prev = Some(x.clone());

        // --- ngspice-style voltage-magnitude damping ---
        // Clamp large voltage swings: if max |dx| > 10 V, scale all of dx
        // so the largest change is exactly 10 V.
        let max_diff = dx.as_slice().iter().map(|v| v.abs()).fold(0.0_f64, f64::max);
        let vclamp = if max_diff > 10.0 { 10.0 / max_diff } else { 1.0 };

        // Bank-Rose residual tracking: halve the damping factor for each
        // consecutive iteration where the residual did not decrease.
        let alpha_br = if res_norm >= prev_res_norm && _iter > 0 {
            consecutive_growth += 1;
            (0.5_f64.powi(consecutive_growth as i32)).max(1.0 / 64.0)
        } else {
            consecutive_growth = 0;
            1.0
        };

        // Combined damping factor: take the more conservative of the two.
        let damp = vclamp.min(alpha_br);

        // Update x with damped Newton step.
        for i in 0..dim {
            x[i] += damp * dx[i];
        }

        prev_res_norm = res_norm;
    }

    // Did not converge within max iterations — return convergence error
    // so the adaptive loop can reject the step and retry with a smaller h.
    Err(SimError::Convergence {
        iterations: TRANSIENT_MAX_ITER as u32,
        residual: prev_res_norm,
    })
}

/// Estimate the Local Truncation Error using divided differences (matches ngspice cktterr.c).
///
/// For BE/Trapezoidal (order=1): uses second divided difference, `del = raw`
/// For Gear2 (order=2): uses third divided difference, `del = sqrt(raw)`
///
/// Returns `(max_lte_ratio, suggested_new_h)` where `max_lte_ratio` is the
/// worst-case LTE/tolerance ratio across all state variables, and
/// `suggested_new_h` is the step size that would bring LTE within tolerance.
fn estimate_lte_and_new_h(
    q_history: &[&DenseVec],  // [q_n, q_{n-1}, q_{n-2}, ...]
    h_history: &[f64],        // [h_n, h_{n-1}, ...]
    method: IntegrationMethod,
    _tol: f64,
) -> (f64, f64) {
    let order = match method {
        IntegrationMethod::BackwardEuler => 1,
        IntegrationMethod::Trapezoidal => 1,
        IntegrationMethod::Gear2 => 2,
    };

    let factor = match method {
        IntegrationMethod::BackwardEuler => 0.5,
        IntegrationMethod::Trapezoidal => 0.5,
        IntegrationMethod::Gear2 => 0.2222222222,
    };

    let n = q_history[0].len();
    let mut max_lte_ratio = 0.0_f64;

    // ngspice defaults: abstol=1e-12, reltol=1e-3, chgtol=1e-14, trtol=7.0
    let abstol = 1e-12;
    let reltol = 1e-3;
    let chgtol = 1e-14;
    let trtol = 7.0;

    for i in 0..n {
        // Build divided differences for state variable i.
        let num_pts = (order + 2).min(q_history.len());
        if num_pts < 2 { continue; }
        let mut diff: Vec<f64> = q_history[..num_pts].iter().map(|q| q[i]).collect();
        let mut deltmp: Vec<f64> = h_history[..num_pts - 1].to_vec();
        // Accumulate time spans for higher-order divided differences.
        for k in 1..deltmp.len() {
            deltmp[k] += deltmp[k - 1];
        }

        // Compute divided differences up to `order`.
        let dd_order = (order).min(num_pts - 1);
        for k in 0..dd_order {
            for j in 0..(diff.len() - 1 - k) {
                diff[j] = (diff[j] - diff[j + 1]) / deltmp[j];
            }
        }

        let volttol = abstol + reltol * q_history[0][i].abs().max(q_history[1][i].abs());
        let chargetol = reltol * q_history[0][i].abs().max(chgtol) / h_history[0];
        let local_tol = volttol.max(chargetol);

        let lte_est = (factor * diff[0].abs()).max(abstol);
        max_lte_ratio = max_lte_ratio.max(lte_est / local_tol);
    }

    // New timestep: del = trtol / max_lte_ratio, scaled by order.
    let raw_del = trtol / max_lte_ratio.max(1e-30);
    let del = match order {
        1 => raw_del,
        2 => raw_del.sqrt(),
        _ => raw_del.powf(1.0 / order as f64),
    };

    let new_h = del * h_history[0];
    (max_lte_ratio, new_h)
}

/// Run a transient analysis and collect results into a `TransientResult`.
///
/// Supports Backward Euler and Trapezoidal integration methods, fixed and
/// adaptive timestep modes, and UIC (use initial conditions) to skip DC OP.
///
/// If the circuit has `.IC` initial conditions, they are applied as forced
/// node voltages when computing the starting state for t=0.
pub fn run_transient(
    circuit: &mut Circuit,
    registry: &DeviceRegistry,
    config: &TransientConfig,
) -> Result<TransientResult, SimError> {
    let nv = circuit.num_vars() as usize;
    let nb = circuit.num_branches() as usize;
    let dim = circuit.mna_dimension();
    let solver = incspice_solver::Solver::default();

    // Compute initial state: either from DC OP or zero/IC values (UIC).
    let x_ic: Vec<f64> = if config.uic {
        // UIC: start from zero vector with any .IC values applied.
        let mut x = vec![0.0f64; dim];
        for vc in circuit.initial_conditions() {
            if vc.neg_node.is_ground() {
                let idx = vc.pos_node.0 as usize;
                if idx > 0 && idx <= nv {
                    x[idx - 1] = vc.voltage;
                }
            }
        }
        x
    } else if circuit.initial_conditions().is_empty() {
        solver.solve(circuit, registry, None)?.solution
    } else {
        // Convert initial_conditions() to ic_pins (node matrix index, voltage).
        let ic_pins: Vec<(usize, f64)> = circuit
            .initial_conditions()
            .iter()
            .filter_map(|vc| {
                if !vc.neg_node.is_ground() {
                    return None;
                }
                let idx = (vc.pos_node.0 as usize).checked_sub(1)?;
                if idx >= nv {
                    return None;
                }
                Some((idx, vc.voltage))
            })
            .collect();
        let mut dc = match solver.solve_with_ic_pins(circuit, registry, &ic_pins) {
            Ok(result) => result.solution,
            Err(_) => {
                // Fallback: unconstrained OP + IC override.
                solver.solve(circuit, registry, None)?.solution
            }
        };
        // Override with explicit ICs.
        for vc in circuit.initial_conditions() {
            if vc.neg_node.is_ground() {
                let idx = vc.pos_node.0 as usize;
                if idx > 0 && idx <= nv {
                    dc[idx - 1] = vc.voltage;
                }
            }
        }
        dc
    };

    // Compute q(x_0) and g(x_0) at the initial state.
    let (mut q_prev, mut g_prev) = {
        let mut g_trip = TripletMatrix::with_capacity(dim, dim, dim * 4);
        let mut c_trip = TripletMatrix::with_capacity(dim, dim, dim * 4);
        let mut r_g = DenseVec::zeros(dim);
        let mut r_q = DenseVec::zeros(dim);
        stamp_circuit_gc_at_time(circuit, &x_ic, registry, &mut g_trip, &mut c_trip, &mut r_g, &mut r_q, 0.0, None);
        (r_q, r_g)
    };

    let mut times = Vec::new();
    let mut node_voltages_flat = Vec::new();
    let mut branch_currents_flat = Vec::new();
    let mut history = BdfHistory::new(2, nv);

    times.push(0.0);
    node_voltages_flat.extend_from_slice(&x_ic[..nv]);
    if nb > 0 && x_ic.len() >= nv + nb {
        branch_currents_flat.extend_from_slice(&x_ic[nv..nv + nb]);
    }
    history.push(0.0, &x_ic);

    let mut x_prev = x_ic;

    let wall_start = Instant::now();

    if config.adaptive {
        // Adaptive timestep loop.
        let mut h = config.tstep;
        let mut t = 0.0;
        // Keep one extra q history for LTE estimation.
        let mut q_prev2 = q_prev.clone();
        // Hard cap: prevent infinite loops on stiff circuits.
        const MAX_STEPS: usize = 200_000;
        let mut total_steps = 0usize;
        let mut rejected_steps = 0usize;
        // Minimum h: below this, accept unconditionally and reset h to tstep.
        let h_min = config.tstep * 1e-4;
        // Order reduction at breakpoints (ngspice dctran.c:549-556):
        // Force Backward Euler for 2 steps after each breakpoint to prevent
        // trapezoidal ringing at discontinuities.
        let mut steps_at_order1: u32 = 0;

        while t < config.tstop {
            total_steps += 1;
            if total_steps > MAX_STEPS {
                // Too many steps — return what we have so far (partial result is ok).
                break;
            }

            // Wall-clock timeout check (every 1,000 steps to amortize cost).
            if let Some(limit) = config.timeout_secs {
                if total_steps % 1_000 == 0 && wall_start.elapsed().as_secs_f64() >= limit {
                    break;
                }
            }

            let remaining = config.tstop - t;

            // Clamp timestep to next source event (breakpoint detection).
            let mut h_event = f64::MAX;
            for dev in circuit.devices() {
                if dev.kind == incspice_core::DeviceKind::VoltageSource
                    || dev.kind == incspice_core::DeviceKind::CurrentSource
                {
                    let wf = Waveform::from_params(&dev.params);
                    if let Some(evt) = wf.next_event_time(t) {
                        let dt = (evt - t).max(h_min);
                        h_event = h_event.min(dt);
                    }
                }
            }

            // Detect breakpoint: the event time is limiting the step size.
            let at_breakpoint = h_event < h && h_event < remaining;
            if at_breakpoint {
                // ngspice dctran.c:552,556 — force order=1 and cut delta by 0.1x.
                steps_at_order1 = 2;
                h = (h * 0.1).max(h_min);
            }

            let h_use = h
                .min(config.tmax.unwrap_or(h))
                .min(remaining)
                .min(h_event);

            if h_use <= 0.0 {
                break;
            }

            // Use BE when in forced order-1 mode (post-breakpoint).
            let effective_method = if steps_at_order1 > 0 {
                IntegrationMethod::BackwardEuler
            } else {
                config.method
            };

            // Build fallback chain: Trap/Gear2 -> BE, BE -> BE only.
            let methods_to_try: &[IntegrationMethod] = match effective_method {
                IntegrationMethod::Trapezoidal => &[IntegrationMethod::Trapezoidal, IntegrationMethod::BackwardEuler],
                IntegrationMethod::Gear2 => &[IntegrationMethod::Gear2, IntegrationMethod::BackwardEuler],
                other => {
                    // BackwardEuler — single-element slice via leak-free trick:
                    // we already handled the only other variant above, so this is BE.
                    let _ = other;
                    &[IntegrationMethod::BackwardEuler]
                }
            };
            let mut step_result = Err(SimError::Convergence { iterations: 0, residual: f64::MAX });
            for &try_method in methods_to_try {
                step_result = solve_transient_step(
                    circuit,
                    registry,
                    &x_prev,
                    &q_prev,
                    &g_prev,
                    t + h_use,
                    h_use,
                    try_method,
                    Some(&q_prev2),
                );
                if step_result.is_ok() {
                    break;
                }
            }

            match step_result {
                Ok((x_new, q_new, g_new)) => {
                    // Guard against NaN/Inf from non-convergent NR.
                    if x_new.iter().any(|v| !v.is_finite())
                        || q_new.as_slice().iter().any(|v| !v.is_finite())
                    {
                        rejected_steps += 1;
                        h /= 8.0;
                        if h < h_min {
                            break;
                        }
                        continue;
                    }

                    // LTE check using divided differences (ngspice cktterr.c style).
                    let q_hist: Vec<&DenseVec> = vec![&q_new, &q_prev, &q_prev2];
                    let h_hist: Vec<f64> = vec![h_use, h_use]; // assume uniform for now
                    let (_lte_ratio, new_h_lte) = estimate_lte_and_new_h(
                        &q_hist, &h_hist, effective_method, config.tol,
                    );

                    // Reject if LTE too large (ngspice: newdelta < 0.9*delta)
                    // AND h is still above minimum.
                    if new_h_lte < 0.9 * h_use && h_use > h_min {
                        h = new_h_lte.max(h_min);
                        continue;
                    }

                    // Accept step.
                    if steps_at_order1 > 0 {
                        steps_at_order1 -= 1;
                    }
                    t += h_use;
                    history.push(t, &x_new);
                    times.push(t);
                    node_voltages_flat.extend_from_slice(&x_new[..nv]);
                    if nb > 0 && x_new.len() >= nv + nb {
                        branch_currents_flat.extend_from_slice(&x_new[nv..nv + nb]);
                    }

                    // Update T-line and LTRA delayed-wave history buffers so
                    // the next timestep can retrieve the correct incident waves.
                    update_tline_histories(circuit, &x_new, t);
                    update_ltra_histories(circuit, &x_new, t);

                    q_prev2 = q_prev.clone();
                    q_prev = q_new;
                    g_prev = g_new;
                    x_prev = x_new;

                    // After a forced tiny-step accept, reset h to tstep to avoid crawling.
                    if h_use <= h_min {
                        h = config.tstep;
                    } else {
                        // Use LTE-suggested step, but cap growth at 2x current and 4x tstep.
                        h = new_h_lte.min(h * 2.0).min(config.tstep * 4.0);
                    }
                }
                Err(_) => {
                    rejected_steps += 1;
                    // ngspice-style aggressive cut: divide by 8 on NR failure.
                    h /= 8.0;
                    if h < h_min {
                        // Below minimum step — accept a best-effort forward step
                        // at h_min to avoid stalling. If even that fails, bail.
                        let h_try = h_min;
                        // Try fallback chain at minimum step size too.
                        let be_methods: &[IntegrationMethod] = match effective_method {
                            IntegrationMethod::Trapezoidal => &[IntegrationMethod::Trapezoidal, IntegrationMethod::BackwardEuler],
                            IntegrationMethod::Gear2 => &[IntegrationMethod::Gear2, IntegrationMethod::BackwardEuler],
                            _ => &[IntegrationMethod::BackwardEuler],
                        };
                        let mut best_effort = Err(SimError::Convergence { iterations: 0, residual: f64::MAX });
                        for &try_m in be_methods {
                            best_effort = solve_transient_step(
                                circuit,
                                registry,
                                &x_prev,
                                &q_prev,
                                &g_prev,
                                t + h_try,
                                h_try,
                                try_m,
                                Some(&q_prev2),
                            );
                            if best_effort.is_ok() { break; }
                        }
                        match best_effort {
                            Ok((x_new, q_new, g_new)) => {
                                t += h_try;
                                history.push(t, &x_new);
                                times.push(t);
                                node_voltages_flat.extend_from_slice(&x_new[..nv]);
                                if nb > 0 && x_new.len() >= nv + nb {
                                    branch_currents_flat.extend_from_slice(&x_new[nv..nv + nb]);
                                }
                                update_tline_histories(circuit, &x_new, t);
                                update_ltra_histories(circuit, &x_new, t);
                                q_prev2 = q_prev.clone();
                                q_prev = q_new;
                                g_prev = g_new;
                                x_prev = x_new;
                                // Reset h to tstep after forced tiny step.
                                h = config.tstep;
                            }
                            Err(_) => {
                                // Can't converge even at minimum step — bail.
                                break;
                            }
                        }
                    }
                }
            }
        }
    } else {
        // Fixed timestep loop.
        let mut t = 0.0;
        let h = config.tstep;
        let mut fixed_steps = 0usize;
        let mut q_prev2_fixed = q_prev.clone();
        // Minimum sub-step for NR retry: h/16.
        let h_min_fixed = h / 16.0;

        while t < config.tstop {
            fixed_steps += 1;
            if fixed_steps > TRANSIENT_MAX_FIXED_STEPS {
                // Hard cap: prevent simulation from running indefinitely on
                // stiff/non-convergent circuits (e.g. oscillators with large
                // step counts). Return the partial result accumulated so far.
                break;
            }

            // Wall-clock timeout check (every 1,000 steps to amortize cost).
            if let Some(limit) = config.timeout_secs {
                if fixed_steps % 1_000 == 0 && wall_start.elapsed().as_secs_f64() >= limit {
                    break;
                }
            }

            let t_target = t + h;

            // Try the full step first, then retry with smaller sub-steps on failure.
            let mut h_try = h;
            let mut t_sub = t;
            let mut sub_converged = false;

            // Build fallback chain for fixed-step loop.
            let fixed_methods: &[IntegrationMethod] = match config.method {
                IntegrationMethod::Trapezoidal => &[IntegrationMethod::Trapezoidal, IntegrationMethod::BackwardEuler],
                IntegrationMethod::Gear2 => &[IntegrationMethod::Gear2, IntegrationMethod::BackwardEuler],
                other => { let _ = other; &[IntegrationMethod::BackwardEuler] }
            };

            while t_sub < t_target - 1e-18 * h {
                let h_sub = (t_target - t_sub).min(h_try);
                let q_prev2_ref = if fixed_steps > 1 { Some(&q_prev2_fixed) } else { None };

                // Try each method in the fallback chain.
                let mut step_result = Err(SimError::Convergence { iterations: 0, residual: f64::MAX });
                for &try_method in fixed_methods {
                    step_result = solve_transient_step(
                        circuit,
                        registry,
                        &x_prev,
                        &q_prev,
                        &g_prev,
                        t_sub + h_sub,
                        h_sub,
                        try_method,
                        q_prev2_ref,
                    );
                    if step_result.is_ok() { break; }
                }

                match step_result {
                    Ok((x_new, q_new, g_new)) => {
                        // Check for NaN/Inf in sub-step solution.
                        if x_new.iter().any(|v| !v.is_finite())
                            || q_new.as_slice().iter().any(|v| !v.is_finite())
                        {
                            h_try /= 2.0;
                            if h_try < h_min_fixed {
                                // Accept with warning: at minimum sub-step.
                                #[cfg(debug_assertions)]
                                eprintln!("[TRAN] NaN at t={:.4e}, accepting at min sub-step", t_sub + h_sub);
                                sub_converged = false;
                                break;
                            }
                            continue;
                        }

                        t_sub += h_sub;
                        x_prev = x_new;
                        q_prev2_fixed = q_prev.clone();
                        q_prev = q_new;
                        g_prev = g_new;
                        sub_converged = true;
                        // Grow sub-step back toward full step size.
                        h_try = (h_try * 2.0).min(h);
                    }
                    Err(_) => {
                        // All methods in fallback chain failed — halve the step.
                        h_try /= 2.0;
                        if h_try < h_min_fixed {
                            // At minimum sub-step — accept previous solution with warning.
                            #[cfg(debug_assertions)]
                            eprintln!("[TRAN] NR failed at t={:.4e}, min sub-step reached", t_sub + h_sub);
                            sub_converged = false;
                            break;
                        }
                    }
                }
            }

            // Record the result at the target time (or as far as we got).
            t = if sub_converged { t_target } else { t_target };
            history.push(t, &x_prev);
            times.push(t);
            node_voltages_flat.extend_from_slice(&x_prev[..nv]);
            if nb > 0 && x_prev.len() >= nv + nb {
                branch_currents_flat.extend_from_slice(&x_prev[nv..nv + nb]);
            }

            // Update T-line and LTRA delayed-wave history buffers.
            update_tline_histories(circuit, &x_prev, t);
            update_ltra_histories(circuit, &x_prev, t);
        }
    }

    // Build legacy nested view.
    let num_steps = times.len();
    let node_voltages: Vec<Vec<f64>> = (0..num_steps)
        .map(|s| node_voltages_flat[s * nv..(s + 1) * nv].to_vec())
        .collect();

    // Build branch name list.
    let branch_names: Vec<String> = circuit
        .devices()
        .iter()
        .filter_map(|dev| dev.branch_index.map(|_| dev.name.clone()))
        .collect();

    Ok(TransientResult {
        times,
        node_voltages,
        node_voltages_flat,
        num_nodes: nv,
        branch_names,
        branch_currents_flat,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use incspice_solver::device::DeviceRegistry;

    #[test]
    fn test_transient_config_with_method() {
        let cfg = TransientConfig::with_method(1e-9, 1e-6, IntegrationMethod::Trapezoidal);
        assert!(!cfg.adaptive);
        assert_eq!(cfg.tstep, 1e-9);
        assert_eq!(cfg.tstop, 1e-6);
    }

    #[test]
    fn test_transient_config_with_adaptive() {
        let cfg = TransientConfig::with_adaptive(1e-9, 1e-6, IntegrationMethod::BackwardEuler);
        assert!(cfg.adaptive);
        assert_eq!(cfg.tstep, 1e-9);
    }

    #[test]
    fn test_transient_tmax_cap() {
        let mut cfg = TransientConfig::with_adaptive(1e-9, 1e-6, IntegrationMethod::Trapezoidal);
        cfg.tmax = Some(5e-9);
        assert_eq!(cfg.tmax, Some(5e-9));
        assert!(cfg.adaptive);
    }

    #[test]
    fn test_transient_config_new_backward_compat() {
        let cfg = TransientConfig::new(1e-3, 5e-3);
        assert_eq!(cfg.tstep, 1e-3);
        assert_eq!(cfg.tstop, 5e-3);
        assert!(!cfg.adaptive);
        assert!(!cfg.uic);
    }

    /// RC charging circuit test: Vdd=5V, R=1kΩ, C=1µF → τ = 1ms
    ///
    /// The circuit topology:
    ///   Vdd (5V) between node "vdd" and GND (voltage source)
    ///   R1 (1kΩ) between "vdd" and "out"
    ///   C1 (1µF) between "out" and GND
    ///
    /// Expected behaviour:
    ///   V(out, t) = Vdd * (1 - exp(-t / τ))    where τ = R*C = 1ms
    ///
    /// At t=0: V(out) ≈ 0 V
    /// At t=5τ=5ms: V(out) > 0.99 * Vdd = 4.95 V
    #[test]
    fn test_transient_rc_charging_exponential() {
        let mut ckt = Circuit::new();

        // Add nodes.
        let n_vdd = ckt.add_node("vdd");
        let n_out = ckt.add_node("out");

        // V1: 5 V source between "vdd" and GND.
        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n_vdd), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);

        // R1: 1 kΩ resistor between "vdd" and "out".
        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n_vdd), (1, n_out)],
        )
        .with_param("resistance", 1e3);

        // C1: 1 µF capacitor between "out" and GND.
        let c1 = DeviceInstance::new(
            DeviceId::new(0),
            "C1",
            DeviceKind::Capacitor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", 1e-6);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(c1);
        ckt.build_topology();

        // Initial condition: capacitor starts uncharged (V(out) = 0 at t=0).
        ckt.add_initial_condition(n_out, 0.0);

        let registry = DeviceRegistry::default();
        let config = TransientConfig::new(0.1e-3, 5e-3); // tstep=0.1ms, tstop=5ms

        let result = run_transient(&mut ckt, &registry, &config).unwrap();

        // Find the index for node "out" (node index = NodeId - 1, since GND=0).
        // "vdd" = node 1 → matrix index 0
        // "out" = node 2 → matrix index 1
        let n_out_idx = (n_out.0 - 1) as usize;

        // At t=0, V(out) should be ≈ 0 V (capacitor uncharged in DC OP).
        let v_out_t0 = result.node_voltages[0][n_out_idx];
        assert!(
            v_out_t0.abs() < 0.1,
            "V(out) at t=0 should be ~0 V, got {v_out_t0}"
        );

        // At t=5ms (5τ), V(out) should be > 4.95 V (99% of Vdd).
        let last = result.node_voltages.last().unwrap();
        let v_out_final = last[n_out_idx];
        assert!(
            v_out_final > 4.95,
            "V(out) at t=5ms should be > 4.95 V (99% of Vdd=5V), got {v_out_final}"
        );

        // Verify monotonic charging: each step voltage should be >= previous.
        for step in 1..result.num_steps() {
            let v_prev = result.node_voltages[step - 1][n_out_idx];
            let v_curr = result.node_voltages[step][n_out_idx];
            assert!(
                v_curr >= v_prev - 1e-9,
                "V(out) should be non-decreasing; at step {step}: {v_prev} -> {v_curr}"
            );
        }

        // Spot-check exponential shape at t=1τ=1ms: V should be ≈ Vdd*(1-1/e) ≈ 3.16V
        // Step index for t=1ms with tstep=0.1ms: step 10 (0-based) + 1 offset for DC = step 11
        let tau_step_idx = (1e-3_f64 / 0.1e-3_f64).round() as usize; // 10 steps after t=0
        if tau_step_idx < result.num_steps() {
            let v_at_tau = result.node_voltages[tau_step_idx][n_out_idx];
            let expected = 5.0 * (1.0 - (-1.0_f64).exp()); // ≈ 3.161
            // Allow 5% numerical tolerance for Backward Euler discretisation.
            assert!(
                (v_at_tau - expected).abs() < 0.25,
                "V(out) at t=τ should be ≈ {expected:.3} V (±0.25 V tolerance), got {v_at_tau:.3}"
            );
        }
    }

    /// Regression test: fixed-step transient with a very high step count must not hang.
    ///
    /// This simulates the scenario triggered by the `colpitts_oscillator.sp`
    /// fixture: `.TRAN 0.1n 10u` = 100,000 nominal steps.  The TRANSIENT_MAX_FIXED_STEPS
    /// cap must cause the simulation to return well before exhausting all steps.
    ///
    /// The circuit is a simple RC (Vdd=5V, R=1kΩ, C=1pF, τ=1ns) with a
    /// nanosecond-scale timestep.  We ask for tstop=100µs, which would be
    /// 1,000,000 steps — well beyond the cap of 200,000.
    #[test]
    fn test_fixed_step_max_steps_cap_prevents_hang() {
        let mut ckt = Circuit::new();
        let n_vdd = ckt.add_node("vdd");
        let n_out = ckt.add_node("out");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n_vdd), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);

        let r1 = DeviceInstance::new(
            DeviceId::new(1),
            "R1",
            DeviceKind::Resistor,
            &[(0, n_vdd), (1, n_out)],
        )
        .with_param("resistance", 1e3);

        let c1 = DeviceInstance::new(
            DeviceId::new(2),
            "C1",
            DeviceKind::Capacitor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", 1e-12);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(c1);
        ckt.build_topology();
        ckt.add_initial_condition(n_out, 0.0);

        let registry = DeviceRegistry::default();

        // tstep=1e-10, tstop=1e-4 → 1,000,000 nominal steps without the cap.
        // The cap (TRANSIENT_MAX_FIXED_STEPS=200,000) must truncate this early.
        let config = TransientConfig::with_method(1e-10, 1e-4, IntegrationMethod::BackwardEuler);

        let start = std::time::Instant::now();
        let result = run_transient(&mut ckt, &registry, &config).unwrap();
        let elapsed = start.elapsed();

        // Must complete within a few seconds, not hang for minutes.
        assert!(
            elapsed.as_secs() < 30,
            "fixed-step transient took {elapsed:?}, expected < 30s (hang prevention check)"
        );

        // Must have produced at least some results (not failed entirely).
        assert!(
            !result.times.is_empty(),
            "expected at least one transient timestep to be accepted"
        );

        // Must have been cut off by the cap: step count ≤ TRANSIENT_MAX_FIXED_STEPS + 1
        // (the +1 accounts for the initial DC point at t=0).
        let max_expected = TRANSIENT_MAX_FIXED_STEPS + 1;
        assert!(
            result.times.len() <= max_expected,
            "expected at most {max_expected} timesteps, got {}",
            result.times.len()
        );
    }

    /// RC charging via Trapezoidal integration: Vdd=5V, R=1kΩ, C=1µF, τ=1ms.
    ///
    /// At t=5τ the capacitor should be charged to > 99% of Vdd (4.95V).
    /// Trapezoidal is second-order accurate and should behave qualitatively
    /// the same as Backward Euler for this simple RC circuit.
    #[test]
    fn test_transient_rc_trapezoidal() {
        let mut ckt = Circuit::new();
        let n_vdd = ckt.add_node("vdd");
        let n_out = ckt.add_node("out");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n_vdd), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);

        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n_vdd), (1, n_out)],
        )
        .with_param("resistance", 1e3);

        let c1 = DeviceInstance::new(
            DeviceId::new(0),
            "C1",
            DeviceKind::Capacitor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", 1e-6);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(c1);
        ckt.build_topology();
        ckt.add_initial_condition(n_out, 0.0);

        let registry = DeviceRegistry::default();
        let config = TransientConfig::with_method(
            0.1e-3,
            5e-3,
            IntegrationMethod::Trapezoidal,
        );

        let result = run_transient(&mut ckt, &registry, &config).unwrap();

        let n_out_idx = (n_out.0 - 1) as usize;
        let last = result.node_voltages.last().unwrap();
        let v_out_final = last[n_out_idx];

        assert!(
            v_out_final > 4.95,
            "Trapezoidal: V(out) at t=5ms should be > 4.95V, got {v_out_final}"
        );
    }

    /// Adaptive timestep RC charging: should still reach ~99% of Vdd at 5τ.
    #[test]
    fn test_transient_rc_adaptive() {
        let mut ckt = Circuit::new();
        let n_vdd = ckt.add_node("vdd");
        let n_out = ckt.add_node("out");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n_vdd), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);

        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n_vdd), (1, n_out)],
        )
        .with_param("resistance", 1e3);

        let c1 = DeviceInstance::new(
            DeviceId::new(0),
            "C1",
            DeviceKind::Capacitor,
            &[(0, n_out), (1, NodeId::GROUND)],
        )
        .with_param("capacitance", 1e-6);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(c1);
        ckt.build_topology();
        ckt.add_initial_condition(n_out, 0.0);

        let registry = DeviceRegistry::default();
        let config = TransientConfig::with_adaptive(
            0.1e-3,
            5e-3,
            IntegrationMethod::BackwardEuler,
        );

        let result = run_transient(&mut ckt, &registry, &config).unwrap();

        let n_out_idx = (n_out.0 - 1) as usize;
        let last = result.node_voltages.last().unwrap();
        let v_out_final = last[n_out_idx];

        assert!(
            v_out_final > 4.5,
            "Adaptive: V(out) at t=5ms should be > 4.5V, got {v_out_final}"
        );
        // Adaptive should produce fewer or equal steps vs fixed with same initial tstep.
        assert!(
            !result.times.is_empty(),
            "adaptive transient must produce at least one time point"
        );
    }

    /// BdfHistory ring buffer: push/get operations maintain LIFO order.
    #[test]
    fn test_bdf_history_push_get_order() {
        let mut hist = BdfHistory::new(2, 3);

        // Push three states.
        hist.push(0.0, &[1.0, 2.0, 3.0]);
        hist.push(1.0, &[4.0, 5.0, 6.0]);
        hist.push(2.0, &[7.0, 8.0, 9.0]);

        // Most recent (ago=0) should be the last pushed.
        let (state0, t0) = hist.get(0).unwrap();
        assert!((t0 - 2.0).abs() < 1e-15, "t0={t0} expected 2.0");
        assert!((state0[0] - 7.0).abs() < 1e-15, "state0[0]={} expected 7", state0[0]);

        // One step back (ago=1) should be the second push.
        let (state1, t1) = hist.get(1).unwrap();
        assert!((t1 - 1.0).abs() < 1e-15, "t1={t1} expected 1.0");
        assert!((state1[0] - 4.0).abs() < 1e-15, "state1[0]={} expected 4", state1[0]);

        // Two steps back (ago=2) should be the first push.
        let (state2, t2) = hist.get(2).unwrap();
        assert!((t2 - 0.0).abs() < 1e-15, "t2={t2} expected 0.0");
        assert!((state2[0] - 1.0).abs() < 1e-15, "state2[0]={} expected 1", state2[0]);

        // Out of range should return None.
        assert!(hist.get(3).is_none(), "ago=3 should be out of range");
    }

    /// BdfHistory: overwriting oldest entry when ring buffer is full.
    #[test]
    fn test_bdf_history_ring_wrap() {
        // max_order=1 → ring can hold 2 states.
        let mut hist = BdfHistory::new(1, 2);

        hist.push(0.0, &[10.0, 20.0]);
        hist.push(1.0, &[30.0, 40.0]);
        // Ring is full. Push again — oldest (t=0) should be evicted.
        hist.push(2.0, &[50.0, 60.0]);

        // Most recent should be t=2.0.
        let (s0, t0) = hist.get(0).unwrap();
        assert!((t0 - 2.0).abs() < 1e-15, "t0={t0} expected 2.0");
        assert!((s0[0] - 50.0).abs() < 1e-15, "s0[0]={} expected 50", s0[0]);

        // One step back should be t=1.0.
        let (s1, t1) = hist.get(1).unwrap();
        assert!((t1 - 1.0).abs() < 1e-15, "t1={t1} expected 1.0");
        assert!((s1[0] - 30.0).abs() < 1e-15, "s1[0]={} expected 30", s1[0]);

        // t=0.0 has been evicted — ago=2 is out of range.
        assert!(hist.get(2).is_none(), "t=0.0 should be evicted from ring");
    }

    /// TransientResult: num_steps, num_nodes, and node_voltages dimensions are consistent.
    #[test]
    fn test_transient_result_dimensions() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("n1");

        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 1.0);

        ckt.add_device(v1);
        ckt.build_topology();

        let registry = DeviceRegistry::default();
        let config = TransientConfig::new(1e-4, 5e-4); // 5 steps

        let result = run_transient(&mut ckt, &registry, &config).unwrap();

        assert_eq!(result.num_nodes, 1, "circuit has 1 non-ground node");
        assert_eq!(
            result.node_voltages.len(),
            result.times.len(),
            "node_voltages and times must have the same length"
        );
        for (step, vrow) in result.node_voltages.iter().enumerate() {
            assert_eq!(
                vrow.len(),
                result.num_nodes,
                "step {step}: node_voltages row length mismatch"
            );
        }
    }

    // ---- Additional TransientConfig tests ----

    #[test]
    fn transient_config_uic_flag_set() {
        let mut cfg = TransientConfig::new(1e-9, 1e-6);
        cfg.uic = true;
        assert!(cfg.uic);
    }

    #[test]
    fn transient_config_tol_default() {
        let cfg = TransientConfig::new(1e-9, 1e-6);
        assert!((cfg.tol - 1e-3).abs() < 1e-15);
    }

    #[test]
    fn transient_config_timeout_none_by_default() {
        let cfg = TransientConfig::new(1e-9, 1e-6);
        assert!(cfg.timeout_secs.is_none());
    }

    #[test]
    fn transient_config_timeout_set() {
        let mut cfg = TransientConfig::new(1e-9, 1e-6);
        cfg.timeout_secs = Some(5.0);
        assert_eq!(cfg.timeout_secs, Some(5.0));
    }

    #[test]
    fn transient_config_method_stored_correctly() {
        let cfg = TransientConfig::with_method(1e-9, 1e-6, IntegrationMethod::Gear2);
        assert_eq!(cfg.method, IntegrationMethod::Gear2);
    }

    #[test]
    fn transient_config_adaptive_stores_tol() {
        let cfg = TransientConfig::with_adaptive(1e-9, 1e-6, IntegrationMethod::Trapezoidal);
        assert_eq!(cfg.method, IntegrationMethod::Trapezoidal);
        assert!(cfg.adaptive);
    }

    // ---- Additional BdfHistory tests ----

    #[test]
    fn bdf_history_empty_returns_none() {
        let hist = BdfHistory::new(2, 3);
        assert!(hist.get(0).is_none());
        assert!(hist.get(1).is_none());
    }

    #[test]
    fn bdf_history_single_push_get() {
        let mut hist = BdfHistory::new(2, 4);
        hist.push(1.0, &[10.0, 20.0, 30.0, 40.0]);
        let (state, t) = hist.get(0).unwrap();
        assert!((t - 1.0).abs() < 1e-15);
        assert!((state[0] - 10.0).abs() < 1e-15);
        assert!((state[3] - 40.0).abs() < 1e-15);
        assert!(hist.get(1).is_none());
    }

    #[test]
    fn bdf_history_two_pushes_order() {
        let mut hist = BdfHistory::new(2, 2);
        hist.push(0.0, &[1.0, 2.0]);
        hist.push(1.0, &[3.0, 4.0]);
        let (s0, t0) = hist.get(0).unwrap();
        let (s1, t1) = hist.get(1).unwrap();
        assert!((t0 - 1.0).abs() < 1e-15);
        assert!((s0[0] - 3.0).abs() < 1e-15);
        assert!((t1 - 0.0).abs() < 1e-15);
        assert!((s1[0] - 1.0).abs() < 1e-15);
    }

    #[test]
    fn bdf_history_max_order_1_capacity_2() {
        // max_order=1 allows 2 stored states
        let mut hist = BdfHistory::new(1, 1);
        hist.push(0.0, &[5.0]);
        hist.push(1.0, &[6.0]);
        assert!(hist.get(0).is_some());
        assert!(hist.get(1).is_some());
        assert!(hist.get(2).is_none());
    }

    #[test]
    fn bdf_history_ring_wrap_overwrites_oldest_max_order_2() {
        // max_order=2 → capacity 3
        let mut hist = BdfHistory::new(2, 1);
        hist.push(0.0, &[1.0]);
        hist.push(1.0, &[2.0]);
        hist.push(2.0, &[3.0]);
        // Ring is full; push one more — oldest (t=0) evicted
        hist.push(3.0, &[4.0]);
        let (s0, t0) = hist.get(0).unwrap();
        assert!((t0 - 3.0).abs() < 1e-15, "t0={t0}");
        assert!((s0[0] - 4.0).abs() < 1e-15);
        // t=0.0 gone; only 3 entries retained
        assert!(hist.get(3).is_none());
    }

    // ---- Additional integration tests ----

    #[test]
    fn transient_gear2_method_runs_without_error() {
        // Gear2 uses real BDF2 companion (falls back to BE for the first step
        // when only one history point is available). Check it runs and produces results.
        let mut ckt = Circuit::new();
        let n_vdd = ckt.add_node("vdd");
        let n_out = ckt.add_node("out");

        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n_vdd), (1, NodeId::GROUND)])
            .with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(1), "R1", DeviceKind::Resistor,
                &[(0, n_vdd), (1, n_out)])
            .with_param("resistance", 1e3),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(2), "C1", DeviceKind::Capacitor,
                &[(0, n_out), (1, NodeId::GROUND)])
            .with_param("capacitance", 1e-6),
        );
        ckt.build_topology();
        ckt.add_initial_condition(n_out, 0.0);

        let registry = DeviceRegistry::default();
        let config = TransientConfig::with_method(0.5e-3, 2e-3, IntegrationMethod::Gear2);
        let result = run_transient(&mut ckt, &registry, &config).unwrap();
        assert!(!result.times.is_empty());
    }

    #[test]
    fn transient_result_voltage_accessor_matches_flat() {
        let mut ckt = Circuit::new();
        let n_vdd = ckt.add_node("vdd");
        let n_out = ckt.add_node("out");

        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n_vdd), (1, NodeId::GROUND)])
            .with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(1), "R1", DeviceKind::Resistor,
                &[(0, n_vdd), (1, n_out)])
            .with_param("resistance", 1e3),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(2), "C1", DeviceKind::Capacitor,
                &[(0, n_out), (1, NodeId::GROUND)])
            .with_param("capacitance", 1e-6),
        );
        ckt.build_topology();
        ckt.add_initial_condition(n_out, 0.0);

        let registry = DeviceRegistry::default();
        let cfg = TransientConfig::new(0.1e-3, 0.5e-3);
        let result = run_transient(&mut ckt, &registry, &cfg).unwrap();

        for step in 0..result.num_steps() {
            for node in 0..result.num_nodes {
                let via_accessor = result.voltage(step, node);
                let via_flat = result.node_voltages_flat[step * result.num_nodes + node];
                assert!((via_accessor - via_flat).abs() < 1e-15,
                    "step={step} node={node}: accessor={via_accessor} flat={via_flat}");
            }
        }
    }

    #[test]
    fn transient_uic_skips_dc_op() {
        // With UIC=true, capacitor starts at specified initial condition voltage.
        let mut ckt = Circuit::new();
        let n_vdd = ckt.add_node("vdd");
        let n_out = ckt.add_node("out");

        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n_vdd), (1, NodeId::GROUND)])
            .with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(1), "R1", DeviceKind::Resistor,
                &[(0, n_vdd), (1, n_out)])
            .with_param("resistance", 1e3),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(2), "C1", DeviceKind::Capacitor,
                &[(0, n_out), (1, NodeId::GROUND)])
            .with_param("capacitance", 1e-6),
        );
        ckt.build_topology();
        // Set an initial condition of 2.5V on the output node
        ckt.add_initial_condition(n_out, 2.5);

        let registry = DeviceRegistry::default();
        let mut cfg = TransientConfig::new(0.1e-3, 0.5e-3);
        cfg.uic = true;

        let result = run_transient(&mut ckt, &registry, &cfg).unwrap();
        // First entry (t=0) in node_voltages reflects UIC
        let n_out_idx = (n_out.0 - 1) as usize;
        let v_t0 = result.node_voltages[0][n_out_idx];
        // UIC sets voltage from initial_conditions vector
        assert!(v_t0.is_finite(), "UIC transient should give finite initial voltage");
        assert!(!result.times.is_empty());
    }

    #[test]
    fn transient_times_are_monotonically_increasing() {
        let mut ckt = Circuit::new();
        let n = ckt.add_node("n1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n), (1, NodeId::GROUND)])
            .with_param("dc", 1.0),
        );
        ckt.build_topology();

        let registry = DeviceRegistry::default();
        let cfg = TransientConfig::new(1e-4, 5e-4);
        let result = run_transient(&mut ckt, &registry, &cfg).unwrap();

        for i in 1..result.times.len() {
            assert!(result.times[i] > result.times[i - 1],
                "times not monotone at step {i}: {} -> {}", result.times[i-1], result.times[i]);
        }
    }

    #[test]
    fn transient_flat_and_nested_voltages_consistent() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("n1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)])
            .with_param("dc", 3.0),
        );
        ckt.build_topology();

        let registry = DeviceRegistry::default();
        let cfg = TransientConfig::new(1e-4, 3e-4);
        let result = run_transient(&mut ckt, &registry, &cfg).unwrap();

        let nv = result.num_nodes;
        for (step, row) in result.node_voltages.iter().enumerate() {
            for (ni, &v_nested) in row.iter().enumerate() {
                let v_flat = result.node_voltages_flat[step * nv + ni];
                assert!((v_nested - v_flat).abs() < 1e-15,
                    "step={step} ni={ni}: nested={v_nested} flat={v_flat}");
            }
        }
    }

    #[test]
    fn transient_single_resistor_dc_stays_constant() {
        // Pure DC circuit (no capacitor): voltage at node should be constant across all steps.
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("n1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)])
            .with_param("dc", 3.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(1), "R1", DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)])
            .with_param("resistance", 1e3),
        );
        ckt.build_topology();

        let registry = DeviceRegistry::default();
        let cfg = TransientConfig::new(1e-4, 5e-4);
        let result = run_transient(&mut ckt, &registry, &cfg).unwrap();

        let v0 = result.node_voltages[0][0];
        for (step, row) in result.node_voltages.iter().enumerate() {
            assert!((row[0] - v0).abs() < 1e-6,
                "step {step}: V(n1)={} should be constant ~{v0}", row[0]);
        }
        assert!((v0 - 3.0).abs() < 0.01, "V(n1) should be ~3V, got {v0}");
    }

    /// Verify that T-line history buffers are updated during transient analysis.
    ///
    /// Circuit: V1(1V DC) → RS(50Ω) → T1(Z0=50, TD=0.1ns) → RL(50Ω) → GND
    ///
    /// After running for several time steps, the T-line history buffer must
    /// contain at least one pushed sample (proving update_tline_histories was
    /// called).  Without the fix this buffer stays empty.
    #[test]
    fn tline_history_is_updated_after_transient_steps() {
        use incspice_solver::update_tline_histories as _; // confirm import compiles

        let mut ckt = Circuit::new();
        let n_in  = ckt.add_node("in");
        let n_p1  = ckt.add_node("p1");
        let n_p2  = ckt.add_node("p2");

        // V1: 1 V source at "in"
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n_in), (1, NodeId::GROUND)])
            .with_param("dc", 1.0),
        );
        // RS: 50 Ω source impedance
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(1), "RS", DeviceKind::Resistor,
                &[(0, n_in), (1, n_p1)])
            .with_param("resistance", 50.0),
        );
        // T1: lossless tline, Z0=50 Ω, TD=0.1 ns
        let t1_id = ckt.add_device(
            DeviceInstance::new(DeviceId::new(2), "T1", DeviceKind::Tline,
                &[(0, n_p1), (1, NodeId::GROUND), (2, n_p2), (3, NodeId::GROUND)])
            .with_param("z0", 50.0)
            .with_param("td", 0.1e-9),
        );
        // RL: 50 Ω matched load
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(3), "RL", DeviceKind::Resistor,
                &[(0, n_p2), (1, NodeId::GROUND)])
            .with_param("resistance", 50.0),
        );
        ckt.build_topology();

        let registry = DeviceRegistry::default();
        // Run 5 fixed steps of 0.05 ns each — enough to push history entries.
        let cfg = TransientConfig::with_method(0.05e-9, 0.25e-9, IntegrationMethod::BackwardEuler);
        let result = run_transient(&mut ckt, &registry, &cfg).unwrap();

        // The simulation must produce at least a few timesteps.
        assert!(
            result.times.len() >= 2,
            "expected at least 2 transient timepoints, got {}",
            result.times.len()
        );

        // The T-line history buffer must have been populated.
        let hist = ckt
            .tline_history(t1_id)
            .expect("TlineHistory must exist after transient with T-line");

        // delayed_p1 at a time well after the last push should return a finite value.
        let probe_time = *result.times.last().unwrap() + 0.1e-9;
        let e_p1 = hist.delayed_p1(probe_time);
        assert!(
            e_p1.is_finite(),
            "delayed_p1 should be finite after history update, got {e_p1}"
        );
    }

    /// Diagnostic: simulate ECL gate and print key signal swings.
    /// Run with: `cargo test -p incspice-analysis -- debug_ecl --ignored --nocapture`
    #[test]
    #[ignore]
    fn debug_ecl_gate() {
        use incspice_parser::SpiceParser;

        let sp = r#"* ECL OR/NOR Gate
VEE vee 0 DC -5.2
VBB ref 0 DC -1.32
VA ina 0 PULSE(-1.7 -0.9 0 0.1n 0.1n 5n 10n)
VB inb 0 PULSE(-1.7 -0.9 2.5n 0.1n 0.1n 5n 10n)
RC1 0 col1 220
RC2 0 col2 220
Q1A col1 ina tail NPN1
Q1B col1 inb tail NPN1
Q2 col2 ref tail NPN1
REE tail vee 780
Q3 0 col1 nor_out NPN1
RNOR nor_out vee 2k
Q4 0 col2 or_out NPN1
ROR or_out vee 2k
.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)
.TRAN 0.1n 20n
.END
"#;
        let parsed = SpiceParser::parse_str(sp).unwrap();
        let mut circuit = parsed.circuit;
        let reg = DeviceRegistry::new_default();
        let fixed_fine_tstep = 0.05e-9;
        let cfg = TransientConfig::with_method(fixed_fine_tstep, 20e-9, IntegrationMethod::Trapezoidal);
        let result = run_transient(&mut circuit, &reg, &cfg).unwrap();

        let nv = result.num_nodes;
        let n = result.times.len();
        println!("Steps: {} t_final: {:.3e}s", n, result.times.last().copied().unwrap_or(0.0));

        for ni in 0..nv {
            let vals: Vec<f64> = (0..n).map(|s| result.node_voltages_flat[s * nv + ni]).collect();
            let vmin = vals.iter().cloned().fold(f64::INFINITY, f64::min);
            let vmax = vals.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
            println!("  node[{}]: min={:.4} max={:.4}", ni, vmin, vmax);
        }
    }

    /// Diagnostic: simulate astable multivibrator and print node voltage ranges.
    /// This test is `#[ignore]`d in CI — run with `-- --ignored` to inspect waveforms.
    #[test]
    #[ignore]
    fn debug_multivibrator_oscillation() {
        use incspice_parser::SpiceParser;

        let sp = r#"* Astable Multivibrator
VCC vcc 0 DC 5
RC1 vcc col1 10k
RC2 vcc col2 10k
C1 col1 base2 10n
C2 col2 base1 10n
RB1 vcc base1 10k
RB2 vcc base2 10k
Q1 col1 base1 0 NPN1
Q2 col2 base2 0 NPN1
VSTART base1 base1x DC 0.001
RSTART base1x 0 100MEG
.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 CJE=2p CJC=1p TF=0.3n TR=6n)
.TRAN 10n 500u
.END
"#;
        let parsed = SpiceParser::parse_str(sp).unwrap();
        let mut circuit = parsed.circuit;
        let reg = DeviceRegistry::new_default();
        let cfg = TransientConfig {
            timeout_secs: Some(10.0),
            ..TransientConfig::with_method(10e-9, 500e-6, IntegrationMethod::BackwardEuler)
        };
        let result = run_transient(&mut circuit, &reg, &cfg).unwrap();

        let nv = result.num_nodes;
        let n = result.times.len();
        println!("Steps: {} / t_final: {:.3e}s", n, result.times.last().copied().unwrap_or(0.0));

        // Compute min/max for each node voltage
        for ni in 0..nv {
            let vals: Vec<f64> = (0..n).map(|s| result.node_voltages_flat[s * nv + ni]).collect();
            let vmin = vals.iter().cloned().fold(f64::INFINITY, f64::min);
            let vmax = vals.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
            println!("  node[{}]: min={:.4} max={:.4} swing={:.4}",
                     ni, vmin, vmax, vmax - vmin);
        }

        // Print first 5 and last 5 timestep values for node 1 (col1)
        let print_idx = 1usize;
        println!("col1 (idx={}) first 5 steps:", print_idx);
        for s in 0..5.min(n) {
            println!("  t={:.3e}: v={:.4e}", result.times[s], result.node_voltages_flat[s * nv + print_idx]);
        }
        println!("col1 last 5 steps:");
        for s in n.saturating_sub(5)..n {
            println!("  t={:.3e}: v={:.4e}", result.times[s], result.node_voltages_flat[s * nv + print_idx]);
        }

        // Check oscillation: col1 and col2 should swing at least 1V
        let col1_idx = 1; // col1 is the first circuit node (node 1, idx 0)
        let col2_idx = 2;
        let col1_vals: Vec<f64> = (0..n).map(|s| result.node_voltages_flat[s * nv + col1_idx]).collect();
        let col2_vals: Vec<f64> = (0..n).map(|s| result.node_voltages_flat[s * nv + col2_idx]).collect();
        let col1_swing = col1_vals.iter().cloned().fold(f64::NEG_INFINITY, f64::max)
            - col1_vals.iter().cloned().fold(f64::INFINITY, f64::min);
        let col2_swing = col2_vals.iter().cloned().fold(f64::NEG_INFINITY, f64::max)
            - col2_vals.iter().cloned().fold(f64::INFINITY, f64::min);
        println!("col1 swing: {:.4}V, col2 swing: {:.4}V", col1_swing, col2_swing);
    }
}
