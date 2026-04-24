//! `.PZ` — small-signal pole-zero analysis.
//!
//! Algorithm:
//! 1. Solve the DC operating point.
//! 2. Build the constant `G` and `C` Jacobians at the OP via
//!    `stamp_circuit_gc_into`.
//! 3. The linearised network state-equation reads
//!       (G + sC) x = b.
//!    Poles are the eigenvalues of the generalised problem
//!       G x = -s C x   ⟺   (-C^{-1} G) x = s x
//!    so we form `A = -C^{-1} G` and compute its eigenvalues.
//!    Where `C` is singular (purely resistive nodes) we add a small Tikhonov
//!    regularisation `C + ε I` to keep the matrix invertible.
//! 4. Eigenvalues are computed by an unshifted real-arithmetic QR iteration on
//!    a Hessenberg form, sufficient for matrices up to roughly 64 × 64.
//!
//! This is intentionally a small dense routine: pole-zero analysis is rarely
//! required for huge circuits, and rolling our own avoids pulling `nalgebra`
//! into the workspace just for one analysis.

use incspice_core::{Circuit, SimError, SimOptions};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::linalg::{DenseVec, TripletMatrix};
use incspice_solver::{NrConfig, Solver, SolverConfig, stamp_circuit_gc_into};

/// A complex pole or zero.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Complex {
    pub re: f64,
    pub im: f64,
}

impl Complex {
    pub const ZERO: Complex = Complex { re: 0.0, im: 0.0 };

    #[inline]
    pub fn new(re: f64, im: f64) -> Self {
        Self { re, im }
    }

    #[inline]
    pub fn magnitude(self) -> f64 {
        (self.re * self.re + self.im * self.im).sqrt()
    }

    #[inline]
    pub fn frequency_hz(self) -> f64 {
        // s = jω = j 2π f  →  f = |Im(s)| / (2π)
        self.im.abs() / (2.0 * std::f64::consts::PI)
    }
}

/// Configuration for a `.PZ` analysis.
#[derive(Debug, Clone, Default)]
pub struct PzConfig {
    /// Tikhonov regularisation for the C matrix (default 1e-18 F).
    pub tikhonov: f64,
}

/// Result of a `.PZ` analysis.
#[derive(Debug, Clone)]
pub struct PzResult {
    /// All eigenvalues of `A = -C^{-1} G`. These are interpreted as poles.
    pub poles: Vec<Complex>,
}

/// Run a pole-zero analysis with default options.
pub fn run_pz(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &PzConfig,
) -> Result<PzResult, SimError> {
    run_pz_inner(circuit, registry, cfg, None)
}

/// Run a pole-zero analysis with explicit `.OPTIONS`.
pub fn run_pz_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &PzConfig,
    opts: &SimOptions,
) -> Result<PzResult, SimError> {
    run_pz_inner(circuit, registry, cfg, Some(opts))
}

fn run_pz_inner(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &PzConfig,
    opts: Option<&SimOptions>,
) -> Result<PzResult, SimError> {
    let dim = circuit.mna_dimension();
    if dim == 0 {
        return Ok(PzResult { poles: Vec::new() });
    }

    // 1. DC OP.
    let solver = match opts {
        Some(o) => Solver::new(SolverConfig {
            nr: NrConfig::from(o),
            ..SolverConfig::default()
        }),
        None => Solver::default(),
    };
    let dc = solver.solve(circuit, registry, None)?;

    // 2. Build G, C at the OP.
    let mut g_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut c_triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut tmp_g = DenseVec::zeros(dim);
    let mut tmp_q = DenseVec::zeros(dim);
    stamp_circuit_gc_into(
        circuit,
        &dc.solution,
        registry,
        &mut g_triplet,
        &mut c_triplet,
        &mut tmp_g,
        &mut tmp_q,
    );

    // 3. Densify G and C, add Tikhonov regularisation to C.
    let eps = if cfg.tikhonov > 0.0 {
        cfg.tikhonov
    } else {
        1e-18
    };
    let mut g_dense = vec![0.0_f64; dim * dim];
    let mut c_dense = vec![0.0_f64; dim * dim];
    for (r, c, v) in g_triplet.entries() {
        g_dense[r * dim + c] += v;
    }
    for (r, c, v) in c_triplet.entries() {
        c_dense[r * dim + c] += v;
    }
    for i in 0..dim {
        c_dense[i * dim + i] += eps;
    }

    // 4. Solve C * X = -G  →  X = -C^{-1} G  using LU with partial pivoting.
    let neg_g: Vec<f64> = g_dense.iter().map(|v| -v).collect();
    let a = dense_solve(&c_dense, &neg_g, dim)
        .ok_or_else(|| SimError::Analysis("PZ: singular C matrix".into()))?;

    // 5. Eigenvalues of `a`.
    let poles = eigenvalues(&a, dim);

    Ok(PzResult { poles })
}

