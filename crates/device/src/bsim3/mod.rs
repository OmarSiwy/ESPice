// BSIM3 — ported from Berkeley BSIM3v3.3 (ECL-2.0)
//
// This submodule implements the BSIM3v3.3 MOSFET compact model as a hand
// port of the Berkeley reference release.  ngspice's GPL-3 patched copy is
// used only as a structural / algorithmic reference; no source code is
// copied verbatim.
//
// Architecture (Data-Oriented Design):
//
//   ┌──────────┐    ┌──────────┐    ┌──────────────┐
//   │ params   │ →  │ model    │ →  │ instance     │
//   │ (Cold)   │    │ (Cold)   │    │ (Warm/binned)│
//   └──────────┘    └──────────┘    └──────────────┘
//                                           │
//                                           ▼
//                                  ┌─────────────────┐
//                                  │ temp / setup    │
//                                  │ (one-time prep) │
//                                  └─────────────────┘
//                                           │
//                                           ▼
//                                  ┌─────────────────┐
//                                  │ eval (Hot)      │
//                                  │ stamp (Hot)     │
//                                  └─────────────────┘
//
// Tier responsibilities:
//   * `params.rs`   — flat `Bsim3ModelParams` mirror of the Berkeley
//                     `BSIM3model` parameter set + L/W binning prefixes.
//   * `model.rs`    — `Bsim3Model` cold tier, NMOS/PMOS polarity, mode flags.
//   * `instance.rs` — `Bsim3SizeParams` after L/W binning + temp pre-compute,
//                     resolved per device geometry.
//   * `state.rs`    — Hot SoA state for many BSIM3 instances (transient
//                     bias-history, op-point cache).
//   * `temp.rs`     — Berkeley `b3temp.c` port: temperature scaling and
//                     binned per-instance constants.
//   * `setup.rs`    — Berkeley `b3set.c` port: parameter checking and
//                     defaulting.
//   * `eval.rs`     — Berkeley `b3ld.c` DC current path, split into small
//                     branchless helper functions.
//   * `stamp.rs`    — Jacobian / RHS stamping into the MNA matrix.
//
// All hot-path functions are `#[inline]`, take primitive `f64` slices,
// avoid allocation, and never invoke trait objects.

#![allow(non_snake_case)]
#![allow(dead_code)]

pub mod params;
pub mod model;
pub mod instance;
pub mod state;
pub mod temp;
pub mod setup;
pub mod eval;
pub mod stamp;

pub use model::{Bsim3, Bsim3Model};
pub use params::{Bsim3ModelParams, Bsim3Type};
pub use instance::Bsim3SizeParams;
pub use state::Bsim3InstanceArray;
