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
    /// For BankRose: uses `consecutive_growth` count to progressively reduce
    /// alpha (0.5, 0.25, 0.125, ...) down to a floor of 1/64.
    pub fn apply(
        &self,
        x_old: &[f64],
        dx: &[f64],
        x_new: &mut [f64],
        consecutive_growth: u32,
    ) -> f64 {
        let alpha = match self {
            Self::None => 1.0,
            Self::Fixed(a) => *a,
            Self::BankRose => {
                if consecutive_growth == 0 {
                    1.0
                } else {
                    // 0.5^consecutive_growth, floor at 1/64
                    (0.5_f64.powi(consecutive_growth as i32)).max(1.0 / 64.0)
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
        let alpha = d.apply(&x_old, &dx, &mut x_new, 0);
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
        let alpha = d.apply(&x_old, &dx, &mut x_new, 0);
        assert_eq!(alpha, 0.25);
        assert!((x_new[0] - 2.0).abs() < 1e-15);
        assert!((x_new[1] - 0.0).abs() < 1e-15);
    }

    #[test]
    fn bank_rose_no_growth() {
        let d = DampingStrategy::BankRose;
        let mut x_new = [0.0; 2];
        let alpha = d.apply(&[1.0, 2.0], &[1.0, 1.0], &mut x_new, 0);
        assert_eq!(alpha, 1.0);
    }

    #[test]
    fn bank_rose_with_growth() {
        let d = DampingStrategy::BankRose;
        let mut x_new = [0.0; 2];
        let alpha = d.apply(&[1.0, 2.0], &[1.0, 1.0], &mut x_new, 1);
        assert_eq!(alpha, 0.5);
        assert!((x_new[0] - 1.5).abs() < 1e-15);
    }

    #[test]
    fn bank_rose_progressive_damping() {
        let d = DampingStrategy::BankRose;
        let mut x_new = [0.0; 2];
        // 2 consecutive growths → alpha = 0.25
        let alpha = d.apply(&[0.0, 0.0], &[4.0, 8.0], &mut x_new, 2);
        assert_eq!(alpha, 0.25);
        assert!((x_new[0] - 1.0).abs() < 1e-15);
        assert!((x_new[1] - 2.0).abs() < 1e-15);
        // 3 consecutive → 0.125
        let alpha = d.apply(&[0.0, 0.0], &[8.0, 8.0], &mut x_new, 3);
        assert_eq!(alpha, 0.125);
        // 6+ consecutive → floor at 1/64
        let alpha = d.apply(&[0.0, 0.0], &[8.0, 8.0], &mut x_new, 10);
        assert!((alpha - 1.0 / 64.0).abs() < 1e-15);
    }

    #[test]
    fn no_damping_with_residual_growth() {
        // DampingStrategy::None ignores consecutive_growth
        let d = DampingStrategy::None;
        let mut x_new = [0.0; 2];
        let alpha = d.apply(&[0.0, 0.0], &[1.0, 2.0], &mut x_new, 3);
        assert_eq!(alpha, 1.0);
        assert!((x_new[0] - 1.0).abs() < 1e-15);
        assert!((x_new[1] - 2.0).abs() < 1e-15);
    }

    #[test]
    fn fixed_damping_with_residual_growth() {
        // Fixed damping ignores consecutive_growth
        let d = DampingStrategy::Fixed(0.1);
        let mut x_new = [0.0; 2];
        let alpha = d.apply(&[0.0, 0.0], &[10.0, 20.0], &mut x_new, 5);
        assert_eq!(alpha, 0.1);
        assert!((x_new[0] - 1.0).abs() < 1e-15);
        assert!((x_new[1] - 2.0).abs() < 1e-15);
    }

    #[test]
    fn fixed_damping_alpha_1_is_no_damping() {
        let d = DampingStrategy::Fixed(1.0);
        let mut x_new = [0.0; 3];
        let alpha = d.apply(&[1.0, 2.0, 3.0], &[0.5, -0.5, 1.0], &mut x_new, 0);
        assert_eq!(alpha, 1.0);
        assert!((x_new[0] - 1.5).abs() < 1e-15);
        assert!((x_new[1] - 1.5).abs() < 1e-15);
        assert!((x_new[2] - 4.0).abs() < 1e-15);
    }

    #[test]
    fn bank_rose_with_growth_x_new_correct() {
        let d = DampingStrategy::BankRose;
        let x_old = [4.0, 8.0];
        let dx = [2.0, -4.0];
        let mut x_new = [0.0; 2];
        let alpha = d.apply(&x_old, &dx, &mut x_new, 1);
        assert_eq!(alpha, 0.5);
        // x_new = x_old + 0.5 * dx
        assert!((x_new[0] - 5.0).abs() < 1e-15);
        assert!((x_new[1] - 6.0).abs() < 1e-15);
    }

    #[test]
    fn default_damping_is_bank_rose() {
        let d = DampingStrategy::default();
        matches!(d, DampingStrategy::BankRose);
    }

    #[test]
    fn fixed_damping_zero_dx() {
        let d = DampingStrategy::Fixed(0.5);
        let mut x_new = [0.0; 2];
        let alpha = d.apply(&[3.0, 5.0], &[0.0, 0.0], &mut x_new, 0);
        assert_eq!(alpha, 0.5);
        assert!((x_new[0] - 3.0).abs() < 1e-15);
        assert!((x_new[1] - 5.0).abs() < 1e-15);
    }
}
