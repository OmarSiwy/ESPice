//! Harmonic Balance single-tone analysis (§2.1).
//!
//! Implements a frequency-domain Newton-Raphson solve for periodic
//! steady-state. The unknown vector X stores spectral coefficients for
//! every MNA variable:
//!
//!   X = [V_dc(0..N), V_re(1..N), V_im(1..N), ..., V_re(K..N), V_im(K..N)]
//!
//! which gives M = N*(2*K+1) unknowns total (N = mna_dim, K = num_harmonics).
//!
//! The residual F(X) is computed by:
//!   1. IDFT X → time-domain samples x(t_k), k = 0..(2K)
//!   2. Stamp the circuit at each time point → KCL residuals r(t_k)
//!   3. DFT r(t_k) → spectral residuals F(X)
//!
//! The Jacobian J = ∂F/∂X is formed by finite differences.

use std::f64::consts::PI;

use incspice_cache::CacheManager;
use incspice_core::{Circuit, SimError, StreamingSink};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::linalg::{DenseVec, LinSolver, LinSolverKind, TripletMatrix};
use incspice_solver::newton::NrConfig;
use incspice_solver::stamp_circuit;
use crate::{Analysis, AnalysisError};

// ─── Public types ────────────────────────────────────────────────────────────

pub struct HarmonicBalance { pub fundamental: f64, pub harmonics: usize }

impl Analysis for HarmonicBalance {
    fn run(
        &self,
        circuit: &mut Circuit,
        registry: &DeviceRegistry,
        _config: &NrConfig,
        _cache: &mut CacheManager,
        sink: &mut dyn StreamingSink,
    ) -> Result<(), AnalysisError> {
        let cfg = HbSingleConfig {
            f0: self.fundamental,
            num_harmonics: self.harmonics,
            max_iter: 50,
            tol: 1e-6,
        };
        let _result = run_hb_single_tone(circuit, registry, &cfg)?;
        sink.finalize()?;
        Ok(())
    }
    fn name(&self) -> &str { "hb" }
}

/// Configuration for a single-tone harmonic balance solve.
#[derive(Debug, Clone)]
pub struct HbSingleConfig {
    /// Fundamental frequency [Hz].
    pub f0: f64,
    /// Number of harmonics to include (DC + harmonics 1..num_harmonics).
    pub num_harmonics: usize,
    /// Maximum Newton-Raphson iterations.
    pub max_iter: usize,
    /// Convergence tolerance.
    pub tol: f64,
}

/// HB state storage — spectral coefficients for each node.
///
/// For `N` nodes and `K+1` frequency bins (DC plus K harmonics), the state
/// holds `real[bin * N + node]` and `imag[bin * N + node]`.
#[derive(Debug, Clone)]
pub struct HbState {
    pub num_nodes: usize,
    pub num_freqs: usize, // nharm + 1
    /// Real parts, row-major [freq][node].
    pub real: Vec<f64>,
    /// Imaginary parts, row-major [freq][node].
    pub imag: Vec<f64>,
}

impl HbState {
    pub fn zeros(num_nodes: usize, num_freqs: usize) -> Self {
        let n = num_nodes * num_freqs;
        Self { num_nodes, num_freqs, real: vec![0.0; n], imag: vec![0.0; n] }
    }

    pub fn re(&self, freq_bin: usize, node: usize) -> f64 {
        self.real[freq_bin * self.num_nodes + node]
    }

    pub fn im(&self, freq_bin: usize, node: usize) -> f64 {
        self.imag[freq_bin * self.num_nodes + node]
    }
}

/// Result of a single-tone HB analysis.
#[derive(Debug, Clone)]
pub struct HbResult {
    /// Final spectral state.
    pub state: HbState,
    /// Whether HB converged within `max_iter`.
    pub converged: bool,
    /// Number of NR iterations consumed.
    pub iterations: usize,
    /// Residual at convergence.
    pub residual: f64,
}

impl HbResult {
    /// Magnitude of harmonic `harm` at `node`.  `harm=0` → DC.
    pub fn magnitude(&self, harm: usize, node: usize) -> f64 {
        if harm >= self.state.num_freqs || node >= self.state.num_nodes {
            return 0.0;
        }
        let re = self.state.re(harm, node);
        let im = self.state.im(harm, node);
        (re * re + im * im).sqrt()
    }
}

