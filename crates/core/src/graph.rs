use crate::device::DeviceId;
use crate::node::NodeId;
use serde::{Deserialize, Serialize};

/// Compressed Sparse Row graph representing circuit topology.
///
/// Rows = nodes, columns = devices connected to each node.
/// This is the Level 5 topology cache — changes only on structural netlist edits.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompressedGraph {
    /// Row pointers: `row_ptr[i]..row_ptr[i+1]` gives the range of devices for node i.
    pub row_ptr: Vec<u32>,
    /// Column indices: device IDs connected to each node.
    pub col_idx: Vec<DeviceId>,
    /// Number of nodes (rows).
    pub num_nodes: u32,
    /// Number of devices (logical columns).
    pub num_devices: u32,
}

impl CompressedGraph {
    /// Build a compressed graph from a list of (node, device) connections.
    pub fn from_connections(
        num_nodes: u32,
        num_devices: u32,
        connections: &[(NodeId, DeviceId)],
    ) -> Self {
        let n = num_nodes as usize;

        // Count entries per node.
        let mut counts = vec![0u32; n];
        for &(node, _) in connections {
            if !node.is_ground() {
                counts[node.index()] += 1;
            }
        }

        // Build row pointers (prefix sum).
        let mut row_ptr = Vec::with_capacity(n + 1);
        row_ptr.push(0);
        for &c in &counts {
            row_ptr.push(row_ptr.last().unwrap() + c);
        }

        // Fill column indices.
        let total = *row_ptr.last().unwrap() as usize;
        let mut col_idx = vec![DeviceId::new(0); total];
        let mut offsets = vec![0u32; n];

        for &(node, device) in connections {
            if !node.is_ground() {
                let idx = node.index();
                let pos = row_ptr[idx] + offsets[idx];
                col_idx[pos as usize] = device;
                offsets[idx] += 1;
            }
        }

        Self {
            row_ptr,
            col_idx,
            num_nodes,
            num_devices,
        }
    }

    /// Get the devices connected to a given node.
    pub fn devices_at(&self, node: NodeId) -> &[DeviceId] {
        if node.is_ground() || node.index() >= self.num_nodes as usize {
            return &[];
        }
        let start = self.row_ptr[node.index()] as usize;
        let end = self.row_ptr[node.index() + 1] as usize;
        &self.col_idx[start..end]
    }

    /// Total number of connections.
    pub fn nnz(&self) -> usize {
        self.col_idx.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn graph_from_connections() {
        // Simple circuit: R1 between node 1 and 2, R2 between node 2 and GND
        let connections = vec![
            (NodeId::new(1), DeviceId::new(0)),
            (NodeId::new(2), DeviceId::new(0)),
            (NodeId::new(2), DeviceId::new(1)),
        ];

        let g = CompressedGraph::from_connections(3, 2, &connections);

        assert_eq!(g.devices_at(NodeId::new(1)).len(), 1);
        assert_eq!(g.devices_at(NodeId::new(2)).len(), 2);
        assert_eq!(g.devices_at(NodeId::GROUND).len(), 0);
    }

    #[test]
    fn graph_empty() {
        let g = CompressedGraph::from_connections(1, 0, &[]);
        assert_eq!(g.nnz(), 0);
    }

    #[test]
    fn devices_at_ground_always_empty() {
        let connections = vec![(NodeId::GROUND, DeviceId::new(0))];
        let g = CompressedGraph::from_connections(2, 1, &connections);
        assert_eq!(g.devices_at(NodeId::GROUND).len(), 0);
    }

    #[test]
    fn devices_at_out_of_range_node_returns_empty() {
        let g = CompressedGraph::from_connections(2, 0, &[]);
        // NodeId(99) is beyond num_nodes=2
        assert_eq!(g.devices_at(NodeId::new(99)).len(), 0);
    }

    #[test]
    fn nnz_counts_non_ground_connections() {
        // Connect same device to two non-ground nodes and one ground node.
        let connections = vec![
            (NodeId::new(1), DeviceId::new(0)),
            (NodeId::new(2), DeviceId::new(0)),
            (NodeId::GROUND, DeviceId::new(0)), // ground → must be excluded from nnz
        ];
        let g = CompressedGraph::from_connections(3, 1, &connections);
        assert_eq!(g.nnz(), 2);
    }

    #[test]
    fn num_nodes_and_num_devices_stored() {
        let g = CompressedGraph::from_connections(5, 3, &[]);
        assert_eq!(g.num_nodes, 5);
        assert_eq!(g.num_devices, 3);
    }

    #[test]
    fn devices_at_correct_device_ids() {
        let d0 = DeviceId::new(0);
        let d1 = DeviceId::new(1);
        let connections = vec![
            (NodeId::new(1), d0),
            (NodeId::new(1), d1),
        ];
        let g = CompressedGraph::from_connections(2, 2, &connections);
        let devs = g.devices_at(NodeId::new(1));
        assert_eq!(devs.len(), 2);
        // Both d0 and d1 must appear (order may vary).
        assert!(devs.contains(&d0));
        assert!(devs.contains(&d1));
    }

    #[test]
    fn row_ptr_has_correct_length() {
        let g = CompressedGraph::from_connections(4, 2, &[]);
        // row_ptr should have num_nodes+1 entries
        assert_eq!(g.row_ptr.len(), 5);
    }
}
