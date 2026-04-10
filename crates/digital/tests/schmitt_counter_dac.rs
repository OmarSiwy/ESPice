//! End-to-end integration test for the native digital event engine.
//!
//! Pipeline (all simulated through `DigitalRuntime`):
//!
//! ```text
//!   analog_in --(adc_bridge w/ Schmitt hysteresis)--> clk
//!         clk --> 4-bit ripple counter (Q0..Q3)
//!         Q0..Q3 --(dac_bridge each)--> analog_out0..3
//! ```
//!
//! The 4-bit counter is built from four `DFlipFlop` primitives wired in
//! ripple-carry style: `Q0` toggles on every rising edge of `clk`, then `Q1`
//! toggles on every rising edge of `~Q0`, and so on.
//!
//! The test feeds a synthetic analog ramp into the ADC bridge, runs the
//! runtime over a sequence of timesteps, and verifies that:
//!
//! 1. The ADC produces a clean digital clock with hysteresis.
//! 2. The counter increments deterministically across the run.
//! 3. The DAC bridges produce the expected analog values for the bit pattern
//!    on the counter outputs after settling.

use pisim_digital::{
    AdcBridge, DacBridge, DigNodeIdx, DigState, DigitalNet, DigitalRuntime, EdgeKind,
    Primitive, PrimitiveKind, Strength,
};

/// Build a Schmitt-trigger ADC + 4-bit counter + per-bit DAC pipeline.
fn build_pipeline() -> DigitalRuntime {
    // Node layout:
    //   0  : clk        (digital, driven by ADC)
    //   1  : clk_n      (NOT clk)
    //   2  : q0
    //   3  : q0_n       (NOT q0)
    //   4  : q1
    //   5  : q1_n       (NOT q1)
    //   6  : q2
    //   7  : q2_n
    //   8  : q3
    //   9  : q3_n       (unused)
    let mut net = DigitalNet::with_capacity(10, 16, 256);

    // Schmitt-trigger ADC: analog node 0, low=1.0V, high=2.0V.
    net.bridges
        .push_adc(AdcBridge::new(0, DigNodeIdx::new(0), 1.0, 2.0));

    // NOT clk -> clk_n  (used as the clock for q1 in ripple-carry).
    net.primitives.push(Primitive::new_comb(
        PrimitiveKind::Not,
        &[DigNodeIdx::new(0)],
        DigNodeIdx::new(1),
        0.0,
    ));

    // FF0: D = q0_n, CLK = clk         → q0 (toggle FF on rising clk)
    net.primitives.push(Primitive::new_dff(
        DigNodeIdx::new(3),
        DigNodeIdx::new(0),
        DigNodeIdx::new(2),
        0.0,
        EdgeKind::Rising,
    ));
    // q0_n = NOT q0
    net.primitives.push(Primitive::new_comb(
        PrimitiveKind::Not,
        &[DigNodeIdx::new(2)],
        DigNodeIdx::new(3),
        0.0,
    ));

    // FF1: D = q1_n, CLK = q0_n        → q1
    net.primitives.push(Primitive::new_dff(
        DigNodeIdx::new(5),
        DigNodeIdx::new(3),
        DigNodeIdx::new(4),
        0.0,
        EdgeKind::Rising,
    ));
    net.primitives.push(Primitive::new_comb(
        PrimitiveKind::Not,
        &[DigNodeIdx::new(4)],
        DigNodeIdx::new(5),
        0.0,
    ));

    // FF2: D = q2_n, CLK = q1_n
    net.primitives.push(Primitive::new_dff(
        DigNodeIdx::new(7),
        DigNodeIdx::new(5),
        DigNodeIdx::new(6),
        0.0,
        EdgeKind::Rising,
    ));
    net.primitives.push(Primitive::new_comb(
        PrimitiveKind::Not,
        &[DigNodeIdx::new(6)],
        DigNodeIdx::new(7),
        0.0,
    ));

    // FF3: D = q3_n, CLK = q2_n
    net.primitives.push(Primitive::new_dff(
        DigNodeIdx::new(9),
        DigNodeIdx::new(7),
        DigNodeIdx::new(8),
        0.0,
        EdgeKind::Rising,
    ));
    net.primitives.push(Primitive::new_comb(
        PrimitiveKind::Not,
        &[DigNodeIdx::new(8)],
        DigNodeIdx::new(9),
        0.0,
    ));

    // Per-bit DAC bridges, mapping q0..q3 to analog nodes 1..4 with 0V/5V.
    for (bit, qnode) in [2, 4, 6, 8].iter().enumerate() {
        net.bridges.push_dac(DacBridge::new(
            (bit + 1) as u32,
            DigNodeIdx::new(*qnode as u32),
            0.0,
            5.0,
            1e-12,
            1e-12,
        ));
    }

    // Initialise q0..q3 to 0 so the counter has a defined start state.
    for &qn in &[2u32, 4, 6, 8] {
        net.node_state[qn as usize] = DigState::ZERO;
    }
    for &qnn in &[3u32, 5, 7, 9] {
        net.node_state[qnn as usize] = DigState::ONE;
    }
    // Force the FF memory to "previous clk = 0" so the first rising edge
    // is detected after the ADC drives clk high.
    DigitalRuntime::new(net)
}

