//! Statistical-function support for `.PARAM` expressions used by Monte Carlo
//! and worst-case analysis (Phase 3.6).
//!
//! This module is intentionally tiny and self-contained: it does *not* extend
//! the existing `BehavioralExpr`/`Expression` ASTs.  Instead it provides:
//!
//! 1. A small [`StatExpr`] enum that captures a parsed statistical primitive
//!    along with optional `LOT` / `DEV` matching tokens (HSPICE semantics).
//! 2. A pure [`StatExpr::sample`] entry point that takes the four random draws
//!    needed by the analysis driver and returns the realised value.
//! 3. A tiny inline xorshift PRNG (`StatRng`) used by both `mc.rs` and
//!    `wcase.rs`.  No external `rand` dependency is added — the workspace
//!    Cargo.toml does not currently pull in `rand` or `rand_xoshiro`, and
//!    Phase 3.6 explicitly says "use a tiny inline implementation" if not
//!    already present.
//!
//! # Statistical functions supported
//!
//! | Function                          | Meaning                                                            |
//! |-----------------------------------|--------------------------------------------------------------------|
//! | `AGAUSS(mean, sigma, nsig)`       | Absolute Gaussian: `mean + Z * sigma / nsig`                       |
//! | `GAUSS(mean, rel_var, nsig)`      | Relative Gaussian: `mean * (1 + Z * rel_var / nsig)`               |
//! | `UNIF(mean, rel_range)`           | Uniform: `mean * (1 + U * rel_range)` where `U ∈ [-1, 1]`          |
//! | `LIMIT(mean, abs_var)`            | Bounded uniform: `mean + sign * abs_var` where `sign ∈ {-1, +1}`   |
//!
//! `Z` is a standard-normal sample, `U` is a uniform `[-1, 1]` sample.  The
//! `nsig` argument is the number of standard deviations the user-supplied
//! `sigma` / `rel_var` represents (typical: 1, 3).  Worst-case analysis
//! reuses the same definitions but draws ±nsig corners deterministically.
//!
//! # LOT / DEV semantics
//!
//! In HSPICE compatibility mode, statistical parameters carry one of two
//! qualifiers:
//!
//! - `LOT` — every instance that references the same parent (`.MODEL`) sees
//!   the **same** random draw within a Monte Carlo sample.  Used to model
//!   wafer-level process variation.
//! - `DEV` — every instance gets an **independent** draw, modelling local
//!   mismatch between physically distinct devices.
//!
//! Plain (unqualified) statistical params behave like `DEV` by default.
//!
//! These qualifiers are stored in [`Matching`] and consumed by the MC driver
//! when it builds the per-sample seeded PRNG: `LOT` parameters are seeded
//! once per `(sample_idx, model_name)` pair, `DEV` parameters once per
//! `(sample_idx, instance_id)` pair.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Tiny inline PRNG (xorshift-style; quality is fine for MC/WCASE seeding).
// ---------------------------------------------------------------------------

/// A small deterministic 64-bit PRNG using the xorshift64-star algorithm.
///
/// Why not `rand_xoshiro`?  The PiSIM workspace deliberately does not depend
/// on the `rand` family today.  This implementation is ~20 lines of code,
/// passes the bare-minimum quality checks for Monte Carlo simulation
/// parameter draws, and produces fully reproducible streams from any seed.
///
/// The state is `Copy`, so callers can cheaply spawn per-stream PRNGs by
/// reseeding from a master `StatRng` — see [`StatRng::derive_stream`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StatRng {
    state: u64,
}

impl StatRng {
    /// Create a new PRNG from an explicit 64-bit seed.
    ///
    /// A zero seed is internally remapped to a non-zero constant; xorshift
    /// requires a non-zero state.
    pub fn new(seed: u64) -> Self {
        let state = if seed == 0 { 0x9E37_79B9_7F4A_7C15 } else { seed };
        Self { state }
    }

