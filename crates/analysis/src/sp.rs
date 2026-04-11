//! S-parameter analysis (`.SP`) — N.3.1.
//!
//! Computes the N-port scattering matrix at each frequency by exciting each
//! port in turn with a test current and measuring the resulting wave variables.
//!
//! ## Algorithm
//!
//! For each frequency ω and each port p (1..N):
//! 1. Build the AC admittance matrix Y(jω) = G + jωC (same blocks as AC).
//! 2. Excite port p with 1 A; terminate all other ports with `R_port` (default 50 Ω).
//! 3. Solve for node voltages → compute port voltage V_p.
//! 4. Compute S-matrix column p from wave variables:
//!    `b_i = (V_i/R_port - I_i) / sqrt(4/R_port)`
//!    `a_p = 1 / sqrt(4/R_port)` (only the driven port)
//!    `S_ip = b_i / a_p`
//!
//! ## Port definition
//!
//! Ports are specified as a list of `(pos_node, neg_node)` pairs.  The
//! negative node is typically ground.  Port resistance defaults to 50 Ω.
//!
//! ## Output
//!
//! Returns an [`SpResult`] with the S-matrix at every frequency point.  The
//! matrix entry `S[freq][i][j]` is the complex transfer coefficient from port
//! j to port i.
//!
//! ## TODO
//!
//! Wire up to `Touchstone` writer in `crates/io/` once the io crate stabilises
//! its API. For now callers can access raw complex values from `SpResult`.

use bigospice_core::{Circuit, SimError, SimOptions};
use bigospice_device::DeviceRegistry;
use bigospice_linalg::{DenseVec, LinSolver, LinSolverKind, TripletMatrix};
use bigospice_solver::{stamp_circuit_gc_into, Solver, SolverConfig, NrConfig};

use crate::ac::AcSweepType;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One port definition: (positive_node_mna_index, negative_node_mna_index).
///
/// `neg` is `None` when the negative terminal is ground (most common case).
#[derive(Debug, Clone, Copy)]
pub struct SpPort {
    /// MNA row index of the positive terminal (0-based, ground excluded).
    pub pos: usize,
    /// MNA row index of the negative terminal, or `None` for ground.
    pub neg: Option<usize>,
}

impl SpPort {
    /// Convenience constructor — positive node only (negative = ground).
    pub fn new(pos: usize) -> Self {
        Self { pos, neg: None }
    }

    /// Positive node with explicit negative node.
    pub fn differential(pos: usize, neg: usize) -> Self {
        Self { pos, neg: Some(neg) }
    }
}

/// Configuration for `.SP` analysis.
#[derive(Debug, Clone)]
pub struct SpConfig {
    /// Port definitions.  Must have at least one port.
    pub ports: Vec<SpPort>,
    /// Reference impedance for each port in ohms (SPICE default = 50 Ω).
    /// If shorter than `ports`, the last value is repeated.
    pub port_impedances: Vec<f64>,
    /// Frequency sweep (reuses AC sweep config).
    pub freq_start: f64,
    pub freq_stop: f64,
    pub num_points: usize,
    pub sweep_type: AcSweepType,
}

impl SpConfig {
    /// Construct with uniform 50 Ω port impedances.
    pub fn new(
        ports: Vec<SpPort>,
        freq_start: f64,
        freq_stop: f64,
        num_points: usize,
        sweep_type: AcSweepType,
    ) -> Self {
        let n = ports.len();
        Self {
            ports,
            port_impedances: vec![50.0; n],
            freq_start,
            freq_stop,
            num_points,
            sweep_type,
        }
    }

    fn port_r(&self, port_idx: usize) -> f64 {
        let n = self.port_impedances.len();
        if n == 0 {
            50.0
        } else {
            self.port_impedances[port_idx.min(n - 1)]
        }
    }
}

/// Complex number (re, im) — avoids adding a num-complex dependency.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Complex {
    pub re: f64,
    pub im: f64,
}

impl Complex {
    pub fn new(re: f64, im: f64) -> Self {
        Self { re, im }
    }

    pub fn magnitude(&self) -> f64 {
        (self.re * self.re + self.im * self.im).sqrt()
    }

    pub fn phase_rad(&self) -> f64 {
        self.im.atan2(self.re)
    }

    pub fn magnitude_db(&self) -> f64 {
        20.0 * self.magnitude().log10()
    }
}

