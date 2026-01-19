# Pole-Zero Analysis

Eigenproblem formulation; QZ vs reduced standard eigenproblem; our
Hessenberg + Francis QR solver.

## 1. Mathematical specification

### From MNA planes to an eigenproblem

The linearized circuit $ (G + sC)\,X(s) = U(s)$ has transfer functions
whose **poles** are the values of $s$ where $G + sC$ drops rank — the
generalized eigenvalues of the pencil $(G, C)$:

$$
\det(G + s\,C) = 0 .
$$

The clean general formulation is the **QZ (generalized Schur)
decomposition** of $(-G, C)$, which handles singular $C$ (MNA always has
resistive rows and branch rows with no charge) by producing infinite
eigenvalues for the non-dynamic directions. *(QZ path: derived, not
implemented — see below.)*

### Reduction to a standard eigenproblem (our route)

When $G$ is nonsingular (any circuit with a DC solution and no pure-C
cutsets), multiply through:

$$
\det(G + sC) = 0
\;\Longleftrightarrow\;
\det\big(I + s\,G^{-1}C\big) = 0
\;\Longleftrightarrow\;
\lambda = -\tfrac{1}{s} \text{ is an eigenvalue of } G^{-1}C .
$$

With $A = -G^{-1}C$, the eigenvalues $\lambda_i$ of $A$ are **negated time
constants** (units: seconds) and the poles are

$$
s_i = \frac{1}{\lambda_i} = \frac{\bar\lambda_i}{|\lambda_i|^2}.
$$

The $C$ null-space (resistive nodes, branch rows) maps to $\lambda \approx 0$
— *not* poles at the origin but absent dynamics; they are discarded by a
relative cutoff $|\lambda| \le 10^{-9}\max_i|\lambda_i|$. Stability
classification: $\Re(s_i) < 0$.

**Zeros** of a specific input→output transfer function are the poles of the
circuit with input and output constrained (ngspice computes them from the
same machinery with the transfer function specified as a node-pair /
node-pair ratio); *zeros are not implemented here* — the analysis reports
poles.

### The eigen solver

Dense real non-symmetric eigensolve, textbook two-stage:

1. **Householder reduction to upper Hessenberg** $H = Q^{\mathsf T} A Q$
   ($O(n^3)$, finite).
2. **Francis implicit double-shift QR iteration** on $H$: bulge-chasing
   with the shift polynomial $(H - \sigma)(H - \bar\sigma)$ taken from the
   trailing $2\times2$ block, deflating converged $1\times1$ (real) and
   $2\times2$ (complex-pair) blocks off the bottom. Convergence is
   deflation-based with tolerance `qr_tol` on subdiagonal entries relative
   to their neighbors; the double-shift keeps the iteration in real
   arithmetic while extracting complex pairs.

Contrast with ngspice, which does a *sub-optimal numerical search* on
$\det(G + sC)$ via repeated factorizations (manual §1.2.5: "may take a
considerable time or fail... may find an excessive number of poles") — the
eigenvalue route finds all $n$ candidates unconditionally at $O(n^3)$
dense cost.

## 2. Flow explanation

`src/analysis/eigen/pz.zig`:

1. One `eval()` at $x_{op}$ — the analytic planes are the linearization.
   Dense copies of $G$ and $C$.
2. Sparse-blind dense build of $A = -G^{-1}C$: factor $G$ once (dense LU),
   one back-substitution per column of $C$. Singular $G$ → `error.Singular`
   (pure-C node; the circuit has no finite DC linearization).
3. Hessenberg + Francis QR (`eigenvaluesQR`, up to `qr_max_iter` sweeps).
   Hitting the iteration cap without full deflation is *not* an error: the
   pole list is returned with `qr_converged = false` (incomplete list,
   flagged).
4. Eigenvalue post-pass: cutoff filter, $\lambda \to s = \bar\lambda/|\lambda|^2$,
   stability count.

Knobs: `qr_max_iter` (1000), `qr_tol` (1e-12); tolerance bundle only feeds
the upstream OP.

## 3. Pseudo-code, CPU sequential

```
pz(ckt, x_op):
    eval(x_op); G, C = dense planes
    lu = factor(G)                      # error.Singular if rank-deficient
    for j in 0..n: A[:,j] = -solve(lu, C[:,j])
    H = householder_hessenberg(A)
    eigs = []
    while not fully deflated and sweeps < qr_max_iter:
        pick double shift from trailing 2x2 of active block
        bulge-chase one implicit QR sweep
        deflate small subdiagonals (|h[i+1,i]| <= qr_tol * (|h[i,i]|+|h[i+1,i+1]|))
        pop converged 1x1 / 2x2 blocks -> eigs
    cutoff = 1e-9 * max|eig|
    poles = { conj(l)/|l|^2 : |l| > cutoff }
    n_stable = count(Re < 0)
```

## 4. Pseudo-code, GPU parallel

Dense $O(n^3)$ at MNA sizes rarely justifies a GPU port on its own; the
axes that do parallelize:

- **Building $A$**: the $n$ back-substitutions on the factored $G$ are
  independent — one blocked multi-RHS triangular solve (GETRS with $n$
  RHS), then a GEMM-shaped negation. This is the dominant cost for
  $n \gtrsim$ a few hundred and is pure BLAS-3.
- **Hessenberg reduction**: blocked Householder (BLAS-3) — standard
  LAPACK-style GPU port.
- **QR iteration stays sequential** in its bulge chase (tightly recurrent);
  batched small-matrix eigensolvers only pay in the ensemble axis:
  Monte-Carlo pole clouds = $L$ independent $n\times n$ eigenproblems, one
  per lane (batched Hessenberg + batched QR, the cuSOLVER/MAGMA batched
  model).

```
host pz_gpu(lanes = MC trials or corners):
    per lane: build A (batched GETRF/GETRS + GEMM)
    batched hessenberg; batched francis-QR (small-matrix batched kernels)
    parallel filter/map eigenvalues -> poles per lane
```

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Dense LU of $G$ + per-column solves | none (dense path) | `src/solvers/dense_lu.zig` `factorize`/`solveFactored` |
| Eigen solver (Hessenberg + Francis double-shift QR) | none (analysis-local) | `src/analysis/eigen/pz.zig eigenvaluesQR` |
| Sparse alternative for large n (factor $G$ sparsely, shift-invert Arnoldi for the few dominant poles) | [klu-pipeline.md](../solvers/klu-pipeline.md), [gilbert-peierls-lu.md](../solvers/gilbert-peierls-lu.md) | upgrade path — reuses `direct.zig` factors as the Arnoldi operator (same pattern as [matex-exponential-integrators.md](matex-exponential-integrators.md) rational Krylov) |
| Upstream OP | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `dc/op.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §1.2.4/§11.3.6 (.PZ) | **fetched, verified** — supported devices, numerical-search method + its failure modes |
| Francis QR / QZ theory (Golub & Van Loan) | **book — derived, not source-verified** (standard algorithms) |

**Per-section verification**

- §1 pencil→standard reduction, $\lambda$-cutoff, $s = 1/\lambda$ map:
  verified against `pz.zig` source. QZ formulation + zeros: derived, not
  implemented (marked).
- §2/§3: direct transcription. §4: prospective.

**Our implementation**

- `src/analysis/eigen/pz.zig` — poles via $-G^{-1}C$ eigenvalues.
- Bench fixtures: `benchmark/fixtures/pz/*`.
