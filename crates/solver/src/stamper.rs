use bigospice_core::{Circuit, DeviceKind, LtraHistoryStore};
use bigospice_device::{DeviceEval, DeviceRegistry, eval_bsource_i, eval_bsource_v};
use bigospice_device::{LtraLineParams, LtraNorton, eval_ltra_transient_slices_nonint};
use bigospice_linalg::{DenseVec, TripletMatrix};
use rayon::prelude::*;

use crate::junction_limit;

/// Map a B-source "ref pin" index to a global MNA column index.
///
/// For `BsourceV`: pins 0,1 = n+,n-; pin 2 = branch; pins 3+ = ref nodes.
/// For `BsourceI`: pins 0,1 = n+,n-; pins 2+ = ref nodes.
///
/// `ref_node_names[i]` gives the node name for ref_pin = base_pin + i.
fn bsource_ref_pin_to_global(
    pin: u8,
    base_pin: u8,
    ref_node_names: &[String],
    circuit: &Circuit,
) -> Option<usize> {
    let ref_idx = pin.checked_sub(base_pin)? as usize;
    let name = ref_node_names.get(ref_idx)?;
    let nid = circuit.find_node(name)?;
    if nid.is_ground() {
        None
    } else {
        Some((nid.0 - 1) as usize)
    }
}

/// Map a device-local pin index to a global MNA row/column index.
///
/// - Pins `0..num_terminals` map to the connected node's `matrix_index`.
/// - The first pin beyond `num_terminals` maps to the branch current
///   variable at `num_vars + branch_index`.
/// - Returns `None` for ground (no matrix entry).
fn pin_to_global(
    device: &bigospice_core::DeviceInstance,
    pin: u8,
    num_vars: u32,
) -> Option<usize> {
    let num_terms = device.terminals.len() as u8;
    if pin < num_terms {
        let node_id = device.terminals[pin as usize].node;
        if node_id.is_ground() {
            None
        } else {
            // matrix_index = node_id - 1 (ground is 0, first real node is 1)
            Some((node_id.0 - 1) as usize)
        }
    } else {
        // Branch variable
        device
            .branch_index
            .map(|bi| num_vars as usize + bi as usize)
    }
}

/// Stamp the entire circuit at the given solution vector.
///
/// Returns `(jacobian, residual)` where:
/// - `jacobian`: the MNA Jacobian matrix in triplet form
/// - `residual`: the right-hand side F(x) (should -> 0 at convergence)
///
/// Note: this allocates new buffers each call. For the NR hot loop, prefer
/// `stamp_circuit_into` which reuses pre-allocated buffers.
pub fn stamp_circuit(
    dim: usize,
    circuit: &Circuit,
    solution: &[f64],
    registry: &DeviceRegistry,
) -> (TripletMatrix, DenseVec) {
    let mut triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut residual = DenseVec::zeros(dim);
    stamp_circuit_into(dim, circuit, solution, registry, &mut triplet, &mut residual, None);
    (triplet, residual)
}

