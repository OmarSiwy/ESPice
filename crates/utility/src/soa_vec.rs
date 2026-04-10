/// Structure-of-Arrays container for data-oriented batch processing.
///
/// Stores `num_fields` parallel arrays of `f64`, each of length `len`.
/// Memory layout: field-major (all values of field 0, then all of field 1, ...).
/// This is optimal for SIMD processing across instances of the same field.
#[derive(Debug, Clone)]
pub struct SoaVec {
    storage: Vec<f64>,
    num_fields: usize,
    len: usize,
}

impl SoaVec {
    pub fn new(num_fields: usize) -> Self {
        Self {
            storage: Vec::new(),
            num_fields,
            len: 0,
        }
    }

    pub fn with_capacity(num_fields: usize, capacity: usize) -> Self {
        Self {
            storage: vec![0.0; num_fields * capacity],
            num_fields,
            len: 0,
        }
    }

    pub fn zeros(num_fields: usize, len: usize) -> Self {
        Self {
            storage: vec![0.0; num_fields * len],
            num_fields,
            len,
        }
    }

    #[inline]
    pub fn num_fields(&self) -> usize {
        self.num_fields
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.len
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Get a slice of all values for one field.
    #[inline]
    pub fn field(&self, field_idx: usize) -> &[f64] {
        debug_assert!(field_idx < self.num_fields);
        let start = field_idx * self.len;
        &self.storage[start..start + self.len]
    }

    /// Get a mutable slice of all values for one field.
    #[inline]
    pub fn field_mut(&mut self, field_idx: usize) -> &mut [f64] {
        debug_assert!(field_idx < self.num_fields);
        let start = field_idx * self.len;
        &mut self.storage[start..start + self.len]
    }

    /// Get value at (field, index).
    #[inline]
    pub fn get(&self, field_idx: usize, elem_idx: usize) -> f64 {
        self.storage[field_idx * self.len + elem_idx]
    }

    /// Set value at (field, index).
    #[inline]
    pub fn set(&mut self, field_idx: usize, elem_idx: usize, val: f64) {
        self.storage[field_idx * self.len + elem_idx] = val;
    }

    /// Push one row: one value per field.
    pub fn push_row(&mut self, values: &[f64]) {
        assert_eq!(values.len(), self.num_fields);
        let new_len = self.len + 1;
        let new_storage_len = self.num_fields * new_len;

        let mut new_storage = vec![0.0; new_storage_len];

        // Copy existing fields, shifting each to accommodate the new length.
        for f in (0..self.num_fields).rev() {
            let old_start = f * self.len;
            let new_start = f * new_len;
            new_storage[new_start..new_start + self.len]
                .copy_from_slice(&self.storage[old_start..old_start + self.len]);
            new_storage[new_start + self.len] = values[f];
        }

        self.storage = new_storage;
        self.len = new_len;
    }

    /// SIMD axpy on a single field: `field[i] += alpha * src_field[i]`.
    pub fn field_axpy(&mut self, field_idx: usize, alpha: f64, src: &SoaVec, src_field_idx: usize) {
        assert_eq!(self.len, src.len);
        let dst = self.field_mut(field_idx);
        let s = src.field(src_field_idx);
        simd_axpy(alpha, s, dst);
    }

    /// SIMD scale on a single field: `field[i] *= alpha`.
    pub fn field_scale(&mut self, field_idx: usize, alpha: f64) {
        let n = self.len;
        let start = field_idx * n;
        let slice = &mut self.storage[start..start + n];
        simd_scale(alpha, slice);
    }

    /// SIMD dot product on a single field.
    pub fn field_dot(&self, field_a: usize, other: &SoaVec, field_b: usize) -> f64 {
        assert_eq!(self.len, other.len);
        let a = self.field(field_a);
        let b = other.field(field_b);
        simd_dot(a, b)
    }

    /// Fill all values of a field with a constant.
    pub fn field_fill(&mut self, field_idx: usize, val: f64) {
        let slice = self.field_mut(field_idx);
        slice.fill(val);
    }

    /// Clear all data, keeping field count.
    pub fn clear(&mut self) {
        self.storage.clear();
        self.len = 0;
    }
}

fn simd_axpy(alpha: f64, src: &[f64], dst: &mut [f64]) {
    dst.iter_mut()
        .zip(src.iter())
        .for_each(|(d, &s)| *d += alpha * s);
}

fn simd_scale(alpha: f64, data: &mut [f64]) {
    data.iter_mut().for_each(|v| *v *= alpha);
}

fn simd_dot(a: &[f64], b: &[f64]) -> f64 {
    a.iter()
        .zip(b.iter())
        .map(|(&ai, &bi)| ai * bi)
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zeros_layout() {
        let v = SoaVec::zeros(3, 4);
        assert_eq!(v.num_fields(), 3);
        assert_eq!(v.len(), 4);
        for f in 0..3 {
            assert!(v.field(f).iter().all(|&x| x == 0.0));
        }
    }

    #[test]
    fn get_set() {
        let mut v = SoaVec::zeros(2, 5);
        v.set(0, 3, 42.0);
        v.set(1, 1, -7.0);
        assert_eq!(v.get(0, 3), 42.0);
        assert_eq!(v.get(1, 1), -7.0);
        assert_eq!(v.get(0, 0), 0.0);
    }

    #[test]
    fn push_row() {
        let mut v = SoaVec::new(3);
        v.push_row(&[1.0, 2.0, 3.0]);
        v.push_row(&[4.0, 5.0, 6.0]);

        assert_eq!(v.len(), 2);
        assert_eq!(v.field(0), &[1.0, 4.0]);
        assert_eq!(v.field(1), &[2.0, 5.0]);
        assert_eq!(v.field(2), &[3.0, 6.0]);
    }

    #[test]
    fn field_axpy() {
        let mut a = SoaVec::zeros(2, 8);
        let mut b = SoaVec::zeros(2, 8);

        a.field_fill(0, 1.0);
        b.field_fill(0, 2.0);

        a.field_axpy(0, 3.0, &b, 0);
        assert!(a.field(0).iter().all(|&v| (v - 7.0).abs() < 1e-15));
    }

    #[test]
    fn field_scale() {
        let mut v = SoaVec::zeros(2, 10);
        v.field_fill(1, 4.0);
        v.field_scale(1, 0.25);
        assert!(v.field(1).iter().all(|&x| (x - 1.0).abs() < 1e-15));
    }

    #[test]
    fn field_dot() {
        let mut a = SoaVec::zeros(1, 8);
        let mut b = SoaVec::zeros(1, 8);
        a.field_fill(0, 2.0);
        b.field_fill(0, 3.0);
        assert!((a.field_dot(0, &b, 0) - 48.0).abs() < 1e-12);
    }

    #[test]
    fn non_aligned_length() {
        let mut v = SoaVec::zeros(2, 7);
        v.field_fill(0, 5.0);
        v.field_scale(0, 2.0);
        assert!(v.field(0).iter().all(|&x| (x - 10.0).abs() < 1e-15));
    }

    #[test]
    fn clear_resets() {
        let mut v = SoaVec::zeros(3, 100);
        v.clear();
        assert_eq!(v.len(), 0);
        assert!(v.is_empty());
        assert_eq!(v.num_fields(), 3);
    }
}