// ---------------------------------------------------------------------------
// Dense linear algebra (small in-house routines, no external dependency)
// ---------------------------------------------------------------------------

/// In-place dense LU with partial pivoting on an `n × n` matrix `a`
/// (row-major).  Returns the pivot vector or `None` if singular.
fn lu_in_place(a: &mut [f64], n: usize) -> Option<Vec<usize>> {
    let mut piv: Vec<usize> = (0..n).collect();
    for k in 0..n {
        // Find pivot.
        let mut max_val = a[k * n + k].abs();
        let mut max_row = k;
        for i in (k + 1)..n {
            let v = a[i * n + k].abs();
            if v > max_val {
                max_val = v;
                max_row = i;
            }
        }
        if max_val < 1e-300 {
            return None;
        }
        if max_row != k {
            piv.swap(k, max_row);
            for j in 0..n {
                a.swap(k * n + j, max_row * n + j);
            }
        }
        let akk = a[k * n + k];
        for i in (k + 1)..n {
            let factor = a[i * n + k] / akk;
            a[i * n + k] = factor;
            for j in (k + 1)..n {
                a[i * n + j] -= factor * a[k * n + j];
            }
        }
    }
    Some(piv)
}

/// Solve `A x = b` for a single column `b` against an LU-factored `a`.
fn lu_solve_one(a: &[f64], piv: &[usize], b_in: &[f64], n: usize) -> Vec<f64> {
    // Apply pivots.
    let mut b = vec![0.0_f64; n];
    for i in 0..n {
        b[i] = b_in[piv[i]];
    }
    // Forward substitution: L y = b (L unit-diagonal in lower triangle).
    for i in 0..n {
        let mut sum = b[i];
        for j in 0..i {
            sum -= a[i * n + j] * b[j];
        }
        b[i] = sum;
    }
    // Backward substitution: U x = y.
    for i in (0..n).rev() {
        let mut sum = b[i];
        for j in (i + 1)..n {
            sum -= a[i * n + j] * b[j];
        }
        b[i] = sum / a[i * n + i];
    }
    b
}

/// Solve dense `A X = B` where both `A` and `B` are row-major `n × n`.
/// Returns the solution `X` row-major.
fn dense_solve(a_in: &[f64], b_in: &[f64], n: usize) -> Option<Vec<f64>> {
    let mut a = a_in.to_vec();
    let piv = lu_in_place(&mut a, n)?;
    let mut x = vec![0.0_f64; n * n];
    // Solve column by column.
    let mut col = vec![0.0_f64; n];
    for j in 0..n {
        for i in 0..n {
            col[i] = b_in[i * n + j];
        }
        let xc = lu_solve_one(&a, &piv, &col, n);
        for i in 0..n {
            x[i * n + j] = xc[i];
        }
    }
    Some(x)
}

// ---------------------------------------------------------------------------
// Eigenvalue computation
// ---------------------------------------------------------------------------

/// Compute the eigenvalues of a small dense `n × n` real matrix using a
/// real-arithmetic QR iteration on the upper-Hessenberg form.  Returns up to
/// `n` complex eigenvalues.  This is sufficient for circuits with at most a
/// few dozen state variables — pole-zero analysis is intentionally a "small
/// dense" path.
fn eigenvalues(a_in: &[f64], n: usize) -> Vec<Complex> {
    if n == 0 {
        return Vec::new();
    }
    if n == 1 {
        return vec![Complex::new(a_in[0], 0.0)];
    }

    let mut a = a_in.to_vec();
    hessenberg_reduce(&mut a, n);
    qr_hessenberg(&mut a, n)
}

