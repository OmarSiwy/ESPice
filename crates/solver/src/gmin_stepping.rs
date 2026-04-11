use bigospice_linalg::TripletMatrix;

/// GMIN stepping convergence aid.
///
/// Adds a small conductance from every node to ground to improve
/// conditioning. Starts large, reduces geometrically until the
/// circuit solves with negligible GMIN.
#[derive(Debug, Clone)]
pub struct GminStepping {
    pub initial_gmin: f64,
    pub final_gmin: f64,
    pub reduction_factor: f64,
}

impl Default for GminStepping {
    fn default() -> Self {
        Self {
            initial_gmin: 1e-2,
            final_gmin: 1e-12,
            // Use a gentle reduction factor of ~3.16x (half-decade) instead
            // of 10x (full decade). This prevents the abrupt transition when
            // GMIN-dominated behavior gives way to device-dominated behavior,
            // which causes divergence in circuits with current sources driving
            // MOSFETs (e.g., diff pairs, current mirrors).
            reduction_factor: 3.1623,
        }
    }
}

impl GminStepping {
    /// Generate the geometric sequence of GMIN values.
    pub fn gmin_steps(&self) -> Vec<f64> {
        let mut steps = Vec::new();
        let mut g = self.initial_gmin;
        while g >= self.final_gmin {
            steps.push(g);
            g /= self.reduction_factor;
        }
        steps.push(self.final_gmin);
        steps
    }

    /// Add GMIN conductance on every diagonal entry (node→ground shunt).
    pub fn add_gmin_stamps(triplet: &mut TripletMatrix, gmin: f64, num_nodes: usize) {
        for i in 0..num_nodes {
            triplet.add(i, i, gmin);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gmin_step_sequence() {
        let gs = GminStepping::default();
        let steps = gs.gmin_steps();
        assert!(steps.len() > 2);
        assert!((steps[0] - 1e-2).abs() < 1e-15);
        assert!(*steps.last().unwrap() <= 1e-12 + 1e-20);
        // Each step is 10x smaller than previous
        for w in steps.windows(2) {
            assert!(w[1] < w[0]);
        }
    }

    #[test]
    fn gmin_stamps_diagonal() {
        let mut t = TripletMatrix::new(3, 3);
        GminStepping::add_gmin_stamps(&mut t, 0.01, 3);
        let csc = t.to_csc();
        for i in 0..3 {
            assert_eq!(csc.get(i, i), Some(0.01));
        }
    }
}
