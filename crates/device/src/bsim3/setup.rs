// BSIM3 — ported from Berkeley BSIM3v3.3 (ECL-2.0)
//
// One-time parameter checking and defaulting. The bulk of `b3set.c`
// validates that user-supplied parameters lie within physical ranges
// and emits warnings; in PiSIM these checks are performed lazily on the
// first eval call (or skipped, depending on the `paramChk` flag).
//
// Reference (READ-ONLY):
//   tests/external/ngspice/src/spicelib/devices/bsim3/b3set.c

#![allow(non_snake_case, dead_code)]
