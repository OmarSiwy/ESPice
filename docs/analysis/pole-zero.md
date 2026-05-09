# Pole-Zero Analysis

Eigenproblem formulation; QZ vs reduced standard eigenproblem; our
Hessenberg + Francis QR solver.

## 1. Mathematical specification

### From MNA planes to an eigenproblem

The linearized circuit $ (G + sC)\,X(s) = U(s)$ has transfer functions
whose **poles** are the values of $s$ where $G + sC$ drops rank: the
generalized eigenvalues of the pencil $(G, C)$:

$$
\det(G + s\,C) = 0 .
$$

The clean general formulation is the **QZ (generalized Schur)
decomposition** of $(-G, C)$, which handles singular $C$ (MNA always has
resistive rows and branch rows with no charge) by producing infinite
eigenvalues for the non-dynamic directions. *(QZ path: derived, not
implemented; see below.)*

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

The $C$ null-space (resistive nodes, branch rows) maps to $\lambda \approx 0$:
not poles at the origin but absent dynamics. It is zero to within the QR's
backward error, $O(n\,\epsilon\,\|A\|)$, so the cutoff is absolute,
$|\lambda| \le n\,\epsilon \max_i|\lambda_i|$. Anything above it is a
real time constant however small next to the slowest one:
`pz/widely_separated_modes` has $\tau$ = 1 ns next to $\tau$ = 1000 s, twelve
decades apart. Stability classification: $\Re(s_i) < 0$.

**Zeros** of the input-to-output transfer function
$H(s) = e_{\text{out}}^{\mathsf T} Y(s)^{-1} d$ are, by Cramer's rule, the
roots of the determinant of $Y = G + sC$ with the output column replaced by
the input drive $d$. That equals the bordered determinant
$\begin{bmatrix} Y & d \\ e_{\text{out}}^{\mathsf T} & 0 \end{bmatrix}$,
but as a column swap the $C$ plane stays emptier: a grounded output
capacitor drops out of the pencil instead of surviving as a spurious root.
The numerator pencil goes through the same reduction and QR. Its $G$ part
can be singular at $s = 0$, so the zeros pass factors $M = G + \sigma C$ on a
ladder of shifts $\sigma$ scaled by the largest pole magnitude and maps the
eigenvalues back with $s = \sigma + 1/\lambda$. The denominator uses
$\sigma = 0$.

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
considerable time or fail... may find an excessive number of poles"): the
eigenvalue route finds all $n$ candidates unconditionally at $O(n^3)$
dense cost.

## 2. Flow explanation

`src/analysis/eigen/pz.zig`:

1. `linearizeAc(x_op)`: the analytic planes are the linearization. Dense
   copies of $G$ and $C$.
2. Dense build of $A = -G^{-1}C$: factor $G$ once (dense LU), one
   back-substitution per column of $C$. Singular $G$ gives `error.Singular`
   (a node reached only through capacitors).
3. Hessenberg reduction and Francis QR (`eigen/qr.zig eigenvalues`, up to
   `qr_max_iter` sweeps). Hitting the iteration cap without full deflation
   raises `error.PzDidNotConverge`: a partial root set is never returned.
   Diverges from ngspice, which warns at its iteration limit and publishes
   the roots it found (cktpzstr.c:225).
4. Eigenvalue post-pass: cutoff filter,
   $\lambda \to s = \bar\lambda/|\lambda|^2$, stability count.
5. When zeros are requested: build the numerator pencil, walk the shift
   ladder until $G + \sigma C$ factors, and repeat steps 2 to 4 with
   $s = \sigma + 1/\lambda$. No factorable shift gives `error.Singular`.

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
    cutoff = n * eps * max|eig|
    poles = { conj(l)/|l|^2 : |l| > cutoff }
    n_stable = count(Re < 0)
    if want_zeros:
        replace the output column of (G, C) by the input drive
        for sigma in shift ladder (scaled by max|pole|):
            if factor(G + sigma*C) succeeds: break
        zeros = { sigma + 1/l : eigenvalues l of -(G + sigma*C)^-1 C }
```

## 4. Parallel execution

Everything runs on the host. Dense $O(n^3)$ at MNA sizes rarely justifies a
GPU port on its own. Not implemented (design notes): the $n$
back-substitutions that build $A$ are one blocked multi-RHS triangular solve
(BLAS-3, the dominant cost past a few hundred unknowns); the Hessenberg
reduction ports as blocked Householder; the QR bulge chase stays sequential,
so batched small-matrix eigensolvers pay only on an ensemble axis (Monte
Carlo pole clouds, one $n \times n$ problem per lane).

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Dense LU of $G$ + per-column solves | none (dense path) | `src/solver/dense_lu.zig` `factorize`/`solveFactored` |
| Eigen solver (Hessenberg + Francis double-shift QR) | none (analysis-local) | `src/analysis/eigen/qr.zig` (`hessenbergReduce`, `eigenvalues`) |
| Sparse alternative for large n (factor $G$ sparsely, shift-invert Arnoldi for the few dominant poles) | [klu-pipeline.md](../solvers/klu-pipeline.md), [gilbert-peierls-lu.md](../solvers/gilbert-peierls-lu.md) | upgrade path: reuses `direct.zig` factors as the Arnoldi operator (same pattern as [matex-exponential-integrators.md](matex-exponential-integrators.md) rational Krylov) |
| Upstream OP | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `dc/op.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §1.2.4/§11.3.6 (.PZ) | fetched, verified: supported devices, numerical-search method + its failure modes |
| Francis QR / QZ theory (Golub & Van Loan) | book; derived, not source-verified (standard algorithms) |

**Per-section verification**

- §1 pencil-to-standard reduction, $\lambda$ cutoff, $s = 1/\lambda$ map, and
  the column-swap zeros: verified against `pz.zig`. QZ formulation: derived,
  not implemented.
- §2/§3: transcribed from source. §4: design notes.

**Our implementation**

- `src/analysis/eigen/pz.zig`: poles and zeros via $-M^{-1}C$ eigenvalues.
- `src/analysis/eigen/qr.zig`: Hessenberg reduction and Francis QR.
- Fixtures: `tests/fixtures/pz/`.
