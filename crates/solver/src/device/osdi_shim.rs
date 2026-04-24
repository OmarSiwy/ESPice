// SPDX-License-Identifier: LGPL-3.0-only
//
// OSDI ABI definitions follow the public OpenVAF OSDI spec; this file
// contains no OpenVAF source code.
//
//! # OSDI dispatch shim
//!
//! This module exists purely to keep the `DeviceDispatch` enum in
//! [`crate::dispatch`] able to reference an externally-loaded OSDI
//! plugin without taking a dependency on `incspice-osdi` (which would
//! create a crate-graph cycle).
//!
//! The trick: we expose an opaque [`OsdiHandle`] — a tiny `Copy` POD
//! struct holding nothing but indices and cached scalars. The actual
//! OSDI registry, plugin, and trampoline live in `incspice-osdi` and are
//! borrowed by the simulator alongside the dispatch enum at stamping
//! time.
//!
//! The handle records:
//!
//! - `instance_idx`: stable u32 index into the `Vec<OsdiInstance>`
//!   owned by the `OsdiRegistry`.
//! - `num_terminals`: cached u8 so the dispatch enum can answer
//!   `num_terminals()` and `needs_branch()` without chasing the plugin.
//! - `flags`: bit-encoded metadata (currently just `needs_branch`).

use incspice_core::{DeviceKind, ParamMap};

use crate::device::eval::{DeviceEval, DeviceModel};

/// Bit flag: device requires a branch current row in the MNA matrix.
pub const OSDI_FLAG_NEEDS_BRANCH: u8 = 1 << 0;

/// Opaque handle to an externally-loaded OSDI device instance.
///
/// `OsdiHandle` is intentionally a plain old data type with no pointers,
/// no `Drop`, no `Send`/`Sync` concerns — just three small integers. This
/// keeps the [`crate::dispatch::DeviceDispatch`] enum trivially `Copy`
/// even when one of its variants references an OSDI device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(C)]
pub struct OsdiHandle {
    /// Index into the `Vec<OsdiInstance>` arena owned by the registry.
    pub instance_idx: u32,
    /// Number of external terminals (cached for hot-path dispatch).
    pub num_terminals: u8,
    /// Bit-encoded metadata (see `OSDI_FLAG_*` constants).
    pub flags: u8,
    /// Reserved for future use.
    _reserved: u16,
}

impl OsdiHandle {
    /// Create a new handle for a given instance index.
    #[inline]
    pub const fn new(instance_idx: u32, num_terminals: u8, needs_branch: bool) -> Self {
        let flags = if needs_branch {
            OSDI_FLAG_NEEDS_BRANCH
        } else {
            0
        };
        Self {
            instance_idx,
            num_terminals,
            flags,
            _reserved: 0,
        }
    }

    /// Whether this handle requires a branch current row.
    #[inline]
    pub const fn needs_branch(self) -> bool {
        (self.flags & OSDI_FLAG_NEEDS_BRANCH) != 0
    }
}

/// `DeviceModel` implementation for OSDI handles.
///
/// The implementation deliberately returns *empty* `DeviceEval` values:
/// the real evaluation must be performed by the `incspice-osdi` trampoline,
/// which the stamper invokes directly with a borrow of the OSDI registry.
/// This trait impl exists only so the `DeviceDispatch::Osdi` variant can
/// satisfy the `eval`/`num_terminals`/`needs_branch`/`kind` methods of
/// the dispatch enum without panicking.
impl DeviceModel for OsdiHandle {
    fn eval(&self, _voltages: &[f64], _params: &ParamMap) -> DeviceEval {
        // Sentinel — the real eval comes from `incspice-osdi::OsdiRegistry::evaluate`.
        DeviceEval::new()
    }

    fn num_terminals(&self) -> usize {
        self.num_terminals as usize
    }

    fn needs_branch(&self) -> bool {
        Self::needs_branch(*self)
    }

    fn kind(&self) -> DeviceKind {
        // Reuse VbicNpn as a sentinel — see crate::osdi_shim::OSDI_KIND_SENTINEL
        OSDI_KIND_SENTINEL
    }
}

