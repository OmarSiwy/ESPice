use crate::linalg::TripletMatrix;

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
        // Each step is smaller than previous
        for w in steps.windows(2) {
            assert!(w[1] < w[0]);
        }
    }

    #[test]
    fn gmin_stamps_diagonal() {
        let mut t = TripletMatrix::with_capacity(3, 3, 3);
        GminStepping::add_gmin_stamps(&mut t, 0.01, 3);
        let csc = t.to_csc();
        for i in 0..3 {
            assert_eq!(csc.get(i, i), Some(0.01));
        }
    }

    #[test]
    fn gmin_steps_end_value_is_final_gmin() {
        let gs = GminStepping::default();
        let steps = gs.gmin_steps();
        assert!(*steps.last().unwrap() <= gs.final_gmin + 1e-25);
    }

    #[test]
    fn gmin_steps_start_value_is_initial_gmin() {
        let gs = GminStepping::default();
        let steps = gs.gmin_steps();
        assert!((steps[0] - gs.initial_gmin).abs() < 1e-20);
    }

    #[test]
    fn gmin_steps_all_positive() {
        let gs = GminStepping::default();
        for &g in gs.gmin_steps().iter() {
            assert!(g > 0.0, "gmin step must be positive: {g}");
        }
    }

    #[test]
    fn gmin_custom_stepping() {
        let gs = GminStepping {
            initial_gmin: 1.0,
            final_gmin: 1e-4,
            reduction_factor: 10.0,
        };
        let steps = gs.gmin_steps();
        // Should have approximately log10(1/1e-4) = 4 steps plus the final
        assert!(steps.len() >= 4, "expected at least 4 steps: got {}", steps.len());
        // Steps should be non-increasing (the last appended final_gmin may equal
        // the previous step if the loop stopped exactly at final_gmin)
        for w in steps.windows(2) {
            assert!(w[1] <= w[0], "steps must be non-increasing: {:?}", steps);
        }
    }

    #[test]
    fn gmin_add_stamps_zero_nodes() {
        // Should not panic for 0 nodes
        let mut t = TripletMatrix::new(5, 5);
        GminStepping::add_gmin_stamps(&mut t, 0.01, 0);
        assert_eq!(t.nnz(), 0);
    }

    #[test]
    fn gmin_add_stamps_accumulate_with_existing() {
        // Adding GMIN stamps to an existing matrix with diagonal entries
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 1.0);
        t.add(1, 1, 2.0);
        GminStepping::add_gmin_stamps(&mut t, 0.1, 2);
        let csc = t.to_csc();
        // Diagonal should be original + gmin
        assert!((csc.get(0, 0).unwrap() - 1.1).abs() < 1e-14);
        assert!((csc.get(1, 1).unwrap() - 2.1).abs() < 1e-14);
    }

    #[test]
    fn gmin_stepping_clone() {
        let gs = GminStepping::default();
        let gc = gs.clone();
        assert_eq!(gc.initial_gmin, gs.initial_gmin);
        assert_eq!(gc.final_gmin, gs.final_gmin);
        assert_eq!(gc.reduction_factor, gs.reduction_factor);
    }

    #[test]
    fn gmin_stepping_debug() {
        let gs = GminStepping::default();
        let s = format!("{:?}", gs);
        assert!(s.contains("initial_gmin"));
    }
}
