use ahash::AHashMap;
use serde::{Deserialize, Serialize};
use std::borrow::Borrow;
use std::fmt;
use std::hash::{Hash, Hasher};

/// A parameter key — compact interned string for fast lookup.
///
/// Implements `Borrow<str>` so that `AHashMap::get` can accept `&str`
/// without allocating a `String` on every hot-path lookup.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParamKey(pub String);

impl ParamKey {
    pub fn new(s: impl Into<String>) -> Self {
        Self(s.into().to_lowercase())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Hash for ParamKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        // Hash the &str content so that Borrow<str> hashing is consistent.
        self.0.as_str().hash(state);
    }
}

impl Borrow<str> for ParamKey {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ParamKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<&str> for ParamKey {
    fn from(s: &str) -> Self {
        Self::new(s)
    }
}

/// A parameter value — always f64 for circuit simulation.
/// Internal wrapper providing Eq/Hash for f64 (used as map value).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
struct ParamValue(f64);

impl Eq for ParamValue {}

impl Hash for ParamValue {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.0.to_bits().hash(state);
    }
}

/// Stack buffer size for case-insensitive key lookup.
/// Parameter names in SPICE are short (e.g., "resistance", "lambda", "vth0").
/// 32 bytes covers all known parameter names without heap allocation.
const KEY_BUF_LEN: usize = 32;

/// Convert a key to lowercase in a stack-allocated buffer.
/// Returns `Some(&str)` if the key fits, `None` if it exceeds the buffer.
/// In the `None` case, the caller falls back to a heap-allocated `String`.
#[inline]
fn lowercase_key(key: &str) -> Option<([u8; KEY_BUF_LEN], usize)> {
    let bytes = key.as_bytes();
    if bytes.len() > KEY_BUF_LEN {
        return None;
    }
    let mut buf = [0u8; KEY_BUF_LEN];
    let len = bytes.len();
    // Manual ASCII lowercase — all SPICE parameter names are ASCII.
    buf[..len].iter_mut().zip(bytes.iter()).for_each(|(d, &s)| {
        *d = s.to_ascii_lowercase();
    });
    Some((buf, len))
}

/// Flat hash map of parameter key→value pairs for a device instance.
///
/// Hot-path lookups (`get`, `get_or`, `contains`) use a stack-allocated
/// lowercase buffer to avoid heap allocation. Parameter names in SPICE
/// are short ASCII strings, so this is always stack-allocated in practice.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ParamMap {
    inner: AHashMap<ParamKey, ParamValue>,
}

impl ParamMap {
    pub fn new() -> Self {
        Self { inner: AHashMap::new() }
    }

    pub fn with_capacity(cap: usize) -> Self {
        Self { inner: AHashMap::with_capacity(cap) }
    }

    pub fn set(&mut self, key: &str, value: f64) {
        self.inner.insert(ParamKey::new(key), ParamValue(value));
    }

    /// Look up a parameter by name. Case-insensitive.
    ///
    /// Uses a stack-allocated buffer for lowercase conversion to avoid
    /// heap allocation on the hot path. For the rare case of parameter
    /// names longer than 32 bytes, falls back to `String` allocation.
    #[inline]
    pub fn get(&self, key: &str) -> Option<f64> {
        if let Some((buf, len)) = lowercase_key(key) {
            // SAFETY: we lowercased valid ASCII bytes from a &str.
            let lower = unsafe { std::str::from_utf8_unchecked(&buf[..len]) };
            self.inner.get(lower).map(|v| v.0)
        } else {
            // Fallback for unusually long keys — heap allocate.
            let lower = key.to_lowercase();
            self.inner.get(lower.as_str()).map(|v| v.0)
        }
    }

    #[inline]
    pub fn get_or(&self, key: &str, default: f64) -> f64 {
        self.get(key).unwrap_or(default)
    }

    #[inline]
    pub fn contains(&self, key: &str) -> bool {
        if let Some((buf, len)) = lowercase_key(key) {
            let lower = unsafe { std::str::from_utf8_unchecked(&buf[..len]) };
            self.inner.contains_key(lower)
        } else {
            let lower = key.to_lowercase();
            self.inner.contains_key(lower.as_str())
        }
    }

    pub fn remove(&mut self, key: &str) -> Option<f64> {
        if let Some((buf, len)) = lowercase_key(key) {
            let lower = unsafe { std::str::from_utf8_unchecked(&buf[..len]) };
            self.inner.remove(lower).map(|v| v.0)
        } else {
            let lower = key.to_lowercase();
            self.inner.remove(lower.as_str()).map(|v| v.0)
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, f64)> + '_ {
        self.inner.iter().map(|(k, v)| (k.as_str(), v.0))
    }

    pub fn len(&self) -> usize {
        self.inner.len()
    }

    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }
}

// ---------------------------------------------------------------------------
// Compiled parameters — hot-path optimization layer over `ParamMap`
// ---------------------------------------------------------------------------

