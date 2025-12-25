# ZPicey — Mathematical Foundation and Analysis Pipeline

This document is a self-contained mathematical walkthrough of the ZPicey SPICE simulator:
the compiled-circuit core, the AD-based assembly, the Newton and linear-solver layers, and
one section per analysis (all 22), each ending with an explicit **"Requires from
CompiledCircuit"** list. File references are relative to
`/home/omare/Documents/Projects/ZpiceyRE/modules/analysis/src/` unless absolute.

---

## 1. MNA formulation and the compiled-circuit idea

**File:** `compiled.zig` (1691 lines).

The circuit is a nonlinear DAE in charge-oriented Modified Nodal Analysis form:

$$
f(x,t) \;=\; \frac{d}{dt}\,q(x) \;+\; i(x,t) \;=\; 0, \qquad x \in \mathbb{R}^n
$$

where $x$ stacks node voltages **and** branch currents (branch/internal unknowns are
appended per device at `addDevice`, compiled.zig:482–498). One `eval(x,t)` pass
(compiled.zig:1345–1355) fills **four value planes** over a single **frozen CSC sparsity
pattern** (`col_ptr`/`row_idx`, built at compile time, compiled.zig:576–623):

| Plane    | Meaning                                  | Line |
| -------- | ---------------------------------------- | ---- |
| `rhs`    | resistive residual $i(x,t)$              | 1304 |
| `q_vec`  | charge/flux vector $q(x)$                | 1305 |
| `g_vals` | $G = \partial i/\partial x$ (CSC values) | 1302 |
| `c_vals` | $C = \partial q/\partial x$ (CSC values) | 1303 |

Every analysis is an **affine consumer** of $(G,C)$ (compiled.zig:8–9):

$$
\text{DC: } A = G, \qquad
\text{TRAN: } A = G + \alpha C, \qquad
\text{AC: } A(\omega) = G + j\omega C .
$$

The pattern is the union of the $G$ and $C$ patterns plus the full diagonal
(compiled.zig:582; `diag_slots` at 607–608 gives O(1) gmin stamping). Chargeless circuits
still expose an exact $C=0$ plane (603–605), so AC/PZ/STB read valid zeros.

**Value-form device contract** (compiled.zig:312–333). Device physics is written once,
generic over an opaque scalar `S`; a device returns residual/charge _values_ per local
unknown, not stamps. With gather map $P_D$ (`gath`, compiled.zig:990):

$$
i(x,t) = \sum_D P_D^{\mathsf T}\, i_D(P_D x, t), \qquad
q(x) = \sum_D P_D^{\mathsf T}\, q_D(P_D x).
$$

Dispatch is one vtable call per device **type** per eval (`Batch`, compiled.zig:629–647),
with the per-instance loop monomorphized inside `DeviceBatch(D)`. Optional hooks: `limit`
(NR damping, :323), `State/updateState` (:324–325), `noise_gens` (:326), history devices
(:329–332).

**Ground pinning (branch-free ground).** Ground $x_0$ is a _real unknown_
(compiled.zig:11–13). Two mechanisms:

1. **Trash slots** — any stamp touching row/column 0 is routed to slot `nnz` and rhs
   index `n` (compiled.zig:597–601, 688–696, 843–848); planes are allocated `nnz+1`/`n+1`
   so writes are unconditional (no branches in the hot loop).
2. **Pinning equation** — after all batches stamp, `eval` appends
   `g_vals[diag_slots[0]] += 1.0; rhs[0] += x[0]` (compiled.zig:1353–1354):

$$
G = \begin{pmatrix} 1 & 0 \\ 0 & G_{\text{red}} \end{pmatrix},\qquad f_0(x) = x_0
\;\Rightarrow\; \text{Newton drives } x_0 \to 0 .
$$

The matrix stays $n\times n$ and nonsingular; classic reduced MNA is recovered implicitly.
The gather map keeps ground reads at index 0 with the invariant $x[0]=0$ (compiled.zig:989).

**Auxiliary hooks** (used by individual analyses below):
`collectNoiseSources` (compiled.zig:1549–1557) — thermal generators $4kT\,g$ read directly
off the analytic Jacobian; `collectParams` (:1179–1222) — every finite-default `f32`
Model/Instance field becomes a stable `ParamRef` raw pointer for sens/MC/temp;
`HistoryBuffer` ring with binary-search linear interpolation
$v(t_q)=v_0+\tfrac{t_q-t_0}{t_1-t_0}(v_1-v_0)$ (:128–192), `injectHistory` (:1516–1520),
`minDelay` (:1522–1528); `updateStates` (:1497–1507) — per-device state machines returning
a minimum reject-at time; `PrepCache` dedup (:711–736).

---

## 2. Forward-mode AD: residual + analytic Jacobian in one pass

`AdScalar(N)` (compiled.zig:207–300) is a dual number with an $N$-wide SIMD derivative
vector:

$$
\tilde a = \langle a_v,\ \vec a_d\rangle, \qquad \vec a_d \in \mathbb{R}^N\ (\texttt{@Vector(N, f64)})
$$

representing $a_v = a(x_D)$ and $\vec a_d = \nabla_{x_D} a$. Arithmetic implements the
chain rule exactly:

$$
\begin{aligned}
\tilde a \cdot \tilde b &= \langle a_v b_v,\ a_v \vec b_d + b_v \vec a_d\rangle &&\text{(:230)}\\
\tilde a / \tilde b &= \Big\langle \tfrac{a_v}{b_v},\ \tfrac{\vec a_d - (a_v/b_v)\vec b_d}{b_v}\Big\rangle &&\text{(:233, one reciprocal)}\\
e^{\tilde a} &= \langle e^{a_v},\ e^{a_v}\vec a_d\rangle &&\text{(:244)}\\
\tilde a^{\,c} &= \langle a_v^c,\ c\,a_v^{c-1}\vec a_d\rangle &&\text{(:276)}
\end{aligned}
$$

plus `log/sqrt/sin/cos/tanh/atan/sinh/cosh` (:248–288). Piecewise ops take the winner's
derivative (`max/min`, :290–295); clamp guards `minC/maxC` flatten the derivative past the
bound (:269–274) — subgradient-style, keeping Newton stable at limiter corners.

**Seeding** (`evalInner`, compiled.zig:1020–1026): for a device with $n_u$ local unknowns,
AD width $N = n_u$ and each input is seeded with a unit direction,
$\tilde x_u = \langle x[\text{gath}(u)],\ e_u\rangle$. Since forward duals propagate
$\vec y_d = J_y\,\vec x_d$ and the seeds are $I_{n_u}$, output row $r$ carries the full
local gradient:

$$
\text{out}[r] = \big\langle\, i_{D,r}(x_D,t),\ \nabla_{x_D}\, i_{D,r} \,\big\rangle
\;\Rightarrow\;
\text{out}[r].d[c] = \frac{\partial i_{D,r}}{\partial x_{D,c}} = G_D[r,c].
$$

**One physics execution yields the residual and the entire dense $n_u\times n_u$ elemental
Jacobian — no finite differences anywhere** (compiled.zig:15–17). Scatter
(:1035–1039): `rhs[rhs_idx[r]] += out[r].v` assembles $i(x,t)$;
`g_vals[slots[r][c]] += out[r].d[c]` assembles $G$; identically for `q`/`c_vals`
(:1050–1070), giving $C = \partial q/\partial x$. The `slots` tape (:993) is precomputed at
`finalize` (:685–697) via binary-search `findSlot` (:1480–1489) — runtime assembly is pure
indexed adds. The same math crosses the dlopen ABI: `.so` devices ship `eval_ad` returning
residual + analytic row-major Jacobian, instantiated with a dual scalar at _their_ compile
time (compiled.zig:55–58, 83, 907–931).

Noise reuses this machinery: `collectNoise` (:1232–1259) re-runs the AD eval at $x_{op}$
and reads thermal conductance straight off the Jacobian, $S_i = 4kT\,|G[r,c]|$ — no
perturbation (:36–38).

---

## 3. Newton–Raphson: iteration, limiting, convergence, baseline

**File:** `newton.zig` (shared, hook-parametrized loop), plus `op.zig`/`dc.zig` wrappers.

The hook chooses the factored matrix (newton.zig:30–37): DC hooks use $J=G$; transient
hooks assemble $G + \alpha C$ via `combineGC`. Per iteration (newton.zig:41–72):

1. **Assemble** $F(x^{(k)})$, $J(x^{(k)})$ via `hook.assemble` → `evalNewton` (:53).
2. **Gmin regularization** (:55–59): for every diagonal $i$ (all $n$, including branch
   rows and the ground row),
   $$J_{ii} \mathrel{+}= g_{\min}, \qquad F_i \mathrel{+}= g_{\min} x_i^{(k)},$$
   i.e. the iteration is _exact_ Newton on the loaded residual
   $F_\gamma(x) = F(x) + g_{\min}x$ — a true shunt $g_{\min}$ from every unknown to ground
   (fixed point satisfies $F(x^\ast)+g_{\min}x^\ast=0$, not $F(x^\ast)=0$; default
   $g_{\min}=10^{-12}$, :19).
3. **Solve** — the direct solver computes the negated step directly:
   $\Delta x = -J^{-1}F(x^{(k)})$ (`solveNeg`, direct.zig:87).
4. **Step clamp** (:63): $\Delta x_i \leftarrow \operatorname{clamp}(\Delta x_i, -10, +10)$
   (`dx_clamp` default 10; transient paths override it to $\infty$).
5. **Update + norm** (:64–65, 74–81): $x^{(k+1)} = x^{(k)} + \Delta x$,
   $\|\Delta x\|_\infty = \max_i|\Delta x_i|$.
6. **Device limiting** (:66): $x^{(k+1)} \leftarrow \mathcal L(x^{(k+1)}, x_{\text{old}})$ —
   classic SPICE limiters (`pnjlim` with
   $V_{\text{crit}} = nV_T\ln(nV_T/(\sqrt2\,I_{\text{sat}}))$, `fetlim`, `limvds`) in
   `modules/devices/src/`.
7. **State machines** (:67): `updateStates(x)` — any digital/VF flip forces `continue`,
   so convergence can never be declared on a flip iteration.

**Convergence** (:68–69): pure absolute step-size test on the **pre-limiting** clamped
norm, $\|\Delta x\|_\infty < \text{abstol}$ (default $10^{-12}$). No relative tolerance and
no residual/KCL check: `op.Options.reltol = 1e-3` (op.zig:15) is declared but never
forwarded — dead. Failure returns `converged=false` after `max_iter=100` (:15, :71).

**Constant-Jacobian baseline** (compiled.zig:1384–1418, 1360–1380). Linear devices declare
`constant_g/constant_c` (:671–672, 980–981); `computeBaseline` evaluates constant batches
once at $x=0$ (valid — their derivative planes are $x$-independent) into frozen
`g_base/c_base`, ground pin included:

$$
G_{\text{base}} = \sum_{D\in\text{const}} P_D^{\mathsf T} G_D P_D + e_0 e_0^{\mathsf T},
\qquad
C_{\text{base}} = \sum_{D\in\text{const}} P_D^{\mathsf T} C_D P_D .
$$

`evalNewton` then restores by `@memcpy` from the baseline instead of zeroing, and constant
batches skip the Jacobian scatter entirely, stamping only scalar `rhs`/`q_vec` values
(compiled.zig:1008–1018, 1040–1048, 1061–1069):

$$
G(x) = G_{\text{base}} + \sum_{D\notin\text{const}} P_D^{\mathsf T}\,
\frac{\partial i_D}{\partial x_D}(x)\, P_D ,
$$

