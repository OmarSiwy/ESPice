use pisim_device::DeviceEval;

/// Level 3 cache: operating point solution and per-device evaluations.
#[derive(Debug, Clone)]
pub struct OpCache {
    pub solution: Vec<f64>,
    pub device_evals: Vec<Option<DeviceEval>>,
    pub valid: bool,
}

impl OpCache {
    pub fn new(dim: usize, num_devices: usize) -> Self {
        Self {
            solution: vec![0.0; dim],
            device_evals: vec![None; num_devices],
            valid: false,
        }
    }

    pub fn store(&mut self, solution: &[f64], evals: Vec<DeviceEval>) {
        self.solution = solution.to_vec();
        self.device_evals = evals.into_iter().map(Some).collect();
        self.valid = true;
    }

    pub fn invalidate(&mut self) {
        self.valid = false;
    }

    pub fn get_solution(&self) -> Option<&[f64]> {
        if self.valid { Some(&self.solution) } else { None }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn op_cache_store_retrieve() {
        let mut c = OpCache::new(3, 2);
        assert!(!c.valid);
        assert!(c.get_solution().is_none());

        c.store(&[1.0, 2.0, 3.0], vec![DeviceEval::new(), DeviceEval::new()]);
        assert!(c.valid);
        assert_eq!(c.get_solution().unwrap(), &[1.0, 2.0, 3.0]);
    }

    #[test]
    fn op_cache_invalidate() {
        let mut c = OpCache::new(2, 1);
        c.store(&[1.0, 2.0], vec![DeviceEval::new()]);
        c.invalidate();
        assert!(c.get_solution().is_none());
    }
}
