//! Analog ↔ digital bridge elements.
//!
//! Two pure data types live here:
//!
//! * **`AdcBridge`** — observes one analog node voltage and emits a digital
//!   event whenever the voltage crosses one of two thresholds (with hysteresis):
//!     * `v ≥ in_high` → schedule `DigState::ONE` on the digital output.
//!     * `v ≤ in_low`  → schedule `DigState::ZERO`.
//!     * `in_low < v < in_high` → no change.
//!
//! * **`DacBridge`** — converts a digital state into a target analog voltage,
//!   ramping linearly between `out_low` and `out_high` over `t_rise` / `t_fall`.
//!   Exposes a `current_voltage(t)` method that the analog stamper queries each
//!   Newton iteration; this is what makes the bridge appear as a time-varying
//!   voltage source on the analog side.
//!
//! Both bridge types are stored together in `BridgeBlock` (SoA), with a
//! `kind: Vec<u8>` discriminator (`0` = ADC, `1` = DAC).  The hot path is a
//! single linear sweep over `BridgeBlock::adc_step`/`dac_step`.

use super::event_queue::{DigNodeIdx, EventQueue};
use super::state::DigState;

/// Opaque identifier for a bridge instance within a `BridgeBlock`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(transparent)]
pub struct BridgeId(pub u32);

/// Analog → digital bridge with hysteresis.
#[derive(Debug, Clone, Copy)]
pub struct AdcBridge {
    /// Analog node id (interpreted by the caller; we treat it as opaque `u32`).
    pub analog_node: u32,
    /// Digital output node.
    pub digital_node: DigNodeIdx,
    /// Propagation delay before a new sampled state is emitted.
    pub delay: f64,
    /// Lower hysteresis threshold (volts).
    pub in_low: f64,
    /// Upper hysteresis threshold (volts).
    pub in_high: f64,
    /// Last digital level emitted.  Initial value should be `DigState::X`.
    pub last_state: DigState,
}

impl AdcBridge {
    pub fn new(
        analog_node: u32,
        digital_node: DigNodeIdx,
        delay: f64,
        in_low: f64,
        in_high: f64,
    ) -> Self {
        Self {
            analog_node,
            digital_node,
            delay,
            in_low,
            in_high,
            last_state: DigState::X,
        }
    }

    /// Apply one analog sample.  If a threshold is crossed, schedule the new
    /// digital state at time `t` and return `true`.
    pub fn step(&mut self, t: f64, voltage: f64, queue: &mut EventQueue) -> bool {
        let new_state = if voltage >= self.in_high {
            Some(DigState::ONE)
        } else if voltage <= self.in_low {
            Some(DigState::ZERO)
        } else {
            None
        };

        if let Some(s) = new_state {
            if s != self.last_state {
                queue.schedule(t + self.delay.max(0.0), self.digital_node, s);
                self.last_state = s;
                return true;
            }
        }
        false
    }
}

/// Digital → analog bridge with linear rise/fall ramps.
#[derive(Debug, Clone, Copy)]
pub struct DacBridge {
    /// Analog node id (interpreted by the caller).
    pub analog_node: u32,
    /// Digital input node.
    pub digital_node: DigNodeIdx,
    /// Output voltage when input is logic 0.
    pub out_low: f64,
    /// Output voltage when input is logic 1.
    pub out_high: f64,
    /// Rise time from `out_low` to `out_high` [s].
    pub t_rise: f64,
    /// Fall time from `out_high` to `out_low` [s].
    pub t_fall: f64,
    /// Voltage at the start of the current ramp.
    pub v_start: f64,
    /// Target voltage at end of ramp.
    pub v_target: f64,
    /// Time at which the current ramp started.
    pub t_start: f64,
    /// Currently latched digital input level.
    pub last_input: DigState,
}

impl DacBridge {
    pub fn new(
        analog_node: u32,
        digital_node: DigNodeIdx,
        out_low: f64,
        out_high: f64,
        t_rise: f64,
        t_fall: f64,
    ) -> Self {
        Self {
            analog_node,
            digital_node,
            out_low,
            out_high,
            t_rise,
            t_fall,
            v_start: out_low,
            v_target: out_low,
            t_start: 0.0,
            last_input: DigState::X,
        }
    }

    /// Notify the bridge that its digital input took on `new_state` at time `t`.
    /// Updates the ramp parameters so subsequent `current_voltage` calls
    /// produce the correct intermediate voltage.
    pub fn on_digital_event(&mut self, t: f64, new_state: DigState) {
        if new_state == self.last_input {
            return;
        }
        let target = if new_state.is_one() {
            self.out_high
        } else if new_state.is_zero() {
            self.out_low
        } else {
            // X / Z → hold current target.
            self.last_input = new_state;
            return;
        };
        self.v_start = self.current_voltage(t);
        self.v_target = target;
        self.t_start = t;
        self.last_input = new_state;
    }

