//! Generic parameter sweep runner — Phase 3.5.
//!
//! Drives an arbitrary inner analysis (DC OP, AC, TRAN, ...) across a list of
//! parameter values supplied by `.STEP` directives in the netlist (or any
//! caller-supplied set).
//!
//! ## Design
//!
//! Stays in the data-oriented spirit of the rest of `pisim-analysis`:
//!
//! * `ParamSweep` is a tiny struct of arrays — one entry per swept point —
//!   so the hot loop is a contiguous index over `Vec<f64>`.
//! * The inner analysis is invoked through a closure that receives a mutable
//!   `Circuit` clone, so we never mutate the original circuit and downstream
//!   incremental caches stay valid.
//! * No trait objects, no virtual dispatch — the closure is generic so the
//!   compiler can monomorphize the runner per analysis type.
//!
//! ## Example
//!
//! ```rust,ignore
//! use pisim_analysis::sweep::{ParamSweep, ParamTarget};
//! use pisim_analysis::dc_op::run_dc_op;
//!
//! let sweep = ParamSweep::lin(ParamTarget::DeviceParam("r1".into(), "resistance".into()),
//!                              1e3, 5e3, 1e3);
//! let results = sweep.run(&circuit, &registry, |ckt, reg| run_dc_op(ckt, reg))?;
//! ```

use ahash::AHashMap;
use pisim_cache::CacheManager;
use pisim_core::{Circuit, SimError};

/// Identifies what a single sweep value should mutate.
///
/// Two flavours:
///
/// * `GlobalParam(name)` — overwrite a `.PARAM` value (the caller is
///   responsible for re-evaluating dependent element params before each
///   inner run; not all callers need this).
/// * `DeviceParam(device, key)` — directly poke a device instance parameter
///   (e.g. `r1.resistance`, `c2.capacitance`, `m1.w`). Lowercase device names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParamTarget {
    /// Modify a `.PARAM` map entry.
    GlobalParam(String),
    /// Modify a device instance parameter directly.
    DeviceParam(String, String),
}

/// A flat parameter sweep — one target, a list of values.
///
/// All sweep generators (lin/dec/oct/list) reduce to this one struct.
#[derive(Debug, Clone)]
pub struct ParamSweep {
    /// What to mutate at each sweep point.
    pub target: ParamTarget,
    /// Pre-materialized list of values (from `.STEP`).
    pub values: Vec<f64>,
}

impl ParamSweep {
    /// Construct from a target and an explicit list of values.
    pub fn new(target: ParamTarget, values: Vec<f64>) -> Self {
        Self { target, values }
    }

    /// `.STEP LIN target start stop step`
    pub fn lin(target: ParamTarget, start: f64, stop: f64, step: f64) -> Self {
        let mut values = Vec::new();
        if step <= 0.0 || stop < start {
            values.push(start);
        } else {
            let eps = step.abs() * 1e-9;
            let mut v = start;
            while v <= stop + eps {
                values.push(v);
                v += step;
            }
        }
        Self::new(target, values)
    }

    /// `.STEP DEC target start stop ppd` — points per decade.
    pub fn dec(target: ParamTarget, start: f64, stop: f64, ppd: usize) -> Self {
        let mut values = Vec::new();
        if start <= 0.0 || stop <= 0.0 || ppd == 0 {
            values.push(start);
        } else {
            let n_decades = (stop / start).log10();
            let n_points = (n_decades * ppd as f64).ceil() as usize + 1;
            values = (0..n_points)
                .map(|i| start * 10f64.powf(i as f64 / ppd as f64))
                .filter(|v| *v <= stop * (1.0 + 1e-12))
                .collect();
        }
        Self::new(target, values)
    }

    /// `.STEP OCT target start stop ppo` — points per octave.
    pub fn oct(target: ParamTarget, start: f64, stop: f64, ppo: usize) -> Self {
        let mut values = Vec::new();
        if start <= 0.0 || stop <= 0.0 || ppo == 0 {
            values.push(start);
        } else {
            let n_octaves = (stop / start).log2();
            let n_points = (n_octaves * ppo as f64).ceil() as usize + 1;
            values = (0..n_points)
                .map(|i| start * 2f64.powf(i as f64 / ppo as f64))
                .filter(|v| *v <= stop * (1.0 + 1e-12))
                .collect();
        }
        Self::new(target, values)
    }

