//! # Arena — Bump Allocator for Phase-Scoped Data
//!
//! An arena allocator groups allocations into a single contiguous buffer and frees them all
//! at once. There is no per-object deallocation. This makes allocation extremely fast (just
//! increment a pointer) and is ideal for data that has a clear lifetime scope:
//!
//! - **Frame-scoped:** game engines allocate per-frame scratch data, reset every frame
//! - **Phase-scoped:** compilers allocate AST nodes during parsing, free after codegen
//! - **Request-scoped:** web servers allocate per-request data, free after response
//!
//! ## Performance characteristics
//!
//! - **Allocation:** O(1) — bump a pointer, no free-list traversal
//! - **Deallocation:** O(1) — reset the pointer, no per-object Drop
//! - **Memory overhead:** ~0 per allocation (no headers, no bookkeeping per item)
//! - **Cache behavior:** excellent — sequential allocations are contiguous in memory
//!
//! ## Comparison to general-purpose allocators
//!
//! | Property           | `malloc`/`Box`  | Arena          |
//! |--------------------|-----------------|----------------|
//! | Alloc cost         | O(log n)        | O(1)           |
//! | Free cost          | O(log n)        | O(1) amortized |
//! | Per-item overhead  | 8-16 bytes      | 0-7 bytes (alignment padding only) |
//! | Fragmentation      | yes             | no             |
//! | Individual free    | yes             | no             |
//!
//! ## Usage
//!
//! ```rust
//! use bigospice_utility::Arena;
//!
//! let mut arena = Arena::new(4096); // 4KB initial block
//!
//! // Allocate values — fast bump allocation
//! let x = arena.alloc(42u32);
//! let y = arena.alloc(3.14f64);
//! let name = arena.alloc_str("hello world");
//!
//! // Allocate slices — contiguous, cache-friendly
//! let positions = arena.alloc_slice_copy(&[1.0f32, 2.0, 3.0, 4.0]);
//! let zeroed = arena.alloc_slice_default::<u64>(1024);
//!
//! // When done with this phase, free everything at once
//! arena.reset();
//! ```

use std::alloc::{self, Layout};

use std::ptr::{self, NonNull};

/// A single block of memory in the arena's chain.
struct Block {
    /// Pointer to the allocated memory.
    ptr: NonNull<u8>,
    /// Layout used for this allocation (needed for dealloc).
    layout: Layout,
}

impl Drop for Block {
    fn drop(&mut self) {
        unsafe {
            alloc::dealloc(self.ptr.as_ptr(), self.layout);
        }
    }
}

/// A bump allocator that allocates from contiguous blocks and frees everything at once.
///
/// ## Memory layout
///
/// The arena maintains a chain of blocks. Allocations bump a cursor forward within the
/// current block. When a block is exhausted, a new (larger) block is allocated. On `reset()`,
/// all blocks except the first are freed, and the cursor returns to the start.
///
/// ```text
/// Block 0: [████████████░░░░░░░░]  ← cursor is here
///           ^ allocated   ^ free
///
/// After reset:
/// Block 0: [░░░░░░░░░░░░░░░░░░░░]  ← cursor back to start
///           ^ all free
/// ```
pub struct Arena {
    blocks: Vec<Block>,
    cursor: usize,
    block_size: usize,
    current_block: usize,
    total_allocated: usize,
}

impl Arena {
    /// Create a new arena with the given initial block size (in bytes).
    ///
    /// Tip: for frame-scoped game data, 64KB-1MB is a good starting size.
    /// For compiler ASTs, 1MB-16MB. The arena grows automatically if needed.
    pub fn new(block_size: usize) -> Self {
        let block_size = block_size.max(64); // minimum 64 bytes
        let layout = Layout::from_size_align(block_size, 16).expect("invalid layout");
        let ptr = unsafe { alloc::alloc(layout) };
        let ptr = NonNull::new(ptr).expect("arena allocation failed");

        Arena {
            blocks: vec![Block { ptr, layout }],
            cursor: 0,
            block_size,
            current_block: 0,
            total_allocated: 0,
        }
    }

    /// Allocate a single value in the arena. Returns a mutable reference with the arena's lifetime.
    ///
    /// Note: `Drop` is NOT called on arena-allocated values. If `T` has a `Drop` impl that
    /// performs important cleanup (e.g., closing file handles), don't arena-allocate it.
    #[inline]
    pub fn alloc<T>(&mut self, value: T) -> &mut T {
        let layout = Layout::new::<T>();
        let ptr = self.alloc_raw(layout);
        unsafe {
            let typed_ptr = ptr.as_ptr() as *mut T;
            typed_ptr.write(value);
            &mut *typed_ptr
        }
    }

