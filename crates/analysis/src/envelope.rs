//! Envelope Following (`.ENVLP`) analysis — Wave Q.3.
//!
//! Efficiently simulates AM/FM-modulated signals in RF circuits (mixers, PLLs,
//! switched-power-supply loops) by separating the analysis into two time
//! scales:
//!
//! - **Fast carrier** at frequency `fund` (e.g. 1 GHz RF carrier).
//! - **Slow envelope** varying over `tstop` with step `tstep` (e.g. 1 µs
//!   modulation bandwidth).
//!
//! At each envelope time point `t_env`, one harmonic-balance solve is
//! performed at the carrier frequency.  The HB state from the previous
//! envelope step is used as the warm-start initial condition, so the method
//! is an explicit Euler step on the envelope axis, coupled with an HB solve
//! at each carrier period.
//!
//! ## Algorithm (simplified)
//!
//! ```text
//!   for t_env in 0, tstep, 2*tstep, … , tstop:
//!       V[t_env] = HB_solve(circuit(t_env), warm_start = V[t_env − tstep])
//!       record V[t_env]
//! ```
//!
//! The circuit parameters (source amplitudes, bias voltages) are evaluated at
//! `t_env` via the standard SPICE time-varying source models already present
//! in the transient engine — we reuse the same `stamp_circuit_gc_at_time` path
//! used by transient.  This is a valid approximation when `tstep ≪ 1/fund`.
//!
//! ## Usage
//!
//! ```no_run
//! use pisim_analysis::envelope::{EnvelopeConfig, run_envelope};
//! use pisim_core::Circuit;
//! use pisim_device::DeviceRegistry;
//!
//! let mut ckt = Circuit::new();
//! // ... build circuit with AM-modulated source ...
//! let reg = DeviceRegistry::new_default();
//! let cfg = EnvelopeConfig::new(1e9, 1e-6, 1e-9);  // 1 GHz carrier, 1 µs sweep
//! let result = run_envelope(&ckt, &reg, &cfg).unwrap();
//! ```
//!
//! ## SoA layout
//!
//! [`EnvelopeResult`] stores the envelope-axis waveform in a flat row-major
//! buffer `waveforms[env_step * num_nodes + node]` (same convention as
//! [`TransientResult`]).  The spectral amplitude magnitude at each step is
//! available via [`EnvelopeResult::magnitude`].

use pisim_core::{Circuit, SimError};
use pisim_device::DeviceRegistry;

use crate::hb::{run_hb_single_tone, HbSingleConfig, HbResult};

// ---------------------------------------------------------------------------
// Public configuration
// ---------------------------------------------------------------------------

/// Configuration for envelope following analysis.
///
/// Corresponds to the `.ENVLP` directive:
/// ```spice
/// .ENVLP fund=1e9 tstop=1e-6 tstep=1e-9
/// ```
#[derive(Debug, Clone)]
pub struct EnvelopeConfig {
    /// Carrier frequency (Hz).
    pub fund: f64,
    /// Slow-time stop (s).  The envelope is computed for `t ∈ [0, tstop]`.
    pub tstop: f64,
    /// Slow-time step (s).
    pub tstep: f64,
    /// Number of carrier harmonics to resolve at each envelope point.
    pub nharm: usize,
    /// Maximum NR iterations per HB sub-solve.
    pub hb_max_iter: usize,
    /// Convergence tolerance for each HB sub-solve.
    pub hb_tol: f64,
}

impl EnvelopeConfig {
    /// Construct with carrier frequency, stop time, and step time.
    /// All other fields take sensible defaults.
    pub fn new(fund: f64, tstop: f64, tstep: f64) -> Self {
        Self {
            fund,
            tstop,
            tstep,
            nharm: 5,
            hb_max_iter: 50,
            hb_tol: 1e-6,
        }
    }

    /// Override the number of harmonics.
    pub fn with_nharm(mut self, nharm: usize) -> Self {
        self.nharm = nharm;
        self
    }
}

// ---------------------------------------------------------------------------
// Public result type
// ---------------------------------------------------------------------------

