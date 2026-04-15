// BSIM4 — ported from Berkeley BSIM4.8.3 (ECL-2.0)
//
// Jacobian + RHS stamping for the DC load path.  Produces a 4-terminal
// (D, G, S, B) device evaluation in the same shape that the existing
// `bigospice_device::eval::DeviceEval` infrastructure already understands.
//
// Mapped pin layout (matches existing `MosfetLevel1`):
//   pin 0 = drain
//   pin 1 = gate
//   pin 2 = source
//   pin 3 = bulk
//
// The 5th node (substrate thermal `T`) for self-heating is left as a
// TODO — Bsim4Instance carries the temperature directly so the rest of
// the simulator does not see a thermal pin yet.

#![allow(non_snake_case)]

use smallvec::{smallvec, SmallVec};

use crate::eval::DeviceEval;

use super::eval::{evaluate_dc, Bsim4Eval};
use super::instance::Bsim4Instance;

/// Build a `DeviceEval` populated with the BSIM4 DC load contribution
/// for one device at the given terminal voltages.
///
/// The `C` matrix is populated with the intrinsic gate capacitances (Ward-Dutton
/// charge partitioning) and drain charge partition computed by `evaluate_dc`.
/// Pin layout: 0=D, 1=G, 2=S, 3=B.
///
/// Series S/D parasitic resistance (`rds`, from RDSW/PRWB/PRWG) is folded into
/// the conductance Jacobian via the first-order series approximation already
/// performed in `evaluate_dc` (gds_eff = gds/(1 + gds*Rds)).
pub fn stamp_bsim4(inst: &Bsim4Instance, voltages: &[f64]) -> DeviceEval {
    // Default safe sample if voltages aren't supplied (shouldn't happen).
    let vd = voltages.first().copied().unwrap_or(0.0);
    let vg = voltages.get(1).copied().unwrap_or(0.0);
    let vs = voltages.get(2).copied().unwrap_or(0.0);
    let vb = voltages.get(3).copied().unwrap_or(0.0);

    let e: Bsim4Eval = evaluate_dc(inst, vd, vg, vs, vb);

    // Companion model: linearise around (vd, vg, vs, vb).
    //
    // Ids(V) ≈ Ids0 + gm*(Vgs - Vgs0) + gds*(Vds - Vds0) + gmbs*(Vbs - Vbs0)
    //
    // Treat the linearised RHS the same way `MosfetLevel1` does — emit
    // the constant current at the drain (+) and source (−), with the
    // conductance entries mapping into the Jacobian sub-block.
    // Note: e.gds already incorporates the Rds folding done in evaluate_dc.
    let ids = e.ids;
    let gm   = e.gm;
    let gds  = e.gds;   // already Gds_eff = gds/(1 + gds*Rds)
    let gmbs = e.gmbs;

    // Currents into the four nodes (KCL): D = +Ids, S = −Ids, G = 0, B = 0.
    // Add GIDL/GISL leakage between D-B and S-B respectively.
    let id_node = ids + e.igidl;
    let is_node = -ids + e.igisl;
    let ib_node = -(e.igidl + e.igisl);

    // Jacobian entries — mirror `MosfetLevel1` layout but include the bulk
    // body-effect column and gmbs row.
    //
    // Row D (pin 0):
    //   d(Id)/dVd = +gds
    //   d(Id)/dVg = +gm
    //   d(Id)/dVs = -(gm + gds + gmbs)
    //   d(Id)/dVb = +gmbs
    // Row S (pin 2):
    //   d(Is)/dVd = -gds
    //   d(Is)/dVg = -gm
    //   d(Is)/dVs = +(gm + gds + gmbs)
    //   d(Is)/dVb = -gmbs
    let G: SmallVec<[(u8, u8, f64); 8]> = smallvec![
        (0, 0,  gds),
        (0, 1,  gm),
        (0, 2, -(gm + gds + gmbs)),
        (0, 3,  gmbs),
        (2, 0, -gds),
        (2, 1, -gm),
        (2, 2,  (gm + gds + gmbs)),
        (2, 3, -gmbs),
    ];

    // ── AC small-signal C matrix (b4acld.c charge partitioning) ──────────
    //
    // Pin convention: 0=D, 1=G, 2=S, 3=B.
    //
    // Gate charge Qg derivatives (row = pin 1 = G):
    //   C[G,G] = dQg/dVg = cgg
    //   C[G,D] = dQg/dVd = cgd
    //   C[G,S] = dQg/dVs = cgs
    //   C[G,B] = dQg/dVb = cgb
    //
    // Drain charge Qd derivatives (row = pin 0 = D):
    //   C[D,G] = dQd/dVg = cdg
    //   C[D,D] = dQd/dVd = cdd
    //   C[D,S] = dQd/dVs = cds
    //   C[D,B] = dQd/dVb = cdb
    //
    // Source charge Qs: enforce charge conservation Qg + Qd + Qs = 0.
    //   C[S,G] = -(cgg + cdg)
    //   C[S,D] = -(cgd + cdd)
    //   C[S,S] = -(cgs + cds)
    //   C[S,B] = -(cgb + cdb)
    let cgg = e.cgg;
    let cgd = e.cgd;
    let cgs = e.cgs;
    let cgb = e.cgb;
    let cdg = e.cdg;
    let cdd = e.cdd;
    let cds = e.cds;
    let cdb = e.cdb;

    let C: SmallVec<[(u8, u8, f64); 16]> = smallvec![
        // Gate row (pin 1)
        (1, 1,  cgg),
        (1, 0,  cgd),
        (1, 2,  cgs),
        (1, 3,  cgb),
        // Drain row (pin 0)
        (0, 1,  cdg),
        (0, 0,  cdd),
        (0, 2,  cds),
        (0, 3,  cdb),
        // Source row (pin 2) — charge conservation
        (2, 1, -(cgg + cdg)),
        (2, 0, -(cgd + cdd)),
        (2, 2, -(cgs + cds)),
        (2, 3, -(cgb + cdb)),
    ];

    DeviceEval {
        g:   smallvec![id_node, 0.0, is_node, ib_node],
        q:   smallvec![0.0, 0.0, 0.0, 0.0],
        G,
        C,
        rhs: SmallVec::new(),
    }
}