/// A device-specific compiled parameter struct.
///
/// Devices that implement this trait pay the (still tiny but non-zero) cost of
/// hashed string lookups **once**, at construction / topology-build time, and
/// then read their parameters out of a fixed-layout struct on every Newton
/// iteration.  This eliminates per-call hashing, lowercasing, and bucket
/// probing on the simulator's hot path.
///
/// The compiled struct is meant to be `Copy` (or at least `Clone`) and to live
/// either on the device instance directly or in a side table indexed by
/// `DeviceId`.
///
/// # Example
///
/// ```ignore
/// use pisim_core::param::{CompiledParams, ParamMap};
///
/// #[derive(Clone, Copy)]
/// struct MosfetParams {
///     kp: f64,
///     vth: f64,
///     lambda: f64,
///     w: f64,
///     l: f64,
/// }
///
/// impl CompiledParams for MosfetParams {
///     fn compile(map: &ParamMap) -> Self {
///         Self {
///             kp:     map.get_or("kp", 2e-5),
///             vth:    map.get_or("vth", 0.7),
///             lambda: map.get_or("lambda", 0.0),
///             w:      map.get_or("w", 1e-6),
///             l:      map.get_or("l", 1e-6),
///         }
///     }
/// }
///
/// let mut pm = ParamMap::new();
/// pm.set("kp", 5e-5);
/// pm.set("vth", 0.55);
/// let cp = MosfetParams::compile(&pm);
/// assert_eq!(cp.kp, 5e-5);
/// assert_eq!(cp.vth, 0.55);
/// // lambda, w, l fall back to the trait-provided defaults.
/// ```
///
/// This trait is intentionally **additive**: existing devices may keep
/// calling `ParamMap::get` directly, and any new device may opt into the
/// compiled layout by implementing this trait.
pub trait CompiledParams: Sized {
    /// Build a compiled parameter struct from a generic `ParamMap`.
    ///
    /// Implementations should pull every parameter the device cares about,
    /// supplying a sensible default if the user did not specify the value
    /// (use [`ParamMap::get_or`] for this).
    fn compile(map: &ParamMap) -> Self;
}

/// Pull a parameter by name, falling back to `default` if it is missing.
///
/// This is a tiny convenience wrapper around [`ParamMap::get_or`] that exists
/// so that compiled-parameter `compile` implementations can read like a list
/// of `(key, default)` pairs without repeating the `map.` prefix everywhere.
///
/// ```ignore
/// use pisim_core::param::{compiled_get, ParamMap};
/// let mut m = ParamMap::new();
/// m.set("vth", 0.5);
/// assert_eq!(compiled_get(&m, "vth", 0.7), 0.5);
/// assert_eq!(compiled_get(&m, "kp", 2e-5), 2e-5);
/// ```
#[inline]
pub fn compiled_get(map: &ParamMap, key: &str, default: f64) -> f64 {
    map.get_or(key, default)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn param_map_basic_ops() {
        let mut pm = ParamMap::new();
        pm.set("resistance", 1e3);
        pm.set("tc1", 0.001);

        assert_eq!(pm.get("resistance"), Some(1e3));
        assert_eq!(pm.get("tc1"), Some(0.001));
        assert_eq!(pm.get("missing"), None);
        assert_eq!(pm.get_or("missing", 42.0), 42.0);
        assert_eq!(pm.len(), 2);
    }

    #[test]
    fn param_key_case_insensitive() {
        let mut pm = ParamMap::new();
        pm.set("Resistance", 1e3);
        assert_eq!(pm.get("resistance"), Some(1e3));
        assert_eq!(pm.get("RESISTANCE"), Some(1e3));
    }

    #[test]
    fn param_map_remove() {
        let mut pm = ParamMap::new();
        pm.set("r", 100.0);
        assert_eq!(pm.remove("r"), Some(100.0));
        assert!(!pm.contains("r"));
    }

    // -------------------------------------------------------------------
    // CompiledParams tests
    // -------------------------------------------------------------------

    #[derive(Clone, Copy, Debug, PartialEq)]
    struct TestMosfetParams {
        kp: f64,
        vth: f64,
        lambda: f64,
        w: f64,
        l: f64,
    }

    impl CompiledParams for TestMosfetParams {
        fn compile(map: &ParamMap) -> Self {
            Self {
                kp:     map.get_or("kp", 2e-5),
                vth:    map.get_or("vth", 0.7),
                lambda: map.get_or("lambda", 0.0),
                w:      map.get_or("w", 1e-6),
                l:      map.get_or("l", 1e-6),
            }
        }
    }

    #[test]
    fn compiled_params_pulls_user_values() {
        let mut pm = ParamMap::new();
        pm.set("kp", 5e-5);
        pm.set("vth", 0.55);
        pm.set("lambda", 0.02);
        pm.set("w", 2e-6);
        pm.set("l", 1.8e-7);

        let cp = TestMosfetParams::compile(&pm);
        assert_eq!(cp, TestMosfetParams {
            kp: 5e-5,
            vth: 0.55,
            lambda: 0.02,
            w: 2e-6,
            l: 1.8e-7,
        });
    }

    #[test]
    fn compiled_params_uses_defaults_when_missing() {
        let pm = ParamMap::new();
        let cp = TestMosfetParams::compile(&pm);
        assert_eq!(cp, TestMosfetParams {
            kp: 2e-5,
            vth: 0.7,
            lambda: 0.0,
            w: 1e-6,
            l: 1e-6,
        });
    }

    #[test]
    fn compiled_params_case_insensitive_keys() {
        // The user may capitalize parameter names; ParamMap is
        // case-insensitive so the compiled struct should still pick them up.
        let mut pm = ParamMap::new();
        pm.set("KP", 9e-5);
        pm.set("Vth", 0.42);
        let cp = TestMosfetParams::compile(&pm);
        assert_eq!(cp.kp, 9e-5);
        assert_eq!(cp.vth, 0.42);
    }

    #[test]
    fn compiled_get_helper() {
        let mut pm = ParamMap::new();
        pm.set("vth", 0.5);
        assert_eq!(compiled_get(&pm, "vth", 0.7), 0.5);
        assert_eq!(compiled_get(&pm, "kp", 2e-5), 2e-5);
    }
}
