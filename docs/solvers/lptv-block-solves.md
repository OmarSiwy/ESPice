# LPTV Block Solves (Harmonic Conversion Matrices)

The conversion-matrix system behind PAC/PXF/pnoise/QPAC as a structured
linear-algebra problem: block factorization, factor reuse, transpose
solves, storage, matrix-free application.

**Status: partially implemented** — `pss/pac.zig` builds and solves the
full conversion matrix densely; everything block-structured below is the
documented upgrade required by PXF, true-LPTV pnoise, and QPSS.

## 1. Mathematical specification

### The system

Linearizing about a T-periodic orbit gives periodic
$G(t) = \sum_m G_m e^{jm\omega_0 t}$, $C(t) = \sum_m C_m e^{jm\omega_0 t}$
(each $G_m, C_m \in \mathbb{C}^{n\times n}$ carries the **circuit's
sparsity pattern** — the harmonic expansion never densifies a block).
Truncated to sidebands $m \in [-M, M]$, the response phasors
$X = (X_{-M}, \dots, X_{M})$ at analysis frequency $f$ solve

$$
\mathcal A(f)\, X = B, \qquad
\mathcal A_{pq}(f) = G_{p-q} + j\omega_p\, C_{p-q}, \quad
\omega_p = 2\pi(f + p f_0),
$$

a $(2M{+}1)n$ complex system. Structure to exploit:

1. **Block-Toeplitz in the harmonic index** — block $(p,q)$ depends only
   on $p-q$ through $G_{p-q}, C_{p-q}$; the $j\omega_p C$ factor breaks
   exact Toeplitz-ness only via the *diagonal-scalar* $\omega_p$, so the
   operator is "Toeplitz + frequency ramp": storage is $2M{+}1$
   coefficient pairs, never $(2M{+}1)^2$ blocks.
2. **Harmonic decay** — for any orbit with finite smoothness,
   $\|G_m\| \to 0$ as $|m|$ grows (exponentially for smooth orbits). The
   matrix is block-*banded* in practice: keeping $|p-q| \le M_G \ll 2M$
   loses nothing measurable. The LTI limit ($G_m = 0$ for $m \ne 0$) is
   exactly block-diagonal = $2M{+}1$ independent AC solves.
