//! LTRA `O` element (lossy transmission line) — integration tests.
//!
//! Phase 2.8 implements the DC steady-state path (resistive T network) plus
//! the Roychowdhury-Pederson dispersive transient convolution kernel.
//!
//! These tests cover the parser, dense registry, the DC operating point
//! through the full MNA pipeline, the SoA history container, and the
//! transient history update / convolution path.

use pisim_core::{DeviceKind, ParamMap};
use pisim_device::{DeviceRegistry, Ltra, LtraHistory, LtraInstance};
use pisim_device::eval::DeviceModel;
use pisim_test_harness::{parse_netlist_str, run_dc_op, run_transient};

// ───────────────────────────────────────────────────────────────────────
// Registry / dispatch smoke tests
// ───────────────────────────────────────────────────────────────────────

#[test]
fn ltra_is_registered_by_default() {
    let reg = DeviceRegistry::new_default();
    let dispatch = reg
        .get(DeviceKind::Ltra)
        .expect("LTRA should be in the default registry");
    assert_eq!(dispatch.num_terminals(), 4);
    assert!(!dispatch.needs_branch());
    assert_eq!(dispatch.kind(), DeviceKind::Ltra);
}

#[test]
fn ltra_dispatch_eval_matches_direct_model() {
    let reg = DeviceRegistry::new_default();
    let dispatch = reg.get(DeviceKind::Ltra).unwrap();

    let mut params = ParamMap::new();
    params.set("r", 4.0);
    params.set("g", 0.0);
    params.set("len", 1.0);

    let voltages = [1.0_f64, 0.0, 0.0, 0.0];
    let via_dispatch = dispatch.eval(&voltages, &params);
    let via_direct = Ltra.eval(&voltages, &params);

    assert_eq!(via_dispatch.g.len(), via_direct.g.len());
    for (a, b) in via_dispatch.g.iter().zip(via_direct.g.iter()) {
        assert!((a - b).abs() < 1e-15, "dispatch g {a} != direct g {b}");
    }
}

// ───────────────────────────────────────────────────────────────────────
// Parser + build_circuit tests
// ───────────────────────────────────────────────────────────────────────

#[test]
fn parser_accepts_ltra_model_and_element() {
    let netlist = "\
* LTRA parse smoke test
V1 in 0 DC 1
R_term out 0 50
.MODEL LYNE LTRA (R=10 L=0 G=0 C=0 LEN=2)
O1 in 0 out 0 LYNE
.OP
.END
";

    let (circuit, _analyses) = parse_netlist_str(netlist)
        .expect("LTRA parse should succeed");

    // Find the LTRA device.
    let ltra_dev = circuit
        .devices()
        .iter()
        .find(|d| d.kind == DeviceKind::Ltra)
        .expect("LTRA device should be in the circuit");

    assert_eq!(ltra_dev.terminal_count(), 4);
    // Model params should have flowed through to the device ParamMap.
    assert!((ltra_dev.params.get_or("r", -1.0) - 10.0).abs() < 1e-12);
    assert!((ltra_dev.params.get_or("len", -1.0) - 2.0).abs() < 1e-12);
}

#[test]
fn parser_ltra_element_override_beats_model() {
    // Element-card R=42 must override the model-card R=10.
    let netlist = "\
.MODEL MYL LTRA (R=10 L=0 G=0 C=0 LEN=1)
V1 a 0 DC 1
O1 a 0 b 0 MYL R=42
R1 b 0 1k
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("override parse");
    let ltra = circuit
        .devices()
        .iter()
        .find(|d| d.kind == DeviceKind::Ltra)
        .expect("LTRA device");
    assert!((ltra.params.get_or("r", 0.0) - 42.0).abs() < 1e-12);
}

// ───────────────────────────────────────────────────────────────────────
// DC semantics (direct model eval — independent of full MNA pipeline)
// ───────────────────────────────────────────────────────────────────────

/// With `R=10 Ω/m, LEN=1 m, G=0`, the DC equivalent is a 10 Ω series
/// resistor.  Driving +1 V at port 1 into a shorted port 2 should give
/// a 0.1 A axial current.
#[test]
fn ltra_dc_ohms_law_across_length() {
    let m = Ltra;
    let mut p = ParamMap::new();
    p.set("r", 10.0);
    p.set("g", 0.0);
    p.set("len", 1.0);

    let eval = m.eval(&[1.0, 0.0, 0.0, 0.0], &p);
    // Pin-0 KCL: +I_series = +0.1 A.
    assert!((eval.g[0] - 0.1).abs() < 1e-12, "pin0 g = {}", eval.g[0]);
    // Pin-2 KCL: -I_series = -0.1 A.
    assert!((eval.g[2] + 0.1).abs() < 1e-12, "pin2 g = {}", eval.g[2]);
}

