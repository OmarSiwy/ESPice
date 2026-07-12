# Structured Preconditioners for HB / LPTV / QPSS Krylov

Block-circulant (averaged-Jacobian) preconditioning, FFT diagonalization,
degradation modes, fallback hierarchy, multi-tone generalization.

**Status: not implemented** — the JFNK path (`converger.zig`) has
diagonal-Jacobi and factored-LU right preconditioning for the *time-domain*
Newton systems; nothing structured exists yet for spectral (HB/conversion-
matrix) systems. Required by Krylov-HB, matrix-free PAC/PXF, and QPSS.

## 1. Mathematical specification

### The target operators

Krylov-HB and LPTV solves apply operators of the form (see
[lptv-block-solves.md](lptv-block-solves.md))

$$
\mathcal A = \mathcal F\, \big[G(t_k)\cdot\big]\, \mathcal F^{-1} \;+\; j\Omega\,\mathcal F\,\big[C(t_k)\cdot\big]\,\mathcal F^{-1},
$$

block-Toeplitz in the harmonic index with coefficient blocks
$G_m, C_m$. GMRES on $\mathcal A$ needs a preconditioner that captures the
dominant coupling at $O(\text{cheap})$ per application.

### Block-circulant / averaged-Jacobian preconditioner

Keep only the time-average ($m = 0$) blocks:

$$
P \;=\; \mathrm{blkdiag}_p\,\big(\bar G + j\omega_p\, \bar C\big),
\qquad \bar G = G_0 = \frac{1}{N}\sum_k G(t_k),\ \ \bar C = C_0 .
$$

Two equivalent readings:

- **frequency domain**: $P$ is the exact operator of the *time-invariant*
  circuit with Jacobians frozen at their period average — block-diagonal,
  one $n \times n$ sparse complex solve per sideband/harmonic;
- **time domain**: dropping $m \ne 0$ harmonics makes the operator
  time-invariant, and a (block-)Toeplitz operator with constant blocks is
  block-**circulant** under the periodic boundary; circulants are
  diagonalized by the DFT — which is *why* $P$ is block-diagonal in the
  frequency basis. $P^{-1}$ application: already in the DFT basis, just
  $2M{+}1$ independent stacked-real solves (each on the circuit pattern —
  the KLU pipeline verbatim, symbolic shared across all sidebands since
  the pattern is $\omega$-independent).

Quality: the preconditioned spectrum is governed by the *relative
harmonic content* of the Jacobian,
$\|P^{-1}(\mathcal A - P)\| \sim \max_{m\ne 0}\|G_m\|/\|\bar G + j\omega C\|$.
For mildly nonlinear circuits (small-signal RF, filters, weakly driven
mixers) $G_m$ decays fast and GMRES converges in a handful of iterations
— this is the standard Krylov-HB preconditioner in the literature
(rf-sim.pdf's HB section describes the frequency-domain Newton whose
diagonal blocks this is; the preconditioning specialization is marked
derived below).

### When it degrades

Strong nonlinearity = strong Jacobian modulation. A hard-switching mixer
or logic gate has $G(t)$ swinging orders of magnitude within the period:
$\|G_{\pm 1, \pm 2}\| \sim \|G_0\|$, the off-diagonal blocks are no longer
a perturbation, and block-circulant-preconditioned GMRES stalls (iteration
counts drift toward the unpreconditioned case). Diagnostics: watch the
GMRES residual decay rate; a stall within the first restart window is the
signal, not a reason to iterate harder.

### Fallback hierarchy

Ordered by cost, each strictly stronger on modulation coupling:

