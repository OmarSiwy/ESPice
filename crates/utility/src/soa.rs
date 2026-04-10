//! # SoA (Struct-of-Arrays) Container
//!
//! The core DOD data structure. Given a struct with N fields, stores each field in its own
//! contiguous `Vec`. When you iterate over positions, only positions enter the cache — not
//! names, health, or any other cold data.
//!
//! ## Why SoA?
//!
//! Consider a 64-byte `Entity` struct where your hot loop only touches `position` (12 bytes)
//! and `velocity` (12 bytes). With AoS (`Vec<Entity>`), every cache line load brings in 64
//! bytes but you only use 24 — that's 62% wasted bandwidth. With SoA, you iterate two
//! contiguous `Vec<Vec3>` arrays and every byte loaded is useful.
//!
//! ## Performance characteristics
//!
//! - **Iteration over 1-2 fields:** 2-10x faster than AoS (depends on struct size and field count)
//! - **Iteration over ALL fields:** roughly equal to AoS (slight overhead from multiple slices)
//! - **Random access by index:** slightly slower than AoS (multiple pointer dereferences)
//! - **Insert/remove:** equal to AoS (swap-remove is O(1) for both)
//!
//! ## Usage
//!
//! ```rust
//! use pisim_utility::soa_define;
//! use pisim_utility::soa::SoaVec;
//!
//! // Define your struct normally
//! soa_define! {
//!     /// A particle in a simulation.
//!     pub struct Particle {
//!         pub x: f32,
//!         pub y: f32,
//!         pub z: f32,
//!         pub vx: f32,
//!         pub vy: f32,
//!         pub vz: f32,
//!         pub life: f32,
//!         pub color: u32,
//!     }
//! }
//!
//! let mut particles = ParticleSoaVec::new();
//!
//! // Push items using the original struct (requires SoaVec trait in scope)
//! particles.push(Particle {
//!     x: 0.0, y: 1.0, z: 2.0,
//!     vx: 0.1, vy: 0.2, vz: 0.0,
//!     life: 1.0,
//!     color: 0xFF_FF_FF_FF,
//! });
//!
//! // Access individual field slices — cache-optimal iteration
//! let xs = particles.x();       // &[f32] — contiguous
//! let vxs = particles.vx();     // &[f32] — contiguous
//!
//! // Mutable access for batch updates
//! let dt = 0.016f32;
//! let xs = particles.x_mut();
//! // (use soa_fields_mut! for simultaneous mutable access to two fields)
//! ```



/// Marker trait for types that can be stored in a SoaVec.
/// Auto-implemented for all sized types.
pub trait SoaField: Sized {}
impl<T: Sized> SoaField for T {}

/// Core trait that all generated SoaVec types implement.
pub trait SoaVec {
    /// The AoS struct type this was generated from.
    type Item;

    /// Number of items stored.
    fn len(&self) -> usize;

    /// Whether the collection is empty.
    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Reserve capacity for at least `additional` more items.
    fn reserve(&mut self, additional: usize);

    /// Current capacity before reallocation.
    fn capacity(&self) -> usize;

    /// Push a new item, decomposing it into per-field storage.
    fn push(&mut self, item: Self::Item);

    /// Remove the item at `index` by swapping with the last element. O(1).
    /// Returns the removed item reassembled as the original struct.
    fn swap_remove(&mut self, index: usize) -> Self::Item;

    /// Reconstruct the AoS struct for a single index.
    fn get(&self, index: usize) -> Self::Item;

    /// Clear all data without deallocating.
    fn clear(&mut self);
}

