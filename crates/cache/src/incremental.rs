//! Incremental cache logic — skip unchanged devices during a solve.
//!
//! `IncrementalCache` orchestrates the topology, dirty-tracking, and
//! operating-point sub-caches into a single state machine:
//!
//! ```text
//!   Empty → Topology → OperatingPoint
//!                ↑            |
//!                └────────────┘  (param change demotes back to Topology)
//! ```
//!
//! The `Full` state is a synonym for `OperatingPoint` in this refactor;
//! both indicate a valid warm-start solution is available.

use crate::dirty_tracker::DirtyTracker;
use crate::op_cache::OpCache;
use crate::topology_cache::TopologyCache;
use incspice_core::{Circuit, DeviceId};

/// Overall state of the incremental cache.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CacheState {
    Empty,
    Topology,
    OperatingPoint,
    Full,
}

/// Orchestrates the five-level incremental cache hierarchy.
#[derive(Debug, Clone)]
pub struct IncrementalCache {
    pub topology: Option<TopologyCache>,
    pub op: Option<OpCache>,
    pub dirty: DirtyTracker,
    pub state: CacheState,
}

impl IncrementalCache {
    pub fn new(num_devices: usize) -> Self {
        Self::with_size(num_devices, 0)
    }

    /// Construct with explicit device + node counts so the dirty tracker
    /// is sized correctly for the target circuit.
    pub fn with_size(num_devices: usize, num_nodes: usize) -> Self {
        Self {
            topology: None,
            op: None,
            dirty: DirtyTracker::new(num_devices, num_nodes),
            state: CacheState::Empty,
        }
    }

    pub fn on_topology_change(&mut self) {
        self.topology = None;
        self.op = None;
        self.state = CacheState::Empty;
    }

    /// Mark a single device parameter as changed.  Rebuilds adjacency if
    /// needed, marks the device dirty with two-hop propagation, and demotes
    /// the cache state to `Topology` so the next solve will re-evaluate all
    /// dirty devices.
    pub fn on_param_change(&mut self, _param: &str, circuit: &Circuit, device: DeviceId) {
        // Make sure the tracker's adjacency reflects the current circuit
        // before we mark anything (cheap if topology hasn't changed).
        self.dirty.rebuild_adjacency(circuit);
        self.dirty.mark_device(device);
        self.dirty.propagate();
        if self.state == CacheState::OperatingPoint || self.state == CacheState::Full {
            if let Some(ref mut op) = self.op {
                op.invalidate();
            }
            self.state = CacheState::Topology;
        }
    }

    pub fn store_topology(&mut self, circuit: &Circuit) {
        self.topology = Some(TopologyCache::from_circuit(circuit));
        self.state = CacheState::Topology;
    }

    /// Cache a completed operating-point solution for use as a warm start.
    pub fn store_op(&mut self, solution: &[f64]) {
        let mut op = OpCache::new(solution.len());
        op.store(solution);
        self.op = Some(op);
        self.dirty.clear();
        self.state = CacheState::OperatingPoint;
    }

    /// Return cached solution for Newton-Raphson warm start, or `None` if
    /// no valid operating point is cached.
    pub fn warm_start(&self) -> Option<&[f64]> {
        self.op.as_ref().and_then(|op| op.get_solution())
    }

    /// Returns `true` if a topology cache entry exists and matches `circuit`.
    pub fn topology_valid(&self, circuit: &Circuit) -> bool {
        self.topology
            .as_ref()
            .map(|t| t.is_valid(circuit))
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_state_transitions() {
        let mut cache = IncrementalCache::new(5);
        assert_eq!(cache.state, CacheState::Empty);
        assert!(cache.warm_start().is_none());

        let ckt = Circuit::new();
        cache.store_topology(&ckt);
        assert_eq!(cache.state, CacheState::Topology);

        cache.store_op(&[1.0, 2.0, 3.0]);
        assert_eq!(cache.state, CacheState::OperatingPoint);
        assert_eq!(cache.warm_start().unwrap(), &[1.0, 2.0, 3.0]);
    }

    #[test]
    fn topology_change_clears_all() {
        let mut cache = IncrementalCache::new(5);
        cache.store_op(&[1.0, 2.0]);
        cache.on_topology_change();
        assert_eq!(cache.state, CacheState::Empty);
        assert!(cache.warm_start().is_none());
    }

    #[test]
    fn param_change_demotes_to_topology() {
        use incspice_core::{DeviceId, DeviceInstance, DeviceKind, NodeId};
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
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

        let mut cache = IncrementalCache::new(1);
        cache.store_topology(&ckt);
        cache.store_op(&[5.0]);
        assert_eq!(cache.state, CacheState::OperatingPoint);

        cache.on_param_change("resistance", &ckt, DeviceId::new(0));
        assert_eq!(cache.state, CacheState::Topology);
        assert!(cache.warm_start().is_none());
    }
}
