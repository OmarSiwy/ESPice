//! Linear algebra benchmarks: sparse LU, BTF, KLU.

use criterion::{BenchmarkId, Criterion};
use bigospice_linalg::{TripletMatrix, lu_factorize};

fn build_tridiagonal(n: usize) -> bigospice_linalg::CscMatrix {
    let mut triplet = TripletMatrix::new(n, n);
    for i in 0..n {
        triplet.add(i, i, 4.0);
        if i > 0 {
            triplet.add(i, i - 1, -1.0);
            triplet.add(i - 1, i, -1.0);
        }
    }
    triplet.to_csc()
}

pub fn bench_linalg(c: &mut Criterion) {
    let mut group = c.benchmark_group("linalg/sparse_lu");
    for &n in &[4usize, 10, 50, 100, 500] {
        let csc = build_tridiagonal(n);
        group.bench_with_input(BenchmarkId::new("tridiag", n), &csc, |b, mat| {
            b.iter(|| lu_factorize(mat).unwrap());
        });
    }
    group.finish();
}
