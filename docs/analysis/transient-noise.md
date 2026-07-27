# Transient Noise

Time-domain noise: per-step noise-source synthesis, PSD correctness, and
the correlation with `.noise`.

## 1. Mathematical specification

### Noise-source synthesis

Each device noise generator (from the same `collectNoiseSources` registry
`.noise` uses) becomes a stochastic current source between its nodes. A
white source of one-sided PSD $S_i$ [A²/Hz], sampled once per timestep of
length $h$, must produce a discrete sequence whose power matches the PSD
over the step's Nyquist band $B = 1/(2h)$:

$$
i_n \sim \mathcal N(0, \sigma^2), \qquad
\sigma^2 = S_i \cdot B = \frac{S_i}{2h},
$$

for thermal noise $S_i = 4kTg$:

$$
\sigma = \sqrt{\,4kT\,g \cdot \tfrac{1}{2h}\,}.
$$

Held constant over the step (zero-order hold), the resulting process has
spectrum $S_i\,\mathrm{sinc}^2(f h)$ — flat to within 1 dB below
$\approx 0.2/h$, rolling off toward Nyquist. The synthesis is therefore
band-limited white noise with bandwidth set by the step size: **the
timestep is the noise bandwidth knob.** Under *adaptive* $h$ the
per-step variance rescales as $1/h$, keeping the PSD level constant across
step-size changes (the discrete increments mimic Brownian-motion scaling
$\Delta W \sim \sqrt h$: $i_n \cdot h \sim \sqrt{S_i h/2}$).

Flicker ($1/f$) sources need correlated synthesis (sum-of-Ornstein–
Uhlenbeck / filtered-white cascades) — *not implemented*; thermal only.

### Integration in the presence of noise

The sampled currents enter the residual like any source:

$$
\frac{q(x_m) - q(x_{m-1})}{h} + i(x_m) + u(t_m) + \textstyle\sum_s i_{n,s}\, (e_{p_s} - e_{n_s}) = 0,
$$

with **backward Euler**, deliberately: BE's strong damping at the Nyquist
edge is the correct companion for ZOH noise (trapezoidal would ring the
step-to-step noise increments), and this is an SDE in disguise — BE here is
the drift-implicit Euler–Maruyama scheme, whose weak order (order of
statistics) is 1 regardless of the deterministic integrator's order, so a
higher-order method buys nothing statistically. **No LTE control**: the
"local error" is dominated by the injected noise by construction, so LTE
rejection would fight the physics; the step shrinks only on Newton failure
and grows gently ($\times 1.5$, capped) otherwise.

### Correlation with `.noise`

Validation identity: for an LTI (or small-signal-valid) circuit, the
time-domain output variance must reproduce the frequency-domain integral,

$$
\operatorname{Var}[v_o] \;=\; \int_0^{B_{\text{eff}}} S_{v,o}(f)\, df
\;=\; \big(v_{n,\text{tot}}^{\text{(.noise)}}\big)^2,
$$

with $B_{\text{eff}}$ the circuit bandwidth (provided the sampling band
$1/(2h)$ covers it). Concretely: an RC-filtered resistor must show
$\operatorname{Var}[v_C] = kT/C$ from either analysis. Ensemble averaging
over seeds tightens the estimate as $1/\sqrt{N_{\text{seeds}}}$; a single
long run tightens as $1/\sqrt{T_{\text{sim}} \cdot B_{\text{eff}}}$
(effective independent samples). Where the two analyses *legitimately*
diverge: large-signal operation — transient noise captures
noise-nonlinearity interaction (threshold jitter, oscillator phase
diffusion) that LTI `.noise` cannot; that regime is the analysis's reason
to exist.

## 2. Flow explanation

`modules/analysis/src/tran/tran_noise.zig`:

1. **Sources — the in-device convention.** The device model owns the
   noise physics; the analysis only converts PSD → sample sequence. The
   same contract path as `.noise`
   ([ac-small-signal-noise.md](ac-small-signal-noise.md) §2, device-side
   "Noise model (in-device)" sections in
   [docs/devices/](../devices/README.md)): devices declare `noise_gens`
   (`kind ∈ {thermal, shot, flicker}`), `collectNoiseSources` reads each
   generator's conductance off the AD Jacobian at the device's own bias —
   the device says $4kTg$ / $2qI$ / $K_F I^{A_F}/f$; the synthesis step
   only maps that PSD to $\sigma = \sqrt{S \cdot B}$. **Gap vs the
   convention, flagged**: today only thermal generators reach this
   analysis (the collector skips shot/flicker pending the device-side
   `noisePsd` hook — contract surface landed 2026-07-12, device impls pending), and §1's flicker synthesis (correlated OU cascade) is
   unimplemented — both halves of the gap live behind the same device
   hook, not in this analysis.