/// Stamp the entire circuit into pre-allocated buffers.
///
/// Clears `triplet` and `residual` before stamping. This avoids heap
/// allocation on every NR iteration — the caller allocates once and
/// reuses across iterations.
///
/// When `prev_solution` is provided, SPICE-style per-device junction
/// voltage limiting is applied before device evaluation. This prevents
/// Newton from overshooting across PN junction exponentials and MOSFET
/// region boundaries.
pub fn stamp_circuit_into(
    _dim: usize,
    circuit: &Circuit,
    solution: &[f64],
    registry: &DeviceRegistry,
    triplet: &mut TripletMatrix,
    residual: &mut DenseVec,
    prev_solution: Option<&[f64]>,
) {
    triplet.clear();
    residual.fill_zero();

    for device in circuit.devices() {
        // ── T-line special path ───────────────────────────────────────────
        // Lossless T-lines use Branin's method with two branch variables
        // (port-1 and port-2 Thevenin sources) and delayed history values.
        // The DeviceRegistry eval cannot access the circuit history, so we
        // stamp T-lines directly here.
        if device.kind == DeviceKind::Tline {
            let bi = match device.branch_index {
                Some(b) => b as usize,
                None => continue,
            };

            let num_vars = circuit.num_vars() as usize;
            let br1 = num_vars + bi;       // port-1 branch row
            let br2 = num_vars + bi + 1;   // port-2 branch row (always bi+1)

            // Resolve node rows (None = ground).
            let row_of = |pin: u8| -> Option<usize> {
                let t = device.terminals.get(pin as usize)?;
                if t.node.is_ground() { None } else { Some((t.node.0 - 1) as usize) }
            };
            let rp1 = row_of(0); // port-1 n+
            let rn1 = row_of(1); // port-1 n-
            let rp2 = row_of(2); // port-2 n+
            let rn2 = row_of(3); // port-2 n-

            // Terminal voltages.
            let vp1 = rp1.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);
            let vn1 = rn1.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);
            let vp2 = rp2.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);
            let vn2 = rn2.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);

            // Branch currents.
            let i_br1 = if br1 < solution.len() { solution[br1] } else { 0.0 };
            let i_br2 = if br2 < solution.len() { solution[br2] } else { 0.0 };

            let z0 = device.params.get_or("z0", 50.0);

            // History values default to zero (cold-start / DC OP).
            let (e_hist_p1, e_hist_p2) = (0.0_f64, 0.0_f64);

            // Branch equation residuals: V(n+) - V(n-) - Z0*I_br - E_hist
            let br_res1 = (vp1 - vn1) - z0 * i_br1 - e_hist_p1;
            let br_res2 = (vp2 - vn2) - z0 * i_br2 - e_hist_p2;

            // Stamp residuals.
            if let Some(r) = rp1 { residual[r] += i_br1; }
            if let Some(r) = rn1 { residual[r] -= i_br1; }
            if let Some(r) = rp2 { residual[r] += i_br2; }
            if let Some(r) = rn2 { residual[r] -= i_br2; }
            residual[br1] += br_res1;
            residual[br2] += br_res2;

            // Stamp Jacobian G.
            // Port 1 KCL
            if let Some(r) = rp1 { triplet.add(r, br1, 1.0); }
            if let Some(r) = rn1 { triplet.add(r, br1, -1.0); }
            // Port 2 KCL
            if let Some(r) = rp2 { triplet.add(r, br2, 1.0); }
            if let Some(r) = rn2 { triplet.add(r, br2, -1.0); }
            // Branch equation 1
            if let Some(r) = rp1 { triplet.add(br1, r, 1.0); }
            if let Some(r) = rn1 { triplet.add(br1, r, -1.0); }
            triplet.add(br1, br1, -z0);
            // Branch equation 2
            if let Some(r) = rp2 { triplet.add(br2, r, 1.0); }
            if let Some(r) = rn2 { triplet.add(br2, r, -1.0); }
            triplet.add(br2, br2, -z0);

            continue;
        }
        // ── end T-line special path ───────────────────────────────────────

        // ── B-source special path ─────────────────────────────────────────
        // B-sources carry a per-instance expression in `circuit.bsource_exprs`.
        // We evaluate them here and stamp directly, bypassing DeviceRegistry.
        if matches!(device.kind, DeviceKind::BsourceV | DeviceKind::BsourceI | DeviceKind::VcvsExpr | DeviceKind::VccsExpr) {
            let bse = match circuit.bsource_expr(device.id) {
                Some(b) => b,
                None => continue, // expression missing — skip
            };

            // Resolve referenced node voltages.
            let ref_vbuf: Vec<(&str, f64)> = bse
                .node_refs
                .iter()
                .map(|name| {
                    let v = circuit
                        .find_node(name)
                        .map(|nid| {
                            if nid.is_ground() {
                                0.0
                            } else {
                                let idx = (nid.0 - 1) as usize;
                                if idx < solution.len() { solution[idx] } else { 0.0 }
                            }
                        })
                        .unwrap_or(0.0);
                    (name.as_str(), v)
                })
                .collect();

            // Dummy borrow trick: the borrow of bse.node_refs ends before we
            // use ref_vbuf below, but the lifetimes are tricky. We rebuild
            // a owned-string version as a Vec<(String, f64)> first, then
            // transmute to &[(&str, f64)] via the buf.
            // Actually we need `ref_vbuf: Vec<(&str, f64)>` where the `&str`
            // borrows from `bse.node_refs`. This is safe because `bse` lives
            // for the duration of the loop body and `ref_vbuf` is consumed
            // before `bse` is dropped.
            // The above code already does this correctly — ref_vbuf borrows from
            // bse.node_refs elements. Proceed.
            let _ = &ref_vbuf; // ensure the borrow is kept alive

            let vp = device.terminals.first().map(|t| {
                if t.node.is_ground() { 0.0 } else {
                    let idx = (t.node.0 - 1) as usize;
                    if idx < solution.len() { solution[idx] } else { 0.0 }
                }
            }).unwrap_or(0.0);
            let vn = device.terminals.get(1).map(|t| {
                if t.node.is_ground() { 0.0 } else {
                    let idx = (t.node.0 - 1) as usize;
                    if idx < solution.len() { solution[idx] } else { 0.0 }
                }
            }).unwrap_or(0.0);

            let is_voltage_form = matches!(device.kind, DeviceKind::BsourceV | DeviceKind::VcvsExpr);
            let eval_result = if is_voltage_form {
                let br_idx = circuit.num_vars() as usize
                    + device.branch_index.unwrap() as usize;
                let i_branch = if br_idx < solution.len() { solution[br_idx] } else { 0.0 };
                eval_bsource_v(bse, vp, vn, &ref_vbuf, i_branch)
            } else {
                eval_bsource_i(bse, &ref_vbuf)
            };

            let eval = match eval_result {
                Ok(e) => e,
                Err(_) => continue, // expression eval error — skip device
            };

            // Stamp residual for n+ and n-.
            let np_row = if device.terminals[0].node.is_ground() { None } else {
                Some((device.terminals[0].node.0 - 1) as usize)
            };
            let nn_row = if device.terminals.len() < 2 || device.terminals[1].node.is_ground() {
                None
            } else {
                Some((device.terminals[1].node.0 - 1) as usize)
            };

            if is_voltage_form {
                // g[0] = I_br (at n+), g[1] = -I_br (at n-), g[2] = branch_eq = V(n+)-V(n-)-f
                if let Some(r) = np_row { residual[r] += eval.g[0]; }
                if let Some(r) = nn_row { residual[r] += eval.g[1]; }
                // Branch equation residual: g[2] already equals V(n+)-V(n-)-f = 0 at solution.
                // Do NOT subtract rhs again — g[2] is the complete residual already.
                let br_row = circuit.num_vars() as usize + device.branch_index.unwrap() as usize;
                residual[br_row] += eval.g[2];
            } else {
                // Current form: g[0] at n+, g[1] at n-
                if let Some(r) = np_row { residual[r] += eval.g[0]; }
                if let Some(r) = nn_row { residual[r] += eval.g[1]; }
            }

            // Stamp Jacobian entries.
            // For voltage form: pin layout 0=n+, 1=n-, 2=branch, 3+i=ref[i]
            // For current form: pin layout 0=n+, 1=n-, 2+i=ref[i]
            let (base_ref_pin, branch_row_opt) = if is_voltage_form {
                let br = circuit.num_vars() as usize + device.branch_index.unwrap() as usize;
                (3u8, Some(br))
            } else {
                (2u8, None)
            };

            #[allow(non_snake_case)]
            for &(row_pin, col_pin, value) in &eval.G {
                // Map row pin
                let row = match row_pin {
                    0 => np_row,
                    1 => nn_row,
                    2 if is_voltage_form => branch_row_opt,
                    _ => None,
                };
                // Map col pin — may be a "ref pin" beyond the terminal+branch range
                let col = if col_pin < base_ref_pin {
                    match col_pin {
                        0 => np_row,
                        1 => nn_row,
                        2 if is_voltage_form => branch_row_opt,
                        _ => None,
                    }
                } else {
                    bsource_ref_pin_to_global(col_pin, base_ref_pin, &bse.node_refs, circuit)
                };

                if let (Some(r), Some(c)) = (row, col) {
                    triplet.add(r, c, value);
                }
            }

            continue; // done with this B-source device
        }
        // ── end B-source special path ─────────────────────────────────────

        let model = match registry.get(device.kind) {
            Some(m) => m,
            None => continue,
        };

        // Extract terminal voltages from the solution vector.
        let mut voltages: smallvec::SmallVec<[f64; 4]> = smallvec::SmallVec::new();
        for term in &device.terminals {
            if term.node.is_ground() {
                voltages.push(0.0);
            } else {
                let idx = (term.node.0 - 1) as usize;
                voltages.push(if idx < solution.len() { solution[idx] } else { 0.0 });
            }
        }

        // Apply per-device junction voltage limiting when previous solution
        // is available. Only affects nonlinear devices (diodes, MOSFETs).
        if let Some(prev) = prev_solution {
            let mut old_voltages: smallvec::SmallVec<[f64; 4]> = smallvec::SmallVec::new();
            for term in &device.terminals {
                if term.node.is_ground() {
                    old_voltages.push(0.0);
                } else {
                    let idx = (term.node.0 - 1) as usize;
                    old_voltages.push(if idx < prev.len() { prev[idx] } else { 0.0 });
                }
            }
            voltages = junction_limit::limit_junction_voltages(
                device.kind,
                &voltages,
                &old_voltages,
                &device.params,
            );
        }

        // Get branch current if this device has one.
        let eval: DeviceEval = if device.needs_branch() {
            let br_idx = circuit.num_vars() as usize + device.branch_index.unwrap() as usize;
            let i_branch = if br_idx < solution.len() { solution[br_idx] } else { 0.0 };
            model.eval_with_branch(&voltages, i_branch, &device.params)
        } else {
            model.eval(&voltages, &device.params)
        };

        // --- Stamp residual (F vector) ---
        // For non-branch devices (e.g. current sources), eval.rhs carries
        // KCL contributions indexed by pin. For branch devices (e.g. voltage
        // sources), eval.rhs carries the branch equation constraint.
        let has_branch = device.needs_branch();
        for (pin, &gi) in eval.g.iter().enumerate() {
            let pin = pin as u8;
            if let Some(row) = pin_to_global(device, pin, circuit.num_vars()) {
                if pin < device.terminals.len() as u8 {
                    // KCL row: add device current
                    let rhs_val = if !has_branch && (pin as usize) < eval.rhs.len() {
                        eval.rhs[pin as usize]
                    } else {
                        0.0
                    };
                    residual[row] += gi + rhs_val;
                } else {
                    // Branch equation residual
                    let rhs_idx = pin as usize - device.terminals.len();
                    let rhs_val = if rhs_idx < eval.rhs.len() {
                        eval.rhs[rhs_idx]
                    } else {
                        0.0
                    };
                    residual[row] += gi - rhs_val;
                }
            }
        }

        // --- Stamp Jacobian (G matrix) ---
        #[allow(non_snake_case)]
        for &(row_pin, col_pin, value) in &eval.G {
            if let (Some(r), Some(c)) = (
                pin_to_global(device, row_pin, circuit.num_vars()),
                pin_to_global(device, col_pin, circuit.num_vars()),
            ) {
                triplet.add(r, c, value);
            }
        }
    }
}

