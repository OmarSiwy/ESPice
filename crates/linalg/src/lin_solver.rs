use crate::csc::CscMatrix;
use crate::dense_vec::DenseVec;
use crate::klu::KluSolver;
use crate::lu::{LuFactors, LuSymbolic, lu_factorize, lu_refactorize, lu_symbolic};
use crate::solve::lu_solve;
use pisim_core::SimError;

/// Which linear solver algorithm to use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinSolverKind {
    /// Sparse LU with partial pivoting (AMD-ordered, current default).
    SparseLu,
    /// SuiteSparse KLU — BTF + AMD + Gilbert-Peierls LU.
    ///
    /// Requires the `klu` Cargo feature and `libklu.so` at runtime.
    /// Falls back to an error at runtime when the feature is absent.
    Klu,
}

/// A factorised linear system, ready to solve.
///
/// Wraps the underlying solver data behind an enum so callers can switch
/// algorithms without changing call-sites.  The existing free functions
/// (`lu_factorize`, `lu_solve`, etc.) remain available for direct use.
pub enum LinSolver {
    /// Sparse LU with partial pivoting.
    SparseLu {
        symbolic: LuSymbolic,
        factors: LuFactors,
    },
    /// KLU solver (BTF + AMD + sparse LU via SuiteSparse).
    Klu(KluSolver),
}

impl LinSolver {
    /// Factorize a matrix using the given algorithm.
    pub fn factorize(kind: LinSolverKind, matrix: &CscMatrix) -> Result<Self, SimError> {
        match kind {
            LinSolverKind::SparseLu => {
                let symbolic = lu_symbolic(matrix);
                let factors = lu_factorize(matrix)?;
                Ok(Self::SparseLu { symbolic, factors })
            }
            LinSolverKind::Klu => {
                let solver = KluSolver::factorize(matrix)?;
                Ok(Self::Klu(solver))
            }
        }
    }

    /// Solve `Ax = b` using the pre-computed factorisation.
    pub fn solve(&self, rhs: &DenseVec) -> Result<DenseVec, SimError> {
        match self {
            Self::SparseLu { factors, .. } => lu_solve(factors, rhs),
            Self::Klu(s) => s.solve(rhs),
        }
    }

    /// Re-factorize with the same sparsity pattern (e.g. during Newton
    /// iterations where the matrix values change but the structure does not).
    pub fn refactorize(&mut self, matrix: &CscMatrix) -> Result<(), SimError> {
        match self {
            Self::SparseLu { symbolic, factors } => {
                *factors = lu_refactorize(matrix, symbolic)?;
                Ok(())
            }
            Self::Klu(s) => s.refactorize(matrix),
        }
    }

    /// The algorithm this solver was created with.
    pub fn kind(&self) -> LinSolverKind {
        match self {
            Self::SparseLu { .. } => LinSolverKind::SparseLu,
            Self::Klu(_) => LinSolverKind::Klu,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::triplet::TripletMatrix;

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

    #[test]
    fn lin_solver_factorize_and_solve() {
        let a = build_3x3();
        let solver = LinSolver::factorize(LinSolverKind::SparseLu, &a).unwrap();

        let x_true = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let b = a.mul_vec(&x_true);
        let x = solver.solve(&b).unwrap();

        for i in 0..3 {
            assert!(
                (x[i] - x_true[i]).abs() < 1e-12,
                "x[{i}] = {} expected {}",
                x[i],
                x_true[i]
            );
        }
    }

    #[test]
    fn lin_solver_refactorize() {
        let a = build_3x3();
        let mut solver = LinSolver::factorize(LinSolverKind::SparseLu, &a).unwrap();

        // Build a different matrix with the same sparsity pattern.
        let mut t2 = TripletMatrix::new(3, 3);
        t2.add(0, 0, 4.0);
        t2.add(0, 1, 1.0);
        t2.add(1, 0, 1.0);
        t2.add(1, 1, 5.0);
        t2.add(1, 2, 1.0);
        t2.add(2, 1, 1.0);
        t2.add(2, 2, 6.0);
        let a2 = t2.to_csc();

        solver.refactorize(&a2).unwrap();

        let x_true = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let b = a2.mul_vec(&x_true);
        let x = solver.solve(&b).unwrap();

        for i in 0..3 {
            assert!(
                (x[i] - x_true[i]).abs() < 1e-12,
                "x[{i}] = {} expected {}",
                x[i],
                x_true[i]
            );
        }
    }

    #[test]
    fn lin_solver_kind_accessor() {
        let a = CscMatrix::identity(3);
        let solver = LinSolver::factorize(LinSolverKind::SparseLu, &a).unwrap();
        assert_eq!(solver.kind(), LinSolverKind::SparseLu);
    }

    #[test]
    fn lin_solver_singular_matrix() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 1.0);
        t.add(0, 1, 1.0);
        // Row 1 is all zero -> singular.
        let a = t.to_csc();
        let result = LinSolver::factorize(LinSolverKind::SparseLu, &a);
        assert!(result.is_err());
    }

    #[test]
    fn lin_solver_identity() {
        let id = CscMatrix::identity(4);
        let solver = LinSolver::factorize(LinSolverKind::SparseLu, &id).unwrap();
        let b = DenseVec::from_slice(&[7.0, 8.0, 9.0, 10.0]);
        let x = solver.solve(&b).unwrap();
        for i in 0..4 {
            assert!((x[i] - b[i]).abs() < 1e-14);
        }
    }
}
