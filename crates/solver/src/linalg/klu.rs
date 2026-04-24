//! KLU linear solver backend (SuiteSparse).
//!
//! KLU (Clark Kent LU) is a sparse LU factorisation optimised for circuit
//! simulation matrices.  It performs BTF pre-ordering followed by AMD
//! ordering within each block, then Gilbert-Peierls-style sparse LU with
//! partial pivoting — the same algorithm chain ngspice and Xyce use.
//!
//! ## Feature gate
//!
//! Compiled only when the `klu` Cargo feature is enabled **and** the
//! SuiteSparse KLU shared library was found at build time (`build.rs`).
//! Without the feature the public types still compile; all methods return
//! `SimError::Analysis("KLU not enabled")` at runtime so call-sites are
//! always valid.
//!
//! ## Safety
//!
//! All `unsafe` is confined to the thin `ffi` sub-module and the wrapper
//! methods that call it.  The public [`KluSolver`] API is fully safe.

use super::csc::CscMatrix;
use super::dense_vec::DenseVec;
use incspice_core::SimError;

// ---------------------------------------------------------------------------
// FFI bindings (klu feature only)
// ---------------------------------------------------------------------------

#[cfg(feature = "klu")]
mod ffi {
    //! Raw FFI bindings to `libklu` (SuiteSparse 5.x, 32-bit `int` API).

    use std::ffi::c_int;

    // Opaque handle types — never inspected from Rust.

    #[repr(C)]
    pub struct KluSymbolic {
        _opaque: [u8; 0],
    }

    #[repr(C)]
    pub struct KluNumeric {
        _opaque: [u8; 0],
    }

    /// `klu_common` — control parameters and statistics.
    ///
    /// We need the struct's exact size to stack/heap allocate it and pass a
    /// pointer to KLU.  Rather than replicate all 160 bytes of named fields,
    /// we use an opaque byte array with f64 alignment.  Named accessors read
    /// the specific offsets that are stable across SuiteSparse 5.x.
    ///
    /// Layout (klu.h, SuiteSparse 5.13, x86-64):
    ///   +0   double tol
    ///   +8   double memgrow
    ///   +16  double initmem_amd
    ///   +24  double initmem
    ///   +32  double maxwork
    ///   +40  int btf
    ///   +44  int ordering
    ///   +48  int scale
    ///   +52  (4-byte pad)
    ///   +56  void* user_order  (8 bytes)
    ///   +64  void* user_data   (8 bytes)
    ///   +72  int halt_if_singular
    ///   +76  int status
    ///   +80  int nrealloc
    ///   +84  int structural_rank
    ///   +88  int numerical_rank
    ///   +92  int singular_col
    ///   +96  int noffdiag
    ///   +100 (4-byte pad)
    ///   +104 double flops
    ///   +112 double rcond
    ///   +120 double condest
    ///   +128 double rgrowth
    ///   +136 double work
    ///   +144 size_t memusage  (8 bytes)
    ///   +152 size_t mempeak   (8 bytes)
    ///   total: 160 bytes
    #[repr(C, align(8))]
    pub struct KluCommon {
        pub bytes: [u8; 160],
    }

    impl KluCommon {
        /// Read the `status` field at byte offset 76.
        #[inline]
        pub fn status(&self) -> c_int {
            i32::from_ne_bytes(self.bytes[76..80].try_into().unwrap())
        }
    }

    // KLU status codes (from klu.h).
    pub const KLU_OK: c_int = 0;
    pub const KLU_SINGULAR: c_int = 1;
    pub const KLU_OUT_OF_MEMORY: c_int = 2;
    pub const KLU_INVALID: c_int = 3;

