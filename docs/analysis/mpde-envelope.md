# MPDE Multirate / Envelope Following

Multitime PDE formulation and transient-envelope methods for the
widely-separated-time-scales ("million cycles") problem.

## 1. Mathematical specification

### The problem

Modulated-carrier circuits have signals
$x(t) = \sum_k \tilde X_k(t)\, e^{j2\pi k f_c t}$ where the envelope
$\tilde X_k(t)$ varies on a scale $T_{\text{mod}} \gg T_c = 1/f_c$
(Kundert rf-sim.pdf eq. 50). Plain transient must resolve every carrier
cycle — $O(T_{\text{mod}}/T_c)$ steps, the "million cycles" cost Spectre
brute-forces without envelope methods.

### The MPDE

*(structure verified against Mei/Roychowdhury TCAD 2005; original
Roychowdhury TCAS 2001 not fetched)*

Introduce independent artificial times: $t_1$ (slow, envelope) and $t_2$
(fast, carrier). Replace the univariate unknown $x(t)$ by the bivariate
$\hat x(t_1, t_2)$ and the circuit DAE
$\frac{d}{dt}q(x) + i(x) + u(t) = 0$ by the **multirate PDE**

$$
\frac{\partial\, q(\hat x)}{\partial t_1}
+ \frac{\partial\, q(\hat x)}{\partial t_2}
+ i(\hat x) + \hat u(t_1, t_2) = 0,
$$

with **periodic boundary conditions along the fast time**
$\hat x(t_1, t_2 + T_c) = \hat x(t_1, t_2)$, and the bi-variate source
$\hat u$ chosen so $\hat u(t, t) = u(t)$. Any solution of the MPDE
recovers a solution of the original DAE **along the diagonal**:

$$
x(t) = \hat x(t, t),
$$

(chain rule: $\frac{d}{dt} q(\hat x(t,t)) = \partial_{t_1} q + \partial_{t_2} q$).
The payoff: a fast/slow signal that needs $10^6$ time points univariately is
a *smooth, low-point-count surface* bivariately — discretize $t_2$ with a
handful of points per carrier cycle and $t_1$ on the envelope scale.

Numerical schemes over the MPDE:

- **Multivariate FDTD**: discretize both axes, solve the whole grid.
- **Envelope following = time-march along $t_1$**: semi-discretize $t_2$
  (collocation, harmonic balance, or shooting per $t_1$-slice), integrate
  the resulting DAE in $t_1$ with standard implicit methods and LTE
  control.
- **Hierarchical shooting**: shooting in $t_2$ nested inside shooting/
  transient in $t_1$.

Stability (the Mei/Roychowdhury result): the two discretizations are not
independent — explicit or A-stable-but-not-L-stable choices along the fast
axis inject spurious eigenmodes into the slow-axis ODE system; backward
differentiation along $t_2$ keeps the discretized-in-$t_2$ system's
eigenvalues in the stable region regardless of the $t_1$ integrator, so
BD-in-fast-time + any stiffly-stable slow integrator is the robust
combination. Oscillators need the warped MPDE (WaMPDE) with a local
frequency unknown $\omega(t_1)$.

### Fourier-envelope (harmonic-balance flavor)

Kundert rf-sim.pdf eqs. 50–54: take the fast axis in the frequency domain
with slowly time-varying Fourier coefficients $\tilde V(t)$:

$$
\frac{d\,\tilde Q(\tilde V(t))}{dt}
+ \Omega\, \tilde Q(\tilde V(t))
+ \tilde I(\tilde V(t)) + \tilde U(t) = 0,
\qquad \Omega = \mathrm{diag}(j2\pi k f_c),
$$

valid when each harmonic's envelope bandwidth $\ll f_c/2$ (else adjacent
sidebands overlap and the representation is not unique). Discretize
$d\tilde Q/dt$ with BE/trap exactly like transient (rf-sim eq. 54 shows the
BE case) and solve each envelope step with Newton, devices evaluated by
IDFT → time domain → DFT per step. This is Sharrit's "circuit envelope".

### Sample-envelope (shooting flavor)

