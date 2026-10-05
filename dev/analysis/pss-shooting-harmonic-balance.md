# Periodic Steady State: Shooting Newton + Harmonic Balance

Shooting Newton (dense finite-difference or matrix-free Krylov) and harmonic
balance.

## 1. Mathematical specification

### The two-point boundary value problem

For a circuit driven T-periodically, the periodic steady state is the
solution of the circuit DAE

$$
f(v(t), t) = i(v(t)) + \frac{d\,q(v(t))}{dt} + u(t) = 0
$$

that also satisfies the two-point boundary constraint (Kundert rf-sim.pdf
eq. 34)

$$
v(T) - v(0) = 0 .
$$

### Shooting Newton

Define the **state transition function** $\phi_T(v_0, t_0)$: the solution
at $t_0 + T$ of the initial value problem started at $v_0$ (rf-sim eq. 35):

$$
v(t_0 + T) = \phi_T(v(t_0), t_0).
$$

The shooting equation combines both (rf-sim eq. 36):

$$
\Phi(v_0) \;\equiv\; \phi_T(v_0, 0) - v_0 \;=\; 0,
$$

a nonlinear algebraic system in $v_0 \in \mathbb{R}^n$ solved by Newton:

$$
J_\Phi(v_0^k)\,\Delta v_0 = -\Phi(v_0^k), \qquad
J_\Phi = \frac{\partial \phi_T}{\partial v_0} - I .
$$

$M \equiv \partial\phi_T/\partial v_0$ is the **monodromy (sensitivity)
matrix**: how the state after one period responds to a change of the initial
state. Along the inner integration with steps $t_0 < t_1 < \dots < t_S = T$,
each implicit step $x_{s+1}$ satisfies the companion system, and implicit
differentiation gives the chain

$$
M \;=\; \prod_{s=S-1}^{0} \big(G_{s+1} + \alpha\, C_{s+1}\big)^{-1} \beta\, C_s ,
$$

($\alpha,\beta$ the integration coefficients: for BE,
$\alpha = \beta = 1/h_s$), i.e. one extra back-substitution per timestep per
initial-condition direction, using the *already factored* companion matrices
of the inner transient.

**Matrix-free Krylov shooting** *(Telichevesky/Kundert/White DAC'95 -
paywalled; derivation marked derived, concept verified against rf-sim.pdf)*:
never form $M$. Solve $ (M - I)\,\Delta v_0 = -\Phi $ with GMRES; each
Krylov application $M \cdot w$ is one pass of the recurrence

$$
w_{s+1} = \big(G_{s+1} + \alpha C_{s+1}\big)^{-1} \beta\, C_s\, w_s,
$$

which costs $S$ back-substitutions on saved factorizations: no new
factorizations, no $n \times n$ dense storage. GMRES converges in few
iterations because $M$'s spectrum clusters near 0 for stable circuits (fast
modes decay within a period), so $M - I$ has clustered eigenvalues near
$-1$. This is the SpectreRF PSS core; cost per shooting-Newton iteration is
$O(S \cdot \text{nnz})$ instead of $O(S \cdot n \cdot \text{nnz})$ for the
dense/FD Jacobian.

**Implementation status.** The Krylov path is implemented with a
finite-difference matvec instead of the saved-factor recurrence above:
$M w \approx (\phi_T(v_0 + \epsilon w) - \phi_T(v_0))/\epsilon$, one full
period integration per GMRES iteration, unpreconditioned. It runs from 50
unknowns up; below that the dense FD Jacobian is cheaper. The saved-factor
recurrence and subspace recycling remain targets (see
[monodromy-krylov.md](../solvers/monodromy-krylov.md)).

Convergence test: $\|\Phi(v_0)\|_\infty < \texttt{shooting\_tol}$, with the
inner transient's Newton solves governed by the usual tolerance bundle.

For **autonomous circuits** (oscillators) the period $T$ joins the unknowns
and a phase-anchoring equation (e.g. $\dot v_j(0) = 0$ or $v_j(0) = V$)
closes the system (rf-sim §4.1.5).

### Harmonic balance

Assume $v(t)$, $u(t)$ T-periodic and expand the DAE in a Fourier series
(rf-sim eqs. 23-24):

$$
\sum_{k=-\infty}^{\infty} F_k(V)\, e^{j2\pi k f t} = 0,
\qquad
F_k(V) = j2\pi k f\, Q_k(V) + I_k(V) + U_k ,
$$

where $V$, $Q_k$, $I_k$ are the Fourier coefficients of the node voltages,
charges, and resistive currents. Linear independence of the exponentials
gives one algebraic system **per harmonic**; truncation to $K$ harmonics
yields $n(2K{+}1)$ real unknowns (DC + cos/sin per harmonic per node):

