# solvers

Standalone sparse/dense linear algebra for circuit simulation. No dependency on the analysis or devices modules.

## Solvers

| Module | What it does |
|--------|-------------|
| `direct` | Fixed-pattern sparse LU (Gilbert–Peierls, threshold pivoting). BTF+AMD ordering via `order.zig`. Zero-alloc refactor path for Newton iteration. Tridiag fast-path for chain topologies. |
| `dense_lu` | Dense LU with partial pivoting. Used by small-matrix analyses (PZ, TF, dense AC) and as the fallback when n < threshold. |
| `freq_solve` | Complex frequency-domain solver: builds (G + jωC) from real CSC planes, dispatches to dense or sparse path by size. |
| `fft` | Radix-2 / split-radix FFT and inverse. Powers harmonic balance, PSS, Fourier analysis. |

## Internal

| Module | Role |
|--------|------|
| `order` | BTF decomposition + approximate minimum degree (AMD) ordering. Called once by `direct.init`. |

## Types

- `BbdInfo` / `BbdBlock` — bordered block diagonal structure for subcircuit-aware partitioning.

## Usage

```zig
const solvers = @import("solvers");

// Sparse direct solve
var s = try solvers.direct.Solver.init(gpa, n, col_ptr, row_idx, null);
defer s.deinit();
try s.factor(vals);
try s.solveNeg(rhs, x);

// Dense LU
solvers.dense_lu.solveDense(n, a_row_major, rhs, x);

// Frequency domain
var fs = try solvers.freq_solve.FreqSolver.init(gpa, n, col_ptr, row_idx, g_vals, c_vals);
try fs.solve(omega, rhs_complex, x_complex);

// FFT
solvers.fft.fft(re, im);
solvers.fft.ifft(re, im);
```