    /// `.STEP LIST target v1 v2 v3 ...`
    pub fn list(target: ParamTarget, values: Vec<f64>) -> Self {
        Self::new(target, values)
    }

    /// Number of sweep points.
    pub fn len(&self) -> usize {
        self.values.len()
    }

    /// Whether the sweep has any points.
    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }

    /// Apply this sweep's value at index `i` to a clone of `base` and return it.
    ///
    /// `params_override` is provided so callers that want to chain global
    /// `.PARAM` updates can intercept the value before it lands on a device.
    /// Returns the modified circuit clone (or an error if the device or
    /// parameter cannot be located).
    pub fn apply(&self, base: &Circuit, i: usize) -> Result<Circuit, SimError> {
        if i >= self.values.len() {
            return Err(SimError::Parse(format!(
                "ParamSweep::apply: index {} out of range (len {})",
                i,
                self.values.len()
            )));
        }
        let v = self.values[i];
        let mut ckt = base.clone();

        match &self.target {
            ParamTarget::DeviceParam(dev_name, key) => {
                let lower = dev_name.to_lowercase();
                if !ckt.set_device_param(&lower, key, v) {
                    return Err(SimError::Parse(format!(
                        "ParamSweep: device '{dev_name}' or param '{key}' not found in circuit"
                    )));
                }
            }
            ParamTarget::GlobalParam(_) => {
                // For global .PARAM sweeps the caller is expected to re-evaluate
                // any dependent device parameters before calling apply().
                // Since the circuit alone doesn't carry the .PARAM map at this
                // point, we apply nothing here — the caller-supplied closure
                // sees the index `i` and can dispatch on it.
            }
        }
        Ok(ckt)
    }

    /// Run an inner analysis once per sweep point.
    ///
    /// `f` receives the per-point modified circuit clone and the
    /// (target, value) pair so it can build/lookup whatever per-point context
    /// it needs.  It returns one inner result per sweep point.
    ///
    /// The closure is generic so the compiler monomorphizes the runner — no
    /// trait-object indirection in the hot loop.
    pub fn run<R, F>(&self, base: &Circuit, mut f: F) -> Result<Vec<R>, SimError>
    where
        F: FnMut(&Circuit, &ParamTarget, f64) -> Result<R, SimError>,
    {
        let mut out = Vec::with_capacity(self.values.len());
        for (i, &v) in self.values.iter().enumerate() {
            let ckt = self.apply(base, i)?;
            out.push(f(&ckt, &self.target, v)?);
        }
        Ok(out)
    }

    /// Cache-aware sweep runner for `.STEP` directives (M.4).
    ///
    /// Before the sweep starts, builds a [`CacheManager`] from `base`
    /// (topology hash, symbolic-LU placeholder, dirty-tracker adjacency).
    ///
    /// At each step:
    /// 1. Calls `cache.mark_param_changed(device_id, param, new_value / prev_value)`
    ///    so the dirty tracker and compiled-eval cache stay consistent.
    /// 2. Invokes `f(&ckt, &mut cache, &target, value)` — the caller runs the
    ///    inner analysis and may call `cache.solve_cached` / `cache.on_solve_complete`
    ///    to exploit the warm start and skip clean-device re-evals.
    ///
    /// For `GlobalParam` targets there is no device to mark, so the cache is
    /// invalidated wholesale at each step.  For `DeviceParam` targets the
    /// factor passed to `mark_param_changed` is `new_value / prev_value`
    /// (or `1.0` on the first step when there is no prior value).
    pub fn run_with_cache<R, F>(&self, base: &Circuit, mut f: F) -> Result<Vec<R>, SimError>
    where
        F: FnMut(&Circuit, &mut CacheManager, &ParamTarget, f64) -> Result<R, SimError>,
    {
        let mut cache = CacheManager::new_for_circuit(base);
        let mut out = Vec::with_capacity(self.values.len());
        let mut prev_value: Option<f64> = None;

        for (i, &v) in self.values.iter().enumerate() {
            let ckt = self.apply(base, i)?;

            match &self.target {
                ParamTarget::DeviceParam(dev_name, param) => {
                    let lower = dev_name.to_lowercase();
                    if let Some(dev) = base.find_device(&lower) {
                        let factor = prev_value.map_or(1.0, |p| if p.abs() > 1e-300 { v / p } else { 1.0 });
                        cache.mark_param_changed(dev.id.0, param, factor);
                    }
                }
                ParamTarget::GlobalParam(_) => {
                    // Global param change — invalidate everything so the inner
                    // analysis starts clean.
                    cache.invalidate_op();
                }
            }

            out.push(f(&ckt, &mut cache, &self.target, v)?);
            prev_value = Some(v);
        }
        Ok(out)
    }
}

