use super::dense_vec::DenseVec;
use super::triplet::TripletMatrix;

/// Compressed Sparse Column (CSC) matrix.
///
/// Data is laid out for cache-friendly column traversal which is ideal for
/// left-looking LU factorisation and sparse matrix-vector products.
///
/// Invariants (maintained by constructors):
/// - `col_ptr.len() == ncols + 1`
/// - `row_idx.len() == values.len() == col_ptr[ncols]`
/// - Row indices within each column are sorted in ascending order.
#[derive(Debug, Clone, PartialEq)]
pub struct CscMatrix {
    nrows: usize,
    ncols: usize,
    /// Column pointers.  Column `j` spans `col_ptr[j]..col_ptr[j+1]`.
    col_ptr: Vec<usize>,
    /// Row indices for non-zero entries.
    row_idx: Vec<usize>,
    /// Non-zero values (parallel to `row_idx`).
    values: Vec<f64>,
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

impl CscMatrix {
    /// Build from raw CSC arrays.  No validation beyond dimension checks.
    pub fn new(
        nrows: usize,
        ncols: usize,
        col_ptr: Vec<usize>,
        row_idx: Vec<usize>,
        values: Vec<f64>,
    ) -> Self {
        assert_eq!(col_ptr.len(), ncols + 1, "col_ptr length mismatch");
        assert_eq!(
            row_idx.len(),
            values.len(),
            "row_idx / values length mismatch"
        );
        assert_eq!(
            col_ptr[ncols],
            values.len(),
            "col_ptr sentinel does not match nnz"
        );
        Self {
            nrows,
            ncols,
            col_ptr,
            row_idx,
            values,
        }
    }

    /// Convert a triplet matrix to CSC, summing duplicate entries.
    pub fn from_triplet(triplet: &TripletMatrix) -> Self {
        let nrows = triplet.nrows();
        let ncols = triplet.ncols();

        if triplet.nnz() == 0 {
            return Self {
                nrows,
                ncols,
                col_ptr: vec![0; ncols + 1],
                row_idx: Vec::new(),
                values: Vec::new(),
            };
        }

        let trip_rows = triplet.row_idx();
        let trip_cols = triplet.col_idx();
        let trip_vals = triplet.vals();

        // --- Step 1: count entries per column ---
        let mut col_counts = vec![0usize; ncols];
        for &c in trip_cols {
            col_counts[c as usize] += 1;
        }

        // --- Step 2: build col_ptr from counts ---
        let mut col_ptr = vec![0usize; ncols + 1];
        for j in 0..ncols {
            col_ptr[j + 1] = col_ptr[j] + col_counts[j];
        }

        // --- Step 3: scatter entries into position ---
        let nnz = col_ptr[ncols];
        let mut row_idx = vec![0usize; nnz];
        let mut values = vec![0.0f64; nnz];
        let mut cursor = col_ptr[..ncols].to_vec();

        for ((&r, &c), &v) in trip_rows.iter().zip(trip_cols.iter()).zip(trip_vals.iter()) {
            let cu = c as usize;
            let pos = cursor[cu];
            row_idx[pos] = r as usize;
            values[pos] = v;
            cursor[cu] += 1;
        }

        // --- Step 4: sort each column by row index ---
        for j in 0..ncols {
            let start = col_ptr[j];
            let end = col_ptr[j + 1];
            if start == end {
                continue;
            }

            let slice_r = &mut row_idx[start..end];
            let slice_v = &mut values[start..end];
            for i in 1..slice_r.len() {
                let mut k = i;
                while k > 0 && slice_r[k - 1] > slice_r[k] {
                    slice_r.swap(k - 1, k);
                    slice_v.swap(k - 1, k);
                    k -= 1;
                }
            }
        }

        // --- Step 5: compress duplicates in-place ---
        let mut new_row_idx = Vec::with_capacity(nnz);
        let mut new_values = Vec::with_capacity(nnz);
        let mut new_col_ptr = vec![0usize; ncols + 1];

        for j in 0..ncols {
            let start = col_ptr[j];
            let end = col_ptr[j + 1];
            let col_start = new_row_idx.len();

            let mut i = start;
            while i < end {
                let r = row_idx[i];
                let mut v = values[i];
                i += 1;
                while i < end && row_idx[i] == r {
                    v += values[i];
                    i += 1;
                }
                new_row_idx.push(r);
                new_values.push(v);
            }
            new_col_ptr[j] = col_start;
        }
        new_col_ptr[ncols] = new_row_idx.len();

        Self {
            nrows,
            ncols,
            col_ptr: new_col_ptr,
            row_idx: new_row_idx,
            values: new_values,
        }
    }

