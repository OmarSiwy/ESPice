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
incompatible with line-search/backtracking globalization: limiting depends on
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

Rows with a zero diagonal (voltage-defined branches) skip the residual gate,
since an exact solution still leaves O(gain * eps) residual there; the delta
test alone governs them. See [tolerance-system.md](tolerance-system.md) for
how this gate diverges from ngspice's `NIconvTest`.
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
- every rung's Newton runs with the ITL2 budget (ngspice `CKTdcTrcvMaxIter`,
  `cktop.c:194`);
- easy rung (iterations $\le$ ITL2/4): accelerate $\phi \leftarrow \min(\phi\sqrt\phi, 10)$;
- hard rung (iterations $> 3\cdot$ITL2/4): decelerate $\phi \leftarrow \max(\sqrt\phi, 1.00005)$;
- when the next step would pass the target, set $\phi = g/g_{\text{target}}$
  and $g = g_{\text{target}}$ (`cktop.c:207-222`);
- failed rung: back up toward last good $g$ with $\phi \leftarrow \phi^{1/4}$,
  restart from last converged $x$;
- give up when $\phi < 1.00005$ (wedged against the last good rung);
- after converging at $g_{\text{target}}$, one more Newton with no diagonal
  gmin gives the answer, as ngspice's `dynamic_gmin` removes `diagGmin` for
  the last solve.

Where $g$ lands matters for the path. ngspice's `LoadGmin` (spsmp.c) adds it
to the diagonal Sparse holds after `spMNA_Preorder` (sputils.c), which swaps
each column with no diagonal element (a voltage-source branch) for a
symmetric pair of $\pm 1$ entries. A grounded source $V = E$ therefore
solves $(1 + g)V = E$ during the stepping, and its node's own diagonal gets
no $g$. `op.zig` `gminStamps` replays the preorder on the assembled values
and hands the placement to the converger. Loading $g$ on every diagonal
instead (branch rows included) moved the rung-1e-3 solution of
`stress/scaling_inverter_chain_256` from ngspice's 0.1385278 V to 0.1389463 V;
from there the 1e-4 rung "converged" on a 4.7e12 A supply current, where
ngspice's rung fails and backs off. The multi-twin tie (a floating source)
takes the lower row index, which follows ngspice's node numbering only when
the two agree.

### Source stepping

Homotopy in the source amplitude $\lambda \in [0,1]$:

$$
F(x; \lambda) = 0, \qquad
u(\lambda) = \lambda\, u_{\text{full}},
$$

$\lambda = 0$ gives the trivially solvable dead circuit, $\lambda = 1$ the
target. Adaptive ramp: step $\Delta\lambda$ grows $\times 1.5$ on success,
halves on failure with restart from the last good $(\lambda, x)$; abort when
$\Delta\lambda < 10^{-4}$, after 100 solves, or at once when the
$\lambda = 0$ solve itself fails (a retry would repeat the same cold solve).
Newton runs with the ITL2 budget. (ngspice's dynamic variant uses raise $\in$
$[10^{-7}, 10^{-2}]$ with $\times1.5 / \times0.5 / \div10$ rules; ours is the
same shape with different constants.)

### Pseudo-transient continuation (PTC)

*(derived, not source-verified: Kelley & Keyes, SIAM J. Numer. Anal. 35(2),
1998, is paywalled)*

PTC solves $F(x)=0$ by integrating the artificial ODE $\dot x = -F(x)$ to
steady state with implicit Euler and a growing pseudo-timestep:

$$
\Big(\frac{1}{\delta_k} M + J(x^k)\Big)\,\Delta x = -F(x^k),
\qquad x^{k+1} = x^k + \Delta x,
$$

with $M$ a scaling matrix (identity, or the physical $C$ matrix for circuit
PTC: Xyce's PTRAN uses the actual charge Jacobian so the trajectory is the
physical turn-on transient). Switched evolution relaxation (SER) step
control:

$$
\delta_{k+1} = \delta_k\,\frac{\|F(x^{k-1})\|}{\|F(x^k)\|},
$$

so $\delta \to \infty$ as the residual falls and PTC degenerates into full
Newton with local quadratic convergence. Kelley-Keyes prove global
convergence to the stable steady state under: $F$ smooth, the ODE trajectory
converging to a root $x^\ast$ with $J(x^\ast)$ nonsingular, and $\delta_0$
small enough: PTC follows the physical trajectory when Newton's domain of
attraction is missed. Advantage over gmin/source stepping: it does not
require the homotopy branch to be fold-free; the ODE flow goes where the
circuit would physically go.