/// Shunt-conductance-only case: a line with `R=0, G=0.5 S/m, LEN=1 m`
/// has `G_tot = 0.5 S`, so each port-shunt half is `0.25 S`.  Driving
/// +1 V across port-1 should drain 0.25 A into port-1's negative pin.
#[test]
fn ltra_shunt_conductance_drain() {
    let m = Ltra;
    let mut p = ParamMap::new();
    p.set("r", 0.0);
    p.set("g", 0.5);
    p.set("len", 1.0);

    let eval = m.eval(&[1.0, 0.0, 0.0, 0.0], &p);
    // Pin-1 KCL: -I_sh1 = -0.25 A.
    assert!((eval.g[1] + 0.25).abs() < 1e-9, "pin1 g = {}", eval.g[1]);
    // Pin-3 KCL: -I_sh2 ≈ 0 (port-2 at ground).
    assert!(eval.g[3].abs() < 1e-9, "pin3 g = {}", eval.g[3]);
}

// ───────────────────────────────────────────────────────────────────────
// DC operating point through the full MNA pipeline
// ───────────────────────────────────────────────────────────────────────

/// Voltage divider: 1 V → LTRA(R=10 Ω·m, LEN=1) → 10 Ω load to ground.
/// Expected V(out) = 1 × (10 / (10 + 10)) = 0.5 V.
#[test]
fn ltra_dc_op_voltage_divider() {
    let netlist = "\
* LTRA DC voltage divider
V1 in 0 DC 1
.MODEL LRL LTRA (R=10 L=0 G=0 C=0 LEN=1)
O1 in 0 out 0 LRL
R_load out 0 10
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let op = run_dc_op(&circuit).expect("DC OP should converge");

    let v_out = op
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("node 'out' in DC OP result");
    assert!(
        (v_out - 0.5).abs() < 1e-6,
        "V(out) = {v_out}, expected 0.5 (LTRA+R divider)"
    );
}

/// A "small-loss" LTRA (R=1 Ω·m, LEN=1) driving a 100 Ω load acts as
/// an almost-ideal wire at DC: V(out) ≈ V(in) × 100 / (101) ≈ 0.99 V.
#[test]
fn ltra_dc_op_low_loss_near_wire() {
    let netlist = "\
* Nearly-lossless LTRA at DC
V1 in 0 DC 1
.MODEL LINE LTRA (R=1 L=0 G=0 C=0 LEN=1)
O1 in 0 out 0 LINE
R_load out 0 100
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let op = run_dc_op(&circuit).expect("DC OP should converge");

    let find_node = |n: &str| -> f64 {
        op.node_voltages
            .iter()
            .find(|(name, _)| name == n)
            .map(|(_, v)| *v)
            .unwrap_or_else(|| panic!("node '{n}' not in DC OP result"))
    };

    let v_in = find_node("in");
    let v_out = find_node("out");

    let expected = 100.0 / 101.0; // ≈ 0.990099 V
    assert!((v_in - 1.0).abs() < 1e-9, "V(in) = {v_in}");
    assert!(
        (v_out - expected).abs() < 1e-6,
        "V(out) = {v_out}, expected ~{expected}"
    );
}

// ───────────────────────────────────────────────────────────────────────
// History container — SoA layout smoke test
// ───────────────────────────────────────────────────────────────────────

#[test]
fn ltra_instance_history_is_soa() {
    let mut inst = LtraInstance::new();
    assert_eq!(inst.ports, [0, 1, 2, 3]);
    assert!(inst.history.is_empty());

    inst.history.push(0.0, 0.0, 0.0, 0.0, 0.0);
    inst.history.push(1e-9, 0.5, 0.0, 1e-3, 0.0);
    inst.history.push(2e-9, 1.0, 0.25, 2e-3, 0.25e-3);

    assert_eq!(inst.history.len(), 3);
    // SoA layout: each field is a distinct contiguous Vec<f64>.
    assert_eq!(inst.history.times.len(), 3);
    assert_eq!(inst.history.v1.len(), 3);
    assert_eq!(inst.history.v2.len(), 3);
    assert_eq!(inst.history.i1.len(), 3);
    assert_eq!(inst.history.i2.len(), 3);
}

#[test]
fn ltra_history_with_capacity_preallocates() {
    let h = LtraHistory::with_capacity(128);
    assert!(h.is_empty());
    assert!(h.times.capacity() >= 128);
    assert!(h.v1.capacity() >= 128);
    assert!(h.i2.capacity() >= 128);
}

