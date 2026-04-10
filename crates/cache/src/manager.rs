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

use pisim_core::{Circuit, DeviceId};

use crate::checkpoint::{CheckpointIdx, TransientArena};
use crate::compiled_eval::{CompiledEvalCache, DeviceIdx, InvalidationReason};
use crate::dirty_tracker::DirtyTracker;
use crate::topology_cache::{LinSolverCache, SymbolicLu, TopologyHash};

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
            "resistance" | "capacitance" | "inductance"
            | "w" | "l" | "m" | "area" | "scale"
            | "dc" | "value" | "amplitude" => ParamChange::Scaling { factor },
            "temp" | "tnom" | "tj" => ParamChange::Temperature { ratio: factor },
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
    pub fn store_affine(&mut self, device: DeviceId, rows: usize, i0: &[f64], g: &[f64], v0: &[f64]) {
        self.compiled
            .store(DeviceIdx::from_id(device), rows, i0, g, v0);
    }

    /// Replay the cached affine model for `device`.  Returns `Some(())` on
    /// hit, `None` on miss; the caller falls back to a full eval on miss.
    pub fn replay_affine(&mut self, device: DeviceId, v: &[f64], out_i: &mut [f64]) -> Option<()> {
        self.compiled
            .replay(DeviceIdx::from_id(device), v, out_i)
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pisim_core::{
        DeviceInstance, DeviceKind, NodeId,
    };

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
}
