/// Source stepping convergence aid.
///
/// When initial Newton-Raphson fails, ramp all independent sources from 0
/// to their final value in graduated steps.
#[derive(Debug, Clone)]
pub struct SourceStepping {
    pub steps: Vec<f64>,
}

impl Default for SourceStepping {
    fn default() -> Self {
        Self {
            steps: vec![0.001, 0.01, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 1.0],
        }
    }
}

impl SourceStepping {
    pub fn new(steps: Vec<f64>) -> Self {
        Self { steps }
    }

    /// Scale a source value by the current step fraction.
    #[inline]
    pub fn scale(&self, step_idx: usize, full_value: f64) -> f64 {
        full_value * self.steps[step_idx]
    }

    pub fn num_steps(&self) -> usize {
        self.steps.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_steps() {
        let ss = SourceStepping::default();
        assert_eq!(ss.num_steps(), 10);
        assert!((ss.steps[0] - 0.001).abs() < 1e-15);
        assert!((ss.steps[ss.num_steps() - 1] - 1.0).abs() < 1e-15);
    }

    #[test]
    fn scale_value() {
        let ss = SourceStepping::default();
        let v = ss.scale(4, 5.0); // step 4 = 0.2
        assert!((v - 1.0).abs() < 1e-15);
    }
}