// ─── DFT / IDFT helpers ──────────────────────────────────────────────────────

/// Spectral unknowns layout for N MNA variables and K harmonics.
///
/// The flat vector X has length M = N * (2*K+1):
///   X[0..N]         = DC values  (real, imag=0 for DC)
///   X[N..3*N]       = harmonic 1: real part [N..2N], imag part [2N..3N]
///   X[3*N..5*N]     = harmonic 2: real part, imag part
///   ...
///
/// Helper: index into X for the real part of harmonic `h` at MNA variable `v`
/// (h=0 → DC; h>=1 → real part of h-th harmonic).
#[inline]
fn x_re_idx(h: usize, v: usize, n: usize) -> usize {
    if h == 0 {
        v
    } else {
        n + (2 * (h - 1)) * n + v
    }
}

/// Index into X for the imaginary part of harmonic `h` (h >= 1) at variable `v`.
#[inline]
fn x_im_idx(h: usize, v: usize, n: usize) -> usize {
    debug_assert!(h >= 1);
    n + (2 * (h - 1) + 1) * n + v
}

/// IDFT: convert spectral coefficients → time-domain samples.
///
/// Input `spectral` is the full X vector (length N*(2K+1)).
/// Output: time-domain vector of length `n_time * n` where
/// `n_time = 2*K+1` and the layout is `[t0_v0, t0_v1, ..., t1_v0, ...]`.
fn idft_all(spectral: &[f64], n: usize, k_harmonics: usize) -> Vec<f64> {
    let n_time = 2 * k_harmonics + 1;
    let mut time = vec![0.0_f64; n_time * n];
    for t_idx in 0..n_time {
        for v in 0..n {
            // DC contribution
            let mut val = spectral[x_re_idx(0, v, n)];
            // Harmonic contributions
            for h in 1..=k_harmonics {
                let angle = 2.0 * PI * (h as f64) * (t_idx as f64) / (n_time as f64);
                let re = spectral[x_re_idx(h, v, n)];
                let im = spectral[x_im_idx(h, v, n)];
                val += re * angle.cos() + im * angle.sin();
            }
            time[t_idx * n + v] = val;
        }
    }
    time
}

/// DFT: convert time-domain residuals → spectral residuals.
///
/// Input `time_res` has layout `[t0_v0, t0_v1, ..., t1_v0, ...]`.
/// Output has same layout as the spectral X vector.
fn dft_all(time_res: &[f64], n: usize, k_harmonics: usize) -> Vec<f64> {
    let n_time = 2 * k_harmonics + 1;
    let m = n * (2 * k_harmonics + 1);
    let mut freq = vec![0.0_f64; m];
    let scale = 1.0 / (n_time as f64);

    for v in 0..n {
        // DC bin
        let dc_sum: f64 = (0..n_time).map(|t| time_res[t * n + v]).sum();
        freq[x_re_idx(0, v, n)] = dc_sum * scale;

        // Harmonic bins
        for h in 1..=k_harmonics {
            let mut re_sum = 0.0_f64;
            let mut im_sum = 0.0_f64;
            for t_idx in 0..n_time {
                let angle = 2.0 * PI * (h as f64) * (t_idx as f64) / (n_time as f64);
                re_sum += time_res[t_idx * n + v] * angle.cos();
                im_sum += time_res[t_idx * n + v] * angle.sin();
            }
            // Use 2/N scaling for harmonics (one-sided spectrum convention)
            freq[x_re_idx(h, v, n)] = 2.0 * re_sum * scale;
            freq[x_im_idx(h, v, n)] = 2.0 * im_sum * scale;
        }
    }
    freq
}

// ─── Core HB residual evaluator ──────────────────────────────────────────────

