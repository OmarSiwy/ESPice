# Periodic Steady State: Shooting Newton + Harmonic Balance

Krylov matrix-free shooting (SpectreRF core) and the harmonic balance
formulation.

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

Define the **state transition function** $\phi_T(v_0, t_0)$ — the solution
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

($\alpha,\beta$ the integration coefficients — for BE,
$\alpha = \beta = 1/h_s$), i.e. one extra back-substitution per timestep per
initial-condition direction, using the *already factored* companion matrices
of the inner transient.

**Matrix-free Krylov shooting** *(Telichevesky/Kundert/White DAC'95 —
paywalled; derivation marked derived, concept verified against rf-sim.pdf)*:
never form $M$. Solve $ (M - I)\,\Delta v_0 = -\Phi $ with GMRES; each
Krylov application $M \cdot w$ is one pass of the recurrence

$$
w_{s+1} = \big(G_{s+1} + \alpha C_{s+1}\big)^{-1} \beta\, C_s\, w_s,
$$

which costs $S$ back-substitutions on saved factorizations — no new
factorizations, no $n \times n$ dense storage. GMRES converges in few
iterations because $M$'s spectrum clusters near 0 for stable circuits (fast
modes decay within a period), so $M - I$ has clustered eigenvalues near
$-1$. This is the SpectreRF PSS core; cost per shooting-Newton iteration is
$O(S \cdot \text{nnz})$ instead of $O(S \cdot n \cdot \text{nnz})$ for the
dense/FD Jacobian.

Convergence test: $\|\Phi(v_0)\|_\infty < \texttt{shooting\_tol}$, with the
inner transient's Newton solves governed by the usual tolerance bundle.

For **autonomous circuits** (oscillators) the period $T$ joins the unknowns
and a phase-anchoring equation (e.g. $\dot v_j(0) = 0$ or $v_j(0) = V$)
closes the system (rf-sim §4.1.5).

### Harmonic balance

Assume $v(t)$, $u(t)$ T-periodic and expand the DAE in a Fourier series
(rf-sim eqs. 23–24):

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
up front — one scratch arena, zero growth), computes
$\Phi = x(T) - x_0$, tests $\|\Phi\|_\infty$, then builds $J_\Phi$
**column-by-column via finite differences over the flow map** (one full
period integration per column — this stays FD by construction; the analytic
planes give the Jacobian of $F$, not of the period map) and takes a dense-LU
Newton step. A failed inner integration inside a perturbed column falls back
to an identity column rather than aborting. After convergence one final
period is integrated to record the waveform. The FD/dense Jacobian is the
current implementation's scaling ceiling ($n{+}1$ period integrations per
shooting iteration, $O(n^2)$ storage); the Krylov matrix-free path in §1 is
the designed upgrade (RESEARCH.md checklist item 3).

**HB** (`src/analysis/pss/hb.zig`): real trigonometric basis
$[\,dc, \cos_1, \sin_1, \dots, \cos_K, \sin_K\,]$, $2K{+}1$ time samples per
period. Per Newton iteration: IDFT $\hat V \to$ samples; one `ckt.eval` per
sample fills the residual **and** the analytic $G$ plane (sample 0 also
captures the $C$ plane, a DC-sample approximation of $C(t)$); cosine source
excitation added in time domain; DFT residuals to $\hat F$; charge terms
$j\omega_h C \hat V_h$ added spectrally; dense HB Jacobian assembled from
the harmonic content of $G(t)$ (DC + first-order cos/sin cross-blocks kept;
higher-order intermodulation blocks truncated) plus the $\pm\omega_h C$
skew blocks; dense LU, full Newton update. Non-convergence surfaces as a
warning with the residual (the spectra are still extracted).

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

# matrix-free Krylov upgrade (target, not yet implemented):
pss_krylov(ckt, x_dc, T):
    for iter in ...:
        integrate one period, SAVING each step's factored (G + alpha*C) and C_s
        phi = x(T) - x0; if converged: break
        GMRES solve (M - I) dx0 = -phi where
            M*w: w_{s+1} = solve_saved(s+1, beta*C_s*w_s)  for s = 0..S-1
        x0 += dx0

hb(ckt, f0, K):
    X = 0                                        # [dc,cos,sin]*K per node
    for iter in 0..max_iter:
        x_td = IDFT(X)                           # 2K+1 samples per node
        for each sample k: eval(x_td[:,k])       # fills F and analytic G
                            (k==0: capture C)
        f_td += source excitation
        F = DFT(f_td) + spectral charge terms (w_h C X_h)
        if max|F| < hb_tol: return X
        J = spectral(G(t)) blocks + (+-w_h C) skew blocks
        solve dense J dX = -F;  X += dX
