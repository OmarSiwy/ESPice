//! Phase 5.2 — Dirty tracking.
//!
//! Per-device + per-node bitset tracking which devices have to be re-evaluated
//! after a parameter change, and which MNA rows have to be re-stamped as a
//! consequence.
//!
//! ## Data layout (DOD)
//!
//! - `devices: BitVec` — one bit per device, indexed by `DeviceId`.
//! - `nodes:   BitVec` — one bit per non-ground node, indexed by `(NodeId.0 - 1)`.
//! - `adjacency: Vec<SmallVec<[u32; 4]>>` — for every device, the list of
//!   non-ground node indices it touches.  Built once at `build()` time and
//!   reused across every dirty propagation.
//!
//! Both bitsets use `bitvec`, which gives us O(popcount) iteration via
//! `iter_ones()`.

use bitvec::prelude::*;
use pisim_core::{Circuit, DeviceId};
use smallvec::SmallVec;

/// Bitset-backed dirty tracker for devices and nodes.
#[derive(Debug, Clone)]
pub struct DirtyTracker {
    devices: BitVec,
    nodes: BitVec,
    /// `adjacency[device_idx]` → list of non-ground node row indices that
    /// device touches in MNA.  Pre-computed once at `rebuild_adjacency`.
    adjacency: Vec<SmallVec<[u32; 4]>>,
    /// Per-device list of *other* devices that share at least one node.
    /// Used by `propagate()` for two-hop dirty propagation.
    device_neighbours: Vec<SmallVec<[u32; 4]>>,
}

impl DirtyTracker {
    /// Allocate an empty tracker sized for `num_devices` and `num_nodes`
    /// (non-ground only).  Adjacency is empty until `rebuild_adjacency`
    /// is called.
    pub fn new(num_devices: usize, num_nodes: usize) -> Self {
        Self {
            devices: bitvec![0; num_devices],
            nodes: bitvec![0; num_nodes],
            adjacency: vec![SmallVec::new(); num_devices],
            device_neighbours: vec![SmallVec::new(); num_devices],
        }
    }

    /// Build (or rebuild) the device→node and device→device adjacency tables
    /// from the supplied circuit.  Called once after every topology change.
    pub fn rebuild_adjacency(&mut self, circuit: &Circuit) {
        let num_devices = circuit.devices().len();
        let num_nodes = circuit.nodes().len();

        // Resize bitsets if the circuit grew/shrank.
        self.devices.clear();
        self.devices.resize(num_devices, false);
        self.nodes.clear();
        self.nodes.resize(num_nodes.saturating_sub(1), false);
        self.adjacency.clear();
        self.adjacency.resize(num_devices, SmallVec::new());
        self.device_neighbours.clear();
        self.device_neighbours.resize(num_devices, SmallVec::new());

        // First pass: device → nodes
        for (di, dev) in circuit.devices().iter().enumerate() {
            let entry = &mut self.adjacency[di];
            for term in &dev.terminals {
                if !term.node.is_ground() {
                    let row = term.node.0 - 1;
                    if !entry.contains(&row) {
                        entry.push(row);
                    }
                }
            }
        }

        // Second pass: node → devices reverse index, then collapse to
        // device → device neighbour lists.
        let n_rows = self.nodes.len();
        let mut node_to_devs: Vec<SmallVec<[u32; 4]>> = vec![SmallVec::new(); n_rows];
        for (di, rows) in self.adjacency.iter().enumerate() {
            for &r in rows {
                node_to_devs[r as usize].push(di as u32);
            }
        }
        for di in 0..num_devices {
            let mut nbrs: SmallVec<[u32; 4]> = SmallVec::new();
            for &r in &self.adjacency[di] {
                for &other in &node_to_devs[r as usize] {
                    if other != di as u32 && !nbrs.contains(&other) {
                        nbrs.push(other);
                    }
                }
            }
            self.device_neighbours[di] = nbrs;
        }
    }

    /// Mark a parameter change on `device_idx`.
    ///
    /// This is the canonical entry point used by the analysis layer when a
    /// parameter is mutated.  The caller passes the *current* `num_devices`
    /// so the tracker can lazily resize itself if the circuit grew between
    /// calls.  Marks the owning device dirty and propagates to its node
    /// neighbours via the precomputed adjacency.
    ///
    /// The signature is intentionally `(device_idx, num_devices)` and is
    /// kept stable across the entire crate (see `manager::on_param_changed`,
    /// which forwards here).
    pub fn mark_param_changed(&mut self, device_idx: u32, num_devices: usize) {
        // Lazy resize on capacity overflow.
        if self.devices.len() < num_devices {
            self.devices.resize(num_devices, false);
            self.adjacency.resize(num_devices, SmallVec::new());
            self.device_neighbours.resize(num_devices, SmallVec::new());
        }
        self.mark_device(DeviceId::new(device_idx));
    }

