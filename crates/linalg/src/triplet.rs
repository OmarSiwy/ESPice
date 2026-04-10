use crate::csc::CscMatrix;

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
    ///
    /// All three arrays (`row_idx`, `col_idx`, `vals`) are grown in lockstep,
    /// so the row_idx capacity is representative of the whole triplet's
    /// allocation headroom.
    #[inline]
    pub fn capacity(&self) -> usize {
        self.row_idx.capacity()
    }

    /// Add (accumulate) a value at `(row, col)`.  Duplicates are summed when
    /// converting to CSC.
    ///
    /// Indices are stored as `u32`.  In debug builds we assert that the
    /// caller-provided `usize` indices fit; in release builds the cast is
    /// unchecked, matching the previous behavior.
    #[inline]
    pub fn add(&mut self, row: usize, col: usize, value: f64) {
        debug_assert!(row < self.nrows, "row {row} out of bounds (nrows={})", self.nrows);
        debug_assert!(col < self.ncols, "col {col} out of bounds (ncols={})", self.ncols);
        debug_assert!(row <= u32::MAX as usize, "row index {row} exceeds u32::MAX");
        debug_assert!(col <= u32::MAX as usize, "col index {col} exceeds u32::MAX");
        self.row_idx.push(row as u32);
        self.col_idx.push(col as u32);
        self.vals.push(value);
    }

    /// Add a batch of entries from three parallel slices.  All three slices
    /// must have the same length.  This is the SoA-friendly bulk insertion
    /// path: callers that already have separate row / col / value arrays
    /// (e.g. cached device stamps) can hand them over directly without
    /// re-zipping into tuples.
    #[inline]
    pub fn add_batch(&mut self, rows: &[u32], cols: &[u32], values: &[f64]) {
        assert_eq!(rows.len(), cols.len(), "add_batch: rows/cols length mismatch");
        assert_eq!(rows.len(), values.len(), "add_batch: rows/values length mismatch");
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

    /// Direct access to the row index field as `u32`.  This is the SoA fast
    /// path: a tight loop that only needs row indices loads only this slice
    /// into cache.
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
    ///
    /// Returns an iterator that synthesizes the tuple from the three SoA
    /// arrays on the fly — no intermediate `Vec<(usize, usize, f64)>` is ever
    /// materialized.  Callers that only need one field should prefer
    /// [`row_idx`](Self::row_idx) / [`col_idx`](Self::col_idx) /
    /// [`vals`](Self::vals) for tighter cache behavior.
    #[inline]
    pub fn entries(&self) -> impl Iterator<Item = (usize, usize, f64)> + '_ {
        self.row_idx
            .iter()
            .zip(self.col_idx.iter())
            .zip(self.vals.iter())
            .map(|((&r, &c), &v)| (r as usize, c as usize, v))
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
        assert_eq!(t.nnz(), 3); // stored as 3 entries

        // After CSC conversion they should be summed
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
        // Build a small matrix:
        //  [1  0  2]
        //  [0  3  0]
        //  [4  0  5]
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

    // -----------------------------------------------------------------------
    // SoA correctness tests (added with the AoS->SoA refactor)
    // -----------------------------------------------------------------------

    /// Round-trip: build a moderately large matrix with many entries, convert
    /// to CSC, and verify every entry is in the right place.
    #[test]
    fn test_soa_roundtrip_csc() {
        // Deterministic pseudo-random fill of a 16x16 matrix.
        let n = 16;
        let mut t = TripletMatrix::new(n, n);
        // Use a simple LCG so the test is reproducible without `rand`.
        let mut rng = 0x12345678u32;
        let mut next = || {
            rng = rng.wrapping_mul(1664525).wrapping_add(1013904223);
            rng
        };

        // Reference: parallel AoS-style storage we will compare against.
        let mut reference: Vec<(usize, usize, f64)> = Vec::with_capacity(100);
        for _ in 0..100 {
            let r = (next() as usize) % n;
            let c = (next() as usize) % n;
            let v = ((next() & 0xFFFF) as f64) / 1024.0 - 32.0;
            t.add(r, c, v);
            reference.push((r, c, v));
        }

        // Sanity: SoA arrays match the reference order exactly.
        assert_eq!(t.nnz(), reference.len());
        for (i, &(r, c, v)) in reference.iter().enumerate() {
            assert_eq!(t.row_idx()[i] as usize, r);
            assert_eq!(t.col_idx()[i] as usize, c);
            assert_eq!(t.vals()[i], v);
        }

        // CSC conversion: every entry must show up in the dense reconstruction
        // with the correct (possibly summed) value.
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

    /// Duplicate entries at the same coordinate must accumulate to a single
    /// CSC entry.
    #[test]
    fn test_soa_duplicate_accumulation_csc() {
        let mut t = TripletMatrix::new(3, 3);
        t.add(1, 1, 2.0);
        t.add(1, 1, 3.0);
        t.add(0, 2, -1.5);
        t.add(0, 2, 1.5);
        let csc = t.to_csc();
        assert_eq!(csc.get(1, 1), Some(5.0));
        // 0,2 sums to exactly 0 — implementations may keep or drop the slot,
        // both are acceptable provided the value reads as 0.
        assert_eq!(csc.get(0, 2).unwrap_or(0.0), 0.0);
    }

    /// Empty triplet -> empty CSC of correct dimensions.
    #[test]
    fn test_soa_empty_to_csc() {
        let t = TripletMatrix::new(5, 7);
        let csc = t.to_csc();
        assert_eq!(csc.nrows(), 5);
        assert_eq!(csc.ncols(), 7);
        assert_eq!(csc.nnz(), 0);
    }

    /// `clear()` must reset all three SoA arrays without deallocating.
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

        // Refill works correctly after clear.
        t.add(3, 3, 7.0);
        t.add(0, 1, 8.0);
        assert_eq!(t.nnz(), 2);
        assert_eq!(t.row_idx(), &[3u32, 0]);
        assert_eq!(t.col_idx(), &[3u32, 1]);
        assert_eq!(t.vals(), &[7.0, 8.0]);
    }

    /// `add_batch` produces the same result as repeated `add` calls.
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

    /// The synthetic `entries()` iterator must yield the exact tuples a
    /// caller would have seen with the previous AoS layout.
    #[test]
    fn test_soa_entries_iterator() {
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 1, 1.0);
        t.add(2, 0, 2.0);
        t.add(1, 1, 3.0);
        let collected: Vec<(usize, usize, f64)> = t.entries().collect();
        assert_eq!(collected, vec![(0, 1, 1.0), (2, 0, 2.0), (1, 1, 3.0)]);
    }
}
