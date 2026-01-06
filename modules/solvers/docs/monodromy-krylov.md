# Monodromy-Krylov Machinery (Matrix-Free Shooting)

Monodromy matrix-vector products via sensitivity propagation, GMRES on the
shooting Jacobian, Krylov recycling. Serves PSS shooting, MFT-QPSS, PXF's
time-domain adjoint.

**Status: not implemented** — `pss/pss.zig` builds the shooting Jacobian
by finite differences (one period integration per column, dense LU). This
doc is the spec for the Krylov replacement (RESEARCH.md checklist item 3).

## 1. Mathematical specification

### Monodromy products without forming Φ

The shooting Newton solves $(\Phi - I)\,\Delta x_0 = -(x(T) - x_0)$ with
$\Phi = \partial x(T)/\partial x_0$ the monodromy matrix. Differentiate the
inner integrator's step equations instead of differencing them. One
implicit step from $x_s$ to $x_{s+1}$ at coefficients $(\alpha, \beta)$
satisfies $F_{\text{dyn}}(x_{s+1}; x_s) = 0$; implicit differentiation
w.r.t. the initial condition gives the **forward sensitivity recurrence**

$$
\underbrace{\big(G_{s+1} + \alpha\, C_{s+1}\big)}_{A_{s+1},\ \text{the step's Newton matrix}}\, w_{s+1}
\;=\; \beta\, C_s\, w_s
\qquad (\text{BE: } \alpha = \beta = \tfrac1h;\ \ \text{trap adds the } i\text{-prev chain}),
$$

so $\Phi v = w_S$ from $w_0 = v$: **one back-substitution per timestep on
the factorization that step already produced**, plus one SpMV with the
saved $C_s$. Never form $\Phi$ ($n^2$ dense) — a product costs
$O(S \cdot \text{nnz}(LU))$.

For trapezoidal the exact recurrence carries the dynamic-current
sensitivity too: with $i_s = \alpha(q_s - q_{s-1}) - i_{s-1}$, the chain
adds a second term; writing $u_s = \partial i_s/\partial x_0 \cdot v$,

$$
A_{s+1} w_{s+1} = \alpha C_s w_s + u_s, \qquad
u_{s+1} = \alpha (C_{s+1} w_{s+1} - C_s w_s) - u_s ,
$$

(BE drops $u$). Getting this chain right is what makes matrix-free $\Phi v$
*exact* — the FD flow-map derivative it replaces was only $O(\epsilon)$.

### GMRES on the shooting Jacobian

Solve $(\Phi - I)\Delta x_0 = -\phi$ matrix-free. Why Krylov converges
fast here: $\Phi$'s eigenvalues are the **Floquet multipliers**
$\mu_i = e^{\lambda_i T}$; every mode with time constant $\ll T$ has
$|\mu_i| \approx 0$, so the spectrum of $\Phi - I$ clusters at $-1$ with a
handful of outliers (slow modes, high-Q resonances, the $\mu \to 1$ mode
of near-autonomous circuits). GMRES iteration count tracks the outlier
count, not $n$ — typically ≤ 10 even for large circuits (the
Telichevesky/Kundert/White observation that made SpectreRF PSS scale;
concept verified via rf-sim.pdf, derivation marked derived below). No
preconditioner is usually needed; when it is (high-Q), the recycling
below is the answer before any explicit preconditioner.

### Adjoint (transpose) recurrence

PXF/pnoise-adjoint need $(\Phi - I)^{\mathsf H} y = c$ products:
transpose the recurrence and run it **backward in step order**,

$$
z_s = C_s^{\mathsf T}\, \beta\, A_{s+1}^{-\mathsf T} z_{s+1},
$$

each step one `solveT` on the *same* saved factorization. Same cost, same
storage, opposite traversal — the time-domain twin of the conversion-matrix
adjoint in [lptv-block-solves.md](lptv-block-solves.md).

### Storage

The recurrence needs, per step: the factorization of $A_s$ and $C_s$'s
values. $S \times (\text{nnz}(LU) + \text{nnz}(C))$ floats — for
$S = 256$, a 10k-nnz-LU circuit ≈ 20 MB; affordable, and the factors were
already computed during the period integration (the *only* change is not
throwing them away). Fallback when memory-bound: checkpointing — store
every $k$-th factor, re-factor the gaps during the sweep
(classic adjoint checkpointing trade, $O(S/k)$ storage for $O(k)$ extra
refactors per product).

### Krylov subspace recycling (GCRO-DR style)

*(derived, not source-verified — Parks, de Sturler et al., SIAM J. Sci.
Comput. 28(5) 2006, is paywalled)*

Consecutive shooting-Newton iterations (and adjacent sweep points in
pnoise/PXF, and adjacent MFT cycle systems) solve slowly-varying systems
with the same few outlier eigenvalues. Recycling keeps a $k$-dimensional
subspace $U$ spanning approximate invariant directions (harmonic Ritz
vectors of the previous solve) and solves the next system deflated:

- maintain $C = A U$ with $C^{\mathsf H} C = I$ (GCRO split);
- solve the projected problem in $U$ directly, run GMRES on the
  $(I - CC^{\mathsf H})A$-projected complement;
- after each solve, recompute the $k$ best harmonic Ritz pairs from the
  combined subspace → next $U$ (this is the DR/"deflated restart" part).

Effect: the outliers that dominate GMRES iteration count are solved
"for free" from the second Newton iteration on — measured payoffs in the
literature are 2–5× on sequences of related systems. Ordering of value
here: (1) between Newton iterations of one shooting solve, (2) between
sweep points (pnoise frequencies), (3) between MFT cycles. Simplest
correct start: plain deflated restarts within one solve, recycling across
solves later — the data structure ($U$, $C$, $k \lesssim 10$ vectors) is
identical.

### Cost model vs the FD-dense method

Per shooting-Newton iteration: FD-dense = $(n{+}1)$ period integrations
$= O(n \cdot S \cdot \text{lu})$ + dense $O(n^3)$ solve. Krylov =
1 period integration + $m_{\text{GMRES}} \cdot S$ back-substitutions,
$m \ll n$. Crossover is immediate for $n \gtrsim$ tens; the FD path
remains the right *debug oracle* (it validates the recurrence).

## 2. Flow explanation

Integration into the existing code:

1. `integrateOnePeriod` (pss.zig) already runs `converger` per step whose
   `Workspace.slv` holds the factored $A_s$ at acceptance — the change is
   a per-step **factor snapshot** (copy of the numeric LU arrays; symbolic
   is shared) plus a $C_s$ vals snapshot, both appended to a period tape.
2. Shooting iteration: integrate (filling the tape) → $\phi$ → GMRES on
   $(\Phi - I)$ where each $\Phi v$ replays the tape forward
   (`solve` per step) and each adjoint product replays backward
   (`solveT` per step). The GMRES core is `converger.zig`'s existing
   Givens/MGS machinery — reuse it, do not re-implement (it needs only an
   operator callback where `jvProduct` currently sits).
3. Convergence/tolerances: outer shooting tol unchanged; inner GMRES tol
   tied to the outer residual (inexact-Newton forcing, e.g.
   $\eta = \min(0.1, \|\phi\|)$ — cheap Eisenstat–Walker flavor, derived).
4. Failure handling: GMRES stagnation → grow restart, then deflated
   restart, then fall back to the FD-dense path (which stays as the
   guarantee rung, mirroring the OP ladder philosophy).
5. MFT-QPSS reuse: the same tape/replay serves each of the $2K{+}1$
   carrier cycles; the cycles' recurrences are independent (parallel), and
   the small spectral coupling solve sits on top.

## 3. Pseudo-code, CPU sequential

```
integrate_period_with_tape(x0):
    for s in 0..S:
        newton step (existing PeriodHook)      # factors A_{s+1} anyway
        tape[s] = { lu_snapshot(ws.slv), C_vals_snapshot }
    return x_T, tape

monodromy_apply(tape, v):                      # w = Phi * v
    w = v; u = 0
    for s in 0..S:
        rhs = alpha * C[s] @ w  (+ u if trap)
        w   = tape[s].lu.solve(rhs)
        u   = alpha*(C[s+1] @ w - C[s] @ w_prev) - u    # trap chain
    return w

adjoint_apply(tape, z):                        # y = Phi^T * z
    for s in S-1..0: z = beta * C[s]^T @ tape[s].lu.solveT(z)
    return z

pss_krylov(x0):
    U = recycled subspace (empty first call)
    repeat:
        x_T, tape = integrate_period_with_tape(x0)
        phi = x_T - x0; if ||phi|| < tol: break
        dx0 = gcro_dr(op = v -> monodromy_apply(tape, v) - v,
                      rhs = -phi, recycle = U, tol = min(0.1, ||phi||))
        U = harmonic_ritz_update(U)
        x0 += dx0
```

## 4. Pseudo-code, GPU parallel

- **Within one $\Phi v$**: the step loop is sequential (recurrence), but
  each step is a sparse triangular solve + SpMV — level-scheduled solves
  per [gpu-sparse-lu.md](gpu-sparse-lu.md), or keep the whole replay
  on-device with the tape resident in GPU memory (it was produced there if
  the period integration ran in the megakernel).
- **Across Krylov vectors**: block-GMRES — propagate all $m$ basis
  candidates (or the $2K{+}1$ MFT cycles' vectors) through the recurrence
  as a multiple-RHS blocked triangular solve per step; this is the axis
  that actually fills a GPU, since single-vector triangular solves are
  latency-bound.
- **FD-column fallback** (today's method) parallelizes as independent
  period-integration lanes — worth keeping as the batched oracle.
- Recycling bookkeeping ($U$ updates, small Ritz eigenproblems) is
  thread-0/host scalar work, same policy as the megakernel's GMRES
  bookkeeping.

```
kernel monodromy_block_apply(tape, V[m]):      # all Krylov vectors at once
    for s in 0..S:                             # sequential
        parallel: RHS = alpha * C[s] @ V       # SpMM, grid-stride
        parallel: V = level_sched_solve(tape[s].lu, RHS)   # multi-RHS
        grid_barrier
```

---

**Sources fetched**

| Source | Status |
|---|---|
| Kundert rf-sim.pdf §4.1.4 (shooting, sensitivity of final state, Krylov acceleration) | fetched (prior pass), verified — problem statement + "Krylov subspace methods have been applied to accelerate... shooting methods" |
| Telichevesky/Kundert/White DAC'95 (matrix-implicit shooting) | **paywalled — derived, not source-verified** (recurrence + Floquet clustering argument from knowledge; consistent with rf-sim) |
| Parks, de Sturler et al., GCRO-DR (SISC 2006) | **paywalled — derived, not source-verified** (GCRO split + harmonic-Ritz deflated restart from knowledge) |
| Eisenstat–Walker forcing terms | **paywalled — derived** (simple min-rule variant stated) |

**Per-section verification**

- §1 forward/adjoint recurrences: derived by implicit differentiation of
  the exact step equations in `pss.zig`/`tran.zig` (companion forms
  verified against source); the trap dynamic-current chain matches the
  implemented `i_prev` update rule.
- §1 Floquet clustering, GCRO-DR, checkpointing: derived, marked.
- §2–§4: design spec; existing pieces verified (`converger.zig` GMRES
  core, `direct.zig` solve/solveT, `pss.zig` FD path as oracle).

**Our implementation**

- Exists: `modules/analysis/src/pss/pss.zig` (FD-dense shooting — the
  oracle), `modules/analysis/src/helper/converger.zig` (GMRES core to
  reuse), `modules/solvers/src/direct.zig` (`solve`/`solveT` on frozen
  factors).
- Consumers: [pss-shooting-harmonic-balance](../analysis/pss-shooting-harmonic-balance.md)
  Krylov upgrade, [qpss](../analysis/qpss.md) MFT (future),
  [pxf](../analysis/pxf.md) time-domain adjoint (future),
  [periodic-noise](../analysis/periodic-noise.md) adjoint upgrade.
- Bench fixtures: `benchmark/fixtures/pss/*` (correctness vs the FD
  oracle is the acceptance test).