    /// Mark a single device dirty and propagate to every node it touches.
    pub fn mark_device(&mut self, device: DeviceId) {
        let idx = device.index();
        if idx >= self.devices.len() {
            return;
        }
        self.devices.set(idx, true);
        if let Some(rows) = self.adjacency.get(idx) {
            for &r in rows {
                let r = r as usize;
                if r < self.nodes.len() {
                    self.nodes.set(r, true);
                }
            }
        }
    }

    /// Mark every device that touches `node` (zero-based MNA row) dirty.
    pub fn mark_node(&mut self, node_row: usize) {
        if node_row < self.nodes.len() {
            self.nodes.set(node_row, true);
        }
        for (di, rows) in self.adjacency.iter().enumerate() {
            if rows.iter().any(|&r| r as usize == node_row) {
                self.devices.set(di, true);
            }
        }
    }

    /// Two-hop propagation: every device that shares a node with a currently
    /// dirty device is also marked dirty.  Used when a parameter change in
    /// one device alters the operating point of its neighbours.
    pub fn propagate(&mut self) {
        // Snapshot the current dirty set so we don't propagate transitively
        // in a single call.
        let initial: SmallVec<[u32; 16]> =
            self.devices.iter_ones().map(|i| i as u32).collect();
        for d in initial {
            for &nbr in &self.device_neighbours[d as usize] {
                self.devices.set(nbr as usize, true);
                if let Some(rows) = self.adjacency.get(nbr as usize) {
                    for &r in rows {
                        let r = r as usize;
                        if r < self.nodes.len() {
                            self.nodes.set(r, true);
                        }
                    }
                }
            }
        }
    }

    pub fn is_dirty(&self, device: DeviceId) -> bool {
        let idx = device.index();
        idx < self.devices.len() && self.devices[idx]
    }

    pub fn is_node_dirty(&self, row: usize) -> bool {
        row < self.nodes.len() && self.nodes[row]
    }

    pub fn iter_dirty_devices(&self) -> impl Iterator<Item = DeviceId> + '_ {
        self.devices
            .iter_ones()
            .map(|i| DeviceId::new(i as u32))
    }

    pub fn iter_dirty_nodes(&self) -> impl Iterator<Item = usize> + '_ {
        self.nodes.iter_ones()
    }

    pub fn dirty_device_count(&self) -> usize {
        self.devices.count_ones()
    }

    pub fn dirty_node_count(&self) -> usize {
        self.nodes.count_ones()
    }

    pub fn clear(&mut self) {
        self.devices.fill(false);
        self.nodes.fill(false);
    }

    /// Total number of devices in the tracker.
    pub fn num_devices(&self) -> usize {
        self.devices.len()
    }

    /// Adjacency lookup for diagnostics.
    pub fn adjacent_nodes(&self, device: DeviceId) -> &[u32] {
        self.adjacency
            .get(device.index())
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }

    /// Mark every device dirty (used on a topology-cache miss).
    pub fn mark_all_dirty(&mut self) {
        self.devices.fill(true);
        self.nodes.fill(true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dirty_tracker_basic() {
        let mut dt = DirtyTracker::new(5, 3);
        assert_eq!(dt.dirty_device_count(), 0);
        assert!(!dt.is_dirty(DeviceId::new(2)));

        dt.mark_device(DeviceId::new(2));
        assert!(dt.is_dirty(DeviceId::new(2)));
        assert_eq!(dt.dirty_device_count(), 1);

        dt.clear();
        assert_eq!(dt.dirty_device_count(), 0);
    }

    #[test]
    fn mark_param_changed_signature() {
        // The (device_idx, num_devices) signature is the canonical entry point.
        let mut dt = DirtyTracker::new(5, 3);
        dt.mark_param_changed(2, 5);
        assert!(dt.is_dirty(DeviceId::new(2)));
        assert_eq!(dt.dirty_device_count(), 1);

        // Lazy resize: pass a larger num_devices and the tracker grows.
        dt.mark_param_changed(7, 8);
        assert_eq!(dt.num_devices(), 8);
        assert!(dt.is_dirty(DeviceId::new(7)));
    }

    #[test]
    fn dirty_tracker_iteration() {
        let mut dt = DirtyTracker::new(5, 3);
        dt.mark_device(DeviceId::new(1));
        dt.mark_device(DeviceId::new(3));
        let ids: Vec<_> = dt.iter_dirty_devices().collect();
        assert_eq!(ids, vec![DeviceId::new(1), DeviceId::new(3)]);
    }
}
