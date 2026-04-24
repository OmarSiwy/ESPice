use serde::{Deserialize, Serialize};
use std::fmt;

/// Index into the node array. Ground is always index 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[repr(transparent)]
pub struct NodeId(pub u32);

impl NodeId {
    pub const GROUND: Self = Self(0);

    #[inline]
    pub fn new(index: u32) -> Self {
        Self(index)
    }

    #[inline]
    pub fn index(self) -> usize {
        self.0 as usize
    }

    #[inline]
    pub fn is_ground(self) -> bool {
        self.0 == 0
    }
}

impl fmt::Display for NodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_ground() {
            write!(f, "GND")
        } else {
            write!(f, "n{}", self.0)
        }
    }
}

impl From<u32> for NodeId {
    fn from(v: u32) -> Self {
        Self(v)
    }
}

impl From<NodeId> for usize {
    fn from(n: NodeId) -> usize {
        n.0 as usize
    }
}

/// Sentinel value representing the ground node.
#[allow(non_upper_case_globals)]
pub const Ground: NodeId = NodeId::GROUND;

/// A circuit node with its name and matrix row assignment.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Node {
    pub id: NodeId,
    pub name: String,
    /// Row/column index in the MNA matrix (None for ground).
    pub matrix_index: Option<u32>,
}

impl Node {
    pub fn new(id: NodeId, name: impl Into<String>) -> Self {
        let matrix_index = if id.is_ground() { None } else { Some(id.0 - 1) };
        Self {
            id,
            name: name.into(),
            matrix_index,
        }
    }

    pub fn ground() -> Self {
        Self {
            id: NodeId::GROUND,
            name: "0".into(),
            matrix_index: None,
        }
    }
}

impl PartialEq for Node {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl Eq for Node {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ground_is_zero() {
        assert!(NodeId::GROUND.is_ground());
        assert_eq!(NodeId::GROUND.index(), 0);
    }

    #[test]
    fn node_display() {
        assert_eq!(format!("{}", NodeId::GROUND), "GND");
        assert_eq!(format!("{}", NodeId::new(3)), "n3");
    }

    #[test]
    fn node_matrix_index() {
        let g = Node::ground();
        assert!(g.matrix_index.is_none());

        let n1 = Node::new(NodeId::new(1), "vdd");
        assert_eq!(n1.matrix_index, Some(0));

        let n5 = Node::new(NodeId::new(5), "out");
        assert_eq!(n5.matrix_index, Some(4));
    }

    #[test]
    fn test_ground_is_zero() {
        assert_eq!(NodeId::GROUND.0, 0);
        assert!(NodeId::GROUND.is_ground());
    }

    #[test]
    fn test_non_ground_node() {
        let n = NodeId(1);
        assert!(!n.is_ground());
        assert_eq!(n.index(), 1);
    }

    #[test]
    fn test_node_ordering() {
        assert!(NodeId(1) < NodeId(2));
        assert!(NodeId::GROUND < NodeId(1));
    }

    #[test]
    fn node_id_from_u32() {
        let n: NodeId = 7u32.into();
        assert_eq!(n.index(), 7);
        assert!(!n.is_ground());
    }

    #[test]
    fn node_id_into_usize() {
        let n = NodeId::new(4);
        let idx: usize = n.into();
        assert_eq!(idx, 4);
    }

    #[test]
    fn ground_constant_equals_zero() {
        assert_eq!(NodeId::GROUND.0, 0);
        assert_eq!(crate::node::Ground, NodeId::GROUND);
    }

    #[test]
    fn node_display_ground_shows_gnd() {
        assert_eq!(format!("{}", NodeId::GROUND), "GND");
    }

    #[test]
    fn node_display_nonzero_shows_index() {
        assert_eq!(format!("{}", NodeId::new(42)), "n42");
    }

    #[test]
    fn node_ground_fn_has_correct_fields() {
        let g = Node::ground();
        assert!(g.id.is_ground());
        assert_eq!(g.name, "0");
        assert!(g.matrix_index.is_none());
    }

    #[test]
    fn node_equality_based_on_id() {
        let a = Node::new(NodeId::new(3), "vdd");
        let b = Node::new(NodeId::new(3), "something_else");
        assert_eq!(a, b, "Nodes with same ID must be equal regardless of name");

        let c = Node::new(NodeId::new(4), "vdd");
        assert_ne!(a, c, "Nodes with different IDs must not be equal");
    }

    #[test]
    fn node_matrix_index_node1_is_zero() {
        let n1 = Node::new(NodeId::new(1), "n1");
        assert_eq!(n1.matrix_index, Some(0));
    }

    #[test]
    fn node_matrix_index_node10_is_nine() {
        let n10 = Node::new(NodeId::new(10), "n10");
        assert_eq!(n10.matrix_index, Some(9));
    }

    #[test]
    fn node_id_equality_and_hash() {
        use std::collections::HashSet;
        let mut set = HashSet::new();
        set.insert(NodeId::new(1));
        set.insert(NodeId::new(1));
        set.insert(NodeId::new(2));
        assert_eq!(set.len(), 2);
    }
}