    extern "C" {
        /// Initialise `*common` with default control parameters.
        /// Returns non-zero on success.
        pub fn klu_defaults(common: *mut KluCommon) -> c_int;

        /// Symbolic analysis: BTF + AMD ordering.
        /// Returns an owning pointer or NULL on failure.
        pub fn klu_analyze(
            n: c_int,
            ap: *const c_int,
            ai: *const c_int,
            common: *mut KluCommon,
        ) -> *mut KluSymbolic;

        /// Numeric factorisation.
        /// Returns an owning pointer or NULL on failure.
        pub fn klu_factor(
            ap: *const c_int,
            ai: *const c_int,
            ax: *const f64,
            symbolic: *mut KluSymbolic,
            common: *mut KluCommon,
        ) -> *mut KluNumeric;

        /// Solve `A x = b`.  `b` is overwritten with the solution.
        /// Returns non-zero on success.
        pub fn klu_solve(
            symbolic: *mut KluSymbolic,
            numeric: *mut KluNumeric,
            ldim: c_int,
            nrhs: c_int,
            b: *mut f64,
            common: *mut KluCommon,
        ) -> c_int;

        /// Re-factorise reusing the symbolic analysis.
        /// Returns non-zero on success.
        pub fn klu_refactor(
            ap: *const c_int,
            ai: *const c_int,
            ax: *const f64,
            symbolic: *mut KluSymbolic,
            numeric: *mut KluNumeric,
            common: *mut KluCommon,
        ) -> c_int;

        /// Free the symbolic object; sets `*symbolic` to NULL.
        pub fn klu_free_symbolic(symbolic: *mut *mut KluSymbolic, common: *mut KluCommon) -> c_int;

        /// Free the numeric object; sets `*numeric` to NULL.
        pub fn klu_free_numeric(numeric: *mut *mut KluNumeric, common: *mut KluCommon) -> c_int;
    }
}

// ---------------------------------------------------------------------------
// KluSolver — public safe wrapper
// ---------------------------------------------------------------------------

/// A factorised linear system backed by SuiteSparse KLU.
///
/// KLU performs BTF + AMD ordering and Gilbert-Peierls sparse LU — the same
/// pipeline as ngspice/Xyce.  For circuit matrices (which are typically
/// reducible to block-diagonal form) this is significantly faster than the
/// built-in sparse LU.
///
/// When the `klu` Cargo feature is absent all methods return an error.
pub struct KluSolver {
    #[cfg(feature = "klu")]
    inner: KluSolverInner,
    #[cfg(not(feature = "klu"))]
    _phantom: std::marker::PhantomData<()>,
}

#[cfg(feature = "klu")]
struct KluSolverInner {
    n: usize,
    /// KLU common block on the heap so its address is stable across calls.
    common: Box<ffi::KluCommon>,
    /// Symbolic analysis (BTF + AMD); owned, freed on drop.
    symbolic: *mut ffi::KluSymbolic,
    /// Numeric factors (L, U, pivots); owned, freed on drop.
    numeric: *mut ffi::KluNumeric,
    /// Column pointers cast to i32 for KLU's `int` API.
    col_ptr_i32: Vec<i32>,
    /// Row indices cast to i32.
    row_idx_i32: Vec<i32>,
}

#[cfg(feature = "klu")]
impl Drop for KluSolverInner {
    fn drop(&mut self) {
        // SAFETY: pointers are non-null — we only store valid ones.
        unsafe {
            if !self.numeric.is_null() {
                ffi::klu_free_numeric(&mut self.numeric, self.common.as_mut());
            }
            if !self.symbolic.is_null() {
                ffi::klu_free_symbolic(&mut self.symbolic, self.common.as_mut());
            }
        }
    }
}

// SAFETY: KluSolverInner exclusively owns the KLU objects (no shared refs).
// KLU is not thread-safe for concurrent calls on the same objects, but
// single-owner exclusive access across threads is sound.
#[cfg(feature = "klu")]
unsafe impl Send for KluSolverInner {}

impl KluSolver {
    /// Factorize `matrix` using KLU (symbolic analysis + numeric factors).
    ///
    /// Returns `Err` when the `klu` feature is disabled, or when the matrix
    /// is structurally/numerically singular.
    pub fn factorize(matrix: &CscMatrix) -> Result<Self, SimError> {
        #[cfg(feature = "klu")]
        {
            let n = matrix.nrows();
            assert_eq!(n, matrix.ncols(), "KLU requires a square matrix");

            let col_ptr_i32: Vec<i32> = matrix.col_ptr().iter().map(|&x| x as i32).collect();
            let row_idx_i32: Vec<i32> = matrix.row_idx().iter().map(|&x| x as i32).collect();

            let mut common = Box::new(ffi::KluCommon { bytes: [0u8; 160] });
            unsafe {
                let ok = ffi::klu_defaults(common.as_mut());
                if ok == 0 {
                    return Err(SimError::Analysis("klu_defaults failed".into()));
                }
            }

            let symbolic = unsafe {
                ffi::klu_analyze(
                    n as i32,
                    col_ptr_i32.as_ptr(),
                    row_idx_i32.as_ptr(),
                    common.as_mut(),
                )
            };
            if symbolic.is_null() {
                return Err(SimError::Analysis(
                    "klu_analyze failed (structurally singular?)".into(),
                ));
            }

            let numeric = unsafe {
                ffi::klu_factor(
                    col_ptr_i32.as_ptr(),
                    row_idx_i32.as_ptr(),
                    matrix.values().as_ptr(),
                    symbolic,
                    common.as_mut(),
                )
            };
            if numeric.is_null() {
                let status = common.status();
                let mut sym_ptr = symbolic;
                unsafe {
                    ffi::klu_free_symbolic(&mut sym_ptr, common.as_mut());
                }
                return Err(klu_status_to_err(status));
            }

            return Ok(Self {
                inner: KluSolverInner {
                    n,
                    common,
                    symbolic,
                    numeric,
                    col_ptr_i32,
                    row_idx_i32,
                },
            });
        }

        #[cfg(not(feature = "klu"))]
        {
            let _ = matrix;
            Err(SimError::Analysis("KLU feature not enabled".into()))
        }
    }

