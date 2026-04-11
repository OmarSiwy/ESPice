//! # Generational Index Pool
//!
//! A flat `Vec`-backed collection where items are referenced by `Handle` instead of pointer.
//! Each handle contains an index and a generation counter. When a slot is reused after removal,
//! the generation increments, making all old handles to that slot stale. This gives you:
//!
//! - **Use-after-free detection** at runtime (stale handles return `None`)
//! - **Half the size** of pointers (8 bytes vs 16 for a `Box<T>` equivalent)
//! - **Reallocation-safe** references (indices don't move when the Vec grows)
//! - **Serialization-friendly** (it's just two u32s)
//! - **Cache-friendly** storage (items live in a flat Vec)
//!
//! ## When to use Pool vs Vec
//!
//! Use `Pool` when:
//! - Items are created and destroyed independently (not all at once)
//! - Other systems need stable references to items that survive insertions/removals
//! - You need to detect dangling references
//!
//! Use plain `Vec` (or `SoaVec`) when:
//! - Items are all created at startup and never removed
//! - Removal order doesn't matter and swap-remove is fine
//! - You don't need stable handles across frames
//!
//! ## Usage
//!
//! ```rust
//! use bigospice_utility::{Pool, Handle};
//!
//! let mut pool: Pool<String> = Pool::new();
//!
//! let h1 = pool.insert("hello".to_string());
//! let h2 = pool.insert("world".to_string());
//!
//! assert_eq!(pool.get(h1), Some(&"hello".to_string()));
//!
//! pool.remove(h1);
//!
//! // h1 is now stale — the generation doesn't match
//! assert_eq!(pool.get(h1), None);
//!
//! // The slot gets reused, but with a new generation
//! let h3 = pool.insert("reused".to_string());
//! assert_eq!(h3.index, h1.index); // same slot
//! assert_ne!(h3.generation, h1.generation); // different generation
//! ```
//!
//! ## Design notes (Zig comparison)
//!
//! This is analogous to how the Zig compiler references AST nodes: `u32` indices into a flat
//! array, with generation counters for safety. The Zig standard library doesn't have a built-in
//! generational pool, but the pattern is ubiquitous in Zig codebases (the compiler uses
//! `Ast.Node.Index = u32` throughout).

use std::fmt;

/// A handle to an item in a [`Pool`]. Contains an index and a generation counter.
///
/// ## Size
/// 8 bytes total (two u32s). Compare to `Box<T>` which is 8 bytes for the pointer alone,
/// plus heap allocation overhead.
///
/// ## Copy semantics
/// Handles are `Copy` — you can freely duplicate them. This is intentional: handles are
/// like keys, not owners. The Pool owns the data; handles are just lookup tokens.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Handle {
    /// Index into the pool's storage vec.
    pub index: u32,
    /// Generation counter. Incremented each time this slot is reused.
    /// A handle is valid only if its generation matches the slot's current generation.
    pub generation: u32,
}

impl fmt::Debug for Handle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Handle({}:gen{})", self.index, self.generation)
    }
}

impl fmt::Display for Handle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:g{}", self.index, self.generation)
    }
}

/// Entry in the pool's internal storage. Either occupied (with data + generation)
/// or free (with a pointer to the next free slot).
enum Entry<T> {
    Occupied {
        value: T,
        generation: u32,
    },
    Free {
        generation: u32,
        next_free: Option<u32>,
    },
}

/// A generational index pool. Stores items in a flat Vec, references them by Handle.
///
/// ## Invariants
/// - Every slot has a monotonically increasing generation counter
/// - A Handle is valid iff `handle.generation == slot.generation` AND the slot is Occupied
/// - Removed slots are pushed onto a free list for O(1) reuse
/// - The free list is LIFO (stack) for cache locality — recently freed slots are reused first
pub struct Pool<T> {
    entries: Vec<Entry<T>>,
    free_head: Option<u32>,
    len: usize,
}

impl<T> Pool<T> {
    /// Create an empty pool.
    pub fn new() -> Self {
        Pool {
            entries: Vec::new(),
            free_head: None,
            len: 0,
        }
    }

    /// Create a pool with pre-allocated capacity.
    pub fn with_capacity(cap: usize) -> Self {
        Pool {
            entries: Vec::with_capacity(cap),
            free_head: None,
            len: 0,
        }
    }

    /// Number of live items in the pool.
    pub fn len(&self) -> usize {
        self.len
    }

    /// Whether the pool has no live items.
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Insert an item, returning a handle to it.
    ///
    /// If there's a free slot, it's reused (O(1)). Otherwise, a new slot is appended.
    pub fn insert(&mut self, value: T) -> Handle {
        self.len += 1;

        if let Some(free_idx) = self.free_head {
            // Reuse a free slot
            let idx = free_idx as usize;
            match &self.entries[idx] {
                Entry::Free { generation, next_free } => {
                    let cur_gen = *generation;
                    let next = *next_free;
                    self.entries[idx] = Entry::Occupied {
                        value,
                        generation: cur_gen,
                    };
                    self.free_head = next;
                    Handle {
                        index: free_idx,
                        generation: cur_gen,
                    }
                }
                Entry::Occupied { .. } => unreachable!("free list pointed to occupied slot"),
            }
        } else {
            // Append a new slot
            let index = self.entries.len() as u32;
            let generation = 0;
            self.entries.push(Entry::Occupied { value, generation });
            Handle { index, generation }
        }
    }

