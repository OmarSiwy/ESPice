// BSIM4 — ported from Berkeley BSIM4.8.3 (ECL-2.0)
//
// Setup helpers — geometry resolution and instance binning.
// Equivalent to `BSIM4setup` in `b4set.c`, slimmed down to the parts the
// DC eval kernel actually consumes.

#![allow(non_snake_case)]

use incspice_core::ParamMap;

use super::instance::Bsim4Geometry;

/// Pull instance-level geometry parameters from a `ParamMap`.
pub fn geometry_from_map(map: &ParamMap) -> Bsim4Geometry {
    Bsim4Geometry {
        L: map.get_or("l", 1.0e-7),
        W: map.get_or("w", 1.0e-6),
        NF: map.get_or("nf", 1.0),
        M: map.get_or("m", 1.0),
        AS: map.get_or("as", 0.0),
        AD: map.get_or("ad", 0.0),
        PS: map.get_or("ps", 0.0),
        PD: map.get_or("pd", 0.0),
        NRS: map.get_or("nrs", 1.0),
        NRD: map.get_or("nrd", 1.0),
        SA: map.get_or("sa", 0.0),
        SB: map.get_or("sb", 0.0),
        SD: map.get_or("sd", 0.0),
    }
}
