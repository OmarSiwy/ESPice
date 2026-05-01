# Matrix-Exponential Integrators (MATEX)

Exponential time differencing with Krylov-subspace $e^{Ah}v$: larger
stable steps than BDF/trap for large linear(ized) networks.

The explicit `.matex` query implements a fixed-matrix R-MATEX path in
`src/analysis/tran/matex.zig`. The theory below also describes extensions;
I-MATEX, nonlinear exponential Rosenbrock integration, automatic linearity
detection, and GPU Arnoldi execution are not implemented here.

## 1. Mathematical specification

### Exact solution of the linear circuit DAE

The MNA system of a linear network (MATEX eq. 1):

$$
C\,\dot x(t) = -G\,x(t) + B\,u(t),
$$

$C$ from capacitive/inductive elements, $G$ conductive, $B$ the input
selector. For nonsingular $C$, with $A = -C^{-1}G$ and
$b(t) = C^{-1}B\,u(t)$ (MATEX eq. 3), the variation-of-constants formula
gives the **exact** step (MATEX eq. 4):

$$
x(t+h) = e^{hA}\,x(t) + \int_0^h e^{(h-\tau)A}\, b(t+\tau)\, d\tau .
$$

For piecewise-linear inputs (slope constant within the step) the integral
evaluates in closed form (MATEX eq. 5):

$$
x(t+h) = e^{hA}\Big(x(t) + A^{-1}b(t) + A^{-2}\tfrac{b(t+h)-b(t)}{h}\Big)
- \Big(A^{-1}b(t+h) + A^{-2}\tfrac{b(t+h)-b(t)}{h}\Big).
$$

No truncation error in time: the only errors are the PWL input assumption
and the approximation of $e^{hA}v$. Consequently $h$ is bounded by input
**transition spots** (source slope breaks), not by stability or LTE:
between two transition spots the step can be the whole interval.

### Krylov approximation of $e^{hA}v$

$A$ is huge; $e^{hA}$ is never formed. Build the Krylov subspace
$K_m(A, v) = \mathrm{span}\{v, Av, \dots, A^{m-1}v\}$ by Arnoldi:
$A V_m = V_m H_m + h_{m+1,m} v_{m+1} e_m^{\mathsf T}$, then (MATEX §2.3)

$$
e^{hA} v \;\approx\; \|v\|\, V_m\, e^{h H_m} e_1 ,
$$

with $H_m$ ($m \times m$, $m \sim 10\text{-}100$) exponentiated densely
(Padé/scaling-squaring). Posterior error estimate (MATEX eq. 7):

$$
\|r_m(h)\| = \|v\|\, \big| h_{m+1,m}\, e_m^{\mathsf T}\, e^{h H_m} e_1 \big| ,
$$

grow $m$ until $\|r_m\| < \epsilon$. Key reuse property: $H_m$ is
$h$-independent: **one subspace serves every $h$ in the reuse window** by
rescaling $e^{hH_m}$, which is what makes adaptive stepping nearly free.

### Stiffness: inverted and rational Krylov

Standard Krylov approximates the *large*-magnitude eigenvalues of $A$
first: exactly the components $e^{hA}$ kills: so stiff circuits need
large $m$. Two spectral transforms fix this (MATEX §3.3):

