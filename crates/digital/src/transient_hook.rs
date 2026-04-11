//! Integration glue between the digital event engine and BigOSpice's analog
//! transient solver.
//!
//! The contract with the analog Newton-Raphson driver is intentionally narrow:
//!
//! 1. Before each NR iteration, the driver calls `DigitalRuntime::flush(t_now,
//!    analog_voltages)`.  The runtime:
//!     a. Pops every event whose `time <= t_now` from the queue.
//!     b. Updates the per-node digital state slice (`node_state`).
//!     c. Forwards the event to every DAC bridge that listens on that node.
//!     d. Re-evaluates every primitive whose input was just touched.
//!     e. Schedules each primitive's output change with the appropriate delay.
//!     f. Drives every ADC bridge with the latest analog sample.
//!
//! 2. If the analog NR converges, the driver calls `commit()` (a no-op today —
//!    reserved for future checkpointing).
//!
//! 3. If the analog NR fails, the driver calls `rollback(t_after)`, which
//!    drops every event scheduled after `t_after` so the smaller-step retry
//!    is consistent.
//!
//! The runtime exposes `dac_voltage(node_index)` so the analog stamper can
//! query the current DAC output during NR iterations.

use crate::bridges::{BridgeBlock, DacBridge};
use crate::event_queue::{DigNodeIdx, Event, EventQueue};
use crate::primitives::PrimitiveBlock;
use crate::state::DigState;

/// Policy that controls how aggressively the runtime rolls back events when
/// the analog solver fails.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RollbackPolicy {
    /// Drop only events strictly past `t_after`.
    StrictlyAfter,
    /// Drop everything past or equal to `t_after`.
    AtOrAfter,
}

/// Top-level container holding the entire digital netlist.
pub struct DigitalNet {
    pub primitives: PrimitiveBlock,
    pub bridges: BridgeBlock,
    pub queue: EventQueue,
    /// Per-node current digital state, indexed by `DigNodeIdx::index()`.
    pub node_state: Vec<DigState>,
}

impl DigitalNet {
    pub fn with_capacity(num_nodes: usize, num_primitives: usize, num_events: usize) -> Self {
        Self {
            primitives: PrimitiveBlock::with_capacity(num_primitives),
            bridges: BridgeBlock::new(),
            queue: EventQueue::with_capacity(num_events),
            node_state: vec![DigState::X; num_nodes],
        }
    }

    /// Resize the node-state vector to accommodate `n` digital nodes.
    pub fn resize_nodes(&mut self, n: usize) {
        if n > self.node_state.len() {
            self.node_state.resize(n, DigState::X);
        }
    }
}

impl Default for DigitalNet {
    fn default() -> Self {
        Self::with_capacity(0, 0, 1024)
    }
}

/// Stateful runtime adapter — owns the `DigitalNet` and a scratch event buffer.
pub struct DigitalRuntime {
    pub net: DigitalNet,
    /// Scratch buffer reused across `flush` calls to avoid per-step allocs.
    scratch: Vec<Event>,
    /// Rollback policy used by `rollback`.
    pub policy: RollbackPolicy,
}

impl DigitalRuntime {
    pub fn new(net: DigitalNet) -> Self {
        Self {
            net,
            scratch: Vec::with_capacity(256),
            policy: RollbackPolicy::StrictlyAfter,
        }
    }

    /// Flush the digital queue up to `t_now` and re-evaluate any primitives
    /// whose inputs changed.  Drives ADC bridges with the latest analog sample
    /// slice.  Returns the number of events processed.
    ///
    /// `analog_voltages` may be empty if there are no ADC bridges or the
    /// caller does not yet have a usable solution vector.
    pub fn flush(&mut self, t_now: f64, analog_voltages: &[f64]) -> usize {
        // Step 1: tick clock pulse sources up to t_now.
        self.net.primitives.tick_pulses(t_now, &mut self.net.queue);

        // Step 2: drive ADC bridges with the latest analog sample.
        self.net
            .bridges
            .tick_adcs(t_now, analog_voltages, &mut self.net.queue);

        // Step 3: drain due events.
        self.net.queue.pop_due(t_now, &mut self.scratch);
        let processed = self.scratch.len();

        // Step 4: apply each event to the node-state vector and forward to
        // DAC bridges.
        for ev in self.scratch.iter() {
            let idx = ev.node.index();
            if idx < self.net.node_state.len() {
                self.net.node_state[idx] = ev.value;
            }
            self.net
                .bridges
                .dispatch_event_to_dacs(ev.time, ev.node, ev.value);
        }

        // Step 5: re-evaluate primitives whose inputs touched a changed node.
        // Today this is a coarse "evaluate every primitive" pass — fine for
        // small testbenches and dramatically simpler than maintaining a
        // sensitivity list.  Outputs are scheduled with their per-primitive
        // `delay` so causality is preserved.
        if processed > 0 {
            for id in 0..self.net.primitives.len() {
                let updates = self.net.primitives.eval(id, &self.net.node_state);
                let delay = self.net.primitives.delays[id];
                for (node, val) in updates {
                    // Only schedule an output event when the value actually
                    // changes.  Suppressing no-change events prevents
                    // downstream sequential primitives (e.g. DFF in a ripple
                    // counter) from seeing spurious clock edges every time a
                    // combinational gate re-evaluates to the same state.
                    let cur = self.net.node_state
                        .get(node.index())
                        .copied()
                        .unwrap_or(DigState::X);
                    if val != cur {
                        let t_emit = t_now + delay;
                        self.net.queue.schedule(t_emit, node, val);
                    }
                }
            }
        }

        processed
    }

