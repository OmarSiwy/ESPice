# Pole-Zero Analysis

Eigenproblem formulation; QZ vs reduced standard eigenproblem. Poles go
through Hessenberg + Francis QR on $-G^{-1}C$, zeros through QZ on the
numerator pencil.

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
eigenvalues for the non-dynamic directions. The zeros take this path
(`eigen/qz.zig`); the poles take the reduction below.

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
The numerator pencil is solved as it stands, by QZ. Two things rule out
the reduction for it. Its $G$ part is singular at $s = 0$ whenever the
transfer has a zero there. And most of its roots are at infinity in a
defective block: through $A = -M^{-1}C$ that block comes back as roundoff
eigenvalues near zero spread over $\epsilon^{1/k}\|A\|$, as large as
genuine roots, so no cutoff or rank count separates them. An RC ladder with
bridging capacitors (each bridge's zero exactly $-1/(R\,C_b)$) got 38 zeros
where LAPACK `dggev` finds 8, and 0 where it finds 11, through the old
shift ladder and $\mathrm{rank}(A^m)$ count.

QZ (`eigen/qz.zig`, LAPACK `dggbal` 'P' + `dgghrd` + `dhgeqz`, all Givens):
exact-zero row/column isolation, Hessenberg-triangular reduction, then the
double-shift iteration. A diagonal of $C$'s triangular factor at or below
$\epsilon\|C\|_F$ is a root at infinity; it is chased to the bottom of its
block and deflated there, one per root, whatever the Jordan structure.
Everything else is finite, $z = \alpha/\beta$.

Measured against `dggev` and the exact bridge zeros (12 random bridged
ladders, 5 to 90 sections): every zero count matches, worst relative error
4.7e-16. The old path got the count wrong on 10 of 12 and was off by
6.1e-10 on one it counted right. 40 uniform ladders (2 to 80 sections, RC
from 1e-21 to 1e6 s): no zeros, as before.

**Poles stay on the QR.** QZ on $(G, -C)$ would retire `qr.zig` too, but it
is normwise backward stable in $(G, C)$, which costs the slow poles of a
long ladder relative accuracy: on the same 40 uniform ladders the worst
pole error against the closed form grew from 5.5e-14 to 2.1e-12 (80
sections), and a relative deflation tolerance of eps instead of `qr_tol`
did not recover it. $-G^{-1}C$ keeps the slow poles as the largest
eigenvalues. Fallback if a pole deck needs a singular $G$: QZ on $(G, -C)$
via `qz.roots`.

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
5. When zeros are requested: build the numerator pencil and take its
   finite roots with `eigen/qz.zig roots` (same `qr_tol`, `qr_max_iter`
   and `error.PzDidNotConverge`). A singular numerator $G$ is fine.

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
        isolate rows/columns with one nonzero across (G, -C)
        (H, T) = hessenberg_triangular(G, -C)       # Givens
        QZ sweeps; T[j,j] <= eps*||T||_F: chase to the bottom, drop (infinite)
        zeros = { alpha/beta of the deflated 1x1 and 2x2 blocks }
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
| Eigen solver (Hessenberg + Francis double-shift QR), poles | none (analysis-local) | `src/analysis/eigen/qr.zig` (`hessenbergReduce`, `eigenvalues`) |
| Generalized eigen solver (Hessenberg-triangular + double-shift QZ), zeros | none (analysis-local) | `src/analysis/eigen/qz.zig` (`roots`) |
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
  the column-swap zeros and the QZ zeros path: verified against `pz.zig` and
  `qz.zig`.
- §2/§3: transcribed from source. §4: design notes.

**Our implementation**

- `src/analysis/eigen/pz.zig`: poles via $-G^{-1}C$ eigenvalues, zeros via QZ.
- `src/analysis/eigen/qr.zig`: Hessenberg reduction and Francis QR.
- `src/analysis/eigen/qz.zig`: isolation, Hessenberg-triangular reduction, QZ.
- Fixtures: `tests/fixtures/pz/`.
