# BigOSpice Issue Fix Plan

## Context
BJT DC OP 4 circuits (bjt_cascode, bjt_common_base, bjt_emitter_follower, bjt_ecl_gate) converge to wrong solution (99-102% error). These circuits work in ngspice. Root cause: (1) no BJT-specific initial guess heuristics, (2) plain NR returns immediately on convergence even if wrong solution, bypassing fallback sequence. BJT Jacobian derivatives (dqb/dvbe, dqb/dvbc) already correct.

---

## DONE (applied in session)

### P0.1: Source stepping GMIN (newton.rs line 1059)
ss_gmin now uses `max_source_current * 0.1` independent of source_factor. Fixes early stepping GMIN conditioning.

### P0.2: Divergence guard (newton.rs ~line 895)
If residual grows 100x over 4 iterations, nr_loop aborts. Fixes H001/H002 hang.

---

## P1: BJT Wrong Solution (4 circuits — priority)

### Root Cause (confirmed)
1. **No BJT initial guess heuristics** — `compute_dc_initial_guess` Pass 3 biases MOSFETs so Vgs > Vth. No equivalent for BJTs. Unknown BJT nodes → VDD/2 by default, can reverse-bias junctions.
2. **Immediate return on NR convergence** — `solve()` line 494: plain NR converges → return immediately → fallback (GMIN/source/homotopy) never reached.
3. **GMIN stepping divergence abort** — when GMIN detects divergence, breaks and retries plain NR. But plain NR already converged to wrong OP from bad initial guess.

### Fix A: BJT initial guess heuristics (newton.rs `compute_dc_initial_guess`)

Add after line 450 (after MOSFET Pass 3):

```rust
// Pass 4: Bias BJT base/emitter nodes for forward-active operation.
// Vbe ≈ 0.7V (NPN) or -0.7V (PNP). Set unknown nodes so junction is
// forward-biased from iteration 0.
for dev in circuit.devices() {
    let (base_guess, emit_guess) = match dev.kind {
        DeviceKind::BjtN => {
            // Collector known from Pass 1 (voltage source). Base: emit + 0.7V.
            // Emitter: if emitter resistor to ground, estimate Ic ≈ VCC/RC,
            // then Ib ≈ Ic/β, Vemitter ≈ Ib * Re.
            let vcc_estimate = v_max;
            let v_emit = vcc_estimate * 0.1; // default 10% of VDD
            let v_base = v_emit + 0.7;
            (v_base, v_emit)
        }
        DeviceKind::BjtP => {
            let v_emit = v_max * 0.9;
            let v_base = v_emit - 0.7;
            (v_base, v_emit)
        }
        _ => continue,
    };
    // Apply to base (pin 1), emitter (pin 2)
    for (pin, guess_val) in [(1, base_guess), (2, emit_guess)] {
        if let Some(n) = dev.node(pin as u8).filter(|n| !n.is_ground()) {
            let idx = (n.0 - 1) as usize;
            if idx < num_nodes && !known[idx] { guess[idx] = guess_val; }
        }
    }
}
```

### Fix B: Reduce max_voltage_step (newton.rs line 93-96, options.rs line 202)

Default 5.0V too large — causes NR overshoot into wrong basin. NGspice default ~0.5V.

```rust
// Crates/core/src/options.rs line 202:
// change: max_voltage_step: Some(5.0)
// to:     max_voltage_step: Some(1.0)
```

### Fix C: Verify solution basin before accepting NR result (newton.rs ~line 494)

After plain NR converges, check solution reasonableness before returning:

```rust
// In solve() around line 494, after plain nr_loop returns Some(result):
// Quick sanity check: no BJT should have |Vbe| > 3*0.7V or |Vbc| > 5V
// in a correctly-biased circuit
let sanity_ok = check_bjt_bias_sanity(circuit, &result.solution, registry);
if !sanity_ok {
    // Wrong basin — skip to GMIN stepping instead of returning
    x.copy_from_slice(&result.solution);
    // Continue to GMIN stepping loop (line 504)
} else {
    return Ok(result);
}
```

`check_bjt_bias_sanity`: iterate all BJT devices, compute junction voltages from solution, flag if any junction is reverse-biased beyond reasonable limits (>3V for BE, >5V for BC).

### Files to Modify
- `crates/solver/src/newton.rs`: `compute_dc_initial_guess` (line 450+), `solve()` (line 494+), `limit_step` call (line 856)
- `crates/core/src/options.rs`: `max_voltage_step` default (line 202)

### Verification
```bash
cargo test --test external -- --include-ignored bjt 2>&1 | grep -E "bjt_cascode|bjt_common_base|bjt_emitter_follower|PASS|FAIL"
```

---

## P1: LTRA Transmission Lines (7 circuits, NRMSE 9-77%)

### Root Cause
LTRA uses DC resistive-T fallback when history < 2 samples. For short electrical lengths, first few timesteps use DC model instead of full transmission line.

### Fix: LTRA timestep control (transient.rs)
```rust
// Sample LTRA at 10+ points per electrical length
let min_td = circuit.devices()
    .filter(|d| d.kind == DeviceKind::Ltra)
    .map(|d| LtraLineParams::from_params(&d.params).td().max(1e-15))
    .fold(f64::MAX, f64::min);
if min_td < f64::MAX {
    h = h.min(min_td / 10.0);
}
```

---

## P1: MOSFET DC Sweep (2 circuits, 16-36% error)

### Fix (dc_sweep.rs)
Invalidate LU cache between sweep points.

---

## P2: XSPICE AHDL Parsing (xspice_nand_gate)

### Fix (tokenizer.rs `parse_a_device_tokens`)
Handle AHDL model cards where `{` appears after model name. Don't use `token_to_node_name` for model name token.

---

## P2: Transient Accuracy

### class_b_crossover (32.8%) — BJT near-cutoff
Make GMIN proportional to junction current, not node voltage.

### bjt_ecl_gate (603%) — ECL small swing
Reduce `gmin_tol` scaling from 100 to 10.

---

## P2: AC Analysis (no output)

Check `crates/analysis/src/ac.rs` output storage.

---

## Critical Files
- `crates/solver/src/newton.rs` — NR loop, initial guess, fallback
- `crates/core/src/options.rs` — max_voltage_step default
- `crates/device/src/bjt.rs` — Gummel-Poon (already correct)
- `crates/solver/src/stamper.rs` — LTRA stamping
- `crates/analysis/src/transient.rs` — timestep control
- `crates/parser/src/tokenizer.rs` — AHDL parsing
- `crates/analysis/src/dc_sweep.rs` — DC sweep LU cache
