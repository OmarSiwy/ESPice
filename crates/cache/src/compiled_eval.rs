//! Phase 5.3 — Compiled-eval closure cache (the project's KEY differentiator).
//!
//! ## Why this exists
//!
//! Every nonlinear device evaluation in SPICE — every BSIM4 call, every diode
//! exponential, every MOSFET region computation — produces, at the end, an
//! affine local model:
//!
//! ```text
//!     I(V)  ≈  I0 + G · (V - V0)
//! ```
//!
//! That is what the Newton iteration actually consumes.  The full BSIM4 eval
//! is essentially a giant function that computes `(I0, G)` from `V` and the
//! model card.
//!
//! Once we have `(I0, G, V0)` for the current operating point, we can:
//!
//! 1. Re-use it across NR iterations near the same point (warm start).
//! 2. Re-use it across `.STEP` parameter sweeps where the changing parameter
//!    is a simple *scaling* parameter (W, L, M, temperature) by patching the
//!    cached `I0`/`G` analytically.
//! 3. Detect when the operating point has moved too far and fall back to a
//!    full eval.
//!
//! ## Storage layout (DOD)
//!
//! For `n` devices and `m` rows in each device's local Jacobian, we store:
//!
//! - `i0:  Vec<f64>` — flat `n*m` matrix of cached `I0` row vectors.
//! - `g:   Vec<f64>` — flat `n*m*m` matrix of cached `G` Jacobian blocks.
//! - `v0:  Vec<f64>` — flat `n*m` matrix of cached `V0` linearisation points.
//! - `valid: BitVec` — one bit per device, fast popcount of cached entries.
//! - `tolerance: f64` — `|V - V0|` infinity-norm beyond which we invalidate.
//!
//! All indexing is via `DeviceIdx(u32)` for type safety.
//!
//! Currently we use a fixed `MAX_ROWS = 4` so the storage stays a flat
//! `Vec<f64>` with predictable strides.  Devices with more terminals (e.g.
//! BSIM4 with bulk + drain + gate + source) fit; in the future we can lift
//! this to a per-device-kind block layout.

use incspice_core::DeviceId;
use bitvec::prelude::*;

/// Hard upper bound on rows of the cached affine model per device.
/// Most analog devices use 2–4 terminals, so 4 is plenty.
pub const MAX_ROWS: usize = 4;

/// Newtype for typed indexing into the compiled-eval cache.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DeviceIdx(pub u32);

impl DeviceIdx {
    #[inline]
    pub fn from_id(id: DeviceId) -> Self {
        Self(id.0)
    }

    #[inline]
    pub fn index(self) -> usize {
        self.0 as usize
    }
}

/// Reasons a cache entry can be invalidated, for telemetry / debug.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InvalidationReason {
    /// Device entry is fresh (never populated).
    NeverComputed,
    /// `|V - V0| > tolerance` — operating point moved too far.
    MovedTooFar,
    /// Parameter changed in a way that can't be analytically patched.
    NonLinearParamChange,
    /// Topology changed underneath us.
    TopologyChange,
}

/// SoA storage for the affine models of every device in the circuit.
#[derive(Debug, Clone)]
pub struct CompiledEvalCache {
    /// Number of devices the cache is sized for.
    num_devices: usize,
    /// Per-device row count actually used (≤ `MAX_ROWS`).
    row_counts: Vec<u8>,
    /// Flat `n * MAX_ROWS` cached current vectors.
    i0: Vec<f64>,
    /// Flat `n * MAX_ROWS * MAX_ROWS` cached conductance blocks (row-major).
    g: Vec<f64>,
    /// Flat `n * MAX_ROWS` cached linearisation voltage vectors.
    v0: Vec<f64>,
    /// One bit per device — `true` ⇔ entry holds a usable affine model.
    valid: BitVec,
    /// Move-too-far tolerance (V).  `|V - V0| > tolerance` ⇒ invalidate.
    pub tolerance: f64,
    /// Hit / miss telemetry.
    pub hits: u64,
    pub misses: u64,
    pub patches: u64,
}

impl CompiledEvalCache {
    pub fn new(num_devices: usize) -> Self {
        Self {
            num_devices,
            row_counts: vec![0; num_devices],
            i0: vec![0.0; num_devices * MAX_ROWS],
            g: vec![0.0; num_devices * MAX_ROWS * MAX_ROWS],
            v0: vec![0.0; num_devices * MAX_ROWS],
            valid: bitvec![0; num_devices],
            tolerance: 1e-3,
            hits: 0,
            misses: 0,
            patches: 0,
        }
    }

    pub fn num_devices(&self) -> usize {
        self.num_devices
    }