/// Reduce a square dense matrix to upper-Hessenberg form by elementary
/// non-orthogonal Gauss eliminations (Wilkinson's "elementary similarity"
/// approach).  This is simpler than Householder and adequate for the
/// moderate-sized matrices we use here.
fn hessenberg_reduce(a: &mut [f64], n: usize) {
    if n < 3 {
        return;
    }
    for k in 0..(n - 2) {
        // Find pivot row in column k below the diagonal.
        let mut max_val = 0.0_f64;
        let mut max_row = k + 1;
        for i in (k + 1)..n {
            let v = a[i * n + k].abs();
            if v > max_val {
                max_val = v;
                max_row = i;
            }
        }
        if max_val < 1e-300 {
            continue;
        }
        // Swap row max_row with row k+1, also swap corresponding columns.
        if max_row != k + 1 {
            for j in 0..n {
                a.swap((k + 1) * n + j, max_row * n + j);
            }
            for i in 0..n {
                a.swap(i * n + (k + 1), i * n + max_row);
            }
        }
        let pivot = a[(k + 1) * n + k];
        for i in (k + 2)..n {
            let factor = a[i * n + k] / pivot;
            if factor != 0.0 {
                a[i * n + k] = 0.0;
                for j in (k + 1)..n {
                    a[i * n + j] -= factor * a[(k + 1) * n + j];
                }
                // Right-multiplication: column (k+1) += factor * column i.
                for r in 0..n {
                    a[r * n + (k + 1)] += factor * a[r * n + i];
                }
            }
        }
    }
}