/// Sentinel `DeviceKind` value the dispatch layer uses to recognise an
/// OSDI handle. We re-use `VbicNpn` rather than extending the closed
/// `DeviceKind` enum (which is in `incspice-core` and would touch every
/// existing match) — the dispatch enum's `Osdi` variant is the
/// authoritative source of truth, and consumers should match on it
/// directly rather than relying on the `DeviceKind` discriminant.
pub const OSDI_KIND_SENTINEL: DeviceKind = DeviceKind::VbicNpn;

// ---------------------------------------------------------------------------
// OSDI evaluation hook — breaks the dependency cycle
// ---------------------------------------------------------------------------

/// Callback interface for evaluating OSDI-loaded device instances from
/// analysis engines (e.g. Harmonic Balance) that cannot depend on
/// `incspice-osdi` directly (which would create a crate-graph cycle since
/// `incspice-osdi` depends on `incspice-device`).
///
/// Callers that have an `OsdiRegistry` implement this trait, then pass
/// `Some(&mut hook)` to functions like `run_hb_n_tone`.  When no OSDI
/// plugins are loaded, `None` is passed and OSDI devices are silently
/// skipped (they contribute zero nonlinear current — safe for circuits
/// without OSDI components).
///
/// # Contract
///
/// `eval_instance` is called once per OSDI device instance per time
/// point. The implementation must:
///
/// 1. Write `voltages` into the OSDI trampoline.
/// 2. Call the plugin's `eval`, `load_residual_resist`, and
///    `load_jacobian_resist` entry points.
/// 3. Fill `out_currents` (indexed by MNA node, excluding ground) with
///    the resistive branch currents sourced by the device.
/// 4. Fill `out_conductances` (same indexing) with the diagonal of the
///    small-signal conductance matrix (used for the averaged-Jacobian
///    approximation in HB).
///
/// Both output slices have length `num_mna_nodes` (the MNA dimension,
/// ground excluded).  The implementation adds to the existing values
/// rather than overwriting them, so the HB loop can accumulate across
/// multiple OSDI devices without clearing the buffers.
pub trait OsdiEvalHook: Send + Sync {
    /// Evaluate one OSDI device instance at the supplied terminal
    /// voltages and accumulate its contributions into `out_currents`
    /// and `out_conductances`.
    ///
    /// - `instance_idx`: the `OsdiHandle::instance_idx` field.
    /// - `voltages`: slice of length `num_terminals` in device-pin order.
    /// - `time`: simulation time (seconds); pass `0.0` for DC/HB.
    /// - `out_currents`: length-`num_mna_nodes` accumulator for `g(x)`.
    /// - `out_conductances`: length-`num_mna_nodes` accumulator for `diag(G)`.
    /// - `terminal_nodes`: maps each device pin index to its MNA node
    ///   index (0-based, ground = `usize::MAX`).
    #[allow(clippy::too_many_arguments)]
    fn eval_instance(
        &mut self,
        instance_idx: u32,
        voltages: &[f64],
        time: f64,
        out_currents: &mut [f64],
        out_conductances: &mut [f64],
        terminal_nodes: &[usize],
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handle_size_is_compact() {
        // 4 (idx) + 1 (terminals) + 1 (flags) + 2 (reserved) = 8 bytes,
        // matching one machine word on x86_64.
        assert!(core::mem::size_of::<OsdiHandle>() <= 8);
    }

    #[test]
    fn handle_needs_branch_round_trip() {
        let h = OsdiHandle::new(7, 4, true);
        assert_eq!(h.instance_idx, 7);
        assert_eq!(h.num_terminals, 4);
        assert!(h.needs_branch());
        let h2 = OsdiHandle::new(0, 2, false);
        assert!(!h2.needs_branch());
    }

    #[test]
    fn device_model_impl_returns_empty_eval() {
        let h = OsdiHandle::new(0, 4, false);
        let eval = h.eval(&[0.0; 4], &ParamMap::new());
        assert!(eval.g.is_empty());
        assert!(eval.G.is_empty());
        assert_eq!(h.num_terminals(), 4);
        assert!(!h.needs_branch());
    }
}