    /// Allocate a slice by copying from an existing slice.
    pub fn alloc_slice_copy<T: Copy>(&mut self, src: &[T]) -> &mut [T] {
        if src.is_empty() {
            return &mut [];
        }
        let layout = Layout::array::<T>(src.len()).expect("slice layout overflow");
        let ptr = self.alloc_raw(layout);
        unsafe {
            let dst = ptr.as_ptr() as *mut T;
            ptr::copy_nonoverlapping(src.as_ptr(), dst, src.len());
            std::slice::from_raw_parts_mut(dst, src.len())
        }
    }

    /// Allocate a zero-initialized slice.
    pub fn alloc_slice_default<T: Default + Copy>(&mut self, count: usize) -> &mut [T] {
        if count == 0 {
            return &mut [];
        }
        let layout = Layout::array::<T>(count).expect("slice layout overflow");
        let ptr = self.alloc_raw(layout);
        unsafe {
            let dst = ptr.as_ptr() as *mut T;
            // Zero the memory (works for numeric defaults)
            ptr::write_bytes(dst, 0, count);
            std::slice::from_raw_parts_mut(dst, count)
        }
    }

    /// Allocate a string slice in the arena.
    pub fn alloc_str(&mut self, s: &str) -> &mut str {
        let bytes = self.alloc_slice_copy(s.as_bytes());
        // SAFETY: we copied valid UTF-8 bytes
        unsafe { std::str::from_utf8_unchecked_mut(bytes) }
    }

    /// Raw allocation: returns aligned memory from the current block, growing if necessary.
    fn alloc_raw(&mut self, layout: Layout) -> NonNull<u8> {
        let align = layout.align();
        let size = layout.size();

        // Align the cursor
        let block = &self.blocks[self.current_block];
        let base = block.ptr.as_ptr() as usize;
        let current = base + self.cursor;
        let aligned = (current + align - 1) & !(align - 1);
        let offset = aligned - base;

        if offset + size <= block.layout.size() {
            // Fits in current block
            self.cursor = offset + size;
            self.total_allocated += size;
            unsafe { NonNull::new_unchecked((base + offset) as *mut u8) }
        } else {
            // Need a new block — double the size or use the requested size, whichever is larger
            self.grow(size.max(self.block_size));
            // Recurse — the new block is guaranteed to fit
            self.alloc_raw(layout)
        }
    }

    /// Allocate a new block and make it current.
    fn grow(&mut self, min_size: usize) {
        let new_size = min_size.max(self.block_size * 2);
        self.block_size = new_size;
        let layout = Layout::from_size_align(new_size, 16).expect("invalid layout");
        let ptr = unsafe { alloc::alloc(layout) };
        let ptr = NonNull::new(ptr).expect("arena growth allocation failed");
        self.blocks.push(Block { ptr, layout });
        self.current_block = self.blocks.len() - 1;
        self.cursor = 0;
    }

    /// Reset the arena, making all allocated memory available for reuse.
    /// Does NOT call Drop on any allocated values.
    ///
    /// This is O(n) in the number of extra blocks allocated (they get freed),
    /// but O(1) amortized if you reserve enough upfront.
    pub fn reset(&mut self) {
        // Keep the first block, free the rest
        self.blocks.truncate(1);
        self.current_block = 0;
        self.cursor = 0;
        self.total_allocated = 0;
    }

    /// Total bytes currently allocated (not including alignment padding).
    pub fn bytes_allocated(&self) -> usize {
        self.total_allocated
    }

    /// Total bytes of backing memory (including unused space in blocks).
    pub fn bytes_reserved(&self) -> usize {
        self.blocks.iter().map(|b| b.layout.size()).sum()
    }
}

impl Drop for Arena {
    fn drop(&mut self) {
        // Blocks are dropped automatically via Vec<Block> Drop
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_alloc() {
        let mut arena = Arena::new(256);
        let x = arena.alloc(42u32);
        assert_eq!(*x, 42);
        let y = arena.alloc(3.14f64);
        assert!((*y - 3.14).abs() < f64::EPSILON);
    }

    #[test]
    fn slice_alloc() {
        let mut arena = Arena::new(256);
        let data = [1.0f32, 2.0, 3.0, 4.0];
        let slice = arena.alloc_slice_copy(&data);
        assert_eq!(slice, &[1.0, 2.0, 3.0, 4.0]);
        slice[0] = 99.0;
        assert_eq!(slice[0], 99.0);
    }

    #[test]
    fn str_alloc() {
        let mut arena = Arena::new(256);
        let s = arena.alloc_str("hello world");
        assert_eq!(s, "hello world");
    }

    #[test]
    fn reset_reuses_memory() {
        let mut arena = Arena::new(256);
        for i in 0..100 {
            arena.alloc(i as u64);
        }
        let _reserved_before = arena.bytes_reserved();
        arena.reset();
        assert_eq!(arena.bytes_allocated(), 0);
        // After reset, first block is retained
        assert!(arena.bytes_reserved() > 0);
    }

    #[test]
    fn growth() {
        let mut arena = Arena::new(64);
        // Allocate way more than 64 bytes
        for i in 0..1000 {
            arena.alloc(i as u64);
        }
        assert!(arena.bytes_allocated() >= 8000);
    }
}