    /// Solve `A x = b` using the pre-computed factorisation.
    pub fn solve(&self, rhs: &DenseVec) -> Result<DenseVec, SimError> {
        #[cfg(feature = "klu")]
        {
            let n = self.inner.n;
            assert_eq!(rhs.len(), n, "KLU solve: dimension mismatch");

            // klu_solve overwrites b in-place; copy rhs first.
            let mut x = rhs.as_slice().to_vec();

            // SAFETY: klu_solve only reads Common, no mutation; we hold &self.
            let ok = unsafe {
                ffi::klu_solve(
                    self.inner.symbolic,
                    self.inner.numeric,
                    n as i32,
                    1,
                    x.as_mut_ptr(),
                    self.inner.common.as_ref() as *const ffi::KluCommon as *mut ffi::KluCommon,
                )
            };
            if ok == 0 {
                return Err(SimError::Analysis("klu_solve failed".into()));
            }
            return Ok(DenseVec::from_slice(&x));
        }

        #[cfg(not(feature = "klu"))]
        {
            let _ = rhs;
            Err(SimError::Analysis("KLU feature not enabled".into()))
        }
    }

    /// Re-factorise with new numerical values, reusing the symbolic analysis.
    ///
    /// The sparsity pattern of `matrix` must match the original.  This is the
    /// fast path for Newton iterations where only values change.
    pub fn refactorize(&mut self, matrix: &CscMatrix) -> Result<(), SimError> {
        #[cfg(feature = "klu")]
        {
            let ok = unsafe {
                ffi::klu_refactor(
                    self.inner.col_ptr_i32.as_ptr(),
                    self.inner.row_idx_i32.as_ptr(),
                    matrix.values().as_ptr(),
                    self.inner.symbolic,
                    self.inner.numeric,
                    self.inner.common.as_mut(),
                )
            };
            if ok == 0 {
                return Err(klu_status_to_err(self.inner.common.status()));
            }
            return Ok(());
        }

        #[cfg(not(feature = "klu"))]
        {
            let _ = matrix;
            Err(SimError::Analysis("KLU feature not enabled".into()))
        }
    }
}

/// Convert a KLU status code to a [`SimError`].
#[cfg(feature = "klu")]
fn klu_status_to_err(status: i32) -> SimError {
    match status {
        ffi::KLU_SINGULAR => SimError::SingularMatrix { row: 0 },
        ffi::KLU_OUT_OF_MEMORY => SimError::Analysis("KLU: out of memory".into()),
        ffi::KLU_INVALID => SimError::Analysis("KLU: invalid inputs".into()),
        other => SimError::Analysis(format!("KLU error status {other}")),
    }
}

// ---------------------------------------------------------------------------
// Tests (compiled only with `klu` feature)
// ---------------------------------------------------------------------------

#[cfg(all(test, feature = "klu"))]
mod tests {
    use super::*;
    use super::triplet::TripletMatrix;