so per-iteration Jacobian cost scales with the _nonlinear_ device count while the residual
is always fully re-evaluated.

**Gmin-stepping continuation** (op.zig:28–62; source stepping not implemented, op.zig:8–9):
if plain Newton at $\gamma = 10^{-12}$ fails, reset $x=0$ and solve the homotopy family
$F_\gamma(x)=0$ with

$$
\gamma_0 = 10^{-2}, \qquad \gamma_{j+1} = \max(\gamma_j/2,\ g_{\min}),
$$

warm-starting each stage from the previous root; no retreat/bisection — a failed stage
ends with `converged=false`. One `newton.Workspace` (solver + scratch) serves the whole
continuation since the pattern is frozen (op.zig:37).

**combineGC — the transient companion stamp as one axpy** (compiled.zig:1422–1457).
Discretizing $\dot q + i = 0$ with a one-leg integrator whose current-step derivative is
$\dot q_{k+1} \approx \alpha q_{k+1} + \text{history}$ (BE: $\alpha=1/h$; TRAP:
$\alpha=2/h$), the Newton system is

$$
\underbrace{(G+\alpha C)}_{A}\,\Delta x = -\big(i(x) + \alpha q(x) + \text{history}\big),
$$

and because $G,C$ share one frozen pattern, $A_k = g_k + \alpha c_k$ is a single 8-wide
SIMD sweep over the nnz (trash slot excluded); `combineGCAndClear` fuses zeroing of the
planes for the next eval into the same cache-warm pass (:1426–1427). AC is the same
consumption with $\alpha = j\omega$ done complex on the analysis side; dense analyses
expand via `denseG`/`denseC` (:1461–1478).

---

## 4. Linear solvers

`solver/lib.zig:1–4` re-exports exactly four modules: `dense_lu`, `freq_solve`, `direct`,
`fft` (`order.zig` is internal to `direct`).

### 4.1 Sparse direct LU — `solver/direct.zig` (722 lines)

Consumes the frozen CSC pattern plus a caller-built `vals` slice on that pattern (any
affine plane combination). No assembly happens here (direct.zig:1–3).

- **Facade `Solver`** (:34–116). `init` dispatches on pattern shape: tridiagonal
  (bandwidth $\le 1$, $n\ge3$, :403–413) → Thomas solver; else general LU. Ordering runs
  once here. `factor` (:70–85) is **refactor-first**: full symbolic+numeric factorization
  only on the _first_ call (`self.factored=false`); afterwards a zero-allocation
  numeric-only `refactor` replays the stored L/U pattern and pivot sequence, falling back
  to a full `factor(pivot_tol=1e-3)` on pivot collapse. `solveNeg` (:87) computes the
  Newton step $x = -A^{-1}r$ with an 8-wide SIMD negate; `solve`/`solveT` (:97, :107) are
  the forward/adjoint paths.
- **`Lu` — left-looking Gilbert–Peierls** (:130–399). Per pivot column $c=q[k]$:
  iterative-DFS _reach_ through completed L columns (topological order of the sparse
  triangular solve, :226–257); scatter + sparse triangular solve $L u = A_{:,c}$ in
  reverse finish order (:260–275); **KLU-style threshold pivoting preferring the
  diagonal** — keep the diagonal if $|w_c| \ge \tau\,a_{\max}$, $\tau = 10^{-3}$
  (:277–293); store $L_{:,k}=w/d$. `refactor` (:315–344) is the Newton hot path.
  `solve` (:347–367): $A = P^{-1}LUQ^{-1}$. `solveT` (:376–398):
  $$A^{-\mathsf T} = P^{-1} L^{-\mathsf T} U^{-\mathsf T} Q^{\mathsf T}$$
  — gather-mode substitutions on $U^{\mathsf T}$/$L^{\mathsf T}$, used by adjoint analyses
  (noise/tf).
- **`TriDiag` Thomas solver** (:419–509): $O(n)$ for RC ladders; $m_i = a_i/b'_{i-1}$,
  $b'_i = b_i - m_i c_{i-1}$; no partial pivoting (relies on diagonally-dominant MNA +
  gmin, :401–402).

### 4.2 Ordering — `solver/order.zig` (705 lines): stage-1 BTF + per-block AMD

Pattern-only, called once at `Lu.init` (direct.zig:188). Runs on a caller-owned bump
workspace (`wsSize = 48n + 8\,\mathrm{nnz} + 64`, order.zig:59–61) — no allocator, so
identical code runs at comptime, runtime, and under the emitter.

- **BTF** (:64–184): iterative Tarjan SCC on $j\to i \iff A_{ij}\neq0$; the structurally
  full diagonal (guaranteed by the pattern merge + ground pin) makes the identity
  transversal valid — no maximum matching needed (:5–8). SCCs emit in reverse topological
  order; each block is ordered by AMD.
- **AMD** (:211–508): Amestoy–Davis–Duff approximate minimum degree over a contiguous
  packed adjacency. Dense-row deferral for degree $\ge \max(16, 10\sqrt n)$ (:295–328);
  degree buckets for O(1) pivot pick; element formation
  $L_p = (A_p \cup \bigcup_{e\in E_p} L_e)\setminus\{p\}$; aggressive absorption when
  external degree $w[e]=|L_e\setminus L_p| = 0$; approximate degree
  $$d_i = \min\!\big(|A_i| + (|L_p| - \mathrm{nv}_i) + \textstyle\sum_e w[e],\ n-k-\mathrm{nv}_p\big)$$
  (:451–452); supervariable merging via adjacency hashing + exact check. Deterministic;
  comptime ≡ runtime byte-compared (tests :663–692).

### 4.3 Dense LU — `solver/dense_lu.zig` (233 lines)

Row-major dense, SIMD $W=4$. `factorizeSolveImpl` (:20–53) is a fused factor+solve
carrying the RHS through elimination (no pivot storage; partial pivoting with full-row
swaps; singular threshold $10^{-30}$); `factorizeSolveNeg` (:15) negates the RHS up front
for Newton. `factorize`/`solveFactored` (:55–96) is the stored-pivot multi-RHS variant
(all pivot swaps must be applied to the RHS _before_ forward elimination, :83–87).
`buildComplexAdmittance` (:142–183) SIMD-fills the stacked-real expansion

$$
\begin{bmatrix} G & -\omega C \\ \omega C & G \end{bmatrix} \in \mathbb{R}^{2n\times 2n}.
$$

### 4.4 Complex frequency-domain solve — `solver/freq_solve.zig` (315 lines)

Solves $(G + j\omega C)x = b$ in stacked-real form. `fromCircuit` (:49) calls
`ckt.eval(x_op, 0)` **once** — the `g_vals`/`c_vals` planes _are_ the small-signal
linearization. Two strategies split at `DENSE_THRESHOLD = 128` (:13):

- **Dense** ($n\le128$): densify via `denseG/denseC`, then per-$\omega$
  `buildComplexAdmittance` + `dense_lu.factorize` into a kept `a_lu` for multi-RHS
  (`setOmega`, :157–161).
- **Sparse** ($n>128$): a $2n$ CSC pattern with exactly $4\cdot\text{nnz}$ entries is
  derived once from the circuit CSC (:66–90); per-$\omega$ fill is a straight streamed
  copy from the _borrowed_ planes — left columns $[\,G \mid +\omega C\,]$, right columns
  $[\,-\omega C \mid G\,]$ (:163–189) — then `direct.Solver.factor` on the fixed pattern
  (first call full, thereafter numeric refactor; see §4.1). Planes are borrowed: the
  circuit must outlive the solver and not be re-eval'd mid-sweep (:36–37).
- `solveRhsT` (:205–220): adjoint at the current $\omega$; sparse path uses `solveT`,
  dense path explicitly transposes and refactors twice (cold path, small $n$). Note the
  plain real transpose of the stacked-real matrix is the stacked-real form of
  $G^{\mathsf T} - j\omega C^{\mathsf T} = M^{\mathsf H}$, i.e. **`solveRhsT` solves the
  true conjugate-transpose adjoint** $M^{\mathsf H}y = b$ (see §5.5).

### 4.5 GMRES + ILU(0): not in this crate

Absent from `modules/analysis/src/solver/` on branch `refactor/crate-split` — deliberately:
direct.zig:23–26 excludes iterative solvers from the time-domain Newton loop by the MNA
conditioning invariant. Commit `51bad17` ("Add ILU(0) preconditioner support to GMRES
solver") lives only in workflow worktrees (e.g.
`.claude/worktrees/wf_ac6e3c3e-dc8-15/analysis/src/solver/gmres.zig`); grep hits on `ilu`
in `stb.zig`/`tran_noise.zig`/`compiled.zig` are substring false positives ("fa**ilu**re").
GMRES with left-ILU(0) preconditioning solves $M^{-1}Ax = M^{-1}b$, $M = \tilde L\tilde U$
on the sparsity of $A$, minimizing $\|r_0\| - \|Ax_k - b\|$ over the Krylov space
$\mathcal K_k(M^{-1}A, M^{-1}r_0)$ via Arnoldi + Givens least squares — but is not a
consumer of the current planes on this branch.

### 4.6 FFT — `solver/fft.zig` (509 lines)

Zero-dependency, in-place, caller-owned buffers; time-series only (transient
post-processing; conventions match ngspice/numpy, :12–13).

- `fft`/`ifft` (:24–43): radix-2 Cooley–Tukey DIT,
  $$X_k = \sum_{n=0}^{N-1} x_n e^{-j2\pi nk/N}$$
  unnormalized forward, $1/N$ inverse; bit-reversal (:235–246) + iterative butterflies
  with recurrence-rotated twiddles (:250–280).
- `fftReal` (:48–133): real-input FFT via the $N/2$ packing $z_k = x_{2k} + jx_{2k+1}$
  with conjugate-pair unpack; writes $N/2+1$ bins.
- `bluestein` (:142–209): chirp-z for arbitrary $N$,
  $X_k = b_k^{*}\sum_n (x_n b_n^{*})\,b_{k-n}$, $b_m = e^{j\pi m^2/N}$, as a circular
  convolution zero-padded to $M = \mathrm{nextPow2}(2N-1)$.

**Solver consumption map:**

| Module          | CSC pattern                                   | Values input                                                      |
| --------------- | --------------------------------------------- | ----------------------------------------------------------------- |
| `direct.Solver` | frozen `col_ptr/row_idx` (init-time ordering) | caller-built `vals` on the pattern ($G$, $G+\alpha C$, freq $2n$) |
| `order`         | pattern only                                  | —                                                                 |
| `dense_lu`      | none                                          | dense row-major $G,C$ via `denseG/denseC`                         |
| `freq_solve`    | circuit CSC → derived $2n$ CSC (once)         | borrowed `g_vals`/`c_vals` after one `eval(x_op,0)`               |
| `fft`           | none                                          | time-series buffers                                               |

---

## 5. The analyses

Each section: what it computes, the math, and **Requires from CompiledCircuit** — the
per-analysis requirements list.

### 5.1 DC operating point (`dc.zig`)

**Computes:** the DC solution $x$ (node voltages + branch currents, ground pinned to 0)
of $f(x)=0$ at $t=0$, charge terms ignored ($A=G$). dc.zig is a 43-line wrapper: `solve`
(cold start $x^0=0$) and `solveWarm` (caller's $x$ + `gmin_extra` floor for the OP
continuation), both delegating to the shared Newton loop of §3 (dc.zig:16–43).

**Math:** per iteration, sparse LU solve of the regularized system

$$
\big(G(x^k) + g_{\min}I\big)\Delta x^k = -\big(f(x^k) + g_{\min}x^k\big),
\qquad g_{\min} = \max(g_{\text{extra}}, 10^{-12}),
$$