1. **DC-sample block-diagonal** — $G(t_0)$ instead of $\bar G$ (what
   `hb.zig`'s Jacobian already approximates for $C$): cheapest, weakest;
   fine when the orbit hugs one operating region.
2. **Averaged block-circulant** ($\bar G, \bar C$) — the default above.
3. **Block-banded** — keep $|p-q| \le 1..2$ harmonic off-blocks and
   factor the resulting block-tridiagonal system (block Thomas over
   sidebands, each block solve = sparse LU on the circuit pattern):
   captures first-order modulation coupling, cost grows linearly in the
   band.
4. **Time-domain preconditioner** — precondition with one full period of
   the *transient* operator (one BE sweep over the saved step factors,
   i.e. a single application of the monodromy-style recurrence from
   [monodromy-krylov.md](monodromy-krylov.md)): captures arbitrary
   modulation since it *is* time-varying; costs $S$ back-substitutions per
   application. This is the strong-nonlinearity endgame (shooting-flavored
   preconditioning of HB).
5. **Give up on spectral** — strongly switching circuits are shooting's
   home turf; route the analysis to the shooting path instead of forcing
   HB (analysis-level fallback, mirrors the OP ladder philosophy).

### Multi-tone (d-dimensional) generalization — QPSS

For $d$ fundamentals, harmonics live on a grid
$\mathbf m \in \prod_i [-K_i, K_i]$, frequencies
$\omega_{\mathbf m} = 2\pi\, \mathbf m \cdot \mathbf f$, and the operator
is block-Toeplitz in *each* harmonic index (level-$d$ block-Toeplitz).
Everything above tensorizes:

$$
P \;=\; \mathrm{blkdiag}_{\mathbf m}\big(\bar G + j\omega_{\mathbf m} \bar C\big),
$$

diagonalized by the $d$-dimensional DFT over the
$N_1 \times \dots \times N_d$ sample grid; $P^{-1}$ = one sparse
stacked-real solve per grid point ($\prod (2K_i{+}1)$ of them, all
independent, all sharing symbolic). The matrix-free operator apply is the
$d$-dim FFT sandwich of per-sample SpMVs. Band-fallbacks generalize
per-axis (keep coupling in the strongly-driven tone's index, stay diagonal
in the weak tone's — the physically right anisotropy for a mixer: LO
strongly modulates, RF doesn't).

## 2. Flow explanation

Where it plugs in: `converger.zig`'s GMRES already right-preconditions via
a callback (`applyPreconditioner`: factored `direct.Solver` or Jacobi
diagonal). The structured preconditioners are new implementations of that
same slot for spectral unknown vectors:

1. **Setup per orbit/Newton iteration**: compute $\bar G, \bar C$ (mean of
   the sampled plane values — one axpy pass over the snapshots), build the
   stacked-real pattern once, factor per sideband on demand and cache —
   sidebands differ only by the scalar $\omega_p$, so values-fill +
   refactor per sideband is the same streamed copy `freq_solve.zig` does
   per $\omega$.
2. **Apply** = per-sideband back-substitutions (already in the DFT basis
   for HB/LPTV vectors; no transform needed in the apply).
3. **Refresh policy**: the preconditioner freezes per outer Newton
   iteration (like the JFNK diagonal preconditioner today); refresh only
   when GMRES iteration count degrades across Newton iterations —
   staleness is cheap, rebuilds are not.
4. **Escalation**: measured stall (no residual-norm halving within
   $m/2$ Krylov steps) climbs the hierarchy one rung; rung choice is
   remembered per analysis run (a circuit that needed banded once will
   again).

## 3. Pseudo-code, CPU sequential

```
setup(orbit_samples, M):
    Gbar = mean_k(G_k); Cbar = mean_k(C_k)      # axpy over sparse vals
    symbolic = analyze(stackedreal_pattern)     # once, shared by all p

apply_blockcirculant(v):                        # v = sideband-stacked vector
    for p in -M..M:                             # independent
        if !cached[p]:
            fill values: Gbar, w_p*Cbar; factor -> cached[p]
        v[p] = cached[p].solve(v[p])            # (or solveT for adjoint)
    return v

gmres_with_hierarchy(A_apply, rhs):
    P = blockcirculant
    loop:
        x, stalled = gmres(A_apply, P, rhs)
        if !stalled: return x
        P = next_rung(P)     # dc-sample -> circulant -> banded -> time-domain
        if P exhausted: signal analysis-level fallback (shooting)
```

## 4. Pseudo-code, GPU parallel

- Per-sideband solves are **embarrassingly parallel** (independent
  factors, one per lane/block-cluster) — and they batch perfectly: same
  symbolic, different scalar $\omega_p$, the batched-refactor case
  [gpu-sparse-lu.md](gpu-sparse-lu.md) discusses.
- $\bar G$/$\bar C$ reduction: grid-stride mean over (sample × nnz).
- Banded rung: block-tridiagonal Thomas is sequential over sidebands but
  each block op is a parallel sparse solve; alternatively cyclic reduction
  over the sideband axis for $\log$ depth.
- Time-domain rung: the monodromy replay kernel
  ([monodromy-krylov.md](monodromy-krylov.md) §4), multi-RHS.
- $d$-dim FFTs: batched cuFFT-shaped kernels; grid-point solves = lanes.

```
kernel precond_apply(v):                       # inside per-lane GMRES
    parallel over sidebands p (block clusters):
        refactor(Gbar + j*w_p*Cbar) if stale   # batched, shared symbolic
        level_sched_solve -> v[p]
    grid_barrier
```

---

**Sources fetched**

| Source | Status |
|---|---|
| Kundert rf-sim.pdf §4.1.1 (HB frequency-domain Newton, time-domain device eval via DFT/IDFT) | fetched (prior pass), verified — the operator being preconditioned |
| Averaged/block-circulant HB preconditioning (Feldmann/Melville/Long; Rösch/Kundert HB writings) | **paywalled / not located free — derived, not source-verified** (standard Krylov-HB practice; the circulant-DFT diagonalization is elementary) |
| Multi-tone/multidimensional FFT HB | rf-sim.pdf §4.1.3 quasiperiodic HB (fetched) for the formulation; preconditioner tensorization derived |

**Per-section verification**

- §1 operator + block-circulant algebra + $d$-dim generalization:
  derived, marked (self-checkable: $P$ = exact inverse for an LTI circuit,
  so GMRES must converge in 1 iteration on any `ac/*`-class fixture — the
  natural unit test).
- §1 degradation analysis: derived (perturbation bound is standard).
- §2 plug-in point: verified against `converger.zig applyPreconditioner`
  (the callback slot exists; only spectral implementations are missing).
- §3/§4: design spec.

**Our implementation**

- Exists (the slot + ingredients): `modules/analysis/src/helper/converger.zig`
  (`applyPreconditioner`, GMRES core),
  `modules/solvers/src/freq_solve.zig` (per-$\omega$ refill/refactor
  pattern to copy), `modules/solvers/src/direct.zig`,
  `modules/solvers/src/fft.zig`.
- Consumers: Krylov-HB in
  [pss-shooting-harmonic-balance](../analysis/pss-shooting-harmonic-balance.md),
  [pac](../analysis/pac.md)/[pxf](../analysis/pxf.md) matrix-free path,
  [qpss](../analysis/qpss.md) (future — hard requirement),
  [mpde-envelope](../analysis/mpde-envelope.md) Fourier-envelope steps.
- Bench fixtures: `benchmark/fixtures/hb/*` (iteration-count acceptance),
  `benchmark/fixtures/ac/*` (LTI 1-iteration check).
