/// Anderson acceleration (Type-1 / Walker-Ni 2011) wrapped around a fixed-point
/// or Newton iterate.
///
/// Given successive iterates `x_k` and their residuals `f_k = G(x_k) - x_k`
/// (where `G` is the fixed-point map), `step()` returns an accelerated estimate
/// for `x_{k+1}` by solving the least-squares mixing problem over the last `m`
/// residuals.
///
/// # Algorithm
/// At step k with window of mk = min(k, m) past differences:
///   ΔF = [f_{k-mk} | ... | f_{k-1}]  (n × mk matrix of residual diffs)
///   ΔX = [x_{k-mk} | ... | x_{k-1}]  (n × mk matrix of iterate diffs)
///   γ* = argmin_γ ||ΔF γ - f_k||_2   (solved via normal equations or QR)
///   x_{k+1} = x_k + β·f_k - (ΔX + β·ΔF)·γ*
///
/// # References
/// H. F. Walker and P. Ni, "Anderson acceleration for fixed-point iterations,"
/// SIAM J. Numer. Anal. 49(4), 2011.
use std::collections::VecDeque;

// ---------------------------------------------------------------------------
// Tiny dense linear algebra helpers (no external dependencies)
// ---------------------------------------------------------------------------

/// Solve the min-norm least-squares problem min_γ ||A γ - b||_2
/// where A is (m_rows × n_cols) with m_rows >= n_cols.
///
/// Uses the normal equations A'A γ = A'b followed by Cholesky (or, if
/// A'A is ill-conditioned, a regularized solve).  The matrix sizes here
/// are at most `m_hist` × `m_hist` (typically 5×5 to 15×15), so this is
/// negligible cost.
///
/// Returns `gamma` of length `n_cols`, or all-zeros if the system is
/// degenerate (e.g. all columns are zero).
fn least_squares_normal_equations(
    a_cols: &[Vec<f64>], // each inner Vec is one column of A, length m_rows
    b: &[f64],           // length m_rows
) -> Vec<f64> {
    let n_cols = a_cols.len();
    if n_cols == 0 {
        return vec![];
    }
    let m_rows = a_cols[0].len();
    assert_eq!(b.len(), m_rows);

    // Build the Gram matrix G = A'A (n_cols × n_cols, row-major).
    let mut gram = vec![0.0_f64; n_cols * n_cols];
    for j in 0..n_cols {
        for i in 0..=j {
            let dot: f64 = a_cols[i]
                .iter()
                .zip(a_cols[j].iter())
                .map(|(&ai, &aj)| ai * aj)
                .sum();
            gram[i * n_cols + j] = dot;
            gram[j * n_cols + i] = dot;
        }
    }

    // Build rhs = A'b (n_cols).
    let mut rhs: Vec<f64> = a_cols
        .iter()
        .map(|col| col.iter().zip(b.iter()).map(|(&c, &bi)| c * bi).sum())
        .collect();

    // Tikhonov regularisation: add λ·I to the Gram matrix so the system is
    // always well-conditioned. λ = 1e-10 * ||A'A||_F is effectively zero for
    // well-separated residuals.
    let frob_sq: f64 = gram.iter().map(|&v| v * v).sum();
    let lam = 1e-10 * frob_sq.sqrt().max(1e-30);
    for i in 0..n_cols {
        gram[i * n_cols + i] += lam;
    }

    // Solve G γ = rhs with Cholesky (G is SPD after regularisation).
    // We use a simple LDL' / Gaussian elimination for small matrices.
    gaussian_solve(&mut gram, &mut rhs, n_cols);
    rhs
}

/// In-place Gaussian elimination with partial pivoting for a small n×n system.
/// Solves `A x = b`; result is written into `b`.
fn gaussian_solve(a: &mut [f64], b: &mut [f64], n: usize) {
    // Forward elimination with partial pivoting.
    for col in 0..n {
        // Find pivot.
        let mut max_val = a[col * n + col].abs();
        let mut max_row = col;
        for row in col + 1..n {
            let v = a[row * n + col].abs();
            if v > max_val {
                max_val = v;
                max_row = row;
            }
        }

        if max_val < 1e-300 {
            // Singular / near-singular column — leave b[col] = 0 and continue.
            continue;
        }

        // Swap rows col and max_row.
        if max_row != col {
            for k in 0..n {
                a.swap(col * n + k, max_row * n + k);
            }
            b.swap(col, max_row);
        }

        let pivot = a[col * n + col];
        for row in col + 1..n {
            let factor = a[row * n + col] / pivot;
            for k in col..n {
                let sub = factor * a[col * n + k];
                a[row * n + k] -= sub;
            }
            b[row] -= factor * b[col];
        }
    }

    // Back substitution.
    for row in (0..n).rev() {
        let mut sum = b[row];
        for k in row + 1..n {
            sum -= a[row * n + k] * b[k];
        }
        let diag = a[row * n + row];
        b[row] = if diag.abs() < 1e-300 { 0.0 } else { sum / diag };
    }
}

