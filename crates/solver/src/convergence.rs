/// Convergence criteria for Newton-Raphson iteration.
#[derive(Debug, Clone)]
pub struct ConvergenceCriteria {
    pub abs_tol: f64,
    pub rel_tol: f64,
    pub v_tol: f64,
    pub i_tol: f64,
    pub max_iter: u32,
}

impl ConvergenceCriteria {
    /// Build convergence criteria from simulation options.
    ///
    /// Maps SPICE `.OPTIONS` fields:
    /// - `abstol`  → `abs_tol`
    /// - `reltol`  → `rel_tol`
    /// - `vntol`   → `v_tol`
    /// - `abstol * 1000` → `i_tol` (SPICE derives current tolerance from abstol)
    /// - `itl1`    → `max_iter` (DC operating-point iteration limit)
    ///
    /// `chgtol` is preserved in `SimOptions` for transient charge-error checks
    /// but is not consumed here — that is a transient-analysis concern.
    pub fn from_options(opts: &pisim_core::SimOptions) -> Self {
        Self {
            abs_tol: opts.abstol,
            rel_tol: opts.reltol,
            v_tol: opts.vntol,
            // i_tol is not a direct SPICE option; standard practice scales abstol by 1000.
            i_tol: opts.abstol * 1000.0,
            // itl1 = DC operating point iteration limit.
            max_iter: opts.itl1 as u32,
        }
    }
}

impl Default for ConvergenceCriteria {
    fn default() -> Self {
        Self::from_options(&pisim_core::SimOptions::default())
    }
}

impl From<&pisim_core::SimOptions> for ConvergenceCriteria {
    fn from(opts: &pisim_core::SimOptions) -> Self {
        Self::from_options(opts)
    }
}

/// Outcome of a convergence check.
#[derive(Debug, Clone)]
pub enum ConvergenceStatus {
    Converged { iterations: u32 },
    NotConverged { iterations: u32, residual: f64 },
}

impl ConvergenceCriteria {
    /// Check whether the Newton update `dx` and residual `rhs` satisfy
    /// both update-based and residual-based convergence tests.
    pub fn check(&self, dx: &[f64], x: &[f64], rhs: &[f64]) -> bool {
        let update_ok = dx.iter().zip(x.iter()).all(|(&dxi, &xi)| {
            dxi.abs() < self.abs_tol + self.rel_tol * xi.abs()
        });
        let residual_ok = rhs.iter().all(|&ri| ri.abs() < self.i_tol);
        update_ok && residual_ok
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pisim_core::SimOptions;

    #[test]
    fn converged_case() {
        let c = ConvergenceCriteria::default();
        let dx = [1e-14, 1e-13];
        let x = [1.0, 2.0];
        let rhs = [1e-15, 1e-14];
        assert!(c.check(&dx, &x, &rhs));
    }

    #[test]
    fn not_converged_large_dx() {
        let c = ConvergenceCriteria::default();
        let dx = [1.0, 0.0];
        let x = [1.0, 2.0];
        let rhs = [1e-15, 1e-14];
        assert!(!c.check(&dx, &x, &rhs));
    }

    #[test]
    fn not_converged_large_residual() {
        let c = ConvergenceCriteria::default();
        let dx = [1e-14, 1e-13];
        let x = [1.0, 2.0];
        let rhs = [1.0, 0.0];
        assert!(!c.check(&dx, &x, &rhs));
    }

    // --- from_options propagation tests ---

    #[test]
    fn default_matches_sim_options_default() {
        let c = ConvergenceCriteria::default();
        let opts = SimOptions::default();
        assert_eq!(c.abs_tol, opts.abstol);
        assert_eq!(c.rel_tol, opts.reltol);
        assert_eq!(c.v_tol, opts.vntol);
        assert_eq!(c.i_tol, opts.abstol * 1000.0);
        assert_eq!(c.max_iter, opts.itl1 as u32);
    }

    #[test]
    fn from_options_custom_abstol_propagates() {
        let mut opts = SimOptions::default();
        opts.abstol = 1e-6;
        let c = ConvergenceCriteria::from_options(&opts);
        assert_eq!(c.abs_tol, 1e-6);
        assert_eq!(c.i_tol, 1e-3, "i_tol must scale with abstol");
    }

    #[test]
    fn from_options_custom_itl1_propagates() {
        let mut opts = SimOptions::default();
        opts.itl1 = 200;
        let c = ConvergenceCriteria::from_options(&opts);
        assert_eq!(c.max_iter, 200);
    }

    #[test]
    fn from_options_custom_vntol_propagates() {
        let mut opts = SimOptions::default();
        opts.vntol = 1e-4;
        let c = ConvergenceCriteria::from_options(&opts);
        assert_eq!(c.v_tol, 1e-4);
    }

    #[test]
    fn from_trait_and_from_options_agree() {
        let mut opts = SimOptions::default();
        opts.abstol = 1e-10;
        opts.reltol = 1e-4;
        opts.itl1 = 150;
        let via_fn = ConvergenceCriteria::from_options(&opts);
        let via_trait = ConvergenceCriteria::from(&opts);
        assert_eq!(via_fn.abs_tol, via_trait.abs_tol);
        assert_eq!(via_fn.rel_tol, via_trait.rel_tol);
        assert_eq!(via_fn.max_iter, via_trait.max_iter);
    }
}