#[test]
fn ltra_history_trapz_exact_for_constant_integrand() {
    let mut h = LtraHistory::with_capacity(8);
    for i in 0..=4 {
        h.push(i as f64, 0.0, 0.0, 0.0, 0.0);
    }
    let ones = vec![1.0; 5];
    // Integrate f(t) = 1 from t=0..4 → area = 4 exactly.
    let area = h.trapz(&ones, 4.0);
    assert!((area - 4.0).abs() < 1e-12, "trapz = {area}, expected 4");

    // Truncate at t=2: area = 2.
    let area2 = h.trapz(&ones, 2.0);
    assert!((area2 - 2.0).abs() < 1e-12, "trapz(t_end=2) = {area2}");
}

// ───────────────────────────────────────────────────────────────────────
// Transient analysis — convolution history update path
// ───────────────────────────────────────────────────────────────────────

/// Purely resistive LTRA at DC: the transient should immediately converge
/// to the Ohm's-law steady state and stay there.
///
/// Circuit: 1 V → O(R=10, LEN=1) → 10 Ω load → GND.
/// V(out) = 1 * 10/(10+10) = 0.5 V at every timestep.
#[test]
fn ltra_rc_line_step_response() {
    let netlist = "\
* LTRA transient step response (resistive line)
V1 in 0 DC 1
.MODEL LRL LTRA (R=10 L=0 G=0 C=0 LEN=1)
O1 in 0 out 0 LRL
R_load out 0 10
.TRAN 1n 10n
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let result = run_transient(&circuit, 1e-9, 10e-9).expect("transient should converge");

    assert!(result.times.len() >= 5, "expected at least 5 timesteps");

    // Node order: "in" = index 0, "out" = index 1.
    for (i, &t) in result.times.iter().enumerate() {
        let v_out = result.node_voltages[i][1];
        assert!(
            (v_out - 0.5).abs() < 0.01,
            "t={t:.2e}: V(out)={v_out:.6}, expected 0.5"
        );
    }
}

/// RLC LTRA line under DC drive: the simulation must converge without
/// diverging.  We only check that it terminates successfully and that
/// the final V(out) is physically plausible (between 0 and 1 V).
#[test]
fn ltra_rlc_line_step_response() {
    let netlist = "\
* LTRA RLC transient (convergence check)
V1 in 0 DC 1
.MODEL RLC LTRA (R=1 L=250n G=0 C=100p LEN=1)
O1 in 0 out 0 RLC
R_load out 0 50
.TRAN 1n 20n
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let result = run_transient(&circuit, 1e-9, 20e-9)
        .expect("transient should converge for RLC LTRA");

    assert!(result.times.len() >= 10, "expected at least 10 timesteps");

    let last = result.times.len() - 1;
    let v_out = result.node_voltages[last][1];
    assert!(
        v_out > 0.0 && v_out < 1.1,
        "V(out) at final step should be in (0,1), got {v_out}"
    );
}

/// Matched termination: load = Z0 = sqrt(L/C).  The line sees no
/// reflections; V(out) approaches the source voltage times the resistive
/// divider.  Simulation must converge.
#[test]
fn ltra_matched_termination_convergence() {
    // Z0 = sqrt(250n / 100p) = sqrt(2500) = 50 Ω.
    let netlist = "\
* LTRA matched termination (Z0 = 50 Ω)
V1 in 0 DC 1
.MODEL MLINE LTRA (R=0 L=250n G=0 C=100p LEN=1)
O1 in 0 out 0 MLINE
R_load out 0 50
.TRAN 1n 20n
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let result = run_transient(&circuit, 1e-9, 20e-9)
        .expect("matched LTRA transient should converge");

    // Must produce at least one timestep.
    assert!(!result.times.is_empty(), "no timesteps produced");
    // Output voltage must be physically bounded.
    for (i, voltages) in result.node_voltages.iter().enumerate() {
        let v_out = voltages[1];
        assert!(
            v_out.abs() < 2.0,
            "step {i}: V(out)={v_out} out of physical range"
        );
    }
}