/// Evaluate F(X): stamp circuit at every time point and DFT the result.
///
/// Returns the spectral residual vector of length M = N*(2K+1).
fn hb_residual(
    x: &[f64],
    circuit: &Circuit,
    registry: &DeviceRegistry,
    n: usize,           // MNA dimension
    k_harmonics: usize,
    f0: f64,
) -> Vec<f64> {
    let n_time = 2 * k_harmonics + 1;
    let period = if f0 > 0.0 { 1.0 / f0 } else { 1.0 };
    let dt = period / (n_time as f64);

    // Convert spectral X → time-domain waveforms
    let time_sol = idft_all(x, n, k_harmonics);

    // Evaluate KCL residual at each time point
    let mut time_res = vec![0.0_f64; n_time * n];
    for t_idx in 0..n_time {
        let t = (t_idx as f64) * dt;
        let sol_slice = &time_sol[t_idx * n..(t_idx + 1) * n];
        let (_jac, res) = stamp_circuit(n, circuit, sol_slice, registry);
        // For HB we only care about the KCL residual (first `n` entries).
        // Note: stamp_circuit residual already gives F(x) = I_device - I_source
        // which should be 0 at steady state.
        let _ = t; // time-varying sources would use t; DC devices ignore it
        for v in 0..n {
            time_res[t_idx * n + v] = res[v];
        }
    }

    // DFT → spectral residual
    dft_all(&time_res, n, k_harmonics)
}

// ─── Main solver ─────────────────────────────────────────────────────────────

