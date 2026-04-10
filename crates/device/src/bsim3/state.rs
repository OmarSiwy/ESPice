// BSIM3 — ported from Berkeley BSIM3v3.3 (ECL-2.0)
//
// Hot-tier SoA state for many BSIM3 instances. This is the
// data-oriented home for the bias-history needed by the Newton voltage
// limiter and the transient charge integrators (qb, qg, qd, qcheq, qdef).
//
// In the current cut of the port, BSIM3 is invoked through the regular
// `DeviceModel::eval` path which performs no bias-history caching.
// This struct is the placeholder for the eventual SoA hot loop that
// processes a slice of BSIM3 instances per Newton iteration.

#![allow(non_snake_case, dead_code)]

/// Struct-of-arrays state for `N` BSIM3 instances.
///
/// Every field is a contiguous `Vec<f64>` so the SIMD-friendly
/// integration loops can process all devices in one pass.
#[derive(Debug, Default, Clone)]
pub struct Bsim3InstanceArray {
    pub vds:    Vec<f64>,
    pub vgs:    Vec<f64>,
    pub vbs:    Vec<f64>,
    pub ids:    Vec<f64>,
    pub gm:     Vec<f64>,
    pub gds:    Vec<f64>,
    pub gmbs:   Vec<f64>,
    pub vth:    Vec<f64>,
    pub vdsat:  Vec<f64>,
    pub von:    Vec<f64>,
    pub isub:   Vec<f64>,
    /// Length (number of populated entries).
    pub len:    usize,
}

impl Bsim3InstanceArray {
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            vds:   Vec::with_capacity(cap),
            vgs:   Vec::with_capacity(cap),
            vbs:   Vec::with_capacity(cap),
            ids:   Vec::with_capacity(cap),
            gm:    Vec::with_capacity(cap),
            gds:   Vec::with_capacity(cap),
            gmbs:  Vec::with_capacity(cap),
            vth:   Vec::with_capacity(cap),
            vdsat: Vec::with_capacity(cap),
            von:   Vec::with_capacity(cap),
            isub:  Vec::with_capacity(cap),
            len:   0,
        }
    }

    pub fn push_default(&mut self) {
        self.vds.push(0.0);
        self.vgs.push(0.0);
        self.vbs.push(0.0);
        self.ids.push(0.0);
        self.gm.push(0.0);
        self.gds.push(0.0);
        self.gmbs.push(0.0);
        self.vth.push(0.0);
        self.vdsat.push(0.0);
        self.von.push(0.0);
        self.isub.push(0.0);
        self.len += 1;
    }
}