$$
\hat F(\hat V) = \Omega\, \hat Q(\hat V) + \hat I(\hat V) + \hat U = 0,
\qquad \Omega = \mathrm{blkdiag}(j 2\pi k f).
$$

Nonlinear devices cannot be evaluated in the frequency domain: evaluate
$i(\cdot), q(\cdot)$ at time samples $t_s = sT/(2K{+}1)$ obtained by IDFT of
$\hat V$, DFT the results back (rf-sim §4.1.1). The HB Jacobian couples
harmonics through the spectrum of the time-varying small-signal conductance
$G(t) = \partial i/\partial v(v(t))$:

$$
\frac{\partial \hat I_k}{\partial \hat V_l} = \hat G_{k-l}
\quad\text{(block-Toeplitz in the exponential basis)},
\qquad
\frac{\partial}{\partial \hat V}\big(\Omega \hat Q\big)
= \Omega\, \hat C_{k-l},
$$

solved per Newton iteration. Newton on $\hat F$ with tolerance
$\|\hat F\|_\infty < \texttt{hb\_tol}$. HB shines for mildly nonlinear,
sharply frequency-selective circuits (distributed/measured linear models
stamp directly in $\Omega$-space); shooting shines for strongly nonlinear
switching circuits (the time-domain integrator places its own steps on the
sharp edges).

## 2. Flow explanation

**Shooting** (`src/analysis/pss/pss.zig`): start $v_0$ from the DC
operating point. Each shooting iteration integrates one period with
fixed-step trapezoidal ($n_{\text{samples}}$ steps, every buffer size known
up front, one scratch arena), computes $\Phi = x(T) - x_0$ and tests
$\|\Phi\|_\infty$. The Newton step depends on size:

- below 50 unknowns, $J_\Phi$ is built column by column by finite
  differences over the flow map (one period integration per column; the
  analytic planes give the Jacobian of $F$, not of the period map) and solved
  by dense LU. A failed inner integration in a perturbed column becomes an
  identity column instead of aborting;
- from 50 unknowns up, $(M - I)\,\Delta v_0 = -\Phi$ is solved by
  matrix-free GMRES with the FD matvec of §1. A failed integration inside a
  matvec returns a zero column.

After convergence one final period is integrated to record the waveform.

**Period seam.** Each period starts with the trapezoid dynamic current
seeded as $i_{\text{prev}} = -f(x_0)$ (the static residual at $x_0$) on rows
with a nonzero diagonal $C$ entry, and 0 elsewhere. A converged trapezoid
step always leaves $i_{\text{prev}} = -f(x_{\text{new}})$, so this is the
periodic trapezoid state carried across the seam; since it is a function of
$x_0$ it sits inside the FD shooting Jacobian and Newton stays quadratic.
The mask matters: unmasked, algebraic rows at a perturbed $x_0$ ring as
$\pm f(x_0)$ undamped and make the Jacobian near singular. Rows whose charge
has no diagonal $C$ entry get 0 (a `ponytail:` comment in `pss.zig` names
this ceiling). Zeroing $i_{\text{prev}}$ at every period start, as the code
once did, loses $dt\,i_0/2$ of charge per period: a steady mean offset of
$-(i_0 R)/(2N)$ on the RC decks, which matched the measured offsets to three
digits. The seed fixed `pss/rc_default` (3.91x to 0.03x of tolerance),
`rc_minimal_grid`, `rc_negative_amplitude`, `rc_slow_settling`,
`bench_pss_rlc_driven` (20.8x to 0.10x) and `diode_clipper` (issues.md F10,
commit `6ccb2a7`). Rejected alternatives: backward Euler for the first step of
each period (fails `rc_minimal_grid` at 3.17x and `rc_slow_settling` at
1003x), and carrying $i_{\text{prev}}(T)$ from the previous base integration
(a Picard update contracting at $e^{-T/\tau}$ per iteration, about 0.999 on
`rc_slow_settling`).

