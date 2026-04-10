// BSIM4 — ported from Berkeley BSIM4.8.3 (ECL-2.0)
//
// Temperature pre-compute. Berkeley keeps almost all temperature scaling
// inside `b4temp.c` so each Newton iteration only sees the constant
// temperature-corrected values. We collapse the relevant subset into the
// instance-build path (`Bsim4Instance::from_model`); this file exposes a
// helper for re-deriving an instance at a new device temperature for
// `.TEMP` sweeps.

#![allow(non_snake_case)]

use super::instance::{Bsim4Geometry, Bsim4Instance};
use super::model::Bsim4Model;

/// Re-derive a `Bsim4Instance` at a different `temp_k` (Kelvin).
///
/// Equivalent to running `BSIM4temp` for one device.  Used by `.TEMP`
/// sweeps and by `Bsim4Setup::rebuild_at_temp`.
pub fn temperature_recompute(
    model: &Bsim4Model,
    geom: &Bsim4Geometry,
    temp_k: f64,
) -> Bsim4Instance {
    Bsim4Instance::from_model(model, geom, temp_k)
}