/// Stamp the entire circuit producing both the resistive (G) and reactive (C)
/// Jacobian contributions, plus the resistive residual `g(x)` and the reactive
/// residual `q(x)` (charges/fluxes).
///
/// This is the lower-level entry point used by transient and AC analysis.
/// - `g_triplet` accumulates the resistive Jacobian `G = dg/dx`.
/// - `c_triplet` accumulates the reactive Jacobian `C = dq/dx`.
/// - `residual_g` accumulates `g(x) + sources(t)` (the DC residual).
/// - `residual_q` accumulates `q(x)` (charge/flux state vector).
/// - `sim_time` — current simulation time in seconds, forwarded to time-varying
///   sources (voltage sources, current sources with waveforms).
///
/// All four buffers are cleared at the start. The DC stamper (`stamp_circuit_into`)
/// is unaffected and continues to be used by the existing Newton solver.
pub fn stamp_circuit_gc_into(
    circuit: &Circuit,
    solution: &[f64],
    registry: &DeviceRegistry,
    g_triplet: &mut TripletMatrix,
    c_triplet: &mut TripletMatrix,
    residual_g: &mut DenseVec,
    residual_q: &mut DenseVec,
) {
    stamp_circuit_gc_at_time(circuit, solution, registry, g_triplet, c_triplet, residual_g, residual_q, 0.0);
}