**HB** (`src/analysis/pss/hb.zig`): real trigonometric basis
$[\,dc, \cos_1, \sin_1, \dots, \cos_K, \sin_K\,]$, $2K{+}1$ time samples per
period. Per Newton iteration: IDFT $\hat V \to$ samples; one `ckt.eval` per
sample fills the residual, the analytic $G$ plane and $q(t_k)$; cosine source
excitation added in the time domain; DFT residuals to $\hat F$. The charge
term is the DFT of $q(t_k)$ differentiated spectrally, exact for nonlinear
charge (commit `c0023c8`; QPSS does the same). The dense HB Jacobian is
assembled from the harmonic content of $G(t)$ (DC and first-order cos/sin
cross-blocks kept, higher-order intermodulation blocks truncated) plus the
$\pm\omega_h C$ skew blocks, where $C$ is sampled at $t_0$ only. That makes
Newton quasi-Newton for nonlinear charge; the residual is exact, so the
fixed point is right. Dense LU, a backtracking line search on the
residual. Non-convergence is `error.HbDidNotConverge`.
`hb.solveSpectrum` returns every unknown's spectrum, and `hb.orbit`
samples it on any grid, which is how `.hbac`, `.hbxf` and `.hbnoise` reuse
the shooting analyses' back halves ([periodic-noise.md](periodic-noise.md),
[pac.md](pac.md)). The
per-sample $G$ values are stored slot-major over the nnz pattern (samples
contiguous per slot), not as dense per-sample matrices: `hb/diode_clipper`
219.1M to 210.1M Ir (-4.1%), and a diode clipper with a 40-stage RC ladder
at `.hb 1k 8` 19.28G to 18.42G Ir with peak RSS 12.8 to 11.2 MB (commit
`47e9b03`).

**Oscillators (autonomous PSS and HB).** An oscillator has no drive to
set the period, so T is an unknown, and every time shift of the orbit is
another solution. One unknown has to go to fix the phase.

- Shooting (`.pss v(osc) f [n [settle]]`, alias HSPICE `.snosc`): T joins
  the unknowns and x0[osc] leaves them, pinned at its start value, so the
  Newton system stays n x n with the osc column holding dφ/d(ln T) (an FD
  period integration at T(1 + ε); the Krylov matvec perturbs T the same
  way). The start is VACASK and Spectre's tstab in miniature
  (`startOscillator`): kick the DC point by 1 mV at the osc node, integrate
  `settle` guess periods (default 30), record 8 more, take the period as
  the mean spacing of the osc node's rising mid-swing crossings, and start
  Newton from the first sample after the last crossing. Steps change ln T
  by at most 0.2. `error.OscillatorDidNotStart` when fewer than two
  crossings show. The period is the last row's time. VACASK's phase
  condition is αᵀΔx0 = 0 with α = ẋ(0); pinning one node is HSPICE's
  OSCNODE, cheaper and enough when that node's slope at the anchor is not
  small, which the mid-swing anchor ensures.
- HB (`.hb v(osc) f [K]`, alias HSPICE `.hbosc`): the osc node's sin_1
  coefficient is held at 0 and its unknown becomes ln f0. f0 enters the
  residual only through the charge terms, linearly, so that Jacobian column
  is the charge-term vector itself, exact. HB from the DC point would find
  the trivial solution, so the seed is the shooting orbit above: its first K
  harmonics, time-shifted so the osc fundamental is a cosine. HSPICE's
  HBOSC instead searches amplitude and frequency with a probe source of
  voltage VP (PROBENODE, FSPTS); that is not implemented, and PROBENODE's
  VP is not accepted.

Measured against ngspice-45 long transients (`uic`, reltol 1e-6, periods
from 50 to 150 rising crossings, same digits at a 2.5x to 4x finer step):

| Deck | ngspice | ESPice | Rel. error |
|---|---|---|---|
| `pss/ring_oscillator` (3-stage tanh ring, 256 steps) | T = 3.52176 us | 3.52195 us | 5.4e-5 (trapezoid, 256 steps) |
| `hb/ring_oscillator` (K = 15) | f = 283.9489 kHz | 283.9493 kHz | 1.4e-6 |
| `hb/lc_oscillator` (Van der Pol, K = 7) | f = 999.4303 kHz | 999.4305 kHz | 2e-7 |

The Van der Pol frequency sits eps²/16 below 1/(2π sqrt(LC)) (eps = 0.095),
and HB puts the fundamental at 1.00007 V against the describing-function
1 V.

Knobs: `period`/`f0`, `n_samples` (shooting time resolution),
`n_harmonics`, `shooting_tol`/`hb_tol`, `fd_epsilon`, inner Newton budget
and tolerance; the global bundle governs inner transient steps.

## 3. Pseudo-code, CPU sequential