    fn build_3x3() -> CscMatrix {
        // [2  1  0]
        // [1  3  1]
        // [0  1  4]
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 2.0);
        t.add(0, 1, 1.0);
        t.add(1, 0, 1.0);
        t.add(1, 1, 3.0);
        t.add(1, 2, 1.0);
        t.add(2, 1, 1.0);
        t.add(2, 2, 4.0);
        t.to_csc()
    }

    /// Build a 4×4 nodal conductance matrix for a simple resistor mesh.
    ///
    /// Topology (all resistors = 1 Ω):
    ///   Node 0 — R=1 — Node 1 — R=1 — Node 2 — R=1 — Node 3
    ///   Node 0 — R=1 — Node 2   (cross link)
    ///   Node 1 — R=1 — Node 3   (cross link)
    ///
    /// Nodal conductance stamp: G[i][i] += 1/R, G[i][j] -= 1/R.
    ///
    /// With all R=1 the matrix is:
    ///   [ 2 -1 -1  0]
    ///   [-1  2  0 -1]
    ///   [-1  0  2 -1]
    ///   [ 0 -1 -1  2]
    ///
    /// (Note: this is singular as written because all row/col sums are zero —
    /// a grounded node is needed.  We fix node 3 by replacing its equation
    /// with the identity row, giving a non-singular system.)
    fn build_resistor_mesh_4x4() -> CscMatrix {
        let mut t = TripletMatrix::new(4, 4);
        // Stamps for edges: (0,1), (0,2), (1,3), (2,3) — all R=1.
        // Edge 0-1
        t.add(0, 0, 1.0);
        t.add(1, 1, 1.0);
        t.add(0, 1, -1.0);
        t.add(1, 0, -1.0);
        // Edge 0-2
        t.add(0, 0, 1.0);
        t.add(2, 2, 1.0);
        t.add(0, 2, -1.0);
        t.add(2, 0, -1.0);
        // Edge 1-3
        t.add(1, 1, 1.0);
        t.add(3, 3, 1.0);
        t.add(1, 3, -1.0);
        t.add(3, 1, -1.0);
        // Edge 2-3
        t.add(2, 2, 1.0);
        t.add(3, 3, 1.0);
        t.add(2, 3, -1.0);
        t.add(3, 2, -1.0);
        // Fix node 3 (ground): replace row 3 with identity.
        // Zero out the off-diagonal stamps for row 3 that we added above.
        t.add(3, 1, 1.0); // cancels the -1 from edge 1-3
        t.add(3, 2, 1.0); // cancels the -1 from edge 2-3
        t.add(3, 3, -1.0); // net: G[3,3] = 1+1 + (-1) = 1
        t.to_csc()
    }

    #[test]
    fn klu_solve_resistor_mesh_4x4() {
        // Known solution: voltages [V0, V1, V2, V3] = [2.0, 1.5, 1.5, 0.0].
        // RHS is computed as A * x_true so the residual check is exact.
        let a = build_resistor_mesh_4x4();
        let solver = KluSolver::factorize(&a).expect("klu factorize 4x4 mesh");
        let x_true = DenseVec::from_slice(&[2.0, 1.5, 1.5, 0.0]);
        let b = a.mul_vec(&x_true);
        let x = solver.solve(&b).expect("klu solve 4x4 mesh");
        // Verify residual ||A*x - b|| < 1e-10 component-wise.
        let residual = a.mul_vec(&x);
        for i in 0..4 {
            assert!(
                (residual[i] - b[i]).abs() < 1e-10,
                "residual[{i}] = {} (expected {})",
                residual[i],
                b[i]
            );
        }
    }

    #[test]
    fn klu_solve_3x3() {
        let a = build_3x3();
        let solver = KluSolver::factorize(&a).expect("klu factorize");
        let x_true = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let b = a.mul_vec(&x_true);
        let x = solver.solve(&b).expect("klu solve");
        for i in 0..3 {
            assert!(
                (x[i] - x_true[i]).abs() < 1e-11,
                "x[{i}] = {} expected {}",
                x[i],
                x_true[i]
            );
        }
    }

    #[test]
    fn klu_solve_identity() {
        let id = CscMatrix::identity(4);
        let solver = KluSolver::factorize(&id).expect("klu factorize");
        let b = DenseVec::from_slice(&[1.0, 2.0, 3.0, 4.0]);
        let x = solver.solve(&b).expect("klu solve");
        for i in 0..4 {
            assert!((x[i] - b[i]).abs() < 1e-14);
        }
    }

    #[test]
    fn klu_refactorize() {
        let a = build_3x3();
        let mut solver = KluSolver::factorize(&a).expect("klu factorize");

        let mut t2 = TripletMatrix::new(3, 3);
        t2.add(0, 0, 4.0);
        t2.add(0, 1, 1.0);
        t2.add(1, 0, 1.0);
        t2.add(1, 1, 5.0);
        t2.add(1, 2, 1.0);
        t2.add(2, 1, 1.0);
        t2.add(2, 2, 6.0);
        let a2 = t2.to_csc();

        solver.refactorize(&a2).expect("klu refactorize");

        let x_true = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let b = a2.mul_vec(&x_true);
        let x = solver.solve(&b).expect("klu solve after refactorize");
        for i in 0..3 {
            assert!(
                (x[i] - x_true[i]).abs() < 1e-11,
                "x[{i}] = {} expected {}",
                x[i],
                x_true[i]
            );
        }
    }
}