#[allow(dead_code)]
fn _force_imports() {
    // Suppress dead-code warning for the EdgeKind::Falling import path.
    let _ = EdgeKind::Falling;
}

/// Drive `n_clocks` falling+rising clock edges into the ADC by toggling the
/// analog input above and below the hysteresis band.  Returns the runtime's
/// final node state for inspection.
fn run_clocks(rt: &mut DigitalRuntime, n_clocks: usize) {
    let dt = 1e-9;
    let mut t = 0.0;
    for k in 0..n_clocks {
        // Drive low: V = 0.5
        rt.flush(t, &[0.5]);
        t += dt;
        rt.flush(t, &[0.5]);
        t += dt;
        // Drive high: V = 3.0
        rt.flush(t, &[3.0]);
        t += dt;
        rt.flush(t, &[3.0]);
        t += dt;
        // Let any post-edge events propagate.
        rt.flush(t, &[3.0]);
        t += dt;
        let _ = k;
    }
    // One more low pulse so subsequent edges can be detected.
    rt.flush(t, &[0.5]);
}

/// Read the 4-bit counter value as an integer.
fn counter_value(rt: &DigitalRuntime) -> u32 {
    let mut v = 0u32;
    for (bit, &qn) in [2u32, 4, 6, 8].iter().enumerate() {
        if rt.read_node(DigNodeIdx::new(qn)).is_one() {
            v |= 1 << bit;
        }
    }
    v
}

#[test]
fn schmitt_counter_dac_pipeline_runs_end_to_end() {
    let mut rt = build_pipeline();

    // Apply 1 clock — counter should toggle from 0 to 1.
    run_clocks(&mut rt, 1);
    let after_one = counter_value(&rt);
    assert_eq!(after_one, 1, "counter after 1 clock should be 1");

    // Run 2 more clocks (3 total) — counter should now be 3.
    run_clocks(&mut rt, 2);
    assert_eq!(counter_value(&rt), 3, "counter after 3 clocks");

    // Verify DACs reflect Q0 == 1 and Q1 == 1 with the appropriate analog level.
    let v_q0 = rt.dac_voltage(DigNodeIdx::new(2), 1e-3).unwrap();
    let v_q1 = rt.dac_voltage(DigNodeIdx::new(4), 1e-3).unwrap();
    assert!((v_q0 - 5.0).abs() < 1e-6, "DAC q0 should be high; got {v_q0}");
    assert!((v_q1 - 5.0).abs() < 1e-6, "DAC q1 should be high; got {v_q1}");
}

#[test]
fn schmitt_hysteresis_rejects_noise_in_band() {
    let mut rt = build_pipeline();
    // Sit inside the hysteresis band — no clock edges should be produced.
    for k in 0..10 {
        let t = k as f64 * 1e-9;
        rt.flush(t, &[1.5]);
    }
    assert_eq!(counter_value(&rt), 0, "in-band noise should not clock");
}

#[test]
fn dig_states_are_packed_to_one_byte() {
    // Sanity-check the DOD claim from CLAUDE.md.
    assert_eq!(std::mem::size_of::<DigState>(), 1);
    let s = DigState::one(Strength::Resistive);
    assert!(s.is_one());
    assert_eq!(s.strength(), Strength::Resistive);
}
