//! Phase 5.6 — `CacheManager`: orchestrates every Phase-5 cache layer.
//!
//! Public, solver-facing entry point.  The solver crate (and the future
//! `ParamSweep` runner in `crates/analysis/src/sweep.rs`) construct a single
//! `CacheManager` per simulation session and call into it on the events:
//!
//! 1. `on_topology_built(&Circuit)` — once at the start, after the parser
//!    finalises the circuit.  Computes the topology hash, refreshes the
//!    dirty-tracker adjacency, and either reuses or allocates a symbolic
//!    LU entry.
//! 2. `on_param_changed(device_id, &ParamChange)` — every parameter mutation.
//!    Marks the device (and its node neighbours) dirty, and patches/inval-
//!    idates the compiled-eval entry as appropriate.
//! 3. `on_solve_complete(solution, …)` — after a successful Newton solve.
//!    Stores the operating point and (eventually) the device affine models.
//! 4. `on_transient_step(t, state, …)` — periodic checkpointing during a
//!    transient run.
//!
//! Provides hooks the solver *could* call without modifying the solver yet
//! (per ownership constraint in the prompt — we do not edit the solver here).
//!
//! ## Woodbury integration (TODO §6)
//!
//! During a parameter sweep, instead of a full re-factorisation for every
//! point, callers can register rank-1 updates to the Jacobian via
//! [`push_woodbury_rank1`] and then call [`try_woodbury_update`] to obtain
//! a corrected solution cheaply.  The decision to use Woodbury vs. a full
//! solve is made by the free function [`crate::woodbury::should_use_woodbury`]
//! (re-exposed here as [`CacheManager::should_use_woodbury`]).
//!
//! ### Integration point for dc_sweep / ParamSweep runners
//!
//! After each parameter change in the sweep loop, the sweep runner should:
//!
//! ```text
//! // 1. Register the rank-1 change that models ΔJ for the changed element.
//! cache.push_woodbury_rank1(&u_col, &v_col);
//!
//! // 2. Try the cheap Woodbury path first.
//! let solution = if cache.should_use_woodbury(n) {
//!     cache.try_woodbury_update(rhs, |b, out| solver.solve_with_cached_lu(b, out))
//!         .unwrap_or_else(|| solver.full_solve(circuit, rhs))
//! } else {
//!     solver.full_solve(circuit, rhs)
//! };
//!
//! // 3. After the solve succeeds, clear the pending updates ready for the
//! //    next sweep point.
//! cache.clear_woodbury();
//! cache.on_solve_complete(&solution);
//! ```
//!
//! If the Woodbury inner system is singular (very rare), `try_woodbury_update`
//! returns `None` and the caller falls back to a full re-solve automatically.

use incspice_core::{Circuit, DeviceId};

use crate::checkpoint::{CheckpointIdx, TransientArena};
use crate::compiled_eval::{CompiledEvalCache, DeviceIdx, InvalidationReason};
use crate::dirty_tracker::DirtyTracker;
use crate::topology_cache::{LinSolverCache, SymbolicLu, TopologyHash};
use crate::woodbury::{should_use_woodbury as woodbury_eligible, WoodburyUpdate};

/// Description of a parameter change, used by `CacheManager::on_param_changed`.
///
/// `Scaling` parameters can be patched into the cached affine model by a
/// simple multiply.  `NonLinear` parameters force a full re-eval.
#[derive(Debug, Clone, Copy)]
pub enum ParamChange {
    /// Multiply cached `I0`/`G` by `factor` (e.g. `W` doubled → `factor=2.0`).
    Scaling { factor: f64 },
    /// Temperature ratio (Arrhenius-like).
    Temperature { ratio: f64 },
    /// Anything else — invalidate.
    NonLinear,
}

/// Top-level cache façade owned by the analysis layer.
#[derive(Debug, Clone)]
pub struct CacheManager {
    pub topology_hash: Option<TopologyHash>,
    pub lin_cache: LinSolverCache,
    pub dirty: DirtyTracker,
    pub compiled: CompiledEvalCache,
    pub checkpoints: TransientArena,
    /// Last cached operating point (warm start for the next solve).
    pub op_solution: Vec<f64>,
    pub op_valid: bool,
    /// Counter of solves that hit the topology cache (for telemetry).
    pub topology_hits: u64,
    pub topology_misses: u64,
    /// Total number of *device evaluations* performed since the last
    /// `reset_eval_count`.  Bumped by [`solve_cached`] for every dirty
    /// device that was actually re-evaluated; clean devices served out of
    /// `compiled` do not bump this counter.
    eval_count: u64,
    /// Pending rank-k Woodbury update.
    ///
    /// Callers register rank-1 changes to the Jacobian via
    /// [`push_woodbury_rank1`] as each device parameter changes.  Once all
    /// changes for a sweep point are registered, [`try_woodbury_update`]
    /// applies the Sherman-Morrison-Woodbury identity to obtain the new
    /// solution without a full LU refactorisation.
    ///
    /// This is `None` until the system dimension is known (i.e. after the
    /// first [`on_topology_built`] call).  [`clear_woodbury`] resets `k` to
    /// zero but keeps the dimension and capacity so successive sweep points
    /// pay no allocation cost.
    pub woodbury: Option<WoodburyUpdate>,
    /// Number of times [`try_woodbury_update`] succeeded (telemetry).
    pub woodbury_hits: u64,
    /// Number of times [`try_woodbury_update`] returned `None` (telemetry).
    pub woodbury_misses: u64,
}

