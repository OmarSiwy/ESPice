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
        Self { row, col, device, kind: StampType::Conductance }
    }

    pub fn capacitance(row: u32, col: u32, device: DeviceId) -> Self {
        Self { row, col, device, kind: StampType::Capacitance }
    }

    pub fn rhs(row: u32, device: DeviceId) -> Self {
        Self { row, col: 0, device, kind: StampType::Rhs }
    }

    pub fn branch(row: u32, col: u32, device: DeviceId) -> Self {
        Self { row, col, device, kind: StampType::Branch }
    }

    /// Matrix position as (row, col) tuple.
    #[inline]
    pub fn pos(&self) -> (usize, usize) {
        (self.row as usize, self.col as usize)
    }
}

impl fmt::Display for StampEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Stamp({},{}) {:?} from {}", self.row, self.col, self.kind, self.device)
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
}
