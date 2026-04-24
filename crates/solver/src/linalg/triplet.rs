use super::csc::CscMatrix;

/// Coordinate (COO / triplet) sparse matrix in **Struct-of-Arrays** layout.
///
/// Entries are conceptually `(row, col, value)` triples, but stored as three
/// parallel arrays so that callers can iterate a single field (e.g. all column
/// indices) without paying for the cache traffic of the others.  Indices are
/// stored as `u32` because circuit MNA dimensions are well below 4 billion;
/// this halves index storage versus `usize` on 64-bit targets and is the
/// canonical DOD win for index-heavy structures.
///
/// Duplicate `(row, col)` pairs are permitted — they are summed during
/// conversion to CSC.
#[derive(Debug, Clone, Default)]
pub struct TripletMatrix {
    nrows: usize,
    ncols: usize,
    /// Row indices (parallel to `col_idx` and `vals`).
    row_idx: Vec<u32>,
    /// Column indices (parallel to `row_idx` and `vals`).
    col_idx: Vec<u32>,
    /// Numerical values (parallel to `row_idx` and `col_idx`).
    vals: Vec<f64>,
}

impl TripletMatrix {
    /// Create an empty triplet matrix with the given dimensions.
    #[inline]
    pub fn new(nrows: usize, ncols: usize) -> Self {
        Self {
            nrows,
            ncols,
            row_idx: Vec::new(),
            col_idx: Vec::new(),
            vals: Vec::new(),
        }
    }

    /// Create an empty triplet matrix with pre-allocated capacity.
    #[inline]
    pub fn with_capacity(nrows: usize, ncols: usize, capacity: usize) -> Self {
        Self {
            nrows,
            ncols,
            row_idx: Vec::with_capacity(capacity),
            col_idx: Vec::with_capacity(capacity),
            vals: Vec::with_capacity(capacity),
        }
    }

    /// Return the currently allocated capacity of the underlying SoA arrays.
    #[inline]
    pub fn capacity(&self) -> usize {
        self.row_idx.capacity()
    }

    /// Add (accumulate) a value at `(row, col)`.  Duplicates are summed when
    /// converting to CSC.
    #[inline]
    pub fn add(&mut self, row: usize, col: usize, value: f64) {
        debug_assert!(
            row < self.nrows,
            "row {row} out of bounds (nrows={})",
            self.nrows
        );
        debug_assert!(
            col < self.ncols,
            "col {col} out of bounds (ncols={})",
            self.ncols
        );
        debug_assert!(row <= u32::MAX as usize, "row index {row} exceeds u32::MAX");
        debug_assert!(col <= u32::MAX as usize, "col index {col} exceeds u32::MAX");
        self.row_idx.push(row as u32);
        self.col_idx.push(col as u32);
        self.vals.push(value);
    }

    /// Add a batch of entries from three parallel slices.
    #[inline]
    pub fn add_batch(&mut self, rows: &[u32], cols: &[u32], values: &[f64]) {
        assert_eq!(rows.len(), cols.len(), "add_batch: rows/cols length mismatch");
        assert_eq!(
            rows.len(),
            values.len(),
            "add_batch: rows/values length mismatch"
        );
        self.row_idx.extend_from_slice(rows);
        self.col_idx.extend_from_slice(cols);
        self.vals.extend_from_slice(values);
    }

    /// Number of stored entries (including duplicates).
    #[inline]
    pub fn nnz(&self) -> usize {
        self.vals.len()
    }

    /// Number of rows.
    #[inline]
    pub fn nrows(&self) -> usize {
        self.nrows
    }

    /// Number of columns.
    #[inline]
    pub fn ncols(&self) -> usize {
        self.ncols
    }

    /// Direct access to the row index field as `u32`.
    #[inline]
    pub fn row_idx(&self) -> &[u32] {
        &self.row_idx
    }

    /// Direct access to the column index field as `u32`.
    #[inline]
    pub fn col_idx(&self) -> &[u32] {
        &self.col_idx
    }