impl Default for CacheManager {
    fn default() -> Self {
        Self::new()
    }
}

impl CacheManager {
    pub fn new() -> Self {
        Self {
            topology_hash: None,
            lin_cache: LinSolverCache::new(),
            dirty: DirtyTracker::new(0, 0),
            compiled: CompiledEvalCache::new(0),
            checkpoints: TransientArena::new(),
            op_solution: Vec::new(),
            op_valid: false,
            topology_hits: 0,
            topology_misses: 0,
            eval_count: 0,
            woodbury: None,
            woodbury_hits: 0,
            woodbury_misses: 0,
        }
    }

    /// Convenience constructor that sizes every internal layer for the
    /// supplied circuit and immediately runs `on_topology_built`.
    ///
    /// Used by `ParamSweep::run_with_cache` so the sweep loop only has to
    /// touch a single `CacheManager` per pass.
    pub fn new_for_circuit(circuit: &Circuit) -> Self {
        let mut mgr = Self::new();
        let _ = mgr.on_topology_built(circuit);
        // Real solvers will store their own `SymbolicLu`; for the sweep
        // replay flow we only care about the dirty / compiled-eval layers,
        // so an empty placeholder is fine.
        mgr.store_symbolic(SymbolicLu::empty(circuit.mna_dimension()));
        mgr
    }

    /// Step (1): topology built.  Returns `true` if the topology hash matches
    /// a cached symbolic factor (caller can skip symbolic factorisation),
    /// `false` if the caller must build a fresh `SymbolicLu`.
    pub fn on_topology_built(&mut self, circuit: &Circuit) -> bool {
        let hash = TopologyHash::from_circuit(circuit);

        // Re-size dirty tracker if device count changed.
        let n_dev = circuit.devices().len();
        let n_nodes = circuit.nodes().len();
        if self.dirty.num_devices() != n_dev {
            self.dirty = DirtyTracker::new(n_dev, n_nodes);
            self.compiled.resize(n_dev);
        }
        self.dirty.rebuild_adjacency(circuit);
        self.dirty.clear();

        // Initialise (or resize) the Woodbury accumulator to match the MNA
        // dimension.  We reset k=0 here so a topology change always starts
        // fresh; the Vec capacity is retained across same-topology rebuilds.
        let mna_n = circuit.mna_dimension();
        match &mut self.woodbury {
            Some(w) if w.n == mna_n => w.clear(),
            _ => self.woodbury = Some(WoodburyUpdate::new(mna_n)),
        }

        let hit = self.lin_cache.peek(hash).is_some();
        if hit {
            self.topology_hits += 1;
        } else {
            self.topology_misses += 1;
            // Compiled-eval cache must be invalidated on topology miss.
            self.compiled.invalidate_all();
            self.op_valid = false;
        }
        self.topology_hash = Some(hash);
        hit
    }

    /// Step (1b): the solver has just produced a fresh symbolic factor —
    /// stash it under the current topology hash so a future identical-topology
    /// run can skip symbolic factorisation entirely.
    pub fn store_symbolic(&mut self, symbolic: SymbolicLu) {
        if let Some(h) = self.topology_hash {
            self.lin_cache.insert(h, symbolic);
        }
    }

    /// Read-only view of the cached symbolic factor for the current topology.
    pub fn cached_symbolic(&self) -> Option<&SymbolicLu> {
        let h = self.topology_hash?;
        self.lin_cache.peek(h).map(|e| &e.symbolic)
    }

    /// Step (2): parameter changed on `device`.
    ///
    /// Marks the device (and its neighbours via dirty propagation) dirty.
    /// If the change is `Scaling` or `Temperature` and a compiled-eval entry
    /// exists for the device, that entry is patched in place; otherwise it
    /// is invalidated.
    pub fn on_param_changed(&mut self, device: DeviceId, change: ParamChange) {
        // Forward through the canonical mark_param_changed entry point so
        // every dirty event flows through one signature.  num_devices is
        // taken from the tracker's current size.
        let n_dev = self.dirty.num_devices().max(device.index() + 1);
        self.dirty.mark_param_changed(device.0, n_dev);

        let dev_idx = DeviceIdx::from_id(device);
        match change {
            ParamChange::Scaling { factor } => {
                if self.compiled.is_valid(dev_idx) {
                    let _ = self.compiled.patch_scale(dev_idx, factor);
                }
            }
            ParamChange::Temperature { ratio } => {
                if self.compiled.is_valid(dev_idx) {
                    let _ = self.compiled.patch_temperature(dev_idx, ratio);
                }
            }
            ParamChange::NonLinear => {
                self.compiled
                    .invalidate(dev_idx, InvalidationReason::NonLinearParamChange);
            }
        }
    }

    /// Convenience: mark several params changed in a batch.
    pub fn on_param_changes(&mut self, changes: &[(DeviceId, ParamChange)]) {
        for &(d, c) in changes {
            self.on_param_changed(d, c);
        }
    }

