// BSIM3 — ported from Berkeley BSIM3v3.3 (ECL-2.0)
//
// Cold tier wrapper: ties together the user-supplied parameter set
// (`Bsim3ModelParams`) with model-card-level constants and flag access.
// One `Bsim3Model` is shared by all instances that reference the same
// `.MODEL` card.

#![allow(non_snake_case)]

use pisim_core::{DeviceKind, ParamMap};
use smallvec::{SmallVec, smallvec};

use crate::eval::{DeviceEval, DeviceModel};
use super::params::{Bsim3ModelParams, Bsim3Type};
use super::instance::Bsim3SizeParams;

/// A BSIM3 `.MODEL` card after parameter resolution but before
/// per-instance binning / temperature scaling.
#[derive(Debug, Clone, Copy)]
pub struct Bsim3Model {
    pub params: Bsim3ModelParams,
}

impl Bsim3Model {
    /// Construct from a `ParamMap` (typical parser path).
    pub fn from_map(map: &ParamMap, mos_type: Bsim3Type) -> Self {
        Self {
            params: Bsim3ModelParams::from_map(map, mos_type),
        }
    }

    /// Default NMOS card.
    pub fn nmos_default() -> Self {
        let mut p = Bsim3ModelParams::default();
        p.mos_type = Bsim3Type::Nmos;
        Self { params: p }
    }

    /// Default PMOS card.
    pub fn pmos_default() -> Self {
        let mut p = Bsim3ModelParams::default();
        p.mos_type = Bsim3Type::Pmos;
        // PMOS gets a smaller default low-field mobility.
        p.u0 = 0.025;
        Self { params: p }
    }

    #[inline]
    pub fn polarity(&self) -> f64 {
        self.params.mos_type.polarity()
    }

    #[inline]
    pub fn is_nmos(&self) -> bool {
        matches!(self.params.mos_type, Bsim3Type::Nmos)
    }
}

/// `Bsim3` is the device-model dispatch type registered with the
/// `DeviceRegistry`.  It carries the resolved model card by value so
/// that `DeviceDispatch` remains `Copy`.
///
/// Per-instance binning is performed lazily on each `eval` call from
/// the `ParamMap` of the device instance (which holds W/L/AS/AD/...).
/// This is the same lazy strategy used by [`crate::Vbic`] and keeps the
/// integration with the existing `DeviceModel` trait branchless.
#[derive(Debug, Clone, Copy)]
pub struct Bsim3 {
    pub model: Bsim3Model,
}

impl Bsim3 {
    /// Build a default NMOS BSIM3 device.
    pub fn nmos() -> Self {
        Self { model: Bsim3Model::nmos_default() }
    }

    /// Build a default PMOS BSIM3 device.
    pub fn pmos() -> Self {
        Self { model: Bsim3Model::pmos_default() }
    }
}

impl DeviceModel for Bsim3 {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        // Pin layout (matches MOS Level 1):
        //   pin 0 = drain, pin 1 = gate, pin 2 = source, pin 3 = bulk.
        let vd = voltages[0];
        let vg = voltages[1];
        let vs = voltages[2];
        let vb = if voltages.len() > 3 { voltages[3] } else { vs };

        // Resolve a per-instance binned/temperature-scaled parameter set.
        // The model card's defaults are blended with any instance-level
        // overrides found in `params` (W, L, etc).
        let merged = Bsim3ModelParams::from_map(params, self.model.params.mos_type);
        let model = Bsim3Model { params: merged };
        let size = Bsim3SizeParams::resolve(&model, params);

        // Polarity-aware bias terms — the equations operate in NMOS-like
        // coordinates and are flipped at stamp time.
        let pol = model.polarity();
        let vds = pol * (vd - vs);
        let vgs = pol * (vg - vs);
        let vbs = pol * (vb - vs);

        let mut op = super::eval::Bsim3OpPoint::default();
        super::eval::compute_dc_currents(&size, vgs, vds, vbs, &mut op);

        // GMIN leakage on the Vds branch — matches all other PiSIM device
        // models — and ensure the Jacobian stays well-conditioned even at
        // cutoff.
        const GDS_MIN: f64 = 1e-12;
        let id_total = op.ids + GDS_MIN * vds;
        let gds_total = op.gds + GDS_MIN;
        let gm_total = op.gm;
        let gmbs_total = op.gmbs;

        // Substrate impact-ionization current (drain → bulk).
        let isub = op.isub;
        let gisub_d = op.gbds; // d isub / d vds
        let gisub_g = op.gbgs; // d isub / d vgs
        let gisub_b = op.gbbs; // d isub / d vbs

        // Polarity-applied terminal currents.
        let id_signed   = pol * (id_total - isub);   // current into drain
        let isub_signed = pol * isub;                // current into bulk

        // Source: −(id − isub) − isub = −id (KCL)
        let is_signed = -pol * id_total;

        // Build the conductance Jacobian (in NMOS coordinates; sign flips
        // cancel because each row/col uses the same `pol` factor).
        //
        //   I_d  =  Ids - Isub
        //   I_s  = -Ids
        //   I_b  =  Isub
        //
        // d Ids / d Vd = +gds      (since vds = vd - vs)
        // d Ids / d Vg = +gm       (since vgs = vg - vs)
        // d Ids / d Vs = -(gm+gds+gmbs)
        // d Ids / d Vb = +gmbs
        let jac_dd =  gds_total - gisub_d;
        let jac_dg =  gm_total  - gisub_g;
        let jac_ds = -(gm_total + gds_total + gmbs_total) - (-gisub_d - gisub_g - gisub_b);
        let jac_db =  gmbs_total - gisub_b;

        let jac_sd = -gds_total;
        let jac_sg = -gm_total;
        let jac_ss =  gm_total + gds_total + gmbs_total;
        let jac_sb = -gmbs_total;

        let jac_bd =  gisub_d;
        let jac_bg =  gisub_g;
        let jac_bs = -(gisub_d + gisub_g + gisub_b);
        let jac_bb =  gisub_b;

        // ── AC small-signal C matrix (b3acld.c Ward-Dutton charge partitioning) ──
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
        //   C[S,*] = -(C[G,*] + C[D,*])
        let cgg = op.cgg;
        let cgd = op.cgd;
        let cgs = op.cgs;
        let cgb = op.cgb;
        let cdg = op.cdg;
        let cdd = op.cdd;
        let cds = op.cds;
        let cdb = op.cdb;

        DeviceEval {
            g: smallvec![id_signed, 0.0, is_signed, isub_signed],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0, jac_dd + GDS_MIN), (0, 1, jac_dg), (0, 2, jac_ds - GDS_MIN), (0, 3, jac_db),
                (2, 0, jac_sd - GDS_MIN), (2, 1, jac_sg), (2, 2, jac_ss + GDS_MIN), (2, 3, jac_sb),
                (3, 0, jac_bd),           (3, 1, jac_bg), (3, 2, jac_bs),           (3, 3, jac_bb),
            ],
            C: smallvec![
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
                // Source row (pin 2) — charge conservation: Qs = -(Qg + Qd)
                (2, 1, -(cgg + cdg)),
                (2, 0, -(cgd + cdd)),
                (2, 2, -(cgs + cds)),
                (2, 3, -(cgb + cdb)),
            ],
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn kind(&self) -> DeviceKind {
        if self.model.is_nmos() {
            DeviceKind::Bsim3N
        } else {
            DeviceKind::Bsim3P
        }
    }
}
