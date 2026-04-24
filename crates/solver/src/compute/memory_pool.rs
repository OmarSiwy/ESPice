use std::cell::RefCell;

/// Arena-style memory pool for simulation temporaries.
///
/// Avoids malloc/free on the hot path by pre-allocating blocks and recycling
/// them through a free list. Call [`reset`] between simulation steps to return
/// all blocks without deallocating.
pub struct MemoryPool {
    /// Each arena is one block of `block_size` bytes.
    arenas: RefCell<Vec<Vec<u8>>>,
    /// Default block size in bytes.
    block_size: usize,
    /// Indices into `arenas` that are currently free.
    free_list: RefCell<Vec<usize>>,
    /// Per-block write cursor — how many bytes have been handed out.
    cursors: RefCell<Vec<usize>>,
}

impl MemoryPool {
    /// Create a new pool whose blocks are each `block_size` bytes.
    pub fn new(block_size: usize) -> Self {
        assert!(block_size > 0, "block_size must be positive");
        Self {
            arenas: RefCell::new(Vec::new()),
            block_size,
            free_list: RefCell::new(Vec::new()),
            cursors: RefCell::new(Vec::new()),
        }
    }

    /// Return the block size.
    pub fn block_size(&self) -> usize {
        self.block_size
    }

    /// Allocate `size` bytes from the pool. Returns a mutable slice.
    ///
    /// If the requested size fits in an existing free block, that block is
    /// reused. Otherwise a new block is allocated (its capacity is
    /// `max(block_size, size)` so oversized requests are supported).
    ///
    /// # Safety
    ///
    /// The returned reference borrows from the internal arena. The caller must
    /// not hold references across a call to [`reset`].
    pub fn alloc(&self, size: usize) -> &mut [u8] {
        assert!(size > 0, "allocation size must be positive");

        let mut arenas = self.arenas.borrow_mut();
        let mut free_list = self.free_list.borrow_mut();
        let mut cursors = self.cursors.borrow_mut();

        // Try to find a free block with enough remaining capacity.
        let mut found_idx = None;
        for (fi, &arena_idx) in free_list.iter().enumerate() {
            let remaining = arenas[arena_idx].len() - cursors[arena_idx];
            if remaining >= size {
                found_idx = Some(fi);
                break;
            }
        }

        let arena_idx = if let Some(fi) = found_idx {
            free_list.swap_remove(fi)
        } else {
            // Allocate a new block.
            let cap = self.block_size.max(size);
            arenas.push(vec![0u8; cap]);
            cursors.push(0);
            arenas.len() - 1
        };

        let cursor = cursors[arena_idx];
        cursors[arena_idx] = cursor + size;

        // If there is remaining space, put it back on the free list.
        let remaining = arenas[arena_idx].len() - cursors[arena_idx];
        if remaining > 0 {
            free_list.push(arena_idx);
        }

        let ptr = arenas[arena_idx].as_mut_ptr();
        // SAFETY: we have exclusive access through the RefCell borrow, and the
        // slice is within bounds because we checked capacity above. The lifetime
        // is tied to the pool (which is borrowed &self), so this is sound as
        // long as the caller does not hold references across `reset`.
        unsafe { std::slice::from_raw_parts_mut(ptr.add(cursor), size) }
    }

    /// Allocate a mutable slice of `count` elements of type `T`.
    ///
    /// The returned memory is zeroed.
    ///
    /// # Panics
    ///
    /// Panics if `T` has alignment greater than 8 (use [`AlignedVec`] for
    /// cache-line-aligned data) or if `count` is zero.
    pub fn alloc_slice<T: Copy + Default>(&self, count: usize) -> &mut [T] {
        assert!(count > 0, "count must be positive");
        let align = std::mem::align_of::<T>();
        assert!(
            align <= 8,
            "alloc_slice only supports types with alignment <= 8; use AlignedVec for larger"
        );

        let elem_size = std::mem::size_of::<T>();
        // Over-allocate by (align - 1) bytes so we can align the pointer.
        let raw_size = elem_size * count + (align - 1);
        let raw = self.alloc(raw_size);
        let raw_ptr = raw.as_mut_ptr();
        let addr = raw_ptr as usize;
        let aligned_addr = (addr + align - 1) & !(align - 1);
        let offset = aligned_addr - addr;

        // SAFETY: aligned_addr is within the allocated region, and we reserved
        // enough bytes for `count * elem_size` after alignment.
        unsafe {
            let aligned_ptr = raw_ptr.add(offset) as *mut T;
            // Zero-initialize.
            std::ptr::write_bytes(aligned_ptr, 0, count);
            std::slice::from_raw_parts_mut(aligned_ptr, count)
        }
    }

