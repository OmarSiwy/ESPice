/// Placeholder for the Woodbury low-rank update engine.
///
/// When a small number of matrix entries change (e.g. a single device
/// parameter sweep), the Woodbury formula can update the existing LU
/// factorisation in O(n * k^2) instead of refactorising in O(n^3).
///
/// This is a stub — the full implementation will land when incremental
/// parameter sweeps are wired up in the analysis layer.
#[derive(Debug, Clone)]
pub struct WoodburyUpdater {
    /// Dimension of the original system.
    pub n: usize,
}

impl WoodburyUpdater {
    /// Create a new updater for a system of dimension `n`.
    pub fn new(n: usize) -> Self {
        Self { n }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn woodbury_creation() {
        let w = WoodburyUpdater::new(10);
        assert_eq!(w.n, 10);
    }
}