```

## 4. Pseudo-code, GPU parallel

**Shooting.** The inner time march is sequential (see transient doc), but
PSS adds two wide parallel axes on top:

- **Shooting sensitivities / multiple RHS**: the FD Jacobian's $n$ columns
  are independent period integrations from perturbed initial states — ideal
  batch parallelism (each column is one lane/launch). In the Krylov
  version, the per-step propagation $w_{s+1} = A_{s+1}^{-1}\beta C_s w_s$
  applies to *all* Krylov vectors (and, for pnoise later, all adjoint
  vectors) as a blocked multiple-RHS triangular solve.
- **Within each timestep**: batched SoA device eval + JFNK exactly as in
  the transient megakernel; the shooting outer loop is host-side.

```
host pss_gpu:
    for shooting iter:                          # sequential
        launch tran_chunk(s) for the period     # sequential march on-device
        phi readback (n floats)
        # Jacobian: batch the n (or m Krylov) perturbed integrations
        launch batched_period_integrations(X0 + eps*E)   # lanes = columns
        (or: GMRES where M*w is replayed back-substitutions on stored
         per-step factors — sequential in s, parallel over n per step,
         parallel over Krylov block width)
        dense/least-squares solve on host (n small) or cuSolver
```

**HB.** Frequency-domain structure is the GPU-friendly one:

- device evaluation parallelizes over **samples × instances** (the $2K{+}1$
  sample evals are independent — batch them as one big SoA eval with a
  sample index axis);
- DFT/IDFT are batched GEMMs (or FFTs for large $K$);
- the HB Jacobian solve parallelizes as a block system — matrix-free
  GMRES with the block-Toeplitz operator applied via
  FFT · diag(G(t)) · IFFT per Krylov vector, block-diagonal
  $(G_0 + j\omega_h C)$ preconditioner per harmonic (standard Krylov-HB;
  fits the repo's JFNK/GMRES kernel pattern directly).

```
kernel hb_gpu(iteration):
    parallel IDFT: X -> x_td            # batched GEMM, nodes x samples
    parallel eval: for (sample, batch, instance) grid-stride:
        stamp f_td[:, sample], G_td[:, sample]      # SoA, atomics per sample
    parallel DFT: f_td -> F_hat; add spectral charge terms
    GMRES on J_hb * dX = -F_hat:
        J*v = DFT( G(t) .* IDFT(v) ) + Omega*C*v    # matrix-free, all parallel
        precond: per-harmonic block solves           # independent -> parallel
    thread0/host: convergence check
```

Sequential remains: the outer Newton iterations (both methods) and the time
march inside shooting.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Inner fixed-step trap Newton (per timestep of every period integration) | [klu-pipeline.md](../solvers/klu-pipeline.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/solvers/direct.zig` via `converger.run` + `PeriodHook` |
| Shooting Jacobian solve (dense $J_\Phi$) | none (dense path) | `src/solvers/dense_lu.zig factorizeSolveNeg` |
| Krylov-shooting upgrade: monodromy products via sensitivity replay on saved per-step factors, GMRES on $(\Phi-I)$, subspace recycling | [monodromy-krylov.md](../solvers/monodromy-krylov.md) — full spec | target — reuses `converger.jfnk` GMRES core + `direct.zig solve/solveT` |
| HB spectral Jacobian solve (dense) | none (dense path); Krylov-HB upgrade = matrix-free block-Toeplitz apply per [lptv-block-solves.md](../solvers/lptv-block-solves.md) + block-circulant preconditioner per [structured-preconditioners.md](../solvers/structured-preconditioners.md) | `dense_lu.zig`; `src/solvers/fft.zig` for the operator apply |
| Upstream OP for the initial orbit guess | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `dc/op.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| Kundert, *Introduction to RF Simulation and its Application*, designers-guide.org/analysis/rf-sim.pdf | **fetched, verified** — eqs. 22–24 (HB), 34–36 (shooting), autonomous variants, method trade-offs |
| Telichevesky/Kundert/White DAC'95 (matrix-free Krylov shooting) | **paywalled — derived, not source-verified**; concept and motivation verified against rf-sim.pdf §4.1.4 ("Krylov subspace methods have been applied to accelerate both harmonic balance and the shooting methods") |
| Xyce Math Formulation | fetched — this revision has no HB section (noted by fetch) |

**Per-section verification**

- §1 BVP/shooting/HB formulations: verified against rf-sim.pdf.
- §1 monodromy chain + Krylov spectrum argument: derived, not
  source-verified (standard; matches DAC'95 abstract-level description).
- §2/§3 implementation flow: direct transcription of repo source (including
  the FD-Jacobian ceiling and the DC-sample $C$ approximation in HB —
  honest deltas vs the ideal spec).
- §4: repo kernel patterns extrapolated; GPU PSS/HB not yet implemented.

**Our implementation**

- `src/analysis/pss/pss.zig` — shooting Newton (FD dense Jacobian).
- `src/analysis/pss/hb.zig` — harmonic balance (dense spectral
  Jacobian).
- `src/analysis/pss/pac.zig` — periodic AC on the PSS orbit.
- Bench fixtures: `benchmark/fixtures/pss/{diode_rect_driven,rc_driven,rlc_driven}`,
  `benchmark/fixtures/hb/{diode_clipper,rc_single_tone,tline_guard}`.