    /// Identity matrix of size `n`.
    pub fn identity(n: usize) -> Self {
        let col_ptr: Vec<usize> = (0..=n).collect();
        let row_idx: Vec<usize> = (0..n).collect();
        let values = vec![1.0; n];
        Self {
            nrows: n,
            ncols: n,
            col_ptr,
            row_idx,
            values,
        }
    }

    /// Zero matrix.
    pub fn zeros(nrows: usize, ncols: usize) -> Self {
        Self {
            nrows,
            ncols,
            col_ptr: vec![0; ncols + 1],
            row_idx: Vec::new(),
            values: Vec::new(),
        }
    }
}

// ---------------------------------------------------------------------------
// Accessors
// ---------------------------------------------------------------------------

impl CscMatrix {
    #[inline]
    pub fn nrows(&self) -> usize {
        self.nrows
    }

    #[inline]
    pub fn ncols(&self) -> usize {
        self.ncols
    }

    /// Number of stored non-zeros.
    #[inline]
    pub fn nnz(&self) -> usize {
        self.col_ptr[self.ncols]
    }

    /// Column pointer array (length `ncols + 1`).
    #[inline]
    pub fn col_ptr(&self) -> &[usize] {
        &self.col_ptr
    }

    /// Row index array (length `nnz`).
    #[inline]
    pub fn row_idx(&self) -> &[usize] {
        &self.row_idx
    }

    /// Value array (length `nnz`).
    #[inline]
    pub fn values(&self) -> &[f64] {
        &self.values
    }

    /// Mutable value array (for numerical refactorisation).
    #[inline]
    pub fn values_mut(&mut self) -> &mut [f64] {
        &mut self.values
    }

    /// Retrieve the value at `(row, col)`, or `None` if the entry is
    /// structurally zero.
    pub fn get(&self, row: usize, col: usize) -> Option<f64> {
        if col >= self.ncols || row >= self.nrows {
            return None;
        }
        let start = self.col_ptr[col];
        let end = self.col_ptr[col + 1];
        match self.row_idx[start..end].binary_search(&row) {
            Ok(offset) => Some(self.values[start + offset]),
            Err(_) => None,
        }
    }

    /// Iterate over non-zeros in column `j` as `(row, value)` pairs.
    pub fn column(&self, j: usize) -> ColumnIter<'_> {
        let start = self.col_ptr[j];
        let end = self.col_ptr[j + 1];
        ColumnIter {
            row_idx: &self.row_idx[start..end],
            values: &self.values[start..end],
            pos: 0,
        }
    }

    /// Iterate over non-zeros in column `j`, yielding `(row, &mut value)`.
    pub fn column_mut(&mut self, j: usize) -> ColumnIterMut<'_> {
        let start = self.col_ptr[j];
        let end = self.col_ptr[j + 1];
        ColumnIterMut {
            row_idx: &self.row_idx[start..end],
            values: &mut self.values[start..end],
            pos: 0,
        }
    }

    /// Range of indices into `row_idx` / `values` for column `j`.
    #[inline]
    pub fn col_range(&self, j: usize) -> std::ops::Range<usize> {
        self.col_ptr[j]..self.col_ptr[j + 1]
    }
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

impl CscMatrix {
    /// Sparse matrix - dense vector product: `y = A * x`.
    pub fn mul_vec(&self, x: &DenseVec) -> DenseVec {
        assert_eq!(self.ncols, x.len(), "mul_vec: dimension mismatch");
        let mut y = DenseVec::zeros(self.nrows);
        for j in 0..self.ncols {
            let xj = x[j];
            if xj == 0.0 {
                continue;
            }
            let start = self.col_ptr[j];
            let end = self.col_ptr[j + 1];
            for idx in start..end {
                y[self.row_idx[idx]] += self.values[idx] * xj;
            }
        }
        y
    }