**Implementation status:** SER-controlled PTC is not implemented. The
closest rung is OPtran (rung 5 below): a real transient with full sources,
which lets the device capacitances do the conditioning. A dedicated PTC rung
would reuse `TranHook` with SER dt control.

### Model-visible gmin and source scale

The gmin and source rungs also write the Verilog-A `$simparam("gmin")` and
`$simparam("sourceScaleFactor")` values (VerA's host-written `gmin__` and
`source_scale__` model fields, through `Hooks.set_homotopy`). During a gmin
rung a model reads the stepped gmin; during a source rung it reads the ramp
`lambda`. Both go back to the deck's `.options gmin` and 1 when the rung ends,
error paths included, so the final clean solve sees the deck values.

This diverges from ngspice. ngspice's gmin stepping (`cktop.c`) ramps
`CKTdiagGmin`, a diagonal shunt, and leaves `CKTgmin`, the value its devices
read, at the deck setting throughout. Converged operating points are the same,
because the last solve uses the deck gmin in both; only the stepping path
differs, for the roughly eleven built-in models that read `$simparam("gmin")`
(bsim3, bsim4va, psp103, hisimhv, the b3soi models, the tline models). The
fallback, if a deck's stepping path needs ngspice's behaviour, is to drop the
`gmin__` write in `op.zig`'s gmin rung and keep only the restore.
Pinned by `tests/fixtures/hdl/veriloga_simparam_homotopy.sp` and the
`set_homotopy` test in `src/device/tests/eval.zig`.

A parameter whose default is `$simparam("gmin")` keeps its build-time value
during stepping, because `derive` does not rerun.

## 2. Flow explanation

Every analysis converges through `src/solver/converger.zig`; the strategies
differ only in a comptime hook that decides what is assembled and which
matrix plane is factored. The OP flow (`src/analysis/dc/op.zig
solveLadder`) is a five-rung ladder over one `Workspace`, so the ordering
and symbolic factorization happen once. Each rung is attempted in full before
the next; the stepping rungs restart cold (zeroed $x$ plus SPICE
`MODEINITJCT` junction seeds, so iteration 1 linearizes at
$v_{\text{crit}}$/vto instead of 0).

**Floating nodes.** When a node has no DC path to ground
(`Circuit.needs_tran_op`, a capacitor-only island), the static operating
point is not unique. Under a transient's own OP the ladder goes straight to
OPtran and reports the settled state, as ngspice does under TRANOP. A
standalone `.op`, `.ac` or `.pz` fails with `error.FloatingNode`.

**Rung 1: plain Newton** with no diagonal gmin and the ITL1 budget.
ngspice's `NIiter` loads a diagonal gmin only during gmin stepping (junction
gmin lives in the device models); an always-on shunt moved `voltage_divider`
by 2.5e-9 and settled a floating bridge on a common mode ngspice never picks.
Assemble, factor (BTF + AMD + Gilbert-Peierls, symbolic work done once),
`solveNeg`, damp, limiting and state gates, convergence test.
`SingularMatrix` is a plain failure, not an abort. A `matrix_sig` fast path
skips refactoring when the assembled matrix provably did not change.

**Rung 2: dynamic gmin.** The factor-adaptation loop of §1, up to 100
solves at ITL2 each, then a clean ITL1 solve with no shunt.

**Rung 3: source stepping.** Devices implement `attempt(lambda)`; the
engine recomputes the constant baseline per $\lambda$, restores the true
models afterwards whatever the outcome, and finishes with one ITL1 solve at
the true parameters. The `.ic` holds of a transient operating point scale
with the sources, held at $\lambda \cdot v_{ic}$, as `cktload.c` multiplies
each `.ic` by `CKTsrcFact`.

**Nodesets.** Before the ladder, `x` takes the `.nodeset` (and held `.ic`)
values, as ngspice's `CKTic` seeds `rhsOld`, and one Newton runs with those
rows tied to their values by $10^{10}$ S (MODEINITJCT/INITFIX). Seeding
matters: a latch whose $x = 0$ is an exact metastable solution linearizes
there and never leaves it, whatever the hold. `op.nodesetLadder` serves the
operating point and every cold DC-sweep point
(`dc/nodeset_sweep_latch`).

