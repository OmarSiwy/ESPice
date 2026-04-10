// BSIM3 — ported from Berkeley BSIM3v3.3 (ECL-2.0)
//
// Temperature pre-compute. The full Berkeley `b3temp.c` is folded into
// `instance::Bsim3SizeParams::resolve()` for compactness; this module
// is reserved for future expansion (S/D diode tnom scaling, vjsm/vjdm
// linearization, k1/k2 temperature coefficients, etc.).
//
// Reference (READ-ONLY):
//   tests/external/ngspice/src/spicelib/devices/bsim3/b3temp.c

#![allow(non_snake_case, dead_code)]