    /// String-keyed parameter mutation entry point used by the public
    /// `ParamSweep` runner.
    ///
    /// Looks up the device by index, classifies the parameter name into a
    /// [`ParamChange`] (`Scaling` for the standard size/value parameters
    /// `resistance`, `capacitance`, `inductance`, `w`, `l`, `m`, `area`,
    /// `dc`, `value`; `Temperature` for `temp`/`tnom`; `NonLinear` for
    /// everything else), and forwards to `on_param_changed`.
    ///
    /// `factor` is the new-value-to-old-value ratio so the cached affine
    /// model can be analytically patched in place.
    pub fn mark_param_changed(&mut self, dev_idx: u32, param: &str, factor: f64) {
        let mut lower = param.to_string();
        lower.make_ascii_lowercase();
        let change = match lower.as_str() {
            "resistance" | "capacitance" | "inductance" | "w" | "l" | "m" | "area" | "scale"
            | "dc" | "value" | "amplitude" => ParamChange::Scaling { factor },
            "temp" | "tnom" | "tj" | "temperature" => ParamChange::Temperature { ratio: factor },
            _ => ParamChange::NonLinear,
        };
        self.on_param_changed(DeviceId::new(dev_idx), change);
    }

    /// Replay-aware "solve" entry point.
    ///
    /// Walks the dirty bitset and re-evaluates the affine model **only**
    /// for devices marked dirty since the last solve, leaving every other
    /// device served straight out of [`CompiledEvalCache`].
    /// `eval_device` is the user closure that performs the (otherwise
    /// expensive) device re-eval; it is invoked exactly once per dirty
    /// device per call.
    ///
    /// `rhs` is the freshly-computed solution vector — it is stashed as
    /// the new warm start so the next sweep point can pick it up via
    /// [`warm_start`].
    ///
    /// Returns the number of device re-evaluations performed during this
    /// call (also accumulated into [`eval_count`]).
    pub fn solve_cached<F>(&mut self, rhs: &[f64], mut eval_device: F) -> u64
    where
        F: FnMut(DeviceId),
    {
        let dirty: Vec<DeviceId> = self.dirty.iter_dirty_devices().collect();
        let n = dirty.len() as u64;
        for d in &dirty {
            eval_device(*d);
        }
        self.eval_count = self.eval_count.saturating_add(n);
        self.on_solve_complete(rhs);
        n
    }

    /// Total number of device re-evaluations since the last
    /// `reset_eval_count` (or since `CacheManager::new`).
    pub fn eval_count(&self) -> u64 {
        self.eval_count
    }

    /// Zero out the eval counter (test helper / per-sweep-point reset).
    pub fn reset_eval_count(&mut self) {
        self.eval_count = 0;
    }

    /// Step (3): a successful solve has just produced `solution`.
    ///
    /// Caches the operating point so the next solve can warm-start, and
    /// clears the dirty tracker.
    pub fn on_solve_complete(&mut self, solution: &[f64]) {
        self.op_solution.clear();
        self.op_solution.extend_from_slice(solution);
        self.op_valid = true;
        self.dirty.clear();
    }

    /// Store an affine model entry for one device after a successful eval.
    pub fn store_affine(
        &mut self,
        device: DeviceId,
        rows: usize,
        i0: &[f64],
        g: &[f64],
        v0: &[f64],
    ) {
        self.compiled
            .store(DeviceIdx::from_id(device), rows, i0, g, v0);
    }

    /// Replay the cached affine model for `device`.  Returns `Some(())` on
    /// hit, `None` on miss; the caller falls back to a full eval on miss.
    pub fn replay_affine(&mut self, device: DeviceId, v: &[f64], out_i: &mut [f64]) -> Option<()> {
        self.compiled.replay(DeviceIdx::from_id(device), v, out_i)
    }

    /// Read-only warm start (None if no operating point cached).
    pub fn warm_start(&self) -> Option<&[f64]> {
        if self.op_valid && !self.op_solution.is_empty() {
            Some(&self.op_solution)
        } else {
            None
        }
    }

    /// Step (4): record a transient checkpoint.
    pub fn on_transient_step(
        &mut self,
        time: f64,
        state: &[f64],
        charges: &[f64],
        events: &[(f64, u32)],
    ) -> CheckpointIdx {
        self.checkpoints.push(time, state, charges, events)
    }

    /// Restore the nearest checkpoint at-or-before `t`, returning the index
    /// the caller can pass to `checkpoints.get(...)`.
    pub fn restore_nearest(&self, t: f64) -> Option<CheckpointIdx> {
        self.checkpoints.nearest_before(t)
    }

    /// Wipe the operating-point and compiled-eval caches; keep the symbolic
    /// LU around because the topology is unchanged.
    pub fn invalidate_op(&mut self) {
        self.op_valid = false;
        self.compiled.invalidate_all();
        self.dirty.mark_all_dirty();
    }

    /// Full reset — used on a topology change so the cache forgets everything.
    pub fn reset_all(&mut self) {
        self.topology_hash = None;
        self.lin_cache.clear();
        self.dirty = DirtyTracker::new(0, 0);
        self.compiled.resize(0);
        self.checkpoints.reset();
        self.op_solution.clear();
        self.op_valid = false;
        self.woodbury = None;
        self.woodbury_hits = 0;
        self.woodbury_misses = 0;
    }

    // -------------------------------------------------------------------------
    // Woodbury incremental-update API (TODO §6)
    // -------------------------------------------------------------------------

