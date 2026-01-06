# The KLU Pipeline: Pivoting, Refactorization, Growth & Condition Monitoring, Refinement

## 1. Mathematical specification

**Full pipeline (thesis ch. 3).** KLU solves $Ax=b$ as

$$\bigl(P\,R\,A\,Q\bigr)\,Q^T x = P\,R\,b, \qquad PRAQ = LU + F,$$

where $R$ = row scaling (diagonal; row-max or row-sum), $P$ = rows
(transversal ∘ BTF ∘ partial pivoting), $Q$ = columns (BTF ∘ AMD), $LU$ =
factored diagonal blocks, $F$ = unfactored off-diagonal entries. Phases:
*analyze* (orderings, once per pattern), *factor* (symbolic+numeric with
pivoting, once per pattern), *refactor* (numeric only, every subsequent
matrix), *solve*.

**Threshold partial pivoting with diagonal preference (thesis §2.9).** At
step $k$ with candidate vector $x$ (result of the column's triangular
solve) and column max $a_{\max} = \max_{i \ge k} |x_i|$:

$$\text{pivot} =
\begin{cases}
x_{kk} & \text{if } |x_{kk}| \ge \tau \, a_{\max} \\
\arg\max_i |x_i| & \text{otherwise},
\end{cases}
\qquad \tau = 0.001 \text{ (KLU default)}.$$

Multipliers obey $|l_{ik}| \le 1/\tau$. Diagonal preference exists because
the ordering was computed for the diagonal pivot sequence — an off-diagonal
pivot perturbs $P$ away from AMD's assumption and can add fill (thesis
§2.8); circuit matrices are close to diagonally dominant after gmin, so a
loose $\tau$ almost always keeps the diagonal while retaining an escape
hatch for MNA's structurally-zero-diagonal rows (voltage sources).

**Numeric refactorization (thesis §3.2, §4.2.6).** For subsequent matrices
$A'$ with the same pattern (Newton iterations, timesteps): reuse $P, Q$,
the L/U patterns, and the pivot sequence; recompute only values. No DFS, no
pivot search, no pruning. This is valid because the reach sets depend only
on the pattern and pivot order, both frozen. Cost drops to a pure replay of
flops(LU); thesis table 3–6 measures refactor ≈ 3–4× cheaper than factor
and ≈ 8× cheaper than analysis+factor. The risk: the frozen pivot sequence
can become numerically bad for the new values — hence monitoring.

**Pivot-growth monitoring (thesis §2.11).** Growth factor
$\rho = \max_k \max_{ij} |a^{(k)}_{ij}| / \max_{ij} |a_{ij}|$ bounds the
backward error of Gaussian elimination ($\|E\| \le c(n)\, u\, \rho
\|A\|$ in the standard Wilkinson analysis — derived, not source-verified);
large $\rho$ = unstable elimination. KLU computes the cheap reciprocal
per-column variant (thesis eq. 2–35, column-scaling invariant):

$$\frac{1}{\rho} = \min_j \frac{\max_i |a_{ij}|}{\max_i |u_{ij}|}.$$

Our refactor-time variant is a per-pivot decay test: fail the refactor when
$|u_{kk}| < \gamma \cdot \max_i |{\text{column }k}|$ (with $\gamma$ =
`refactor_growth_limit`, default $10^{-12}$), i.e. detect a reused pivot
collapsing relative to its column *during* the replay, and answer by
re-running the full pivoting factorization.

**Condition estimation (thesis §2.12).** $\kappa_1(A) = \|A\|_1
\|A^{-1}\|_1$; $\|A^{-1}\|_1$ is estimated without forming $A^{-1}$ by
Hager's optimization of $F(x) = \|A^{-1}x\|_1$ over $\|x\|_1 \le 1$, each
iteration solving $Ax=b$ and $A^Tx=b$ with the existing factors, refined
per Higham (≤ 5 iterations, plus the alternating-sign probe
$b_i = (-1)^{i+1}(1 + \tfrac{i-1}{n-1})$, final estimate the max of both).
Cost: a few solves — cheap diagnostics for "is this Newton matrix
trustworthy".

