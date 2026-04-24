//! Phase 5.1 — Topology cache.
//!
//! Goal: when a parameter sweep keeps the netlist topology fixed, skip the
//! expensive symbolic factorisation step entirely on every solve after the
//! first one.  Only the numeric LU has to run again.
//!
//! ## Design
//!
//! `TopologyHash` is a 64-bit FNV-1a digest of:
//!   - the node count
//!   - every device kind (`u8` discriminants), in declaration order
//!   - every device's terminal `(pin, node_id)` connectivity, in declaration
//!     order
//!   - the parser/topology version constant `TOPOLOGY_VERSION`
//!
//! Two circuits with the same `TopologyHash` are guaranteed to produce the
//! same MNA structural pattern, which means:
//!   - column counts of the LU factors,
//!   - row indices of the L/U non-zeros,
//!   - the AMD ordering permutation,
//!   - the elimination tree,
//!
//! can all be reused without recomputation.  Only the numeric values change.
//!
//! ## Why FNV-1a (and not ahash)?
//!
//! The cache layer is meant to be deterministic across runs, processes, and
//! machines so a `.STEP` sweep can persist its symbolic factorisation
//! between invocations.  `ahash` randomises its seed at process start, which
//! would break that property.  FNV-1a is small, fast, and stable.

use incspice_core::{Circuit, DeviceInstance};

/// Bumped whenever the parser or topology layout changes meaning, so a stale
/// on-disk cache from an older BigOSpice version is automatically discarded.
pub const TOPOLOGY_VERSION: u64 = 1;

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

/// Tiny streaming FNV-1a 64-bit hasher.
///
/// Inlined locally so the cache layer has zero hashing dependencies and so
/// the hash value is bit-stable across processes (`ahash` is not).
#[derive(Debug, Clone, Copy)]
pub struct Fnv1a64 {
    state: u64,
}

impl Default for Fnv1a64 {
    fn default() -> Self {
        Self { state: FNV_OFFSET }
    }
}

impl Fnv1a64 {
    #[inline]
    pub fn new() -> Self {
        Self::default()
    }

    #[inline]
    pub fn write(&mut self, bytes: &[u8]) {
        let mut state = self.state;
        for &b in bytes {
            state ^= b as u64;
            state = state.wrapping_mul(FNV_PRIME);
        }
        self.state = state;
    }

    #[inline]
    pub fn write_u8(&mut self, v: u8) {
        self.write(&[v]);
    }

    #[inline]
    pub fn write_u32(&mut self, v: u32) {
        self.write(&v.to_le_bytes());
    }

    #[inline]
    pub fn write_u64(&mut self, v: u64) {
        self.write(&v.to_le_bytes());
    }

    #[inline]
    pub fn finish(self) -> u64 {
        self.state
    }
}

/// 64-bit content hash uniquely identifying a circuit's MNA topology.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TopologyHash(pub u64);

impl TopologyHash {
    /// Hash a circuit by its node count, device kinds, and connectivity.
    ///
    /// Note: device parameters and names are deliberately *not* included.
    /// The whole point of the topology cache is that two circuits with
    /// identical structure but different parameter values share a hash.
    pub fn from_circuit(circuit: &Circuit) -> Self {
        let mut h = Fnv1a64::new();
        h.write_u64(TOPOLOGY_VERSION);
        h.write_u32(circuit.nodes().len() as u32);
        h.write_u32(circuit.devices().len() as u32);

        // Devices in declaration order; netlist order is the canonical order
        // because the parser preserves it and the MNA dimension is built from
        // it.  We do *not* sort here — sorting would mean the AMD ordering
        // we end up caching would no longer match this circuit's pivot order.
        for dev in circuit.devices() {
            Self::hash_device_into(&mut h, dev);
        }

        Self(h.finish())
    }

    #[inline]
    fn hash_device_into(h: &mut Fnv1a64, dev: &DeviceInstance) {
        h.write_u8(dev.kind as u8);
        h.write_u8(dev.terminals.len() as u8);
        for term in &dev.terminals {
            h.write_u8(term.pin);
            // NodeId — ground is 0, real nodes 1..
            h.write_u32(term.node.0);
        }
        // Branch index presence affects the MNA dimension.
        match dev.branch_index {
            Some(bi) => {
                h.write_u8(1);
                h.write_u32(bi);
            }
            None => h.write_u8(0),
        }
    }
}

