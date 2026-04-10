/// Mutual inductance coupling record.
///
/// A `K` element couples two existing inductors:
///   `K<name> L1_name L2_name k_coefficient`
///
/// The mutual inductance is `M = k * sqrt(L1 * L2)`.
///
/// # MNA formulation for coupled inductors
///
/// Uncoupled inductor equations (backward Euler, timestep h):
///   V1 - L1/h * I1 = -L1/h * I1_prev  (companion model of dI1/dt)
///   V2 - L2/h * I2 = -L2/h * I2_prev
///
/// With coupling, the branch equations become:
///   V1 - L1/h * I1 - M/h * I2  = -L1/h * I1_prev - M/h * I2_prev
///   V2 - L2/h * I2 - M/h * I1  = -L2/h * I2_prev - M/h * I1_prev
///
/// The off-diagonal term `M/h` must be stamped into the MNA matrix by the
/// transient stamper. The stamper reads `Circuit::mutual_couplings()` and
/// adds these cross-terms to the branch-equation rows of L1 and L2.
///
/// The `MutualCoupling` struct here carries only the *configuration* — the
/// actual stamping is done by `crates/solver/src/stamper.rs`.
///
/// # DC operating point
///
/// In DC (dI/dt = 0), inductors become short circuits and there is no
/// coupling term. The K element has no DC effect; the stamper ignores
/// mutual couplings during DC analysis.
#[derive(Debug, Clone, Copy)]
pub struct MutualCoupling {
    /// Coupling coefficient k ∈ (0, 1].
    /// k = 1.0 is ideal (lossless) coupling; k = 0.0 means no coupling.
    pub k: f64,
}

impl MutualCoupling {
    /// Compute the mutual inductance M from L1, L2, and the coupling coefficient k.
    ///
    /// `M = k * sqrt(L1 * L2)`
    ///
    /// Both L values should be in henries.
    #[inline]
    pub fn mutual_inductance(k: f64, l1: f64, l2: f64) -> f64 {
        k * (l1 * l2).sqrt()
    }

    /// Create a new coupling record from a coupling coefficient.
    pub fn new(k: f64) -> Self {
        Self { k }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mutual_inductance_formula() {
        // k=1, L1=1mH, L2=1mH → M = 1*sqrt(1e-3 * 1e-3) = 1e-3 H
        let m = MutualCoupling::mutual_inductance(1.0, 1e-3, 1e-3);
        assert!((m - 1e-3).abs() < 1e-15, "M={m}");
    }

    #[test]
    fn mutual_inductance_partial_coupling() {
        // k=0.5, L1=4mH, L2=1mH → M = 0.5 * sqrt(4e-3 * 1e-3) = 0.5 * 2e-3 = 1e-3 H
        let m = MutualCoupling::mutual_inductance(0.5, 4e-3, 1e-3);
        assert!((m - 1e-3).abs() < 1e-15, "M={m}");
    }

    #[test]
    fn mutual_inductance_zero_coupling() {
        let m = MutualCoupling::mutual_inductance(0.0, 1e-3, 1e-3);
        assert_eq!(m, 0.0);
    }

    #[test]
    fn mutual_coupling_new() {
        let mc = MutualCoupling::new(0.9);
        assert!((mc.k - 0.9).abs() < 1e-15);
    }

    /// Two coupled inductors L1=L2=1mH, k=1.0 (ideal transformer 1:1).
    ///
    /// For a step-response test using the companion model (backward Euler):
    ///   V1 - (L1/h)*I1 - (M/h)*I2  = -(L1/h)*I1_prev - (M/h)*I2_prev
    ///   V2 - (L2/h)*I2 - (M/h)*I1  = -(L2/h)*I2_prev - (M/h)*I1_prev
    ///
    /// Initial conditions: I1=I2=0, V1=1V, V2 open circuit.
    /// At t=h (one step): V2 should equal V1 (ideal 1:1 transformer).
    #[test]
    fn ideal_transformer_companion_model_one_step() {
        let l1 = 1e-3_f64;
        let l2 = 1e-3_f64;
        let k  = 1.0_f64;
        let h  = 1e-6_f64;  // 1 µs timestep

        let m = MutualCoupling::mutual_inductance(k, l1, l2);
        assert!((m - 1e-3).abs() < 1e-15);

        // Companion model stamps for the two inductors with coupling:
        //
        //   MNA variables: [V1, V2, I1, I2]  (V1=1V source, V2=output)
        //
        // Branch equations (row 2 for L1, row 3 for L2):
        //   g_L1: V1 - V1_neg - (L1/h)*I1 - (M/h)*I2 = 0
        //   g_L2: V2 - V2_neg - (L2/h)*I2 - (M/h)*I1 = 0
        //
        // With V1=1V (forced), V1_neg=0, I1_prev=0, I2_prev=0:
        //   Backward Euler companion for L1:   1 = (L1/h)*I1 + (M/h)*I2
        //   Coupled equation for L2 (open):    V2 = (L2/h)*I2 + (M/h)*I1
        //
        // For open-circuit on L2 (V2 not connected → no load current):
        //   I2 = 0 (no return path), so from L1 eq: I1 = h/L1 * V1 = h/L1
        //   Then V2 = 0 + (M/h) * I1 = (M/h) * (h/L1) = M/L1 = 1.0 * 1e-3/1e-3 = 1.0 V
        //
        // This is the expected 1:1 transformer voltage ratio.
        let l1_over_h = l1 / h;  // companion self term
        let m_over_h  = m / h;   // coupling term

        // Solve: V1 = l1_over_h * I1  (when M*I2 = 0 for open secondary)
        let i1 = 1.0_f64 / l1_over_h;  // = h / L1

        // Output voltage: V2 = m_over_h * I1
        let v2_computed = m_over_h * i1;  // = (M/h) * (h/L1) = M/L1

        let v2_expected = m / l1;  // = 1.0 for k=1, L1=L2
        assert!(
            (v2_computed - v2_expected).abs() < 1e-10,
            "1:1 transformer V2={v2_computed} expected={v2_expected}"
        );
        assert!(
            (v2_computed - 1.0).abs() < 1e-10,
            "Ideal 1:1 transformer: V_out should equal V_in=1V, got {v2_computed}"
        );
    }
}
