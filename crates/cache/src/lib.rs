//! `incspice-cache` — Phase 5 incremental simulation cache.
//!
//! This crate is the differentiator promised in `CLAUDE.md`:
//!
//! > "incremental spice runs are just calling a cached version of the spice
//! > version that should just plug in values into the cached equation."
//!
//! It provides six layers of cache, each independently usable, all
//! orchestrated by the public [`CacheManager`].
//!
//! | § | Module | Purpose |
//! |---|---|---|
//! | 5.1 | [`topology_cache`] | `TopologyHash` (FNV-1a 64) + `LinSolverCache` (symbolic LU reuse) |
//! | 5.2 | [`dirty_tracker`] | `BitVec`-backed `DirtyTracker` with adjacency propagation |
//! | 5.3 | [`compiled_eval`] | SoA cached `(I0, G, V0)` affine models per device |
//! | 5.4 | [`woodbury`] | Rank-k Sherman-Morrison-Woodbury LU update |
//! | 5.5 | [`checkpoint`] | Transient `TransientArena` with `nearest_before(t)` queries |
//! | 5.6 | [`manager`] | Public `CacheManager` façade for the solver / sweep runner |
//! |     | [`op_cache`] | Operating-point save/restore (`OpCache`) |
//! |     | [`incremental`] | `IncrementalCache` state machine (Empty→Topology→OperatingPoint) |

pub mod checkpoint;
pub mod compiled_eval;
pub mod dirty_tracker;
pub mod incremental;
pub mod manager;
pub mod op_cache;
pub mod topology_cache;
pub mod woodbury;

pub use checkpoint::{Checkpoint, CheckpointIdx, CheckpointSnapshot, TransientArena};
pub use compiled_eval::{CompiledEvalCache, DeviceIdx, InvalidationReason, MAX_ROWS};
pub use dirty_tracker::DirtyTracker;
pub use incremental::{CacheState, IncrementalCache};
pub use manager::{CacheManager, ParamChange};
pub use op_cache::OpCache;
pub use topology_cache::{
    Fnv1a64, LinSolverCache, LinSolverCacheEntry, SymbolicLu, TopologyCache, TopologyHash,
    TOPOLOGY_VERSION,
};
pub use woodbury::{should_use_woodbury, WoodburyUpdate};
