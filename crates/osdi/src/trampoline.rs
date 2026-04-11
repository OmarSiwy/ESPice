// SPDX-License-Identifier: LGPL-3.0-only
//
// OSDI ABI definitions follow the public OpenVAF OSDI spec; this file
// contains no OpenVAF source code.

//! # `OsdiTrampoline` — bridge between BigOSpice stamping and OSDI buffers.
//!
//! The hot path looks like this:
//!
//! ```text
//!     BigOSpice solver state ───voltages───▶ trampoline ───▶ OSDI eval()
//!                                                         │
//!                                                         ▼
//!                                              load_residual_resist
//!                                              load_jacobian_resist
//!                                                         │
//!     BigOSpice CSC stamping ◀──conductances + currents──── trampoline
//! ```
//!
//! The trampoline owns:
//!
//! - [`SoaBuffers`]: contiguous `Vec<f64>` columns for terminal voltages,
//!   resistive residual, reactive residual, conductance Jacobian, and
//!   reactive Jacobian. SoA layout means each `eval` invocation does at
//!   most one heap touch (the `Vec` allocation is reused across calls).
//! - A reference to the live [`OsdiInstance`].
//!
//! The trampoline never allocates after the first NR iteration: buffer
//! sizes are determined by the descriptor's `num_terminals` /
//! `num_jacobian_entries` / `num_react_entries` and stay constant.

use std::ptr;

use crate::abi::{
    OsdiDescriptor, OsdiNodePair, OsdiSimInfo, OsdiSimParas,
};
use crate::instance::OsdiInstance;
use crate::{OsdiError, OsdiResult};

/// SoA buffer pack for one OSDI device instance.
///
/// All vectors are sized once at construction and re-used across
/// Newton-Raphson iterations. No allocations on the hot path.
#[derive(Debug, Clone)]
pub struct SoaBuffers {
    /// Per-terminal voltages, written by the trampoline before `eval`.
    pub voltages: Vec<f64>,
    /// Per-row resistive residual `g(x)`, filled by `load_residual_resist`.
    pub residual_resist: Vec<f64>,
    /// Per-row reactive residual `q(x)`, filled by `load_residual_react`.
    pub residual_react: Vec<f64>,
    /// Conductance Jacobian entries (one per `OsdiNodePair`).
    pub jacobian_resist: Vec<f64>,
    /// Reactive Jacobian entries.
    pub jacobian_react: Vec<f64>,
}

impl SoaBuffers {
    /// Allocate buffers sized for the given descriptor.
    pub fn for_descriptor(descriptor: &OsdiDescriptor) -> Self {
        let num_terminals = descriptor.num_terminals as usize;
        let num_nodes = num_terminals + descriptor.num_nodes as usize;
        let num_jac = descriptor.num_jacobian_entries as usize;
        let num_react = descriptor.num_react_entries as usize;
        Self {
            voltages: vec![0.0; num_terminals],
            residual_resist: vec![0.0; num_nodes],
            residual_react: vec![0.0; num_nodes],
            jacobian_resist: vec![0.0; num_jac],
            jacobian_react: vec![0.0; num_react],
        }
    }

    /// Reset all buffers to zero (called between NR iterations if the
    /// caller does not want stale state to leak).
    pub fn clear(&mut self) {
        self.voltages.iter_mut().for_each(|v| *v = 0.0);
        self.residual_resist.iter_mut().for_each(|v| *v = 0.0);
        self.residual_react.iter_mut().for_each(|v| *v = 0.0);
        self.jacobian_resist.iter_mut().for_each(|v| *v = 0.0);
        self.jacobian_react.iter_mut().for_each(|v| *v = 0.0);
    }
}

/// Bridge object that owns the SoA buffers + borrows an `OsdiInstance`.
///
/// You typically construct one of these per OSDI device instance and call
/// [`OsdiTrampoline::evaluate`] on every NR iteration. The output buffers
/// are then read back by the BigOSpice stamper, which translates the
/// `OsdiNodePair` indices into MNA matrix coordinates and applies them to
/// the global CSC system.
#[derive(Debug)]
pub struct OsdiTrampoline {
    pub buffers: SoaBuffers,
}

impl OsdiTrampoline {
    /// Allocate the trampoline for the given descriptor.
    pub fn new(descriptor: &OsdiDescriptor) -> Self {
        Self {
            buffers: SoaBuffers::for_descriptor(descriptor),
        }
    }