    /// Register one rank-1 change `u · v^T` to the Jacobian.
    ///
    /// Call this once for every element of the system matrix that changes
    /// between two consecutive sweep points.  When all changes have been
    /// pushed, call [`try_woodbury_update`] to solve the updated system
    /// cheaply.
    ///
    /// `u_col` and `v_col` must each have length equal to the MNA dimension
    /// (`circuit.mna_dimension()`).  If the Woodbury accumulator has not been
    /// initialised yet (i.e. [`on_topology_built`] has not been called) this
    /// is a no-op.
    pub fn push_woodbury_rank1(&mut self, u_col: &[f64], v_col: &[f64]) {
        if let Some(w) = &mut self.woodbury {
            w.push_rank1(u_col, v_col);
        }
    }

    /// Reset the pending rank-k Woodbury update to rank 0.
    ///
    /// Call this after a sweep point has been resolved (whether via Woodbury
    /// or a full re-solve) so the accumulator is clean for the next point.
    /// Retains allocated capacity.
    pub fn clear_woodbury(&mut self) {
        if let Some(w) = &mut self.woodbury {
            w.clear();
        }
    }

    /// Return the current rank `k` of pending Woodbury updates.
    ///
    /// Useful for the sweep runner to decide whether to call
    /// [`try_woodbury_update`] or go straight to a full re-solve.
    pub fn woodbury_rank(&self) -> usize {
        self.woodbury.as_ref().map_or(0, |w| w.rank())
    }

    /// Predicate: should we use Woodbury for `k` pending updates on an `n×n`
    /// system?
    ///
    /// This is a thin re-export of [`crate::woodbury::should_use_woodbury`]
    /// that reads `n` and `k` from the manager's own state, so the sweep
    /// runner does not have to query them separately.
    ///
    /// Returns `false` if the Woodbury accumulator has not been initialised.
    pub fn should_use_woodbury(&self) -> bool {
        match &self.woodbury {
            Some(w) => woodbury_eligible(w.n, w.k),
            None => false,
        }
    }

    /// Try to solve `(J_old + ΔJ) · x = rhs` using the accumulated Woodbury
    /// rank-k update, without a full LU refactorisation.
    ///
    /// `solve_base` is a closure `FnMut(&[f64], &mut [f64])` that solves
    /// `J_old · out = b` using the *previous* (cached) LU factorisation.
    /// The caller retains ownership of that LU; the cache layer never stores
    /// numeric LU values itself (those live in the solver crate).
    ///
    /// Returns `Some(solution)` on success, or `None` if:
    /// - no Woodbury accumulator is present (topology not yet built), or
    /// - the inner `k×k` Woodbury system is singular, or
    /// - the pending rank exceeds the `should_use_woodbury` threshold (the
    ///   caller should fall back to a full re-solve).
    ///
    /// On success the telemetry counter [`woodbury_hits`] is incremented; on
    /// failure [`woodbury_misses`] is incremented.
    ///
    /// # Sweep-loop usage pattern
    ///
    /// ```text
    /// // After registering all rank-1 updates for this sweep point:
    /// let sol = if cache.should_use_woodbury() {
    ///     cache.try_woodbury_update(rhs, |b, out| lu.solve(b, out))
    ///         .unwrap_or_else(|| full_solve(circuit, rhs))
    /// } else {
    ///     full_solve(circuit, rhs)
    /// };
    /// cache.clear_woodbury();
    /// cache.on_solve_complete(&sol);
    /// ```
    pub fn try_woodbury_update<F>(&mut self, rhs: &[f64], solve_base: F) -> Option<Vec<f64>>
    where
        F: FnMut(&[f64], &mut [f64]),
    {
        let w = self.woodbury.as_ref()?;

        // Eligibility check: too many updates → fall back to full re-solve.
        if !woodbury_eligible(w.n, w.k) {
            self.woodbury_misses += 1;
            return None;
        }

        let n = w.n;
        let mut out = vec![0.0_f64; n];

        match w.solve(rhs, &mut out, solve_base) {
            Ok(()) => {
                self.woodbury_hits += 1;
                Some(out)
            }
            Err(_) => {
                // Inner k×k system singular — caller must fall back.
                self.woodbury_misses += 1;
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::{DeviceInstance, DeviceKind, NodeId};

    fn rc_circuit() -> Circuit {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("dc", 5.0);
        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "R1",
            DeviceKind::Resistor,
            &[(0, n1), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0);
        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.build_topology();
        ckt
    }

    #[test]
    fn topology_hit_after_first_build() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        let hit_first = mgr.on_topology_built(&ckt);
        assert!(!hit_first);
        // Pretend we just built a symbolic factor.
        mgr.store_symbolic(SymbolicLu::empty(ckt.mna_dimension()));

        let hit_second = mgr.on_topology_built(&ckt);
        assert!(hit_second);
        assert_eq!(mgr.topology_hits, 1);
        assert_eq!(mgr.topology_misses, 1);
    }

    #[test]
    fn warm_start_round_trip() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);
        mgr.on_solve_complete(&[5.0, -0.005]);
        assert_eq!(mgr.warm_start().unwrap(), &[5.0, -0.005]);
    }