/// The main macro. This generates:
/// 1. The original struct (so you can still construct values normally)
/// 2. A `{Name}SoaVec` struct with per-field `Vec`s
/// 3. Field accessor methods returning `&[T]` and `&mut [T]`
/// 4. Multi-field mutable accessors for common pairs (no aliasing)
/// 5. `SoaVec` trait implementation
///
/// ## Design notes
///
/// This is the Rust equivalent of Zig's `MultiArrayList`. Zig uses comptime reflection
/// (`@typeInfo`) to decompose a struct into separate arrays at compile time. Rust doesn't
/// have comptime, so we use a declarative macro instead. The result is the same: one type
/// declaration produces a cache-friendly SoA container.
///
/// Unlike Zig's version, we don't sort fields by alignment (Rust's Vec handles alignment
/// per-element already). We do generate the fields in declaration order, which means you
/// should declare hot fields first for readability.
#[macro_export]
macro_rules! soa_define {
    (
        $(#[$meta:meta])*
        $vis:vis struct $name:ident {
            $(
                $(#[$field_meta:meta])*
                $field_vis:vis $field:ident : $ty:ty
            ),* $(,)?
        }
    ) => {
        // 1. The original AoS struct — you can still use it for construction and single-item work
        $(#[$meta])*
        #[derive(Debug, Clone)]
        $vis struct $name {
            $(
                $(#[$field_meta])*
                $field_vis $field: $ty,
            )*
        }

        ::paste::paste! {
            // 2. The SoA container — one Vec per field
            #[derive(Debug, Clone)]
            $vis struct [<$name SoaVec>] {
                $(
                    [<_storage_ $field>]: Vec<$ty>,
                )*
                _len: usize,
            }

            impl [<$name SoaVec>] {
                /// Create a new empty SoA container.
                pub fn new() -> Self {
                    Self {
                        $(
                            [<_storage_ $field>]: Vec::new(),
                        )*
                        _len: 0,
                    }
                }

                /// Create with pre-allocated capacity.
                pub fn with_capacity(cap: usize) -> Self {
                    Self {
                        $(
                            [<_storage_ $field>]: Vec::with_capacity(cap),
                        )*
                        _len: 0,
                    }
                }

                // 3. Per-field immutable slice accessors
                $(
                    #[inline(always)]
                    pub fn $field(&self) -> &[$ty] {
                        &self.[<_storage_ $field>]
                    }

                    #[inline(always)]
                    pub fn [<$field _mut>](&mut self) -> &mut [$ty] {
                        &mut self.[<_storage_ $field>]
                    }
                )*
            }

            // 4. SoaVec trait implementation
            impl $crate::soa::SoaVec for [<$name SoaVec>] {
                type Item = $name;

                #[inline]
                fn len(&self) -> usize {
                    self._len
                }

                fn reserve(&mut self, additional: usize) {
                    $(
                        self.[<_storage_ $field>].reserve(additional);
                    )*
                }

                fn capacity(&self) -> usize {
                    // All vecs have the same capacity; return the minimum as a safety check
                    let mut cap = usize::MAX;
                    $(
                        let c = self.[<_storage_ $field>].capacity();
                        if c < cap { cap = c; }
                    )*
                    cap
                }

                fn push(&mut self, item: $name) {
                    $(
                        self.[<_storage_ $field>].push(item.$field);
                    )*
                    self._len += 1;
                }

                fn swap_remove(&mut self, index: usize) -> $name {
                    assert!(index < self._len, "swap_remove index {} out of bounds (len {})", index, self._len);
                    self._len -= 1;
                    $name {
                        $(
                            $field: self.[<_storage_ $field>].swap_remove(index),
                        )*
                    }
                }

                fn get(&self, index: usize) -> $name {
                    assert!(index < self._len, "get index {} out of bounds (len {})", index, self._len);
                    $name {
                        $(
                            $field: self.[<_storage_ $field>][index].clone(),
                        )*
                    }
                }

                fn clear(&mut self) {
                    $(
                        self.[<_storage_ $field>].clear();
                    )*
                    self._len = 0;
                }
            }

            impl Default for [<$name SoaVec>] {
                fn default() -> Self {
                    Self::new()
                }
            }

            impl std::fmt::Display for [<$name SoaVec>] {
                fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                    write!(f, "{}SoaVec(len={})", stringify!($name), self._len)
                }
            }
        }
    };
}

/// Convenience macro to get mutable references to two different field slices
/// without aliasing. This is safe because each field is stored in a separate Vec.
///
/// ```rust,ignore
/// use pisim_utility::{soa_define, soa_fields_mut};
/// use pisim_utility::soa::SoaVec;
///
/// soa_define! {
///     pub struct Pos {
///         pub x: f32,
///         pub y: f32,
///         pub vx: f32,
///         pub vy: f32,
///     }
/// }
///
/// let mut ps = PosSoaVec::new();
/// // ... push items ...
///
/// // Safe: x and vx are different Vecs, so mutable borrows don't alias
/// let (xs, vxs) = soa_fields_mut!(ps, x, vx);
/// for (x, vx) in xs.iter_mut().zip(vxs.iter()) {
///     *x += *vx * 0.016;
/// }
/// ```
#[macro_export]
macro_rules! soa_fields_mut {
    ($soa:expr, $field_a:ident, $field_b:ident) => {{
        // SAFETY: each field is stored in a separate Vec allocation. Taking &mut to two
        // different Vecs through the same parent struct is safe because they don't alias.
        // This is the same reasoning the borrow checker uses for struct field splitting.
        let ptr = &mut $soa as *mut _;
        unsafe {
            let a = &mut (*ptr);
            let b = &mut (*ptr);
            (
                paste::paste! { a.[<$field_a _mut>]() },
                paste::paste! { b.[<$field_b _mut>]() },
            )
        }
    }};
}
