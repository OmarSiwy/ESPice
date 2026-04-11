//! # Dense BitSet for Existence-Based Processing
//!
//! In DOD, you avoid `if entity.is_alive` in hot loops. Instead, you maintain a bitset
//! that tracks which indices are alive/active/dirty. Iteration skips entire 64-entity
//! blocks that are all-zero, and within each block, `trailing_zeros()` finds the next
//! set bit in one CPU instruction.
//!
//! ## Why not `HashSet<usize>`?
//!
//! - `HashSet` is 24 bytes per entry + hashing overhead
//! - `BitSet` is 1 *bit* per entry — 192x more compact
//! - `BitSet` iteration is branch-free over empty blocks
//! - `BitSet` AND/OR/XOR operations are single instructions per 64 items
//!
//! ## Usage
//!
//! ```rust
//! use bigospice_utility::BitSet;
//!
//! let mut alive = BitSet::new();
//! alive.insert(0);
//! alive.insert(5);
//! alive.insert(63);
//! alive.insert(1000);
//!
//! // Iterate only over set bits — skips empty u64 words entirely
//! for idx in alive.iter() {
//!     // process entity at idx
//! }
//!
//! // Set operations for combining queries
//! let mut damaged = BitSet::new();
//! damaged.insert(5);
//! damaged.insert(42);
//!
//! // "alive AND damaged" — only process alive entities that are damaged
//! let targets = alive.intersection(&damaged);
//! for idx in targets.iter() {
//!     // apply damage effects
//! }
//! ```
//!
//! ## Design notes
//!
//! This is the Rust equivalent of the "existence-based processing" pattern. Instead of
//! storing a `bool is_alive` field on every entity (which wastes 7 bits + padding per entity
//! and forces branching in hot loops), store a separate bitset and iterate only set bits.

/// A growable dense bitset backed by a `Vec<u64>`.
///
/// Each `u64` word tracks 64 indices. Total memory for N items: `N/8` bytes (plus Vec overhead).
/// For 10,000 entities: ~1.2 KB. Compare to `Vec<bool>`: 10,000 bytes.
#[derive(Clone, Default)]
pub struct BitSet {
    words: Vec<u64>,
}

impl BitSet {
    /// Create an empty bitset.
    pub fn new() -> Self {
        Self { words: Vec::new() }
    }

    /// Create a bitset with capacity for at least `n` bits.
    pub fn with_capacity(n: usize) -> Self {
        Self {
            words: vec![0u64; (n + 63) / 64],
        }
    }

    /// Set the bit at `index`.
    #[inline]
    pub fn insert(&mut self, index: usize) {
        let word = index / 64;
        let bit = index % 64;
        if word >= self.words.len() {
            self.words.resize(word + 1, 0);
        }
        self.words[word] |= 1u64 << bit;
    }

    /// Clear the bit at `index`.
    #[inline]
    pub fn remove(&mut self, index: usize) {
        let word = index / 64;
        let bit = index % 64;
        if word < self.words.len() {
            self.words[word] &= !(1u64 << bit);
        }
    }

    /// Check if the bit at `index` is set.
    #[inline]
    pub fn contains(&self, index: usize) -> bool {
        let word = index / 64;
        let bit = index % 64;
        word < self.words.len() && (self.words[word] & (1u64 << bit)) != 0
    }

    /// Toggle the bit at `index`. Returns the new value.
    #[inline]
    pub fn toggle(&mut self, index: usize) -> bool {
        let word = index / 64;
        let bit = index % 64;
        if word >= self.words.len() {
            self.words.resize(word + 1, 0);
        }
        self.words[word] ^= 1u64 << bit;
        (self.words[word] & (1u64 << bit)) != 0
    }

    /// Number of set bits.
    pub fn count(&self) -> usize {
        self.words.iter().map(|w| w.count_ones() as usize).sum()
    }

    /// Clear all bits.
    pub fn clear(&mut self) {
        self.words.iter_mut().for_each(|w| *w = 0);
    }

    /// Whether no bits are set.
    pub fn is_empty(&self) -> bool {
        self.words.iter().all(|&w| w == 0)
    }