    #[test]
    fn param_change_marks_dirty() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);
        mgr.on_param_changed(DeviceId::new(1), ParamChange::Scaling { factor: 2.0 });
        assert!(mgr.dirty.is_dirty(DeviceId::new(1)));
    }

    #[test]
    fn test_temperature_param_classified() {
        // "temperature" must map to ParamChange::Temperature, not NonLinear.
        // We verify this indirectly: a Temperature change on a device with a
        // valid compiled-eval entry calls patch_temperature (which succeeds),
        // whereas NonLinear would call invalidate instead.
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);

        let dev = DeviceId::new(0);
        let dev_idx = crate::compiled_eval::DeviceIdx::from_id(dev);

        // Seed a valid compiled-eval entry for device 0.
        mgr.compiled.store(
            dev_idx,
            1,
            &[0.5],
            &[1.0],
            &[0.0],
        );
        assert!(mgr.compiled.is_valid(dev_idx), "entry should be valid before param change");

        // Apply a "temperature" parameter change with ratio=1.0 (identity).
        // If classified as Temperature, patch_temperature is called and the
        // entry remains valid.  If classified as NonLinear it would be invalidated.
        mgr.mark_param_changed(dev.0, "temperature", 1.0);

        assert!(
            mgr.compiled.is_valid(dev_idx),
            "temperature param must not invalidate the compiled-eval entry"
        );
        assert_eq!(mgr.compiled.patches, 1, "patch counter should increment for Temperature change");
    }

    #[test]
    fn test_temperature_aliases_classified() {
        // "temp", "tnom", "tj" must also all classify as Temperature.
        for param in &["temp", "tnom", "tj", "temperature"] {
            let ckt = rc_circuit();
            let mut mgr = CacheManager::new();
            mgr.on_topology_built(&ckt);

            let dev = DeviceId::new(0);
            let dev_idx = crate::compiled_eval::DeviceIdx::from_id(dev);
            mgr.compiled.store(dev_idx, 1, &[1.0], &[1.0], &[0.0]);

            mgr.mark_param_changed(dev.0, param, 1.0);

            assert!(
                mgr.compiled.is_valid(dev_idx),
                "param '{}' should be classified as Temperature (not NonLinear)",
                param
            );
        }
    }

    // -------------------------------------------------------------------------
    // Woodbury integration tests (TODO §6)
    // -------------------------------------------------------------------------

    /// After `on_topology_built`, the Woodbury accumulator must be present
    /// and sized to `mna_dimension()`.
    #[test]
    fn woodbury_initialised_on_topology_built() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        assert!(mgr.woodbury.is_none(), "before topology build woodbury should be None");

        mgr.on_topology_built(&ckt);

        let w = mgr.woodbury.as_ref().expect("woodbury should be Some after topology build");
        assert_eq!(w.n, ckt.mna_dimension());
        assert_eq!(w.k, 0, "freshly initialised accumulator must have rank 0");
    }

    /// `push_woodbury_rank1` increments the rank; `clear_woodbury` resets it.
    #[test]
    fn woodbury_push_and_clear() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);

        let n = ckt.mna_dimension();
        let u = vec![1.0; n];
        let v = vec![0.5; n];

        assert_eq!(mgr.woodbury_rank(), 0);
        mgr.push_woodbury_rank1(&u, &v);
        assert_eq!(mgr.woodbury_rank(), 1);
        mgr.push_woodbury_rank1(&u, &v);
        assert_eq!(mgr.woodbury_rank(), 2);

        mgr.clear_woodbury();
        assert_eq!(mgr.woodbury_rank(), 0, "clear must reset rank to 0");
    }

    /// `should_use_woodbury` returns false when no updates are pending and
    /// true once a rank-1 update is registered (for n >= 1).
    #[test]
    fn woodbury_should_use_flag() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);

        assert!(!mgr.should_use_woodbury(), "no pending updates → should not use Woodbury");

        let n = ckt.mna_dimension();
        if n > 0 {
            let u = vec![0.0; n];
            let v = vec![0.0; n];
            mgr.push_woodbury_rank1(&u, &v);
            // k=1, n>=1: eligible if 1 <= sqrt(n).max(1)
            // For n=2 (typical RC circuit MNA size): sqrt(2)=1, so k=1 is eligible.
            let eligible = crate::woodbury::should_use_woodbury(n, 1);
            assert_eq!(mgr.should_use_woodbury(), eligible);
        }
    }

    /// `try_woodbury_update` returns `None` before topology is built.
    #[test]
    fn woodbury_returns_none_before_topology() {
        let mut mgr = CacheManager::new();
        let rhs = vec![1.0, 2.0, 3.0];
        let result = mgr.try_woodbury_update(&rhs, |b, out| out.copy_from_slice(b));
        assert!(result.is_none(), "try_woodbury_update must return None when woodbury is not initialised");
        assert_eq!(mgr.woodbury_misses, 0, "no miss counted because we returned None early via ?, not the eligibility check");
    }

    /// Core round-trip: `try_woodbury_update` returns `Some` and gives a
    /// correct result when k=1 and n is eligible.
    ///
    /// We set up a 3×3 toy system so we can compute the exact answer with
    /// Cramer's rule, then verify the Woodbury path matches it.
    #[test]
    fn test_try_woodbury_update_returns_some_when_eligible() {
        // System dimension n=3.  We use a manager without a real circuit;
        // instead we manually install a WoodburyUpdate of the right size.
        let mut mgr = CacheManager::new();

        // Manually set the woodbury accumulator (bypassing on_topology_built)
        // to a 3-dimensional one so we can drive the test with a known system.
        let n = 3;
        mgr.woodbury = Some(WoodburyUpdate::new(n));

        // J_old (3×3, stored row-major for the closure below).
        let j_old: [f64; 9] = [4.0, 1.0, 0.0, 1.0, 3.0, 1.0, 0.0, 1.0, 2.0];

        // Rank-1 update: u=(1,0,0), v=(0,1,0) — adds 1 at position (0,1).
        let u_col = [1.0, 0.0, 0.0];
        let v_col = [0.0, 1.0, 0.0];
        mgr.push_woodbury_rank1(&u_col, &v_col);

        assert_eq!(mgr.woodbury_rank(), 1);
        assert!(mgr.should_use_woodbury(), "k=1, n=3 → sqrt(3)=1 → eligible");

        let b = [1.0, 2.0, 3.0];

        // Compute reference solution from J_new = J_old + u*v^T directly.
        let mut j_new = j_old;
        for i in 0..n {
            for j in 0..n {
                j_new[i * n + j] += u_col[i] * v_col[j];
            }
        }
        let mut x_ref = [0.0_f64; 3];
        dense_inverse_solve_3x3(&j_new, &b, &mut x_ref);

        // Woodbury path via try_woodbury_update.
        // The closure receives dynamic slices; we copy into fixed-size arrays
        // for the Cramer's-rule helper.
        let solve_base = |rhs: &[f64], out: &mut [f64]| {
            let rhs3: [f64; 3] = rhs.try_into().unwrap();
            let mut tmp = [0.0_f64; 3];
            dense_inverse_solve_3x3(&j_old, &rhs3, &mut tmp);
            out.copy_from_slice(&tmp);
        };
        let result = mgr.try_woodbury_update(&b, solve_base);

        assert!(result.is_some(), "try_woodbury_update must return Some for eligible k=1, n=3");
        assert_eq!(mgr.woodbury_hits, 1);
        assert_eq!(mgr.woodbury_misses, 0);

        let x_wood = result.unwrap();
        for i in 0..n {
            let diff = (x_ref[i] - x_wood[i]).abs();
            assert!(
                diff < 1e-12,
                "x_ref[{i}]={} x_wood[{i}]={} diff={}",
                x_ref[i], x_wood[i], diff
            );
        }
    }

    /// When k exceeds the `should_use_woodbury` threshold, `try_woodbury_update`
    /// returns `None` and increments `woodbury_misses`.
    #[test]
    fn test_woodbury_returns_none_when_too_many_updates() {
        let mut mgr = CacheManager::new();
        let n = 4; // sqrt(4)=2, so k=3 is over threshold
        mgr.woodbury = Some(WoodburyUpdate::new(n));

        let u = vec![1.0; n];
        let v = vec![1.0; n];
        // Push 3 rank-1 updates: k=3 > sqrt(4)=2 → ineligible.
        mgr.push_woodbury_rank1(&u, &v);
        mgr.push_woodbury_rank1(&u, &v);
        mgr.push_woodbury_rank1(&u, &v);

        assert!(!mgr.should_use_woodbury(), "k=3 > sqrt(4)=2 → ineligible");

        let rhs = vec![0.0; n];
        let result = mgr.try_woodbury_update(&rhs, |b, out| out.copy_from_slice(b));
        assert!(result.is_none(), "try_woodbury_update must return None when ineligible");
        assert_eq!(mgr.woodbury_misses, 1);
        assert_eq!(mgr.woodbury_hits, 0);
    }

    /// Simulate a 10-step resistor sweep: verify Woodbury path gives the same
    /// result as a direct solve at each step.
    ///
    /// Circuit: Vin → R → GND modelled as a 2×2 MNA system (one voltage node,
    /// one branch current).  The MNA matrix for this circuit is:
    ///
    /// ```text
    ///   [ 1/R   1 ]   (KCL at v_node: conductance + voltage branch)
    ///   [ 1     0 ]   (KVL: v_node = Vin)
    /// ```
    ///
    /// Actually the standard SPICE MNA for Vin (ideal voltage source):
    ///   Node 1 (v1):  G*v1 + i_v = 0   (G = 1/R)
    ///   Branch (iv):  v1 = Vin
    ///
    /// Matrix A = [[G, 1],[1, 0]], rhs = [0, Vin].
    /// Solution: v1 = Vin, i_v = -Vin*G.
    ///
    /// When R increases by delta each step we add ΔG = -ΔR/(R*(R+ΔR)) to
    /// position (0,0), which is a rank-1 update u=(1,0), v=(1,0) scaled by ΔG.
    #[test]
    fn test_woodbury_resistor_sweep_10_steps() {
        let n = 2usize; // 2×2 MNA
        let vin = 5.0_f64;
        let r0 = 1000.0_f64;
        let delta_r = 10.0_f64; // increase R by 10 Ω each step

        // Build the initial MNA for R = r0.
        // A_old = [[1/R, 1], [1, 0]]  (row-major, 2×2)
        let make_a = |r: f64| -> [f64; 4] {
            [1.0 / r, 1.0, 1.0, 0.0]
        };

        // Closed-form solve: A*x = b => x = A^{-1} * b.
        // A = [[g,1],[1,0]], det = -1, A^{-1} = [[0,-1],[-1,g]].
        // b = [0, vin] => x = [0*0 + (-1)*vin, (-1)*0 + g*vin] = [-vin, g*vin].
        // So v1 = -vin ... wait let me recalculate.
        // Actually det(A) = g*0 - 1*1 = -1.
        // A^{-1} = (1/det)*[[0,-1],[-1,g]] = [[0,1],[1,-g]].
        // x = A^{-1}*[0,vin] = [vin, -g*vin].  (v1=vin, iv=-vin/r)
        let exact_solve = |r: f64| -> [f64; 2] {
            [vin, -vin / r]
        };

        // Cramer's rule 2×2 solve: A*x = b.
        let cramer_2x2 = |a: &[f64; 4], b: &[f64; 2]| -> [f64; 2] {
            let det = a[0] * a[3] - a[1] * a[2];
            [(b[0] * a[3] - b[1] * a[1]) / det, (a[0] * b[1] - a[2] * b[0]) / det]
        };

        let mut mgr = CacheManager::new();
        mgr.woodbury = Some(WoodburyUpdate::new(n));

        let b = [0.0_f64, vin];
        let mut woodbury_taken = 0u32;

        for step in 0..10u32 {
            let r_old = r0 + (step as f64) * delta_r;
            let r_new = r_old + delta_r;
            let a_old = make_a(r_old);

            // ΔG = 1/R_new - 1/R_old at position (0,0).
            // Rank-1: u=(1,0), v=(1,0) scaled by delta_g.
            let delta_g = 1.0 / r_new - 1.0 / r_old;
            let u_col = [delta_g, 0.0];
            let v_col = [1.0, 0.0];
            mgr.push_woodbury_rank1(&u_col, &v_col);

            // Try Woodbury path.
            let wood_sol = if mgr.should_use_woodbury() {
                let a_old_cap = a_old; // capture for closure
                mgr.try_woodbury_update(&b, move |rhs, out| {
                    let s = cramer_2x2(&a_old_cap, &[rhs[0], rhs[1]]);
                    out[0] = s[0];
                    out[1] = s[1];
                })
            } else {
                None
            };

            // Reference solve against the updated matrix directly.
            let a_new = make_a(r_new);
            let ref_sol = cramer_2x2(&a_new, &[b[0], b[1]]);
            let expected = exact_solve(r_new);

            // Exact solution must agree with Cramer's rule.
            assert!((ref_sol[0] - expected[0]).abs() < 1e-10, "step {step}: cramer mismatch v1");
            assert!((ref_sol[1] - expected[1]).abs() < 1e-10, "step {step}: cramer mismatch iv");

            if let Some(ws) = wood_sol {
                woodbury_taken += 1;
                for i in 0..n {
                    let diff = (ws[i] - ref_sol[i]).abs();
                    assert!(
                        diff < 1e-10,
                        "step {step} dim {i}: Woodbury={} ref={} diff={}",
                        ws[i], ref_sol[i], diff
                    );
                }
            }

            mgr.clear_woodbury();
        }

        // For n=2, sqrt(2)=1, so k=1 is always eligible → all 10 steps taken.
        assert_eq!(woodbury_taken, 10, "all 10 sweep steps should have used the Woodbury path");
        assert_eq!(mgr.woodbury_hits, 10);
        assert_eq!(mgr.woodbury_misses, 0);
    }

    // -------------------------------------------------------------------------
    // Additional CacheManager tests
    // -------------------------------------------------------------------------

    #[test]
    fn cache_manager_new_is_clean() {
        let mgr = CacheManager::new();
        assert!(mgr.topology_hash.is_none());
        assert!(!mgr.op_valid);
        assert!(mgr.op_solution.is_empty());
        assert_eq!(mgr.topology_hits, 0);
        assert_eq!(mgr.topology_misses, 0);
        assert!(mgr.warm_start().is_none());
    }

    #[test]
    fn cache_manager_default_is_same_as_new() {
        let a = CacheManager::new();
        let b = CacheManager::default();
        assert_eq!(a.op_valid, b.op_valid);
        assert_eq!(a.topology_hits, b.topology_hits);
    }

    #[test]
    fn on_solve_complete_marks_op_valid() {
        let mut mgr = CacheManager::new();
        assert!(!mgr.op_valid);
        mgr.on_solve_complete(&[1.0, 2.0, 3.0]);
        assert!(mgr.op_valid);
        assert_eq!(mgr.warm_start().unwrap(), &[1.0, 2.0, 3.0]);
    }

    #[test]
    fn on_solve_complete_clears_dirty() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);
        mgr.on_param_changed(DeviceId::new(1), ParamChange::NonLinear);
        assert!(mgr.dirty.is_dirty(DeviceId::new(1)));
        mgr.on_solve_complete(&[5.0, -0.005]);
        assert!(!mgr.dirty.is_dirty(DeviceId::new(1)));
    }

    #[test]
    fn invalidate_op_makes_warm_start_none() {
        let mut mgr = CacheManager::new();
        mgr.on_solve_complete(&[1.0, 2.0]);
        assert!(mgr.warm_start().is_some());
        mgr.invalidate_op();
        assert!(mgr.warm_start().is_none());
    }

    #[test]
    fn invalidate_op_marks_all_dirty() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);
        mgr.on_solve_complete(&[5.0, -0.005]);
        mgr.invalidate_op();
        // After invalidate_op, all devices should be dirty
        assert!(mgr.dirty.dirty_device_count() > 0);
    }

    #[test]
    fn reset_all_clears_everything() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);
        mgr.on_solve_complete(&[5.0, -0.005]);
        mgr.reset_all();
        assert!(mgr.topology_hash.is_none());
        assert!(!mgr.op_valid);
        assert!(mgr.op_solution.is_empty());
        assert!(mgr.woodbury.is_none());
    }

    #[test]
    fn on_param_changes_batch() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);
        let changes = vec![
            (DeviceId::new(0), ParamChange::NonLinear),
            (DeviceId::new(1), ParamChange::Scaling { factor: 2.0 }),
        ];
        mgr.on_param_changes(&changes);
        assert!(mgr.dirty.is_dirty(DeviceId::new(0)));
        assert!(mgr.dirty.is_dirty(DeviceId::new(1)));
    }

    #[test]
    fn eval_count_increments_with_solve_cached() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);
        mgr.on_param_changed(DeviceId::new(0), ParamChange::NonLinear);
        mgr.on_param_changed(DeviceId::new(1), ParamChange::NonLinear);
        let n = mgr.solve_cached(&[5.0, -0.005], |_| {});
        assert_eq!(n, 2, "two dirty devices should produce 2 evaluations");
        assert_eq!(mgr.eval_count(), 2);
    }

    #[test]
    fn reset_eval_count_zeros_counter() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);
        mgr.on_param_changed(DeviceId::new(0), ParamChange::NonLinear);
        mgr.solve_cached(&[5.0], |_| {});
        assert!(mgr.eval_count() > 0);
        mgr.reset_eval_count();
        assert_eq!(mgr.eval_count(), 0);
    }

    #[test]
    fn mark_param_changed_scaling_names() {
        for param in &["resistance", "capacitance", "inductance", "dc", "value", "w", "l"] {
            let ckt = rc_circuit();
            let mut mgr = CacheManager::new();
            mgr.on_topology_built(&ckt);
            mgr.mark_param_changed(0, param, 2.0);
            assert!(mgr.dirty.is_dirty(DeviceId::new(0)),
                "param '{}' should mark device dirty", param);
        }
    }

    #[test]
    fn mark_param_changed_nonlinear_name() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        mgr.on_topology_built(&ckt);
        mgr.mark_param_changed(0, "unknown_param_xyz", 1.5);
        assert!(mgr.dirty.is_dirty(DeviceId::new(0)));
    }

    #[test]
    fn on_transient_step_stores_checkpoint() {
        let mut mgr = CacheManager::new();
        let idx = mgr.on_transient_step(1e-9, &[1.0, 2.0], &[0.0, 0.0], &[]);
        // restore_nearest should return the index we just stored
        let nearest = mgr.restore_nearest(1e-9);
        assert!(nearest.is_some(), "checkpoint at t=1ns should be found");
        let _ = idx;
    }

    #[test]
    fn cached_symbolic_none_before_topology() {
        let mgr = CacheManager::new();
        assert!(mgr.cached_symbolic().is_none());
    }

    #[test]
    fn topology_misses_zero_before_any_build() {
        let mgr = CacheManager::new();
        assert_eq!(mgr.topology_misses, 0);
        assert_eq!(mgr.topology_hits, 0);
    }

    #[test]
    fn topology_miss_on_first_build() {
        let ckt = rc_circuit();
        let mut mgr = CacheManager::new();
        let hit = mgr.on_topology_built(&ckt);
        assert!(!hit, "first build is always a miss");
        assert_eq!(mgr.topology_misses, 1);
        assert_eq!(mgr.topology_hits, 0);
    }

    #[test]
    fn woodbury_rank_zero_without_topology() {
        let mgr = CacheManager::new();
        assert_eq!(mgr.woodbury_rank(), 0);
    }

    // Helper: Cramer's rule for a 3×3 dense matrix (used by the unit tests above).
    fn dense_inverse_solve_3x3(a: &[f64; 9], b: &[f64; 3], out: &mut [f64; 3]) {
        let det = a[0] * (a[4] * a[8] - a[5] * a[7])
            - a[1] * (a[3] * a[8] - a[5] * a[6])
            + a[2] * (a[3] * a[7] - a[4] * a[6]);
        let inv = [
            (a[4] * a[8] - a[5] * a[7]) / det,
            -(a[1] * a[8] - a[2] * a[7]) / det,
            (a[1] * a[5] - a[2] * a[4]) / det,
            -(a[3] * a[8] - a[5] * a[6]) / det,
            (a[0] * a[8] - a[2] * a[6]) / det,
            -(a[0] * a[5] - a[2] * a[3]) / det,
            (a[3] * a[7] - a[4] * a[6]) / det,
            -(a[0] * a[7] - a[1] * a[6]) / det,
            (a[0] * a[4] - a[1] * a[3]) / det,
        ];
        for r in 0..3 {
            let mut s = 0.0;
            for c in 0..3 {
                s += inv[r * 3 + c] * b[c];
            }
            out[r] = s;
        }
    }
}