**Rung 4: JFNK.** `converger.jfnk` from a cold start: restarted GMRES(30)
with finite-difference Jacobian products, right-preconditioned by the
factored Jacobian (Jacobi under `ESPICE_SOLVER=jfnk-nolu`). Its Krylov
least-squares step catches some circuits where the factored direct step
wedges.

**Rung 5: OPtran** (ngspice `optran.c`). A real transient with full sources,
$dt$ 10 ns up to 1 µs, no ramp and no extra regularization, so the device
capacitances do the conditioning the static rungs could not. The settled
state only seeds a clean Newton, and that Newton's verdict is the answer.
ngspice 44.2 runs this rung only when `optran` is given (`cktop.c:94-97`);
here it is always the last rung.

**Failure handling.** Numerical failures (singular factor, NaN stamps)
demote to the next rung; only allocation errors and cancellation abort.
`ZP_OPDBG=1` traces iterations and rungs.

**Tolerance knobs** (see [tolerance-system.md](tolerance-system.md)):
`reltol`, `abstol`, `vntol`, `residual_tol` gate acceptance; `gmin` and
`gmin_start` set the gmin-stepping target and start; `itl1` is the budget of
the plain and final clean solves, `itl2` of the stepping rungs and of the
gmin factor thresholds. Newton takes the full step: device limiting is the
globalization.

### Conformance history: the 4k inverter chain

`stress/scaling_inverter_chain_4k` exposed three ladder defects (issues.md
F5, recipes in [conformance-phase2.md](../conformance-phase2.md) group 6).
ngspice solves this OP with dynamic gmin (768 iterations). The stepping rungs
ran Newton with the ITL1 cap (100) and thresholds, so at a fold where ngspice
slowed down, espice kept its factor, accepted a 79-iteration wandering solve
with $|F| = 0.44$ A, and built every later gmin step on it. Source stepping
then retried the same failing $\lambda = 0$ cold solve 12 times, and OPtran
reported the settled transient as success.

