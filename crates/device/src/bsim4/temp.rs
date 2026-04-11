// BSIM4 — ported from Berkeley BSIM4.8.3 (ECL-2.0)
//
// Temperature pre-compute. Berkeley keeps almost all temperature scaling
// inside `b4temp.c` so each Newton iteration only sees the constant
// temperature-corrected values. We collapse the relevant subset into the
// instance-build path (`Bsim4Instance::from_model`).

#![allow(non_snake_case)]
