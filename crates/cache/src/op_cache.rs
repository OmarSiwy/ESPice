//! Phase 5 — Operating point save/restore.
//!
//! Level 3 cache: stores the last successful Newton-Raphson solution vector
//! so subsequent solves can warm-start from it and skip early NR iterations.
//!
//! The original BigOSpice implementation stored per-device `DeviceEval`
//! structs alongside the solution.  In BigOSpiceRefactor the device eval
//! results are kept in `CompiledEvalCache`; `OpCache` stores only the
//! solution vector and a validity flag.

/// Operating point cache: solution vector + validity flag.
#[derive(Debug, Clone)]
pub struct OpCache {
    pub solution: Vec<f64>,
    pub valid: bool,
}

impl OpCache {
    pub fn new(dim: usize) -> Self {
        Self {
            solution: vec![0.0; dim],
            valid: false,
        }
    }

    /// Store a completed solution vector and mark the cache valid.
    pub fn store(&mut self, solution: &[f64]) {
        self.solution.clear();
        self.solution.extend_from_slice(solution);
        self.valid = true;
    }

    /// Mark the cache invalid (e.g. after a topology or parameter change
    /// that would make the stored point a bad warm start).
    pub fn invalidate(&mut self) {
        self.valid = false;
    }

    /// Return the cached solution for NR warm-start, or `None` if invalid.
    pub fn get_solution(&self) -> Option<&[f64]> {
        if self.valid {
            Some(&self.solution)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn op_cache_store_retrieve() {
        let mut c = OpCache::new(3);
        assert!(!c.valid);
        assert!(c.get_solution().is_none());

        c.store(&[1.0, 2.0, 3.0]);
        assert!(c.valid);
        assert_eq!(c.get_solution().unwrap(), &[1.0, 2.0, 3.0]);
    }

    #[test]
    fn op_cache_invalidate() {
        let mut c = OpCache::new(2);
        c.store(&[1.0, 2.0]);
        c.invalidate();
        assert!(c.get_solution().is_none());
    }

    #[test]
    fn op_cache_overwrite() {
        let mut c = OpCache::new(2);
        c.store(&[1.0, 2.0]);
        c.store(&[3.0, 4.0]);
        assert_eq!(c.get_solution().unwrap(), &[3.0, 4.0]);
    }

    #[test]
    fn op_cache_new_is_invalid() {
        let c = OpCache::new(5);
        assert!(!c.valid);
        assert!(c.get_solution().is_none());
        assert_eq!(c.solution.len(), 5);
    }

    #[test]
    fn op_cache_store_correct_length() {
        let mut c = OpCache::new(4);
        c.store(&[1.0, 2.0, 3.0, 4.0]);
        let sol = c.get_solution().unwrap();
        assert_eq!(sol.len(), 4);
        assert!((sol[2] - 3.0).abs() < 1e-15);
    }

    #[test]
    fn op_cache_invalidate_then_store_again() {
        let mut c = OpCache::new(2);
        c.store(&[5.0, 6.0]);
        c.invalidate();
        assert!(c.get_solution().is_none());
        c.store(&[7.0, 8.0]);
        assert!(c.valid);
        assert_eq!(c.get_solution().unwrap(), &[7.0, 8.0]);
    }

    #[test]
    fn op_cache_zero_dimension() {
        let mut c = OpCache::new(0);
        c.store(&[]);
        assert!(c.valid);
        assert_eq!(c.get_solution().unwrap().len(), 0);
    }

    #[test]
    fn op_cache_multiple_invalidate_store_cycles() {
        let mut c = OpCache::new(3);
        for i in 0..5 {
            c.store(&[i as f64, i as f64 + 1.0, i as f64 + 2.0]);
            assert!(c.valid);
            c.invalidate();
            assert!(!c.valid);
        }
    }

    #[test]
    fn op_cache_solution_correctly_extends() {
        // Store a vector smaller than the initial dim; check it grows correctly.
        let mut c = OpCache::new(4);
        c.store(&[1.0, 2.0, 3.0, 4.0]);
        let sol = c.get_solution().unwrap();
        assert_eq!(sol.len(), 4);
        assert!((sol[0] - 1.0).abs() < 1e-15);
        assert!((sol[3] - 4.0).abs() < 1e-15);
    }

    #[test]
    fn op_cache_store_does_not_keep_old_data() {
        let mut c = OpCache::new(3);
        c.store(&[100.0, 200.0, 300.0]);
        c.store(&[1.0, 2.0, 3.0]); // overwrite
        let sol = c.get_solution().unwrap();
        // Must not see old data
        assert!((sol[0] - 1.0).abs() < 1e-15);
        assert!((sol[2] - 3.0).abs() < 1e-15);
    }

    #[test]
    fn op_cache_valid_set_on_store() {
        let mut c = OpCache::new(2);
        assert!(!c.valid);
        c.store(&[0.0, 0.0]);
        assert!(c.valid);
    }
}