/// Convenience: build a `ParamSweep` from a parser-level `StepDirective`.
///
/// Lives in this module (not `parser`) to keep the parser crate free of
/// dependencies on the analysis crate.
pub fn sweep_from_step(
    step_target: &str,
    values: Vec<f64>,
) -> ParamSweep {
    // If `step_target` contains a `.`, treat it as `device.param`.
    let target = if let Some(idx) = step_target.find('.') {
        let (dev, key) = step_target.split_at(idx);
        ParamTarget::DeviceParam(dev.to_string(), key[1..].to_string())
    } else {
        ParamTarget::GlobalParam(step_target.to_string())
    };
    ParamSweep::new(target, values)
}

/// Re-evaluate every `.PARAM`-driven element value when a global parameter
/// changes.  Stub helper for callers that want to chain `.PARAM` overrides
/// into a sweep — most analyses use device-level sweeps and skip this.
pub fn override_param(params: &mut AHashMap<String, f64>, name: &str, value: f64) {
    params.insert(name.to_string(), value);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lin_sweep_three_points() {
        let s = ParamSweep::lin(
            ParamTarget::GlobalParam("vdd".into()),
            1.0,
            3.0,
            1.0,
        );
        assert_eq!(s.values.len(), 3);
        assert!((s.values[0] - 1.0).abs() < 1e-12);
        assert!((s.values[1] - 2.0).abs() < 1e-12);
        assert!((s.values[2] - 3.0).abs() < 1e-12);
    }

    #[test]
    fn dec_sweep_two_decades() {
        let s = ParamSweep::dec(
            ParamTarget::GlobalParam("freq".into()),
            1.0,
            100.0,
            1,
        );
        // 1, 10, 100 ⇒ 3 points.
        assert!(s.values.len() >= 3);
        assert!((s.values[0] - 1.0).abs() < 1e-12);
        assert!((s.values.last().unwrap() - 100.0).abs() < 1.0);
    }

    #[test]
    fn oct_sweep_one_octave() {
        let s = ParamSweep::oct(
            ParamTarget::GlobalParam("freq".into()),
            1.0,
            2.0,
            1,
        );
        // 1, 2 ⇒ 2 points.
        assert_eq!(s.values.len(), 2);
    }

    #[test]
    fn list_sweep_explicit() {
        let s = ParamSweep::list(
            ParamTarget::GlobalParam("x".into()),
            vec![0.5, 1.0, 1.5, 2.0],
        );
        assert_eq!(s.values, vec![0.5, 1.0, 1.5, 2.0]);
    }

    #[test]
    fn sweep_from_step_device_form() {
        let s = sweep_from_step("r1.resistance", vec![1e3, 2e3]);
        match &s.target {
            ParamTarget::DeviceParam(dev, key) => {
                assert_eq!(dev, "r1");
                assert_eq!(key, "resistance");
            }
            _ => panic!("expected DeviceParam"),
        }
    }

    #[test]
    fn sweep_from_step_global_form() {
        let s = sweep_from_step("vdd", vec![3.3]);
        match &s.target {
            ParamTarget::GlobalParam(name) => assert_eq!(name, "vdd"),
            _ => panic!("expected GlobalParam"),
        }
    }
}
