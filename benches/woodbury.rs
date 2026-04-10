/// Phase 5.4 benchmark — Woodbury rank-k update vs full LU refactorisation.
///
/// For each system size n ∈ {100, 500, 1000} and rank k ∈ {1, 5, 10, sqrt(n)}:
///
///   - `woodbury_update_k`  — accumulate k rank-1 updates into `WoodburyUpdate`
///     and call `.solve()` using the cached base-solver closure.
///   - `lu_refactorize_n`  — call `lu_factorize` on the perturbed matrix
///     (full symbolic + numeric re-factor; baseline cost).
///
/// The crossover point where full refactor wins is at k ≈ sqrt(n).  The bench
/// makes this visible by sweeping k up to and past that threshold.
use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion};
use pisim_cache::{should_use_woodbury, WoodburyUpdate};
use pisim_linalg::{lu_factorize, lu_solve, DenseVec, TripletMatrix};

// ---------------------------------------------------------------------------
// Matrix / problem generators
// ---------------------------------------------------------------------------

/// Build a diagonally-dominant tridiagonal `n×n` matrix in CSC form.
///
/// Diagonal = 4.0, sub/super-diagonal = -1.0.  Always non-singular
/// and well-conditioned so the solve exercises the solver path, not
/// error handling.
fn build_tridiagonal(n: usize) -> pisim_linalg::CscMatrix {
    let mut t = TripletMatrix::new(n, n);
    for i in 0..n {
        t.add(i, i, 4.0);
        if i > 0 {
            t.add(i, i - 1, -1.0);
            t.add(i - 1, i, -1.0);
        }
    }
    t.to_csc()
}

/// Build a unit-length random-looking `u` / `v` column of length `n`.
///
/// Uses a simple deterministic sequence (not a PRNG) so benchmarks are
/// reproducible across runs.  The values are never zero so the
/// rank-1 update is genuinely non-trivial.
fn make_uv_col(n: usize, seed: usize) -> Vec<f64> {
    (0..n)
        .map(|i| {
            let x = ((seed + 1) * (i + 1)) as f64;
            let v = (x * 0.017_453_292).sin(); // sin of angle in degrees-ish
            // scale so the update is small relative to the diagonal
            v * 0.01
        })
        .collect()
}

/// Build an RHS vector of length `n` with alternating ±1.
fn build_rhs(n: usize) -> Vec<f64> {
    (0..n).map(|i| if i % 2 == 0 { 1.0 } else { -1.0 }).collect()
}

// ---------------------------------------------------------------------------
// Benchmark groups
// ---------------------------------------------------------------------------

fn bench_woodbury(c: &mut Criterion) {
    for &n in &[100usize, 500, 1000] {
        let mat = build_tridiagonal(n);

        // Pre-compute the LU factors for the BASE matrix once.  This is what
        // the Woodbury solver reuses.
        let base_factors = lu_factorize(&mat).unwrap();
        let rhs_data = build_rhs(n);
        let rhs = DenseVec::from_slice(&rhs_data);

        // Ranks to benchmark: 1, 5, 10, sqrt(n)
        let sqrt_n = (n as f64).sqrt() as usize;
        let ranks: Vec<usize> = [1, 5, 10]
            .iter()
            .copied()
            .chain(std::iter::once(sqrt_n))
            .filter(|&k| k > 0 && k <= n)
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();

        // ── Woodbury update group ────────────────────────────────────────────
        {
            let mut group = c.benchmark_group(format!("woodbury/n{n}/update"));

            for &k in &ranks {
                // Pre-build the update columns outside the timed loop.
                let u_cols: Vec<Vec<f64>> = (0..k).map(|s| make_uv_col(n, s)).collect();
                let v_cols: Vec<Vec<f64>> = (0..k).map(|s| make_uv_col(n, s + 100)).collect();

                // Clone base factors into an Arc-style share by cloning per iter.
                let bf = base_factors.clone();
                let rhs_clone = rhs.clone();

                group.bench_with_input(
                    BenchmarkId::new("woodbury_solve", k),
                    &k,
                    move |b, _| {
                        b.iter(|| {
                            // Build a fresh WoodburyUpdate with all k columns.
                            let mut wu = WoodburyUpdate::new(n);
                            for j in 0..k {
                                wu.push_rank1(&u_cols[j], &v_cols[j]);
                            }

                            // Solve using the Woodbury identity.
                            let mut out = vec![0.0f64; n];
                            wu.solve(rhs_clone.as_slice(), &mut out, |b_in, b_out| {
                                let b_dv = DenseVec::from_slice(b_in);
                                let x = lu_solve(&bf, &b_dv).unwrap();
                                b_out.copy_from_slice(x.as_slice());
                            })
                            .unwrap();
                        });
                    },
                );
            }

            group.finish();
        }

        // ── Full LU refactorisation group ────────────────────────────────────
        {
            let mut group = c.benchmark_group(format!("woodbury/n{n}/refactor"));

            // Full refactor does not depend on k — bench it once labelled as
            // "full" so the HTML report can overlay it with the Woodbury curves.
            group.bench_with_input(
                BenchmarkId::new("full_refactor", n),
                &mat,
                |b, m| {
                    b.iter(|| {
                        let factors = lu_factorize(m).unwrap();
                        lu_solve(&factors, &rhs).unwrap()
                    });
                },
            );

            group.finish();
        }

        // ── should_use_woodbury decision boundary ────────────────────────────
        {
            let mut group = c.benchmark_group(format!("woodbury/n{n}/cutover"));

            for &k in &ranks {
                let decision = should_use_woodbury(n, k);
                // Label the bench with the actual decision so it appears in
                // the criterion output alongside timing data.
                let label = if decision { "woodbury" } else { "refactor" };
                group.bench_with_input(
                    BenchmarkId::new(label, k),
                    &k,
                    |b, _| {
                        b.iter(|| should_use_woodbury(n, k));
                    },
                );
            }

            group.finish();
        }
    }
}

criterion_group!(benches, bench_woodbury);
criterion_main!(benches);