    /// Transpose: return A^T as a new CSC matrix.
    pub fn transpose(&self) -> CscMatrix {
        let nnz = self.nnz();
        let nt_rows = self.ncols;
        let nt_cols = self.nrows;

        let mut col_counts = vec![0usize; nt_cols];
        for &r in &self.row_idx {
            col_counts[r] += 1;
        }

        let mut col_ptr = vec![0usize; nt_cols + 1];
        for j in 0..nt_cols {
            col_ptr[j + 1] = col_ptr[j] + col_counts[j];
        }

        let mut row_idx = vec![0usize; nnz];
        let mut values = vec![0.0f64; nnz];
        let mut cursor = col_ptr[..nt_cols].to_vec();

        for j in 0..self.ncols {
            let start = self.col_ptr[j];
            let end = self.col_ptr[j + 1];
            for idx in start..end {
                let r = self.row_idx[idx];
                let pos = cursor[r];
                row_idx[pos] = j;
                values[pos] = self.values[idx];
                cursor[r] += 1;
            }
        }

        // Sort row indices within each column
        for j in 0..nt_cols {
            let s = col_ptr[j];
            let e = col_ptr[j + 1];
            let rs = &mut row_idx[s..e];
            let vs = &mut values[s..e];
            for i in 1..rs.len() {
                let mut k = i;
                while k > 0 && rs[k - 1] > rs[k] {
                    rs.swap(k - 1, k);
                    vs.swap(k - 1, k);
                    k -= 1;
                }
            }
        }

        CscMatrix {
            nrows: nt_rows,
            ncols: nt_cols,
            col_ptr,
            row_idx,
            values,
        }
    }

    /// Sparse matrix addition: `C = A + B`.
    pub fn add(&self, other: &CscMatrix) -> CscMatrix {
        assert_eq!(self.nrows, other.nrows, "add: row dimension mismatch");
        assert_eq!(self.ncols, other.ncols, "add: col dimension mismatch");

        let ncols = self.ncols;
        let nrows = self.nrows;

        let mut col_ptr = Vec::with_capacity(ncols + 1);
        let mut row_idx = Vec::new();
        let mut values = Vec::new();
        col_ptr.push(0);

        for j in 0..ncols {
            let a_start = self.col_ptr[j];
            let a_end = self.col_ptr[j + 1];
            let b_start = other.col_ptr[j];
            let b_end = other.col_ptr[j + 1];

            let mut ai = a_start;
            let mut bi = b_start;

            while ai < a_end && bi < b_end {
                let ra = self.row_idx[ai];
                let rb = other.row_idx[bi];
                if ra < rb {
                    row_idx.push(ra);
                    values.push(self.values[ai]);
                    ai += 1;
                } else if ra > rb {
                    row_idx.push(rb);
                    values.push(other.values[bi]);
                    bi += 1;
                } else {
                    let v = self.values[ai] + other.values[bi];
                    row_idx.push(ra);
                    values.push(v);
                    ai += 1;
                    bi += 1;
                }
            }
            while ai < a_end {
                row_idx.push(self.row_idx[ai]);
                values.push(self.values[ai]);
                ai += 1;
            }
            while bi < b_end {
                row_idx.push(other.row_idx[bi]);
                values.push(other.values[bi]);
                bi += 1;
            }
            col_ptr.push(row_idx.len());
        }

        CscMatrix {
            nrows,
            ncols,
            col_ptr,
            row_idx,
            values,
        }
    }
}

// ---------------------------------------------------------------------------
// Column iterators
// ---------------------------------------------------------------------------

/// Iterator over entries `(row_index, value)` in a single CSC column.
pub struct ColumnIter<'a> {
    row_idx: &'a [usize],
    values: &'a [f64],
    pos: usize,
}