then $\Delta x_i \leftarrow \operatorname{clamp}(\Delta x_i,\pm10)$,
$x^{k+1} = \mathcal L(x^k + \Delta x^k,\ x^k)$ (junction limiting). Converged when
$\|\Delta x^k\|_\infty < 10^{-12}$ (pre-limited step), vetoed for one iteration on any
state flip. The converged point satisfies $f(x^\ast) + g_{\min}x^\ast = 0$ — a permanent
$10^{-12}$ S shunt everywhere ($\sim10^{-6}$ V error floor in the divider test).
`dc.Options.reltol` is declared but never forwarded — convergence is absolute-only
(dc.zig:10–12, 38–42).

**Solver:** `direct.Solver` via `newton.Workspace` — BTF+AMD once, Gilbert–Peierls first
factor, zero-alloc refactor thereafter, `solveNeg` step; TriDiag fast path if applicable.

**Requires from CompiledCircuit:**

- `computeBaseline()` once in `solveWarm` (dc.zig:35) — freezes `g_base/c_base`.
- `evalNewton(x, t=0)` — the only eval path (newton.zig:32); baseline restore + ground pin.
- `g_vals` (factored matrix $A=G$), `rhs` (residual, mutated by the gmin term).
- `diag_slots` (gmin regularization + ground-pin slot), `n`, `col_ptr`/`row_idx`
  (one-time solver init).
- `applyLimits(x, x_old)`, `updateStates(x)`.
- **Not consumed:** `combineGC`, `denseG/denseC`, `q_vec`/`c_vals` (written when
  `has_charge` but never read), `collectNoiseSources`, `collectParams`, history hooks.

### 5.2 Operating point with continuation (`op.zig`)

**Computes:** the same DC point as §5.1, but with **gmin-stepping continuation** as
fallback: plain Newton from $x=0$ at $\gamma = 10^{-12}$; on failure, the diagonal-loading
homotopy $F_\gamma(x) = F(x) + \gamma x = 0$,
$\gamma: 10^{-2} \to 10^{-12}$, $\gamma_{j+1} = \max(\gamma_j/2, g_{\min})$, warm-started
per stage; no retreat on stage failure (op.zig:28–62). Each stage is _exact_ Newton on the
loaded residual (both $J_{ii}{+}{=}\gamma$ and $F_i{+}{=}\gamma x_i$), so it converges to
the true root of $F_\gamma$. The loading hits **all** $n$ diagonals — branch-current rows
and the ground row too, unlike classic SPICE gmin (newton.zig:56–59; compiled.zig:607–608).
$A = G$ only; `reltol` dead (op.zig:15, 64–70).

**Solver:** as §5.1; one Workspace for the entire continuation (op.zig:35–37).

**Requires from CompiledCircuit:**

- `computeBaseline()` once before the continuation (op.zig:35).
- `evalNewton(x, 0)`, `g_vals`, `rhs`, `diag_slots`, `n`/`col_ptr`/`row_idx`,
  `applyLimits`, `updateStates` — exactly as §5.1.
- **Not consumed:** `combineGC`, `denseG/denseC`, `collectNoiseSources`, `collectParams`,
  history hooks; `c_vals`/`q_vec` stamped but never read.

### 5.3 Transient analysis (`tran.zig`)

**Computes:** the time-domain solution of $f(x,t) + \tfrac{d}{dt}q(x) = 0$ from a DC start
to $t_{\text{stop}}$ with variable timestep, recording probed unknowns into a `Waveform`
and firing a per-accepted-step callback (envelope/pnoise/pac build on it).

**Math.** Discretization at $t_{k+1} = t_k + \Delta t$ (tran.zig:19–27, 159–189) — the
companion residual is built from the **exact** $q(x)$ plane (nothing lagged, no per-device
companion sources):

$$
\text{BE }(\alpha = 1/\Delta t):\quad F(x) = f(x, t_{k+1}) + \alpha\big(q(x) - q_k\big) = 0,
$$

$$
\text{TRAP }(\alpha = 2/\Delta t):\quad F(x) = f(x, t_{k+1}) + \alpha\big(q(x) - q_k\big) - i_k = 0,
$$

with the classic SPICE dynamic-current recursion on acceptance (tran.zig:304–318):
$i_{k+1} = \alpha(q_{k+1} - q_k) - i_k$ (trap; omitting $-i_k$ makes an RC decay with
twice the time constant — test tran.zig:387–416), $i_0 = 0$ at the DC point. Newton per
step with the exact analytic matrix (dx clamp disabled: $\infty$, tran.zig:273):

$$
\big(G(x^m) + \alpha C(x^m) + g_{\min}I\big)\Delta x = -\big(F(x^m) + g_{\min}x^m\big),
\qquad \|\Delta x\|_\infty < 10^{-9}.
$$

**LTE** via divided differences of the 4-level charge history ring (tran.zig:35–63):