- **I-MATEX (inverted)**: build $K_m(A^{-1}, v)$ (i.e. $-G^{-1}C$;
  factor $G$ once); relation
  $A^{-1}V_m = V_m H'_m + h'_{m+1,m}v_{m+1}e_m^{\mathsf T}$, compute
  $e^{hA}v \approx \|v\| V_m e^{h H'^{-1}_m} e_1$. Small-magnitude
  eigenvalues of $A$ (the slow, behavior-defining ones) become dominant.
- **R-MATEX (rational / shift-and-invert)**: basis
  $K_m\big((I - \gamma A)^{-1}, v\big)$: factor $(C + \gamma G)$ once;
  $\gamma$ set near the order of the intended timestep, and the method is
  insensitive to its exact value. Confines the whole spectrum into the
  unit disk; smallest $m$ of the three, works with singular $C$
  (no explicit $A$, factor $C + \gamma G$ directly: regularization-free).

Cost model per step: $m$ sparse triangular solves on a **once-factored**
matrix + one small dense exponential: vs BDF/trap's refactor-per-$h$-change
(or fixed-$h$ lockstep). MATEX reports ~13× over fixed-step trap on IBM
power-grid benchmarks. Further axis (the paper's framework): decompose the
input sources into groups by transition-spot pattern, simulate each group
independently (superposition, linear system), sum: turns breakpoint-dense
inputs into per-group sparse ones.

### Nonlinear extension

*(derived, not source-verified)* Exponential Rosenbrock/EPIRK methods apply
the same machinery to $\dot x = F(x)$ via per-step linearization
$F(x) \approx F(x_k) + J_k (x - x_k)$:

$$
x_{k+1} = x_k + h\,\varphi_1(hA_k)\,C^{-1}F(x_k), \qquad
\varphi_1(z) = \frac{e^z - 1}{z},
$$

with $A_k = -C^{-1}J_k$ and higher-order correction stages using
$\varphi_2, \varphi_3$; the $\varphi$-functions evaluate on the same Krylov
subspace (augmented-matrix trick: exponentiating
$\tilde A = \left(\begin{smallmatrix} A & v \\ 0 & 0 \end{smallmatrix}\right)$
yields $\varphi_1(A)v$ in its upper-right block). Device-limiting and the SPICE acceptance gates do not
transfer directly: error control is by embedded stages, which is the main
open engineering question for a SPICE-grade nonlinear MATEX.

**Implementation status:** `src/analysis/tran/matex.zig` factors
$(C + \gamma G)$ once, builds a rational Krylov basis per step, and evaluates
the small matrix exponential with scaling and squaring. Source transition
spots and the output step cap bound the march. This is a linear-circuit
method selected explicitly; it does not verify linearity or switch a
nonlinear circuit to a different integrator.

## 2. Flow explanation

(R-MATEX flow; reuse and adaptive recovery below are extensions.)

**Eligibility.** MATEX applies when the dynamic part is linear (or per-step
linearized): power grids, interconnect, RC/RLC reduction targets: the
`rc_ladder`-class fixtures where the matrix never changes. Automatic
eligibility detection is a target; `has_charge` alone does not establish
linearity.

**Phases.** (1) Setup: assemble $G$, $C$ once; factor $(C + \gamma G)$
(R-MATEX, $\gamma \approx$ intended $h$); collect all source transition
spots (the existing breakpoint list *is* this set). (2) March: per step,
choose $h$ = distance to next transition spot (cap: waveform output
resolution); Arnoldi to tolerance $\epsilon$ (posterior estimate), then
advance by the closed-form PWL update. (3) Between transition spots there
is no LTE loop, no Newton, no refactor. Reusing a subspace across output
steps remains a target; the implementation rebuilds it per step.

**Target failure handling.** Arnoldi hitting $m_{\max}$ without meeting
$\epsilon$ → halve $h$ (shrinks $\|r_m\|$ superlinearly) or re-pick
$\gamma$ and refactor (rare). Singular $C$: use R-MATEX only (I-/standard
variants need invertibility or regularization).

The implementation uses the retained basis at $m_{\max}$ and has a local
forward-Euler fallback when the projected matrix is singular; it does not
implement the adaptive recovery described above.

**Implementation notes.**
- The Arnoldi scratch, the pivot arrays and the posterior-estimate workspace
  (`max(n, 7*m_max^2)`) are all sized from $m_{\max}$, so any $m_{\max}$ works;
  they were once fixed at 256 and overflowed above it (commit `c9b25b2`, no
  deck bytes changed).
- $b(t+h)$ of one step is reused as $b(t)$ of the next, and the $C + \gamma G$
  values are built with `Circuit.combinePlanes` (operands swapped relative to
  the transient's $G + \alpha C$), with per-run scratch in one arena
  (commit `bd698f3`). Callgrind Ir: a 200-stage RC ladder at `.matex 1u 5m`
  454.1M to 292.1M (-35.7%, peak RSS 20.6 to 22.1 MB of arena slack),
  `matex/sine` 26.13M to 18.75M (-28.2%).

**Knobs.** $\epsilon$ (Krylov posterior tolerance: plays the role of
reltol on the exponential), $m_{\max}$, $\gamma$ (insensitive; order of
typical $h$), output resolution cap on $h$. Spectre-bundle mapping:
$\epsilon$ scales with `reltol`; there is no `trtol` analogue because
there is no LTE.

## 3. Pseudo-code, CPU sequential (including target subspace reuse)

```
matex_transient(G, C, sources, t_stop, eps, gamma):
    TS = sorted transition spots of all sources     # = breakpoint list
    [L,U] = lu(C + gamma*G)                         # ONE factorization
    x = dc_solve(); t = 0
    while t < t_stop:
        h = min(next(TS) - t, h_output_cap)
        v = x + Ainv_b_terms(t, h)                  # PWL closed-form pieces
        # Arnoldi on (I - gamma*A)^{-1} via the saved LU
        v1 = v/||v||
        for j in 1..m_max:
            w = U \ (L \ (C * v_j))                 # rational Krylov apply
            MGS orthogonalize w against v_1..v_j -> H
            if posterior_error(H, h) < eps: m = j; break
        x = ||v|| * V_m * expm(h * Hm_tilde) * e1 - P(t, h)
        t += h
        # reuse: any t' in (t, next TS) needs only a rescaled expm(h'*Hm)
```

## 4. Parallel execution

Everything runs on the host today. Not implemented (design notes):

- **Arnoldi kernels**: SpMV ($C v_j$), triangular solves on the fixed
  factors (level-scheduled, or replaced by a few Jacobi-preconditioned GMRES
  sweeps), MGS dots and axpys, all data-parallel over $n$ with thread-0
  scalar Hessenberg bookkeeping between barriers.
- **The small dense $e^{hH_m}$** ($m \le 100$): single-block
  scaling-and-squaring, negligible.
- **Superposition decomposition** (the MATEX framework's own axis): input
  source groups are independent complete simulations of the same matrix, one
  group per device, stream or lane, summed at output points.
- **Step parallelism within a reuse window**: all output points sharing one
  Krylov subspace evaluate $\|v\| V_m e^{h_i H_m} e_1$ for many $h_i$ at once
  (a batch of tiny dense ops and one tall-skinny GEMM).

The outer march across transition spots stays sequential (each step's $v$
depends on the previous $x$), but it has one step per input transition, not
per LTE-limited timestep.

## Solvers used and extensions

| Phase | Solver doc | Impl |
|---|---|---|
| One-time factorization of $(C + \gamma G)$ (R-MATEX) | [klu-pipeline.md](../solvers/klu-pipeline.md), [gilbert-peierls-lu.md](../solvers/gilbert-peierls-lu.md), [btf-permutation.md](../solvers/btf-permutation.md), [amd-ordering.md](../solvers/amd-ordering.md) | `src/solver/direct.zig`; small projected solves use `dense_lu.zig` |
| Arnoldi triangular solves on GPU (level-scheduled or GMRES-replaced) | [gpu-sparse-lu.md](../solvers/gpu-sparse-lu.md) | requirement |
| Automatic linear-circuit eligibility detection | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) (`matrix_sig`) | target; current `.matex` selection is explicit |

---

**Sources fetched**

| Source | Status |
|---|---|
| Zhuang, Weng, Lin, Cheng, "MATEX: A Distributed Framework for Transient Simulation of Power Distribution Networks", arXiv:1511.04519 | **fetched, verified**: eqs. 1-8, Algorithms 1-2, I-MATEX/R-MATEX relations, transition-spot stepping, subspace-reuse property, 13× claim |
| arXiv:1505.06699 (exponential integration for power delivery, journal version) | located via search, not separately fetched |
| Nonlinear exponential-Rosenbrock extension | **derived, not source-verified** ($\varphi$-function formulation from knowledge) |

**Per-section verification**

- §1 exact update, PWL closed form, Arnoldi relation, posterior error,
  I-/R-MATEX: verified against fetched arXiv text (equation-level).
- §1 nonlinear extension: derived, marked.
- §2-§3: R-MATEX design, partly implemented as described above; subspace
  reuse and adaptive recovery remain targets.
- §4: design notes.

**Our implementation**

- `src/analysis/tran/matex.zig`: fixed-matrix R-MATEX, source transition
  collection, rational Arnoldi, and the projected matrix exponential.
- `src/solver/direct.zig`: retained sparse factors;
  `src/solver/dense_lu.zig`: projected dense solves.
- Fixtures: `tests/fixtures/matex/`; `tests/fixtures/stress/scaling_rc_ladder_*`
  are the rc_ladder-class decks that would judge it at scale.
