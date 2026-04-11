//! # Typed Indices — Compile-Time Safety for Index-Based References
//!
//! When using DOD patterns, you end up with many parallel arrays indexed by the same integer
//! type. It's easy to accidentally pass an `entity_idx` where a `mesh_idx` was expected.
//! Typed indices prevent this at zero runtime cost.
//!
//! ## The problem
//!
//! ```rust,compile_fail
//! // Both are u32 — nothing stops you from mixing them up
//! let entity_idx: u32 = 5;
//! let mesh_idx: u32 = 3;
//! meshes[entity_idx]; // Compiles! But it's a bug.
//! ```
//!
//! ## The solution
//!
//! ```rust
//! use bigospice_utility::typed_index;
//!
//! typed_index!(EntityIdx);
//! typed_index!(MeshIdx);
//!
//! let entity: EntityIdx = EntityIdx::new(5);
//! let mesh: MeshIdx = MeshIdx::new(3);
//!
//! // meshes[entity]; // Won't compile — type mismatch!
//! // entities[mesh]; // Won't compile either!
//! ```
//!
//! ## Design notes
//!
//! This mirrors Zig's pattern of using `enum(u32) { _ }` for type-safe indices (e.g.,
//! `Ast.Node.Index = enum(u32) { _ }` in the Zig compiler). Rust doesn't have opaque enums,
//! so we use a newtype struct instead. The compiler optimizes it to a bare `u32`.

use std::fmt;

/// Trait implemented by all typed indices. Allows generic code over different index types.
pub trait TypedIndex: Copy + Eq + Ord + std::hash::Hash + fmt::Debug {
    /// Create from a raw u32.
    fn new(raw: u32) -> Self;

    /// Get the raw u32 value.
    fn raw(self) -> u32;

    /// Get the index as usize (for array indexing).
    #[inline(always)]
    fn idx(self) -> usize {
        self.raw() as usize
    }

    /// A sentinel value representing "no index" / null.
    /// Uses `u32::MAX` which gives you 4,294,967,295 usable indices.
    fn none() -> Self {
        Self::new(u32::MAX)
    }

    /// Check if this is the sentinel "none" value.
    fn is_none(self) -> bool {
        self.raw() == u32::MAX
    }

    /// Check if this is a valid (non-sentinel) index.
    fn is_some(self) -> bool {
        !self.is_none()
    }
}

/// Generate a zero-cost newtype wrapper around `u32` for type-safe indexing.
///
/// ## Generated type
///
/// ```rust,ignore
/// #[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
/// pub struct MyIdx(u32);
///
/// impl MyIdx {
///     pub fn new(raw: u32) -> Self { ... }
///     pub fn raw(self) -> u32 { ... }
///     pub fn idx(self) -> usize { ... }
///     pub fn none() -> Self { ... }       // sentinel value (u32::MAX)
///     pub fn is_none(self) -> bool { ... }
///     pub fn is_some(self) -> bool { ... }
/// }
/// ```
///
/// ## Size
///
/// 4 bytes. Half the size of a pointer on 64-bit systems. If your collection has fewer
/// than ~4 billion items, this is strictly better than a pointer in every dimension:
/// smaller, survives reallocation, serialization-friendly, no aliasing issues.
///
/// ## Comparison to Zig
///
/// Zig: `const NodeIndex = enum(u32) { _ };`
/// Rust: `typed_index!(NodeIndex);`
///
/// Same idea: an opaque wrapper around u32 that the type checker treats as distinct from
/// all other u32-based types.
#[macro_export]
macro_rules! typed_index {
    (
        $(#[$meta:meta])*
        $vis:vis $name:ident
    ) => {
        $(#[$meta])*
        #[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        #[repr(transparent)]
        $vis struct $name(u32);

        impl $name {
            /// Create a new typed index from a raw u32.
            #[inline(always)]
            pub const fn new(raw: u32) -> Self {
                Self(raw)
            }

            /// Get the raw u32 value.
            #[inline(always)]
            pub const fn raw(self) -> u32 {
                self.0
            }

            /// Get as usize for direct array indexing.
            #[inline(always)]
            pub const fn idx(self) -> usize {
                self.0 as usize
            }

            /// Sentinel value representing "no index".
            #[inline(always)]
            pub const fn none() -> Self {
                Self(u32::MAX)
            }

            /// Check if this is the sentinel value.
            #[inline(always)]
            pub const fn is_none(self) -> bool {
                self.0 == u32::MAX
            }

            /// Check if this is a valid (non-sentinel) index.
            #[inline(always)]
            pub const fn is_some(self) -> bool {
                self.0 != u32::MAX
            }
        }

        impl $crate::index::TypedIndex for $name {
            #[inline(always)]
            fn new(raw: u32) -> Self { Self(raw) }
            #[inline(always)]
            fn raw(self) -> u32 { self.0 }
        }

        impl std::fmt::Debug for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                if self.is_none() {
                    write!(f, "{}(NONE)", stringify!($name))
                } else {
                    write!(f, "{}({})", stringify!($name), self.0)
                }
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                if self.is_none() {
                    write!(f, "none")
                } else {
                    write!(f, "{}", self.0)
                }
            }
        }

        impl From<u32> for $name {
            #[inline(always)]
            fn from(raw: u32) -> Self { Self(raw) }
        }

        impl From<$name> for u32 {
            #[inline(always)]
            fn from(idx: $name) -> u32 { idx.0 }
        }

        impl From<usize> for $name {
            #[inline(always)]
            fn from(raw: usize) -> Self { Self(raw as u32) }
        }
    };
}

