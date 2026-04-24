// BSIM4 — ported from Berkeley BSIM4.8.3 (ECL-2.0)
//
// Cold tier wrapper: ties together the user-supplied parameter set
// (`Bsim4ModelParams`) with model-card-level constants and flag access.
// One `Bsim4Model` is shared by all instances that reference the same
// `.MODEL` card.

#![allow(non_snake_case)]

use incspice_core::ParamMap;

use super::params::{Bsim4ModelParams, Bsim4Type};

/// A BSIM4 `.MODEL` card after parameter resolution but before
/// per-instance binning.
#[derive(Debug, Clone, Copy)]
pub struct Bsim4Model {
    /// All cold-tier parameters as supplied (or defaulted) by the user.
    pub params: Bsim4ModelParams,
}

impl Bsim4Model {
    /// Construct from a parameter map (typical parser path).
    pub fn from_map(map: &ParamMap, mos_type: Bsim4Type) -> Self {
        Self {
            params: Bsim4ModelParams::from_map(map, mos_type),
        }
    }

    /// Build a default NMOS model (used by tests / `MosfetN` fallback).
    pub fn nmos_default() -> Self {
        let mut p = Bsim4ModelParams::default();
        p.mos_type = Bsim4Type::Nmos;
        Self { params: p }
    }

    /// Build a default PMOS model.
    pub fn pmos_default() -> Self {
        let mut p = Bsim4ModelParams::default();
        p.mos_type = Bsim4Type::Pmos;
        Self { params: p }
    }

    #[inline]
    pub fn polarity(&self) -> f64 {
        self.params.mos_type.polarity()
    }

    #[inline]
    pub fn is_nmos(&self) -> bool {
        matches!(self.params.mos_type, Bsim4Type::Nmos)
    }
}
