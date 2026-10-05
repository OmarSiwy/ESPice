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
spectrum $S_i\,\mathrm{sinc}^2(f h)$: flat to within 1 dB below
$\approx 0.2/h$, rolling off toward Nyquist. The synthesis is therefore
band-limited white noise with bandwidth set by the step size: **the
timestep is the noise bandwidth knob.** Under *adaptive* $h$ the
per-step variance rescales as $1/h$, keeping the PSD level constant across
step-size changes (the discrete increments mimic Brownian-motion scaling
$\Delta W \sim \sqrt h$: $i_n \cdot h \sim \sqrt{S_i h/2}$).

### Flicker synthesis

A flicker source $K/f^{e_f}$ is a sum of Ornstein-Uhlenbeck processes
(Lorentzians). Pole $k$ has corner $f_k$, $\tau_k = 1/(2\pi f_k)$ and
variance $v_k$, one-sided PSD $4 v_k \tau_k / (1 + (2\pi f \tau_k)^2)$.
With corners log-spaced by ratio $r$ over $[f_{\min}, f_{\max}]$ and

$$
v_k = K \ln r \,\sin\!\big(\tfrac{\pi (2 - e_f)}{2}\big)\, f_k^{\,1 - e_f},
$$

the sum approximates $K/f^{e_f}$ between the outer corners (the Lorentzian
integrated over $\ln f_c$ is $\tfrac{\pi}{2} / \sin(\pi s/2)$ with
$s = 2 - e_f$). For $e_f = 1$ every pole carries $K \ln r$ and the
variance is exactly $K \ln(f_{\max}/f_{\min})$. Each process advances
exactly over a step of any length,
$y \leftarrow y\,e^{-h/\tau} + \sqrt{v (1 - e^{-2h/\tau})}\,\xi$, and
starts from its stationary law. $f_{\max} = 1/(2 h_{\max})$, the white
band; $f_{\min}$ defaults to $1/t_{\text{stop}}$ (HSPICE `FMIN`). Three
corners per decade keep the ripple near 0.1 dB; the band edges roll off
over about a decade, which shifts a filtered variance by a few percent
(3.4 % in `jfet_flicker`'s 10 MHz pole). $e_f$ outside $(0, 2)$ has no
finite sum, and such a source keeps its white part only.

### Integration in the presence of noise

The sampled currents enter the residual like any source:

$$
\frac{q(x_m) - q(x_{m-1})}{h} + i(x_m) + u(t_m) + \textstyle\sum_s i_{n,s}\, (e_{p_s} - e_{n_s}) = 0,
$$

with **backward Euler**, deliberately: BE's strong damping at the Nyquist
edge is the correct companion for ZOH noise (trapezoidal would ring the
step-to-step noise increments), and this is an SDE in disguise: BE here is
the drift-implicit Euler-Maruyama scheme, whose weak order (order of
statistics) is 1 regardless of the deterministic integrator's order, so a
higher-order method buys nothing statistically. **No LTE control**: the
"local error" is dominated by the injected noise by construction, so LTE
rejection would fight the physics; the step shrinks only on Newton failure
and grows gently ($\times 1.5$, capped) otherwise.

### Covariance propagation (METHOD=SDE)

HSPICE's `METHOD=SDE` [RF Ch.9] publishes the variance of the noise part
of the output instead of a sample of it. ESPice propagates the covariance
of exactly the sampled scheme above along the noiseless march. With
$A = G + C/h$ and $P = C/h$ at the end of the step, white draws $w$
(covariance $N$, $\sigma^2 = S/(2h)$ per source), flicker poles $y$
(variances $V$, decays $D = e^{-h/\tau}$, injected by $J$),

$$
x_k = A^{-1}(P x_{k-1} + J y_k + w_k),
$$

$K = E[x x^T]$ and $K_{xy} = E[x y^T]$ start at zero and advance as

$$
K_k = A^{-1}\big(P K P^T + P K_{xy} D J^T + J D K_{xy}^T P^T + J V J^T + N\big)A^{-T},
\qquad
K_{xy,k} = A^{-1}(P K_{xy} D + J V).
$$

`onoise` is $\sqrt{K_{oo} - 2K_{or} + K_{rr}}$ for `v(o,r)`. The variance is
the ensemble variance of METHOD=MC runs on the same steps, exactly, for the
circuit linearized along the noiseless march. K is dense $n \times n$ with
a dense LU per step, $O(n^3)$ a step (a `ponytail:` in `Covariance`); a
low-rank factor over the sparse LU is the upgrade. `hspice_sde_rc` checks
the RC recursion $\mathrm{Var} \leftarrow a^2\mathrm{Var} + b^2\, 2kTG/h$
to 1e-6 (within 0.1 % of $kT/C(1-e^{-2t/\tau})$ at $h/\tau = 0.0025$), and
`hspice_sde_flicker` the flicker poles' summed variance
$K_F I_D \ln(F_{\max}/F_{\min})$ plus the channel's white part.

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
diverge: large-signal operation: transient noise captures
noise-nonlinearity interaction (threshold jitter, oscillator phase
diffusion) that LTI `.noise` cannot; that regime is the analysis's reason
to exist.

## 2. Flow explanation

`src/analysis/tran/tran_noise.zig`:

1. **Sources: the in-device convention.** The device model owns the noise
   physics; the analysis only converts PSD to a sample sequence. It uses
   the same contract path as `.noise`
   ([ac-small-signal-noise.md](ac-small-signal-noise.md) §2, model sources
   in [models/](../../models/)): devices declare `noise_gens` and
   `noisePsd`, and `collectNoiseSources` returns each generator's white and
   flicker parts at the device's own bias. The synthesis step maps the white
   part to $\sigma = \sqrt{S \cdot B}$ and the flicker part to §1's OU
   poles (`Flicker`, SoA over every pole), whose values add to the same
   injected current. A rejected step's pole advance stands; each process
   stays stationary. `scale` (HSPICE `SCALE`) multiplies every PSD.
2. RNG: private Xorshift64 + Box-Muller, seed in `Options`
   (default `0xDEAD_BEEF_CAFE_1234`) mixed through SplitMix64 so small
   seeds start well spread, deterministic and reproducible per seed, same
   policy as [ensemble-sweeps.md](ensemble-sweeps.md).
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
`seed`, `scale`, `f_min`; the tolerance bundle for the per-step Newton. The
temperature is the circuit's.

Cards: `.trannoise tstep tstop` (ESPice's own), and HSPICE's
`.trannoise out [METHOD=MC|SDE] [SEED=] [SAMPLES=] [TIME=all|t] [FMIN=]
[FMAX=] [SCALE=] [AUTOCORRELATION=]` [CR .TRANNOISE; RF Ch.9] over the
deck's `.tran`, stepped at $h = 1/(2\,\text{FMAX})$ with FMAX defaulting
to 1/TSTEP. SEED is the Monte Carlo index of the first run (default 2)
and index 1 is the noiseless run, per the manual's keyword table; its
`SAMPLES=30` example says the 30 runs begin with the noiseless index 1,
which contradicts the default of 2, and ESPice follows the table
(unconfirmed). SAMPLES=n makes one query per index, SEED to SEED+n-1, each
a plot named `Transient Noise Analysis (sample=<index>)`; the index seeds
the generator. METHOD=SDE adds the `onoise` column (§1, covariance
propagation) and takes one sample only. `TIME=t` makes the march land on
t exactly (for MC too); `TIME=all` is the default. Divergences: an MC run
records every probe rather than an ONOISE trace; SDE's `onoise` is the
output's only and VRMS of other nodes is not offered; the noise sources
are sampled at the operating point for both methods, where HSPICE's SDE
follows the bias along the march [RF Eq. 58]; AUTOCORRELATION is accepted
and unused, since `.jitter` needs none; `.meas` and `.jitter` print once
per run of a SAMPLES set rather than over the ensemble.

`.jitter trannoise|tran TRIG v(x) VAL= [TD=] [RISE=|FALL=|CROSS=]`
[CR .JITTER] runs as a `.meas` over that result: the event times after TD
(rising edges unless the card counts falls or crossings), minus their
least-squares line against edge index, give the time interval error;
`jitter = <rms> pp= <peak to peak> period= <fitted period> edges= <n>` is
printed. HSPICE computes TIE from an autocorrelation of the noisy output
against the noiseless run; the fitted ideal clock needs neither and
reproduces a deterministic modulation exactly (`tran/jitter_sffm`).

## 3. Pseudo-code, CPU sequential

```
tran_noise(ckt, x, t_stop, seed):
    srcs = collect_noise_sources(x_op)          # white and flicker per generator
    poles = flicker_poles(srcs, f_min, 1/(2 dt_max))
    rng = xorshift64(seed); q_prev = q(x); h = dt_init
    while t < t_stop:
        B = 1/(2h)
        for s in srcs: i_n[s] = sqrt(white_s*B) * randn(rng)
        for p in poles: y[p] = y[p] e^(-h/tau_p) + sqrt(v_p (1 - e^(-2h/tau_p))) randn(rng); i_n[src_p] += y[p]
        nr = newton(x_try, t+h, hook = { rhs += (q - q_prev)/h + noise stamps,
                                          A = G + C/h }, itl4)
        if !nr.converged:
            h /= 2; if h < dt_min: return truncated
            continue
        q_prev = q(x_try)                     # exact q at converged point
        x = x_try; t += h; record(t, x)
        h = min(1.5h, dt_max)
```

## 4. Parallel execution

Time marching stays sequential (see
[transient-integration.md](transient-integration.md) §4), and everything
runs on the host; device evaluation inside each Newton iterate can use
`ParEval` threads or the GPU plane hook. Not implemented (design notes):

- within a step, the noise stamp is a few entries per source, and the draws
  become a parallel map with a counter-based RNG
  (`hash(seed, step, source)`), reproducible regardless of scheduling;
- the ensemble of seeds is the statistically meaningful axis: variance and
  PSD estimates need many runs, and $L$ seeds are $L$ independent transients.
  That is where a GPU would win on wall clock, not per-run latency;
- the PSD estimation epilogue (Welch over lanes) is a batched FFT.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Per-step Newton on $G + C/h$ | [klu-pipeline.md](../solvers/klu-pipeline.md) (refactor per $h$ change), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/solver/direct.zig` via `converger.run` + `NoiseHook` |
| Refactor bypass when $h$ repeats (constant-step stretches) | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) | `matrix_sig` (applicable; not currently passed by this hook) |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §11.3.11 (transient noise, low-frequency) | located in fetched manual TOC; body not transcribed: semantics cross-checked at TOC level |
| SDE/Euler-Maruyama weak-order argument; ZOH $\mathrm{sinc}^2$ spectrum | derived, not source-verified (standard stochastic numerics) |

**Per-section verification**

- §1 $\sigma = \sqrt{4kTgB}$, $B = 1/(2h)$, BE, no-LTE rationale: verified
  against `tran_noise.zig` source (rationale documented in-source).
- §1 flicker synthesis: derived; `tran_noise/jfet_flicker` checks the
  $K \ln(f_{\max}/f_{\min})$ variance and its share through a pole.
  `.noise` correlation identity: derived; the LTI-reduction check is the
  natural fixture (see below).
- §2/§3: transcribed from `tran_noise.zig`. §4: design notes (the
  implementation uses one sequential stream).

**Our implementation**

- `src/analysis/tran/tran_noise.zig`.
- Fixtures: `tests/fixtures/tran_noise/` (`rc_equilibrium` checks the
  $kT/C$ variance; `ideal_clamp_*`; `jfet_flicker` the flicker synthesis
  through the HSPICE card; `hspice_samples` a SAMPLES set with its
  noiseless index 1, the variance band sized from the record length;
  `hspice_sde_rc` and `hspice_sde_flicker` METHOD=SDE and TIME=), `tests/fixtures/tran/jitter_sffm` (`.jitter`),
  `tests/fixtures/noise/` for frequency-domain cross-checks.