    pub fn is_valid(&self, idx: DeviceIdx) -> bool {
        let i = idx.index();
        i < self.valid.len() && self.valid[i]
    }

    /// Resize the cache for a new device count, dropping all entries.
    pub fn resize(&mut self, num_devices: usize) {
        self.num_devices = num_devices;
        self.row_counts.clear();
        self.row_counts.resize(num_devices, 0);
        self.i0.clear();
        self.i0.resize(num_devices * MAX_ROWS, 0.0);
        self.g.clear();
        self.g.resize(num_devices * MAX_ROWS * MAX_ROWS, 0.0);
        self.v0.clear();
        self.v0.resize(num_devices * MAX_ROWS, 0.0);
        self.valid.clear();
        self.valid.resize(num_devices, false);
        self.hits = 0;
        self.misses = 0;
        self.patches = 0;
    }

    /// Store an affine model `(I0, G, V0)` for `idx`.  `rows` is the number
    /// of MNA rows the device contributes (must be ≤ `MAX_ROWS`).
    pub fn store(&mut self, idx: DeviceIdx, rows: usize, i0: &[f64], g: &[f64], v0: &[f64]) {
        let i = idx.index();
        if i >= self.num_devices || rows > MAX_ROWS {
            return;
        }
        debug_assert_eq!(i0.len(), rows);
        debug_assert_eq!(v0.len(), rows);
        debug_assert_eq!(g.len(), rows * rows);

        self.row_counts[i] = rows as u8;

        let i0_off = i * MAX_ROWS;
        self.i0[i0_off..i0_off + rows].copy_from_slice(i0);

        let v0_off = i * MAX_ROWS;
        self.v0[v0_off..v0_off + rows].copy_from_slice(v0);

        let g_stride = MAX_ROWS * MAX_ROWS;
        let g_off = i * g_stride;
        // Copy a `rows×rows` block into the upper-left of a `MAX_ROWS×MAX_ROWS`
        // tile.  This keeps the strides constant and predictable for SIMD.
        for r in 0..rows {
            for c in 0..rows {
                self.g[g_off + r * MAX_ROWS + c] = g[r * rows + c];
            }
        }
        self.valid.set(i, true);
    }

    /// Read the cached `I0` row for `idx` (length = `rows()`).
    pub fn i0(&self, idx: DeviceIdx) -> &[f64] {
        let i = idx.index();
        let off = i * MAX_ROWS;
        let rows = self.row_counts[i] as usize;
        &self.i0[off..off + rows]
    }

    /// Read the cached `V0` row for `idx`.
    pub fn v0(&self, idx: DeviceIdx) -> &[f64] {
        let i = idx.index();
        let off = i * MAX_ROWS;
        let rows = self.row_counts[i] as usize;
        &self.v0[off..off + rows]
    }

    /// Read the cached `G` block for `idx` (returned with the constant
    /// `MAX_ROWS` stride; the device's actual row count is `rows()`).
    pub fn g_tile(&self, idx: DeviceIdx) -> &[f64] {
        let i = idx.index();
        let g_stride = MAX_ROWS * MAX_ROWS;
        let off = i * g_stride;
        &self.g[off..off + g_stride]
    }

    /// Active row count for the cached entry of `idx`.
    pub fn rows(&self, idx: DeviceIdx) -> usize {
        let i = idx.index();
        self.row_counts.get(i).copied().unwrap_or(0) as usize
    }

    /// Replay the affine model at a new operating point `v`:
    ///
    /// ```text
    ///     I(v) = I0 + G · (v - V0)
    /// ```
    ///
    /// Returns `Some(())` on a hit, `None` on a miss.  A miss can mean either
    /// the entry was never computed *or* `|v - V0| > tolerance`.
    pub fn replay(&mut self, idx: DeviceIdx, v: &[f64], out_i: &mut [f64]) -> Option<()> {
        let i = idx.index();
        if i >= self.num_devices || !self.valid[i] {
            self.misses += 1;
            return None;
        }
        let rows = self.row_counts[i] as usize;
        if v.len() != rows || out_i.len() != rows {
            self.misses += 1;
            return None;
        }

        // Move-too-far check (infinity-norm).
        let v0_off = i * MAX_ROWS;
        let mut max_dv = 0.0_f64;
        for r in 0..rows {
            let dv = (v[r] - self.v0[v0_off + r]).abs();
            if dv > max_dv {
                max_dv = dv;
            }
        }
        if max_dv > self.tolerance {
            self.valid.set(i, false);
            self.misses += 1;
            return None;
        }

        // I = I0 + G · (v - V0)
        let i0_off = i * MAX_ROWS;
        let g_off = i * MAX_ROWS * MAX_ROWS;
        for r in 0..rows {
            let mut acc = self.i0[i0_off + r];
            for c in 0..rows {
                acc += self.g[g_off + r * MAX_ROWS + c] * (v[c] - self.v0[v0_off + c]);
            }
            out_i[r] = acc;
        }
        self.hits += 1;
        Some(())
    }

