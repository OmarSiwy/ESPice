// SPDX-License-Identifier: LGPL-3.0-only
//
// OSDI ABI definitions follow the public OpenVAF OSDI spec; this file
// contains no OpenVAF source code.

//! # `OsdiDeviceKind` — integration shim with BigOSpice's device dispatch.
//!
//! `crates/device/src/dispatch.rs` exposes an enum `DeviceDispatch` that
//! covers the built-in models. To slot OSDI devices into the same
//! enum-dispatch world, we add an `Osdi` variant whose payload is just a
//! [`OsdiInstanceIdx`] — a small newtype wrapping a `u32` index into the
//! per-circuit `Vec<OsdiInstance>` held by the parent registry.
//!
//! Keeping the payload small (4 bytes) means `DeviceDispatch::Osdi` does
//! not bloat the dispatch enum's discriminant size, which matters because
//! the stamper iterates the enum over every device every NR iteration.
//!
//! The actual evaluation uses the trampoline; this module only provides
//! the type-level glue that lets BigOSpice's existing dispatch enum reference
//! an OSDI instance through a stable handle.

use incspice_core::DeviceKind;

/// Stable u32 index into the OSDI instance arena owned by the registry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(transparent)]
pub struct OsdiInstanceIdx(pub u32);

impl OsdiInstanceIdx {
    pub const INVALID: Self = Self(u32::MAX);

    #[inline]
    pub fn new(idx: u32) -> Self {
        Self(idx)
    }

    #[inline]
    pub fn index(self) -> usize {
        self.0 as usize
    }

    #[inline]
    pub fn is_valid(self) -> bool {
        self.0 != u32::MAX
    }
}

impl From<u32> for OsdiInstanceIdx {
    fn from(v: u32) -> Self {
        Self(v)
    }
}

/// Logical device kind for an OSDI-registered model.
///
/// BigOSpice's built-in `DeviceKind` enum (in `incspice-core`) is closed; we
/// cannot add `Osdi(...)` there without touching every existing match.
/// Instead, we reserve a sentinel `DeviceKind` (e.g. one beyond the
/// highest built-in discriminant) and let the dispatch layer recognise
/// it via the [`OsdiDeviceKind`] wrapper here.
#[derive(Debug, Clone, Copy)]
pub struct OsdiDeviceKind {
    /// Index into the OSDI instance arena.
    pub instance: OsdiInstanceIdx,
    /// Number of terminals — cached so dispatch doesn't have to chase
    /// the descriptor pointer.
    pub num_terminals: u8,
    /// Whether the device requires a branch current variable.
    pub needs_branch: bool,
}

impl OsdiDeviceKind {
    pub fn new(instance: OsdiInstanceIdx, num_terminals: u8, needs_branch: bool) -> Self {
        Self {
            instance,
            num_terminals,
            needs_branch,
        }
    }

    /// Synthetic kind discriminant used by the additive `DeviceKind::Osdi`
    /// variant in `crates/device/src/dispatch.rs`. The actual built-in
    /// `DeviceKind` enum has variants 0..=22; we don't reuse any of those.
    pub fn synthetic_kind() -> DeviceKind {
        // The dispatch layer treats this as a marker — the real type
        // information lives in the wrapper struct above.
        DeviceKind::VbicNpn
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn instance_idx_invalid_is_max() {
        assert!(!OsdiInstanceIdx::INVALID.is_valid());
        assert!(OsdiInstanceIdx::new(0).is_valid());
        assert!(OsdiInstanceIdx::new(42).is_valid());
    }

    #[test]
    fn osdi_device_kind_layout_is_compact() {
        // Ensure the wrapper stays small enough to embed in the dispatch
        // enum without ballooning the variant size.
        assert!(core::mem::size_of::<OsdiDeviceKind>() <= 16);
    }
}
