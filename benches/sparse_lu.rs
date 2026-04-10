use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion};
use pisim_linalg::{TripletMatrix, lu_factorize};

/// Build a diagonally dominant tridiagonal matrix of size n.
///
/// Main diagonal = 4.0, off-diagonals = -1.0.
/// This is always non-singular and well-conditioned.
fn build_tridiagonal(n: usize) -> pisim_linalg::CscMatrix {
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

fn bench_lu_factorize(c: &mut Criterion) {
    let mut group = c.benchmark_group("sparse_lu");

    for &n in &[4, 10, 50, 100] {
        let csc = build_tridiagonal(n);
        group.bench_with_input(BenchmarkId::new("tridiag", n), &csc, |b, mat| {
            b.iter(|| lu_factorize(mat).unwrap());
        });
    }

    group.finish();
}

criterion_group!(benches, bench_lu_factorize);
criterion_main!(benches);