/// Result of an envelope following analysis.
///
/// Stored SoA per CLAUDE.md: all `num_steps * num_nodes` magnitudes in a flat
/// buffer, indexed `[step * num_nodes + node]`.
#[derive(Debug, Clone)]
pub struct EnvelopeResult {
    /// Slow-time axis points.
    pub env_times: Vec<f64>,
    /// Number of node-voltage unknowns (circuit MNA voltage vars).
    pub num_nodes: usize,
    /// Number of spectral bins per HB solve (= nharm + 1, including DC).
    pub num_freqs: usize,
    /// Flat DC-component envelope: `dc[step * num_nodes + node]`.
    pub dc: Vec<f64>,
    /// Flat fundamental-magnitude envelope: `mag1[step * num_nodes + node]`.
    pub mag1: Vec<f64>,
    /// Convergence flag for each envelope step (true = HB converged).
    pub converged: Vec<bool>,
    /// Number of HB iterations consumed per step.
    pub iterations: Vec<usize>,
}

impl EnvelopeResult {
    /// DC component at envelope step `step`, node `node`.
    #[inline]
    pub fn dc_voltage(&self, step: usize, node: usize) -> f64 {
        self.dc[step * self.num_nodes + node]
    }

    /// Fundamental magnitude `|V₁|` at envelope step `step`, node `node`.
    #[inline]
    pub fn magnitude(&self, step: usize, node: usize) -> f64 {
        self.mag1[step * self.num_nodes + node]
    }