impl<'a> Iterator for ColumnIter<'a> {
    type Item = (usize, f64);
    #[inline]
    fn next(&mut self) -> Option<Self::Item> {
        if self.pos < self.row_idx.len() {
            let i = self.pos;
            self.pos += 1;
            Some((self.row_idx[i], self.values[i]))
        } else {
            None
        }
    }
}

/// Mutable iterator over entries `(row_index, &mut value)` in a single column.
pub struct ColumnIterMut<'a> {
    row_idx: &'a [usize],
    values: &'a mut [f64],
    pos: usize,
}

impl<'a> Iterator for ColumnIterMut<'a> {
    type Item = (usize, &'a mut f64);
    #[inline]
    fn next(&mut self) -> Option<Self::Item> {
        if self.pos < self.row_idx.len() {
            let i = self.pos;
            self.pos += 1;
            // SAFETY: each call advances `pos`, so we never hand out two &mut
            // to the same element.  The lifetime is tied to 'a.
            let val = unsafe { &mut *(self.values.as_mut_ptr().add(i)) };
            Some((self.row_idx[i], val))
        } else {
            None
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_csc() -> CscMatrix {
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 1.0);
        t.add(2, 0, 4.0);
        t.add(1, 1, 3.0);
        t.add(0, 2, 2.0);
        t.add(2, 2, 5.0);
        CscMatrix::from_triplet(&t)
    }

    #[test]
    fn test_from_triplet() {
        let m = sample_csc();
        assert_eq!(m.nrows(), 3);
        assert_eq!(m.ncols(), 3);
        assert_eq!(m.nnz(), 5);
    }

    #[test]
    fn test_get() {
        let m = sample_csc();
        assert_eq!(m.get(0, 0), Some(1.0));
        assert_eq!(m.get(1, 0), None);
        assert_eq!(m.get(2, 0), Some(4.0));
        assert_eq!(m.get(1, 1), Some(3.0));
        assert_eq!(m.get(0, 2), Some(2.0));
        assert_eq!(m.get(2, 2), Some(5.0));
    }

    #[test]
    fn test_identity() {
        let id = CscMatrix::identity(4);
        assert_eq!(id.nrows(), 4);
        assert_eq!(id.ncols(), 4);
        assert_eq!(id.nnz(), 4);
        for i in 0..4 {
            assert_eq!(id.get(i, i), Some(1.0));
            if i + 1 < 4 {
                assert_eq!(id.get(i, i + 1), None);
            }
        }
    }

    #[test]
    fn test_mul_vec() {
        let m = sample_csc();
        let x = DenseVec::from_slice(&[1.0, 1.0, 1.0]);
        let y = m.mul_vec(&x);
        assert!((y[0] - 3.0).abs() < 1e-14);
        assert!((y[1] - 3.0).abs() < 1e-14);
        assert!((y[2] - 9.0).abs() < 1e-14);
    }

    #[test]
    fn test_mul_vec_identity() {
        let id = CscMatrix::identity(3);
        let x = DenseVec::from_slice(&[7.0, 8.0, 9.0]);
        let y = id.mul_vec(&x);
        for i in 0..3 {
            assert_eq!(y[i], x[i]);
        }
    }

    #[test]
    fn test_transpose() {
        let m = sample_csc();
        let mt = m.transpose();
        assert_eq!(mt.nrows(), 3);
        assert_eq!(mt.ncols(), 3);
        assert_eq!(mt.get(0, 0), Some(1.0));
        assert_eq!(mt.get(0, 2), Some(4.0));
        assert_eq!(mt.get(1, 1), Some(3.0));
        assert_eq!(mt.get(2, 0), Some(2.0));
        assert_eq!(mt.get(2, 2), Some(5.0));
    }

    #[test]
    fn test_add() {
        let a = CscMatrix::identity(3);
        let b = sample_csc();
        let c = a.add(&b);
        assert_eq!(c.get(0, 0), Some(2.0));
        assert_eq!(c.get(1, 1), Some(4.0));
        assert_eq!(c.get(2, 2), Some(6.0));
        assert_eq!(c.get(2, 0), Some(4.0));
        assert_eq!(c.get(0, 2), Some(2.0));
    }

    #[test]
    fn test_column_iter() {
        let m = sample_csc();
        let entries: Vec<(usize, f64)> = m.column(0).collect();
        assert_eq!(entries, vec![(0, 1.0), (2, 4.0)]);

        let entries: Vec<(usize, f64)> = m.column(1).collect();
        assert_eq!(entries, vec![(1, 3.0)]);
    }

    #[test]
    fn test_from_triplet_with_duplicates() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 1.0);
        t.add(0, 0, 2.0);
        t.add(1, 1, 5.0);
        let csc = CscMatrix::from_triplet(&t);
        assert_eq!(csc.nnz(), 2);
        assert_eq!(csc.get(0, 0), Some(3.0));
        assert_eq!(csc.get(1, 1), Some(5.0));
    }