/// Time-aware variant of [`stamp_circuit_gc_into`].
///
/// Called by transient analysis at each timestep with the current `sim_time`.
/// Independent sources evaluate their configured waveform at `sim_time`; all
/// other devices ignore `sim_time` and behave identically to
/// `stamp_circuit_gc_into`.
#[allow(clippy::too_many_arguments)]
pub fn stamp_circuit_gc_at_time(
    circuit: &Circuit,
    solution: &[f64],
    registry: &DeviceRegistry,
    g_triplet: &mut TripletMatrix,
    c_triplet: &mut TripletMatrix,
    residual_g: &mut DenseVec,
    residual_q: &mut DenseVec,
    sim_time: f64,
) {
    g_triplet.clear();
    c_triplet.clear();
    residual_g.fill_zero();
    residual_q.fill_zero();

    for device in circuit.devices() {
        // ── T-line special path (transient GC stamper) ────────────────────
        if device.kind == DeviceKind::Tline {
            let bi = match device.branch_index {
                Some(b) => b as usize,
                None => continue,
            };

            let num_vars = circuit.num_vars() as usize;
            let br1 = num_vars + bi;
            let br2 = num_vars + bi + 1;

            let row_of = |pin: u8| -> Option<usize> {
                let t = device.terminals.get(pin as usize)?;
                if t.node.is_ground() { None } else { Some((t.node.0 - 1) as usize) }
            };
            let rp1 = row_of(0);
            let rn1 = row_of(1);
            let rp2 = row_of(2);
            let rn2 = row_of(3);

            let vp1 = rp1.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);
            let vn1 = rn1.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);
            let vp2 = rp2.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);
            let vn2 = rn2.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);

            let i_br1 = if br1 < solution.len() { solution[br1] } else { 0.0 };
            let i_br2 = if br2 < solution.len() { solution[br2] } else { 0.0 };

            let z0 = device.params.get_or("z0", 50.0);

            // Look up delayed incident waves from history (zero = cold start).
            let (e_hist_p1, e_hist_p2) = if let Some(hist) = circuit.tline_history(device.id) {
                (hist.delayed_p1(sim_time), hist.delayed_p2(sim_time))
            } else {
                (0.0, 0.0)
            };

            let br_res1 = (vp1 - vn1) - z0 * i_br1 - e_hist_p1;
            let br_res2 = (vp2 - vn2) - z0 * i_br2 - e_hist_p2;

            // Stamp resistive residual.
            if let Some(r) = rp1 { residual_g[r] += i_br1; }
            if let Some(r) = rn1 { residual_g[r] -= i_br1; }
            if let Some(r) = rp2 { residual_g[r] += i_br2; }
            if let Some(r) = rn2 { residual_g[r] -= i_br2; }
            residual_g[br1] += br_res1;
            residual_g[br2] += br_res2;

            // Stamp G Jacobian.
            if let Some(r) = rp1 { g_triplet.add(r, br1, 1.0); }
            if let Some(r) = rn1 { g_triplet.add(r, br1, -1.0); }
            if let Some(r) = rp2 { g_triplet.add(r, br2, 1.0); }
            if let Some(r) = rn2 { g_triplet.add(r, br2, -1.0); }
            if let Some(r) = rp1 { g_triplet.add(br1, r, 1.0); }
            if let Some(r) = rn1 { g_triplet.add(br1, r, -1.0); }
            g_triplet.add(br1, br1, -z0);
            if let Some(r) = rp2 { g_triplet.add(br2, r, 1.0); }
            if let Some(r) = rn2 { g_triplet.add(br2, r, -1.0); }
            g_triplet.add(br2, br2, -z0);

            continue;
        }
        // ── end T-line special path ───────────────────────────────────────

        // ── LTRA special path ─────────────────────────────────────────────
        if device.kind == DeviceKind::Ltra {
            let lp = LtraLineParams::from_params(&device.params);

            // Helper: map pin index to global MNA row, or None for ground.
            let pin_row = |pin: u8| -> Option<usize> {
                pin_to_global(device, pin, circuit.num_vars())
            };

            let row_p1 = pin_row(0);
            let row_n1 = pin_row(1);
            let row_p2 = pin_row(2);
            let row_n2 = pin_row(3);

            // DC resistive-T stamp (always present for Jacobian conditioning).
            let (r_eff, g_shunt) = {
                let r_tot = lp.r * lp.len;
                let r_eff = if r_tot > 0.0 { r_tot } else { 1.0 / 1e-12_f64 };
                let g_shunt = 0.5 * lp.g * lp.len;
                (r_eff, g_shunt)
            };
            let g_s = 1.0 / r_eff;

            let vp1 = row_p1.map(|r| solution[r]).unwrap_or(0.0);
            let vn1 = row_n1.map(|r| solution[r]).unwrap_or(0.0);
            let vp2 = row_p2.map(|r| solution[r]).unwrap_or(0.0);
            let vn2 = row_n2.map(|r| solution[r]).unwrap_or(0.0);

            // Norton equivalent from the convolution history.  The
            // `nonint` model option chooses between the trapezoidal
            // (interpolated) and midpoint (nearest-neighbour) variants.
            let nonint = device.params.get_or("nonint", 0.0) != 0.0;
            let norton: LtraNorton = if let Some(hist) = circuit.ltra_history(device.id) {
                eval_ltra_transient_slices_nonint(
                    sim_time, &lp, &hist.times, &hist.v1, &hist.v2, &hist.i1, &hist.i2, nonint,
                )
            } else {
                LtraNorton::default()
            };

            // When the companion model is active (g_eq > 0, i.e. history
            // has >= 2 samples), use the transmission-line companion:
            //   Port k: I_k = Y0 * V_k + I_eq_k
            // where Y0 = 1/Z0 is the characteristic admittance.
            // Otherwise fall back to the DC resistive-T network.
            let use_companion = norton.g_eq_p1 > 0.0;

            if use_companion {
                let y0 = norton.g_eq_p1; // = 1/Z0
                let v1_diff = vp1 - vn1;
                let v2_diff = vp2 - vn2;

                // Residual: I_k = Y0 * V_k_diff + I_eq_k
                if let Some(r) = row_p1 { residual_g[r] += y0 * v1_diff + norton.i_eq_p1; }
                if let Some(r) = row_n1 { residual_g[r] += -(y0 * v1_diff + norton.i_eq_p1); }
                if let Some(r) = row_p2 { residual_g[r] += y0 * v2_diff + norton.i_eq_p2; }
                if let Some(r) = row_n2 { residual_g[r] += -(y0 * v2_diff + norton.i_eq_p2); }

                // Jacobian: dI/dV — Y0 self-admittance at each port,
                // no cross-port terms (coupling is through the Norton current).
                if let (Some(r), Some(c)) = (row_p1, row_p1) { g_triplet.add(r, c, y0); }
                if let (Some(r), Some(c)) = (row_p1, row_n1) { g_triplet.add(r, c, -y0); }
                if let (Some(r), Some(c)) = (row_n1, row_p1) { g_triplet.add(r, c, -y0); }
                if let (Some(r), Some(c)) = (row_n1, row_n1) { g_triplet.add(r, c, y0); }
                if let (Some(r), Some(c)) = (row_p2, row_p2) { g_triplet.add(r, c, y0); }
                if let (Some(r), Some(c)) = (row_p2, row_n2) { g_triplet.add(r, c, -y0); }
                if let (Some(r), Some(c)) = (row_n2, row_p2) { g_triplet.add(r, c, -y0); }
                if let (Some(r), Some(c)) = (row_n2, row_n2) { g_triplet.add(r, c, y0); }
            } else {
                // DC resistive-T fallback (no history yet).
                let i_series = (vp1 - vp2) * g_s;
                let i_sh1 = (vp1 - vn1) * g_shunt;
                let i_sh2 = (vp2 - vn2) * g_shunt;

                if let Some(r) = row_p1 { residual_g[r] += i_series + i_sh1; }
                if let Some(r) = row_n1 { residual_g[r] += -i_sh1; }
                if let Some(r) = row_p2 { residual_g[r] += -i_series + i_sh2; }
                if let Some(r) = row_n2 { residual_g[r] += -i_sh2; }

                let gs = g_s;
                let gh = g_shunt;
                if let (Some(r), Some(c)) = (row_p1, row_p1) { g_triplet.add(r, c, gs + gh); }
                if let (Some(r), Some(c)) = (row_p1, row_n1) { g_triplet.add(r, c, -gh); }
                if let (Some(r), Some(c)) = (row_p1, row_p2) { g_triplet.add(r, c, -gs); }
                if let (Some(r), Some(c)) = (row_n1, row_p1) { g_triplet.add(r, c, -gh); }
                if let (Some(r), Some(c)) = (row_n1, row_n1) { g_triplet.add(r, c, gh); }
                if let (Some(r), Some(c)) = (row_p2, row_p1) { g_triplet.add(r, c, -gs); }
                if let (Some(r), Some(c)) = (row_p2, row_p2) { g_triplet.add(r, c, gs + gh); }
                if let (Some(r), Some(c)) = (row_p2, row_n2) { g_triplet.add(r, c, -gh); }
                if let (Some(r), Some(c)) = (row_n2, row_p2) { g_triplet.add(r, c, -gh); }
                if let (Some(r), Some(c)) = (row_n2, row_n2) { g_triplet.add(r, c, gh); }
            }

            continue;
        }
        // ── end LTRA special path ─────────────────────────────────────────

        let model = match registry.get(device.kind) {
            Some(m) => m,
            None => continue,
        };

        // Extract terminal voltages from the solution vector.
        let mut voltages: smallvec::SmallVec<[f64; 4]> = smallvec::SmallVec::new();
        for term in &device.terminals {
            if term.node.is_ground() {
                voltages.push(0.0);
            } else {
                let idx = (term.node.0 - 1) as usize;
                voltages.push(if idx < solution.len() { solution[idx] } else { 0.0 });
            }
        }

        // `DeviceDispatch::eval_at_time(voltages, branch_current, params, t)`
        // handles all devices; for non-branch devices it passes 0.0 as the
        // branch current (unused) and dispatches to the waveform-aware path
        // for V/I sources, or falls back to the normal eval for everything else.
        let eval: DeviceEval = if device.needs_branch() {
            let br_idx = circuit.num_vars() as usize + device.branch_index.unwrap() as usize;
            let i_branch = if br_idx < solution.len() { solution[br_idx] } else { 0.0 };
            model.eval_at_time(&voltages, i_branch, &device.params, sim_time)
        } else {
            model.eval_at_time(&voltages, 0.0, &device.params, sim_time)
        };

        let has_branch = device.needs_branch();

        // --- Stamp resistive residual g(x) and source RHS into residual_g ---
        for (pin, &gi) in eval.g.iter().enumerate() {
            let pin_u = pin as u8;
            if let Some(row) = pin_to_global(device, pin_u, circuit.num_vars()) {
                if pin_u < device.terminals.len() as u8 {
                    let rhs_val = if !has_branch && pin < eval.rhs.len() {
                        eval.rhs[pin]
                    } else {
                        0.0
                    };
                    residual_g[row] += gi + rhs_val;
                } else {
                    let rhs_idx = pin - device.terminals.len();
                    let rhs_val = if rhs_idx < eval.rhs.len() {
                        eval.rhs[rhs_idx]
                    } else {
                        0.0
                    };
                    residual_g[row] += gi - rhs_val;
                }
            }
        }

        // --- Stamp charge residual q(x) into residual_q ---
        for (pin, &qi) in eval.q.iter().enumerate() {
            let pin_u = pin as u8;
            if let Some(row) = pin_to_global(device, pin_u, circuit.num_vars()) {
                residual_q[row] += qi;
            }
        }

        // --- Stamp G Jacobian ---
        #[allow(non_snake_case)]
        for &(row_pin, col_pin, value) in &eval.G {
            if let (Some(r), Some(c)) = (
                pin_to_global(device, row_pin, circuit.num_vars()),
                pin_to_global(device, col_pin, circuit.num_vars()),
            ) {
                g_triplet.add(r, c, value);
            }
        }

        // --- Stamp C Jacobian ---
        #[allow(non_snake_case)]
        for &(row_pin, col_pin, value) in &eval.C {
            if let (Some(r), Some(c)) = (
                pin_to_global(device, row_pin, circuit.num_vars()),
                pin_to_global(device, col_pin, circuit.num_vars()),
            ) {
                c_triplet.add(r, c, value);
            }
        }
    }
}