    /// Return all blocks to the free list without deallocating.
    ///
    /// After calling this, all previously returned slices are invalidated.
    /// Using them is a logic error (but not UB because the memory is still
    /// live).
    pub fn reset(&self) {
        let arenas = self.arenas.borrow();
        let mut free_list = self.free_list.borrow_mut();
        let mut cursors = self.cursors.borrow_mut();

        free_list.clear();
        for i in 0..arenas.len() {
            cursors[i] = 0;
            free_list.push(i);
        }
    }

    /// Number of blocks currently allocated (both free and in-use).
    pub fn num_blocks(&self) -> usize {
        self.arenas.borrow().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_alloc() {
        let pool = MemoryPool::new(1024);
        let slice = pool.alloc(64);
        assert_eq!(slice.len(), 64);
        // Memory should be zero-initialized (from vec![0u8; ...]).
        assert!(slice.iter().all(|&b| b == 0));
    }

    #[test]
    fn alloc_fills_and_grows() {
        let pool = MemoryPool::new(128);
        // First allocation takes part of the first block.
        let _a = pool.alloc(100);
        // Second allocation: only 28 bytes left in block 0, so this should
        // still fit partially or allocate a new block.
        let b = pool.alloc(64);
        assert_eq!(b.len(), 64);
        // We should have at least 2 blocks now.
        assert!(pool.num_blocks() >= 2);
    }

    #[test]
    fn alloc_oversize() {
        let pool = MemoryPool::new(64);
        // Request more than block_size.
        let s = pool.alloc(256);
        assert_eq!(s.len(), 256);
    }

    #[test]
    fn reset_returns_blocks() {
        let pool = MemoryPool::new(256);
        let _a = pool.alloc(128);
        let _b = pool.alloc(128);
        let blocks_before = pool.num_blocks();

        pool.reset();

        // After reset, no new blocks should be allocated for the same amount.
        let _c = pool.alloc(128);
        let _d = pool.alloc(128);
        assert_eq!(pool.num_blocks(), blocks_before);
    }

    #[test]
    fn reset_and_realloc_yields_zeroed_blocks() {
        let pool = MemoryPool::new(256);
        let a = pool.alloc(64);
        // Write some data.
        for b in a.iter_mut() {
            *b = 0xFF;
        }
        pool.reset();

        // The raw bytes may still be 0xFF (reset does not zero), but
        // alloc_slice should zero-initialize through write_bytes.
        let s: &mut [f64] = pool.alloc_slice(4);
        for v in s.iter() {
            assert_eq!(*v, 0.0);
        }
    }

    #[test]
    fn alloc_slice_f64() {
        let pool = MemoryPool::new(1024);
        let s: &mut [f64] = pool.alloc_slice(16);
        assert_eq!(s.len(), 16);
        // All zeros.
        for v in s.iter() {
            assert_eq!(*v, 0.0);
        }
        // Check alignment.
        let ptr = s.as_ptr() as usize;
        assert_eq!(ptr % std::mem::align_of::<f64>(), 0);
    }

    #[test]
    fn alloc_slice_u32() {
        let pool = MemoryPool::new(512);
        let s: &mut [u32] = pool.alloc_slice(100);
        assert_eq!(s.len(), 100);
        for v in s.iter() {
            assert_eq!(*v, 0);
        }
        let ptr = s.as_ptr() as usize;
        assert_eq!(ptr % std::mem::align_of::<u32>(), 0);
    }

    #[test]
    fn multiple_alloc_slice_in_same_block() {
        let pool = MemoryPool::new(4096);
        let a: &mut [f64] = pool.alloc_slice(8);
        let b: &mut [f64] = pool.alloc_slice(8);
        assert_eq!(a.len(), 8);
        assert_eq!(b.len(), 8);
        // They should not overlap.
        let a_start = a.as_ptr() as usize;
        let a_end = a_start + 8 * std::mem::size_of::<f64>();
        let b_start = b.as_ptr() as usize;
        assert!(b_start >= a_end || a_start >= b_start + 8 * std::mem::size_of::<f64>());
    }

    #[test]
    #[should_panic(expected = "block_size must be positive")]
    fn zero_block_size_panics() {
        let _pool = MemoryPool::new(0);
    }

    #[test]
    #[should_panic(expected = "allocation size must be positive")]
    fn zero_alloc_panics() {
        let pool = MemoryPool::new(64);
        let _s = pool.alloc(0);
    }

    #[test]
    #[should_panic(expected = "count must be positive")]
    fn zero_alloc_slice_panics() {
        let pool = MemoryPool::new(64);
        let _s: &mut [f64] = pool.alloc_slice(0);
    }
}
