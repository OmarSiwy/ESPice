//! `d_cosim` device — wraps a loaded Verilator model and exposes its ports as
//! digital nodes that can be driven from / sampled by the digital engine.
//!
//! The device is intentionally a *plain data type* with no analog stamping
//! responsibilities; the analog NR loop never sees `DCosim` directly.  Each
//! transient timestep, the digital event runtime calls `DCosim::tick(t,
//! digital_state)` which:
//!
//! 1. Pushes the latest digital state of every input port into the model
//!    via `VerilatorModel::set_signal`.
//! 2. Calls `VerilatorModel::eval()`.
//! 3. Reads each output port via `get_signal` and emits a digital event into
//!    the queue if the value changed.
//!
//! Clock-driven mode (the default) only invokes `eval` on a clock edge;
//! continuous-assignment mode calls it every timestep.

use bigospice_digital::{DigNodeIdx, DigState, EventQueue, Strength};

use crate::clock_mode::{ClockMode, ClockSpec};
use crate::loader::{CosimError, VerilatorModel};

/// Direction of a `d_cosim` port.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PortDirection {
    Input,
    Output,
}

/// One mapping of a digital node to a Verilator signal name.
#[derive(Debug, Clone)]
pub struct DCosimPort {
    pub name: String,
    pub node: DigNodeIdx,
    pub dir: PortDirection,
    pub width: u8, // 1..=64
    /// For outputs: the last value we observed (so we can emit edge events).
    pub last_value: u64,
}

impl DCosimPort {
    pub fn new(name: impl Into<String>, node: DigNodeIdx, dir: PortDirection, width: u8) -> Self {
        Self {
            name: name.into(),
            node,
            dir,
            width: width.clamp(1, 64),
            last_value: 0,
        }
    }
}

/// `d_cosim` device.
pub struct DCosim {
    pub model: VerilatorModel,
    pub ports: Vec<DCosimPort>,
    pub clock: ClockMode,
    /// Cached port name → index lookup table for fast updates.
    pub last_clock_high: bool,
}

impl DCosim {
    pub fn new(model: VerilatorModel, clock: ClockMode) -> Self {
        Self {
            model,
            ports: Vec::new(),
            clock,
            last_clock_high: false,
        }
    }

    /// Register a port.  The order of registration is irrelevant.
    pub fn add_port(&mut self, port: DCosimPort) {
        self.ports.push(port);
    }

    /// Find a port by digital node, returning its index in `ports`.
    pub fn find_port_by_node(&self, node: DigNodeIdx) -> Option<usize> {
        self.ports.iter().position(|p| p.node == node)
    }

    /// One simulation tick.
    ///
    /// * `t`             — current simulation time.
    /// * `digital_state` — current digital state slice indexed by node.
    /// * `queue`         — event queue to emit output transitions into.
    pub fn tick(
        &mut self,
        t: f64,
        digital_state: &[DigState],
        queue: &mut EventQueue,
    ) -> Result<(), CosimError> {
        // 1. Decide whether this tick performs an `eval`.  Clock-driven mode
        //    triggers only on a clock rising edge as identified by `clock`.
        let should_eval = match &self.clock {
            ClockMode::Continuous => true,
            ClockMode::ClockDriven(ClockSpec { node, .. }) => {
                let cur = digital_state
                    .get(node.index())
                    .copied()
                    .map(|s| s.is_one())
                    .unwrap_or(false);
                let edge = !self.last_clock_high && cur;
                self.last_clock_high = cur;
                edge
            }
        };

        if !should_eval {
            return Ok(());
        }

        // 2. Push every input port's current digital level into the model.
        for port in self.ports.iter() {
            if port.dir != PortDirection::Input {
                continue;
            }
            let st = digital_state
                .get(port.node.index())
                .copied()
                .unwrap_or(DigState::X);
            // Map digital state to a u64.  X / Z map to 0 (Verilator's
            // "unknown" handling is outside this skeleton).
            let bit = if st.is_one() { 1u64 } else { 0u64 };
            let mask = if port.width >= 64 {
                u64::MAX
            } else {
                (1u64 << port.width) - 1
            };
            let value = bit & mask;
            self.model.set_signal(&port.name, value)?;
        }

        // 3. Step the model.
        self.model.eval();

        // 4. Read outputs; emit events on changes.
        for port in self.ports.iter_mut() {
            if port.dir != PortDirection::Output {
                continue;
            }
            let v = self.model.get_signal(&port.name)?;
            if v != port.last_value {
                let new_state = if v & 1 != 0 {
                    DigState::one(Strength::Strong)
                } else {
                    DigState::zero(Strength::Strong)
                };
                queue.schedule(t, port.node, new_state);
                port.last_value = v;
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_digital::DigNodeIdx;

    #[test]
    fn port_construction() {
        let p = DCosimPort::new("clk", DigNodeIdx::new(0), PortDirection::Input, 1);
        assert_eq!(p.width, 1);
        assert_eq!(p.dir, PortDirection::Input);
    }

    #[test]
    fn width_clamp() {
        let p = DCosimPort::new("data", DigNodeIdx::new(1), PortDirection::Input, 99);
        assert_eq!(p.width, 64);
    }
}
