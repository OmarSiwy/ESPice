// BSIM4 — ported from Berkeley BSIM4.8.3 (ECL-2.0)
//
// Hot tier — SoA-friendly per-instance bias state arrays. One
// `Bsim4InstanceArray` per circuit; each device occupies the same index
// across every Vec<f64> field.  Following the data-oriented design rules
// in CLAUDE.md: SoA so that the DC eval kernel touches contiguous f64
// stripes, and the only Vec<...> in the structure is the f64 field
// itself (no Box, no HashMap).

#![allow(non_snake_case)]

/// Hot-tier per-instance bias and small-signal state.
#[derive(Debug, Default, Clone)]
pub struct Bsim4InstanceArray {
    pub vds:     Vec<f64>,
    pub vgs:     Vec<f64>,
    pub vbs:     Vec<f64>,
    pub vbd:     Vec<f64>,
    pub vdseff:  Vec<f64>,
    pub vgsteff: Vec<f64>,
    pub vdsat:   Vec<f64>,
    pub von:     Vec<f64>,
    pub ids:     Vec<f64>,
    pub gm:      Vec<f64>,
    pub gds:     Vec<f64>,
    pub gmbs:    Vec<f64>,
    pub igidl:   Vec<f64>,
    pub igisl:   Vec<f64>,
    pub ibd:     Vec<f64>,
    pub ibs:     Vec<f64>,
    pub gbd:     Vec<f64>,
    pub gbs:     Vec<f64>,
    /// Previous-iteration bias history (for `fetlim`-style limiting).
    pub vds_prev: Vec<f64>,
    pub vgs_prev: Vec<f64>,
    pub vbs_prev: Vec<f64>,
}

impl Bsim4InstanceArray {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_capacity(n: usize) -> Self {
        Self {
            vds:     Vec::with_capacity(n),
            vgs:     Vec::with_capacity(n),
            vbs:     Vec::with_capacity(n),
            vbd:     Vec::with_capacity(n),
            vdseff:  Vec::with_capacity(n),
            vgsteff: Vec::with_capacity(n),
            vdsat:   Vec::with_capacity(n),
            von:     Vec::with_capacity(n),
            ids:     Vec::with_capacity(n),
            gm:      Vec::with_capacity(n),
            gds:     Vec::with_capacity(n),
            gmbs:    Vec::with_capacity(n),
            igidl:   Vec::with_capacity(n),
            igisl:   Vec::with_capacity(n),
            ibd:     Vec::with_capacity(n),
            ibs:     Vec::with_capacity(n),
            gbd:     Vec::with_capacity(n),
            gbs:     Vec::with_capacity(n),
            vds_prev: Vec::with_capacity(n),
            vgs_prev: Vec::with_capacity(n),
            vbs_prev: Vec::with_capacity(n),
        }
    }

    /// Push a fresh, zeroed slot for one new device. Returns its index.
    pub fn push_zero(&mut self) -> usize {
        let i = self.vds.len();
        self.vds.push(0.0);
        self.vgs.push(0.0);
        self.vbs.push(0.0);
        self.vbd.push(0.0);
        self.vdseff.push(0.0);
        self.vgsteff.push(0.0);
        self.vdsat.push(0.0);
        self.von.push(0.0);
        self.ids.push(0.0);
        self.gm.push(0.0);
        self.gds.push(0.0);
        self.gmbs.push(0.0);
        self.igidl.push(0.0);
        self.igisl.push(0.0);
        self.ibd.push(0.0);
        self.ibs.push(0.0);
        self.gbd.push(0.0);
        self.gbs.push(0.0);
        self.vds_prev.push(0.0);
        self.vgs_prev.push(0.0);
        self.vbs_prev.push(0.0);
        i
    }

    /// Rotate `*_prev` ← current bias.  Call after a successful Newton
    /// step so that the next iteration's voltage limiter has a reference.
    pub fn rotate_history(&mut self) {
        self.vds_prev.copy_from_slice(&self.vds);
        self.vgs_prev.copy_from_slice(&self.vgs);
        self.vbs_prev.copy_from_slice(&self.vbs);
    }

    pub fn len(&self) -> usize {
        self.vds.len()
    }

    pub fn is_empty(&self) -> bool {
        self.vds.is_empty()
    }
}