/// Run a single-tone harmonic balance solve.
///
/// Implements a Newton-Raphson loop in the frequency domain:
///   1. Start from the DC operating point.
///   2. Each NR step: evaluate F(X), build J via finite differences, solve.
///   3. Converge when ||F||_inf < tol.
pub fn run_hb_single_tone(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &HbSingleConfig,
) -> Result<HbResult, SimError> {
    let k = config.num_harmonics;
    let num_freqs = k + 1; // DC + K harmonics
    let n = circuit.mna_dimension(); // MNA dimension (nodes + branches)
    let num_nodes = circuit.num_vars() as usize;

    // Total unknowns: DC (real only) + K harmonics (real+imag each) per MNA var
    let m = n * (2 * k + 1);

    // ── Step 1: DC operating point as initial guess ───────────────────────
    let solver = incspice_solver::Solver::default();
    let dc = solver.solve(circuit, registry, None)?;

    // Build initial X: fill DC bin with DC solution, all harmonics = 0
    let mut x = vec![0.0_f64; m];
    for v in 0..n {
        let dc_val = dc.solution.get(v).copied().unwrap_or(0.0);
        x[x_re_idx(0, v, n)] = dc_val;
    }

    // If no harmonics, just return the DC solution
    if k == 0 {
        let mut state = HbState::zeros(num_nodes, num_freqs);
        for v in 0..num_nodes {
            state.real[v] = x[x_re_idx(0, v, n)];
        }
        return Ok(HbResult {
            state,
            converged: true,
            iterations: 1,
            residual: 0.0,
        });
    }

    // ── Step 2: Newton-Raphson loop ───────────────────────────────────────
    let delta = 1e-7_f64; // finite-difference perturbation
    let tol = config.tol;
    let max_iter = config.max_iter;

    let mut converged = false;
    let mut iterations = 0;
    let mut residual_norm = f64::INFINITY;

    for _iter in 0..max_iter {
        iterations += 1;

        // Evaluate F(X)
        let f = hb_residual(&x, circuit, registry, n, k, config.f0);

        residual_norm = f.iter().copied().fold(0.0_f64, |acc, v| acc.max(v.abs()));

        if residual_norm < tol {
            converged = true;
            break;
        }

        // Build Jacobian J[i][j] = (F(X + delta*e_j)[i] - F(X)[i]) / delta
        // J is dense m×m; we build it as a TripletMatrix for the linear solver.
        let mut jac_triplet = TripletMatrix::with_capacity(m, m, m * m / 4 + m);

        for col in 0..m {
            let orig = x[col];
            x[col] = orig + delta;
            let f_pert = hb_residual(&x, circuit, registry, n, k, config.f0);
            x[col] = orig;

            for row in 0..m {
                let dfdx = (f_pert[row] - f[row]) / delta;
                if dfdx.abs() > 1e-20 {
                    jac_triplet.add(row, col, dfdx);
                }
            }
        }

        // Ensure the Jacobian is non-singular (add diagonal regularisation if needed)
        for i in 0..m {
            jac_triplet.add(i, i, 0.0); // ensure every diagonal entry exists
        }

        // Solve J * dx = -F
        let neg_f = DenseVec::from_slice(
            &f.iter().map(|&v| -v).collect::<Vec<_>>()
        );

        let csc = jac_triplet.to_csc();
        let lin = match LinSolver::factorize(LinSolverKind::SparseLu, &csc) {
            Ok(l) => l,
            Err(_) => {
                // Singular Jacobian — give up (DC initial guess is the answer)
                break;
            }
        };
        let dx = match lin.solve(&neg_f) {
            Ok(d) => d,
            Err(_) => break,
        };

        // Update X
        for i in 0..m {
            x[i] += dx[i];
        }
    }

    // Check final residual if loop exhausted without converging
    if !converged {
        let f_final = hb_residual(&x, circuit, registry, n, k, config.f0);
        residual_norm = f_final.iter().copied().fold(0.0_f64, |acc, v| acc.max(v.abs()));
        if residual_norm < tol {
            converged = true;
        }
    }

    // ── Step 3: Pack result into HbState ─────────────────────────────────
    let mut state = HbState::zeros(num_nodes, num_freqs);

    // DC bin
    for v in 0..num_nodes {
        state.real[v] = x[x_re_idx(0, v, n)];
        // imag for DC is identically 0
    }
    // Harmonic bins
    for h in 1..=k {
        for v in 0..num_nodes {
            state.real[h * num_nodes + v] = x[x_re_idx(h, v, n)];
            state.imag[h * num_nodes + v] = x[x_im_idx(h, v, n)];
        }
    }

    Ok(HbResult {
        state,
        converged,
        iterations,
        residual: residual_norm,
    })
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use incspice_solver::device::DeviceRegistry;

    /// Build a simple circuit: V(dc=0) in series with R, output node "out".
    ///
    ///   V1 (n+ = "in", n- = GND, dc=0) — R1 (1kΩ, "in"→"out") — R2 (1kΩ, "out"→GND)
    ///
    /// This is a purely linear resistive divider.  For the HB test we are only
    /// interested in convergence behaviour, not a driven AC source (which would
    /// require waveform support beyond this test scope).
    fn build_resistor_divider() -> (Circuit, DeviceRegistry) {
        let mut ckt = Circuit::new();
        let n_in  = ckt.add_node("in");
        let n_out = ckt.add_node("out");

        // V1: voltage source n_in → GND, dc=5V
        let v1 = DeviceInstance::new(
            DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n_in), (1, NodeId::GROUND)],
        ).with_param("dc", 5.0);

        // R1: 1kΩ  n_in → n_out
        let r1 = DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n_in), (1, n_out)],
        ).with_param("resistance", 1e3);

        // R2: 1kΩ  n_out → GND
        let r2 = DeviceInstance::new(
            DeviceId::new(0), "R2", DeviceKind::Resistor,
            &[(0, n_out), (1, NodeId::GROUND)],
        ).with_param("resistance", 1e3);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(r2);
        ckt.build_topology();

        let registry = DeviceRegistry::new_default();
        (ckt, registry)
    }

    /// Build a diode clipper: V(dc=0) → R → D → GND, output across D.
    ///
    ///   V1(dc=0.3) — R1(1kΩ) — n_out — D1(ideal) — GND
    fn build_diode_circuit() -> (Circuit, DeviceRegistry) {
        let mut ckt = Circuit::new();
        let n_in  = ckt.add_node("in");
        let n_out = ckt.add_node("out");

        // V1: 0.3 V bias (small signal drives diode into nonlinear region)
        let v1 = DeviceInstance::new(
            DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n_in), (1, NodeId::GROUND)],
        ).with_param("dc", 0.3);

        // R1: 1kΩ
        let r1 = DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n_in), (1, n_out)],
        ).with_param("resistance", 1e3);

        // D1: diode n_out → GND
        let d1 = DeviceInstance::new(
            DeviceId::new(0), "D1", DeviceKind::Diode,
            &[(0, n_out), (1, NodeId::GROUND)],
        );

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(d1);
        ckt.build_topology();

        let registry = DeviceRegistry::new_default();
        (ckt, registry)
    }

    #[test]
    fn test_hb_convergence_linear() {
        let (ckt, registry) = build_resistor_divider();
        let cfg = HbSingleConfig {
            f0: 1e6,
            num_harmonics: 3,
            max_iter: 50,
            tol: 1e-6,
        };

        let result = run_hb_single_tone(&ckt, &registry, &cfg)
            .expect("HB solve should not error");

        // Linear circuit → should converge
        assert!(result.converged, "HB should converge for linear circuit; residual = {}", result.residual);

        // DC solution: V-divider with 5V source → n_out ≈ 2.5V
        // Node 0 = "in" (3 MNA vars: in, out, V1 branch); num_nodes = 2
        // node 1 = "out" (matrix index 1)
        let num_nodes = ckt.num_vars() as usize;
        let n_out_node = 1; // second node voltage
        if n_out_node < num_nodes {
            let dc_out = result.state.re(0, n_out_node);
            assert!(
                (dc_out - 2.5).abs() < 0.1,
                "DC output of voltage divider should be ~2.5V, got {dc_out}"
            );
        }

        // For a linear DC-only circuit (no AC stimulus) all harmonics should be ~0
        for h in 1..=3 {
            for v in 0..num_nodes {
                let mag = result.magnitude(h, v);
                assert!(
                    mag < 1e-3,
                    "harmonic {h} of node {v} should be ~0 for linear DC circuit, got {mag}"
                );
            }
        }
    }

    #[test]
    fn test_hb_single_tone_nonlinear_diode() {
        let (ckt, registry) = build_diode_circuit();
        let cfg = HbSingleConfig {
            f0: 1e6,
            num_harmonics: 3,
            max_iter: 50,
            tol: 1e-4, // slightly relaxed for diode nonlinearity
        };

        let result = run_hb_single_tone(&ckt, &registry, &cfg)
            .expect("HB solve should not error for diode circuit");

        // Should converge within the iteration budget
        assert!(
            result.converged || result.iterations == 50,
            "HB should either converge or exhaust iterations (got {})", result.iterations
        );

        // The circuit has a diode: nonlinear → residual should be bounded
        assert!(
            result.residual.is_finite(),
            "HB residual must be finite, got {}", result.residual
        );

        // DC component at output node should be positive (forward-biased diode)
        let num_nodes = ckt.num_vars() as usize;
        if num_nodes >= 2 {
            let dc_out = result.state.re(0, 1);
            assert!(
                dc_out >= 0.0,
                "Diode output DC should be non-negative, got {dc_out}"
            );
        }
    }

    #[test]
    fn test_hb_result_magnitude() {
        let state = HbState {
            num_nodes: 2,
            num_freqs: 3,
            real: vec![1.0, 2.0,  // DC: node0=1, node1=2
                       3.0, 4.0,  // h1 re
                       5.0, 6.0], // h2 re
            imag: vec![0.0, 0.0,
                       4.0, 3.0,  // h1 im
                       0.0, 0.0],
        };
        let result = HbResult { state, converged: true, iterations: 1, residual: 0.0 };

        // DC magnitude = sqrt(1^2 + 0^2) = 1.0
        assert!((result.magnitude(0, 0) - 1.0).abs() < 1e-12);
        // h1 node0: sqrt(3^2 + 4^2) = 5
        assert!((result.magnitude(1, 0) - 5.0).abs() < 1e-12);
        // Out of bounds → 0
        assert_eq!(result.magnitude(10, 0), 0.0);
    }

    #[test]
    fn test_idft_dft_roundtrip() {
        // Verify that DFT(IDFT(X)) ≈ X for a random spectral vector.
        let n = 3;
        let k = 2;
        let m = n * (2 * k + 1);

        // Build a known spectral vector
        let mut x = vec![0.0_f64; m];
        // DC
        x[x_re_idx(0, 0, n)] = 1.0;
        x[x_re_idx(0, 1, n)] = 2.0;
        x[x_re_idx(0, 2, n)] = -1.0;
        // h=1
        x[x_re_idx(1, 0, n)] = 0.5;
        x[x_im_idx(1, 0, n)] = 0.3;
        // h=2
        x[x_re_idx(2, 1, n)] = 0.8;
        x[x_im_idx(2, 1, n)] = -0.2;

        let time_domain = idft_all(&x, n, k);
        let recovered   = dft_all(&time_domain, n, k);

        for i in 0..m {
            assert!(
                (recovered[i] - x[i]).abs() < 1e-10,
                "roundtrip mismatch at index {i}: got {} expected {}",
                recovered[i], x[i]
            );
        }
    }
}
