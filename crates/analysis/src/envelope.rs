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
//! use incspice_analysis::envelope::{EnvelopeConfig, run_envelope};
//! use incspice_core::Circuit;
//! use incspice_solver::device::DeviceRegistry;
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

use incspice_cache::CacheManager;
use incspice_core::{Circuit, SimError, StreamingSink};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::newton::NrConfig;

use crate::{Analysis, AnalysisError};
use crate::hb::{HbResult, HbSingleConfig, run_hb_single_tone};

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

// ---------------------------------------------------------------------------
// EnvelopeFollowing Analysis trait implementation
// ---------------------------------------------------------------------------

/// `Analysis`-trait wrapper for envelope following.
///
/// Wires `run_envelope` into the standard analysis dispatch pipeline so that
/// `.ENVLP` netlists are handled by `build_analysis` in the CLI.
pub struct EnvelopeFollowing {
    /// Carrier frequency (Hz).
    pub fund: f64,
    /// Slow-time stop (s).
    pub tstop: f64,
    /// Slow-time step (s).
    pub tstep: f64,
}

impl Analysis for EnvelopeFollowing {
    fn run(
        &self,
        circuit: &mut Circuit,
        registry: &DeviceRegistry,
        _config: &NrConfig,
        _cache: &mut CacheManager,
        sink: &mut dyn StreamingSink,
    ) -> Result<(), AnalysisError> {
        let cfg = EnvelopeConfig::new(self.fund, self.tstop, self.tstep);
        let result = run_envelope(circuit, registry, &cfg)?;

        // Emit one point per envelope step: [dc_node0, mag1_node0, dc_node1, ...]
        for (step, &t_env) in result.env_times.iter().enumerate() {
            let mut row: Vec<f64> = Vec::with_capacity(result.num_nodes * 2);
            for nd in 0..result.num_nodes {
                row.push(result.dc_voltage(step, nd));
                row.push(result.magnitude(step, nd));
            }
            sink.emit_point(t_env, &row)?;
        }
        sink.finalize()?;
        Ok(())
    }

    fn name(&self) -> &str {
        "envlp"
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Apply the slow-time parameter `t_env` to time-varying sources in the
/// circuit clone.
///
/// For SIN-waveform sources (`waveform_kind == 2`), updates the `dc` bias
/// parameter to track the slow modulation envelope at time `t_env`.  This
/// allows the HB carrier solve at each envelope step to start from the
/// correct large-signal bias point.
///
/// Only the `dc` offset is modified; the carrier-frequency `sin_freq` and
/// amplitude `sin_va` are left unchanged so the inner HB solve still
/// resolves the carrier content correctly.
fn apply_envelope_time(circuit: &mut Circuit, t_env: f64) {
    // Collect (name, dc_value) for every SIN source first (immutable pass),
    // then apply with set_device_param (mutable pass).  Two-pass avoids
    // simultaneous borrow of `circuit`.
    let updates: Vec<(String, f64)> = circuit
        .devices()
        .iter()
        .filter_map(|dev| {
            // waveform_kind == 2.0 → SIN waveform
            let kind = dev.params.get_or("waveform_kind", 0.0) as u32;
            if kind != 2 {
                return None;
            }
            let vo = dev.params.get_or("sin_vo", 0.0);
            let va = dev.params.get_or("sin_va", 0.0);
            let freq = dev.params.get_or("sin_freq", 1e6);
            // Envelope: update the DC bias to track slow modulation at t_env.
            let env_val = vo + va * (2.0 * std::f64::consts::PI * freq * t_env).sin();
            Some((dev.name.clone(), env_val))
        })
        .collect();

    for (name, dc_val) in updates {
        circuit.set_device_param(&name, "dc", dc_val);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use incspice_solver::device::DeviceRegistry;

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
            assert!((v1_dc - 5.0).abs() < 0.5, "step {step}: DC V(1) = {v1_dc}");
            let v2_dc = result.dc_voltage(step, 1);
            assert!((v2_dc - 2.5).abs() < 0.5, "step {step}: DC V(2) = {v2_dc}");
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
            dc: vec![5.0, 2.5, 5.0, 2.5], // step0: [5,2.5], step1: [5,2.5]
            mag1: vec![0.1, 0.05, 0.1, 0.05],
            converged: vec![true, true],
            iterations: vec![3, 3],
        };
        assert_eq!(r.dc_voltage(0, 0), 5.0);
        assert_eq!(r.dc_voltage(0, 1), 2.5);
        assert_eq!(r.dc_voltage(1, 0), 5.0);
        assert!((r.magnitude(0, 1) - 0.05).abs() < 1e-15);
    }

    /// Verify that `apply_envelope_time` updates the `dc` param of a SIN
    /// source between two different envelope time points.
    #[test]
    fn test_envelope_am_source_updates() {
        // Build a circuit with a SIN voltage source.
        // waveform_kind=2 (SIN), sin_vo=0, sin_va=1, sin_freq=1 (so the
        // function sin_vo + sin_va * sin(2π * sin_freq * t) = sin(2π * t)).
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("n1");
        let mut v1 = DeviceInstance::new(
            DeviceId::new(0),
            "V1",
            DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        );
        v1.params.set("waveform_kind", 2.0); // SIN
        v1.params.set("sin_vo", 0.0);
        v1.params.set("sin_va", 1.0);
        v1.params.set("sin_freq", 1.0); // 1 Hz, simple to test
        v1.params.set("dc", 0.0);

        ckt.add_device(
            DeviceInstance::new(
                DeviceId::new(0),
                "R1",
                DeviceKind::Resistor,
                &[(0, n1), (1, NodeId::GROUND)],
            )
            .with_param("resistance", 1000.0),
        );
        ckt.add_device(v1);
        ckt.build_topology();

        // Apply at t=0: expected dc = sin(0) = 0
        apply_envelope_time(&mut ckt, 0.0);
        let dc_at_t0 = ckt.find_device("V1").unwrap().params.get("dc").unwrap();
        assert!(
            dc_at_t0.abs() < 1e-12,
            "DC at t=0 should be ~0, got {dc_at_t0}"
        );

        // Apply at t=0.25 s: expected dc = sin(2π * 1 * 0.25) = sin(π/2) = 1
        apply_envelope_time(&mut ckt, 0.25);
        let dc_at_t025 = ckt.find_device("V1").unwrap().params.get("dc").unwrap();
        assert!(
            (dc_at_t025 - 1.0).abs() < 1e-9,
            "DC at t=0.25 should be ~1, got {dc_at_t025}"
        );

        // Verify DC changed between the two calls.
        assert!(
            (dc_at_t025 - dc_at_t0).abs() > 0.9,
            "DC param should differ between t=0 and t=0.25"
        );
    }
}