$$
\text{BE: } \varepsilon_j = \Delta t^2\big|q_j[t_0,t_1,t_2]\big| \approx \tfrac{\Delta t^2}{2}|q_j''|,\qquad
\text{TRAP: } \varepsilon_j = \tfrac12\Delta t^3\big|q_j[t_0,t_1,t_2,t_3]\big| \approx \tfrac{\Delta t^3}{12}|q_j'''|,
$$

$$
\text{LTE} = \max_j \varepsilon_j / \max(|q_j|, 10^{-15}).
$$

**Step control** (tran.zig:67–87, 282–297): reject + halve on Newton failure or
$\text{LTE} > \text{tol}$ (fail hard below $\Delta t_{\min}$); else

$$
\Delta t_{\text{new}} = \Delta t\cdot\min\!\Big(2,\ 0.9\big(\tfrac{\text{tol}}{\text{LTE}}\big)^{1/(p+1)}\Big),
\quad p = 1\ (\text{BE}),\ 2\ (\text{trap}),
$$

clamped to $[\Delta t_{\min},\ \min(\Delta t_{\max}, \tau_{d,\min})]$ where $\tau_{d,\min}$
is the minimum device delay. Accepted steps swap cur/trial pointers; final step truncated
to land on $t_{\text{stop}}$ (:343).

**Solver:** sparse direct LU only (per §4.1) through `newton.solve`; chargeless circuits
factor `g_vals` directly with no copy (tran.zig:192).

**Requires from CompiledCircuit:**

- `n`, `nnz`, `has_charge`, `has_history` (tran.zig:206–208, 229).
- `evalNewton(x,t)` per Newton iteration (tran.zig:160); `eval(x,t)` only to snapshot
  $q(x)$ for the history ring (t=0 and after each accepted step, :233–234, 285–286).
- `rhs` (companion residual added in place, SIMD W=8, :167–186), `q_vec` (companion + LTE
  ring), `g_vals`, `combineGC(α, a_vals)` (one axpy building $A$, :193).
- `computeBaseline()` before the loop (:226).
- `injectHistory(t)` post-assemble (:188), `recordHistory(x,t)` (:240, 337), `minDelay()`
  clamping effective `dt_max` (:243–244).
- `col_ptr/row_idx`, `diag_slots`, `applyLimits`, `updateStates` via `newton.solve`.
- **Not consumed:** `collectNoiseSources`, `collectParams`, `denseG/denseC`, adjoint
  `solveT`.

### 5.4 AC small-signal sweep (`ac.zig`)

**Computes:** the complex frequency response $H_p(f_k)$ at probe nodes, linearized once at
a supplied $x_{op}$, excitation on a voltage source's **branch row** (the branch equation
$v_p - v_n - V = 0$ means $\text{rhs}[\text{branch}] = V_{ac}$; driving the clamped node
would give zero response, ac.zig:44–46).

**Math.** One AD eval at $x_{op}$; per point of the log grid
($N = \lceil\text{decades}\cdot ppd\rceil + 1$, $f_k$ geometric, freq.zig:7–16):

$$
(G + j\omega_k C)\,\hat x(\omega_k) = \hat b, \qquad
\hat b_\beta = V_{ac}e^{j\phi},\ \hat b_{i\neq\beta} = 0,\ \omega_k = 2\pi f_k,
$$

solved in the stacked-real $2n$ form
$\big[\begin{smallmatrix} G & -\omega C\\ \omega C & G\end{smallmatrix}\big]
\big[\begin{smallmatrix} x_{re}\\ x_{im}\end{smallmatrix}\big] =
\big[\begin{smallmatrix} b_{re}\\ b_{im}\end{smallmatrix}\big]$.
Probes: $H_p = x_{\text{work}}[\text{node}] + j\,x_{\text{work}}[n + \text{node}]$
(ac.zig:80–85). No Newton, no circuit contact inside the frequency loop (ac.zig:1–3).

**Solver:** `FreqSolver` (§4.4), dense iff $n \le 128$, else the fixed-pattern sparse LU
on the derived $2n$ CSC. Per-$\omega$ `factor` is a **full factorization only at the first
frequency point; numeric refactors thereafter** (direct.zig:70–85), with fallback to full
factor on pivot collapse.

**Requires from CompiledCircuit:**

- `eval(x_op, 0)` — exactly **one** plain eval for the entire sweep, inside
  `FreqSolver.fromCircuit` (freq_solve.zig:50).
- `g_vals`, `c_vals` — borrowed by reference (sparse path); circuit must outlive the
  solver and not be re-eval'd mid-sweep (freq_solve.zig:36–37, 99–100).
- `col_ptr/row_idx` — read once to derive the $2n$ stacked-real CSC ($4\cdot$nnz entries);
  `n`, `nnz`; `denseG/denseC` on the dense path.
- Ground-pin convention: $g_{00}=1$ with AC $\text{rhs}[0]=0$ forces zero AC ground
  response.
- Input: `x_op` from a prior `dc.solve`; `ac_branch` (vsource branch index).
- **Not consumed:** `rhs`/`q_vec` planes, `evalNewton`, `combineGC`,
  `collectNoiseSources`, `collectParams`, history, `updateStates`, `solveRhsT`.

### 5.5 Noise analysis (`noise.zig`) — adjoint / interreciprocal method

**Computes:** output-referred noise voltage PSD $S_{out}(f)$ [V²/Hz] at one output node
over a log sweep, plus integrated RMS noise: **one adjoint solve per frequency**, then a
dot product per source — $O(N_f)$ solves instead of $O(N_f \times N_{\text{sources}})$.

**Math.** Linearize once at $x_{op}$; stacked-real
$M(\omega) = \big[\begin{smallmatrix} G & -\omega C\\ \omega C & G\end{smallmatrix}\big]$.
Adjoint solve per frequency (noise.zig:76) via `solveRhsT`, which — because the plain
real transpose of the stacked-real matrix is the stacked-real form of
$G^{\mathsf T} - j\omega C^{\mathsf T}$ — solves the **true conjugate-transpose adjoint**

$$
M^{\mathsf H} y = e_{out}
$$

(the code comment at noise.zig:74–75 is correct as written; relative to the
plain-transpose adjoint the recovered $y$ is conjugated, which is harmless since only
$|H|^2$ enters the density). For each thermal source $k$ between $(p,n)$:

$$
H_k(j\omega) = (y_p - y_n) + j(y_{p+n} - y_{n+n}), \qquad
S_{i,k} = 4k_BT\,g_k \ [\mathrm{A^2/Hz}],
$$

$g_k$ read directly off the analytic AD Jacobian by `collectNoiseSources` — no
perturbation; ground terminals contribute 0 (noise.zig:81–84). Sources uncorrelated:

$$
S_{out}(f) = \sum_k |H_k(j2\pi f)|^2\, 4k_BT\,g_k, \qquad
V_{n,\mathrm{rms}} = \sqrt{\textstyle\sum_k \tfrac12\big(S_{out}(f_{k-1}) + S_{out}(f_k)\big)(f_k - f_{k-1})}
$$

(trapezoid in _linear_ frequency over log-spaced points — coarsest per-hertz at the top
decade, noise.zig:93, 98). Only thermal noise is implemented: `NoiseSource` carries no
kind/frequency field, so shot/flicker kinds (compiled.zig:48) never reach the sweep.

**Solver:** `FreqSolver`; sparse path uses `Lu.solveT`
($A^{-\mathsf T} = P^{-1}L^{-\mathsf T}U^{-\mathsf T}Q^{\mathsf T}$, direct.zig:369–398);
dense path ($n\le128$) costs three LU factorizations per point (setOmega, explicit
transpose, restore — freq_solve.zig:158–160, 207–216).

**Requires from CompiledCircuit:**

- `eval(x_op, 0)` once via `FreqSolver.fromCircuit`; borrowed `g_vals`/`c_vals`;
  `col_ptr/row_idx` → derived $2n$ pattern; `n`, `nnz`; `denseG/denseC` (dense path).
- `collectNoiseSources(x_op)` (compiled.zig:1549–1557, 38–42) — caller obtains
  `[]NoiseSource{node_p, node_n, conductance}` off the analytic Jacobian.
- `GROUND` sentinel (compiled.zig:21).
- Input: converged `x_op` from `dc.solve`.
- **Not consumed:** `rhs`, `q_vec`, `evalNewton`, `combineGC`, `collectParams`, history,
  `updateStates`.

### 5.6 Periodic noise (`pnoise.zig`) — frozen-time LPTV approximation

**Computes:** output noise PSD of a periodically driven circuit + RMS over the band:
PSS by fixed-point shooting, sample $G(t_k), C(t_k)$ at $N$ points on the trajectory, then
fold period-averaged $|H|^2$ over $2M+1$ sidebands. Frozen-time (adiabatic) LPTV — LTI
snapshots averaged over the period, **not** conversion-matrix PNoise; captures duty-cycle-
averaged gain and PSD folding, not noise frequency translation. Reduces provably to AC
noise for LTI circuits (tests pnoise.zig:324–469).

**Math.**

1. _PSS shooting_ (pnoise.zig:208–301): fixed-point $x_0^{(i+1)} = x(T; x_0^{(i)})$ until
   $\|x(T) - x_0\|_\infty < \varepsilon$; no monodromy Newton. The "integration" is
   **quasi-static**: at each $t_k = kT/N$ solve only $I(x_k, t_k) = 0$ with $J = G$ —
   the $dq/dt$ term is dropped entirely (EvalHook factors `g_vals` only), so a linear RC
   would show instantaneous settling per sample. Non-convergence after 50 iterations only
   flags `pss_converged=false`; the trajectory is used anyway.
2. _LPTV sampling_: $G_k, C_k$ densified per sample after one AD eval (:101–107).
3. _Sideband transfer_: for sweep frequency $f$, sideband $m \in [-M, M]$,
   $f_m = f + mf_0$ folded to $\omega_m = 2\pi|f_m|$ (exact-DC sidebands skipped); per
   sample $k$ and source $s$ solve
   $$(G_k + j\omega_m C_k)\,h_{s,k} = e_{p_s} - e_{n_s}$$
   (unit current across the source), $H_{s,k} = h_{s,k}[\text{out}]$, period-averaged
   $\overline{|H_s|^2}(f_m) = \tfrac1N\sum_k |H_{s,k}|^2$.
4. _PSD and RMS_ (:132–191):
   $$
   S_v(f) = \sum_{m=-M}^{M}\sum_s 4k_BT\,g_s\,\overline{|H_s|^2}(f + mf_0), \qquad
   V_{n,rms} = \sqrt{\textstyle\int S_v\,df}\ \text{(trapezoid on the log grid)}.
   $$
   All sources treated as white thermal ($4k_BT g$) regardless of physical origin.

**Solver:** PSS phase — shared sparse Newton (§3/§4.1); noise phase — dense partial-pivot
LU on the $2n\times2n$ realified admittance, one factorization per (sideband, sample) pair
amortized over all sources via `solveFactored` (dense*lu.zig:55, 81, 142). Cost
$\sim N*{\text{sweep}}\,(2M{+}1)\,N$ dense factorizations.

**Requires from CompiledCircuit:**

- `n`; `eval(x_k, t_k)` (plain) per PSS sample to fill both planes; `denseG/denseC`
  snapshots (ground-pin row keeps the dense system nonsingular).
- `NoiseSource` slice (caller-supplied, from `collectNoiseSources(x_op)`); `GROUND`.
- Via PSS Newton: `evalNewton`, `g_vals`, `rhs`, `diag_slots`, `applyLimits`,
  `updateStates`, `col_ptr/row_idx` (one Workspace for all PSS solves).
- Input: `x_dc` as PSS initial guess (pnoise.zig:73, 228).
- **Not consumed:** `q_vec`, `combineGC` (dense path instead), `collectParams`, history
  buffers.

### 5.7 Transient noise (`tran_noise.zig`) — Monte Carlo stochastic transient

**Computes:** a time-domain sample path with thermal noise — an implicit Euler–Maruyama
scheme with sample-and-hold noise: backward-Euler transient where every thermal source
injects one fresh Gaussian current per step, band-limited to the step Nyquist bandwidth so
the discrete sequence carries the correct white PSD independent of $\Delta t$.

**Math.** Per step of width $\Delta t$, source $k$ draws (Box–Muller on xorshift64,
tran_noise.zig:36–63):

$$
i_k^{(m)} = \sigma_k\,\xi_k^{(m)}, \qquad
\sigma_k = \sqrt{4k_BT\,g_k\,\mathrm{BW}}, \qquad \mathrm{BW} = \frac{1}{2\Delta t},
\qquad \xi \sim \mathcal N(0,1);
$$

a ZOH sequence with variance $\sigma_k^2$ at rate $1/\Delta t$ has one-sided PSD
$4k_BT g_k$ exactly. $\sigma_k \propto 1/\sqrt{\Delta t}$ is recomputed every step
(:144–149) — halved $\Delta t$ doubles the sample variance, PSD stays flat. The step
solves BE with noise in the residual:

$$
F(x_{m+1}) = I(x_{m+1}, t_{m+1}) + \frac{1}{\Delta t}\big(Q(x_{m+1}) - Q(x_m)\big)
+ \sum_k i_k^{(m)}(e_{p_k} - e_{n_k}) = 0,
$$

Newton with $A = G + C/\Delta t + g_{\min}\mathbb 1$, dx clamp $\infty$, tol $10^{-9}$.
Injections to `GROUND` are skipped by explicit compare (:86–87). After convergence one
extra full eval refreshes $Q$ exactly (planes are one iterate stale, :177–181). Step
control is deliberately not LTE-based (noise dominates local error): halve on Newton
failure, grow $\times1.5$ capped at `dt_max` (:169–190). BE only — no trap/Gear.

**Solver:** shared Newton loop over the sparse direct LU (§4.1); Newton errors are
swallowed into a dt-halving retry (:162–175).

**Requires from CompiledCircuit:**

- `eval(x,t)` — **full** eval (never `evalNewton`; baseline optimization bypassed) every
  Newton iteration (:80), for initial `q_prev` (:130), and post-convergence refresh
  (:179).
- `rhs` (mutated: BE companion term + sampled noise currents), `q_vec`, `g_vals`
  (chargeless path), `combineGC(1/Δt, a_vals)`, `n`, `nnz`, `has_charge`.
- `NoiseSource` (caller-supplied; production callers use `collectNoiseSources(x_op)`),
  `GROUND`.
- Via `newton.solve`: `diag_slots`, `applyLimits`, `updateStates`, `col_ptr/row_idx`.
- **Not consumed:** `evalNewton`/`computeBaseline`, `denseG/denseC`, `collectParams`,
  history buffers, `combineGCAndClear`, `solveT`.

### 5.8 DC sensitivity (`sens.zig`) — brute-force finite difference

**Computes:** $\partial V_{out}/\partial p_i$ for a list of scalar device parameters
(raw `*f32` `ParamRef` pointers into frozen batch arrays), by direct perturbation —
explicitly _not_ adjoint (`solveT` exists, documented "adjoint — noise/sens",
direct.zig:114, but is never called): cost is $(1 + N_{\text{params}})$ full Newton DC
solves on one frozen pattern.

**Math.** Nominal $F(x, p) = 0$ by the §3 Newton loop. Per parameter (sens.zig:66–86):

$$
\delta_i^{\text{req}} = 10^{-6}|p_i| + 10^{-12},\qquad
\tilde p_i = \mathrm{fl}_{32}(p_i + \delta_i^{\text{req}}),\qquad
\delta_i = (\tilde p_i)_{f64} - p_i
$$

— the FD divisor is the **realized f32 step**, not the requested one ($S_i := 0$ if
rounding swallows it). Re-solve from a **cold zero start** (not warm-started despite the
$\sim10^{-6}$ perturbation), then the one-sided forward difference

$$
S_i = \frac{\partial V_{out}}{\partial p_i} \approx
\frac{x^{(i)}[n_{out}] - x^{(0)}[n_{out}]}{\delta_i}
\quad\big(\text{truncation } O(\delta_i)\big).
$$

Parameter and precompute caches restored afterwards (defer + final `recompute`).

**Baseline caveat:** `sens.run` never calls `computeBaseline()` (unlike `dc.solveWarm`),
and `recompute()` does not invalidate `has_baseline` — correct perturbed Jacobians for
constant-Jacobian devices depend on `evalNewton` taking its no-baseline full-eval fallback;
entering with `has_baseline==true` would factor a stale `g_base` (sens.zig:43–55, 72;
compiled.zig:1362–1377, 1544–1548).

**Solver:** sparse direct LU via one shared `newton.Workspace` (nominal + all perturbed
solves); refactor hot path with fallback.

**Requires from CompiledCircuit:**

- `evalNewton(x, 0)`, `g_vals` (only factored plane), `rhs`, `diag_slots`, `n`,
  `col_ptr/row_idx`, `applyLimits`, `updateStates`.
- `recompute()` after each in-place f32 mutation and at exit (compiled.zig:1544–1548).
- `ParamRef`/`collectParams` — `SensParam.ptr` is exactly a `ParamRef.ptr`
  (compiled.zig:26–33, 1550–1555).
- **Precision on dead work:** `c_vals`/`q_vec` are _written_ inside the Newton assemble
  path when the circuit has charge (memcpy/zero + batch stamps,
  compiled.zig:1464–1484, 1152–1172) but never _consumed_ — never factored, never fed to
  the solve.
- **Not consumed:** `combineGC`, `denseG/denseC`, `collectNoiseSources`, history, full
  `eval` (only via evalNewton's fallback), `solveT`.

### 5.9 Monte Carlo (`mc.zig`) — sampling-based tolerance/yield analysis

**Computes:** per-probe mean, Bessel-corrected std dev, min/max, and interval yield over
repeated DC solves with randomly perturbed parameters. Plain independent-sample MC —
deterministic 64-bit LCG (Numerical Recipes constants) + Box–Muller; reproducible from
the seed; no variance reduction / LHS / QMC.

**Math.** LCG $s_{k+1} = a s_k + c \bmod 2^{64}$, uniforms from the top 53 bits
(mc.zig:25–33). Per trial, parameter $p_j$ with tolerance $\tau_j$:

$$
p_j^{(k)} \sim
\begin{cases}
\mathcal U\big[p_{j,0}(1-\tau_j),\ p_{j,0}(1+\tau_j)\big) & \text{uniform}\\[2pt]
p_{j,0} + p_{j,0}\tau_j z,\quad z = \sqrt{-2\ln\max(u_1, 10^{-300})}\cos(2\pi u_2) & \text{Gaussian (unbounded — no truncation)}
\end{cases}
$$

then `recompute()` and a cold-start ($x=0$) Newton DC solve (§3, $A=G$). Statistics over
the $N_c$ **converged** trials only (failed trials silently dropped;
`n_runs − n_converged` is the only record):

$$
\bar y_p = \tfrac{1}{N_c}\sum_k y_p^{(k)},\qquad
s_p = \sqrt{\tfrac{1}{N_c-1}\sum_k (y_p^{(k)} - \bar y_p)^2},\qquad
\text{Yield}_p = 100\cdot\tfrac{\#\{y_p^{(k)}\in[lo,hi]\}}{N_c}\,\%.
$$

Parameters restored to nominal after every trial (draws never compound; mc.zig:252–256).

**Baseline interaction (corrected):** a stale `g_base` does **not** mask perturbations of
constant-Jacobian devices. The `skip_g` branch skips only the G-matrix scatter; `rhs` is
still stamped freshly with perturbed parameters each iteration
(compiled.zig:1142–1150), so Newton with a stale (chord) Jacobian still converges to the
correct perturbed root — only convergence rate/robustness degrades, and failures are
reported via `converged=false`, not silently wrong answers. (`recompute` at
compiled.zig:1640–1644 never touches `has_baseline`/`g_base`; `evalNewton` at :1464–1484;
`computeBaseline` at :1488–1522.)

**Solver:** one `direct.Solver` (Workspace) for the entire run; refactor hot path.

**Requires from CompiledCircuit:**

- `evalNewton(x, 0)`, `g_vals`, `rhs`, `diag_slots`, `n`, `col_ptr/row_idx`,
  `applyLimits`, `updateStates` (per §5.1).
- `recompute()` per trial + at exit; `ParamRef`/`collectParams` for `param_ptr`.
- `g_base/has_baseline` conditionally (restored by `evalNewton` if previously built).
- **Not consumed:** `c_vals`/`q_vec` (dead writes), `combineGC`, `denseG/denseC`,
  `collectNoiseSources`, history, `minDelay`, `setCircuitTemp`.

### 5.10 Pole analysis (`pz.zig`) — eigenvalues of $A = -G^{-1}C$

**Computes:** **poles only** (no zeros — `Result` has no input/output designation,
pz.zig:16–27): all eigenvalues of the dense state matrix $A = -G^{-1}C$ at a supplied
$x_{op}$, mapped to natural frequencies, plus a stability count and QR-convergence flag.

**Math.** One full AD eval at $(x_{op}, 0)$ gives $G, C$; the ground pin makes $G$
generically nonsingular. Nontrivial small-signal natural response requires
$\det(G + sC) = 0$; substituting $A := -G^{-1}C$:

$$
Av = \lambda v \iff \big(G + \tfrac1\lambda C\big)v = 0
\;\Rightarrow\; s = \frac{1}{\lambda} = \frac{\bar\lambda}{|\lambda|^2}
\quad\text{(pz.zig:88)},
$$

$\lambda$ in seconds (negated time constants). Eigenvalues with
$|\lambda| \le 10^{-9}\max_k|\lambda_k|$ are dropped (:78–87) — these correspond to
**poles at $s = \infty$** (non-dynamic resistive modes; in-code comment at :77), _not_
poles at the origin: a genuine $s=0$ pole (ideal integrator) means $\lambda \to \infty$,
requiring $\det G = 0$, which fails loudly with `error.Singular` at the dense LU
(:29–32, :59) before eigenvalues are computed; a near-singular $G$ (gmin leakage) gives a
very large $|\lambda|$ that is never discarded, so near-origin poles do appear.

**Forming A:** one dense LU $PG = LU$ (:59), then $n$ triangular solves
$a_{:,j} = -G^{-1}c_{:,j}$ (:61–71). **Eigensolver:** Householder Hessenberg reduction
(SIMD W=4, :191–275), then Francis implicit double-shift QR: first column of
$(H - \sigma_1 I)(H - \sigma_2 I)$ via $s = h_{mm} + h_{m+1,m+1}$,
$t = h_{mm}h_{m+1,m+1} - h_{m,m+1}h_{m+1,m}$, bulge chased with 3×3/2×2 reflectors
(:281–411); deflation when
$|h_{k+1,k}| \le 10^{-12}\max(|h_{kk}| + |h_{k+1,k+1}|, 10^{-30})$, iteration counter
reset per deflation (`qr_converged=false` needs 1000 _consecutive_ stagnant iterations);
2×2 blocks by the quadratic formula. Stability: $n_{stable} = \#\{\operatorname{Re}s < 0\}$.

**Solver:** dense LU (`factorize`/`solveFactored`) + in-house dense nonsymmetric
eigensolver; work memory one bulk allocation of $3n^2 + 2n$ f64 + $n$ u32 pivots
(:44–55). No sparse path, no Newton.

**Requires from CompiledCircuit:**

- `eval(x_op, 0)` — full AD eval, exactly once (rhs/q_vec filled but ignored).
- `denseG(out)`, `denseC(out)` (compiled.zig:1461–1477); implicitly `col_ptr/row_idx` via
  the scatter; `n`.
- Ground pin (nonsingular $G$).
- Input: `x_op` from `dc.solve` (pz does no Newton).
- **Not consumed:** `evalNewton`, `rhs`, `q_vec`, `combineGC`, `collectNoiseSources`,
  `collectParams`, history, `updateStates`, `applyLimits`, `findSlot`.

### 5.11 DC transfer function (`tf.zig`) — .TF

**Computes:** three scalars at a supplied $x_{op}$ for a designated input vsource and
output node: DC small-signal gain $dV_{out}/dV_{in}$, input resistance, output resistance.
One eval, one forward dense solve, one transpose dense solve. C plane filled but never
read — TF results are independent of all charge stamps.

**Math.** $J = G = \partial F/\partial x|_{x_{op}}$ from one `eval(x_op, 0)`; the input
source's branch row is $F_b = x_p - x_n - V_{in} = 0$ (branch unknown $b$), node stamp
$F_p \mathrel{+}= i_b$.

_Forward (direct sensitivity):_ only the branch row depends on $V_{in}$ (coefficient
$-1$), so

$$
J\,v = e_b,\qquad v = \frac{\partial x}{\partial V_{in}},\qquad
\text{gain} = v_o,\qquad
R_{in} = \frac{1}{-\partial i_b/\partial V_{in}} = -\frac{1}{v_b}
\ \ (= \infty \text{ if } v_b = 0)
$$

(the delivered current is $-i_b$ by the stamp convention, tf.zig:45–54).

_Adjoint (transpose):_

$$
J^{\mathsf T}u = e_o,\qquad R_{out} = u_o = \big(J^{-\mathsf T}\big)_{oo} = \big(J^{-1}\big)_{oo}
$$

— unit current into the output with independent sources killed (automatic: only the
Jacobian enters). The transpose is mathematically redundant for this diagonal entry, but
the code explicitly forms $J^{\mathsf T}$ and re-factorizes (tf.zig:56–66). A source
directly across the output clamps it: $R_{out} = 0$ (test :111–133).

**Solver:** two independent dense fused `factorizeSolve` calls (partial pivoting, RHS
carried through elimination, no pivot storage — every new RHS is a full $O(n^3)$
refactorization; dense_lu.zig:11–53).

**Requires from CompiledCircuit:**

- `eval(x_op, 0)` — full AD, exactly once; only the G plane read via `denseG(jac)`
  (tf.zig:32–35; compiled.zig:1461–1478).
- Ground pin ($g_{00}=1$ keeps dense $G$ nonsingular); vsource branch-row convention
  (RHS placement + $R_{in}$ sign); `n`.
- Input: caller-provided `x_op`.
- **Not consumed:** `c_vals`/`denseC`, `q_vec`, `rhs` plane, `evalNewton`/baseline,
  `combineGC`, `collectNoiseSources`, `collectParams`, history, `updateStates`.

### 5.12 Distortion (`disto.zig`) — simplified second-order Volterra HD2

**Computes:** $\mathrm{HD2}(f) = |V_2(\text{out})|/|V_1(\text{out})|$ over a log sweep for
a single sinusoidal current excitation: linearize once, build the second-order kernel by
finite-differencing the _analytic_ Jacobian ("FD of AD" — only the extra derivative order
is numerical), then per frequency one linear solve at $\omega$ and one at $2\omega$ driven
by the quadratic intermodulation current. HD2 scales linearly with input amplitude by
construction (test disto.zig:315–365).

**Math.** At $x_0$ (caller's DC point), $G, C$ from one eval. Second-order kernel
(:79–104), one full eval per unknown $b$, $\varepsilon = 10^{-6}$:

$$
K_{r,a,b} = \frac{\partial^2 F_r}{\partial x_a\partial x_b}\bigg|_{x_0}
\approx \frac{G_{r,a}(x_0 + \varepsilon e_b) - G_{r,a}(x_0)}{\varepsilon}
$$

($n{+}2$ evals total; dense $n^3$ f64 tensor). The charge Hessian $\partial C/\partial x$
is **not** differenced — capacitive nonlinearity is excluded ($C$ frozen at $x_0$; a
circuit whose only nonlinearity is a nonlinear capacitor reports HD2 = 0). Per frequency
$\omega = 2\pi f$:

$$
(G + j\omega C)V_1 = A\,e_{\text{src}}, \qquad
D_{2,r} = \sum_{a,b} K_{r,a,b}\,V_{1,a}V_{1,b}\ \text{(no } \tfrac12\text{ Taylor factor)},
$$

$$
(G + j2\omega C)V_2 = -D_2(V_1, V_1), \qquad
\mathrm{HD2}(f) = \frac{|V_{2,\text{out}}|}{|V_{1,\text{out}}|}
\ (0 \text{ if } |V_{1,\text{out}}| \le 10^{-30}).
$$

The missing $\tfrac12$ deviates by 2× from the textbook second-harmonic source term —
covered by the header's "simplified" qualifier. $V_1 \propto A \Rightarrow V_2 \propto A^2
\Rightarrow \mathrm{HD2} \propto A$ (Volterra scaling). The constant ground pin cancels
out of the FD kernel.

**Solver:** dense only — per frequency two independent fused `factorizeSolve` LU calls on
$2n\times2n$ real-equivalent matrices ($\omega$ and $2\omega$), plus an $O(n^3)$ bilinear
contraction with a `coeff==0` skip.

**Requires from CompiledCircuit:**

- `eval(x, 0)` — full AD eval, $n{+}2$ times: at $x_{op}$, per perturbed
  $x_{op}+\varepsilon e_b$, and once more at $x_{op}$ to restore plane consistency.
- `denseG` (per perturbation), `denseC` (once, at $x_{op}$); ground pin; `n`.
- Input: converged `x_op` from `dc.solve`; `logSweep` grid.
- **Not consumed:** `rhs`/`q_vec` planes, `evalNewton`/baseline, `combineGC`,
  `collectNoiseSources`, `collectParams`, history, `updateStates`, sparse CSC solves.

### 5.13 Harmonic balance (`hb.zig`) — single-tone HB, Newton on the real spectrum

**Computes:** the periodic steady state under a single-tone cosine current excitation
(`source_mag` at `source_node`, frequency $f_0$), retaining DC + $H$ harmonics per node,
by trigonometric collocation with Newton on the stacked real Fourier vector.

**Math.** Per node: $X_j = (X_{j,0}, X_{j,1}^c, X_{j,1}^s, \dots, X_{j,H}^c, X_{j,H}^s)$,
$n_f = 2H+1$; total $N = n\,n_f$ unknowns. Collocation at $t_k = kT/n_f$
(critically sampled — Nyquist limit is harmonic $H$, so nonlinearity products at any
$m > H$ **alias into the retained $0..H$ spectrum** since
$\cos(2\pi mk/n_f) = \cos(2\pi(n_f{-}m)k/n_f)$; quadratic products in $(H, 2H]$ already
alias). Pipeline per Newton iteration:

_IDFT_ (hb.zig:153–178):
$x_j(t_k) = X_{j,0} + \sum_h [X_{j,h}^c\cos(h\omega_0 t_k) + X_{j,h}^s\sin(h\omega_0 t_k)]$.

_Sampling_ (:182–203): one full AD eval per sample, **always at $t=0$** (internal
time-varying sources frozen at their $t=0$ value);
$f_j(t_k) = i_j(x(t_k)) + \delta_{j,\text{src}}I_0\cos(\omega_0 t_k)$.

_Rectangle-rule DFT_ (:207–244):
$F_{j,0} = \tfrac1{n_f}\sum_k f_j(t_k)$,
$F_{j,h}^{c,s} = \tfrac2{n_f}\sum_k f_j(t_k)\{\cos,\sin\}(h\omega_0 t_k)$.

_Frequency-domain charge current_ (:246–264), $C$ frozen at the $k{=}0$ sample
(`q_vec` never read — nonlinear charges linearized about $x(t_0)$, not balanced
spectrally):

$$
F_h^c \mathrel{+}= -h\omega_0\,C\,X_h^s, \qquad F_h^s \mathrel{+}= +h\omega_0\,C\,X_h^c
$$

— the sign-negation of the analytic $d/dt$ on the basis; the Jacobian blocks (:352–353)
use the identical convention, so Newton is self-consistent and magnitudes are exact, but
harmonic phases are conjugated relative to true $C\,dx/dt$.

The HB system is $\mathbf F(\mathbf X) = \Gamma\, i(\Gamma^{-1}\mathbf X) + \Omega C\,
\mathbf X + \mathbf U = 0$, converged when $\|\mathbf F\|_\infty < \text{tol}$.

_Truncated conversion-matrix Jacobian_ (:276–356): per dense element, DFT of $G_{rc}(t)$;
stamped blocks are only $G_0$ on (dc,dc) and same-harmonic (cos,cos)/(sin,sin) diagonals,
DC↔harmonic couplings $G_h^c/2, G_h^s/2$ (row dc) and $G_h^c, G_h^s$ (col dc), plus the
$\pm h\omega_0 C_{rc}$ charge rotation. All $h\neq h'$ and resistive cos↔sin cross-blocks
are omitted — **inexact Newton with an exact residual** (fixed points are exact).

_Update_ (:358–364): dense LU $J\,\Delta\mathbf X = -\mathbf F$, full undamped step.
Ground handling: the eval pin flows through $G_0$ and the residual DFT, making every
ground harmonic block identity-like; Newton drives the ground spectrum to zero.

**Solver:** dense partial-pivot LU on the full $N\times N$ Jacobian via
`factorizeSolveNeg` (fused, pivot threshold $10^{-30}$); no damping/line search; one arena
allocation sliced by offset (:107–135). Cost per iteration: $n_f$ full circuit evals +
one $O(N^3)$ LU.

**Requires from CompiledCircuit:**

- `eval(x, 0)` — full AD eval (not evalNewton, no baseline), $n_f$ times per Newton
  iteration.
- `rhs` (I-residual per sample), `denseG` at **every** sample, `denseC` **only at
  $k=0$**; `has_charge` (gates denseC vs zero); `GROUND`; ground pin (nonsingular dense
  Jacobian); `n`.
- **Not consumed:** `evalNewton`/`computeBaseline`, `combineGC`, `q_vec`, sparse pattern
  directly, `collectNoiseSources`, `collectParams`, history, `updateStates`.

### 5.14 Periodic steady state (`pss.zig`) — shooting Newton (Aprille–Trick)

**Computes:** $x_0$ such that integrating the full nonlinear DAE over one period $T$
returns to $x_0$; then one extra transient from the converged $x_0$ records the
steady-state waveform.

**Math.** Flow map $\Phi_T(x_0) = x(T; x_0)$ by full transient integration (§5.3
machinery). Solve

$$
\varphi(x_0) = \Phi_T(x_0) - x_0 = 0, \qquad
J_\varphi\,\Delta x_0 = -\varphi(x_0), \quad x_0 \leftarrow x_0 + \Delta x_0,
$$

where the exact $J_\varphi = M(T) - I$ (monodromy) is approximated column-by-column by
forward finite differences — one full-period transient per column (pss.zig:110–126):

$$
[J_\varphi]_{:,j} \approx \frac{\varphi(x_0 + \epsilon e_j) - \varphi(x_0)}{\epsilon},
\qquad \epsilon = 10^{-7}\ \text{(absolute)}.
$$

Deliberately NOT the analytic AD planes — those give the Jacobian of the residual $F$,
not of the period map (doc, pss.zig:39–41). If a perturbed integration fails, that column
is silently replaced by $e_j$ (:116–119). Convergence
$\|\varphi\|_\infty < 10^{-7}$ is tested _before_ building the Jacobian, so an
already-periodic start converges after one transient and zero dense solves (:104–108).
Cost per iteration: $(1+n)$ transients of length $T$ + one dense $n\times n$ LU. Inner
integration: trapezoidal companion, LTE control, gmin, exactly §5.3.

**Solver:** outer — dense `factorizeSolveNeg`; inner — the shared sparse Newton/direct LU
stack. No matrix-free Krylov shooting.

**Requires from CompiledCircuit** (mostly transitively via `tran.simulate`):

- `n` (shooting vectors + dense $J_\varphi$); `evalNewton`, `eval` (q snapshots), `rhs`,
  `q_vec`, `g_vals`, `combineGC`, `nnz`, `computeBaseline`, `has_charge`/`has_history`,
  `recordHistory`/`injectHistory`/`minDelay`, `col_ptr/row_idx`, `diag_slots`,
  `applyLimits`, `updateStates`; ground pin (FD column $j=0$ well-defined).
- Input: `x_dc` as initial shooting guess.
- **Not consumed:** `collectNoiseSources`, `collectParams`, `denseG/denseC` (the FD
  $J_\varphi$ is PSS's own dense matrix), adjoint `solveT`.

### 5.15 Periodic AC (`pac.zig`) — LPTV conversion-matrix analysis

**Computes:** for each swept input frequency $f_{in}$, the complex transfer at every
sideband $f_{in} + mf_{LO}$, $m \in [-M, M]$ — conversion gain of mixers/switched
circuits including frequency translation. Since the excitation is a **current** injection,
node-voltage results are trans-impedances (V/A).

**Math.**

1. _LPTV linearization:_ around the periodic trajectory $x_p(t)$,
   $$G(t)\,\delta x + \frac{d}{dt}[C(t)\,\delta x] = b(t).$$
2. _Quasi-static PSS (the actual code, not the header comment):_ $(P{-}1)N$ frozen-time
   Newton solves at each $t_k$ with Jacobian $G$ only — the $C\dot x$ term absent from
   residual and Jacobian; convergence failures are silently swallowed
   (`catch` + discarded Result, pac.zig:139–147).
3. _Harmonic decomposition:_ $G(t_k), C(t_k)$ captured densely per sample (one `eval`
   each), then per matrix entry an FFT gives
   $$G_m = \frac1N\sum_k G(t_k)e^{-j2\pi mk/N} \quad (\text{negative } m \to \text{bin } N{+}m),$$
   test-verified: $G(t) = g_0(1 + \mu\cos\omega_0 t) \Rightarrow G_0 = g_0,\ G_{\pm1} = g_0\mu/2$.
4. _Conversion matrix:_ with $\delta x(t) = \sum_q X_q e^{j\omega_q t}$,
   $\omega_q = 2\pi(f_{in} + qf_{LO})$, frequency matching gives per output sideband $p$:
   $$
   \boxed{\ \sum_{q=-M}^{M}\big[G_{p-q} + j\,\omega_p\,C_{p-q}\big]X_q = B_p\ }
   \qquad B_p = \delta_{p,0}\,A\,e_{\text{src}}
   $$
   — $\omega_p$ (the **row/output** sideband frequency) multiplies $C_{p-q}$: the
   standard $\Omega C$ convention ($z_{re} = G_{re} - \omega_p C_{im}$,
   $z_{im} = G_{im} + \omega_p C_{re}$, pac.zig:228, 247–248).
5. _Real embedding:_ the complex $n_{sb}n$ system ($n_{sb} = 2M{+}1$) expands to
   dimension $2n_{sb}n$ and is dense-LU solved per sweep point;
   $H_m(f_{in}) = X_m[\text{probe}]$.

The ground pin lands in the $m{=}0$ harmonic block after the FFT (constant in time),
keeping ground pinned in every sideband diagonal block.

**Solver:** (1) PSS: shared sparse Newton (§3); (2) decomposition: in-tree radix-2 FFT,
run $n^2$ times per plane (including structural zeros); (3) sweep: dense partial-pivot
fused LU on the $2(2M{+}1)n$ real embedding per point — $O((2(2M{+}1)n)^3)$ flops, no
factor reuse across frequencies.

**Requires from CompiledCircuit:**

- `eval(x, t)` per captured sample (fills both planes); `evalNewton` indirectly per PSS
  Newton solve; `g_vals` (PSS matrix + denseG source), `c_vals` (via denseC only),
  `rhs` (inside newton.solve).
- `denseG/denseC` per sample; `col_ptr/row_idx` (Workspace + scatter), `diag_slots`,
  `applyLimits`, `updateStates`, `n`; ground pin.
- Input: `x_init` (DC operating point) as PSS seed.
- **Not consumed:** `q_vec`, `combineGC` (jωC built per-sideband densely),
  `collectNoiseSources`, `collectParams`, history buffers (delay devices would be
  linearized incorrectly — no delay-aware LPTV term).

### 5.16 Envelope following (`envelope.zig`) — quasi-static variant

**Computes:** the slowly varying modulation envelope (peak and RMS per probe) of a
carrier-driven circuit, exploiting $T_{\text{mod}} \gg T_c$. Deliberately degenerate
envelope following: the inner "transient" is a sequence of **quasi-static Newton solves
with $A = G$ only** — capacitive/inductive dynamics have zero effect on the result
(c_vals/q_vec computed by evalNewton but discarded; no `combineGC` anywhere).

**Math.** Inner solve at each sampled $t$: exact Newton on
$F(x,t) = I(x,t) + g_{\min}x = 0$ (§3 loop; clamp ±10, tol $10^{-9}$, gmin $10^{-12}$).
Outer loop with fine step $\Delta t = T_c/M$ ($M=64$ default) and multiplier
$N_k \in [1, 16]$:

$$
T_{k+1} = \min(T_k + N_kT_c,\ t_{\text{stop}});
$$

coarse skip at $4\Delta t$ to $T_{k+1} - T_c$, then $M$ fine solves over one carrier
period; per probe

$$
P_k = \max_{0\le m\le M}|x_{t_m}[p]|, \qquad
R_k = \sqrt{\tfrac{1}{M+1}\sum_{m=0}^{M} x_{t_m}[p]^2}
$$

(divisor $M{+}1$ includes the period-start sample). Bang-bang adaptation on peak change
only (RMS stored but unused for control):
$\rho_k = \max_p |P_k - P_{k-1}|/\max(|P_{k-1}|, 10^{-15})$; halve $N_k$ if
$\rho_k > \varepsilon$ (0.05), double if $\rho_k < \varepsilon/4$. Newton failure rolls
$x$ back to the outer snapshot and halves $N_k$. **No** extrapolation update
$x(T{+}NT_c) \approx x(T) + N[x(T{+}T_c) - x(T)]$ and no envelope shooting — skipped
periods are actually traversed quasi-statically.

**Termination caveat (corrected):** `outer_steps` increments only on _successful_ steps
(envelope.zig:219); both failure paths `continue` without incrementing, so persistent
Newton failure at `min_periods_per_step` is an **unbounded infinite loop** —
`max_outer_steps` ($10^6$) bounds successful steps only. Also the $t=0$ point stores
signed `x[node]` as peak (no `@abs`), inconsistent with later points.

**Solver:** shared Newton + sparse direct LU (§4.1), one Workspace for all solves; no
dense path, no FFT.

**Requires from CompiledCircuit:**

- `evalNewton(x,t)` (only assembly call; baseline path used when built), `g_vals` (only
  factored plane), `rhs`, `diag_slots`, `applyLimits`, `updateStates`, `n`,
  `col_ptr/row_idx`.
- Input: caller-supplied initial `x` (tests seed from `dc.solve`).
- **Not consumed:** `eval` (full), `combineGC`, `c_vals`/`q_vec` (dead writes),
  `denseG/denseC`, `collectNoiseSources`, `collectParams`, history buffers, LTE
  machinery.

### 5.17 Fourier analysis (`four.zig`) — .FOUR harmonic decomposition + THD

**Computes:** DC component, fundamental + harmonics 2–9 (amplitude/phase), and THD of the
**last fundamental period** of a transient waveform (assumed settled to periodic steady
state; rectangular window). Pure post-processor; `run()` first drives a full §5.3
transient on one probe.

**Math.** Window $[t_{end} - T, t_{end})$, $T = 1/f_0$ (`error.InsufficientData` if less
than one period exists); resample to $N = \mathrm{nextPow2}(\text{raw})$ uniform points by
binary-search linear interpolation (four.zig:35–67, 168–189). Unnormalized radix-2 FFT;
because the window is exactly one period, harmonic $h$ lands on bin $m = h$ — no leakage.
With the convention $A\cos(2\pi f_0 t + \varphi) \Rightarrow X[1] = \tfrac{NA}{2}e^{+j\varphi}$:

$$
A_0 = \frac{\operatorname{Re}X[0]}{N}, \qquad
A_h = \frac{2}{N}|X[h]|, \qquad
\varphi_h = \operatorname{atan2}(\operatorname{Im}X[h], \operatorname{Re}X[h])\cdot\tfrac{180}{\pi},
$$

bins $h \ge N/2$ zeroed;

$$
\mathrm{THD}\,[\%] = \frac{\sqrt{\sum_{h=2}^{9}A_h^2}}{A_1}\times 100
\quad (0 \text{ if } A_1 \le 10^{-30}).
$$

`Options.n_harmonics` is dead — a fixed `[9]Harmonic` array is always computed (:15,
135–156).

**Accuracy (corrected):** the non-power-of-2 amplitude error is dominated by
**linear-interpolation attenuation, $O(1/N^2)$** (measured factor ~4 per doubling of
$N$), _not_ the right-edge clamp in `analyzeBuffer` (:92) — wrapping periodically changes
the fundamental error by only ~2%; the clamp's measurable effect is on the DC bin.
Power-of-2 inputs pass at $10^{-10}$ because `n_fft == samples.len` makes the resampler an
identity copy ($\alpha = 0$). `run()` returns `error.TransientFailed` when
`completed=false` — which occurs on Newton/LTE-driven $dt < dt_{\min}$ **or** on
`max_steps` exhaustion before $t_{\text{stop}}$ (tran.zig:257, 348); solver/eval errors
are folded into the same dt-halving path (tran.zig:274).

**Solver:** none in four.zig itself (radix-2 FFT kernel only); `run()` transitively uses
the full transient stack (§5.3).

**Requires from CompiledCircuit:**

- Directly: **nothing** — `analyze`/`analyzeBuffer` operate on `tran.Waveform`/raw
  samples.
- Transitively via `tran.simulate` (run path): everything in §5.3's list
  (`evalNewton`, `eval`, `rhs`, `q_vec`, `g_vals`, `combineGC`, `computeBaseline`,
  history hooks, `diag_slots`, `applyLimits`, `updateStates`, pattern).
- **Not consumed anywhere on this path:** `c_vals` directly (only via combineGC),
  `collectNoiseSources`, `collectParams`, `denseG/denseC`.

### 5.18 Shared frequency utilities (`freq.zig`) — LogSweep + Complex

**Not an analysis** — the shared infrastructure for all frequency-domain analyses
(imported by ac, noise, stb, disto, sp, pz, pac, pnoise; re-exported at root.zig:32). Its
only import is `std`; zero CompiledCircuit contact and no solve of any kind.

**Math.** Log sweep grid (freq.zig:7–16), $D = \log_{10}(f_{stop}/f_{start})$ decades,
$p$ points/decade:

$$
N = \lceil D\,p\rceil + 1, \qquad
f_k = 10^{\,\log_{10}f_{start} + \frac{k}{N-1}D} = f_{start}\Big(\frac{f_{stop}}{f_{start}}\Big)^{k/(N-1)}
$$

endpoint-inclusive **up to pow/log10 rounding at both ends** — even $k=0$ computes
$\mathrm{pow}(10, \log_{10}f_{start})$ rather than returning $f_{start}$, which is not
bit-exact for general f64 (e.g. $\mathrm{pow}(10, \log_{10}999.0) = 999.0000000000001$).
No validation: $f \le 0$ produces NaN/garbage counts. Complex type (:39–96): textbook
(non-Smith) mul/div, $|z|$, $\angle z$, and

$$
|z|_{dB} = \begin{cases} -300 & |z| < 10^{-30}\\ 20\log_{10}|z| & \text{else.}\end{cases}
$$

**Corrected:** the $10^{-30}$ guard is **not a floor at $-300$ dB** — $-300$ dB
corresponds to magnitude $10^{-15}$; magnitudes in $[10^{-30}, 10^{-15})$ take the else
branch and legitimately report below $-300$ dB, while magnitudes below $10^{-30}$ (true
dB $< -600$) are _snapped up_ to $-300$, making `magDb` non-monotonic (discontinuous jump
$\sim{-600}\to{-300}$) at the threshold.

**Requires from CompiledCircuit:** nothing (pure scalar/iterator utility). The
frequency-domain circuit consumption lives in `solver/freq_solve.zig` (§4.4).

### 5.19 S-parameter sweep (`sp.zig`)

**Computes:** the full $n_{\text{ports}}\times n_{\text{ports}}$ scattering matrix per
frequency about a DC operating point, with reference-impedance-embedded ports and the
real-$z_0$ power-wave definition.

**Math.** One eval at $x_{op}$ gives $G, C$. Port embedding (sp.zig:80–83): for port $p$
with vsource branch row $\beta_p$,

$$
G'[\beta_p, \beta_p] = G[\beta_p, \beta_p] - z_{0,p}
$$

(Thevenin form $v_+ - v_- - z_{0,p}i_{br} = V_s$; un-excited ports terminate in $z_0$
rather than clamping; $C$ untouched ⇒ terminations real and frequency-independent). Per
frequency, excited port $p$ with unit source ($\text{rhs}[\beta_p] = 1$):

$$
(G' + j\omega C)\,x = e_{\beta_p}
$$

in stacked-real $2n$ form. Power waves (real $z_0$; Kurokawa reduces to classic):

$$
a_p = \frac{1}{2\sqrt{z_{0,p}}}, \qquad
b_k = \frac{v_k - z_{0,k}i_k}{2\sqrt{z_{0,k}}}, \quad i_k = -x[\beta_k]
$$

(current _into_ the DUT is minus the MNA branch current; $v_k = 0$ for grounded port
nodes), giving $S_{kp}(f) = b_k/a_p$. Log or linear grid. The ground row rides through
the dense LU as the decoupled $x_0 = 0$.

**Solver:** dense LU **unconditionally** — `sweep()` calls `FreqSolver.initDense`
directly, never `fromCircuit`, so the sparse branch and the `DENSE_THRESHOLD=128` check
are unreachable. Per frequency: one $2n\times2n$ `buildComplexAdmittance` + `factorize`,
shared across $n_{\text{ports}}$ `solveFactored` back-substitutions.

**Requires from CompiledCircuit:**

- `eval(x_op, 0)` — plain eval, exactly once per sweep (sp.zig:71).
- `denseG/denseC` (n×n dense copies; ground row included, trash slot excluded); `n`;
  `GROUND` sentinel; MNA layout convention (Port.node / Port.branch, vsource stamp sign).
- Input: `x_op` from `dc.solve`.
- **Not consumed:** `rhs`/`q_vec` planes, `combineGC`, sparse pattern directly,
  `collectNoiseSources`, `collectParams`, history, `updateStates`, `solveRhsT`.

### 5.20 Stability / loop gain (`stb.zig`)

**Computes:** loop gain $T(j\omega)$ over a log sweep plus gain and phase margins, via a
series 0 V voltage-probe injection (single-injection return ratio — _not_ the full
two-injection Tian/Middlebrook combination despite the header label).

**Math.** Stage 1: DC operating point by §3 Newton (`error.DcNotConverged` on failure —
no gmin-stepping retry inside stb). Stage 2: one plain `eval(x_op, 0)`; densify $G, C$
(ground-pin row included, so $x_0 = 0$ is preserved in the AC solves). Stage 3: augment
to $(n{+}1)^2$ with a 0 V probe branch between `probe_p`/`probe_n` — symmetric $\pm1$
incidence stamps $e = e_p - e_n$ in $G$ only ($C$ branch row/col zero: ideal
frequency-independent short; branch diagonal exactly 0, no gmin in the AC solve). Per
$\omega = 2\pi f$:

$$
\begin{bmatrix} G + j\omega C & e \\ e^{\mathsf T} & 0 \end{bmatrix}
\begin{bmatrix} \hat x \\ \hat\imath_{br} \end{bmatrix} =
\begin{bmatrix} 0 \\ 1 \end{bmatrix},
\qquad
T(j\omega) = -\hat\imath_{br} = \frac{1}{e^{\mathsf T}(G + j\omega C)^{-1}e}
$$

— algebraically the driving-point admittance across the probe terminals. Stage 4
(computeMargins, stb.zig:122–178): PM at the first downward 0 dB crossing, linear in dB
with **raw wrapped** phase,

$$
\mathrm{PM} = 180^\circ + \varphi_{k-1} + \alpha(\varphi_k - \varphi_{k-1}), \quad
\alpha = \frac{|T|_{dB,k-1}}{|T|_{dB,k-1} - |T|_{dB,k}}
$$

(a ±360° wrap between the bracketing samples would corrupt PM); GM at the $-180^\circ$
crossing of the **unwrapped** phase,
$\mathrm{GM} = -(|T|_{dB,k-1} + \beta\,\Delta|T|_{dB})$. Both NaN if no crossing.

**Solver:** DC — sparse Newton stack; AC sweep — **always dense**: `FreqSolver.initDense`
on the augmented matrices (sparse path and threshold bypassed), one $2(n{+}1)$ dense LU
per point.

**Requires from CompiledCircuit:**

- Via `dc.solve`: `computeBaseline`, `evalNewton`, `g_vals`, `rhs`, `diag_slots`,
  `col_ptr/row_idx`, `applyLimits`, `updateStates`.
- `eval(x_op, 0)` once (rhs/q_vec discarded); `denseG/denseC` (ground pin row included);
  `n`; `GROUND` (probe stamps skipped for grounded terminals).
- **Not consumed:** `q_vec`, `combineGC` (jω combine happens inside FreqSolver),
  `collectNoiseSources`, `collectParams`, history, `findSlot`; sparse pattern unused for
  the AC solves.

### 5.21 Temperature sweep (`temp_sweep.zig`) — .TEMP / DC over temperature

**Computes:** the DC operating point at each $T_k = T_{start} + k\Delta T$ (default
−40…125 °C, 1 °C; loop guard $T \le T_{stop} + \Delta T/2$). Per point: push $T$ into
device batches (`setCircuitTemp`), apply explicit SPICE tempcos on `ParamRef` pointers,
`recompute()`, then a full Newton DC solve — **cold-started at $x = 0$ every point** (no
warm-start/continuation from the previous temperature). Restores $T_{nom}$ + base values +
`recompute()` at exit.

**Math.** Standard SPICE coefficient model (temp_sweep.zig:62–65), computed in f64,
stored through `*f32` (f32 rounding is the accuracy floor):

$$
p(T) = p(T_{nom})\big(1 + tc_1(T - T_{nom}) + tc_2(T - T_{nom})^2\big),
$$

then the §3 gmin-regularized Newton solve of $F(x; T_j) + g_{\min}x = 0$ (consistent
loading ⇒ $O(g_{\min}R)$ bias). $V_{\text{probe}}(T_j) = x_{\text{node}}$ at convergence.
Non-converged points are silently dropped and arrays compacted — `temps[i]` is _not_
$T_{start} + i\Delta T$ if any point failed; `completed = (failed == 0)`.

**Solver (corrected):** one `direct.Solver` initialized once on the frozen pattern serves
the entire sweep, and `factor()` performs the full symbolic+numeric+pivoting factorization
**only on the first call** — every subsequent Newton iteration of every temperature point
runs the zero-alloc numeric `refactor` (direct.zig:77–92, 322–351), with full
factorization recurring only as fallback on pivot collapse. (Caveat: tridiagonal patterns
get the `TriDiag` solver instead of GP LU, direct.zig:49–59.)

**Requires from CompiledCircuit:**

- `evalNewton(x, 0)` per iteration, `g_vals` (only factored plane), `rhs`, `diag_slots`,
  `n`, `col_ptr/row_idx`, `applyLimits`, `updateStates`.
- `setCircuitTemp(temp)` (compiled.zig:1633–1637), `recompute()` (:1639–1643),
  `collectParams`/`ParamRef` (:1645–1650; batch param arrays pointer-stable after
  compile).
- Baseline caveat as §5.8/§5.9: `recompute` never invalidates `has_baseline`; a
  pre-built baseline would leave stale constant stamps for temperature-modified constant
  devices (moot in tests — `computeBaseline` never called here).
- **Not consumed:** `c_vals`/`q_vec` (DC only), `combineGC`, `denseG/denseC`,
  `collectNoiseSources`, history hooks, full `eval`.

### 5.22 Measurement extraction (`meas.zig`) — .MEASURE post-processor

**Computes:** scalar figures of merit from a sampled (non-uniform) transient waveform:
max/min/peak-to-peak, time-weighted average and RMS, 10–90 % rise/fall times, propagation
delay, fundamental frequency. Pure post-processing: no simulation, no stamping, no linear
algebra, zero allocation; every function is $O(N)$.

**Math.** On samples $\{(t_k, v_k)\}_{k=1}^N$, $N = \min(|t|, |v|)$ (silent truncation;
empty inputs return 0, not errors):

$$
\bar v = \frac{1}{t_N - t_1}\sum_{k=2}^{N}\frac{v_{k-1} + v_k}{2}(t_k - t_{k-1}),
\qquad
v_{\mathrm{rms}} = \sqrt{\frac{1}{t_N - t_1}\sum_{k=2}^{N}\frac{v_{k-1}^2 + v_k^2}{2}(t_k - t_{k-1})}
$$

— note RMS trapezoids the _squared_ samples (treats $v^2$ as piecewise-linear): a single
linear ramp returns $\sqrt{(v_0^2 + v_1^2)/2}$ instead of the exact
$\sqrt{(v_0^2 + v_0v_1 + v_1^2)/3}$, systematically over-estimating on coarse grids.
Threshold crossing by linear interpolation (meas.zig:212–229):

$$
t_\times = t_{k-1} + \frac{V_{th} - v_{k-1}}{v_k - v_{k-1}}(t_k - t_{k-1}),
$$

degenerate slope ($|dv| < 10^{-30}$) snaps to $t_k$; the rising predicate is
strictly-below-then-at-or-above, so a first sample sitting exactly at threshold never
registers. Rise/fall use swing-relative thresholds
$V_\alpha = v_{\min} + \alpha(v_{\max} - v_{\min})$, $\alpha \in \{0.1, 0.9\}$; frequency
uses the trapezoidal mean as crossing level (DC removal) and returns
$f = (M-1)/(t^{(M)} - t^{(1)})$ over $M \ge 2$ rising crossings (0 Hz otherwise).

**Correctness note (corrected):** `findCrossingAfter` filters by right-endpoint sample
time but interpolates within the first accepted interval; in actual usage (`rise_time`/
`fall_time`, where `t_after` is itself a lower-threshold crossing on the same waveform and
segment) it can **never** return a time earlier than `t_after` — same-segment crossings
share the slope and $\text{hi} > \text{lo}$ forces $t_{hi} > t_{lo}$; the shared-interval
coarse-grid case yields the geometrically consistent interpolation with no inflation. The
only latent gap is the doc comment's "strictly after" over-promise for arbitrary
`t_after` values no caller supplies.

**Requires from CompiledCircuit:**

- **Nothing.** Only import is `std` (meas.zig:1); consumes `tran.Waveform` sample arrays
  as opaque f64 slices (borrowed-slice view, :9–18). `delay()` additionally requires both
  waveforms to share a time base (same tran run). Measurement fidelity inherits the
  transient's LTE/timestep control (piecewise-linear assumption between accepted points).

---

## 6. Summary table: analysis × planes × solver × hooks

| #   | Analysis   | File           | Planes consumed                                 | Matrix / solver                                              | Extra CompiledCircuit hooks                                                  |
| --- | ---------- | -------------- | ----------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| 1   | DC         | dc.zig         | g_vals, rhs                                     | $A=G$; sparse LU (BTF+AMD, GP, refactor)                     | computeBaseline, applyLimits, updateStates, diag_slots                       |
| 2   | OP         | op.zig         | g_vals, rhs                                     | $A=G$; sparse LU; gmin homotopy $10^{-2}\!\to\!10^{-12}$     | computeBaseline, applyLimits, updateStates                                   |
| 3   | TRAN       | tran.zig       | g_vals, c_vals, rhs, q_vec                      | $A=G+\alpha C$ (combineGC); sparse LU                        | computeBaseline, history (record/inject/minDelay), applyLimits, updateStates |
| 4   | AC         | ac.zig         | g_vals, c_vals (borrowed)                       | $G+j\omega C$ stacked-real; FreqSolver (dense ≤128 / sparse) | one plain eval; ground pin                                                   |
| 5   | NOISE      | noise.zig      | g_vals, c_vals (borrowed)                       | $M^{\mathsf H}y=e_{out}$ adjoint; FreqSolver solveRhsT       | collectNoiseSources ($4kTg$ off Jacobian)                                    |
| 6   | PNOISE     | pnoise.zig     | g_vals, rhs (PSS); g/c dense snapshots          | PSS: sparse Newton ($A=G$); noise: dense 2n LU per (m,k)     | collectNoiseSources (caller), applyLimits, updateStates                      |
| 7   | TRAN_NOISE | tran_noise.zig | g_vals, c_vals, rhs, q_vec                      | BE $G+C/\Delta t$; sparse LU; full eval (no baseline)        | NoiseSource injection, applyLimits, updateStates                             |
| 8   | SENS       | sens.zig       | g_vals, rhs                                     | $A=G$; sparse LU; $(1{+}N_p)$ cold Newton solves             | recompute, ParamRef/collectParams                                            |
| 9   | MC         | mc.zig         | g_vals, rhs                                     | $A=G$; sparse LU; one Workspace all trials                   | recompute, ParamRef/collectParams                                            |
| 10  | PZ         | pz.zig         | g_vals, c_vals (dense)                          | dense LU on $G$ + Hessenberg/Francis QR on $-G^{-1}C$        | denseG/denseC only                                                           |
| 11  | TF         | tf.zig         | g_vals (dense)                                  | two dense fused LU ($J$, $J^{\mathsf T}$)                    | denseG only                                                                  |
| 12  | DISTO      | disto.zig      | g_vals, c_vals (dense)                          | dense 2n LU at $\omega$, $2\omega$; FD-of-AD kernel $K$      | $n{+}2$ full evals, denseG/denseC                                            |
| 13  | HB         | hb.zig         | rhs, g_vals (dense/sample), c_vals (dense, k=0) | dense $N{=}n(2H{+}1)$ LU, inexact Newton                     | full eval ×$n_f$/iter, GROUND                                                |
| 14  | PSS        | pss.zig        | all four (via tran)                             | outer: dense FD $J_\varphi$ LU; inner: sparse tran stack     | computeBaseline, history, applyLimits, updateStates                          |
| 15  | PAC        | pac.zig        | g_vals, rhs (PSS); g/c dense samples            | PSS sparse Newton ($A=G$); FFT; dense $2(2M{+}1)n$ LU/point  | denseG/denseC, applyLimits, updateStates                                     |
| 16  | ENVELOPE   | envelope.zig   | g_vals, rhs                                     | $A=G$ quasi-static; sparse LU                                | applyLimits, updateStates                                                    |
| 17  | FOUR       | four.zig       | (via tran only)                                 | radix-2 FFT; transient stack transitively                    | tran hooks transitively                                                      |
| 18  | FREQ       | freq.zig       | none                                            | none (grid + Complex utilities)                              | none                                                                         |
| 19  | SP         | sp.zig         | g_vals, c_vals (dense)                          | dense 2n LU unconditionally (initDense)                      | denseG/denseC, GROUND                                                        |
| 20  | STB        | stb.zig        | g_vals, rhs (DC); g/c dense (AC)                | DC sparse Newton; AC dense $2(n{+}1)$ LU (initDense)         | computeBaseline, denseG/denseC                                               |
| 21  | TEMP       | temp_sweep.zig | g_vals, rhs                                     | $A=G$; sparse LU (refactor after first)                      | setCircuitTemp, recompute, ParamRef                                          |
| 22  | MEAS       | meas.zig       | none                                            | none (O(N) scans)                                            | none                                                                         |

**Cross-cutting invariants:** every matrix any analysis factors is an affine combination
of the two AD-filled Jacobian planes on one frozen CSC pattern; ground is a pinned real
unknown ($g_{00}{+}{=}1$, $f_0 = x_0$) so no analysis special-cases row elimination; gmin
regularization is residual-consistent everywhere ($J_{ii}{+}{=}\gamma$ _and_
$F_i{+}{=}\gamma x_i$); GMRES/ILU(0) is intentionally absent from this branch's solver
crate (§4.5); and all noise machinery reads conductances analytically off the AD Jacobian
— there is not a single finite-difference derivative in the device-assembly path (the only
FD in the codebase: sens's parameter perturbation, disto's second-order kernel, and PSS's
monodromy columns — each differencing _solutions or analytic Jacobians_, never device
physics).