    /// Direct access to the value field.
    #[inline]
    pub fn vals(&self) -> &[f64] {
        &self.vals
    }

    /// Iterate stored entries as `(row, col, value)` tuples by value.
    #[inline]
    pub fn entries(&self) -> impl Iterator<Item = (usize, usize, f64)> + '_ {
        self.row_idx
            .iter()
            .zip(self.col_idx.iter())
            .zip(self.vals.iter())
            .map(|((&r, &c), &v)| (r as usize, c as usize, v))
    }

    /// Zero all values in entries whose row matches `row`.
    #[inline]
    pub fn zero_row(&mut self, row: usize) {
        let r32 = row as u32;
        for (r, v) in self.row_idx.iter().zip(self.vals.iter_mut()) {
            if *r == r32 {
                *v = 0.0;
            }
        }
    }

    /// Remove all entries without deallocating the backing storage.
    #[inline]
    pub fn clear(&mut self) {
        self.row_idx.clear();
        self.col_idx.clear();
        self.vals.clear();
    }

    /// Convert to compressed sparse column format.  Duplicate entries at the
    /// same `(row, col)` are summed.
    pub fn to_csc(&self) -> CscMatrix {
        CscMatrix::from_triplet(self)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_empty() {
        let t = TripletMatrix::new(3, 3);
        assert_eq!(t.nrows(), 3);
        assert_eq!(t.ncols(), 3);
        assert_eq!(t.nnz(), 0);
        assert!(t.row_idx().is_empty());
        assert!(t.col_idx().is_empty());
        assert!(t.vals().is_empty());
    }

    #[test]
    fn test_add_entries() {
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 1.0);
        t.add(1, 1, 2.0);
        t.add(2, 2, 3.0);
        assert_eq!(t.nnz(), 3);
        assert_eq!(t.row_idx(), &[0u32, 1, 2]);
        assert_eq!(t.col_idx(), &[0u32, 1, 2]);
        assert_eq!(t.vals(), &[1.0, 2.0, 3.0]);
    }

    #[test]
    fn test_accumulate_duplicates() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 1.0);
        t.add(0, 0, 2.0);
        t.add(0, 0, 3.0);
        assert_eq!(t.nnz(), 3);

        let csc = t.to_csc();
        assert_eq!(csc.get(0, 0), Some(6.0));
    }

    #[test]
    fn test_clear() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 1.0);
        t.add(1, 1, 2.0);
        t.clear();
        assert_eq!(t.nnz(), 0);
        assert!(t.row_idx().is_empty());
        assert!(t.col_idx().is_empty());
        assert!(t.vals().is_empty());
    }

    #[test]
    fn test_to_csc_identity() {
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 1.0);
        t.add(1, 1, 1.0);
        t.add(2, 2, 1.0);
        let csc = t.to_csc();
        assert_eq!(csc.nrows(), 3);
        assert_eq!(csc.ncols(), 3);
        assert_eq!(csc.nnz(), 3);
        for i in 0..3 {
            assert_eq!(csc.get(i, i), Some(1.0));
        }
    }

    #[test]
    fn test_to_csc_general() {
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 1.0);
        t.add(0, 2, 2.0);
        t.add(1, 1, 3.0);
        t.add(2, 0, 4.0);
        t.add(2, 2, 5.0);
        let csc = t.to_csc();
        assert_eq!(csc.nnz(), 5);
        assert_eq!(csc.get(0, 0), Some(1.0));
        assert_eq!(csc.get(0, 1), None);
        assert_eq!(csc.get(0, 2), Some(2.0));
        assert_eq!(csc.get(1, 1), Some(3.0));
        assert_eq!(csc.get(2, 0), Some(4.0));
        assert_eq!(csc.get(2, 2), Some(5.0));
    }

    #[test]
    fn test_with_capacity() {
        let t = TripletMatrix::with_capacity(10, 10, 100);
        assert_eq!(t.nnz(), 0);
        assert_eq!(t.nrows(), 10);
    }

    #[test]
    fn test_soa_roundtrip_csc() {
        let n = 16;
        let mut t = TripletMatrix::new(n, n);
        let mut rng = 0x12345678u32;
        let mut next = || {
            rng = rng.wrapping_mul(1664525).wrapping_add(1013904223);
            rng
        };

        let mut reference: Vec<(usize, usize, f64)> = Vec::with_capacity(100);
        for _ in 0..100 {
            let r = (next() as usize) % n;
            let c = (next() as usize) % n;
            let v = ((next() & 0xFFFF) as f64) / 1024.0 - 32.0;
            t.add(r, c, v);
            reference.push((r, c, v));
        }

        assert_eq!(t.nnz(), reference.len());
        for (i, &(r, c, v)) in reference.iter().enumerate() {
            assert_eq!(t.row_idx()[i] as usize, r);
            assert_eq!(t.col_idx()[i] as usize, c);
            assert_eq!(t.vals()[i], v);
        }

        let csc = t.to_csc();
        let mut dense = vec![vec![0.0_f64; n]; n];
        for &(r, c, v) in &reference {
            dense[r][c] += v;
        }
        for r in 0..n {
            for c in 0..n {
                let expected = dense[r][c];
                let got = csc.get(r, c).unwrap_or(0.0);
                assert!(
                    (got - expected).abs() < 1e-12,
                    "mismatch at ({r},{c}): got {got}, expected {expected}",
                );
            }
        }
    }

    #[test]
    fn test_soa_duplicate_accumulation_csc() {
        let mut t = TripletMatrix::new(3, 3);
        t.add(1, 1, 2.0);
        t.add(1, 1, 3.0);
        t.add(0, 2, -1.5);
        t.add(0, 2, 1.5);
        let csc = t.to_csc();
        assert_eq!(csc.get(1, 1), Some(5.0));
        assert_eq!(csc.get(0, 2).unwrap_or(0.0), 0.0);
    }

    #[test]
    fn test_soa_empty_to_csc() {
        let t = TripletMatrix::new(5, 7);
        let csc = t.to_csc();
        assert_eq!(csc.nrows(), 5);
        assert_eq!(csc.ncols(), 7);
        assert_eq!(csc.nnz(), 0);
    }

    #[test]
    fn test_soa_clear_then_refill() {
        let mut t = TripletMatrix::with_capacity(4, 4, 16);
        t.add(0, 0, 1.0);
        t.add(1, 1, 2.0);
        t.add(2, 2, 3.0);
        assert_eq!(t.nnz(), 3);

        t.clear();
        assert_eq!(t.nnz(), 0);
        assert!(t.row_idx().is_empty());
        assert!(t.col_idx().is_empty());
        assert!(t.vals().is_empty());

        t.add(3, 3, 7.0);
        t.add(0, 1, 8.0);
        assert_eq!(t.nnz(), 2);
        assert_eq!(t.row_idx(), &[3u32, 0]);
        assert_eq!(t.col_idx(), &[3u32, 1]);
        assert_eq!(t.vals(), &[7.0, 8.0]);
    }

    #[test]
    fn test_soa_add_batch_equivalent() {
        let rows: [u32; 4] = [0, 1, 2, 1];
        let cols: [u32; 4] = [0, 1, 2, 0];
        let vals: [f64; 4] = [1.0, 2.0, 3.0, -4.0];

        let mut a = TripletMatrix::new(3, 3);
        a.add_batch(&rows, &cols, &vals);

        let mut b = TripletMatrix::new(3, 3);
        for i in 0..rows.len() {
            b.add(rows[i] as usize, cols[i] as usize, vals[i]);
        }

        assert_eq!(a.row_idx(), b.row_idx());
        assert_eq!(a.col_idx(), b.col_idx());
        assert_eq!(a.vals(), b.vals());

        let ca = a.to_csc();
        let cb = b.to_csc();
        assert_eq!(ca, cb);
    }

    #[test]
    fn test_soa_entries_iterator() {
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 1, 1.0);
        t.add(2, 0, 2.0);
        t.add(1, 1, 3.0);
        let collected: Vec<(usize, usize, f64)> = t.entries().collect();
        assert_eq!(collected, vec![(0, 1, 1.0), (2, 0, 2.0), (1, 1, 3.0)]);
    }

    #[test]
    fn test_zero_row_zeroes_correct_entries() {
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 1.0);
        t.add(1, 0, 2.0);
        t.add(0, 1, 3.0);
        t.add(2, 2, 4.0);
        t.zero_row(0);
        // Row 0 entries should be 0.0, others unchanged
        assert_eq!(t.vals()[0], 0.0);
        assert_eq!(t.vals()[1], 2.0);
        assert_eq!(t.vals()[2], 0.0);
        assert_eq!(t.vals()[3], 4.0);
    }

    #[test]
    fn test_zero_row_nonexistent_does_nothing() {
        let mut t = TripletMatrix::new(3, 3);
        t.add(1, 1, 5.0);
        t.zero_row(0); // Row 0 has no entries
        assert_eq!(t.vals()[0], 5.0);
    }

    #[test]
    fn test_with_capacity_preallocates() {
        let t = TripletMatrix::with_capacity(5, 5, 50);
        assert!(t.capacity() >= 50);
        assert_eq!(t.nnz(), 0);
    }

    #[test]
    fn test_entries_iterator_empty() {
        let t = TripletMatrix::new(2, 2);
        let collected: Vec<_> = t.entries().collect();
        assert!(collected.is_empty());
    }

    #[test]
    fn test_add_batch_large() {
        let n = 10u32;
        let rows: Vec<u32> = (0..n).collect();
        let cols: Vec<u32> = (0..n).collect();
        let vals: Vec<f64> = (0..n).map(|i| i as f64).collect();

        let mut t = TripletMatrix::new(n as usize, n as usize);
        t.add_batch(&rows, &cols, &vals);
        assert_eq!(t.nnz(), n as usize);

        let csc = t.to_csc();
        for i in 0..n as usize {
            assert_eq!(csc.get(i, i), Some(i as f64));
        }
    }

    #[test]
    fn test_triplet_negative_values() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, -3.5);
        t.add(1, 1, -7.0);
        let csc = t.to_csc();
        assert_eq!(csc.get(0, 0), Some(-3.5));
        assert_eq!(csc.get(1, 1), Some(-7.0));
    }

    #[test]
    fn test_duplicate_cancellation_to_zero() {
        // Adding equal and opposite values at same position sums to 0
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 5.0);
        t.add(0, 0, -5.0);
        let csc = t.to_csc();
        // The entry exists but value is 0.0
        let val = csc.get(0, 0).unwrap_or(0.0);
        assert!(val.abs() < 1e-15);
    }

    #[test]
    fn test_multiple_fills_after_clear() {
        let mut t = TripletMatrix::with_capacity(3, 3, 9);
        for pass in 0..3u32 {
            t.clear();
            for i in 0..3usize {
                t.add(i, i, (pass + 1) as f64);
            }
            let csc = t.to_csc();
            for i in 0..3 {
                assert_eq!(csc.get(i, i), Some((pass + 1) as f64));
            }
        }
    }

    #[test]
    fn test_triplet_off_diagonal_pattern() {
        // Verify a non-diagonal pattern is correctly represented
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 2, 1.0);
        t.add(2, 0, 2.0);
        let csc = t.to_csc();
        assert_eq!(csc.get(0, 2), Some(1.0));
        assert_eq!(csc.get(2, 0), Some(2.0));
        assert_eq!(csc.get(0, 0), None);
        assert_eq!(csc.get(1, 1), None);
    }
}