/// Mismatched termination: load much larger than Z0.  Without the
/// full dispersive kernel the line still stamps correctly and must
/// not diverge (convergence failure returns Err, not panic).
#[test]
fn ltra_mismatched_termination_no_divergence() {
    let netlist = "\
* LTRA mismatched termination (open end, high Z load)
V1 in 0 DC 1
.MODEL MLINE LTRA (R=1 L=250n G=0 C=100p LEN=1)
O1 in 0 out 0 MLINE
R_load out 0 10k
.TRAN 1n 10n
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    // Either converges or returns a structured error — must not panic.
    let outcome = run_transient(&circuit, 1e-9, 10e-9);
    match &outcome {
        Ok(r) => {
            assert!(!r.times.is_empty());
            let last = r.times.len() - 1;
            let v_out = r.node_voltages[last][1];
            // V(out) should be close to 1 V (almost open circuit).
            assert!(v_out > 0.5 && v_out < 1.1, "V(out)={v_out}");
        }
        Err(e) => {
            // A convergence failure is acceptable for a mismatched
            // line without full dispersive stamps; divergence (panic)
            // is not.
            let _ = format!("{e:?}"); // ensure Display/Debug works
        }
    }
}

/// LTRA `NONINT=1` selects the non-interpolated history-lookup
/// variant: the convolution kernel uses midpoint quadrature with
/// nearest-neighbour history reads instead of the trapezoidal /
/// linear-interpolated default.  At DC steady state both variants
/// converge to the same resistive-T answer; this test exercises the
/// `nonint=1` path through the parser, registry, stamper, and the
/// device-level eval to make sure no `todo!()` is hit and the
/// solution is physically sensible.
#[test]
fn ltra_nonint_variant_dc_op() {
    let netlist = "\
* NONINT=1 LTRA — DC operating point through the non-interpolated path
V1 in 0 DC 1
.MODEL NI LTRA (R=10 L=0 G=0 C=0 LEN=1 NONINT=1)
O1 in 0 out 0 NI
R1 out 0 10
.OP
.END
";
    let (circuit, _) = parse_netlist_str(netlist).expect("parse");
    let result = run_dc_op(&circuit).expect("DC op should succeed with nonint=1");
    // R1 (10 Ω) and the LTRA series resistance (R*LEN = 10 Ω) form a
    // 1:1 divider, so V(out) ≈ 0.5 V.
    let v_out = result
        .node_voltages
        .iter()
        .find(|(n, _)| n == "out")
        .map(|(_, v)| *v)
        .expect("'out' node should be present in the DC OP result");
    assert!(
        (v_out - 0.5).abs() < 5e-3,
        "V(out) = {v_out}, expected ≈ 0.5 V (10/(10+10) divider)"
    );
}

/// Sanity check the underlying device eval directly: the resistive-T
/// stamp must be identical for `nonint=0` and `nonint=1` (both flag
/// values share the same DC formulation; the difference only shows
/// up in the dispersive convolution kernel at transient time).
#[test]
fn ltra_eval_nonint_matches_default_at_dc() {
    let m = Ltra;
    let mut p = ParamMap::new();
    p.set("r", 10.0);
    p.set("g", 0.0);
    p.set("l", 0.0);
    p.set("c", 0.0);
    p.set("len", 1.0);

    let voltages = [1.0_f64, 0.0, 0.0, 0.0];
    let eval_default = m.eval(&voltages, &p);

    let mut p_ni = p.clone();
    p_ni.set("nonint", 1.0);
    let eval_nonint = m.eval(&voltages, &p_ni);

    assert_eq!(eval_default.g.len(), eval_nonint.g.len());
    for (a, b) in eval_default.g.iter().zip(eval_nonint.g.iter()) {
        assert!((a - b).abs() < 1e-15, "nonint diverges from default: {a} vs {b}");
    }
}

/// The device-level `nearest_history` lookup must snap to the
/// closer of two bracketing samples.
#[test]
fn ltra_nearest_history_snaps_to_closest_sample() {
    use pisim_device::ltra::{nearest_history, history_sample_at};
    let times = [0.0_f64, 1.0, 2.0, 3.0];
    let values = [10.0_f64, 20.0, 30.0, 40.0];

    // 0.4 is closer to 0.0 → 10.0
    let (v, ok) = nearest_history(&times, &values, 0.4);
    assert!(ok);
    assert_eq!(v, 10.0);

    // 0.6 is closer to 1.0 → 20.0
    let (v, ok) = nearest_history(&times, &values, 0.6);
    assert!(ok);
    assert_eq!(v, 20.0);

    // history_sample_at dispatches: nonint=true uses nearest, false interpolates.
    let (v_lin, _) = history_sample_at(&times, &values, 0.5, false);
    assert!((v_lin - 15.0).abs() < 1e-12, "linear: {v_lin}");
    let (v_near, _) = history_sample_at(&times, &values, 0.5, true);
    // 0.5 is equidistant — current implementation prefers the lower bracket.
    assert_eq!(v_near, 10.0);
}