3. **Frequency-sweep reuse** — $\mathcal A(f)$ and $\mathcal A(f')$ differ
   only in the $\omega_p$ scalars multiplying the same $C_{p-q}$ blocks:
   the assembled block pattern, orderings, and symbolic factorization are
   sweep-invariant. Refactor values only, as `freq_solve` already does per
   $\omega$ for AC.

### Stacked-real realization

Complex arithmetic maps to the engine's existing stacked-real trick
(one real solver, no complex kernels): each complex block $Z = Z_r + jZ_i$
becomes $\left(\begin{smallmatrix} Z_r & -Z_i \\ Z_i & Z_r \end{smallmatrix}\right)$
— for AC this is `freq_solve.zig`'s $2n$ form
$[G, -\omega C; \omega C, G]$; for the conversion matrix it is the same
expansion at $(2M{+}1)n$ ("real expansion of the complex system" — exactly
what `pac.zig` builds today, dense). The sparse-path lesson transfers
verbatim: derive the $2\cdot(2M{+}1)n$ pattern once from the circuit CSC ×
harmonic band, then per frequency the fill is a streamed copy of plane
values scaled by $\omega_p$.

### Direct block factorization

Options ordered by exploited structure:

- **Flat sparse LU** on the stacked-real pattern (KLU pipeline as-is):
  correct, reuses everything; fill grows with the harmonic band coupling
  — fine for small $M$.
- **Block-banded elimination**: eliminate sideband blocks in order; each
  pivot block is an $n \times n$ circuit-pattern matrix factored by the
  existing sparse LU; off-band fill is limited by $M_G$. Cost
  $O((2M{+}1) \cdot M_G^2 \cdot \text{lu}(n))$.
- **Matrix-free + preconditioner** (the scalable route): never assemble
  $\mathcal A$; apply it via FFT (below) inside GMRES with a
  block-structured preconditioner
  ([structured-preconditioners.md](structured-preconditioners.md)).

### Transpose/adjoint solves (PXF)

PXF and adjoint pnoise need $\mathcal A^{\mathsf H} Y = e_{\text{out}}$.
Structure: $\mathcal A^{\mathsf H}$ has blocks
$(\mathcal A^{\mathsf H})_{pq} = \overline{G_{q-p}}^{\mathsf T} - j\omega_q \overline{C_{q-p}}^{\mathsf T}$
— block-Toeplitz again with conjugated, transposed coefficients and the
frequency ramp moved to the *column* index. Consequences:

- **direct path**: one factorization serves both directions — the sparse
  LU's `solveT` (already in `direct.zig`: $x = A^{\mathsf T}\backslash b$
  on the same $L, U$) extends to the block factorization; in stacked-real
  form, conjugation = negating the $\omega C$ off-blocks' sign
  contribution, which the noise path already handles ("the conjugate drops
  out of $|H|^2$", `noise.zig`);
- **matrix-free path**: the adjoint operator apply is the forward apply
  with conjugated twiddle factors and $G(t)^{\mathsf T}$ — one extra
  transposed-scatter variant of the batched eval.

### Matrix-free application

The Toeplitz block structure diagonalizes under the DFT: with
$\mathcal F$ the per-node DFT over $N \ge 2(2M{+}1)$ time samples,

$$
\mathcal A\, X \;=\; \mathcal F\,\big[\, G(t_k)\, x(t_k) \,\big]
\;+\; j\,\Omega\, \mathcal F\,\big[\, C(t_k)\, x(t_k)\,\big],
\qquad \Omega = \mathrm{diag}(\omega_p),
$$

i.e. IDFT the sideband vector to time samples, multiply by the *sampled*
(sparse, circuit-pattern) $G(t_k)$/$C(t_k)$ — one SpMV per sample — and
DFT back, applying the frequency ramp spectrally. Cost per apply:
$O(N \cdot \text{nnz} + N \log N \cdot n)$, no harmonic-band truncation
error at all. This is the operator the repo's JFNK/GMRES core
(`converger.zig`) consumes unchanged.

## 2. Flow explanation

What exists: `pss/pac.zig` samples $G(t_k), C(t_k)$ densely, FFTs each
matrix *element* to get $\hat G_m, \hat C_m$, assembles the full
$2(2M{+}1)n$ stacked-real dense matrix per frequency, `dense_lu`
factorize-solve. Correct; $O(((2M{+}1)n)^3)$ per point and $n^2 N$ sample
storage are the ceilings.

Upgrade flow (serves PAC, PXF, LPTV-pnoise, QPAC):

1. **Sample once** per orbit: keep $G(t_k), C(t_k)$ in *sparse* plane
   copies (nnz × N floats), not dense — the batched eval already produces
   plane values; snapshotting is a memcpy of the vals arrays.
2. **Choose path by size**: small $(2M{+}1)n$ → assemble stacked-real
   sparse, KLU factor, `solve`/`solveT` per RHS (mirrors
   `freq_solve.zig`'s dense-below-threshold / sparse-above policy, one
   level up). Large → GMRES with the FFT apply + structured
   preconditioner.
3. **Sweep loop**: symbolic work is per-orbit, not per-frequency; per
   point only values refill (the $\omega_p$ ramp) + refactor or
   preconditioner refresh. PXF flips RHS/solve-direction, nothing else.
4. **Failure handling**: preconditioned GMRES stagnation at strongly
   switching orbits → fall back to the direct sparse factorization (same
   hierarchy the AC path uses when dense/sparse crossover is wrong —
   measured, not guessed).

## 3. Pseudo-code, CPU sequential

```
setup(orbit):                                # once per PSS orbit
    for k in 0..N: snapshot sparse G_k, C_k  # plane vals memcpy
    pattern = stackedreal(circuit CSC) x band(M_G)   # symbolic once

solve_point(f, rhs, adjoint=false):
    if (2M+1)*n < threshold:                 # direct path
        fill values: block(p,q) <- Ghat[p-q] + j*w_p*Chat[p-q]
        factor once; x = adjoint ? solveT(rhs) : solve(rhs)
    else:                                    # matrix-free path
        x = gmres(apply, M_precond, rhs) where
        apply(v):
            v_t = IDFT_pernode(v)            # sidebands -> N samples
            y_t[k] = (adjoint ? G_k^T : G_k) @ v_t[k]        # SpMV per sample
            z_t[k] = (adjoint ? C_k^T : C_k) @ v_t[k]
            return DFT(y_t) + j*Omega .* DFT(z_t)            # ramp spectrally
                   (adjoint: conjugate twiddles, ramp -> conj)
```

## 4. Pseudo-code, GPU parallel

Every piece maps onto existing kernel patterns:

- the per-sample SpMVs are **batched over samples** — one grid-stride pass
  over (sample × nnz), same shape as the batched device eval; better, skip
  the snapshots entirely and evaluate $G(t_k)v_k$ **matrix-free through
  the device batches** (instance eval at the orbit point with directional
  seed), which is the JFNK trick specialized to LPTV;
- DFT/IDFT: batched FFTs over nodes (nodes × N);
- GMRES scalar bookkeeping: thread-0 + grid barriers, verbatim from
  `kernel.zig`;
- frequency points of the sweep: independent lanes (the AC §4 story);
- direct path: batched stacked-real refactors per lane.

```
kernel lptv_apply(v):                        # inside per-lane GMRES
    parallel IDFT (nodes x N)                # batched FFT
    parallel (sample, batch, instance) grid-stride:
        stamp G_k(orbit_k) @ v_k             # SoA eval w/ directional seed
    parallel DFT; parallel ramp j*w_p        # grid-stride over sidebands
kernel lptv_adjoint_apply: same, transposed scatter + conj twiddles
```

---

**Sources fetched**

| Source | Status |
|---|---|
| Kundert rf-sim.pdf (LPTV response eqs. 48–49, HB frequency-domain machinery §4.1.1) | fetched (prior pass), verified — sideband/transfer-function structure |
| Conversion-matrix / harmonic transfer matrix algebra (Maas, Wereley) | **books/paywalled — derived, not source-verified** (standard LPTV result; consistent with the implemented `pac.zig`) |

**Per-section verification**

- §1 conversion-matrix blocks, stacked-real expansion: verified against
  `pss/pac.zig` (implements exactly the block formula, dense).
- §1 Toeplitz/decay/reuse structure, adjoint blocks, FFT apply: derived,
  not source-verified (standard; FFT-apply consistency checkable against
  the dense path on any fixture).
- §2–§4: design spec grounded in existing impl (`freq_solve.zig`
  dense/sparse policy, `direct.zig solveT`, `kernel.zig` GMRES).

**Our implementation**

- Exists: `src/analysis/pss/pac.zig` (dense conversion matrix),
  `src/solvers/freq_solve.zig` (stacked-real pattern trick, the
  $2n$ special case), `src/solvers/direct.zig solveT`,
  `src/solvers/fft.zig`.
- Consumers: [pac](../analysis/pac.md) (today),
  [pxf](../analysis/pxf.md), [periodic-noise](../analysis/periodic-noise.md)
  true-LPTV upgrade, [qpss](../analysis/qpss.md) QPAC (future).
- Bench fixtures: `benchmark/fixtures/pss/*` (orbit source);
  LTI-reduction cross-check vs `benchmark/fixtures/ac/*`.