    /// Query the analog voltage produced by *any* DAC bridge whose digital
    /// input is `node`.  If multiple DACs share the input, the last one wins
    /// (in practice the user should declare a single DAC per analog node).
    pub fn dac_voltage(&self, node: DigNodeIdx, t: f64) -> Option<f64> {
        self.net
            .bridges
            .dacs
            .iter()
            .rev()
            .find(|d| d.digital_node == node)
            .map(|d| d.current_voltage(t))
    }

    /// Return a slice of all DAC bridges so the analog stamper can sweep them.
    pub fn dac_bridges(&self) -> &[DacBridge] {
        &self.net.bridges.dacs
    }

    /// Commit the events flushed during the most recent `flush` call.  Today
    /// this is a no-op; the hook is reserved for future checkpoint/restore.
    pub fn commit(&mut self) {
        self.scratch.clear();
    }

    /// Roll back every event past `t_after`.  Called when the analog Newton
    /// solver fails and the driver wants to retry with a smaller step.
    pub fn rollback(&mut self, t_after: f64) {
        let cutoff = match self.policy {
            RollbackPolicy::StrictlyAfter => t_after,
            // Subtract a tiny epsilon to also drop events at exactly t_after.
            RollbackPolicy::AtOrAfter => t_after - f64::EPSILON,
        };
        self.net.queue.rollback(cutoff);
    }

    /// Read the current digital level on `node`.
    pub fn read_node(&self, node: DigNodeIdx) -> DigState {
        self.net
            .node_state
            .get(node.index())
            .copied()
            .unwrap_or(DigState::X)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridges::{AdcBridge, DacBridge};
    use crate::event_queue::DigNodeIdx;
    use crate::primitives::{Primitive, PrimitiveKind};

    #[test]
    fn flush_processes_due_events() {
        let mut net = DigitalNet::with_capacity(4, 1, 16);
        let id = net
            .primitives
            .push(Primitive::new_comb(
                PrimitiveKind::Not,
                &[DigNodeIdx::new(0)],
                DigNodeIdx::new(1),
                1e-9,
            ));
        let _ = id;
        net.queue.schedule(0.0, DigNodeIdx::new(0), DigState::ONE);

        let mut rt = DigitalRuntime::new(net);
        let n = rt.flush(0.0, &[]);
        assert_eq!(n, 1);
        // Output of NOT(1) should be scheduled after a 1ns delay.
        rt.flush(2e-9, &[]);
        assert_eq!(rt.read_node(DigNodeIdx::new(1)), DigState::ZERO);
    }

    #[test]
    fn dac_voltage_query() {
        let mut net = DigitalNet::with_capacity(2, 0, 16);
        net.bridges.push_dac(DacBridge::new(0, DigNodeIdx::new(0), 0.0, 5.0, 1e-9, 1e-9));
        net.queue.schedule(0.0, DigNodeIdx::new(0), DigState::ONE);
        let mut rt = DigitalRuntime::new(net);
        rt.flush(0.0, &[]);
        let v = rt.dac_voltage(DigNodeIdx::new(0), 1e-9).unwrap();
        assert!((v - 5.0).abs() < 1e-9);
    }

    #[test]
    fn rollback_clears_future_events() {
        let mut net = DigitalNet::with_capacity(2, 0, 16);
        net.queue.schedule(1e-9, DigNodeIdx::new(0), DigState::ONE);
        net.queue.schedule(5e-9, DigNodeIdx::new(0), DigState::ZERO);
        let mut rt = DigitalRuntime::new(net);
        rt.rollback(2e-9);
        assert_eq!(rt.net.queue.len(), 1);
    }

    #[test]
    fn adc_drives_node() {
        let mut net = DigitalNet::with_capacity(2, 0, 16);
        net.bridges
            .push_adc(AdcBridge::new(0, DigNodeIdx::new(0), 1.0, 2.0));
        let mut rt = DigitalRuntime::new(net);
        // Voltage above threshold → ONE event scheduled & flushed.
        rt.flush(0.0, &[2.5]);
        assert_eq!(rt.read_node(DigNodeIdx::new(0)), DigState::ONE);
    }
}
