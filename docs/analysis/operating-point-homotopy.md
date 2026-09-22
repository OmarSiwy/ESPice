# Operating Point + Homotopy Ladder

Newton with device limiting, dynamic gmin stepping, source stepping, and
pseudo-transient continuation.

## 1. Mathematical specification

### MNA system

Modified nodal analysis assembles the DC circuit equations as a nonlinear
algebraic system

$$
F(x) = 0, \qquad F : \mathbb{R}^n \to \mathbb{R}^n,
$$

where $x$ stacks node voltages and branch currents (branch rows exist for
voltage-defined elements: independent V-sources, inductors, controlled
sources). Row $i$ of $F$ is either a KCL residual (sum of currents leaving
node $i$, units A) or a KVL/branch residual (units V). The Jacobian

$$
J(x) = \frac{\partial F}{\partial x}
$$

has conductance units on KCL rows; its sparsity pattern is fixed by the
topology and is frozen once at setup (symbolic ordering/factorization done
exactly once, numeric refactor per iteration).

### Newton iteration with device limiting

The damped-Newton update at iterate $k$:

$$
J(x^k)\,\Delta x^k = -F(x^k), \qquad x^{k+1} = x^k + s^k \Delta x^k .
$$

Direction-preserving damping: if $\max_i |\Delta x_i| > \delta_{\text{clamp}}$
the whole step is scaled by $s^k = \delta_{\text{clamp}} / \max_i|\Delta x_i|$
(component-wise clamping would decouple the step and violate linear rows;
scaling keeps the Newton direction, under which linear-row residuals decay
geometrically for any $s \in (0,1]$).

Device limiting is the SPICE globalization: instead of damping the whole
vector, each strongly nonlinear device privately replaces its controlling
junction voltage $v$ by a limited value $\tilde v = \mathrm{lim}(v, v_{\text{old}})$
(pnjlim for junctions, fetlim/limvds for FETs) and stamps the *companion
correction* so the assembled residual stays consistent:

$$
i_{\text{stamp}} = i(\tilde v) + \frac{\partial i}{\partial v}(\tilde v)\,(v - \tilde v),
$$

