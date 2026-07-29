# MPDE Multirate / Envelope Following

Multitime PDE formulation and transient-envelope methods for the
widely-separated-time-scales ("million cycles") problem.

## 1. Mathematical specification

### The problem

Modulated-carrier circuits have signals
$x(t) = \sum_k \tilde X_k(t)\, e^{j2\pi k f_c t}$ where the envelope
$\tilde X_k(t)$ varies on a scale $T_{\text{mod}} \gg T_c = 1/f_c$
(Kundert rf-sim.pdf eq. 50). Plain transient must resolve every carrier
cycle: $O(T_{\text{mod}}/T_c)$ steps, the "million cycles" cost Spectre
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
a *smooth, low-point-count surface* bivariately: discretize $t_2$ with a
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
independent: explicit or A-stable-but-not-L-stable choices along the fast
axis inject spurious eigenmodes into the slow-axis ODE system; backward
differentiation along $t_2$ keeps the discretized-in-$t_2$ system's
eigenvalues in the stable region regardless of the $t_1$ integrator, so
BD-in-fast-time + any stiffly-stable slow integrator is the robust
combination. Oscillators need the warped MPDE (WaMPDE) with a local
frequency unknown $\omega(t_1)$.

### Fourier-envelope (harmonic-balance flavor)

Kundert rf-sim.pdf eqs. 50-54: take the fast axis in the frequency domain
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

Follow the **sample envelope** $\hat v_n = v(nT_c)$: the sequence of
states at carrier-period boundaries. It varies on the envelope scale, so
skip cycles: from $\hat v_n$, integrate one full carrier period to get
$\hat v_{n+1}$, estimate the envelope slope
$(\hat v_{n+1} - \hat v_n)/T_c$, and extrapolate across $\Delta n$ periods
(implicitly, for stability: solve
$\hat v_{n+\Delta n} - \hat v_{n+\Delta n - 1} = T_c\,\dot{\hat v}(\hat v_{n+\Delta n})$
with the period-integration as the operator). Envelope-scale LTE control
picks $\Delta n$.

### What this repo implements

`tran/envelope.zig` is a pragmatic sample-envelope variant: outer steps
skip whole carrier periods (adaptive $\Delta n \in$
[`min`,`max`]`_periods_per_step`), a coarse pass advances the state between
envelope samples, and one fine-resolution period per outer step feeds
peak/RMS envelope extraction. Every inner step, coarse and fine alike, is a
trapezoid companion step ($A = G + \alpha C$, $\alpha = 2/dt$) that carries
the charge history $q_{\text{prev}}, i_{\text{prev}}$ across steps; $dt$ may
change between coarse and fine steps because trapezoid is one-step. It is not
the MPDE/Fourier-envelope machinery above. Outer adaptivity is driven by the
envelope's relative change per step (`envelope_reltol`, halve or double on
the threshold) rather than a formal LTE.

## 2. Flow explanation

`src/analysis/tran/envelope.zig simulate()`:

**Phases.** (1) Record the DC point as envelope sample 0 and seed the
trapezoid state with $q_{\text{prev}} = q(x_{op})$, $i_{\text{prev}} = 0$
(exact at a DC operating point). (2) Outer loop: choose the outer step
$\Delta t = \texttt{periods\_per\_step} \cdot T_c$; if the step spans more
than one carrier period, coarse-advance to $t_{\text{target}} - T_c$ with 4x
larger inner steps, then run one fine period at `carrier_steps_per_period`
resolution, accumulating per-probe peak and the trapezoid-weighted
$\sum v^2$. (3) Record $(t, \text{peak}, \text{rms})$ per probe. (4) Adapt:
if the max relative peak change exceeds `envelope_reltol`, halve
`periods_per_step` (floor `min_periods_per_step`); if below a quarter of it,
double (cap `max_periods_per_step`).

**RMS window.** The window RMS weights the two endpoint samples by one half
(trapezoid rule over the $N$ fine steps):
$\text{rms}^2 = (\tfrac12 v_0^2 + \sum_{k=1}^{N-1} v_k^2 + \tfrac12 v_N^2)/N$.
Counting both endpoints at full weight (65 samples over 64 steps) read a
periodic sine $\sqrt{64/65}$ low. The peak includes the start sample.

**Column names** come from `probeNames`, which prefers the deck's probe
labels, wrapped as `peak(...)` and `rms(...)`. Naming them from node names
alone published a branch-current probe such as `i(vin)` as `v(2)`.

**Failure handling.** Coarse-advance or inner-step Newton failure restores the
outer-step snapshot (state and trapezoid history), halves the outer step and
retries. The outer loop is bounded by `max_outer_steps`; an early stop
surfaces as a warning with `t_final`, and `n_points` is exact, so rows are
never silently truncated.

**Knobs.** `t_carrier` (the one required physical input),
`carrier_steps_per_period` (fast-axis resolution), `envelope_reltol` (outer
accuracy and step control), the periods-per-step bounds, plus the global
tolerance bundle for the inner Newton solves.