/// S-parameter analysis result.
///
/// `s_matrix[freq_idx][row_port][col_port]` = complex S_ij.
#[derive(Debug, Clone)]
pub struct SpResult {
    /// Frequency points in Hz.
    pub frequencies: Vec<f64>,
    /// Number of ports.
    pub num_ports: usize,
    /// S-matrix data: `s_matrix[freq][i][j]` = S_ij (from port j into port i).
    pub s_matrix: Vec<Vec<Vec<Complex>>>,
}

impl SpResult {
    /// Access S_ij at frequency index `f_idx`.
    pub fn s(&self, f_idx: usize, i: usize, j: usize) -> Complex {
        self.s_matrix[f_idx][i][j]
    }

    /// Return |S_ij| across all frequencies.
    pub fn magnitude(&self, i: usize, j: usize) -> Vec<f64> {
        self.s_matrix.iter().map(|m| m[i][j].magnitude()).collect()
    }
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

/// Run S-parameter analysis with default solver settings.
pub fn run_sp(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &SpConfig,
) -> Result<SpResult, SimError> {
    run_sp_inner(circuit, registry, config, None)
}

/// Run S-parameter analysis with `.OPTIONS` simulation settings.
pub fn run_sp_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &SpConfig,
    opts: &SimOptions,
) -> Result<SpResult, SimError> {
    run_sp_inner(circuit, registry, config, Some(opts))
}

// ---------------------------------------------------------------------------
// Core implementation
// ---------------------------------------------------------------------------