    #[test]
    fn test_zeros() {
        let z = CscMatrix::zeros(3, 4);
        assert_eq!(z.nrows(), 3);
        assert_eq!(z.ncols(), 4);
        assert_eq!(z.nnz(), 0);
    }

    #[test]
    fn test_transpose_of_transpose() {
        let m = sample_csc();
        let mtt = m.transpose().transpose();
        assert_eq!(m, mtt);
    }

    #[test]
    fn csc_matvec_identity_2x2() {
        let mut t = TripletMatrix::with_capacity(2, 2, 2);
        t.add(0, 0, 1.0);
        t.add(1, 1, 1.0);
        let csc = t.to_csc();
        assert_eq!(csc.nnz(), 2);
        let x = DenseVec::from_slice(&[3.0, 7.0]);
        let y = csc.mul_vec(&x);
        assert!((y[0] - 3.0).abs() < 1e-14);
        assert!((y[1] - 7.0).abs() < 1e-14);
    }

    #[test]
    fn csc_empty_matrix_matvec() {
        // Empty (all-zero) matrix: A*x should be zero vector
        let z = CscMatrix::zeros(3, 3);
        let x = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let y = z.mul_vec(&x);
        assert_eq!(y.norm_inf(), 0.0);
    }

    #[test]
    fn csc_1x1_matrix_get_and_matvec() {
        let mut t = TripletMatrix::new(1, 1);
        t.add(0, 0, 42.0);
        let csc = t.to_csc();
        assert_eq!(csc.get(0, 0), Some(42.0));
        let x = DenseVec::from_slice(&[2.0]);
        let y = csc.mul_vec(&x);
        assert!((y[0] - 84.0).abs() < 1e-14);
    }

    #[test]
    fn csc_get_out_of_bounds_returns_none() {
        let m = sample_csc();
        assert_eq!(m.get(5, 0), None);
        assert_eq!(m.get(0, 5), None);
    }

    #[test]
    fn csc_rectangular_matrix_matvec() {
        // 2×3 matrix:  [1 2 3; 4 5 6]
        let mut t = TripletMatrix::new(2, 3);
        t.add(0, 0, 1.0);
        t.add(0, 1, 2.0);
        t.add(0, 2, 3.0);
        t.add(1, 0, 4.0);
        t.add(1, 1, 5.0);
        t.add(1, 2, 6.0);
        let csc = t.to_csc();
        assert_eq!(csc.nrows(), 2);
        assert_eq!(csc.ncols(), 3);
        assert_eq!(csc.nnz(), 6);
        let x = DenseVec::from_slice(&[1.0, 0.0, 0.0]);
        let y = csc.mul_vec(&x);
        assert!((y[0] - 1.0).abs() < 1e-14);
        assert!((y[1] - 4.0).abs() < 1e-14);
    }

    #[test]
    fn csc_transpose_rectangular() {
        // Transpose a 2×3 gives a 3×2
        let mut t = TripletMatrix::new(2, 3);
        t.add(0, 0, 1.0);
        t.add(0, 2, 3.0);
        t.add(1, 1, 5.0);
        let csc = t.to_csc();
        let ct = csc.transpose();
        assert_eq!(ct.nrows(), 3);
        assert_eq!(ct.ncols(), 2);
        assert_eq!(ct.get(0, 0), Some(1.0));
        assert_eq!(ct.get(2, 0), Some(3.0));
        assert_eq!(ct.get(1, 1), Some(5.0));
    }

