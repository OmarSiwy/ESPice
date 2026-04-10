/// Typed arena allocator for simulation temporaries.
///
/// Pre-allocates a contiguous buffer of `T` and hands out references.
/// Call [`reset`] between simulation steps to reclaim all slots without
/// deallocating. Zero per-element allocation overhead on the hot path.
#[derive(Debug)]
pub struct TypedArena<T> {
    storage: Vec<T>,
    cursor: usize,
}

impl<T: Default + Clone> TypedArena<T> {
    pub fn new(capacity: usize) -> Self {
        Self {
            storage: vec![T::default(); capacity],
            cursor: 0,
        }
    }

    /// Allocate one slot, returning a mutable reference.
    ///
    /// Grows the backing store if at capacity.
    pub fn alloc(&mut self) -> &mut T {
        if self.cursor >= self.storage.len() {
            self.storage.push(T::default());
        }
        let idx = self.cursor;
        self.storage[idx] = T::default();
        self.cursor += 1;
        &mut self.storage[idx]
    }

    /// Allocate `n` contiguous slots, returning a mutable slice.
    pub fn alloc_slice(&mut self, n: usize) -> &mut [T] {
        let needed = self.cursor + n;
        if needed > self.storage.len() {
            self.storage.resize(needed, T::default());
        }
        let start = self.cursor;
        for i in start..start + n {
            self.storage[i] = T::default();
        }
        self.cursor += n;
        &mut self.storage[start..start + n]
    }

    /// Reclaim all slots without deallocating.
    pub fn reset(&mut self) {
        self.cursor = 0;
    }

    /// Number of currently allocated slots.
    #[inline]
    pub fn allocated(&self) -> usize {
        self.cursor
    }

    /// Total capacity of the backing store.
    #[inline]
    pub fn capacity(&self) -> usize {
        self.storage.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alloc_and_reset() {
        let mut arena = TypedArena::<f64>::new(4);
        let a = arena.alloc();
        *a = 42.0;
        let b = arena.alloc();
        *b = 99.0;

        assert_eq!(arena.allocated(), 2);
        arena.reset();
        assert_eq!(arena.allocated(), 0);

        let c = arena.alloc();
        assert_eq!(*c, 0.0);
    }

    #[test]
    fn alloc_slice_contiguous() {
        let mut arena = TypedArena::<f64>::new(16);
        let s = arena.alloc_slice(4);
        assert_eq!(s.len(), 4);
        s[0] = 1.0;
        s[3] = 4.0;

        let s2 = arena.alloc_slice(3);
        assert_eq!(s2.len(), 3);
        assert_eq!(arena.allocated(), 7);
    }

    #[test]
    fn grows_on_demand() {
        let mut arena = TypedArena::<u32>::new(2);
        arena.alloc();
        arena.alloc();
        arena.alloc(); // exceeds initial capacity
        assert_eq!(arena.allocated(), 3);
        assert!(arena.capacity() >= 3);
    }

    #[test]
    fn reset_preserves_capacity() {
        let mut arena = TypedArena::<f64>::new(8);
        for _ in 0..8 {
            arena.alloc();
        }
        let cap = arena.capacity();
        arena.reset();
        assert_eq!(arena.capacity(), cap);
        assert_eq!(arena.allocated(), 0);
    }

    #[test]
    fn default_values_on_alloc() {
        let mut arena = TypedArena::<f64>::new(4);
        {
            let v = arena.alloc();
            *v = 999.0;
        }
        arena.reset();
        let v = arena.alloc();
        assert_eq!(*v, 0.0);
    }
}