i.e. the device is evaluated at $\tilde v$ and linearly extrapolated back to
the actual node voltage. This changes the *system being solved* per iteration
(Xyce math doc §4.2: "voltage limiting directly changes the right hand side
vector... it changes the set of equations to be solved"), which is why it is
incompatible with line-search/backtracking globalization — limiting depends on
the path taken, so a monotone-$\|F\|$ safeguard on top of it double-limits.
Any iteration in which some device limited forces at least one more Newton
iteration.

### Convergence criteria

Per-variable weighted update norm (SPICE3f5 `NIconvTest`):

$$
\max_i \frac{|\Delta x_i|}{\texttt{reltol}\cdot\max(|x_i^{k+1}|,|x_i^k|) + a_i} < 1,
\qquad
a_i = \begin{cases}\texttt{vntol} & \text{voltage rows}\\ \texttt{abstol} & \text{current rows}\end{cases}
$$

plus a row-scaled residual gate on the accepted iterate: with $A_{ii}$ the
matrix diagonal of the accepting iteration,

$$
|F_i(x^k)| \le \max\!\big(\texttt{residual\_tol},\; 10\,|A_{ii}|\,(\texttt{reltol}\,|x_i| + \texttt{vntol})\big)\quad \forall i .
$$

The tolerance floors at `residual_tol` on branch rows (near-zero diagonal),
which catches a silently-singular solve returning $\Delta x = 0$ at $x = 0$.
Iteration 1 is never accepted (ngspice `niiter.c`: `iterno != 1`); a device
state flip (switch) or a limiting event also rejects the iterate.

### Gmin regularization and dynamic gmin continuation

Gmin stepping solves the regularized family

$$
F_g(x; g) = F(x) + g\,x_{\text{diag}} = 0
\quad\Longleftrightarrow\quad
J \mathrel{+}= g I_{\text{diag}},\;\; \text{rhs} \mathrel{+}= g\,x
$$

(a conductance $g$ from every node to ground, stamped on the diagonal and,
in the residual form used here, as $g\,x_i$ on the RHS so the *regularized*
residual is what converges to zero). For large $g$ the system is
diagonally dominant and Newton converges from anywhere; the continuation
tracks the solution branch $x^\ast(g)$ as $g \downarrow g_{\text{target}}$.
Existence of the branch follows from the implicit function theorem while
$J + gI$ stays nonsingular; folds in the branch are what the adaptive factor
control walks around.

Dynamic gmin (Gillespie's algorithm, ngspice `cktop.c` `dynamic_gmin`):
descend $g_{k+1} = g_k / \phi$ with an adaptive factor $\phi$:

- start $\phi = 10$, $g_0 = g_{\text{start}}/\phi$ with $g_{\text{start}} = 10^{-2}$;
- easy rung (iterations $\le$ ITL1/4): accelerate $\phi \leftarrow \min(\phi\sqrt\phi, \phi_{\max})$;
- hard rung (iterations $> 3\cdot$ITL1/4): decelerate $\phi \leftarrow \sqrt\phi$;
- failed rung: back up toward last good $g$ with $\phi \leftarrow \phi^{1/4}$,
  restart from last converged $x$;
- give up when $\phi < 1.00005$ (wedged against the last good rung).

### Source stepping

Homotopy in the source amplitude $\lambda \in [0,1]$:

$$
F(x; \lambda) = 0, \qquad
u(\lambda) = \lambda\, u_{\text{full}},
$$

$\lambda = 0$ gives the trivially solvable dead circuit, $\lambda = 1$ the
target. Adaptive ramp: step $\Delta\lambda$ grows $\times 1.5$ on success,
halves on failure with restart from the last good $(\lambda, x)$; abort when
$\Delta\lambda < 10^{-4}$. (ngspice's dynamic variant uses raise $\in$
$[10^{-7}, 10^{-2}]$ with $\times1.5 / \times0.5 / \div10$ rules; ours is the
same shape with different constants.)

### Pseudo-transient continuation (PTC)

*(derived, not source-verified — Kelley & Keyes, SIAM J. Numer. Anal. 35(2),
1998, is paywalled)*

PTC solves $F(x)=0$ by integrating the artificial ODE $\dot x = -F(x)$ to
steady state with implicit Euler and a growing pseudo-timestep:

$$
\Big(\frac{1}{\delta_k} M + J(x^k)\Big)\,\Delta x = -F(x^k),
\qquad x^{k+1} = x^k + \Delta x,
$$

with $M$ a scaling matrix (identity, or the physical $C$ matrix for circuit
PTC — Xyce's PTRAN uses the actual charge Jacobian so the trajectory is the
physical turn-on transient). Switched evolution relaxation (SER) step
control:

$$
\delta_{k+1} = \delta_k\,\frac{\|F(x^{k-1})\|}{\|F(x^k)\|},
$$

so $\delta \to \infty$ as the residual falls and PTC degenerates into full
Newton with local quadratic convergence. Kelley–Keyes prove global
convergence to the stable steady state under: $F$ smooth, the ODE trajectory
converging to a root $x^\ast$ with $J(x^\ast)$ nonsingular, and $\delta_0$
small enough — PTC follows the physical trajectory when Newton's domain of
attraction is missed. Advantage over gmin/source stepping: it does not
require the homotopy branch to be fold-free; the ODE flow goes where the
circuit would physically go.

**Implementation status:** not implemented as a ladder rung in this repo
(ladder is plain → gmin → source → JFNK). The transient engine
(`tran.zig` with a ramped source and growing dt) is the manual PTC
workaround; a dedicated rung would reuse `TranHook` with SER dt control.

## 2. Flow explanation

Every analysis converges through one module,
`src/analysis/solvers/converger.zig`; the strategies differ only in a
comptime hook that decides what is assembled and which matrix plane is
factored. The OP flow (`src/analysis/dc/op.zig`) is a four-rung
ladder; each rung is attempted in full before falling to the next, and every
rung restarts cold (zeroed $x$ plus SPICE `MODEINITJCT` junction seeds:
iteration 1 linearizes at $v_{\text{crit}}$/vto instead of 0).

**Rung 1 — plain Newton.** Assemble → gmin-regularize (fixed target gmin) →
factor (KLU-class: BTF + AMD + Gilbert-Peierls, symbolic work done once) →
solveNeg → damp → limits/state gates → convergence test. `SingularMatrix` is
a plain failure, not an abort. A `matrix_sig` fast path skips refactoring
when the assembled matrix provably didn't change (linear circuit at fixed
$\alpha$/gmin).

**Rung 2 — dynamic gmin.** The factor-adaptation loop above, up to 100
rungs. Convergence at $g \le g_{\text{target}}$ ends the analysis with
`method_used = .gmin`.

**Rung 3 — source stepping.** Devices implement `attempt(lambda)`; the
engine recomputes the constant baseline per $\lambda$, and restores true
models afterwards regardless of outcome, followed by one final solve at the
true parameters.

**Rung 4 — JFNK guarantee rung.** The same Jacobian-free Newton–Krylov the
GPU kernel runs (so CPU convergence is a superset of GPU convergence by
construction). Its different globalization (Krylov least-squares step +
damping) catches circuits where the factored direct step wedges.

**Failure handling.** Nothing throws mid-ladder except allocation/logic
errors; numerical failures (singular factor, NaN stamps) demote to the next
rung. `ZP_OPDBG=1` traces iterations and rungs.

**Tolerance knobs** (see [tolerance-system.md](tolerance-system.md) for the
bundle view): `reltol`, `abstol`, `vntol`, `residual_tol` gate acceptance;
`gmin`, `gmin_start` set the regularization target and ladder start; `itl1`
is the per-rung Newton budget and also drives the gmin factor adaptation
(easy/hard rung thresholds at ITL1/4 and 3·ITL1/4); `dx_clamp` is the
direction-preserving damping bound (default off, $\infty$).

## 3. Pseudo-code, CPU sequential

```
solve_op(ckt, x, tol):
    cold_start(x)                          # zero + junction seeds (vcrit)
    # rung 1: plain newton
    if newton(ckt, x, gmin=tol.gmin) converged: return .plain

    # rung 2: dynamic gmin
    cold_start(x); phi = 10; g_good = 1e-2; g = g_good/phi; have_good = false
    repeat up to 100 solves:
        r = newton(ckt, x, gmin=g)         # SingularMatrix == not converged
        if r.converged:
            if g <= tol.gmin: return .gmin
            x_good = x; g_good = g; have_good = true
            if r.iters <= ITL1/4:      phi = min(phi*sqrt(phi), 10)
            elif r.iters > 3*ITL1/4:   phi = sqrt(phi)
            g = max(g/phi, tol.gmin-snap)
        else:
            if phi < 1.00005: break        # wedged
            phi = phi^(1/4); g = g_good/phi
            x = x_good if have_good else cold_start(x)

    # rung 3: source stepping
    cold_start(x); lam = 0; lam_good = -1; dlam = 0.25
    repeat up to 100 solves:
        apply_attempt(lam); recompute_baseline()
        if newton(ckt, x, gmin=tol.gmin) converged:
            if lam >= 1: break
            lam_good = lam; x_good = x; dlam *= 1.5
            lam = min(lam + dlam, 1)
        else:
            dlam *= 0.5
            if dlam < 1e-4: break
            (x, lam) = (x_good, min(lam_good + dlam, 1)) if lam_good >= 0
                       else (cold_start(x), 0)
    restore_models(); recompute_baseline()
    if newton(ckt, x, gmin=tol.gmin) converged: return .source

    # rung 4: JFNK guarantee
    cold_start(x)
    return jfnk(ckt, x, gmin=tol.gmin)     # GMRES(30), FD J·v

newton(ckt, x, gmin):
    for iter in 0..max_iter:
        assemble(x)                        # devices stamp F(x), J(x) w/ limiting
        J_diag += gmin; rhs += gmin*x
        factor(J) unless matrix_sig unchanged
        dx = solve(J, -F)
        damp_whole_step(dx, dx_clamp)      # scale, never per-component clamp
        x_old = x; x += dx
        limited = apply_device_limits(x, x_old)    # pnjlim/fetlim/limvds
        if state_flipped(x) or limited or iter == 0: continue
        if weighted_dx_norm(dx, x, x_old) >= 1: continue
        if any row: |F_i| > max(residual_tol, 10*|A_ii|*(reltol*|x_i|+vntol)): continue
        return converged
    return not_converged
```

## 4. Pseudo-code, GPU parallel

Repo flavor (`src/analysis/eval/engine.zig` +
`converger.zig` jfnk path): the *entire* Newton/JFNK solve is one
cooperative kernel launch — outer Newton loop, inner GMRES(m), device
residual evals, and the exact same acceptance gates as the CPU (gate-for-gate
mirror, so CPU and GPU accept identical iterates). Host uploads the problem
blob once and reads back `x` + one result header.

What parallelizes:
- **Device evaluation** — devices are grouped into homogeneous batches
  (SoA `BatchDesc` per model kind); each batch is a grid-stride loop, one
  thread per device instance, gather $x$ via index tables, stamp
  RHS/diagonal with atomics.
- **Limiting** — a parallel pass per limited batch mirrors `batch.zig
  applyLimits`: `lim = D.limit(cur, old)` per instance, with the companion
  correction $i(\tilde v) + J(\tilde v)(x - \tilde v)$ making $F$ piecewise
  *linear* in $x$ through limited devices — the finite-difference $J\cdot v$
  is then exact, not approximate.
- **All GMRES vector ops** — axpy, dot (block partials + atomicAdd),
  norms, preconditioner apply: grid-stride over $n$.

What stays sequential:
- The homotopy ladder itself (rungs are causally ordered; the host walks
  gmin/lambda and re-launches).
- Scalar GMRES bookkeeping — Givens rotations, Hessenberg update,
  back-substitution — runs on global thread 0 with decisions published
  through workspace scalar slots; the grid idles for $O(m^2)$ flops
  (irrelevant next to device evals). Software grid barrier between phases
  (`cuLaunchCooperativeKernel`).

```
kernel newton_jfnk(blob, x, t, opts):            # ONE cooperative launch
    for iter in 0..max_iter:                      # sequential (thread-0 steers)
        parallel assemble F(x): zero rhs; for each batch: grid-stride
            instance eval -> stamp rhs (+gmin*x)  # SoA gather/scatter, atomics
        grid_barrier
        parallel reduce |F|; thread0 publishes
        # GMRES(m): J·v by finite difference over the SAME parallel assemble
        for j in 0..m:                            # sequential Krylov sweep
            parallel: x_pert = x + eps*v_j
            parallel assemble F(x_pert); w = (F(x_pert)-F(x))/eps
            parallel precondition w (diag Jacobi on-device)
            parallel MGS dots vs v_0..v_j          # block partials + atomicAdd
            thread0: Givens, Hessenberg, residual check -> publish break
            grid_barrier
        thread0: back-substitute y; parallel dx = V·y; parallel damp
        parallel limit pass over limited batches; reduce limited-flag
        parallel update x, weighted dx norm; thread0 applies the CPU gates
        if converged: write ResultHeader; return
host:
    upload blob once
    launch newton_jfnk                            # rung 0: GPU megakernel
    if !converged: run CPU jfnk warm-started from GPU iterate
    if !converged: run CPU direct newton          # strongest factorable rung
```

Multiple-RHS parallelism (the other GPU axis) does not apply to a single OP
solve but does to ensembles: Monte-Carlo / corner sweeps batch independent
OP problems as independent blob instances (`benchmark/fixtures/ensemble/*`).

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Direct Newton factor/refactor (BTF + AMD + Gilbert-Peierls, frozen pattern) | [klu-pipeline.md](../solvers/klu-pipeline.md), [gilbert-peierls-lu.md](../solvers/gilbert-peierls-lu.md), [btf-permutation.md](../solvers/btf-permutation.md), [amd-ordering.md](../solvers/amd-ordering.md) | `src/analysis/solvers/direct.zig` |
| Convergence gates, device limiting, JFNK/GMRES(m) + preconditioning | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/analysis/solvers/converger.zig` |
| gmin/source ladder (Gillespie controllers, exact ngspice rules) | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `src/analysis/dc/op.zig solveLadder` |
| Factor-once bypass on linear circuits | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) (`matrix_sig` / memcmp) | `converger.Options.matrix_sig` |
| GPU whole-solve megakernel; level-set refactor alternative | [gpu-sparse-lu.md](../solvers/gpu-sparse-lu.md) | `src/analysis/eval/engine.zig` |
| BBD/diagonal right preconditioner for JFNK | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `direct.Solver` factors, `src/analysis/solvers/bbd.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice `cktop.c` (raw.githubusercontent.com/ngspice/ngspice/master) | fetched, verified — dynamic gmin factor rules, source stepping constants |
| Xyce Math Formulation PDF (xyce.sandia.gov) | fetched, verified — MNA/DAE, §4.2 voltage limiting semantics; this doc revision has no gmin/PTC section |
| Kelley & Keyes, PTC convergence theory | **paywalled — derived, not source-verified** (SER rule + convergence conditions from knowledge) |

**Per-section verification**

- §1 MNA/Newton/limiting: verified vs Xyce math doc + our `converger.zig` (ngspice-exact limiting per source comments).
- §1 dynamic gmin / source stepping: verified vs fetched `cktop.c` summary; our constants match ngspice's dynamic variants (ours: source $\Delta\lambda_0 = 0.25$, ngspice: raise$_0 = 0.001$ — flavor difference, noted).
- §1 PTC: derived, not source-verified; not implemented here.
- §3/§4: direct transcription of repo source.

**Our implementation**

- `src/analysis/dc/op.zig` — ladder (`solveLadder`), cold start, junction seeding.
- `src/analysis/solvers/converger.zig` — Newton, JFNK, gates, damping, `Tolerances`.
- `src/analysis/eval/engine.zig` — GPU megakernel (assemble/limit/JFNK on device).
- Bench fixtures: `benchmark/fixtures/op/voltage_divider`,
  `benchmark/fixtures/convergence/{diode_bridge,high_gain_fb,schmitt}`,
  plus every fixture's implicit OP phase.
