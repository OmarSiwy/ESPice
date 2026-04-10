use std::marker::PhantomData;
use std::ops::{Index, IndexMut};

/// Newtype-indexed vector for type-safe indexing.
///
/// Prevents accidental indexing with the wrong ID type. `I` is a phantom
/// index type (e.g. `NodeId`, `DeviceId`) whose `.index()` method returns
/// a `usize`. `T` is the stored value type.
#[derive(Debug, Clone)]
pub struct IndexVec<I, T> {
    data: Vec<T>,
    _phantom: PhantomData<I>,
}

/// Trait for types that can be used as indices into an `IndexVec`.
pub trait Idx {
    fn index(self) -> usize;
    fn from_usize(idx: usize) -> Self;
}

impl<I: Idx, T> IndexVec<I, T> {
    pub fn new() -> Self {
        Self {
            data: Vec::new(),
            _phantom: PhantomData,
        }
    }

    pub fn with_capacity(cap: usize) -> Self {
        Self {
            data: Vec::with_capacity(cap),
            _phantom: PhantomData,
        }
    }

    pub fn push(&mut self, val: T) -> I {
        let idx = self.data.len();
        self.data.push(val);
        I::from_usize(idx)
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.data.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    pub fn get(&self, idx: I) -> Option<&T> {
        self.data.get(idx.index())
    }

    pub fn get_mut(&mut self, idx: I) -> Option<&mut T> {
        self.data.get_mut(idx.index())
    }

    pub fn as_slice(&self) -> &[T] {
        &self.data
    }

    pub fn as_mut_slice(&mut self) -> &mut [T] {
        &mut self.data
    }

    pub fn iter(&self) -> impl Iterator<Item = (I, &T)> {
        self.data
            .iter()
            .enumerate()
            .map(|(i, v)| (I::from_usize(i), v))
    }

    pub fn iter_mut(&mut self) -> impl Iterator<Item = (I, &mut T)> {
        self.data
            .iter_mut()
            .enumerate()
            .map(|(i, v)| (I::from_usize(i), v))
    }

    pub fn clear(&mut self) {
        self.data.clear();
    }
}

impl<I: Idx, T: Default> IndexVec<I, T> {
    pub fn from_len(len: usize) -> Self {
        let mut data = Vec::with_capacity(len);
        for _ in 0..len {
            data.push(T::default());
        }
        Self {
            data,
            _phantom: PhantomData,
        }
    }
}

impl<I: Idx, T> Default for IndexVec<I, T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<I: Idx, T> Index<I> for IndexVec<I, T> {
    type Output = T;

    fn index(&self, idx: I) -> &T {
        &self.data[idx.index()]
    }
}

impl<I: Idx, T> IndexMut<I> for IndexVec<I, T> {
    fn index_mut(&mut self, idx: I) -> &mut T {
        &mut self.data[idx.index()]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Clone, Copy, PartialEq)]
    struct TestId(u32);

    impl Idx for TestId {
        fn index(self) -> usize {
            self.0 as usize
        }
        fn from_usize(idx: usize) -> Self {
            Self(idx as u32)
        }
    }

    #[test]
    fn push_and_index() {
        let mut v = IndexVec::<TestId, f64>::new();
        let a = v.push(1.0);
        let b = v.push(2.0);
        let c = v.push(3.0);

        assert_eq!(v[a], 1.0);
        assert_eq!(v[b], 2.0);
        assert_eq!(v[c], 3.0);
        assert_eq!(v.len(), 3);
    }

    #[test]
    fn index_mut() {
        let mut v = IndexVec::<TestId, f64>::new();
        let a = v.push(0.0);
        v[a] = 42.0;
        assert_eq!(v[a], 42.0);
    }

    #[test]
    fn from_len_default() {
        let v = IndexVec::<TestId, f64>::from_len(5);
        assert_eq!(v.len(), 5);
        for i in 0..5 {
            assert_eq!(v[TestId(i as u32)], 0.0);
        }
    }

    #[test]
    fn get_returns_none_oob() {
        let v = IndexVec::<TestId, u32>::new();
        assert!(v.get(TestId(0)).is_none());
    }

    #[test]
    fn iter_enumerates() {
        let mut v = IndexVec::<TestId, &str>::new();
        v.push("a");
        v.push("b");
        let pairs: Vec<_> = v.iter().collect();
        assert_eq!(pairs[0], (TestId(0), &"a"));
        assert_eq!(pairs[1], (TestId(1), &"b"));
    }

    #[test]
    fn clear_empties() {
        let mut v = IndexVec::<TestId, f64>::new();
        v.push(1.0);
        v.push(2.0);
        v.clear();
        assert!(v.is_empty());
    }
}
