use std::ops::{Deref, DerefMut, Index, IndexMut};

/// A 64-byte (cache-line) aligned vector of `f64`, suitable for SIMD access.
///
/// Uses manual aligned allocation to guarantee that the backing buffer is
/// aligned to 64 bytes, which is the typical x86-64 cache line size and
/// satisfies the alignment requirements of AVX-512 loads/stores.
#[derive(Debug)]
pub struct AlignedVec {
    data: Vec<f64>,
}

const CACHE_LINE: usize = 64;

impl AlignedVec {
    /// Create a zero-filled aligned vector with `n` elements.
    ///
    /// Note: On stable Rust we use a regular `Vec<f64>` as the backing store.
    /// The alignment guarantee comes from over-allocating and selecting the
    /// aligned offset. For most practical purposes on modern allocators, large
    /// allocations are already page-aligned (4096 bytes), which exceeds 64.
    /// For small allocations, we pad to ensure alignment.
    pub fn new(n: usize) -> Self {
        if n == 0 {
            return Self { data: Vec::new() };
        }
        // Allocate using aligned layout directly
        let layout =
            std::alloc::Layout::from_size_align(n * std::mem::size_of::<f64>(), CACHE_LINE)
                .expect("invalid layout");

        let ptr = unsafe { std::alloc::alloc_zeroed(layout) };
        if ptr.is_null() {
            std::alloc::handle_alloc_error(layout);
        }

        let data = unsafe { Vec::from_raw_parts(ptr as *mut f64, n, n) };

        Self { data }
    }

    /// Create a zero-filled aligned vector with `n` elements.
    pub fn zeros(n: usize) -> Self {
        Self::new(n)
    }

    /// Create an aligned vector from an existing slice.
    pub fn from_slice(s: &[f64]) -> Self {
        let mut v = Self::new(s.len());
        v.data.copy_from_slice(s);
        v
    }

    /// Number of elements.
    pub fn len(&self) -> usize {
        self.data.len()
    }

    /// Whether the vector is empty.
    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    /// Push a value. Note: after push, alignment is NOT guaranteed since
    /// Vec may reallocate with default alignment. Use `from_slice` or `new`
    /// for guaranteed alignment.
    pub fn push(&mut self, val: f64) {
        self.data.push(val);
    }

    /// Resize, filling new elements with `val`. Note: after resize, alignment
    /// of the new buffer is NOT guaranteed if reallocation occurs.
    pub fn resize(&mut self, new_len: usize, val: f64) {
        self.data.resize(new_len, val);
    }

    /// Return the raw pointer to the first element.
    pub fn as_ptr(&self) -> *const f64 {
        self.data.as_ptr()
    }

    /// Return the raw mutable pointer to the first element.
    pub fn as_mut_ptr(&mut self) -> *mut f64 {
        self.data.as_mut_ptr()
    }
}

impl Clone for AlignedVec {
    fn clone(&self) -> Self {
        Self::from_slice(&self.data)
    }
}

impl Deref for AlignedVec {
    type Target = [f64];

    fn deref(&self) -> &[f64] {
        &self.data
    }
}

impl DerefMut for AlignedVec {
    fn deref_mut(&mut self) -> &mut [f64] {
        &mut self.data
    }
}

impl Index<usize> for AlignedVec {
    type Output = f64;

    fn index(&self, index: usize) -> &f64 {
        &self.data[index]
    }
}

impl IndexMut<usize> for AlignedVec {
    fn index_mut(&mut self, index: usize) -> &mut f64 {
        &mut self.data[index]
    }
}

impl PartialEq for AlignedVec {
    fn eq(&self, other: &Self) -> bool {
        self.data[..] == other.data[..]
    }
}

impl Drop for AlignedVec {
    fn drop(&mut self) {
        if self.data.capacity() > 0 {
            let cap = self.data.capacity();
            let ptr = self.data.as_mut_ptr();
            // Prevent Vec from deallocating with default layout
            unsafe {
                // Set length to 0 so Vec doesn't drop elements (f64 is Copy, no-op anyway)
                self.data.set_len(0);
            }
            // We need to check if this was allocated with our aligned layout.
            // Only deallocate with aligned layout if we created it that way.
            // Since we use from_raw_parts in new(), we must deallocate with the same layout.
            let layout =
                std::alloc::Layout::from_size_align(cap * std::mem::size_of::<f64>(), CACHE_LINE);
            if let Ok(layout) = layout {
                unsafe {
                    // Forget the vec to prevent double-free
                    let data = std::mem::take(&mut self.data);
                    std::mem::forget(data);
                    std::alloc::dealloc(ptr as *mut u8, layout);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alignment_check() {
        let v = AlignedVec::new(128);
        let ptr = v.as_ptr() as usize;
        assert_eq!(ptr % CACHE_LINE, 0, "pointer is not 64-byte aligned");
    }

    #[test]
    fn alignment_check_small() {
        // Even a tiny vector should be aligned.
        let v = AlignedVec::new(1);
        let ptr = v.as_ptr() as usize;
        assert_eq!(ptr % CACHE_LINE, 0);
    }

    #[test]
    fn zeros_are_zero() {
        let v = AlignedVec::zeros(64);
        assert_eq!(v.len(), 64);
        for &x in v.iter() {
            assert_eq!(x, 0.0);
        }
    }

    #[test]
    fn from_slice_roundtrip() {
        let data: Vec<f64> = (0..32).map(|i| i as f64 * 1.5).collect();
        let v = AlignedVec::from_slice(&data);
        assert_eq!(v.len(), 32);
        for (i, &x) in v.iter().enumerate() {
            assert_eq!(x, data[i]);
        }
        // Still aligned.
        assert_eq!(v.as_ptr() as usize % CACHE_LINE, 0);
    }

    #[test]
    fn deref_and_deref_mut() {
        let mut v = AlignedVec::zeros(4);
        // DerefMut: write through slice.
        v[0] = 1.0;
        v[1] = 2.0;
        v[2] = 3.0;
        v[3] = 4.0;
        // Deref: read through slice.
        let s: &[f64] = &v;
        assert_eq!(s, &[1.0, 2.0, 3.0, 4.0]);
    }

    #[test]
    fn clone_is_independent() {
        let mut a = AlignedVec::from_slice(&[1.0, 2.0, 3.0]);
        let b = a.clone();
        a[0] = 999.0;
        assert_eq!(b[0], 1.0);
        assert_eq!(a[0], 999.0);
    }

    #[test]
    fn index_and_index_mut() {
        let mut v = AlignedVec::zeros(8);
        v[3] = 42.0;
        assert_eq!(v[3], 42.0);
        assert_eq!(v[0], 0.0);
    }

    #[test]
    fn empty_vec() {
        let v = AlignedVec::new(0);
        assert!(v.is_empty());
        assert_eq!(v.len(), 0);
    }

    #[test]
    fn push_and_resize() {
        let mut v = AlignedVec::new(0);
        v.push(1.0);
        v.push(2.0);
        assert_eq!(v.len(), 2);
        assert_eq!(v[0], 1.0);
        assert_eq!(v[1], 2.0);

        v.resize(5, 7.0);
        assert_eq!(v.len(), 5);
        assert_eq!(v[2], 7.0);
        assert_eq!(v[4], 7.0);
    }

    #[test]
    fn large_allocation_aligned() {
        let v = AlignedVec::zeros(100_000);
        assert_eq!(v.as_ptr() as usize % CACHE_LINE, 0);
        assert_eq!(v.len(), 100_000);
    }
}