// ---------------------------------------------------------------------------
// Anderson acceleration struct
// ---------------------------------------------------------------------------

/// Anderson acceleration for a fixed-point or quasi-Newton iteration.
///
/// Typical usage (wrapping a Newton corrector loop):
/// ```text
/// let mut aa = AndersonAcceleration::new(5, 1.0);
/// for iter in 0..max_iter {
///     let f_k = residual(x_k);             // F(x_k) = G(x_k) - x_k
///     let x_next = aa.step(&x_k, &f_k);
///     x_k = x_next;
/// }
/// ```
#[derive(Debug, Clone)]
pub struct AndersonAcceleration {
    /// Window size `m` (number of past iterates kept).
    pub m: usize,
    /// Mixing coefficient (1.0 = pure AA; 0 < beta < 1 adds damping).
    pub beta: f64,
    /// History of iterates `x_k`.
    iterate_hist: VecDeque<Vec<f64>>,
    /// History of residuals `f_k = G(x_k) - x_k`.
    residual_hist: VecDeque<Vec<f64>>,
}

impl AndersonAcceleration {
    /// Create a new Anderson acceleration context.
    ///
    /// - `m`: history window size (5–10 is typical; larger costs more memory/flops).
    /// - `beta`: mixing parameter in (0, 1].  Use 1.0 for standard AA.
    pub fn new(m: usize, beta: f64) -> Self {
        assert!(m >= 1, "Anderson window m must be >= 1");
        assert!(beta > 0.0 && beta <= 1.0, "beta must be in (0, 1]");
        Self {
            m,
            beta,
            iterate_hist: VecDeque::with_capacity(m + 1),
            residual_hist: VecDeque::with_capacity(m + 1),
        }
    }

    /// Reset history (call when the solver restarts from a new point).
    pub fn reset(&mut self) {
        self.iterate_hist.clear();
        self.residual_hist.clear();
    }

