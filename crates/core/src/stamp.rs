use crate::device::DeviceId;
use serde::{Deserialize, Serialize};
use std::fmt;

/// Which kind of contribution a stamp makes to the MNA system.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum StampType {
    /// Conductance (G matrix) — resistive contribution.
    Conductance,
    /// Capacitance (C matrix) — reactive contribution.
    Capacitance,
    /// Right-hand side (source vector).
    Rhs,
    /// Branch equation row/column (for voltage sources, inductors).
    Branch,
}

/// A single entry that a device stamps into the MNA matrix.
///
/// Records (row, col) position and which device produced it,
/// enabling incremental updates when that device's parameters change.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StampEntry {
    pub row: u32,
    pub col: u32,
    pub device: DeviceId,
    pub kind: StampType,
}

impl StampEntry {
    pub fn conductance(row: u32, col: u32, device: DeviceId) -> Self {
        Self {
            row,
            col,
            device,
            kind: StampType::Conductance,
        }
    }

    pub fn capacitance(row: u32, col: u32, device: DeviceId) -> Self {
        Self {
            row,
            col,
            device,
            kind: StampType::Capacitance,
        }
    }

    pub fn rhs(row: u32, device: DeviceId) -> Self {
        Self {
            row,
            col: 0,
            device,
            kind: StampType::Rhs,
        }
    }

    pub fn branch(row: u32, col: u32, device: DeviceId) -> Self {
        Self {
            row,
            col,
            device,
            kind: StampType::Branch,
        }
    }

    /// Matrix position as (row, col) tuple.
    #[inline]
    pub fn pos(&self) -> (usize, usize) {
        (self.row as usize, self.col as usize)
    }
}

impl fmt::Display for StampEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Stamp({},{}) {:?} from {}",
            self.row, self.col, self.kind, self.device
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stamp_entry_creation() {
        let s = StampEntry::conductance(0, 1, DeviceId::new(3));
        assert_eq!(s.pos(), (0, 1));
        assert_eq!(s.kind, StampType::Conductance);
        assert_eq!(s.device, DeviceId::new(3));
    }

    #[test]
    fn stamp_rhs() {
        let s = StampEntry::rhs(2, DeviceId::new(0));
        assert_eq!(s.kind, StampType::Rhs);
        assert_eq!(s.row, 2);
    }

    #[test]
    fn stamp_capacitance_fields() {
        let s = StampEntry::capacitance(3, 4, DeviceId::new(2));
        assert_eq!(s.kind, StampType::Capacitance);
        assert_eq!(s.pos(), (3, 4));
        assert_eq!(s.device, DeviceId::new(2));
    }

    #[test]
    fn stamp_branch_fields() {
        let s = StampEntry::branch(5, 6, DeviceId::new(1));
        assert_eq!(s.kind, StampType::Branch);
        assert_eq!(s.row, 5);
        assert_eq!(s.col, 6);
        assert_eq!(s.pos(), (5, 6));
    }

    #[test]
    fn stamp_rhs_col_is_zero() {
        let s = StampEntry::rhs(7, DeviceId::new(0));
        assert_eq!(s.col, 0, "RHS entries always have col=0");
    }

    #[test]
    fn stamp_display_contains_row_col_kind() {
        let s = StampEntry::conductance(1, 2, DeviceId::new(0));
        let display = format!("{s}");
        assert!(display.contains("1"));
        assert!(display.contains("2"));
        assert!(display.contains("Conductance") || display.contains("conductance"),
            "display should mention kind: got {display}");
    }

    #[test]
    fn stamp_equality_and_hash() {
        use std::collections::HashSet;
        let a = StampEntry::conductance(0, 1, DeviceId::new(0));
        let b = StampEntry::conductance(0, 1, DeviceId::new(0));
        let c = StampEntry::conductance(0, 2, DeviceId::new(0));
        let mut set = HashSet::new();
        set.insert(a);
        set.insert(b); // duplicate of a
        set.insert(c);
        assert_eq!(set.len(), 2);
    }

    #[test]
    fn stamp_type_variants_are_distinct() {
        assert_ne!(StampType::Conductance, StampType::Capacitance);
        assert_ne!(StampType::Rhs, StampType::Branch);
        assert_ne!(StampType::Conductance, StampType::Rhs);
    }
}