    /// Get an immutable reference to the item, or `None` if the handle is stale.
    #[inline]
    pub fn get(&self, handle: Handle) -> Option<&T> {
        match self.entries.get(handle.index as usize)? {
            Entry::Occupied { value, generation } if *generation == handle.generation => {
                Some(value)
            }
            _ => None,
        }
    }

    /// Get a mutable reference to the item, or `None` if the handle is stale.
    #[inline]
    pub fn get_mut(&mut self, handle: Handle) -> Option<&mut T> {
        match self.entries.get_mut(handle.index as usize)? {
            Entry::Occupied { value, generation } if *generation == handle.generation => {
                Some(value)
            }
            _ => None,
        }
    }

    /// Remove the item at the handle. Returns the value if the handle was valid.
    /// The slot is added to the free list with an incremented generation.
    pub fn remove(&mut self, handle: Handle) -> Option<T> {
        let idx = handle.index as usize;
        match self.entries.get(idx)? {
            Entry::Occupied { generation, .. } if *generation == handle.generation => {}
            _ => return None,
        }

        // Take the value out
        let old_entry = std::mem::replace(
            &mut self.entries[idx],
            Entry::Free {
                generation: handle.generation + 1, // increment to invalidate old handles
                next_free: self.free_head,
            },
        );

        self.free_head = Some(handle.index);
        self.len -= 1;

        match old_entry {
            Entry::Occupied { value, .. } => Some(value),
            _ => unreachable!(),
        }
    }

    /// Check if a handle is still valid (points to a live item).
    #[inline]
    pub fn is_valid(&self, handle: Handle) -> bool {
        match self.entries.get(handle.index as usize) {
            Some(Entry::Occupied { generation, .. }) => *generation == handle.generation,
            _ => false,
        }
    }

    /// Iterate over all live items with their handles.
    pub fn iter(&self) -> impl Iterator<Item = (Handle, &T)> {
        self.entries.iter().enumerate().filter_map(|(i, entry)| {
            match entry {
                Entry::Occupied { value, generation } => Some((
                    Handle {
                        index: i as u32,
                        generation: *generation,
                    },
                    value,
                )),
                _ => None,
            }
        })
    }

    /// Iterate mutably over all live items with their handles.
    pub fn iter_mut(&mut self) -> impl Iterator<Item = (Handle, &mut T)> {
        self.entries.iter_mut().enumerate().filter_map(|(i, entry)| {
            match entry {
                Entry::Occupied { value, generation } => Some((
                    Handle {
                        index: i as u32,
                        generation: *generation,
                    },
                    value,
                )),
                _ => None,
            }
        })
    }

    /// Clear all items. All existing handles become invalid.
    pub fn clear(&mut self) {
        self.entries.clear();
        self.free_head = None;
        self.len = 0;
    }

    /// Total number of slots (occupied + free). Useful for understanding memory usage.
    pub fn slot_count(&self) -> usize {
        self.entries.len()
    }
}

impl<T> Default for Pool<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: fmt::Debug> fmt::Debug for Pool<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Pool")
            .field("len", &self.len)
            .field("slots", &self.entries.len())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_get() {
        let mut pool = Pool::new();
        let h = pool.insert(42);
        assert_eq!(pool.get(h), Some(&42));
    }

    #[test]
    fn remove_invalidates() {
        let mut pool = Pool::new();
        let h = pool.insert("hello");
        assert_eq!(pool.remove(h), Some("hello"));
        assert_eq!(pool.get(h), None); // stale
    }

    #[test]
    fn generation_increments() {
        let mut pool = Pool::new();
        let h1 = pool.insert(1);
        pool.remove(h1);
        let h2 = pool.insert(2);
        assert_eq!(h2.index, h1.index); // same slot
        assert_eq!(h2.generation, h1.generation + 1); // newer generation
        assert_eq!(pool.get(h1), None); // old handle is stale
        assert_eq!(pool.get(h2), Some(&2)); // new handle works
    }

    #[test]
    fn free_list_reuse() {
        let mut pool = Pool::new();
        let h1 = pool.insert(1);
        let h2 = pool.insert(2);
        let _h3 = pool.insert(3);
        pool.remove(h2);
        pool.remove(h1);
        // Free list is LIFO: h1 was freed last, so it's reused first
        let h4 = pool.insert(4);
        assert_eq!(h4.index, h1.index);
        let h5 = pool.insert(5);
        assert_eq!(h5.index, h2.index);
    }

    #[test]
    fn iterate() {
        let mut pool = Pool::new();
        pool.insert(10);
        pool.insert(20);
        let h = pool.insert(30);
        pool.remove(h);

        let values: Vec<_> = pool.iter().map(|(_, v)| *v).collect();
        assert_eq!(values, vec![10, 20]);
    }
}