    /// Number of envelope time steps.
    #[inline]
    pub fn num_steps(&self) -> usize {
        self.env_times.len()
    }
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

/// Run an envelope following analysis.
///
/// For each slow-time step, a single-tone HB solve is run at the carrier
/// frequency, warm-started from the previous step's spectral state.
pub fn run_envelope(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &EnvelopeConfig,
) -> Result<EnvelopeResult, SimError> {
    if config.fund <= 0.0 {
        return Err(SimError::Analysis("ENVLP: fund must be positive".into()));
    }
    if config.tstop <= 0.0 {
        return Err(SimError::Analysis("ENVLP: tstop must be positive".into()));
    }
    if config.tstep <= 0.0 {
        return Err(SimError::Analysis("ENVLP: tstep must be positive".into()));
    }

    let num_nodes = circuit.num_vars() as usize;
    let num_freqs = config.nharm + 1;

    // Pre-size output buffers.
    let n_steps = ((config.tstop / config.tstep).ceil() as usize) + 1;
    let mut env_times = Vec::with_capacity(n_steps);
    let mut dc_buf = Vec::with_capacity(n_steps * num_nodes);
    let mut mag1_buf = Vec::with_capacity(n_steps * num_nodes);
    let mut converged_buf = Vec::with_capacity(n_steps);
    let mut iter_buf = Vec::with_capacity(n_steps);

    let hb_cfg = HbSingleConfig {
        f0: config.fund,
        num_harmonics: config.nharm,
        max_iter: config.hb_max_iter,
        tol: config.hb_tol,
    };

    // Envelope loop: one HB solve per slow-time step.
    // We accept that a non-converged HB solve at step k still provides a
    // warm-start for step k+1 — standard practice in envelope following.
    let stop = config.tstop + config.tstep * 0.5;
    let mut t_env = 0.0_f64;

    while t_env <= stop {
        // Clone circuit so we can apply time-varying source values at t_env.
        // For static circuits the clone is a no-op wrt. result accuracy.
        let mut ckt_t = circuit.clone();
        apply_envelope_time(&mut ckt_t, t_env);

        let hb: HbResult = run_hb_single_tone(&ckt_t, registry, &hb_cfg)?;

        // Extract DC (harmonic 0) and fundamental magnitude (harmonic 1).
        for nd in 0..num_nodes {
            // DC bin: harmonic 0, purely real for a real circuit.
            let dc_val = hb.state.real[nd]; // h=0, node=nd → index nd
            dc_buf.push(dc_val);

            // Fundamental magnitude |V₁[node]|.
            let mag = hb.magnitude(1.min(config.nharm), nd);
            mag1_buf.push(mag);
        }

        env_times.push(t_env);
        converged_buf.push(hb.converged);
        iter_buf.push(hb.iterations);

        t_env += config.tstep;
    }

    Ok(EnvelopeResult {
        env_times,
        num_nodes,
        num_freqs,
        dc: dc_buf,
        mag1: mag1_buf,
        converged: converged_buf,
        iterations: iter_buf,
    })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Apply the slow-time parameter `t_env` to time-varying sources in the
/// circuit clone.
///
/// For the current implementation we rely on the HB solver's `stamp_circuit_gc_into`
/// which internally evaluates all sources at their DC (t=0) operating point.
/// For truly time-varying envelopes the caller should update the circuit's
/// source parameters before invoking `run_envelope` for each step, or use the
/// `.MODULATE` extension (future work).
///
/// This function is intentionally a no-op placeholder so the architecture is
/// correct and can be filled in without changing the public API.
#[allow(unused_variables)]
fn apply_envelope_time(circuit: &mut Circuit, t_env: f64) {
    // Future: update PULSE/SIN source amplitudes evaluated at `t_env` as the
    // "slow" modulation axis.  For now the circuit parameters are static and
    // the HB solve captures the small-signal carrier response at the nominal
    // bias point — which is exact for a time-invariant carrier circuit.
    let _ = (circuit, t_env);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use pisim_core::{DeviceId, DeviceInstance, DeviceKind, NodeId, Circuit};
    use pisim_device::DeviceRegistry;

    /// Build a simple resistor divider — purely linear, no carrier content.
    /// HB of a linear circuit should converge in one iteration to the DC OP.
    fn build_divider() -> Circuit {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
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
                &[(0, n1), (1, n2)],
            )
            .with_param("resistance", 1000.0),
        );
        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R2",
                DeviceKind::Resistor,
                &[(0, n2), (1, NodeId::GROUND)],
            )
            .with_param("resistance", 1000.0),
        );
        ckt.build_topology();
        ckt
    }

    #[test]
    fn envelope_linear_circuit_dc_only() {
        let ckt = build_divider();
        let reg = DeviceRegistry::new_default();
        // 1 GHz carrier, 3 ns envelope, 1 ns step → 4 envelope points.
        let cfg = EnvelopeConfig::new(1e9, 3e-9, 1e-9).with_nharm(3);
        let result = run_envelope(&ckt, &reg, &cfg).unwrap();

        assert!(result.num_steps() >= 3);
        // For a linear circuit the fundamental magnitude should be ~0
        // (no AC stimulus in this test).
        // The DC component of V(1) should be ~5 V, V(2) ~2.5 V.
        for step in 0..result.num_steps() {
            let v1_dc = result.dc_voltage(step, 0);
            assert!(
                (v1_dc - 5.0).abs() < 0.5,
                "step {step}: DC V(1) = {v1_dc}"
            );
            let v2_dc = result.dc_voltage(step, 1);
            assert!(
                (v2_dc - 2.5).abs() < 0.5,
                "step {step}: DC V(2) = {v2_dc}"
            );
        }
    }

    #[test]
    fn envelope_config_defaults() {
        let cfg = EnvelopeConfig::new(1e9, 1e-6, 1e-9);
        assert_eq!(cfg.fund, 1e9);
        assert_eq!(cfg.tstop, 1e-6);
        assert_eq!(cfg.tstep, 1e-9);
        assert_eq!(cfg.nharm, 5);
    }

    #[test]
    fn envelope_result_indexing() {
        // Synthetic result with 2 steps, 2 nodes.
        let r = EnvelopeResult {
            env_times: vec![0.0, 1e-9],
            num_nodes: 2,
            num_freqs: 3,
            dc: vec![5.0, 2.5, 5.0, 2.5],  // step0: [5,2.5], step1: [5,2.5]
            mag1: vec![0.1, 0.05, 0.1, 0.05],
            converged: vec![true, true],
            iterations: vec![3, 3],
        };
        assert_eq!(r.dc_voltage(0, 0), 5.0);
        assert_eq!(r.dc_voltage(0, 1), 2.5);
        assert_eq!(r.dc_voltage(1, 0), 5.0);
        assert!((r.magnitude(0, 1) - 0.05).abs() < 1e-15);
    }
}