/// Output of one symbolic factorisation pass — what we want to cache and
/// reuse across solves with identical topology.
///
/// All vectors are SoA `Vec<…>`; no boxed trait objects.
#[derive(Debug, Clone)]
pub struct SymbolicLu {
    /// Matrix dimension (`n` for an `n×n` system).
    pub n: usize,
    /// Column counts of the L+U union pattern (length `n`).
    pub col_counts: Vec<u32>,
    /// Row indices of the L+U non-zeros, packed by column.  Length is the
    /// total number of non-zeros in the symbolic factor pattern.
    pub row_indices: Vec<u32>,
    /// AMD-style fill-reducing column permutation (length `n`).
    pub amd_perm: Vec<u32>,
    /// Inverse of `amd_perm` (length `n`).
    pub amd_inv: Vec<u32>,
    /// Parent[k] in the elimination tree, or `u32::MAX` for a root.
    pub etree_parent: Vec<u32>,
}

impl SymbolicLu {
    /// Build a degenerate empty symbolic factor (used by the cache when the
    /// solver has not yet provided one).
    pub fn empty(n: usize) -> Self {
        Self {
            n,
            col_counts: vec![0; n],
            row_indices: Vec::new(),
            amd_perm: (0..n as u32).collect(),
            amd_inv: (0..n as u32).collect(),
            etree_parent: vec![u32::MAX; n],
        }
    }
}

/// One entry in the linear-solver cache, owned by the global `CacheManager`.
#[derive(Debug, Clone)]
pub struct LinSolverCacheEntry {
    pub topology: TopologyHash,
    pub symbolic: SymbolicLu,
    /// Number of times this entry has been hit (for telemetry).
    pub hits: u64,
}

/// Look-up table from `TopologyHash` to its cached symbolic factor.
///
/// Backed by a `Vec` rather than a `HashMap` because the cache typically
/// holds 1–4 entries during a sweep and a linear scan over a handful of
/// `u64`s is faster than hashing.
#[derive(Debug, Clone, Default)]
pub struct LinSolverCache {
    entries: Vec<LinSolverCacheEntry>,
}

impl LinSolverCache {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    /// Look up the symbolic factor for `hash`, recording a hit on success.
    pub fn get_mut(&mut self, hash: TopologyHash) -> Option<&mut LinSolverCacheEntry> {
        let pos = self.entries.iter().position(|e| e.topology == hash)?;
        self.entries[pos].hits += 1;
        Some(&mut self.entries[pos])
    }

    /// Read-only lookup; does not increment the hit counter.
    pub fn peek(&self, hash: TopologyHash) -> Option<&LinSolverCacheEntry> {
        self.entries.iter().find(|e| e.topology == hash)
    }

    /// Insert a new (or overwrite an existing) entry.
    pub fn insert(&mut self, hash: TopologyHash, symbolic: SymbolicLu) {
        if let Some(pos) = self.entries.iter().position(|e| e.topology == hash) {
            self.entries[pos].symbolic = symbolic;
        } else {
            self.entries.push(LinSolverCacheEntry {
                topology: hash,
                symbolic,
                hits: 0,
            });
        }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// Drop entries that have not been hit recently — naive LRU based on
    /// hit count, retaining the top-`max` most-frequently-hit entries.
    pub fn trim(&mut self, max: usize) {
        if self.entries.len() <= max {
            return;
        }
        self.entries.sort_by_key(|e| std::cmp::Reverse(e.hits));
        self.entries.truncate(max);
    }
}

/// Legacy summary kept for compatibility with the previous `IncrementalCache`
/// scaffolding.  New code should use `TopologyHash` + `LinSolverCache` directly.
#[derive(Debug, Clone)]
pub struct TopologyCache {
    pub hash: TopologyHash,
    pub node_count: usize,
    pub device_count: usize,
    pub mna_dimension: usize,
    pub valid: bool,
}

impl TopologyCache {
    pub fn from_circuit(circuit: &Circuit) -> Self {
        Self {
            hash: TopologyHash::from_circuit(circuit),
            node_count: circuit.nodes().len(),
            device_count: circuit.devices().len(),
            mna_dimension: circuit.mna_dimension(),
            valid: true,
        }
    }

    pub fn is_valid(&self, circuit: &Circuit) -> bool {
        self.valid
            && self.node_count == circuit.nodes().len()
            && self.device_count == circuit.devices().len()
            && self.hash == TopologyHash::from_circuit(circuit)
    }