/// Stamp the entire circuit with independent source values scaled by `source_factor`.
///
/// This is used by source stepping: sources are ramped from 0 to their full
/// value in graduated steps to help convergence on nonlinear circuits.
/// Only independent voltage and current sources have their RHS scaled;
/// all other devices (resistors, MOSFETs, etc.) are stamped normally.
pub fn stamp_circuit_with_source_scale(
    dim: usize,
    circuit: &Circuit,
    solution: &[f64],
    registry: &DeviceRegistry,
    source_factor: f64,
    prev_solution: Option<&[f64]>,
) -> (TripletMatrix, DenseVec) {
    use bigospice_core::DeviceKind;

    let mut triplet = TripletMatrix::with_capacity(dim, dim, dim * 4);
    let mut residual = DenseVec::zeros(dim);

    for device in circuit.devices() {
        let model = match registry.get(device.kind) {
            Some(m) => m,
            None => continue,
        };

        // Extract terminal voltages from the solution vector.
        let mut voltages: smallvec::SmallVec<[f64; 4]> = smallvec::SmallVec::new();
        for term in &device.terminals {
            if term.node.is_ground() {
                voltages.push(0.0);
            } else {
                let idx = (term.node.0 - 1) as usize;
                voltages.push(if idx < solution.len() { solution[idx] } else { 0.0 });
            }
        }

        // Apply per-device junction voltage limiting.
        if let Some(prev) = prev_solution {
            let mut old_voltages: smallvec::SmallVec<[f64; 4]> = smallvec::SmallVec::new();
            for term in &device.terminals {
                if term.node.is_ground() {
                    old_voltages.push(0.0);
                } else {
                    let idx = (term.node.0 - 1) as usize;
                    old_voltages.push(if idx < prev.len() { prev[idx] } else { 0.0 });
                }
            }
            voltages = junction_limit::limit_junction_voltages(
                device.kind,
                &voltages,
                &old_voltages,
                &device.params,
            );
        }

        // Get branch current if this device has one.
        let mut eval: DeviceEval = if device.needs_branch() {
            let br_idx = circuit.num_vars() as usize + device.branch_index.unwrap() as usize;
            let i_branch = if br_idx < solution.len() { solution[br_idx] } else { 0.0 };
            model.eval_with_branch(&voltages, i_branch, &device.params)
        } else {
            model.eval(&voltages, &device.params)
        };

        // Scale independent source RHS values.
        let is_independent = matches!(
            device.kind,
            DeviceKind::VoltageSource | DeviceKind::CurrentSource
        );
        if is_independent {
            for val in eval.rhs.iter_mut() {
                *val *= source_factor;
            }
        }

        // --- Stamp residual (F vector) ---
        let has_branch = device.needs_branch();
        for (pin, &gi) in eval.g.iter().enumerate() {
            let pin = pin as u8;
            if let Some(row) = pin_to_global(device, pin, circuit.num_vars()) {
                if pin < device.terminals.len() as u8 {
                    let rhs_val = if !has_branch && (pin as usize) < eval.rhs.len() {
                        eval.rhs[pin as usize]
                    } else {
                        0.0
                    };
                    residual[row] += gi + rhs_val;
                } else {
                    let rhs_idx = pin as usize - device.terminals.len();
                    let rhs_val = if rhs_idx < eval.rhs.len() {
                        eval.rhs[rhs_idx]
                    } else {
                        0.0
                    };
                    residual[row] += gi - rhs_val;
                }
            }
        }

        // --- Stamp Jacobian (G matrix) ---
        #[allow(non_snake_case)]
        for &(row_pin, col_pin, value) in &eval.G {
            if let (Some(r), Some(c)) = (
                pin_to_global(device, row_pin, circuit.num_vars()),
                pin_to_global(device, col_pin, circuit.num_vars()),
            ) {
                triplet.add(r, c, value);
            }
        }
    }

    (triplet, residual)
}

