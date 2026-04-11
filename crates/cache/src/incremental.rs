use bigospice_core::{Circuit, DeviceId};
use crate::dirty_tracker::DirtyTracker;
use crate::op_cache::OpCache;
use crate::topology_cache::TopologyCache;

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

    /// Mark a single device parameter as changed.  The parameter name is
    /// not currently used by the dirty tracker (which works at device
    /// granularity); it is accepted for future per-parameter dependency
    /// tracking.
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

    pub fn store_op(&mut self, solution: &[f64]) {
        let dim = solution.len();
        let mut op = OpCache::new(dim, 0);
        op.store(solution, vec![]);
        self.op = Some(op);
        self.dirty.clear();
        self.state = CacheState::OperatingPoint;
    }

    /// Return cached solution for Newton-Raphson warm start.
    pub fn warm_start(&self) -> Option<&[f64]> {
        self.op.as_ref().and_then(|op| op.get_solution())
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
}