/// A `Vec` wrapper that is indexed by a `TypedIndex` type instead of `usize`.
/// Prevents mixing up different index types at compile time.
///
/// ```rust
/// use bigospice_utility::{typed_index, index::IndexVec};
///
/// typed_index!(pub EntityIdx);
/// typed_index!(pub MeshIdx);
///
/// let mut entities: IndexVec<EntityIdx, String> = IndexVec::new();
/// let idx = entities.push("player".to_string());
///
/// // entities.get(MeshIdx::new(0)); // Compile error! Wrong index type.
/// assert_eq!(entities.get(idx), Some(&"player".to_string()));
/// ```
#[derive(Debug, Clone)]
pub struct IndexVec<I: TypedIndex, T> {
    inner: Vec<T>,
    _phantom: std::marker::PhantomData<I>,
}

impl<I: TypedIndex, T> IndexVec<I, T> {
    pub fn new() -> Self {
        Self {
            inner: Vec::new(),
            _phantom: std::marker::PhantomData,
        }
    }

    pub fn with_capacity(cap: usize) -> Self {
        Self {
            inner: Vec::with_capacity(cap),
            _phantom: std::marker::PhantomData,
        }
    }

    /// Push an item, returning its typed index.
    pub fn push(&mut self, value: T) -> I {
        let idx = self.inner.len();
        self.inner.push(value);
        I::new(idx as u32)
    }

    /// Get a reference by typed index.
    #[inline]
    pub fn get(&self, idx: I) -> Option<&T> {
        self.inner.get(idx.idx())
    }

    /// Get a mutable reference by typed index.
    #[inline]
    pub fn get_mut(&mut self, idx: I) -> Option<&mut T> {
        self.inner.get_mut(idx.idx())
    }

    /// Index directly (panics on out of bounds).
    #[inline]
    pub fn at(&self, idx: I) -> &T {
        &self.inner[idx.idx()]
    }

    /// Mutable index directly.
    #[inline]
    pub fn at_mut(&mut self, idx: I) -> &mut T {
        &mut self.inner[idx.idx()]
    }

    pub fn len(&self) -> usize {
        self.inner.len()
    }

    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    /// Get the underlying slice.
    pub fn as_slice(&self) -> &[T] {
        &self.inner
    }

    /// Get the underlying mutable slice.
    pub fn as_mut_slice(&mut self) -> &mut [T] {
        &mut self.inner
    }

    pub fn iter(&self) -> impl Iterator<Item = (I, &T)> {
        self.inner
            .iter()
            .enumerate()
            .map(|(i, v)| (I::new(i as u32), v))
    }

    pub fn clear(&mut self) {
        self.inner.clear();
    }
}

impl<I: TypedIndex, T> Default for IndexVec<I, T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<I: TypedIndex, T> std::ops::Index<I> for IndexVec<I, T> {
    type Output = T;
    #[inline]
    fn index(&self, idx: I) -> &T {
        &self.inner[idx.idx()]
    }
}

impl<I: TypedIndex, T> std::ops::IndexMut<I> for IndexVec<I, T> {
    #[inline]
    fn index_mut(&mut self, idx: I) -> &mut T {
        &mut self.inner[idx.idx()]
    }
}