    pub fn invalidate(&mut self) {
        self.valid = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv_smoke() {
        let mut h = Fnv1a64::new();
        h.write(b"abc");
        // FNV-1a("abc") is a well-known constant.
        assert_eq!(h.finish(), 0xe71fa2190541574b);
    }

    #[test]
    fn empty_circuit_hash_is_stable() {
        let ckt = Circuit::new();
        let h1 = TopologyHash::from_circuit(&ckt);
        let h2 = TopologyHash::from_circuit(&ckt);
        assert_eq!(h1, h2);
    }

    #[test]
    fn lin_solver_cache_basic() {
        let mut cache = LinSolverCache::new();
        assert!(cache.is_empty());

        let h = TopologyHash(0xdeadbeef);
        cache.insert(h, SymbolicLu::empty(4));
        assert_eq!(cache.len(), 1);
        assert!(cache.peek(h).is_some());

        let entry = cache.get_mut(h).unwrap();
        assert_eq!(entry.symbolic.n, 4);
        assert_eq!(entry.hits, 1);
    }

    #[test]
    fn lin_solver_cache_trim_keeps_hot_entries() {
        let mut cache = LinSolverCache::new();
        for i in 0..5u64 {
            cache.insert(TopologyHash(i), SymbolicLu::empty(2));
        }
        // Hit only entry 3 a bunch of times.
        for _ in 0..10 {
            let _ = cache.get_mut(TopologyHash(3));
        }
        cache.trim(1);
        assert_eq!(cache.len(), 1);
        assert_eq!(
            cache.peek(TopologyHash(3)).unwrap().topology,
            TopologyHash(3)
        );
    }

    #[test]
    fn topology_hash_stable_for_same_circuit() {
        let ckt = Circuit::new();
        let h1 = TopologyHash::from_circuit(&ckt);
        let h2 = TopologyHash::from_circuit(&ckt);
        assert_eq!(h1, h2, "same circuit should have same hash");
    }

    #[test]
    fn topology_hash_differs_on_added_node() {
        use incspice_core::{DeviceId, DeviceInstance, DeviceKind};
        let mut c1 = Circuit::new();
        let n1 = c1.add_node("n1");
        let d1 = DeviceInstance::new(
            DeviceId::new(0),
            "r1",
            DeviceKind::Resistor,
            &[(0, n1), (1, incspice_core::NodeId::GROUND)],
        ).with_param("resistance", 1000.0);
        c1.add_device(d1);

        let mut c2 = c1.clone();
        let n2 = c2.add_node("n2");
        let d2 = DeviceInstance::new(
            DeviceId::new(0),
            "r2",
            DeviceKind::Resistor,
            &[(0, n2), (1, incspice_core::NodeId::GROUND)],
        ).with_param("resistance", 2000.0);
        c2.add_device(d2);

        let h1 = TopologyHash::from_circuit(&c1);
        let h2 = TopologyHash::from_circuit(&c2);
        assert_ne!(h1, h2, "different circuits should have different hashes");
    }

    #[test]
    fn topology_cache_valid_then_invalidated() {
        let ckt = Circuit::new();
        let mut tc = TopologyCache::from_circuit(&ckt);
        assert!(tc.is_valid(&ckt));
        tc.invalidate();
        assert!(!tc.is_valid(&ckt));
    }

    #[test]
    fn topology_cache_detects_structural_change() {
        use incspice_core::{DeviceId, DeviceInstance, DeviceKind};
        let ckt = Circuit::new();
        let tc = TopologyCache::from_circuit(&ckt);
        assert!(tc.is_valid(&ckt));

        // Add a device to a new circuit — cache should no longer match
        let mut ckt2 = Circuit::new();
        let n1 = ckt2.add_node("n1");
        let d = DeviceInstance::new(
            DeviceId::new(0),
            "r1",
            DeviceKind::Resistor,
            &[(0, n1), (1, incspice_core::NodeId::GROUND)],
        ).with_param("resistance", 1000.0);
        ckt2.add_device(d);

        assert!(!tc.is_valid(&ckt2));
    }

    #[test]
    fn lin_solver_cache_insert_overwrite() {
        let mut cache = LinSolverCache::new();
        let h = TopologyHash(0xaabbccdd);
        cache.insert(h, SymbolicLu::empty(4));
        cache.insert(h, SymbolicLu::empty(8)); // overwrite
        assert_eq!(cache.len(), 1);
        assert_eq!(cache.peek(h).unwrap().symbolic.n, 8);
    }
}