Fixed in `557d833` (ITL2 caps and the `cktop.c` factor rules, early break on
a failed $\lambda = 0$) and `ee748c7` (OPtran returns the confirming
Newton's verdict). The 4k chain now follows ngspice's gmin sequence and
finishes on the gmin rung with the right OP, in 15 s instead of 308 s. Its
transient passes since the mos1 gmbs and LTE-coefficient fixes
([transient-integration.md](transient-integration.md) §1,
[models.md](../devices/models.md)).

## 3. Pseudo-code, CPU sequential

```
solve_op(ckt, x, tol):
    if ckt.needs_tran_op:
        if !tran_op: error FloatingNode
        return optran(ckt, x)
    cold_start(x)                          # zero + junction seeds (vcrit)
    # rung 1: plain newton, no diagonal gmin
    if newton(ckt, x, gmin=0, ITL1) converged: return

    # rung 2: dynamic gmin
    cold_start(x); phi = 10; g_good = gmin_start; g = g_good/phi; have_good = false
    repeat up to 100 solves:
        r = newton(ckt, x, gmin=g, ITL2)   # SingularMatrix == not converged
        if r.converged:
            if g <= tol.gmin:
                if newton(ckt, x, gmin=0, ITL1) converged: return
                break
            x_good = x; g_good = g; have_good = true
            if r.iters <= ITL2/4:      phi = min(phi*sqrt(phi), 10)
            elif r.iters > 3*ITL2/4:   phi = max(sqrt(phi), 1.00005)
            if g < phi*tol.gmin: phi = g/tol.gmin; g = tol.gmin
            else: g /= phi
        else:
            if phi < 1.00005: break        # wedged
            phi = phi^(1/4); g = g_good/phi
            x = x_good if have_good else cold_start(x)

    # rung 3: source stepping
    cold_start(x); lam = 0; lam_good = -1; dlam = 0.25
    repeat up to 100 solves:
        apply_attempt(lam); recompute_baseline()
        if newton(ckt, x, gmin=0, ITL2) converged:
            if lam >= 1: break
            lam_good = lam; x_good = x; dlam *= 1.5
            lam = min(lam + dlam, 1)
        else:
            dlam *= 0.5
            if dlam < 1e-4 or lam_good < 0: break
            x = x_good; lam = min(lam_good + dlam, 1)
    restore_models(); recompute_baseline()
    if newton(ckt, x, gmin=0, ITL1) converged: return

    # rung 4: JFNK
    cold_start(x)
    if jfnk(ckt, x) converged: return      # GMRES(30), FD J*v, LU preconditioner

    # rung 5: OPtran
    return optran(ckt, x)                  # settle, then a clean Newton decides

newton(ckt, x, gmin, max_iter):
    for iter in 0..max_iter:
        assemble(x)                        # devices stamp F(x), J(x) w/ limiting
        J_diag += gmin; rhs += gmin*x
        factor(J) unless matrix_sig unchanged
        dx = solve(J, -F)
        x_old = x; x += dx
        limited = apply_device_limits(x, x_old)    # pnjlim/fetlim/limvds
        if state_flipped(x) or limited or iter == 0: continue
        if weighted_dx_norm(dx, x, x_old) >= 1: continue
        if any row: |F_i| > max(residual_tol, 10*|A_ii|*(reltol*|x_i|+vntol)): continue
        return converged
    return not_converged
```

## 4. Parallel execution

The ladder is sequential: rungs are causally ordered, and each rung's
Newton iterates depend on the previous one. Inside an iterate, device
evaluation runs in parallel: `ParEval` worker threads on the CPU, or the GPU
through `Circuit.gpu_hook.eval_planes` (`src/analysis/gpu.zig`), which ships
`x` up and the value planes down. The factorization, solve, limiting
decisions, gates and the ladder itself run on the host.

Not implemented (design note): a whole-solve GPU kernel would run the outer
Newton loop, inner GMRES(m), device residual evaluation and the same
acceptance gates in one cooperative launch, with thread-0 scalar GMRES
bookkeeping between grid barriers. The limiting companion correction makes
$F$ piecewise linear through limited devices, so the finite-difference
$J\cdot v$ is exact there. An earlier cooperative-kernel prototype of this was
deleted; the GPU evaluates device planes only.

Independent OP problems (Monte Carlo, corners) form a separate parallel axis;
see [ensemble-sweeps.md](ensemble-sweeps.md).

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Direct Newton factor/refactor (BTF + AMD + Gilbert-Peierls, frozen pattern) | [klu-pipeline.md](../solvers/klu-pipeline.md), [gilbert-peierls-lu.md](../solvers/gilbert-peierls-lu.md), [btf-permutation.md](../solvers/btf-permutation.md), [amd-ordering.md](../solvers/amd-ordering.md) | `src/solver/direct.zig` |
| Convergence gates, device limiting, JFNK/GMRES(m) + preconditioning | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/solver/converger.zig` |
| gmin/source ladder (Gillespie controllers, exact ngspice rules) | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `src/analysis/dc/op.zig solveLadder` |
| Factor-once bypass on linear circuits | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) (`matrix_sig` / memcmp) | `converger.Options.matrix_sig` |
| LU (or Jacobi, under `ESPICE_SOLVER=jfnk-nolu`) right preconditioner for JFNK | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `direct.Solver` factors, `converger.jfnk` |
| GPU level-set refactor (not implemented) | [gpu-sparse-lu.md](../solvers/gpu-sparse-lu.md) | none |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice `cktop.c` (raw.githubusercontent.com/ngspice/ngspice/master) | fetched, verified: dynamic gmin factor rules, source stepping constants |
| Xyce Math Formulation PDF (xyce.sandia.gov) | fetched, verified: MNA/DAE, §4.2 voltage limiting semantics; this doc revision has no gmin/PTC section |
| Kelley & Keyes, PTC convergence theory | paywalled; derived, not source-verified (SER rule and convergence conditions) |

**Per-section verification**

- §1 MNA/Newton/limiting: verified vs Xyce math doc + our `converger.zig` (ngspice-exact limiting per source comments).
- §1 dynamic gmin / source stepping: verified against `cktop.c`; the gmin constants match ngspice's dynamic variant. Source stepping differs in its start step (ours $\Delta\lambda_0 = 0.25$, ngspice raise$_0 = 0.001$).
- §1 PTC: derived, not source-verified; not implemented.
- §2/§3: transcribed from `op.zig` and `converger.zig`.

**Our implementation**

- `src/analysis/dc/op.zig`: ladder (`solveLadder`), `transientOp`, cold
  start, junction seeding.
- `src/solver/converger.zig`: `newton`, `jfnk`, `run`, the acceptance gates,
  damping. `Tolerances` is defined in `src/core/numerics.zig`.
- Fixtures: `tests/fixtures/op/`, `tests/fixtures/convergence/`, plus every
  deck's implicit OP phase.