    /// Voltage produced at time `t` by the current ramp.
    ///
    /// Linear ramp between `v_start` and `v_target`, with the active
    /// rise/fall time picked by the polarity of the transition.  Held flat
    /// once the ramp completes.
    pub fn current_voltage(&self, t: f64) -> f64 {
        let dt = (t - self.t_start).max(0.0);
        let active = if self.v_target >= self.v_start {
            self.t_rise
        } else {
            self.t_fall
        };
        if active <= 0.0 || dt >= active {
            return self.v_target;
        }
        let frac = dt / active;
        self.v_start + (self.v_target - self.v_start) * frac
    }
}

/// SoA storage for all bridges in the netlist.
///
/// `kinds[i] == 0` means `adcs[?]`, `kinds[i] == 1` means `dacs[?]`; the
/// `slot[i]` field indexes the appropriate sub-vector.  This keeps the cold
/// metadata small while allowing a unified id space.
pub struct BridgeBlock {
    pub adcs: Vec<AdcBridge>,
    pub dacs: Vec<DacBridge>,
}

impl BridgeBlock {
    pub fn new() -> Self {
        Self {
            adcs: Vec::new(),
            dacs: Vec::new(),
        }
    }

    /// Push an ADC bridge and return its id.
    pub fn push_adc(&mut self, b: AdcBridge) -> BridgeId {
        let id = self.adcs.len() as u32;
        self.adcs.push(b);
        BridgeId(id)
    }

    /// Push a DAC bridge and return its id.
    pub fn push_dac(&mut self, b: DacBridge) -> BridgeId {
        let id = self.dacs.len() as u32;
        self.dacs.push(b);
        BridgeId(id)
    }

    /// Drive every ADC bridge with the latest analog sample slice.
    ///
    /// `analog_voltages` is indexed by `analog_node` from each ADC.  Schedules
    /// any threshold crossings into `queue`.
    pub fn tick_adcs(&mut self, t: f64, analog_voltages: &[f64], queue: &mut EventQueue) {
        for adc in self.adcs.iter_mut() {
            let idx = adc.analog_node as usize;
            if let Some(&v) = analog_voltages.get(idx) {
                adc.step(t, v, queue);
            }
        }
    }

    /// Apply a freshly popped digital event to every DAC bridge whose input
    /// matches the event's node.
    pub fn dispatch_event_to_dacs(&mut self, t: f64, node: DigNodeIdx, value: DigState) {
        for dac in self.dacs.iter_mut() {
            if dac.digital_node == node {
                dac.on_digital_event(t, value);
            }
        }
    }
}

impl Default for BridgeBlock {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::event_queue::{DigNodeIdx, EventQueue};

    #[test]
    fn adc_emits_high_above_threshold() {
        let mut adc = AdcBridge::new(0, DigNodeIdx::new(7), 0.0, 1.0, 2.0);
        let mut q = EventQueue::with_capacity(8);
        // Below in_low → 0.
        assert!(adc.step(0.0, 0.5, &mut q));
        // Still below in_high but above in_low → no change (hysteresis).
        assert!(!adc.step(1.0, 1.5, &mut q));
        // Above in_high → 1.
        assert!(adc.step(2.0, 2.5, &mut q));
        // Drop into hysteresis band — no change.
        assert!(!adc.step(3.0, 1.5, &mut q));
        // Drop below in_low — back to 0.
        assert!(adc.step(4.0, 0.5, &mut q));
        assert_eq!(q.len(), 3);
    }

    #[test]
    fn dac_ramps_linearly() {
        let mut dac = DacBridge::new(0, DigNodeIdx::new(0), 0.0, 5.0, 1e-9, 1e-9);
        // Initially X → no ramp; voltage is v_target = out_low.
        dac.on_digital_event(0.0, DigState::ONE);
        assert!((dac.current_voltage(0.0) - 0.0).abs() < 1e-12);
        let mid = dac.current_voltage(0.5e-9);
        assert!((mid - 2.5).abs() < 1e-9);
        let end = dac.current_voltage(1.0e-9);
        assert!((end - 5.0).abs() < 1e-12);
        let after = dac.current_voltage(1e-6);
        assert!((after - 5.0).abs() < 1e-12);
    }

    #[test]
    fn dac_ignores_x_and_z() {
        let mut dac = DacBridge::new(0, DigNodeIdx::new(0), 0.0, 5.0, 1e-9, 1e-9);
        dac.on_digital_event(0.0, DigState::ONE);
        dac.on_digital_event(2e-9, DigState::X);
        // Target should still be 5V because X is treated as hold.
        assert!((dac.current_voltage(3e-9) - 5.0).abs() < 1e-12);
    }
}