**Iterative refinement.** Given the computed $\hat x$: repeat
$r = b - A\hat x$ (in the *original* values, not the factors),
$Ad = r$ via the existing factorization, $\hat x \mathrel{+}= d$. Each step
multiplies the error by roughly $u\,\kappa(A)$ (derived, not
source-verified); one or two steps recover solve accuracy lost to a loose
$\tau$ or a marginal reused pivot — the standard companion of threshold
pivoting.

## 2. Flow explanation

The pipeline is a state machine keyed to the circuit-simulation matrix
lifecycle (thesis §3.2: pattern fixed once, values change every iteration):

1. **init (once per pattern):** BTF+AMD → `q`; allocate all factor/solve
   workspaces; nothing numeric yet.
2. **first factor:** full Gilbert–Peierls with threshold pivoting; stores
   L/U patterns *and* the topological solve order of each U column, plus
   `prow = pinv ∘ row_idx` so refactor scatters $A$'s values directly into
   permuted coordinates.
3. **steady state — refactor per Newton iteration:** straight-line replay:
   zero the stored pattern, scatter new values through `prow`, replay the
   stored U order (saxpy per entry), divide the stored L pattern by the new
   diagonal. Zero allocation, zero search. Fails loudly on pivot
   collapse/growth.
4. **fallback:** any refactor failure → full factor (fresh pivot order) on
   the same values; only if *that* fails does the caller see
   `SingularMatrix` (and answers with its own ladder — gmin retry etc., see
   `homotopy-continuation.md`).
5. **solve(+refinement):** permuted forward/back substitution; optional 1–2
   refinement steps against the caller's live `vals` slice.

Layer-cake of matrix-change frequency (ours): identical values → `factor`
is a no-op (`vcopy` memcmp bypass); same pattern/new values → refactor;
pivot decay → full factor; pattern change → impossible by construction
(pattern frozen at compile). One notable deviation from KLU: we do not
implement row scaling $R$ (MNA + gmin keeps rows adequately balanced;
`iter_refine_steps` is the recovery knob if a fixture proves otherwise).

## 3. Pseudo-code, CPU sequential

Refactor (matches `direct.zig Lu.refactor` exactly):

```
refactor(col_ptr, vals, growth_limit):        # requires factored == true
  for k in 0..n:
    c = q[k]
    for i in ui[up[k]..up[k+1]]: w[i] = 0     # zero the STORED pattern only
    for i in li[lp[k]..lp[k+1]]: w[i] = 0
    w[k] = 0
    for p in col_ptr[c]..col_ptr[c+1]:
      w[prow[p]] = vals[p]                    # scatter in permuted rows

    for p in up[k]..up[k+1]:                  # replay stored topo order
      i = ui[p]; uki = w[i]; ux[p] = uki
      for pl in lp[i]..lp[i+1]: w[li[pl]] -= lx[pl] * uki

    d = w[k]                                  # the SAME pivot position
    if d == 0 or !finite(d): fail SingularMatrix
    udiag[k] = d
    if growth_limit > 0:                      # pivot-growth monitor
      cmax = max(|d|, max |w[li[p]]| over L pattern)
      lx[p] = w[li[p]] / d for all p
      if |d| < growth_limit * cmax: fail SingularMatrix
    else:
      lx[p] = w[li[p]] / d for all p

caller (Solver.factorInner):
  if factored: refactor(...) catch { factored = false; full factor(...) }
  else: full factor(...)

solve_with_refinement(rhs, x, steps):
  x = rawSolve(rhs)
  repeat steps times:
    r = rhs - A x            # CSC SpMV against the LIVE vals slice
    d = rawSolve(r)
    x += d

condition_estimate(factors):                  # Hager/Higham, KLU §4.2.9
  x = ones/n
  repeat <= 5:
    y = solve(A, x); s = sign(y); z = solveT(A, s)
    if ||z||_inf <= z.x: break else x = e_argmax(z)
  est1 = ||y||_1
  b_i = (-1)^(i+1) (1 + (i-1)/(n-1)); est2 = 2||solve(A,b)||_1 / (3n)
  return max(est1, est2) * ||A||_1
```