/// Parallel variant of [`stamp_circuit_gc_at_time`] for the transient inner loop.
///
/// Device evaluations (the compute-heavy part) are performed in parallel
/// using Rayon's `par_iter`.  Stamping into the triplet matrices and residual
/// vectors is done serially afterward, since `TripletMatrix` / `DenseVec`
/// are not `Send + Sync`.
///
/// Special-path devices (T-lines, LTRA, B-sources) are handled serially
/// in a single pre-pass that runs before the parallel eval, because they
/// require read access to circuit-level history buffers.
///
/// Only devices that resolve through `DeviceRegistry` participate in the
/// parallel eval.  All others fall through to the serial special paths.
#[allow(clippy::too_many_arguments)]
pub fn stamp_circuit_gc_par_at_time(
    circuit: &Circuit,
    solution: &[f64],
    registry: &DeviceRegistry,
    g_triplet: &mut TripletMatrix,
    c_triplet: &mut TripletMatrix,
    residual_g: &mut DenseVec,
    residual_q: &mut DenseVec,
    sim_time: f64,
) {
    g_triplet.clear();
    c_triplet.clear();
    residual_g.fill_zero();
    residual_q.fill_zero();

    // ── Serial pre-pass: special-path devices ─────────────────────────────
    // T-line, LTRA, and B-source devices need circuit history or bsource
    // expression access; stamp them serially first (same logic as the serial
    // stamper) and skip them in the parallel eval below.
    for device in circuit.devices() {
        match device.kind {
            DeviceKind::Tline => {
                let bi = match device.branch_index { Some(b) => b as usize, None => continue };
                let num_vars = circuit.num_vars() as usize;
                let br1 = num_vars + bi;
                let br2 = num_vars + bi + 1;
                let row_of = |pin: u8| -> Option<usize> {
                    let t = device.terminals.get(pin as usize)?;
                    if t.node.is_ground() { None } else { Some((t.node.0 - 1) as usize) }
                };
                let rp1 = row_of(0); let rn1 = row_of(1);
                let rp2 = row_of(2); let rn2 = row_of(3);
                let vp1 = rp1.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);
                let vn1 = rn1.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);
                let vp2 = rp2.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);
                let vn2 = rn2.map(|r| if r < solution.len() { solution[r] } else { 0.0 }).unwrap_or(0.0);
                let i_br1 = if br1 < solution.len() { solution[br1] } else { 0.0 };
                let i_br2 = if br2 < solution.len() { solution[br2] } else { 0.0 };
                let z0 = device.params.get_or("z0", 50.0);
                let (e_hist_p1, e_hist_p2) = if let Some(hist) = circuit.tline_history(device.id) {
                    (hist.delayed_p1(sim_time), hist.delayed_p2(sim_time))
                } else { (0.0, 0.0) };
                let br_res1 = (vp1 - vn1) - z0 * i_br1 - e_hist_p1;
                let br_res2 = (vp2 - vn2) - z0 * i_br2 - e_hist_p2;
                if let Some(r) = rp1 { residual_g[r] += i_br1; }
                if let Some(r) = rn1 { residual_g[r] -= i_br1; }
                if let Some(r) = rp2 { residual_g[r] += i_br2; }
                if let Some(r) = rn2 { residual_g[r] -= i_br2; }
                residual_g[br1] += br_res1;
                residual_g[br2] += br_res2;
                if let Some(r) = rp1 { g_triplet.add(r, br1, 1.0); }
                if let Some(r) = rn1 { g_triplet.add(r, br1, -1.0); }
                if let Some(r) = rp2 { g_triplet.add(r, br2, 1.0); }
                if let Some(r) = rn2 { g_triplet.add(r, br2, -1.0); }
                if let Some(r) = rp1 { g_triplet.add(br1, r, 1.0); }
                if let Some(r) = rn1 { g_triplet.add(br1, r, -1.0); }
                g_triplet.add(br1, br1, -z0);
                if let Some(r) = rp2 { g_triplet.add(br2, r, 1.0); }
                if let Some(r) = rn2 { g_triplet.add(br2, r, -1.0); }
                g_triplet.add(br2, br2, -z0);
            }
            DeviceKind::Ltra => {
                let lp = LtraLineParams::from_params(&device.params);
                let pin_row = |pin: u8| -> Option<usize> { pin_to_global(device, pin, circuit.num_vars()) };
                let row_p1 = pin_row(0); let row_n1 = pin_row(1);
                let row_p2 = pin_row(2); let row_n2 = pin_row(3);
                let r_tot = lp.r * lp.len;
                let r_eff = if r_tot > 0.0 { r_tot } else { 1.0 / 1e-12_f64 };
                let g_s = 1.0 / r_eff;
                let g_shunt = 0.5 * lp.g * lp.len;
                let vp1 = row_p1.map(|r| solution[r]).unwrap_or(0.0);
                let vn1 = row_n1.map(|r| solution[r]).unwrap_or(0.0);
                let vp2 = row_p2.map(|r| solution[r]).unwrap_or(0.0);
                let vn2 = row_n2.map(|r| solution[r]).unwrap_or(0.0);
                let nonint = device.params.get_or("nonint", 0.0) != 0.0;
                let norton: LtraNorton = if let Some(hist) = circuit.ltra_history(device.id) {
                    eval_ltra_transient_slices_nonint(sim_time, &lp, &hist.times, &hist.v1, &hist.v2, &hist.i1, &hist.i2, nonint)
                } else { LtraNorton::default() };
                let use_companion = norton.g_eq_p1 > 0.0;
                if use_companion {
                    let y0 = norton.g_eq_p1;
                    let v1d = vp1 - vn1;
                    let v2d = vp2 - vn2;
                    if let Some(r) = row_p1 { residual_g[r] += y0 * v1d + norton.i_eq_p1; }
                    if let Some(r) = row_n1 { residual_g[r] += -(y0 * v1d + norton.i_eq_p1); }
                    if let Some(r) = row_p2 { residual_g[r] += y0 * v2d + norton.i_eq_p2; }
                    if let Some(r) = row_n2 { residual_g[r] += -(y0 * v2d + norton.i_eq_p2); }
                    if let (Some(r), Some(c)) = (row_p1, row_p1) { g_triplet.add(r, c, y0); }
                    if let (Some(r), Some(c)) = (row_p1, row_n1) { g_triplet.add(r, c, -y0); }
                    if let (Some(r), Some(c)) = (row_n1, row_p1) { g_triplet.add(r, c, -y0); }
                    if let (Some(r), Some(c)) = (row_n1, row_n1) { g_triplet.add(r, c, y0); }
                    if let (Some(r), Some(c)) = (row_p2, row_p2) { g_triplet.add(r, c, y0); }
                    if let (Some(r), Some(c)) = (row_p2, row_n2) { g_triplet.add(r, c, -y0); }
                    if let (Some(r), Some(c)) = (row_n2, row_p2) { g_triplet.add(r, c, -y0); }
                    if let (Some(r), Some(c)) = (row_n2, row_n2) { g_triplet.add(r, c, y0); }
                } else {
                    let i_series = (vp1 - vp2) * g_s;
                    let i_sh1 = (vp1 - vn1) * g_shunt;
                    let i_sh2 = (vp2 - vn2) * g_shunt;
                    if let Some(r) = row_p1 { residual_g[r] += i_series + i_sh1; }
                    if let Some(r) = row_n1 { residual_g[r] += -i_sh1; }
                    if let Some(r) = row_p2 { residual_g[r] += -i_series + i_sh2; }
                    if let Some(r) = row_n2 { residual_g[r] += -i_sh2; }
                    let gs = g_s; let gh = g_shunt;
                    if let (Some(r), Some(c)) = (row_p1, row_p1) { g_triplet.add(r, c, gs + gh); }
                    if let (Some(r), Some(c)) = (row_p1, row_n1) { g_triplet.add(r, c, -gh); }
                    if let (Some(r), Some(c)) = (row_p1, row_p2) { g_triplet.add(r, c, -gs); }
                    if let (Some(r), Some(c)) = (row_n1, row_p1) { g_triplet.add(r, c, -gh); }
                    if let (Some(r), Some(c)) = (row_n1, row_n1) { g_triplet.add(r, c, gh); }
                    if let (Some(r), Some(c)) = (row_p2, row_p1) { g_triplet.add(r, c, -gs); }
                    if let (Some(r), Some(c)) = (row_p2, row_p2) { g_triplet.add(r, c, gs + gh); }
                    if let (Some(r), Some(c)) = (row_p2, row_n2) { g_triplet.add(r, c, -gh); }
                    if let (Some(r), Some(c)) = (row_n2, row_p2) { g_triplet.add(r, c, -gh); }
                    if let (Some(r), Some(c)) = (row_n2, row_n2) { g_triplet.add(r, c, gh); }
                }
            }
            DeviceKind::BsourceV | DeviceKind::BsourceI | DeviceKind::VcvsExpr | DeviceKind::VccsExpr => {
                let bse = match circuit.bsource_expr(device.id) { Some(b) => b, None => continue };
                let ref_vbuf: Vec<(&str, f64)> = bse.node_refs.iter()
                    .map(|name| {
                        let v = circuit.find_node(name)
                            .map(|nid| if nid.is_ground() { 0.0 } else {
                                let idx = (nid.0 - 1) as usize;
                                if idx < solution.len() { solution[idx] } else { 0.0 }
                            }).unwrap_or(0.0);
                        (name.as_str(), v)
                    }).collect();
                let _ = &ref_vbuf;
                let vp = device.terminals.first().map(|t| if t.node.is_ground() { 0.0 } else {
                    let idx = (t.node.0 - 1) as usize;
                    if idx < solution.len() { solution[idx] } else { 0.0 }
                }).unwrap_or(0.0);
                let vn = device.terminals.get(1).map(|t| if t.node.is_ground() { 0.0 } else {
                    let idx = (t.node.0 - 1) as usize;
                    if idx < solution.len() { solution[idx] } else { 0.0 }
                }).unwrap_or(0.0);
                let is_voltage_form = matches!(device.kind, DeviceKind::BsourceV | DeviceKind::VcvsExpr);
                let eval_result = if is_voltage_form {
                    let br_idx = circuit.num_vars() as usize + device.branch_index.unwrap() as usize;
                    let i_branch = if br_idx < solution.len() { solution[br_idx] } else { 0.0 };
                    eval_bsource_v(bse, vp, vn, &ref_vbuf, i_branch)
                } else { eval_bsource_i(bse, &ref_vbuf) };
                let eval = match eval_result { Ok(e) => e, Err(_) => continue };
                let np_row = if device.terminals[0].node.is_ground() { None } else {
                    Some((device.terminals[0].node.0 - 1) as usize)
                };
                let nn_row = if device.terminals.len() < 2 || device.terminals[1].node.is_ground() {
                    None
                } else { Some((device.terminals[1].node.0 - 1) as usize) };
                if is_voltage_form {
                    if let Some(r) = np_row { residual_g[r] += eval.g[0]; }
                    if let Some(r) = nn_row { residual_g[r] += eval.g[1]; }
                    let br_row = circuit.num_vars() as usize + device.branch_index.unwrap() as usize;
                    residual_g[br_row] += eval.g[2];
                } else {
                    if let Some(r) = np_row { residual_g[r] += eval.g[0]; }
                    if let Some(r) = nn_row { residual_g[r] += eval.g[1]; }
                }
                let (base_ref_pin, branch_row_opt) = if is_voltage_form {
                    let br = circuit.num_vars() as usize + device.branch_index.unwrap() as usize;
                    (3u8, Some(br))
                } else { (2u8, None) };
                #[allow(non_snake_case)]
                for &(row_pin, col_pin, value) in &eval.G {
                    let row = match row_pin {
                        0 => np_row, 1 => nn_row,
                        2 if is_voltage_form => branch_row_opt, _ => None,
                    };
                    let col = if col_pin < base_ref_pin {
                        match col_pin {
                            0 => np_row, 1 => nn_row,
                            2 if is_voltage_form => branch_row_opt, _ => None,
                        }
                    } else {
                        bsource_ref_pin_to_global(col_pin, base_ref_pin, &bse.node_refs, circuit)
                    };
                    if let (Some(r), Some(c)) = (row, col) { g_triplet.add(r, c, value); }
                }
            }
            _ => {} // handled in parallel eval below
        }
    }

    // ── Parallel eval pass: registry-dispatched devices ───────────────────
    // Collect per-device inputs (terminal voltages + branch current + model)
    // into a Vec so we can drive par_iter over it without borrowing `circuit`
    // during the parallel section.

    // Each entry: (device_index, voltages, branch_current_opt, model_kind)
    // We store the DeviceEval result alongside the device index so we can
    // stamp in order after the parallel section.
    struct ParEvalInput {
        dev_idx: usize,
        voltages: smallvec::SmallVec<[f64; 4]>,
        branch_current: f64,
    }

    let devices = circuit.devices();
    let num_vars = circuit.num_vars();

    let par_inputs: Vec<ParEvalInput> = devices
        .iter()
        .enumerate()
        .filter(|(_, dev)| {
            !matches!(
                dev.kind,
                DeviceKind::Tline
                    | DeviceKind::Ltra
                    | DeviceKind::BsourceV
                    | DeviceKind::BsourceI
                    | DeviceKind::VcvsExpr
                    | DeviceKind::VccsExpr
            ) && registry.get(dev.kind).is_some()
        })
        .map(|(i, dev)| {
            let mut voltages: smallvec::SmallVec<[f64; 4]> = smallvec::SmallVec::new();
            for term in &dev.terminals {
                if term.node.is_ground() {
                    voltages.push(0.0);
                } else {
                    let idx = (term.node.0 - 1) as usize;
                    voltages.push(if idx < solution.len() { solution[idx] } else { 0.0 });
                }
            }
            let has_branch = dev.needs_branch();
            let branch_current = if has_branch {
                let br_idx = num_vars as usize + dev.branch_index.unwrap() as usize;
                if br_idx < solution.len() { solution[br_idx] } else { 0.0 }
            } else {
                0.0
            };
            ParEvalInput { dev_idx: i, voltages, branch_current }
        })
        .collect();

    // Parallel evaluation: each thread evaluates one device's model.
    // `DeviceDispatch` is `Copy`, so we can cheaply clone registry references.
    let eval_results: Vec<(usize, DeviceEval)> = par_inputs
        .into_par_iter()
        .map(|inp| {
            let dev = &devices[inp.dev_idx];
            let model = registry.get(dev.kind).unwrap();
            let eval = model.eval_at_time(&inp.voltages, inp.branch_current, &dev.params, sim_time);
            (inp.dev_idx, eval)
        })
        .collect();

    // ── Serial stamp pass ─────────────────────────────────────────────────
    // Apply DeviceEval results into the matrices serially.
    for (dev_idx, eval) in eval_results {
        let dev = &devices[dev_idx];
        let has_branch = dev.needs_branch();

        // Stamp resistive residual g(x).
        for (pin, &gi) in eval.g.iter().enumerate() {
            let pin_u = pin as u8;
            if let Some(row) = pin_to_global(dev, pin_u, num_vars) {
                if pin_u < dev.terminals.len() as u8 {
                    let rhs_val = if !has_branch && pin < eval.rhs.len() { eval.rhs[pin] } else { 0.0 };
                    residual_g[row] += gi + rhs_val;
                } else {
                    let rhs_idx = pin - dev.terminals.len();
                    let rhs_val = if rhs_idx < eval.rhs.len() { eval.rhs[rhs_idx] } else { 0.0 };
                    residual_g[row] += gi - rhs_val;
                }
            }
        }

        // Stamp charge residual q(x).
        for (pin, &qi) in eval.q.iter().enumerate() {
            let pin_u = pin as u8;
            if let Some(row) = pin_to_global(dev, pin_u, num_vars) {
                residual_q[row] += qi;
            }
        }

        // Stamp G Jacobian.
        #[allow(non_snake_case)]
        for &(row_pin, col_pin, value) in &eval.G {
            if let (Some(r), Some(c)) = (
                pin_to_global(dev, row_pin, num_vars),
                pin_to_global(dev, col_pin, num_vars),
            ) {
                g_triplet.add(r, c, value);
            }
        }

        // Stamp C Jacobian.
        #[allow(non_snake_case)]
        for &(row_pin, col_pin, value) in &eval.C {
            if let (Some(r), Some(c)) = (
                pin_to_global(dev, row_pin, num_vars),
                pin_to_global(dev, col_pin, num_vars),
            ) {
                c_triplet.add(r, c, value);
            }
        }
    }
}