Follow the **sample envelope** $\hat v_n = v(nT_c)$ — the sequence of
states at carrier-period boundaries. It varies on the envelope scale, so
skip cycles: from $\hat v_n$, integrate one full carrier period to get
$\hat v_{n+1}$, estimate the envelope slope
$(\hat v_{n+1} - \hat v_n)/T_c$, and extrapolate across $\Delta n$ periods
(implicitly, for stability — solve
$\hat v_{n+\Delta n} - \hat v_{n+\Delta n - 1} = T_c\,\dot{\hat v}(\hat v_{n+\Delta n})$
with the period-integration as the operator). Envelope-scale LTE control
picks $\Delta n$.

### What this repo implements

`tran/envelope.zig` is a pragmatic sample-envelope variant: outer steps
skip whole carrier periods (adaptive $\Delta n \in$
[`min`,`max`]`_periods_per_step`), a coarse pass advances the state between
envelope samples, and one fine-resolution period per outer step feeds
peak/RMS envelope extraction. The inner solves are **quasi-static**
($A = G$, no charge integration) — valid for envelope tracking of circuits
whose per-cycle dynamics are source-dominated; it is not yet the MPDE/
Fourier-envelope machinery above (RESEARCH.md checklist item 4). Outer
adaptivity is driven by the envelope's relative change per step
(`envelope_reltol`, halve/double on ±threshold) rather than a formal LTE.

## 2. Flow explanation

`src/analysis/tran/envelope.zig simulate()`:

**Phases.** (1) Record the DC point as envelope sample 0. (2) Outer loop:
choose the outer step $\Delta t = \texttt{periods\_per\_step} \cdot T_c$;
if the step spans more than one carrier period, **coarse-advance** to
$t_{\text{target}} - T_c$ with 4× larger inner steps (state transport
only), then run **one fine period** at
`carrier_steps_per_period` resolution, accumulating per-probe peak and
$\sum v^2$ (RMS). (3) Record $(t, \text{peak}, \text{rms})$ per probe.
(4) Adapt: if the max relative peak change exceeds `envelope_reltol`, halve
`periods_per_step` (floor `min_periods_per_step`); if below a quarter of
it, double (cap `max_periods_per_step`).

**Failure handling.** Coarse-advance or inner-step Newton failure → restore
the outer-step snapshot, halve the outer step, retry; the outer loop is
bounded by `max_outer_steps`, and early stop surfaces as a warning with
`t_final` (never a silent truncation of the reported rows — `n_points` is
exact).

**Knobs.** `t_carrier` (the one required physical input),
`carrier_steps_per_period` (fast-axis resolution),
`envelope_reltol` (outer accuracy/step-control), the periods-per-step
bounds, plus the global tolerance bundle for inner Newton solves.

## 3. Pseudo-code, CPU sequential

```
envelope(ckt, x, T_c, t_stop):
    record(t=0, peak=|x|, rms=|x|)
    pps = periods_per_outer_step
    while t < t_stop:
        snapshot x
        t_target = min(t + pps*T_c, t_stop)
        # transport state across skipped cycles (coarse inner steps)
        if t_target - t > T_c:
            for tc in coarse_steps(t .. t_target - T_c, dt = 4*dt_inner):
                if !newton_quasistatic(x, tc): halve pps; restore x; continue outer
        # one fine-resolution carrier period for envelope extraction
        peak = |x|; sumsq = x^2
        for ti in fine_steps(t_target - T_c .. t_target, dt = T_c/steps_per_period):
            if !newton_quasistatic(x, ti): halve pps; restore x; continue outer
            peak = max(peak, |x|); sumsq += x^2
        t = t_target
        record(t, peak, sqrt(sumsq/samples))
        rel = max_probe |peak - prev_peak| / max(|prev_peak|, eps)
        if rel > envelope_reltol:        pps = max(pps/2, min_pps)
        elif rel < envelope_reltol/4:    pps = min(pps*2, max_pps)

# MPDE / Fourier-envelope target (not yet implemented):
fourier_envelope(ckt, f_c, K, t_stop):
    Vt = hb_solve(f_c, K)                      # envelope IC = PSS spectrum
    for each envelope step h (LTE-controlled):
        newton on: (Qt(V) - Qt(V_prev))/h + Omega*Qt(V) + It(V) + Ut = 0
        # device eval per envelope step: IDFT -> i,q samples -> DFT
```

