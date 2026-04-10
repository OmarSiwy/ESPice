//! Clock-driven vs continuous-assignment dispatch mode for `d_cosim`.
//!
//! Mirrors ngspice's `d_cosim` behaviour: in **clock-driven** mode the
//! Verilator model is `eval()`-ed only when a designated clock node sees a
//! rising edge; in **continuous** mode it is `eval()`-ed every timestep so
//! purely combinational designs can react to input changes between clocks.

use pisim_digital::DigNodeIdx;

/// Configuration for the clock node in clock-driven mode.
#[derive(Debug, Clone, Copy)]
pub struct ClockSpec {
    /// Digital node carrying the clock signal.
    pub node: DigNodeIdx,
    /// Period [s] of the clock — informational, used by waveform generators.
    pub period: f64,
}

impl ClockSpec {
    pub fn new(node: DigNodeIdx, period: f64) -> Self {
        Self { node, period }
    }
}

/// How the `d_cosim` device decides to evaluate the wrapped model.
#[derive(Debug, Clone, Copy)]
pub enum ClockMode {
    /// Re-evaluate every transient timestep (combinational designs).
    Continuous,
    /// Re-evaluate only on rising edges of the clock node.
    ClockDriven(ClockSpec),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clock_spec_construction() {
        let cs = ClockSpec::new(DigNodeIdx::new(7), 10e-9);
        assert_eq!(cs.node, DigNodeIdx::new(7));
        assert!((cs.period - 10e-9).abs() < 1e-18);
    }
}
