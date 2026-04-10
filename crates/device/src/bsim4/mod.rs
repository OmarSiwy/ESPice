// BSIM4 — ported from Berkeley BSIM4.8.3 (ECL-2.0)
//
// Module wiring for the BSIM4 hand port.  Layered cold/warm/hot tiers:
//
//   params.rs   — Cold:  Bsim4ModelParams (the ~500-entry .MODEL card)
//   model.rs    — Cold wrapper:    Bsim4Model
//   instance.rs — Warm:  Bsim4Instance (per-device, after binning + temp)
//   state.rs    — Hot SoA arrays:  Bsim4InstanceArray (vds[], vgs[], …)
//   temp.rs     — Temperature pre-compute helper
//   setup.rs    — Geometry / instance build helper
//   eval.rs     — DC physics: Vth, Vgsteff, mu_eff, Vdsat, Ids, GIDL/GISL
//   stamp.rs    — Jacobian + RHS stamping (4-terminal D,G,S,B)

#![allow(non_snake_case)]

pub mod params;
pub mod model;
pub mod instance;
pub mod state;
pub mod temp;
pub mod setup;
pub mod eval;
pub mod stamp;

pub use eval::{evaluate_dc, Bsim4Eval};
pub use instance::{Bsim4Geometry, Bsim4Instance};
pub use model::Bsim4Model;
pub use params::{Bsim4ModelFlags, Bsim4ModelParams, Bsim4Type};
pub use state::Bsim4InstanceArray;

use pisim_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Top-level BSIM4 device adapter.  Implements the existing
/// `DeviceModel` trait so the simulator can stamp BSIM4 instances
/// through the same dispatch path as Level-1 MOSFETs.
///
/// One `Bsim4` value per polarity (NMOS / PMOS).  Per-instance
/// geometry, model parameters, and temperature live in the
/// `ParamMap` that is supplied at every `eval` call (consistent with
/// every other DC device in this crate).  The cold-tier `Bsim4Model`
/// is rebuilt per call from that `ParamMap` — this is more expensive
/// than the warm-cached form but matches the existing trait, and the
/// rebuild is still O(1) wrt circuit size.
#[derive(Debug, Clone, Copy)]
pub struct Bsim4 {
    pub mos_type: Bsim4Type,
}

impl Bsim4 {
    pub const fn nmos() -> Self {
        Self { mos_type: Bsim4Type::Nmos }
    }
    pub const fn pmos() -> Self {
        Self { mos_type: Bsim4Type::Pmos }
    }
}

impl DeviceModel for Bsim4 {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let model = Bsim4Model::from_map(params, self.mos_type);
        let geom  = setup::geometry_from_map(params);
        let temp_k = params.get_or("temp", 300.15);
        let inst  = Bsim4Instance::from_model(&model, &geom, temp_k);
        stamp::stamp_bsim4(&inst, voltages)
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn kind(&self) -> DeviceKind {
        match self.mos_type {
            Bsim4Type::Nmos => DeviceKind::Bsim4N,
            Bsim4Type::Pmos => DeviceKind::Bsim4P,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nmos_params() -> ParamMap {
        let mut p = ParamMap::new();
        p.set("level", 14.0);
        p.set("vth0",  0.5);
        p.set("u0",    0.067);
        p.set("vsat",  8.0e4);
        p.set("toxe",  3.0e-9);
        p.set("nfactor", 1.0);
        p.set("w",     1.0e-6);
        p.set("l",     1.0e-7);
        p
    }

    #[test]
    fn bsim4_nmos_cutoff_yields_small_current() {
        let m = Bsim4::nmos();
        let p = nmos_params();
        let e = m.eval(&[1.0, 0.0, 0.0, 0.0], &p);
        assert!(e.g[0].abs() < 1.0e-6, "Id at Vgs=0 should be sub-threshold, got {}", e.g[0]);
    }

    #[test]
    fn bsim4_nmos_saturation_positive_id() {
        let m = Bsim4::nmos();
        let p = nmos_params();
        let e = m.eval(&[1.0, 1.2, 0.0, 0.0], &p);
        assert!(e.g[0] > 0.0, "Id should be positive in saturation, got {}", e.g[0]);
        // KCL: Id + Is + Ig + Ib = 0
        let kcl = e.g[0] + e.g[1] + e.g[2] + e.g[3];
        assert!(kcl.abs() < 1.0e-9, "KCL violation: {kcl}");
    }

    #[test]
    fn bsim4_nmos_id_increases_with_vgs() {
        let m = Bsim4::nmos();
        let p = nmos_params();
        let e1 = m.eval(&[1.0, 0.6, 0.0, 0.0], &p);
        let e2 = m.eval(&[1.0, 1.0, 0.0, 0.0], &p);
        let e3 = m.eval(&[1.0, 1.4, 0.0, 0.0], &p);
        assert!(e2.g[0] > e1.g[0], "Id(Vgs=1.0) should exceed Id(Vgs=0.6)");
        assert!(e3.g[0] > e2.g[0], "Id(Vgs=1.4) should exceed Id(Vgs=1.0)");
    }

    #[test]
    fn bsim4_pmos_polarity() {
        let m = Bsim4::pmos();
        let mut p = nmos_params();
        p.set("vth0", -0.5);
        // PMOS forward bias: Vgs = -1.2, Vds = -1.0
        let e = m.eval(&[-1.0, -1.2, 0.0, 0.0], &p);
        // For PMOS, drain current is negative (current flows from S to D).
        assert!(e.g[0] <= 1.0e-9, "PMOS Id should be ≤ 0 in forward bias, got {}", e.g[0]);
    }
}