## 4. Pseudo-code, GPU parallel

The MPDE's structure is what makes it the GPU-native answer to the
million-cycles problem:

- **Fast axis parallelism**: each envelope step solves an entire fast-axis
  slice — $2K{+}1$ HB samples (Fourier-envelope) or $S$ collocation points
  (FDTD flavor) — simultaneously. Device evals batch over
  (sample × instance) exactly like the HB kernel; the per-envelope-step
  Newton is a block system solved matrix-free with the batched apply.
- **Envelope axis stays sequential** (it is a time march), but it has
  $10^3$–$10^6\times$ fewer steps than raw transient — the sequential axis
  was compressed by the formulation, not the hardware.
- Repo-current variant: the fine carrier period's inner steps are
  sequential Newton solves (each one runs the batched/JFNK machinery);
  coarse-advance likewise. Independent envelope runs (modulation corners)
  batch as lanes.

```
kernel fourier_envelope_step(V_prev, h):        # one envelope step, on-device
    newton (thread0-steered, as in megakernel):
        parallel IDFT V -> x_td[samples]         # batched GEMM
        parallel eval (sample, batch, instance)  # SoA, atomics per sample
        parallel DFT -> F_hat; F_hat += (Qt - Qt_prev)/h + Omega*Qt
        GMRES: J*v applied via FFT·G(t)·IFFT + (1/h + Omega)·C   # matrix-free
        gates as in converger
host:
    for each envelope step: launch fourier_envelope_step; LTE-adapt h
```

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Inner quasi-static Newton (coarse advance + fine period) | [klu-pipeline.md](../solvers/klu-pipeline.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `converger.run` with `EvalHook` (matrix = $G$) |
| Fourier-envelope upgrade: per-envelope-step block Newton | matrix-free GMRES per [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md); per-harmonic block factors per [klu-pipeline.md](../solvers/klu-pipeline.md) | target — HB machinery (`pss/hb.zig`) + `src/solvers/fft.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| Mei, Roychowdhury et al., "Robust, Stable Time-Domain Methods for Solving MPDEs of Fast/Slow Systems", TCAD 2005 (jaijeet.github.io) | **fetched, verified** — MPDE form w/ slow/fast time scales, periodic BC on fast axis, per-axis discretization, stability findings (equation images not text-extractable; structure and claims verified from text) |
| Kundert rf-sim.pdf §4.3 (Fourier-envelope, eqs. 50–54; sample envelope) | **fetched, verified** |
| Roychowdhury TCAS 2001 (original MPDE) | not fetched (people.eecs.berkeley.edu redirect; TCAD 2005 used instead) — diagonal-recovery identity marked derived-but-standard |

**Per-section verification**

- §1 MPDE equation + periodic BC + diagonal recovery: verified
  (TCAD 2005 structure + standard chain-rule derivation).
- §1 Fourier-envelope: verified against rf-sim.pdf eqs. 50–54.
- §1 sample-envelope extrapolation scheme: derived (rf-sim describes it in
  prose; discretization detail from knowledge).
- §2/§3 repo flow: direct transcription; the quasi-static inner solve and
  peak/RMS extraction are honestly flagged as not-yet-MPDE.
- §4: design extrapolation from the repo HB/JFNK kernel patterns.

**Our implementation**

- `src/analysis/tran/envelope.zig` — sample-envelope variant
  (quasi-static inner, adaptive periods-per-step).
- `src/analysis/pss/hb.zig` — the fast-axis solver a
  Fourier-envelope upgrade would reuse.
- Bench fixtures: none dedicated yet; nearest coverage
  `benchmark/fixtures/pss/*` (fast-axis correctness) and
  `benchmark/fixtures/tran/*` (envelope-vs-raw-transient ground truth).