    /// Return an accelerated estimate for `x_{k+1}`.
    ///
    /// - `x_k`: current iterate.
    /// - `f_k`: fixed-point residual `F(x_k) = G(x_k) - x_k`.
    ///
    /// On the first call (no history yet) this degenerates to a plain step:
    /// `x_{k+1} = x_k + beta * f_k`.
    pub fn step(&mut self, x_k: &[f64], f_k: &[f64]) -> Vec<f64> {
        let n = x_k.len();
        assert_eq!(f_k.len(), n, "x_k and f_k must have the same length");

        // Store current iterate and residual.
        self.iterate_hist.push_back(x_k.to_vec());
        self.residual_hist.push_back(f_k.to_vec());

        // Keep at most m+1 entries (to form m difference columns).
        while self.iterate_hist.len() > self.m + 1 {
            self.iterate_hist.pop_front();
            self.residual_hist.pop_front();
        }

        let hist_len = self.iterate_hist.len();

        // With only one entry, fall back to plain step.
        if hist_len < 2 {
            return x_k
                .iter()
                .zip(f_k.iter())
                .map(|(&x, &f)| x + self.beta * f)
                .collect();
        }

        // Number of difference columns: k_cols = hist_len - 1.
        let k_cols = hist_len - 1;

        // ΔF[:,j] = f_{j+1} - f_j  for j in 0..k_cols
        let df_cols: Vec<Vec<f64>> = (0..k_cols)
            .map(|j| {
                self.residual_hist[j + 1]
                    .iter()
                    .zip(self.residual_hist[j].iter())
                    .map(|(&a, &b)| a - b)
                    .collect()
            })
            .collect();

        // ΔX[:,j] = x_{j+1} - x_j  for j in 0..k_cols
        let dx_cols: Vec<Vec<f64>> = (0..k_cols)
            .map(|j| {
                self.iterate_hist[j + 1]
                    .iter()
                    .zip(self.iterate_hist[j].iter())
                    .map(|(&a, &b)| a - b)
                    .collect()
            })
            .collect();

        // Solve min_γ ||ΔF γ - f_k||_2 via normal equations.
        let gamma = least_squares_normal_equations(&df_cols, f_k);

        // x_{k+1} = x_k + β·f_k - (ΔX + β·ΔF)·γ
        let mut x_next: Vec<f64> = x_k
            .iter()
            .zip(f_k.iter())
            .map(|(&x, &f)| x + self.beta * f)
            .collect();

        for (j, &gj) in gamma.iter().enumerate() {
            if gj == 0.0 {
                continue;
            }
            for i in 0..n {
                x_next[i] -= gj * (dx_cols[j][i] + self.beta * df_cols[j][i]);
            }
        }

        x_next
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Picard fixed-point of cos(x): x_{k+1} = cos(x_k).
    /// True solution: Dottie number ≈ 0.739085.
    /// Compare convergence rate with vs without AA.
    #[test]
    fn anderson_accelerates_cosine_fixedpoint() {
        let dottie: f64 = 0.739_085_133_215_160_6;

        let plain_iters = {
            let mut x = 0.0_f64;
            let mut count = 0;
            while (x - dottie).abs() > 1e-10 && count < 10_000 {
                x = x.cos();
                count += 1;
            }
            count
        };

        let aa_iters = {
            let mut aa = AndersonAcceleration::new(5, 1.0);
            let mut x = 0.0_f64;
            let mut count = 0;
            while (x - dottie).abs() > 1e-10 && count < 10_000 {
                let g = x.cos();
                let f = g - x; // fixed-point residual: G(x) - x
                let x_next = aa.step(&[x], &[f]);
                x = x_next[0];
                count += 1;
            }
            count
        };

        assert!(
            aa_iters < plain_iters,
            "AA ({aa_iters} iters) should converge faster than plain Picard ({plain_iters} iters)"
        );
        assert!(
            aa_iters < 50,
            "AA should converge in fewer than 50 iterations, got {aa_iters}"
        );
    }

    /// Verify that AA with m=3 on a 2D contraction map gives the correct fixed
    /// point and terminates.
    #[test]
    fn anderson_2d_contraction_converges() {
        // Fixed point of G(x,y) = (0.5*x + 0.1*y + 0.3, 0.1*x + 0.4*y + 0.2)
        // Solution: 0.5x - 0.1y = 0.3, -0.1x + 0.6y = 0.2
        // => x = (0.3*0.6 + 0.1*0.2)/(0.5*0.6 - 0.1*0.1) = 0.20/0.29
        let x_sol = 0.20_f64 / 0.29;
        let y_sol = (0.2 + 0.1 * x_sol) / 0.6;

        let mut aa = AndersonAcceleration::new(3, 1.0);
        let mut x = vec![0.0_f64, 0.0];
        for _ in 0..500 {
            let gx = 0.5 * x[0] + 0.1 * x[1] + 0.3;
            let gy = 0.1 * x[0] + 0.4 * x[1] + 0.2;
            let f = vec![gx - x[0], gy - x[1]];
            if f[0].abs() < 1e-12 && f[1].abs() < 1e-12 {
                break;
            }
            x = aa.step(&x, &f);
        }
        assert!((x[0] - x_sol).abs() < 1e-9, "x={} expected {x_sol}", x[0]);
        assert!((x[1] - y_sol).abs() < 1e-9, "y={} expected {y_sol}", x[1]);
    }

    #[test]
    fn anderson_reset_clears_history() {
        let mut aa = AndersonAcceleration::new(3, 1.0);
        let x = vec![1.0, 2.0];
        let f = vec![-0.1, 0.2];
        let _ = aa.step(&x, &f);
        let _ = aa.step(&x, &f);
        assert_eq!(aa.iterate_hist.len(), 2);

        aa.reset();
        assert_eq!(aa.iterate_hist.len(), 0);
    }

    #[test]
    fn anderson_first_step_is_plain_step() {
        // With no history, AA degenerates to x_next = x + beta*f
        let mut aa = AndersonAcceleration::new(5, 1.0);
        let x = vec![2.0, 3.0];
        let f = vec![0.5, -0.5];
        let x_next = aa.step(&x, &f);
        assert!((x_next[0] - 2.5).abs() < 1e-14, "x_next[0]={}", x_next[0]);
        assert!((x_next[1] - 2.5).abs() < 1e-14, "x_next[1]={}", x_next[1]);
    }

    #[test]
    fn anderson_first_step_with_beta_half() {
        // beta=0.5: x_next = x + 0.5*f
        let mut aa = AndersonAcceleration::new(3, 0.5);
        let x = vec![0.0];
        let f = vec![2.0];
        let x_next = aa.step(&x, &f);
        assert!((x_next[0] - 1.0).abs() < 1e-14);
    }

    #[test]
    fn anderson_window_bounded() {
        // History must not exceed m+1 entries
        let m = 3;
        let mut aa = AndersonAcceleration::new(m, 1.0);
        let x = vec![0.0];
        let f = vec![0.1];
        for _ in 0..10 {
            let _ = aa.step(&x, &f);
        }
        assert!(aa.iterate_hist.len() <= m + 1);
        assert!(aa.residual_hist.len() <= m + 1);
    }

    #[test]
    fn anderson_linear_fixed_point() {
        // G(x) = 0.5*x + 1.0 has fixed point x=2
        let mut aa = AndersonAcceleration::new(5, 1.0);
        let mut x = vec![0.0_f64];
        for _ in 0..100 {
            let g = 0.5 * x[0] + 1.0;
            let f = vec![g - x[0]];
            if f[0].abs() < 1e-12 {
                break;
            }
            x = aa.step(&x, &f);
        }
        assert!((x[0] - 2.0).abs() < 1e-9, "fixed point should be 2.0: got {}", x[0]);
    }

    #[test]
    fn anderson_zero_residual_stays_fixed() {
        // If f=0 (already at fixed point), AA should return x unchanged
        let mut aa = AndersonAcceleration::new(5, 1.0);
        let x = vec![3.14, -2.71];
        let f = vec![0.0, 0.0];
        let x_next = aa.step(&x, &f);
        assert!((x_next[0] - x[0]).abs() < 1e-14);
        assert!((x_next[1] - x[1]).abs() < 1e-14);
    }

    #[test]
    fn anderson_reset_allows_fresh_start() {
        let mut aa = AndersonAcceleration::new(4, 1.0);
        // Do some steps
        let x = vec![1.0];
        let f = vec![0.5];
        for _ in 0..5 {
            let _ = aa.step(&x, &f);
        }
        aa.reset();
        // After reset, first step should again be plain
        let x_next = aa.step(&x, &f);
        assert!((x_next[0] - 1.5).abs() < 1e-14, "after reset: {}", x_next[0]);
    }

    #[test]
    fn gaussian_solve_2x2_identity() {
        // Test gaussian_solve helper with a 2x2 identity system
        let mut a = vec![1.0_f64, 0.0, 0.0, 1.0]; // identity 2x2 row-major
        let mut b = vec![3.0, 7.0];
        gaussian_solve(&mut a, &mut b, 2);
        assert!((b[0] - 3.0).abs() < 1e-14);
        assert!((b[1] - 7.0).abs() < 1e-14);
    }

    #[test]
    fn gaussian_solve_2x2_system() {
        // Solve [2 1; 1 3] x = [5; 10] => x = [1, 3]
        let mut a = vec![2.0_f64, 1.0, 1.0, 3.0];
        let mut b = vec![5.0, 10.0];
        gaussian_solve(&mut a, &mut b, 2);
        assert!((b[0] - 1.0).abs() < 1e-12, "b[0]={}", b[0]);
        assert!((b[1] - 3.0).abs() < 1e-12, "b[1]={}", b[1]);
    }

    #[test]
    fn anderson_m1_degenerates_correctly() {
        // m=1: window of just 1 past step; should still converge
        let mut aa = AndersonAcceleration::new(1, 1.0);
        let mut x = vec![0.0_f64];
        for _ in 0..200 {
            let g = 0.5 * x[0] + 1.0;
            let f = vec![g - x[0]];
            if f[0].abs() < 1e-10 {
                break;
            }
            x = aa.step(&x, &f);
        }
        assert!((x[0] - 2.0).abs() < 1e-8, "fixed point should be 2.0: got {}", x[0]);
    }
}