**Conformance history** (issues.md F8, recipes in
[conformance-phase2.md](../conformance-phase2.md) group 9). The inner solves
were quasi-static ($A = G$, capacitors open), so `envelope/rc_startup_0p001`
published v(out) = v(in); with the trapezoid history it went from 498x to
0.14x of tolerance (commit `74df137`). The label and RMS fixes (commit
`30b509b`) made `envelope/sine` exact, took `dc_offset` and
`negative_offset` from 0.28x to exact, and `rc_startup_1e-05` from 0.57x to
0.06x.

## 3. Pseudo-code, CPU sequential

```
envelope(ckt, x, T_c, t_stop):
    record(t=0, peak=|x|, rms=|x|)
    q_prev = q(x); i_prev = 0                    # exact at the DC point
    pps = periods_per_outer_step
    while t < t_stop:
        snapshot x, q_prev, i_prev
        t_target = min(t + pps*T_c, t_stop)
        # transport state across skipped cycles (coarse trapezoid steps)
        if t_target - t > T_c:
            for tc in coarse_steps(t .. t_target - T_c, dt = 4*dt_inner):
                if !trap_step(x, tc): restore; halve pps; continue outer
        # one fine-resolution carrier period for envelope extraction
        peak = |x|; sumsq = 0.5*x^2
        for ti in fine_steps(t_target - T_c .. t_target, dt = T_c/steps_per_period):
            if !trap_step(x, ti): restore; halve pps; continue outer
            peak = max(peak, |x|); sumsq += x^2
        sumsq -= 0.5*x^2                         # trapezoid endpoint weight
        t = t_target
        record(t, peak, sqrt(sumsq/steps_per_period))
        rel = max_probe |peak - prev_peak| / max(|prev_peak|, eps)
        if rel > envelope_reltol:        pps = max(pps/2, min_pps)
        elif rel < envelope_reltol/4:    pps = min(pps*2, max_pps)

# MPDE / Fourier-envelope target (not implemented):
fourier_envelope(ckt, f_c, K, t_stop):
    Vt = hb_solve(f_c, K)                      # envelope IC = PSS spectrum
    for each envelope step h (LTE-controlled):
        newton on: (Qt(V) - Qt(V_prev))/h + Omega*Qt(V) + It(V) + Ut = 0
        # device eval per envelope step: IDFT -> i,q samples -> DFT
```

## 4. Parallel execution

Today the envelope loop and its inner Newton solves run on the host; device
evaluation inside each iterate can use `ParEval` threads or the GPU plane
hook. Independent envelope runs (modulation corners) are separate problems.

Not implemented (design note): the MPDE structure suits a GPU. Each
envelope step solves a whole fast-axis slice ($2K{+}1$ HB samples, or $S$
collocation points) at once, with device evaluations batched over
(sample, instance) as in HB and the per-step block Newton solved matrix-free.
The envelope axis stays sequential but has $10^3$ to $10^6$ times fewer steps
than a raw transient.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Inner trapezoid Newton (coarse advance + fine period) | [klu-pipeline.md](../solvers/klu-pipeline.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `converger.run` with the envelope's trapezoid hook (matrix $G + \alpha C$) |
| Fourier-envelope upgrade: per-envelope-step block Newton | matrix-free GMRES per [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md); per-harmonic block factors per [klu-pipeline.md](../solvers/klu-pipeline.md) | target: HB machinery (`pss/hb.zig`) + `src/solver/fft.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| Mei, Roychowdhury et al., "Robust, Stable Time-Domain Methods for Solving MPDEs of Fast/Slow Systems", TCAD 2005 (jaijeet.github.io) | **fetched, verified**: MPDE form w/ slow/fast time scales, periodic BC on fast axis, per-axis discretization, stability findings (equation images not text-extractable; structure and claims verified from text) |
| Kundert rf-sim.pdf §4.3 (Fourier-envelope, eqs. 50-54; sample envelope) | **fetched, verified** |
| Roychowdhury TCAS 2001 (original MPDE) | not fetched (people.eecs.berkeley.edu redirect; TCAD 2005 used instead): diagonal-recovery identity marked derived-but-standard |

**Per-section verification**

- §1 MPDE equation + periodic BC + diagonal recovery: verified
  (TCAD 2005 structure + standard chain-rule derivation).
- §1 Fourier-envelope: verified against rf-sim.pdf eqs. 50-54.
- §1 sample-envelope extrapolation scheme: derived (rf-sim describes it in
  prose; discretization detail from knowledge).
- §2/§3: transcribed from `envelope.zig`; the sample-envelope variant is
  not MPDE.
- §4: design note.

**Our implementation**

- `src/analysis/tran/envelope.zig`: sample-envelope variant (trapezoid
  inner steps, adaptive periods per step).
- `src/analysis/pss/hb.zig`: the fast-axis solver a Fourier-envelope upgrade
  would reuse.
- Fixtures: `tests/fixtures/envelope/`.
