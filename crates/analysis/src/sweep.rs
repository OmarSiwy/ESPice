//! Generic parameter sweep runner.
//!
//! Drives an arbitrary inner analysis (DC OP, AC, TRAN, ...) across a list of
//! parameter values supplied by `.STEP` directives in the netlist (or any
//! caller-supplied set).
//!
//! ## Design
//!
//! Stays in the data-oriented spirit of the rest of `incspice-analysis`:
//!
//! * `ParamSweep` is a tiny struct of arrays — one entry per swept point —
//!   so the hot loop is a contiguous index over `Vec<f64>`.
//! * The inner analysis is invoked through a closure that receives a mutable
//!   `Circuit` clone, so we never mutate the original circuit and downstream
//!   incremental caches stay valid.
//! * No trait objects, no virtual dispatch — the closure is generic so the
//!   compiler can monomorphize the runner per analysis type.

use std::collections::HashMap;
use incspice_cache::CacheManager;
use incspice_core::{Circuit, SimError};

/// Identifies what a single sweep value should mutate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParamTarget {
    /// Modify a `.PARAM` map entry.
    GlobalParam(String),
    /// Modify a device instance parameter directly.
    DeviceParam(String, String),
}

/// A flat parameter sweep — one target, a list of values.
#[derive(Debug, Clone)]
pub struct ParamSweep {
    /// What to mutate at each sweep point.
    pub target: ParamTarget,
    /// Pre-materialized list of values.
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
            }
        }
        Ok(ckt)
    }

    /// Run an inner analysis once per sweep point.
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

    /// Cache-aware sweep runner for `.STEP` directives.
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
                        let factor =
                            prev_value.map_or(1.0, |p| if p.abs() > 1e-300 { v / p } else { 1.0 });
                        cache.mark_param_changed(dev.id.0, param, factor);
                    }
                }
                ParamTarget::GlobalParam(_) => {
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
pub fn sweep_from_step(step_target: &str, values: Vec<f64>) -> ParamSweep {
    let target = if let Some(idx) = step_target.find('.') {
        let (dev, key) = step_target.split_at(idx);
        ParamTarget::DeviceParam(dev.to_string(), key[1..].to_string())
    } else {
        ParamTarget::GlobalParam(step_target.to_string())
    };
    ParamSweep::new(target, values)
}

/// Re-evaluate every `.PARAM`-driven element value when a global parameter changes.
pub fn override_param(params: &mut HashMap<String, f64>, name: &str, value: f64) {
    params.insert(name.to_string(), value);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lin_sweep_three_points() {
        let s = ParamSweep::lin(ParamTarget::GlobalParam("vdd".into()), 1.0, 3.0, 1.0);
        assert_eq!(s.values.len(), 3);
        assert!((s.values[0] - 1.0).abs() < 1e-12);
        assert!((s.values[1] - 2.0).abs() < 1e-12);
        assert!((s.values[2] - 3.0).abs() < 1e-12);
    }

    #[test]
    fn dec_sweep_two_decades() {
        let s = ParamSweep::dec(ParamTarget::GlobalParam("freq".into()), 1.0, 100.0, 1);
        assert!(s.values.len() >= 3);
        assert!((s.values[0] - 1.0).abs() < 1e-12);
        assert!((s.values.last().unwrap() - 100.0).abs() < 1.0);
    }

    #[test]
    fn oct_sweep_one_octave() {
        let s = ParamSweep::oct(ParamTarget::GlobalParam("freq".into()), 1.0, 2.0, 1);
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