## 4. Pseudo-code, GPU parallel

Refactor is the piece of the pipeline that maps to the GPU — it is exactly
the "numeric factorization on a frozen pattern" that GLU-style level-set
kernels assume (they too pivot on the host once; see `gpu-sparse-lu.md`).

```
# CPU once: full factor -> patterns, pivot order, level sets of the column DAG
# device: SoA arrays lp/li/lx, up/ui/ux, udiag, prow, vals — allocate once

gpu_refactor():
  parfor columns k: zero stored pattern; scatter vals through prow[]
  for level in levels:                        # serial chain — DAG depth
    parfor k in level:                        # block per column
      replay up[k]..up[k+1] in stored order   # per-entry saxpy = warp work
      d = w_k[k]
      if d == 0 or |d| < growth_limit * colmax_k:
        atomicExch(fail_flag, k)              # growth monitor ON DEVICE
      udiag[k] = d; scale L column by 1/d
    grid barrier                              # cooperative launch
  if fail_flag set: host does full CPU factor (fresh pivots), re-uploads
                    pattern + levels          # the fallback stays host-side

gpu_solve_batched(RHS[m][n]):                 # m independent right-hand sides
  parfor b in 0..m:                           # sweeps/MC/harmonics
    sequential forward/back substitution per b (levels within b optional)
  # refinement: r = b - A x is one batched SpMV — fully parallel

what fundamentally serializes:
  - level chain of the column DAG (refactor)  — DAG depth lower bound
  - substitution order within one RHS (solve) — same DAG, transposed roles
  - full factor with pivoting: pivot choice at step k rewrites the pattern
    that later reach sets depend on -> symbolic+pivot stays on CPU, full stop
```

Fit with our engine: `src/gpu_solver.zig` currently ships whole-Newton
megakernel solves (JFNK/GMRES — no factorization on device, see
`newton-raphson-convergence.md`); a device level-set refactor+solve is the
alternative "direct Newton on GPU" path and reuses the exact arrays
`direct.zig` already stores (`up/ui` in topological order is the enabling
invariant). Host↔device traffic per iteration: `vals` up, `x` down —
same shape as the existing staged-prefix protocol.

---

**Sources fetched:** Palamadai Natarajan thesis (fetched — §§2.9–2.12, 3.2,
3.6.2 [table 3–6 phase timings], 4.2.6 klu_refactor, 4.2.8
klu_rec_pivot_growth, 4.2.9 klu_estimate_cond_number); ngspice sources for
the caller-side retry ladder (see `homotopy-continuation.md`).

**Verification status:** §1 pipeline equations, threshold rule + default
τ=0.001, refactor semantics, reciprocal growth eq. 2–35, Hager/Higham
estimator incl. probe vector — source-verified against thesis. §1 Wilkinson
backward-error form and refinement convergence factor — derived, not
source-verified (standard numerical analysis; Davis book is the paywalled
reference). §2/§3 — verified against `direct.zig` (the growth monitor as a
*refactor-time* per-pivot test is our variant, not KLU's post-hoc
diagnostic; noted as such). §4 — derived, not source-verified (design
aligned with GLU3.0's host-pivoting assumption).

**Our implementation:** `modules/solvers/src/direct.zig` (`Params`
{pivot_tol, refactor_growth_limit, iter_refine_steps}, `Solver.factor`
bypass + fallback chain, `Lu.refactor`, `refine()`); Newton caller
`modules/analysis/src/helper/converger.zig` (`newton()`, `matrix_sig`
factor-once). Condition estimation: not implemented (documented here as the
KLU reference design). Scaling fixtures:
`benchmark/fixtures/scaling/inverter_chain_{256,1k,4k}` (refactor per Newton
iteration), `rc_ladder_100k` (factor-bypass on linear circuits),
`benchmark/fixtures/convergence/{diode_bridge,schmitt,high_gain_fb}`
(pivot-collapse → full-factor fallback).