/// Update T-line history buffers after a converged transient timestep.
///
/// Must be called once per accepted timestep with the converged `solution`
/// and the current simulation `time`.  For each T-line in the circuit it
/// computes the outgoing wave observables:
///
///   E_p1(t) = V(n1+,t) - V(n1-,t) + Z0 * I_br1(t)   (traveling toward port 2)
///   E_p2(t) = V(n2+,t) - V(n2-,t) + Z0 * I_br2(t)   (traveling toward port 1)
///
/// and pushes them into the ring buffer so the next timestep can retrieve
/// the delayed values.
pub fn update_tline_histories(circuit: &mut Circuit, solution: &[f64], time: f64) {
    use bigospice_core::DeviceKind;

    // Collect (id, e1, e2) to avoid simultaneous borrow of circuit.
    let mut updates: Vec<(bigospice_core::DeviceId, f64, f64, f64, f64)> = Vec::new();

    for device in circuit.devices() {
        if device.kind != DeviceKind::Tline {
            continue;
        }
        let bi = match device.branch_index {
            Some(b) => b as usize,
            None => continue,
        };

        let num_vars = circuit.num_vars() as usize;
        let br1 = num_vars + bi;
        let br2 = num_vars + bi + 1;

        let node_v = |pin: u8| -> f64 {
            device.terminals.get(pin as usize).map(|t| {
                if t.node.is_ground() {
                    0.0
                } else {
                    let idx = (t.node.0 - 1) as usize;
                    if idx < solution.len() { solution[idx] } else { 0.0 }
                }
            }).unwrap_or(0.0)
        };

        let vp1 = node_v(0);
        let vn1 = node_v(1);
        let vp2 = node_v(2);
        let vn2 = node_v(3);

        let i_br1 = if br1 < solution.len() { solution[br1] } else { 0.0 };
        let i_br2 = if br2 < solution.len() { solution[br2] } else { 0.0 };

        let z0 = device.params.get_or("z0", 50.0);

        // Outgoing wave at port 1 (the signal that will arrive at port 2 after TD).
        let e_p1 = (vp1 - vn1) + z0 * i_br1;
        // Outgoing wave at port 2 (the signal that will arrive at port 1 after TD).
        let e_p2 = (vp2 - vn2) + z0 * i_br2;

        updates.push((device.id, e_p1, e_p2, z0, device.params.get_or("td", 1e-9)));
    }

    for (id, e_p1, e_p2, z0, td) in updates {
        // Ensure a history buffer exists (first call for this device).
        if circuit.tline_history(id).is_none() {
            // Capacity: enough for TD / min_expected_dt samples (default 256).
            circuit.add_tline_history(id, bigospice_core::TlineHistory::new(z0, td, 256));
        }
        if let Some(hist) = circuit.tline_history_mut(id) {
            hist.push_p1(time, e_p1);
            hist.push_p2(time, e_p2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_core::*;

    /// Build: V1=5V from node 1 to GND, R1=1k from node 1 to node 2, R2=1k from node 2 to GND
    fn voltage_divider() -> Circuit {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");

        let v1 = DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource, &[(0, n1), (1, NodeId::GROUND)])
            .with_param("dc", 5.0);
        let r1 = DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor, &[(0, n1), (1, n2)])
            .with_param("resistance", 1000.0);
        let r2 = DeviceInstance::new(DeviceId::new(0), "R2", DeviceKind::Resistor, &[(0, n2), (1, NodeId::GROUND)])
            .with_param("resistance", 1000.0);

        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.add_device(r2);
        ckt.build_topology();
        ckt
    }

    #[test]
    fn stamper_dimensions() {
        let ckt = voltage_divider();
        let dim = ckt.mna_dimension();
        // 2 nodes + 1 branch = 3
        assert_eq!(dim, 3);
    }

    #[test]
    fn stamp_at_solution() {
        let ckt = voltage_divider();
        let reg = DeviceRegistry::new_default();
        let dim = ckt.mna_dimension();

        // At the correct solution: V(1)=5, V(2)=2.5, I_V1=-0.0025
        let x = vec![5.0, 2.5, -0.0025];
        let (jac_triplet, res) = stamp_circuit(dim, &ckt, &x, &reg);

        // At the correct solution, residual should be near zero
        for i in 0..3 {
            assert!(
                res[i].abs() < 1e-10,
                "residual[{}] = {} (expected ~0)",
                i,
                res[i]
            );
        }

        // Jacobian should be non-empty
        assert!(jac_triplet.nnz() > 0);
    }

    #[test]
    fn stamp_at_zero_gives_nonzero_residual() {
        let ckt = voltage_divider();
        let reg = DeviceRegistry::new_default();
        let dim = ckt.mna_dimension();

        let x = vec![0.0, 0.0, 0.0];
        let (_jac, res) = stamp_circuit(dim, &ckt, &x, &reg);

        // Branch equation residual: V(1)-V(GND) - 5.0 = -5.0
        assert!(res[2].abs() > 1.0, "branch residual should be large at x=0");
    }
}

/// Record the current port voltages and computed axial currents for every
/// LTRA element into the circuit's `LtraHistoryStore`.
///
/// Called by the transient driver after each accepted timestep, before
/// advancing to the next.  The stored waveform data is consumed by
/// `stamp_circuit_gc_at_time` during the next Newton iteration to form the
/// Roychowdhury-Pederson Norton equivalent.
pub fn update_ltra_histories(circuit: &mut Circuit, solution: &[f64], time: f64) {
    // Collect updates first to avoid borrow-checker issues with circuit.
    let mut updates: Vec<(bigospice_core::DeviceId, f64, f64, f64, f64)> = Vec::new();

    for device in circuit.devices() {
        if device.kind != DeviceKind::Ltra {
            continue;
        }
        // Resolve pin voltages from the solution vector.
        let pin_v = |pin: u8| -> f64 {
            let term = device.terminals.get(pin as usize);
            match term {
                Some(t) if !t.node.is_ground() => {
                    let idx = (t.node.0 - 1) as usize;
                    if idx < solution.len() { solution[idx] } else { 0.0 }
                }
                _ => 0.0,
            }
        };

        let vp1 = pin_v(0);
        let vn1 = pin_v(1);
        let vp2 = pin_v(2);
        let vn2 = pin_v(3);
        let v1 = vp1 - vn1;
        let v2 = vp2 - vn2;

        // Compute port current using the companion model when history
        // is available (transient), or DC resistive-T for initialization.
        let lp = LtraLineParams::from_params(&device.params);
        let nonint = device.params.get_or("nonint", 0.0) != 0.0;
        let (i1, i2) = if let Some(hist) = circuit.ltra_history(device.id) {
            if hist.times.len() >= 2 {
                let norton = eval_ltra_transient_slices_nonint(
                    time, &lp, &hist.times, &hist.v1, &hist.v2,
                    &hist.i1, &hist.i2, nonint,
                );
                // LTRA residual current at port k = Y0*Vk + I_eq_k
                // This is current LEAVING the node = current INTO the line.
                let y0 = norton.g_eq_p1;
                (y0 * v1 + norton.i_eq_p1, y0 * v2 + norton.i_eq_p2)
            } else {
                let r_tot = (lp.r * lp.len).max(0.0);
                let r_eff = if r_tot > 0.0 { r_tot } else { 1.0 / 1e-12_f64 };
                let i = (v1 - v2) / r_eff;
                (i, -i)
            }
        } else {
            let r_tot = (lp.r * lp.len).max(0.0);
            let r_eff = if r_tot > 0.0 { r_tot } else { 1.0 / 1e-12_f64 };
            let i = (v1 - v2) / r_eff;
            (i, -i)
        };

        updates.push((device.id, v1, v2, i1, i2));
    }

    for (id, v1, v2, i1, i2) in updates {
        if circuit.ltra_history(id).is_none() {
            circuit.add_ltra_history(id, LtraHistoryStore::with_capacity(256));
        }
        if let Some(hist) = circuit.ltra_history_mut(id) {
            hist.push(time, v1, v2, i1, i2);
        }
    }
}