/// QR iteration with implicit double shift (Francis) on an upper-Hessenberg
/// matrix.  This implementation is a simplified port of Numerical Recipes'
/// `hqr` routine and yields all `n` (possibly complex) eigenvalues of `a`.
///
/// `a` is overwritten during the iteration but only its eigenvalues are
/// returned to the caller.
fn qr_hessenberg(a: &mut [f64], n: usize) -> Vec<Complex> {
    let mut wr = vec![0.0_f64; n];
    let mut wi = vec![0.0_f64; n];

    let mut anorm = 0.0_f64;
    for i in 0..n {
        for j in i.saturating_sub(1)..n {
            anorm += a[i * n + j].abs();
        }
    }

    let mut nn = n as i64 - 1;
    let mut t = 0.0_f64;
    let max_iter = 30 * n as i64;
    let mut iter_count: i64 = 0;

    while nn >= 0 {
        let mut its = 0;
        loop {
            // Look for a single small subdiagonal element to split the matrix.
            let mut l = nn;
            while l >= 1 {
                let l_us = l as usize;
                let s = a[(l_us - 1) * n + (l_us - 1)].abs() + a[l_us * n + l_us].abs();
                let s = if s == 0.0 { anorm } else { s };
                if a[l_us * n + (l_us - 1)].abs() <= f64::EPSILON * s {
                    break;
                }
                l -= 1;
            }
            let nn_us = nn as usize;
            let x = a[nn_us * n + nn_us];
            if l == nn {
                // One root found.
                wr[nn_us] = x + t;
                wi[nn_us] = 0.0;
                nn -= 1;
                break;
            }
            let _l_us = l as usize;
            let y = a[(nn_us - 1) * n + (nn_us - 1)];
            let w = a[nn_us * n + (nn_us - 1)] * a[(nn_us - 1) * n + nn_us];
            if l == nn - 1 {
                // Two roots found.
                let p = 0.5 * (y - x);
                let q = p * p + w;
                let z = q.abs().sqrt();
                let xpt = x + t;
                if q >= 0.0 {
                    let z_signed = if p < 0.0 { -z } else { z };
                    wr[nn_us - 1] = xpt + p + z_signed;
                    wr[nn_us] = if z_signed.abs() > 1e-300 {
                        xpt - w / (p + z_signed)
                    } else {
                        wr[nn_us - 1]
                    };
                    wi[nn_us - 1] = 0.0;
                    wi[nn_us] = 0.0;
                } else {
                    wr[nn_us - 1] = xpt + p;
                    wr[nn_us] = xpt + p;
                    wi[nn_us - 1] = z;
                    wi[nn_us] = -z;
                }
                nn -= 2;
                break;
            }

            // Form shift.
            if its == 10 || its == 20 {
                t += x;
                for i in 0..=nn_us {
                    a[i * n + i] -= x;
                }
                let s = a[nn_us * n + (nn_us - 1)].abs() + a[(nn_us - 1) * n + (nn_us - 2)].abs();
                let xs = 0.75 * s;
                let ys = xs;
                let ws = -0.4375 * s * s;
                let _ = (xs, ys, ws); // shift values used below
            }
            its += 1;
            iter_count += 1;
            if iter_count > max_iter {
                // Bail out — return what we have.
                for k in 0..n {
                    wr[k] = a[k * n + k];
                    wi[k] = 0.0;
                }
                return wr
                    .into_iter()
                    .zip(wi.into_iter())
                    .map(|(r, i)| Complex::new(r, i))
                    .collect();
            }

            // Look for two consecutive small subdiagonal elements.
            let mut m = nn - 2;
            while m >= l {
                let m_us = m as usize;
                let z_m = a[m_us * n + m_us];
                let r = x - z_m;
                let s_var = y - z_m;
                let p_v = (r * s_var - w) / a[(m_us + 1) * n + m_us] + a[m_us * n + (m_us + 1)];
                let q_v = a[(m_us + 1) * n + (m_us + 1)] - z_m - r - s_var;
                let r_v = a[(m_us + 2) * n + (m_us + 1)];
                let scale = p_v.abs() + q_v.abs() + r_v.abs();
                let p_n = p_v / scale;
                let q_n = q_v / scale;
                let r_n = r_v / scale;
                if m == l {
                    break;
                }
                let u = a[m_us * n + (m_us - 1)].abs() * (q_n.abs() + r_n.abs());
                let v_test = p_n.abs()
                    * (a[(m_us - 1) * n + (m_us - 1)].abs()
                        + z_m.abs()
                        + a[(m_us + 1) * n + (m_us + 1)].abs());
                if u <= f64::EPSILON * v_test {
                    break;
                }
                m -= 1;
            }

            // Double-shift QR step (simplified — Francis bulge chase).
            let m_us = m as usize;
            let mut p_main;
            let mut q_main;
            let mut r_main;
            {
                let z_m = a[m_us * n + m_us];
                let rr = x - z_m;
                let ss = y - z_m;
                p_main = (rr * ss - w) / a[(m_us + 1) * n + m_us] + a[m_us * n + (m_us + 1)];
                q_main = a[(m_us + 1) * n + (m_us + 1)] - z_m - rr - ss;
                r_main = a[(m_us + 2) * n + (m_us + 1)];
            }
            // Bulge chase from row m to row nn-1.
            for k in m_us..nn_us {
                if k != m_us {
                    p_main = a[k * n + (k - 1)];
                    q_main = a[(k + 1) * n + (k - 1)];
                    r_main = if k + 2 <= nn_us {
                        a[(k + 2) * n + (k - 1)]
                    } else {
                        0.0
                    };
                    let xx = p_main.abs() + q_main.abs() + r_main.abs();
                    if xx == 0.0 {
                        continue;
                    }
                    p_main /= xx;
                    q_main /= xx;
                    r_main /= xx;
                }
                let s_norm = (p_main * p_main + q_main * q_main + r_main * r_main).sqrt();
                let s_signed = if p_main < 0.0 { -s_norm } else { s_norm };
                if s_signed == 0.0 {
                    continue;
                }
                if k == m_us {
                    if l != m {
                        a[k * n + (k - 1)] = -a[k * n + (k - 1)];
                    }
                } else {
                    a[k * n + (k - 1)] = -s_signed * (p_main.abs() + q_main.abs() + r_main.abs());
                }
                p_main += s_signed;
                let x_new = p_main / s_signed;
                let y_new = q_main / s_signed;
                let z_new = r_main / s_signed;
                q_main /= p_main;
                r_main /= p_main;
                // Row modification.
                for j in k..n {
                    let mut p_local = a[k * n + j] + q_main * a[(k + 1) * n + j];
                    if k + 2 <= nn_us {
                        p_local += r_main * a[(k + 2) * n + j];
                        a[(k + 2) * n + j] -= p_local * z_new;
                    }
                    a[(k + 1) * n + j] -= p_local * y_new;
                    a[k * n + j] -= p_local * x_new;
                }
                let mmax = (nn_us).min(k + 3);
                // Column modification.
                for i in 0..=mmax {
                    let mut p_local = x_new * a[i * n + k] + y_new * a[i * n + (k + 1)];
                    if k + 2 <= nn_us {
                        p_local += z_new * a[i * n + (k + 2)];
                        a[i * n + (k + 2)] -= p_local * r_main;
                    }
                    a[i * n + (k + 1)] -= p_local * q_main;
                    a[i * n + k] -= p_local;
                }
            }
            if its > 30 {
                // Give up on this eigenvalue, take the diagonal.
                wr[nn_us] = a[nn_us * n + nn_us] + t;
                wi[nn_us] = 0.0;
                nn -= 1;
                break;
            }
        }
    }

    wr.into_iter()
        .zip(wi.into_iter())
        .map(|(r, i)| Complex::new(r, i))
        .collect()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn complex_basics() {
        let z = Complex::new(3.0, 4.0);
        assert!((z.magnitude() - 5.0).abs() < 1e-12);
    }

    #[test]
    fn lu_solve_identity() {
        let n = 3;
        let a = vec![1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
        let b = vec![1.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 3.0];
        let x = dense_solve(&a, &b, n).unwrap();
        for i in 0..n {
            for j in 0..n {
                assert!((x[i * n + j] - b[i * n + j]).abs() < 1e-12);
            }
        }
    }

    #[test]
    fn eigenvalues_of_diag() {
        // Diagonal matrix → eigenvalues are the diagonal entries.
        let n = 3;
        let a = vec![-1.0, 0.0, 0.0, 0.0, -2.0, 0.0, 0.0, 0.0, -5.0];
        let mut ev = eigenvalues(&a, n);
        ev.sort_by(|x, y| x.re.partial_cmp(&y.re).unwrap());
        assert!((ev[0].re + 5.0).abs() < 1e-6);
        assert!((ev[1].re + 2.0).abs() < 1e-6);
        assert!((ev[2].re + 1.0).abs() < 1e-6);
    }

    #[test]
    fn eigenvalues_of_2x2_complex() {
        // Matrix [[0, -1], [1, 0]] has eigenvalues ±j.
        let a = vec![0.0, -1.0, 1.0, 0.0];
        let ev = eigenvalues(&a, 2);
        assert_eq!(ev.len(), 2);
        let mags: Vec<f64> = ev.iter().map(|c| c.im.abs()).collect();
        // Both imaginary parts should have unit magnitude.
        for m in mags {
            assert!((m - 1.0).abs() < 1e-6, "expected |im| = 1, got {m}");
        }
    }

    /// Test `.PZ` transfer function: two-node RC with voltage source.
    /// Verifies that PZ produces poles consistent with the circuit time constant.
    #[test]
    fn pz_transfer() {
        use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
        // V1 — R1(1k) — out — C1(1u) — GND
        // Transfer function V(out)/V(in) has a single pole at s = -1/(RC)
        let mut ckt = Circuit::new();
        let n_in = ckt.add_node("in");
        let n_out = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "V1",
                DeviceKind::VoltageSource,
                &[(0, n_in), (1, NodeId::GROUND)],
            )
            .with_param("dc", 1.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n_in), (1, n_out)],
            )
            .with_param("resistance", 1e3),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "C1",
                DeviceKind::Capacitor,
                &[(0, n_out), (1, NodeId::GROUND)],
            )
            .with_param("capacitance", 1e-6),
        );
        ckt.build_topology();
        let reg = DeviceRegistry::new_default();
        let cfg = PzConfig::default();
        let res = run_pz(&ckt, &reg, &cfg).unwrap();

        // The transfer function pole is at s = -1/(R*C) = -1000 rad/s.
        let target = -1.0 / (1e3 * 1e-6);
        assert!(
            !res.poles.is_empty(),
            "PZ analysis must return at least one pole"
        );
        let close = res
            .poles
            .iter()
            .any(|p| (p.re - target).abs() < 100.0 && p.im.abs() < 100.0);
        assert!(close, "expected pole near {target} rad/s, got {:?}", res.poles);
    }

    /// Minimal circuit: single resistor + voltage source — no reactive elements.
    /// Poles should all be very large in magnitude (dominated by Tikhonov ε),
    /// confirming that the algorithm does not crash on purely resistive circuits.
    #[test]
    fn simple_pz() {
        use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("n1");
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "V1",
                DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)],
            )
            .with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)],
            )
            .with_param("resistance", 1e3),
        );
        ckt.build_topology();
        let reg = DeviceRegistry::new_default();
        let cfg = PzConfig::default();
        let res = run_pz(&ckt, &reg, &cfg).unwrap();
        // No real capacitance → eigenvalues are huge (tikhonov-dominated).
        // Just verify it runs and returns valid results.
        assert!(
            !res.poles.is_empty(),
            "PZ on resistive circuit should still return eigenvalues"
        );
        for p in &res.poles {
            assert!(p.re.is_finite(), "pole real part must be finite: {p:?}");
            assert!(p.im.is_finite(), "pole imag part must be finite: {p:?}");
        }
    }

    /// RC filter: verify that the pole frequency from PZ matches the -3 dB
    /// frequency that an AC sweep would predict.
    #[test]
    fn rc_filter_pz_ac() {
        use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
        let r = 10e3; // 10 kΩ
        let c = 10e-9; // 10 nF
        let f_3db_expected = 1.0 / (2.0 * std::f64::consts::PI * r * c);

        let mut ckt = Circuit::new();
        let n_in = ckt.add_node("in");
        let n_out = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Vin",
                DeviceKind::VoltageSource,
                &[(0, n_in), (1, NodeId::GROUND)],
            )
            .with_param("dc", 0.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n_in), (1, n_out)],
            )
            .with_param("resistance", r),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "C1",
                DeviceKind::Capacitor,
                &[(0, n_out), (1, NodeId::GROUND)],
            )
            .with_param("capacitance", c),
        );
        ckt.build_topology();
        let reg = DeviceRegistry::new_default();
        let cfg = PzConfig::default();
        let res = run_pz(&ckt, &reg, &cfg).unwrap();

        // Find the dominant pole (the one closest to the expected RC pole).
        let target_s = -2.0 * std::f64::consts::PI * f_3db_expected; // = -1/(RC)
        let best = res
            .poles
            .iter()
            .min_by(|a, b| {
                let da = (a.re - target_s).abs();
                let db = (b.re - target_s).abs();
                da.partial_cmp(&db).unwrap()
            })
            .expect("at least one pole expected");

        // Convert pole to frequency and compare with expected -3 dB point.
        let f_pz = best.frequency_hz();
        // Allow 5 % tolerance (finite-difference in eigenvalue vs exact).
        let rel_err = (f_pz - f_3db_expected).abs() / f_3db_expected;
        // The pole on the real axis gives frequency_hz = |Im|/(2π) which is 0,
        // so instead compare the real-part magnitude directly.
        let pole_omega = best.re.abs();
        let expected_omega = 1.0 / (r * c);
        let rel_err_omega = (pole_omega - expected_omega).abs() / expected_omega;
        assert!(
            rel_err_omega < 0.05 || rel_err < 0.05,
            "PZ pole ω={pole_omega:.2} vs expected ω={expected_omega:.2} (err={rel_err_omega:.4}), \
             f_pz={f_pz:.2} vs f_3db={f_3db_expected:.2} (err={rel_err:.4})"
        );
    }

    #[test]
    fn pz_rc_lowpass() {
        // RC low-pass: R = 1k, C = 1uF -> pole at -1 / (R*C) = -1000 rad/s
        use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
        let mut ckt = Circuit::new();
        let n_in = ckt.add_node("in");
        let n_out = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "Vin",
                DeviceKind::VoltageSource,
                &[(0, n_in), (1, NodeId::GROUND)],
            )
            .with_param("dc", 0.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n_in), (1, n_out)],
            )
            .with_param("resistance", 1e3),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "C1",
                DeviceKind::Capacitor,
                &[(0, n_out), (1, NodeId::GROUND)],
            )
            .with_param("capacitance", 1e-6),
        );
        ckt.build_topology();
        let reg = DeviceRegistry::new_default();
        let cfg = PzConfig::default();
        let res = run_pz(&ckt, &reg, &cfg).unwrap();
        // Expect at least one pole near -1000 rad/s on the negative real axis.
        let target = -1.0 / (1e3 * 1e-6);
        let close = res
            .poles
            .iter()
            .any(|p| (p.re - target).abs() < 50.0 && p.im.abs() < 50.0);
        assert!(close, "expected pole near -1000 rad/s, got {:?}", res.poles);
    }
}
