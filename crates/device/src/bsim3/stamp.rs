// BSIM3 — ported from Berkeley BSIM3v3.3 (ECL-2.0)
//
// MNA stamping. The current `Bsim3` device emits its full G/g vectors
// through the standard `DeviceModel::eval` interface, which the
// existing `crate::stamper` already maps onto the sparse matrix.  This
// file is reserved for the eventual hot-loop SoA stamper that will
// fuse multiple BSIM3 devices in one Jacobian update pass.

#![allow(non_snake_case, dead_code)]