pub fn run_sp_inner(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &SpConfig,
    opts: Option<&SimOptions>,
) -> Result<SpResult, SimError> {
    if config.ports.is_empty() {
        return Err(SimError::Analysis("SP: at least one port required".into()));
    }

    let dim = circuit.mna_dimension();
    let n_ports = config.ports.len();

    // --- DC operating point for linearisation ---
    let solver = match opts {
        Some(o) => Solver::new(SolverConfig { nr: NrConfig::from(o), ..SolverConfig::default() }),
        None => Solver::default(),
    };
    let dc = solver.solve(circuit, registry, None)?;

    // --- Build G and C matrices at the OP ---
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

    let frequencies = generate_sp_frequencies(config);
    let n_freqs = frequencies.len();

    // Pre-allocate result: [freq][port_row][port_col]
    let zero_row = vec![Complex::new(0.0, 0.0); n_ports];
    let zero_mat = vec![zero_row; n_ports];
    let mut s_matrix = vec![zero_mat; n_freqs];

    let n2 = 2 * dim;
    let mut block_triplet = TripletMatrix::with_capacity(n2, n2, dim * 8 + n_ports * 4);
    let mut rhs = DenseVec::zeros(n2);

    for (f_idx, &freq) in frequencies.iter().enumerate() {
        let omega = 2.0 * std::f64::consts::PI * freq;

        // Build the real-valued 2N×2N block matrix for G + jωC:
        //   [  G   -ωC ] [x_re]   [b_re]
        //   [ ωC    G  ] [x_im] = [b_im]
        //
        // Port terminations: add G_port = 1/R_port to diagonal for each port
        // that is NOT the currently driven port (added per-column-solve below).
        block_triplet.clear();

        // Stamp G into top-left and bottom-right
        g_triplet.entries().for_each(|(r, c, v)| {
            block_triplet.add(r, c, v);
            block_triplet.add(dim + r, dim + c, v);
        });
        // Stamp ωC couplings
        c_triplet.entries().for_each(|(r, c, v)| {
            block_triplet.add(r, dim + c, -omega * v);
            block_triplet.add(dim + r, c, omega * v);
        });

        // For each driven port p, add termination conductances for all OTHER
        // ports, solve once, and extract S-column p.
        for p in 0..n_ports {
            let r_p = config.port_r(p);
            let _g_p = 1.0 / r_p;

            // Clone the base triplet and add port terminations
            let mut solve_triplet = block_triplet.clone();
            for q in 0..n_ports {
                if q == p {
                    continue;
                }
                let r_q = config.port_r(q);
                let g_q = 1.0 / r_q;
                let pos_q = config.ports[q].pos;
                // Stamp real conductance at pos node of port q
                if pos_q < dim {
                    solve_triplet.add(pos_q, pos_q, g_q);
                    solve_triplet.add(dim + pos_q, dim + pos_q, g_q);
                }
                if let Some(neg_q) = config.ports[q].neg {
                    if neg_q < dim {
                        solve_triplet.add(neg_q, neg_q, g_q);
                        solve_triplet.add(dim + neg_q, dim + neg_q, g_q);
                        // Off-diagonal terms for differential port
                        if pos_q < dim {
                            solve_triplet.add(pos_q, neg_q, -g_q);
                            solve_triplet.add(neg_q, pos_q, -g_q);
                            solve_triplet.add(dim + pos_q, dim + neg_q, -g_q);
                            solve_triplet.add(dim + neg_q, dim + pos_q, -g_q);
                        }
                    }
                }
            }

            // RHS: inject 1 A into driven port p (real part only → unit excitation)
            rhs.fill_zero();
            let pos_p = config.ports[p].pos;
            if pos_p < dim {
                rhs[pos_p] = 1.0; // real part of current injection
            }
            if let Some(neg_p) = config.ports[p].neg {
                if neg_p < dim {
                    rhs[neg_p] = -1.0;
                }
            }

            let csc = solve_triplet.to_csc();
            let lin = LinSolver::factorize(LinSolverKind::SparseLu, &csc)
                .map_err(|_| SimError::Analysis("SP: singular admittance matrix".into()))?;
            let sol = lin.solve(&rhs)?;

            // Compute S-column p from wave variables.
            //
            // For port i: V_i = sol[pos_i] - sol[neg_i]  (complex)
            //             I_i = -V_i / R_i  (port current into network)
            //             b_i = (V_i / sqrt(R_i) - sqrt(R_i) * I_i) / 2
            //             a_p = 1 / (2 * sqrt(R_p / R_p)) × ...
            //
            // Simplified: with unit current source excitation at port p,
            //   a_p = sqrt(R_p) / 2   (incident wave amplitude)
            //   b_i = V_i / (2 * sqrt(R_i))  + ...
            //
            // Using wave variable definition (IEEE Std 1597):
            //   a_p = (V_p + R_p * I_p) / (2 * sqrt(R_p))
            //   b_i = (V_i - R_i * I_i) / (2 * sqrt(R_i))
            //
            // With port termination: I_q = -V_q / R_q for q≠p,
            // For the driven port p: I_p = 1 (injected), V_p = sol[pos_p]
            //   a_p = (V_p + R_p * 1) / (2 * sqrt(R_p))
            //   b_p = (V_p - R_p * 1) / (2 * sqrt(R_p))
            //   For q≠p: I_q = -V_q / R_q (terminated)
            //   b_q = (V_q - R_q * (-V_q/R_q)) / (2*sqrt(R_q)) = V_q / sqrt(R_q)
            //   S_qp = b_q / a_p

            let v_p_re = if pos_p < dim { sol[pos_p] } else { 0.0 };
            let v_p_im = if pos_p < dim { sol[dim + pos_p] } else { 0.0 };
            let v_p_re = v_p_re - config.ports[p].neg.filter(|&n| n < dim).map(|n| sol[n]).unwrap_or(0.0);
            let v_p_im = v_p_im - config.ports[p].neg.filter(|&n| n < dim).map(|n| sol[dim + n]).unwrap_or(0.0);

            // a_p = (V_p + R_p) / (2 * sqrt(R_p))  [I_p = 1 A real]
            let sqrt_rp = r_p.sqrt();
            let a_p_re = (v_p_re + r_p) / (2.0 * sqrt_rp);
            let a_p_im = v_p_im / (2.0 * sqrt_rp);
            let a_mag_sq = a_p_re * a_p_re + a_p_im * a_p_im;

            for i in 0..n_ports {
                let pos_i = config.ports[i].pos;
                let r_i = config.port_r(i);
                let sqrt_ri = r_i.sqrt();

                let v_i_re = if pos_i < dim { sol[pos_i] } else { 0.0 };
                let v_i_im = if pos_i < dim { sol[dim + pos_i] } else { 0.0 };
                let v_i_re = v_i_re - config.ports[i].neg.filter(|&n| n < dim).map(|n| sol[n]).unwrap_or(0.0);
                let v_i_im = v_i_im - config.ports[i].neg.filter(|&n| n < dim).map(|n| sol[dim + n]).unwrap_or(0.0);

                let (b_i_re, b_i_im) = if i == p {
                    // b_p = (V_p - R_p) / (2 * sqrt(R_p))
                    ((v_p_re - r_p) / (2.0 * sqrt_rp), v_p_im / (2.0 * sqrt_rp))
                } else {
                    // b_i = V_i / sqrt(R_i)  (terminated port: I_i = -V_i/R_i)
                    (v_i_re / sqrt_ri, v_i_im / sqrt_ri)
                };

                // S_ip = b_i / a_p  (complex division)
                let (s_re, s_im) = if a_mag_sq > 1e-300 {
                    (
                        (b_i_re * a_p_re + b_i_im * a_p_im) / a_mag_sq,
                        (b_i_im * a_p_re - b_i_re * a_p_im) / a_mag_sq,
                    )
                } else {
                    (0.0, 0.0)
                };
                s_matrix[f_idx][i][p] = Complex::new(s_re, s_im);
            }
        }
    }

    Ok(SpResult { frequencies, num_ports: n_ports, s_matrix })
}

