//! `pisim-cache` — Phase 5 incremental simulation cache.
//!
//! This crate is the differentiator promised in `CLAUDE.md`:
//!
//! > "incremental spice runs are just calling a cached version of the spice
//! > version that should just plug in values into the cached equation."
//!
//! It provides five layers of cache, each independently usable, all
//! orchestrated by the public [`CacheManager`].
//!
//! | § | Module | Purpose |
//! |---|---|---|
//! | 5.1 | [`topology_cache`] | `TopologyHash` (FNV-1a 64) + `LinSolverCache` (symbolic LU reuse) |
//! | 5.2 | [`dirty_tracker`] | `BitSet`-backed `DirtyTracker` with adjacency propagation |
//! | 5.3 | [`compiled_eval`] | SoA cached `(I0, G, V0)` affine models per device |
//! | 5.4 | [`woodbury`] | Rank-k Sherman-Morrison-Woodbury LU update |
//! | 5.5 | [`checkpoint`] | Transient `TransientArena` with `nearest_before(t)` queries |
//! | 5.6 | [`manager`] | Public `CacheManager` façade for the solver / sweep runner |
//!
//! ## Design rules (from `CLAUDE.md`)
//!
//! - SoA `Vec<f64>` for every hot-path numeric block.
//! - Typed indices (`DeviceIdx(u32)`, `CheckpointIdx(u32)`).
//! - Zero `Box<dyn …>` and zero `HashMap` in hot loops.
//! - All public APIs accept `&[T]` / `&str`.
//! - Bit-stable hashing (FNV-1a, never `ahash`'s randomised seed).
//!
//! ## Solver wiring (the contract)
//!
//! The solver crate is *not* edited by this crate.  Instead, the planned
//! integration call sequence is:
//!
//! ```text
//!   let mut cache = CacheManager::new();
//!
//!   // Once per circuit build:
//!   if !cache.on_topology_built(&circuit) {
//!       let symbolic = solver.symbolic_factor(&circuit)?;
//!       cache.store_symbolic(symbolic);
//!   }
//!
//!   // For every parameter change between solves:
//!   cache.on_param_changed(dev_id, ParamChange::Scaling { factor });
//!
//!   // After every successful solve:
//!   cache.on_solve_complete(&solution);
//!
//!   // During transient:
//!   if step % checkpoint_period == 0 {
//!       cache.on_transient_step(t, &state, &charges, &events);
//!   }
//! ```
//!
//! All five layers stay consistent under this contract.

pub mod checkpoint;
pub mod compiled_eval;
pub mod dirty_tracker;
pub mod manager;
pub mod op_cache;
pub mod topology_cache;
pub mod woodbury;
pub mod incremental;

pub use checkpoint::{Checkpoint, CheckpointIdx, TransientArena};
pub use compiled_eval::{CompiledEvalCache, DeviceIdx, InvalidationReason, MAX_ROWS};
pub use dirty_tracker::DirtyTracker;
pub use manager::{CacheManager, ParamChange};
pub use op_cache::OpCache;
pub use topology_cache::{
    Fnv1a64, LinSolverCache, LinSolverCacheEntry, SymbolicLu, TopologyCache, TopologyHash,
    TOPOLOGY_VERSION,
};
pub use woodbury::{should_use_woodbury, WoodburyUpdate};
pub use incremental::{IncrementalCache, CacheState};
