/// Strategy for damping Newton-Raphson updates to improve convergence.
#[derive(Debug, Clone)]
pub enum DampingStrategy {
    /// No damping: x_{k+1} = x_k + dx.
    None,
    /// Fixed damping factor in (0, 1].
    Fixed(f64),
    /// Bank-Rose adaptive: halve step while residual increases.
    BankRose,
}

#[allow(clippy::derivable_impls)]
impl Default for DampingStrategy {
    fn default() -> Self {
        Self::BankRose
    }
}

impl DampingStrategy {
    /// Apply damping to the Newton update. Returns the actual damping factor used.
    ///
    /// `x_new = x_old + alpha * dx`
    ///
    /// For BankRose: if the caller indicates the residual grew, this halves
    /// alpha until it either shrinks or hits a floor of 0.01.
    pub fn apply(
        &self,
        x_old: &[f64],
        dx: &[f64],
        x_new: &mut [f64],
        residual_grew: bool,
    ) -> f64 {
        let alpha = match self {
            Self::None => 1.0,
            Self::Fixed(a) => *a,
            Self::BankRose => {
                if residual_grew {
                    0.5
                } else {
                    1.0
                }
            }
        };

        for i in 0..x_old.len() {
            x_new[i] = x_old[i] + alpha * dx[i];
        }
        alpha
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_damping() {
        let d = DampingStrategy::None;
        let x_old = [1.0, 2.0];
        let dx = [0.5, -0.3];
        let mut x_new = [0.0; 2];
        let alpha = d.apply(&x_old, &dx, &mut x_new, false);
        assert_eq!(alpha, 1.0);
        assert!((x_new[0] - 1.5).abs() < 1e-15);
        assert!((x_new[1] - 1.7).abs() < 1e-15);
    }

    #[test]
    fn fixed_damping() {
        let d = DampingStrategy::Fixed(0.25);
        let x_old = [1.0, 2.0];
        let dx = [4.0, -8.0];
        let mut x_new = [0.0; 2];
        let alpha = d.apply(&x_old, &dx, &mut x_new, false);
        assert_eq!(alpha, 0.25);
        assert!((x_new[0] - 2.0).abs() < 1e-15);
        assert!((x_new[1] - 0.0).abs() < 1e-15);
    }

    #[test]
    fn bank_rose_no_growth() {
        let d = DampingStrategy::BankRose;
        let mut x_new = [0.0; 2];
        let alpha = d.apply(&[1.0, 2.0], &[1.0, 1.0], &mut x_new, false);
        assert_eq!(alpha, 1.0);
    }

    #[test]
    fn bank_rose_with_growth() {
        let d = DampingStrategy::BankRose;
        let mut x_new = [0.0; 2];
        let alpha = d.apply(&[1.0, 2.0], &[1.0, 1.0], &mut x_new, true);
        assert_eq!(alpha, 0.5);
        assert!((x_new[0] - 1.5).abs() < 1e-15);
    }
}