    #[test]
    fn csc_add_disjoint_patterns() {
        // A has entries in (0,0), B has entries in (1,1) — no overlap
        let mut ta = TripletMatrix::new(2, 2);
        ta.add(0, 0, 3.0);
        let mut tb = TripletMatrix::new(2, 2);
        tb.add(1, 1, 7.0);
        let a = ta.to_csc();
        let b = tb.to_csc();
        let c = a.add(&b);
        assert_eq!(c.get(0, 0), Some(3.0));
        assert_eq!(c.get(1, 1), Some(7.0));
        assert_eq!(c.get(0, 1), None);
    }

    #[test]
    fn csc_add_overlapping_patterns() {
        // Both have entry at (0,0); should be summed
        let mut ta = TripletMatrix::new(2, 2);
        ta.add(0, 0, 4.0);
        ta.add(0, 1, 1.0);
        let mut tb = TripletMatrix::new(2, 2);
        tb.add(0, 0, 6.0);
        tb.add(1, 0, 2.0);
        let a = ta.to_csc();
        let b = tb.to_csc();
        let c = a.add(&b);
        assert_eq!(c.get(0, 0), Some(10.0));
        assert_eq!(c.get(0, 1), Some(1.0));
        assert_eq!(c.get(1, 0), Some(2.0));
    }

    #[test]
    fn csc_column_iter_empty_column() {
        // Column 1 of the identity(3) has only (1, 1.0)
        let id = CscMatrix::identity(3);
        let entries: Vec<_> = id.column(1).collect();
        assert_eq!(entries, vec![(1, 1.0)]);
    }

    #[test]
    fn csc_column_mut_modifies_values() {
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 1.0);
        t.add(2, 0, 4.0);
        let mut csc = t.to_csc();
        for (_r, v) in csc.column_mut(0) {
            *v *= 2.0;
        }
        assert_eq!(csc.get(0, 0), Some(2.0));
        assert_eq!(csc.get(2, 0), Some(8.0));
    }

    #[test]
    fn csc_col_range_correct() {
        let m = sample_csc();
        // Column 0 has 2 entries (rows 0 and 2)
        let r = m.col_range(0);
        assert_eq!(r.len(), 2);
    }

    #[test]
    fn csc_from_triplet_empty() {
        let t = TripletMatrix::new(4, 5);
        let csc = CscMatrix::from_triplet(&t);
        assert_eq!(csc.nrows(), 4);
        assert_eq!(csc.ncols(), 5);
        assert_eq!(csc.nnz(), 0);
    }

    #[test]
    fn csc_values_mut_allows_refactorisation() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 1.0);
        t.add(1, 1, 1.0);
        let mut csc = t.to_csc();
        // Double every stored value
        for v in csc.values_mut() {
            *v *= 2.0;
        }
        assert_eq!(csc.get(0, 0), Some(2.0));
        assert_eq!(csc.get(1, 1), Some(2.0));
    }

    #[test]
    fn csc_identity_n0_is_empty() {
        let id = CscMatrix::identity(0);
        assert_eq!(id.nrows(), 0);
        assert_eq!(id.ncols(), 0);
        assert_eq!(id.nnz(), 0);
    }

    #[test]
    fn csc_matvec_accumulates_multiple_columns() {
        // A = [1 2; 3 4], x = [1, 1] => y = [3, 7]
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 1.0);
        t.add(1, 0, 3.0);
        t.add(0, 1, 2.0);
        t.add(1, 1, 4.0);
        let a = t.to_csc();
        let x = DenseVec::from_slice(&[1.0, 1.0]);
        let y = a.mul_vec(&x);
        assert!((y[0] - 3.0).abs() < 1e-14);
        assert!((y[1] - 7.0).abs() < 1e-14);
    }

    #[test]
    fn csc_add_zeros_matrix() {
        let z = CscMatrix::zeros(3, 3);
        let m = sample_csc();
        let c = m.add(&z);
        assert_eq!(c, m);
        let c2 = z.add(&m);
        assert_eq!(c2, m);
    }
}