    /// Patch a cached entry analytically when a *scaling* parameter changes.
    ///
    /// For BSIM-style "scaling" parameters (`W`, `L`, `M`, area), the device
    /// current is linear in the scale factor, so we can multiply the cached
    /// `I0` and `G` by `new / old` instead of running a full BSIM eval.
    /// Tolerance and `V0` are unchanged.
    pub fn patch_scale(&mut self, idx: DeviceIdx, scale: f64) -> bool {
        debug_assert!(scale > 0.0, "patch_scale: factor must be positive, got {}", scale);
        let i = idx.index();
        if i >= self.num_devices || !self.valid[i] {
            return false;
        }
        let rows = self.row_counts[i] as usize;
        let i0_off = i * MAX_ROWS;
        for r in 0..rows {
            self.i0[i0_off + r] *= scale;
        }
        let g_off = i * MAX_ROWS * MAX_ROWS;
        for r in 0..rows {
            for c in 0..rows {
                self.g[g_off + r * MAX_ROWS + c] *= scale;
            }
        }
        self.patches += 1;
        true
    }

    /// Patch a temperature change.  This shifts `I0` by an Arrhenius factor
    /// while leaving `G` mostly intact (to first order).  Conservative — the
    /// caller can always invalidate instead.
    pub fn patch_temperature(&mut self, idx: DeviceIdx, ratio: f64) -> bool {
        if !ratio.is_finite() || ratio <= 0.0 {
            return false;
        }
        self.patch_scale(idx, ratio)
    }

    /// Invalidate a single device entry.
    pub fn invalidate(&mut self, idx: DeviceIdx, _reason: InvalidationReason) {
        let i = idx.index();
        if i < self.valid.len() {
            self.valid.set(i, false);
        }
    }

    /// Invalidate every entry (e.g. on topology change).
    pub fn invalidate_all(&mut self) {
        self.valid.fill(false);
    }

    /// Number of devices currently holding a valid cached entry.
    pub fn valid_count(&self) -> usize {
        self.valid.count_ones()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_and_replay_resistor() {
        // 1 kΩ resistor between two nodes:
        //   I = V/R, so I0=0, G=[[1/R, -1/R],[-1/R, 1/R]], V0=[0,0]
        let r = 1000.0;
        let g_val = 1.0 / r;
        let mut cache = CompiledEvalCache::new(1);
        cache.tolerance = 10.0; // resistor is linear; arbitrary excursions ok
        let idx = DeviceIdx(0);
        let g_block = [g_val, -g_val, -g_val, g_val];
        cache.store(idx, 2, &[0.0, 0.0], &g_block, &[0.0, 0.0]);

        // Replay at V = (1.0, 0.5):
        //   I[0] =  0.001 - 0.0005 =  0.0005
        //   I[1] = -0.001 + 0.0005 = -0.0005
        let mut out = [0.0, 0.0];
        cache.replay(idx, &[1.0, 0.5], &mut out).unwrap();
        assert!((out[0] - 0.0005).abs() < 1e-12);
        assert!((out[1] - (-0.0005)).abs() < 1e-12);
        assert_eq!(cache.hits, 1);
    }

    #[test]
    fn move_too_far_invalidates() {
        let mut cache = CompiledEvalCache::new(1);
        cache.tolerance = 0.1;
        let idx = DeviceIdx(0);
        let g_block = [1.0, 0.0, 0.0, 1.0];
        cache.store(idx, 2, &[0.0, 0.0], &g_block, &[0.0, 0.0]);

        // Within tolerance.
        let mut out = [0.0, 0.0];
        cache.replay(idx, &[0.05, 0.05], &mut out).unwrap();

        // Out of tolerance — should invalidate.
        assert!(cache.replay(idx, &[5.0, 5.0], &mut out).is_none());
        assert!(!cache.is_valid(idx));
    }

    #[test]
    fn scale_patch() {
        let mut cache = CompiledEvalCache::new(1);
        let idx = DeviceIdx(0);
        cache.store(idx, 2, &[1.0, -1.0], &[1.0, 0.0, 0.0, 1.0], &[0.0, 0.0]);
        assert!(cache.patch_scale(idx, 2.0));
        let mut out = [0.0, 0.0];
        cache.replay(idx, &[0.0, 0.0], &mut out).unwrap();
        assert!((out[0] - 2.0).abs() < 1e-12);
        assert!((out[1] - (-2.0)).abs() < 1e-12);
    }
}