    /// Pre-fill the SoA voltage column from a slice supplied by the
    /// BigOSpice stamper. Slice length must equal `num_terminals`.
    pub fn write_voltages(&mut self, voltages: &[f64], descriptor: &OsdiDescriptor) -> OsdiResult<()> {
        let expected = descriptor.num_terminals as usize;
        if voltages.len() != expected {
            return Err(OsdiError::VoltageLenMismatch {
                name: descriptor_name_lossy(descriptor),
                expected,
                actual: voltages.len(),
            });
        }
        self.buffers
            .voltages
            .iter_mut()
            .zip(voltages.iter())
            .for_each(|(dst, src)| *dst = *src);
        Ok(())
    }

    /// Run one full evaluation: `eval` → `load_residual_*` → `load_jacobian_*`.
    ///
    /// `time` is forwarded into `OsdiSimInfo.abstime` for transient
    /// analyses. Pass `0.0` for DC.
    pub fn evaluate(
        &mut self,
        instance: &mut OsdiInstance,
        time: f64,
        alpha: f64,
    ) -> OsdiResult<()> {
        let descriptor_ptr = instance.descriptor() as *const OsdiDescriptor;
        // SAFETY: `descriptor_ptr` is valid for the lifetime of `instance`
        // (the instance keeps an Arc<Library> alive). We re-borrow it
        // immediately and never store it.
        let descriptor = unsafe { &*descriptor_ptr };

        let mut sim_info = OsdiSimInfo {
            paras: OsdiSimParas {
                names: ptr::null_mut(),
                vals: self.buffers.voltages.as_mut_ptr(),
                names_str: ptr::null_mut(),
                vals_str: ptr::null_mut(),
            },
            abstime: time,
            prev_solve: self.buffers.voltages.as_mut_ptr(),
            prev_state: ptr::null_mut(),
            next_state: ptr::null_mut(),
            flags: 0,
        };

        let handle = instance.handle_ptr();

        // ── eval ────────────────────────────────────────────────────
        if let Some(eval_fn) = descriptor.eval {
            // SAFETY: `eval_fn` is the descriptor's documented eval entry
            // point. `handle` is a live heap allocation owned by the
            // instance, and `sim_info` lives for the duration of the call.
            let _flags = unsafe { eval_fn(handle, &mut sim_info) };
        }

        // ── residuals ───────────────────────────────────────────────
        if let Some(load_resid) = descriptor.load_residual_resist {
            let dst = self.buffers.residual_resist.as_mut_ptr();
            // SAFETY: `dst` points into a `Vec<f64>` of the correct length
            // (sized at construction from `num_terminals + num_nodes`).
            unsafe { load_resid(handle, dst) };
        }
        if let Some(load_react) = descriptor.load_residual_react {
            let dst = self.buffers.residual_react.as_mut_ptr();
            // SAFETY: same as above; `residual_react` was sized to match.
            unsafe { load_react(handle, dst) };
        }

        // ── Jacobians ───────────────────────────────────────────────
        if let Some(load_jac) = descriptor.load_jacobian_resist {
            let dst = self.buffers.jacobian_resist.as_mut_ptr();
            // SAFETY: `jacobian_resist` was sized from `num_jacobian_entries`.
            unsafe { load_jac(handle, dst) };
        }
        if let Some(load_jac_react) = descriptor.load_jacobian_react {
            let dst = self.buffers.jacobian_react.as_mut_ptr();
            // SAFETY: `jacobian_react` was sized from `num_react_entries`.
            unsafe { load_jac_react(handle, dst, alpha) };
        }
        if let Some(load_contrib) = descriptor.load_jacobian_contrib {
            // Optional contributions Jacobian — written into the same
            // buffer as the resistive Jacobian per the OSDI spec.
            let dst = self.buffers.jacobian_resist.as_mut_ptr();
            // SAFETY: `dst` is the same buffer used above; valid alignment.
            unsafe { load_contrib(handle, dst) };
        }

        Ok(())
    }