    /// Advance the state and return a uniform `u64`.
    #[inline]
    pub fn next_u64(&mut self) -> u64 {
        // xorshift64-star (Marsaglia, 2003)
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Uniform `f64` in `[0, 1)`.  Uses the upper 53 bits of `next_u64`.
    #[inline]
    pub fn next_unit(&mut self) -> f64 {
        // 53-bit precision: shift right by 11 and divide by 2^53.
        ((self.next_u64() >> 11) as f64) * (1.0 / ((1u64 << 53) as f64))
    }

    /// Uniform `f64` in `[-1, 1)`.
    #[inline]
    pub fn next_uniform_signed(&mut self) -> f64 {
        2.0 * self.next_unit() - 1.0
    }

    /// Standard-normal sample using the Box-Muller transform.
    ///
    /// Slightly wasteful (one of the two values per call is discarded) but
    /// stateless, simple, and entirely reproducible.
    #[inline]
    pub fn next_normal(&mut self) -> f64 {
        // Avoid log(0) by clamping the first uniform away from exactly zero.
        let mut u1 = self.next_unit();
        if u1 < 1e-300 {
            u1 = 1e-300;
        }
        let u2 = self.next_unit();
        let r = (-2.0 * u1.ln()).sqrt();
        let theta = 2.0 * std::f64::consts::PI * u2;
        r * theta.cos()
    }

    /// Derive a child PRNG seeded by mixing this stream's state with `tag`.
    ///
    /// Used by the MC driver to spawn `(sample, model)` and
    /// `(sample, instance)` sub-streams without exposing the master state.
    pub fn derive_stream(&self, tag: u64) -> Self {
        // SplitMix-style scrambling — well-distributed for small tag deltas.
        let mut z = self.state.wrapping_add(tag).wrapping_add(0x9E37_79B9_7F4A_7C15);
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        Self::new(z)
    }
}

// ---------------------------------------------------------------------------
// Matching qualifier (LOT vs DEV) and StatExpr
// ---------------------------------------------------------------------------

/// HSPICE-compatible matching qualifier on a statistical parameter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Matching {
    /// Independent draw per device instance (default for unqualified params).
    Dev,
    /// One shared draw per parent model (wafer/lot variation).
    Lot,
}

impl Default for Matching {
    fn default() -> Self {
        Matching::Dev
    }
}

/// Which statistical primitive this expression evaluates.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum StatKind {
    /// `AGAUSS(mean, sigma, nsig)`  — absolute Gaussian.
    AGauss,
    /// `GAUSS(mean, rel_var, nsig)` — relative Gaussian (sigma = mean * rel_var).
    Gauss,
    /// `UNIF(mean, rel_range)`      — uniform `mean * (1 ± rel_range)`.
    Unif,
    /// `LIMIT(mean, abs_var)`       — bounded uniform `mean ± abs_var`.
    Limit,
}

impl StatKind {
    /// Parse the function name (case-insensitive) into a `StatKind`.
    pub fn from_name(name: &str) -> Option<Self> {
        match name.to_ascii_lowercase().as_str() {
            "agauss" => Some(StatKind::AGauss),
            "gauss"  => Some(StatKind::Gauss),
            "unif"   => Some(StatKind::Unif),
            "limit"  => Some(StatKind::Limit),
            _        => None,
        }
    }

    /// Returns true if this primitive uses a Gaussian draw (otherwise uniform).
    pub fn is_gaussian(self) -> bool {
        matches!(self, StatKind::AGauss | StatKind::Gauss)
    }
}

/// A parsed statistical expression — the right-hand side of one
/// `.PARAM name = AGAUSS(...)` (or similar) line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StatExpr {
    pub kind: StatKind,
    /// Mean / nominal value.
    pub mean: f64,
    /// Variation: sigma (AGAUSS), relative-sigma (GAUSS), relative-range (UNIF),
    /// or absolute variation (LIMIT).  Always positive.
    pub variation: f64,
    /// Number of standard-deviations the supplied `variation` represents
    /// (Gaussian families only; uniform families ignore this).  Defaults to 1.
    pub nsig: f64,
    /// `LOT` or `DEV` matching qualifier.
    pub matching: Matching,
}

impl StatExpr {
    /// The nominal (un-perturbed) value — used for the first MC sample and
    /// for the centre point of a worst-case sweep.
    #[inline]
    pub fn nominal(&self) -> f64 {
        self.mean
    }

    /// Draw one realisation given pre-generated raw uniforms.
    ///
    /// `z` is a standard-normal sample (for Gaussian variants).
    /// `u` is a uniform `[-1, 1]` sample (for uniform variants).
    /// `bit` is a single random bit, used by `LIMIT` to pick `+abs_var` or
    /// `-abs_var`.
    ///
    /// Splitting the random inputs from the math keeps this routine pure and
    /// deterministic — the MC driver decides where the entropy comes from
    /// (per-instance or per-lot stream) and `sample` just consumes it.
    pub fn sample(&self, z: f64, u: f64, bit: bool) -> f64 {
        let n = if self.nsig <= 0.0 { 1.0 } else { self.nsig };
        match self.kind {
            StatKind::AGauss => self.mean + z * self.variation / n,
            StatKind::Gauss  => self.mean * (1.0 + z * self.variation / n),
            StatKind::Unif   => self.mean * (1.0 + u * self.variation),
            StatKind::Limit  => {
                let sign = if bit { 1.0 } else { -1.0 };
                self.mean + sign * self.variation
            }
        }
    }