```
pss_shooting(ckt, x_dc, T, S=n_samples):
    x0 = x_dc
    for iter in 0..max_shooting_iter:
        x_end = integrate_one_period(x0)         # S fixed trap steps,
        phi   = x_end - x0                       #   Newton per step
        if max|phi| < shooting_tol: break
        for j in 0..n:                           # FD Jacobian, column j
            x_end_j = integrate_one_period(x0 + eps*e_j)
            J[:,j]  = ((x_end_j - (x0+eps*e_j)) - phi)/eps
        solve dense (J) dx0 = -phi;  x0 += dx0
    record final period from x0

# n >= 50: matrix-free Krylov (implemented with an FD matvec)
pss_krylov(ckt, x_dc, T):
    for iter in ...:
        phi = integrate_one_period(x0) - x0; if converged: break
        GMRES solve (M - I) dx0 = -phi where
            (M - I)*w = ((integrate_one_period(x0 + eps*w) - (x0 + eps*w)) - phi)/eps
        x0 += dx0
# target: replace the FD matvec with the saved-factor recurrence
#   w_{s+1} = solve_saved(s+1, beta*C_s*w_s)  for s = 0..S-1

hb(ckt, f0, K):
    X = 0                                        # [dc,cos,sin]*K per node
    for iter in 0..max_iter:
        x_td = IDFT(X)                           # 2K+1 samples per node
        for each sample k: eval(x_td[:,k])       # fills F, analytic G, q(t_k)
                            (k==0: capture C)
        f_td += source excitation
        F = DFT(f_td) + spectral derivative of DFT(q_td)
        if max|F| < hb_tol: return X
        J = spectral(G(t)) blocks + (+-w_h C) skew blocks
        solve dense J dX = -F;  X += dX
```

## 4. Parallel execution

Today everything runs on the host: the shooting and HB Newton loops, the
dense LUs and GMRES. Device evaluation inside each inner Newton iterate can
use `ParEval` threads or the GPU plane hook (`Circuit.gpu_hook.eval_planes`).

Not implemented (design notes):

- **Shooting.** The FD Jacobian's $n$ columns are independent period
  integrations from perturbed initial states, one lane each. With the
  saved-factor recurrence, the per-step propagation
  $w_{s+1} = A_{s+1}^{-1}\beta C_s w_s$ applies to a whole block of Krylov (or,
  for pnoise, adjoint) vectors as one multiple-RHS triangular solve.
- **HB.** The $2K{+}1$ sample evaluations are independent (a `ponytail:`
  comment in `hb.zig` marks where to batch them); DFT/IDFT are batched GEMMs
  or FFTs; the Jacobian solve becomes matrix-free GMRES with the
  block-Toeplitz operator applied as FFT, diag($G(t)$), IFFT per Krylov
  vector and a block-diagonal $(G_0 + j\omega_h C)$ preconditioner per
  harmonic.

The outer Newton iterations (both methods) and the time march inside
shooting stay sequential.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Inner fixed-step trap Newton (per timestep of every period integration) | [klu-pipeline.md](../solvers/klu-pipeline.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/solver/direct.zig` via `converger.run` + `PeriodHook` |
| Shooting Jacobian solve (dense $J_\Phi$) | none (dense path) | `src/solver/dense_lu.zig factorizeSolveNeg` |
| Krylov shooting from 50 unknowns up: GMRES on $(\Phi-I)$ with an FD matvec | [monodromy-krylov.md](../solvers/monodromy-krylov.md) | `src/solver/gmres.zig`; saved-factor replay and recycling are targets |
| HB spectral Jacobian solve (dense) | none (dense path); a Krylov-HB upgrade would use the block-Toeplitz apply of [lptv-block-solves.md](../solvers/lptv-block-solves.md) and a preconditioner from [structured-preconditioners.md](../solvers/structured-preconditioners.md) (neither implemented) | `dense_lu.zig` |
| Upstream OP for the initial orbit guess | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `dc/op.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| Kundert, *Introduction to RF Simulation and its Application*, designers-guide.org/analysis/rf-sim.pdf | **fetched, verified**: eqs. 22-24 (HB), 34-36 (shooting), autonomous variants, method trade-offs |
| Telichevesky/Kundert/White DAC'95 (matrix-free Krylov shooting) | **paywalled: derived, not source-verified**; concept and motivation verified against rf-sim.pdf §4.1.4 ("Krylov subspace methods have been applied to accelerate both harmonic balance and the shooting methods") |
| Xyce Math Formulation | fetched: this revision has no HB section (noted by fetch) |

**Per-section verification**

- §1 BVP/shooting/HB formulations: verified against rf-sim.pdf.
- §1 monodromy chain + Krylov spectrum argument: derived, not
  source-verified (standard; matches DAC'95 abstract-level description).
- §2/§3 implementation flow: transcribed from `pss.zig` and `hb.zig`
  (including the FD matvec and the $C(t_0)$ Jacobian in HB).
- §4: design notes; GPU PSS/HB is not implemented.

**Our implementation**

- `src/analysis/pss/pss.zig`: shooting Newton (dense FD Jacobian or
  FD-matvec GMRES).
- `src/analysis/pss/hb.zig`: harmonic balance (dense spectral Jacobian).
- `src/analysis/pss/pac.zig`: periodic AC on the PSS orbit.
- Fixtures: `tests/fixtures/pss/`, `tests/fixtures/hb/`.