    /// Iterate over all set bit indices.
    ///
    /// This is the key operation for existence-based processing. It skips entire 64-bit
    /// words that are zero, so if your entities are sparse, iteration is very fast.
    pub fn iter(&self) -> BitSetIter<'_> {
        BitSetIter {
            words: &self.words,
            word_idx: 0,
            current_word: self.words.first().copied().unwrap_or(0),
        }
    }

    /// Bitwise AND — returns a new bitset with only bits set in BOTH sets.
    ///
    /// Use for: "alive AND damaged", "visible AND in_range", etc.
    pub fn intersection(&self, other: &BitSet) -> BitSet {
        BitSet {
            words: self.words.iter()
                .zip(other.words.iter())
                .map(|(&a, &b)| a & b)
                .collect(),
        }
    }

    /// Bitwise OR — returns a new bitset with bits set in EITHER set.
    pub fn union(&self, other: &BitSet) -> BitSet {
        let max_len = self.words.len().max(other.words.len());
        BitSet {
            words: (0..max_len)
                .map(|i| {
                    let a = self.words.get(i).copied().unwrap_or(0);
                    let b = other.words.get(i).copied().unwrap_or(0);
                    a | b
                })
                .collect(),
        }
    }

    /// Bitwise AND NOT — returns bits set in `self` but NOT in `other`.
    ///
    /// Use for: "alive AND NOT invulnerable", "dirty AND NOT already_processed".
    pub fn difference(&self, other: &BitSet) -> BitSet {
        BitSet {
            words: self.words.iter()
                .enumerate()
                .map(|(i, &w)| w & !other.words.get(i).copied().unwrap_or(0))
                .collect(),
        }
    }
}

impl std::fmt::Debug for BitSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "BitSet({} set)", self.count())
    }
}

/// Iterator over set bits in a BitSet. Uses `trailing_zeros()` to skip unset bits efficiently.
pub struct BitSetIter<'a> {
    words: &'a [u64],
    word_idx: usize,
    current_word: u64,
}

impl<'a> Iterator for BitSetIter<'a> {
    type Item = usize;

    #[inline]
    fn next(&mut self) -> Option<usize> {
        loop {
            if self.current_word != 0 {
                // Find the lowest set bit — one CPU instruction on modern hardware
                let bit = self.current_word.trailing_zeros() as usize;
                // Clear it
                self.current_word &= self.current_word - 1;
                return Some(self.word_idx * 64 + bit);
            }
            // Move to next word
            self.word_idx += 1;
            if self.word_idx >= self.words.len() {
                return None;
            }
            self.current_word = self.words[self.word_idx];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_ops() {
        let mut bs = BitSet::new();
        assert!(bs.is_empty());
        bs.insert(0);
        bs.insert(63);
        bs.insert(64);
        bs.insert(1000);
        assert_eq!(bs.count(), 4);
        assert!(bs.contains(0));
        assert!(bs.contains(63));
        assert!(bs.contains(64));
        assert!(bs.contains(1000));
        assert!(!bs.contains(1));
    }

    #[test]
    fn iteration() {
        let mut bs = BitSet::new();
        bs.insert(5);
        bs.insert(100);
        bs.insert(3);
        let bits: Vec<_> = bs.iter().collect();
        assert_eq!(bits, vec![3, 5, 100]); // sorted by index
    }

    #[test]
    fn intersection() {
        let mut a = BitSet::new();
        a.insert(1);
        a.insert(2);
        a.insert(3);
        let mut b = BitSet::new();
        b.insert(2);
        b.insert(3);
        b.insert(4);
        let c = a.intersection(&b);
        let bits: Vec<_> = c.iter().collect();
        assert_eq!(bits, vec![2, 3]);
    }

    #[test]
    fn difference() {
        let mut alive = BitSet::new();
        alive.insert(1);
        alive.insert(2);
        alive.insert(3);
        let mut invulnerable = BitSet::new();
        invulnerable.insert(2);
        let damageable = alive.difference(&invulnerable);
        let bits: Vec<_> = damageable.iter().collect();
        assert_eq!(bits, vec![1, 3]);
    }

    #[test]
    fn toggle() {
        let mut bs = BitSet::new();
        assert!(bs.toggle(5)); // was 0, now 1
        assert!(bs.contains(5));
        assert!(!bs.toggle(5)); // was 1, now 0
        assert!(!bs.contains(5));
    }
}