2. RNG: private Xorshift64 + Box–Muller, seed in `Options`
   (default `0xDEAD_BEEF_CAFE_1234`) — deterministic and reproducible per
   seed, same policy as [ensemble-sweeps.md](ensemble-sweeps.md).
3. March: per step compute $B = 1/(2h)$, draw one Gaussian per source with
   the $\sigma$ above, Newton-solve the BE companion with the noise
   currents added to the residual (`NoiseHook`: matrix $G + C/h$, ITL4
   budget). Newton failure → halve $h$ (down to `dt_min` → truncated
   result flagged `completed=false`); success → exact-$q$ refresh
   ($q$ re-evaluated at the converged point since the planes are one
   iterate stale), $h \leftarrow \min(1.5h, h_{\max})$.
4. Flat point-major recorder with doubling fallback; rows are already
   Result-layout.

Knobs: transient knobs minus LTE (`dt_init/dt_min/dt_max/max_steps`),
`temp_k`, `seed`; tolerance bundle for the per-step Newton.

## 3. Pseudo-code, CPU sequential

```
tran_noise(ckt, x, t_stop, seed):
    srcs = collect_noise_sources(x_op)
    rng = xorshift64(seed); q_prev = q(x); h = dt_init
    while t < t_stop:
        B = 1/(2h)
        for s in srcs: i_n[s] = sqrt(4*k*T*g_s*B) * randn(rng)
        nr = newton(x_try, t+h, hook = { rhs += (q - q_prev)/h + noise stamps,
                                          A = G + C/h }, itl4)
        if !nr.converged:
            h /= 2; if h < dt_min: return truncated
            continue
        q_prev = q(x_try)                     # exact q at converged point
        x = x_try; t += h; record(t, x)
        h = min(1.5h, dt_max)
```

## 4. Pseudo-code, GPU parallel

Time marching stays sequential (see
[transient-integration.md](transient-integration.md) §4); the axes:

- **within a step**: batched SoA device eval + JFNK exactly as transient;
  the noise stamp is one extra grid-stride scatter (a few entries per
  source), and the per-source draws are a parallel map with a
  counter-based RNG (`hash(seed, step, source)` — scheduling-independent
  reproducibility, replacing the sequential Xorshift stream);
- **ensemble of seeds** — the statistically meaningful axis: variance/PSD
  estimates need many runs, and $L$ seeds are $L$ fully independent
  transients = $L$ megakernel lanes. This is where GPU transient noise
  beats CPU by wall-clock, not per-run latency;
- PSD estimation epilogue (Welch over lanes) is batched FFT.

```
host: launch L lanes (seeds) of on-device tran-noise march
kernel lane l:
    while t < t_stop:                          # sequential per lane
        parallel draws: i_n[s] = sigma_s(h) * randn(hash(seed_l, step, s))
        newton/jfnk on-device with noise stamps
        accept/halve as CPU
host: cross-lane statistics / batched Welch PSD
```

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Per-step Newton on $G + C/h$ | [klu-pipeline.md](../solvers/klu-pipeline.md) (refactor per $h$ change), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `modules/solvers/src/direct.zig` via `converger.run` + `NoiseHook` |
| Refactor bypass when $h$ repeats (constant-step stretches) | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) | `matrix_sig` (applicable; not currently passed by this hook) |
| GPU per-step JFNK | [gpu-sparse-lu.md](../solvers/gpu-sparse-lu.md) §4 alternatives | `modules/devices/src/kernel.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §11.3.11 (transient noise, low-frequency) | located in fetched manual TOC; body not transcribed — semantics cross-checked at TOC level |
| SDE/Euler–Maruyama weak-order argument; ZOH $\mathrm{sinc}^2$ spectrum | **derived, not source-verified** (standard stochastic numerics) |

**Per-section verification**

- §1 $\sigma = \sqrt{4kTgB}$, $B = 1/(2h)$, BE, no-LTE rationale: verified
  against `tran_noise.zig` source (rationale documented in-source).
- §1 flicker gap + `.noise` correlation identity: derived; the
  LTI-reduction check is the natural fixture (see below).
- §2/§3: direct transcription. §4: prospective (counter-based RNG is a
  design note; current impl is a sequential stream).

**Our implementation**

- `modules/analysis/src/tran/tran_noise.zig`.
- Bench fixtures: `benchmark/fixtures/noise/*` (frequency-domain
  cross-check targets); no dedicated tran-noise fixture yet — the
  $kT/C$ variance check is the one to add.