    /// Worst-case extremum at `±k` standard deviations / range fractions.
    ///
    /// `direction` of `+1.0` produces the upper corner, `-1.0` the lower.
    /// `k` is typically the user-supplied `nsig` (or 1 for uniforms).
    pub fn corner(&self, direction: f64) -> f64 {
        let sign = if direction >= 0.0 { 1.0 } else { -1.0 };
        match self.kind {
            StatKind::AGauss => self.mean + sign * self.variation,
            StatKind::Gauss  => self.mean * (1.0 + sign * self.variation),
            StatKind::Unif   => self.mean * (1.0 + sign * self.variation),
            StatKind::Limit  => self.mean + sign * self.variation,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rng_is_deterministic() {
        let mut a = StatRng::new(42);
        let mut b = StatRng::new(42);
        for _ in 0..10 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn rng_unit_in_range() {
        let mut r = StatRng::new(7);
        for _ in 0..10_000 {
            let u = r.next_unit();
            assert!((0.0..1.0).contains(&u));
        }
    }

    #[test]
    fn normal_mean_zero_unit_variance() {
        // Empirical: 100k Box-Muller samples should have mean ~0, var ~1.
        let mut r = StatRng::new(123);
        let n = 100_000;
        let samples: Vec<f64> = (0..n).map(|_| r.next_normal()).collect();
        let mean = samples.iter().sum::<f64>() / n as f64;
        let var  = samples.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / n as f64;
        assert!(mean.abs() < 0.05, "mean drift {mean}");
        assert!((var - 1.0).abs() < 0.05, "var drift {var}");
    }

    #[test]
    fn agauss_uses_sigma_over_nsig() {
        // sigma=100, nsig=3, z=3  →  mean + 3 * 100 / 3 = mean + 100
        let e = StatExpr {
            kind: StatKind::AGauss,
            mean: 1000.0,
            variation: 100.0,
            nsig: 3.0,
            matching: Matching::Dev,
        };
        assert!((e.sample(3.0, 0.0, false) - 1100.0).abs() < 1e-12);
        assert!((e.sample(0.0, 0.0, false) - 1000.0).abs() < 1e-12);
    }

    #[test]
    fn gauss_relative() {
        // mean=1k, rel=0.05, nsig=1, z=1  → 1k * (1 + 0.05) = 1050
        let e = StatExpr {
            kind: StatKind::Gauss,
            mean: 1000.0,
            variation: 0.05,
            nsig: 1.0,
            matching: Matching::Dev,
        };
        assert!((e.sample(1.0, 0.0, false) - 1050.0).abs() < 1e-9);
    }

    #[test]
    fn unif_endpoints() {
        let e = StatExpr {
            kind: StatKind::Unif,
            mean: 100.0,
            variation: 0.10,
            nsig: 0.0,
            matching: Matching::Dev,
        };
        assert!((e.sample(0.0,  1.0, false) - 110.0).abs() < 1e-12);
        assert!((e.sample(0.0, -1.0, false) -  90.0).abs() < 1e-12);
        assert!((e.sample(0.0,  0.0, false) - 100.0).abs() < 1e-12);
    }

    #[test]
    fn limit_chooses_sign_from_bit() {
        let e = StatExpr {
            kind: StatKind::Limit,
            mean: 5.0,
            variation: 0.5,
            nsig: 0.0,
            matching: Matching::Dev,
        };
        assert!((e.sample(0.0, 0.0, true)  - 5.5).abs() < 1e-12);
        assert!((e.sample(0.0, 0.0, false) - 4.5).abs() < 1e-12);
    }

    #[test]
    fn corners_are_extreme() {
        let e = StatExpr {
            kind: StatKind::AGauss,
            mean: 1000.0,
            variation: 50.0,
            nsig: 1.0,
            matching: Matching::Lot,
        };
        assert!((e.corner( 1.0) - 1050.0).abs() < 1e-12);
        assert!((e.corner(-1.0) -  950.0).abs() < 1e-12);
    }

    #[test]
    fn from_name_case_insensitive() {
        assert_eq!(StatKind::from_name("AGAUSS"), Some(StatKind::AGauss));
        assert_eq!(StatKind::from_name("gauss"),  Some(StatKind::Gauss));
        assert_eq!(StatKind::from_name("Unif"),   Some(StatKind::Unif));
        assert_eq!(StatKind::from_name("LIMIT"),  Some(StatKind::Limit));
        assert_eq!(StatKind::from_name("normal"), None);
    }

    #[test]
    fn derive_stream_is_deterministic_but_independent() {
        let master = StatRng::new(0xDEAD_BEEF);
        let mut a = master.derive_stream(1);
        let mut b = master.derive_stream(2);
        let mut a2 = master.derive_stream(1);
        // Same tag → same stream.
        assert_eq!(a.next_u64(), a2.next_u64());
        // Different tag → different stream (overwhelmingly likely).
        assert_ne!(a.next_u64(), b.next_u64());
    }
}