pub fn generate_sp_frequencies(config: &SpConfig) -> Vec<f64> {
    match config.sweep_type {
        AcSweepType::Linear => {
            let denom = (config.num_points.max(1) - 1).max(1) as f64;
            let step = (config.freq_stop - config.freq_start) / denom;
            (0..config.num_points)
                .map(|i| config.freq_start + i as f64 * step)
                .collect()
        }
        AcSweepType::Decade => {
            let log_start = config.freq_start.log10();
            let log_stop = config.freq_stop.log10();
            let num_decades = log_stop - log_start;
            let total = (config.num_points as f64 * num_decades).ceil() as usize;
            let step = (log_stop - log_start) / total.max(1) as f64;
            (0..=total).map(|i| 10.0_f64.powf(log_start + i as f64 * step)).collect()
        }
        AcSweepType::Octave => {
            let log_start = config.freq_start.log2();
            let log_stop = config.freq_stop.log2();
            let num_octaves = log_stop - log_start;
            let total = (config.num_points as f64 * num_octaves).ceil() as usize;
            let step = (log_stop - log_start) / total.max(1) as f64;
            (0..=total).map(|i| 2.0_f64.powf(log_start + i as f64 * step)).collect()
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use bigospice_device::DeviceRegistry;

    /// Build a 2-port "thru" circuit: two nodes connected by a wire (zero resistance).
    ///
    /// Represented as R = 1e-6 Ω (near short) between the two port nodes.
    fn thru_circuit() -> (Circuit, SpConfig) {
        // Two-port thru: port1 = n1, port2 = n2.
        // Near-ideal wire (1 µΩ) from n1 to n2.
        // Bias resistors (1 GΩ) from each port to ground give a DC path so
        // the admittance matrix is non-singular without a V-source.
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");

        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R_thru",
                DeviceKind::Resistor,
                &[(0, n1), (1, n2)],
            )
            .with_param("resistance", 1e-6),
        );
        // DC bias to ground — large enough to not load the RF signal
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R_bias1",
                DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)],
            )
            .with_param("resistance", 1e9),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R_bias2",
                DeviceKind::Resistor,
                &[(0, n2), (1, NodeId::GROUND)],
            )
            .with_param("resistance", 1e9),
        );
        ckt.build_topology();

        // NodeId.0 is 1-based; matrix index = NodeId.0 - 1 (ground excluded)
        let n1_idx = (n1.0 - 1) as usize;
        let n2_idx = (n2.0 - 1) as usize;
        let config = SpConfig::new(
            vec![SpPort::new(n1_idx), SpPort::new(n2_idx)],
            1e6, 1e9, 3,
            AcSweepType::Linear,
        );
        (ckt, config)
    }

    #[test]
    fn sp_two_port_thru_s21_near_one() {
        let (ckt, config) = thru_circuit();
        let reg = DeviceRegistry::new_default();
        let result = run_sp(&ckt, &reg, &config).expect("sp thru");
        assert_eq!(result.num_ports, 2);
        assert!(!result.frequencies.is_empty());
        // For a thru: |S21| ≈ 1, |S11| ≈ 0
        for f_idx in 0..result.frequencies.len() {
            let s21 = result.s(f_idx, 1, 0).magnitude();
            let s11 = result.s(f_idx, 0, 0).magnitude();
            assert!(s21 > 0.9, "|S21| = {s21} at f={}", result.frequencies[f_idx]);
            assert!(s11 < 0.15, "|S11| = {s11} at f={}", result.frequencies[f_idx]);
        }
    }

    #[test]
    fn sp_result_accessors() {
        let r = SpResult {
            frequencies: vec![1e6, 2e6],
            num_ports: 2,
            s_matrix: vec![
                vec![
                    vec![Complex::new(0.1, 0.0), Complex::new(0.9, 0.0)],
                    vec![Complex::new(0.9, 0.0), Complex::new(0.1, 0.0)],
                ],
                vec![
                    vec![Complex::new(0.15, 0.0), Complex::new(0.85, 0.0)],
                    vec![Complex::new(0.85, 0.0), Complex::new(0.15, 0.0)],
                ],
            ],
        };
        assert!((r.s(0, 1, 0).magnitude() - 0.9).abs() < 1e-9);
        let mags = r.magnitude(0, 0);
        assert_eq!(mags.len(), 2);
    }
}