    /// Borrow the resistive Jacobian buffer + the descriptor's node-pair
    /// table. BigOSpice's stamper iterates the two in parallel, mapping each
    /// `OsdiNodePair` into a CSC entry and adding the corresponding
    /// conductance.
    pub fn jacobian_iter<'a>(
        &'a self,
        descriptor: &'a OsdiDescriptor,
    ) -> impl Iterator<Item = (OsdiNodePair, f64)> + 'a {
        let pairs = jacobian_pairs(descriptor);
        pairs
            .iter()
            .copied()
            .zip(self.buffers.jacobian_resist.iter().copied())
    }

    /// Borrow the residual buffer alongside the descriptor's node table.
    pub fn residual_iter<'a>(
        &'a self,
    ) -> impl Iterator<Item = (usize, f64)> + 'a {
        self.buffers
            .residual_resist
            .iter()
            .copied()
            .enumerate()
    }
}

/// Borrow the Jacobian node-pair slice from a descriptor.
fn jacobian_pairs(descriptor: &OsdiDescriptor) -> &[OsdiNodePair] {
    if descriptor.num_jacobian_entries == 0 || descriptor.jacobian_entries.is_null() {
        return &[];
    }
    // SAFETY: documented contiguous array of `num_jacobian_entries`
    // entries, owned by the plugin's RDATA.
    unsafe {
        core::slice::from_raw_parts(
            descriptor.jacobian_entries,
            descriptor.num_jacobian_entries as usize,
        )
    }
}

fn descriptor_name_lossy(descriptor: &OsdiDescriptor) -> String {
    if descriptor.name.is_null() {
        return String::from("<unnamed>");
    }
    // SAFETY: descriptor.name is a NUL-terminated UTF-8 string owned by
    // the plugin's RDATA.
    unsafe { core::ffi::CStr::from_ptr(descriptor.name) }
        .to_string_lossy()
        .into_owned()
}

/// Helper exposed for tests: cast a raw `*mut c_void` back to `&mut [u8]`
/// of a known length.
#[cfg(test)]
#[allow(dead_code)]
pub(crate) unsafe fn handle_as_bytes(handle: *mut core::ffi::c_void, len: usize) -> &'static mut [u8] {
    // SAFETY: caller asserts that `handle` points to `len` valid bytes
    // and that no other reference exists for the duration of the call.
    unsafe { core::slice::from_raw_parts_mut(handle as *mut u8, len) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_descriptor() -> OsdiDescriptor {
        OsdiDescriptor {
            name: ptr::null(),
            num_terminals: 4,
            num_nodes: 0,
            nodes: ptr::null(),
            num_collapsible: 0,
            collapsible: ptr::null(),
            num_jacobian_entries: 0,
            jacobian_entries: ptr::null(),
            num_react_entries: 0,
            react_entries: ptr::null(),
            instance_size: 64,
            model_size: 0,
            num_params: 0,
            params: ptr::null(),
            num_opvars: 0,
            opvars: ptr::null(),
            setup_model: None,
            setup_instance: None,
            init_instance: None,
            eval: None,
            load_residual_resist: None,
            load_residual_react: None,
            load_jacobian_resist: None,
            load_jacobian_react: None,
            load_jacobian_contrib: None,
            load_noise: None,
            access: None,
        }
    }

    #[test]
    fn soa_buffers_sized_from_descriptor() {
        let desc = empty_descriptor();
        let buf = SoaBuffers::for_descriptor(&desc);
        assert_eq!(buf.voltages.len(), 4);
        assert_eq!(buf.residual_resist.len(), 4);
        assert_eq!(buf.jacobian_resist.len(), 0);
    }

    #[test]
    fn write_voltages_validates_length() {
        let desc = empty_descriptor();
        let mut t = OsdiTrampoline::new(&desc);
        assert!(t.write_voltages(&[1.0, 2.0, 3.0, 4.0], &desc).is_ok());
        let err = t.write_voltages(&[1.0], &desc).unwrap_err();
        match err {
            OsdiError::VoltageLenMismatch {
                expected, actual, ..
            } => {
                assert_eq!(expected, 4);
                assert_eq!(actual, 1);
            }
            other => panic!("expected VoltageLenMismatch, got {other:?}"),
        }
    }

    #[test]
    fn clear_zeroes_all_buffers() {
        let desc = empty_descriptor();
        let mut buf = SoaBuffers::for_descriptor(&desc);
        buf.voltages[0] = 7.0;
        buf.residual_resist[0] = 3.0;
        buf.clear();
        assert!(buf.voltages.iter().all(|v| *v == 0.0));
        assert!(buf.residual_resist.iter().all(|v| *v == 0.0));
    }
}
