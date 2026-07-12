# Fourier Analysis / THD (.FOUR)

Harmonic decomposition of transient steady state: grid interpolation,
spectrum extraction, THD.

## 1. Mathematical specification

### The estimator

Given a transient waveform $v(t)$ assumed periodic with fundamental
$f_0 = 1/T$ over its final period, the Fourier coefficients

$$
c_k = \frac{1}{T}\int_{t_{\text{end}}-T}^{t_{\text{end}}} v(t)\, e^{-j2\pi k f_0 t}\, dt,
\qquad
\text{mag}_k = 2|c_k|\ (k \ge 1), \quad \text{dc} = c_0,
$$

and total harmonic distortion over harmonics $2..H$:

$$
\mathrm{THD} = \frac{\sqrt{\sum_{k=2}^{H} \text{mag}_k^2}}{\text{mag}_1} \times 100\%.
$$

### Non-uniform grid → uniform grid

Adaptive-step transient output is non-uniformly sampled; the DFT needs a
uniform grid. The last period $[t_{\text{end}}-T,\ t_{\text{end}})$ is
resampled to $N = 2^{\lceil \log_2 M \rceil}$ uniform points by **linear
interpolation** (binary-searched bracketing per target point). Radix-2 FFT
then gives the bins; harmonic $k$ = bin $k$ exactly, because the window is
exactly one fundamental period — **no window function is needed when the
window length is an integer number of periods** (rectangular window nulls
sit on every other harmonic). The error budget is therefore:

- **aliasing** of harmonics above $N/2$ (controlled by points/period —
  default transient gives 200/period, $\ge 100$ harmonics clean);
- **interpolation error** $O(h^2 v'')$ from the linear resample — this,
  not the FFT, sets accuracy on sharp waveforms (ngspice behaves the same
  way; its `fourgridsize` knob exists for exactly this);
- **non-periodicity leakage**: if the transient has not settled, the last
  period is not truly periodic and energy leaks off-bin — the classic
  wrong-THD failure. The convention (spice3/ngspice): analyze the final
  period only, after running several periods (default here: 5).

Phase convention: bin $k$ of the FFT of $A\cos(2\pi k f_0 t + \phi)$ is
$(NA/2)e^{+j\phi}$, so phase = $+\mathrm{atan2}(\Im, \Re)$ — no negation.

Windowing (Hann etc.) is deliberately **not** applied for .FOUR-style
single-period harmonic extraction — windows trade bin-exactness for leakage
robustness and would bias the harmonic magnitudes; they belong to the
spectrum-analyzer use case (`fft`/`spec` commands), not the
harmonic-table one.

## 2. Flow explanation

`modules/analysis/src/post/four.zig`:

**Phases.** (1) Run (or receive) a transient: default window
$5/f_0$ at 200 pts/period — `solve()` drives
`tran.simulate` directly; `analyze()` accepts any recorded `Waveform`.
(2) Extract the final period: find the first sample $\ge t_{\text{end}}-T$;
fewer than 2 samples in the window → `error.InsufficientData` (never a
garbage spectrum). (3) Resample to the next power of two via
binary-search + linear interpolation. (4) In-place radix-2 FFT
(`solvers/fft.zig`). (5) Extract DC (bin 0, no factor of 2), fundamental
(bin 1), harmonics 2–9 (bins 2–9, zeroed if beyond Nyquist), THD over
harmonics 2–9. A pure-cosine unit test pins THD ≈ 0 and a square-wave test
pins the analytic 48.3 % / truncated-9-harmonic value.

`analyzeBuffer()` is the same pipeline for already-uniform single-period
samples (HB/PSS spectra checks use it).

Knobs: `f_fundamental`, `n_harmonics` (table size; THD always uses 2–9),
`tran_opts` override; transient knobs pass through.

## 3. Pseudo-code, CPU sequential

```
four(waveform, f0):
    T = 1/f0; t_end = waveform.t[last]
    window = samples with t >= t_end - T      # final period only
    if len(window) < 2: error InsufficientData
    N = next_pow2(len(window))
    for k in 0..N:                            # uniform resample
        t_k = (t_end - T) + T*k/N
        u[k] = linear_interp(window, t_k)     # binary-searched bracket
    X = fft(u)
    dc   = Re X[0] / N
    mag_k = 2*|X[k]|/N,  phase_k = atan2(Im X[k], Re X[k])   # k = 1..H
    THD  = sqrt(sum_{k=2..9} mag_k^2) / mag_1 * 100
```

## 4. Pseudo-code, GPU parallel

Post-processing — cheap next to the transient that feeds it. Parallel axes
that matter:

- **the transient itself** (see [transient-integration.md](transient-integration.md) §4);
- **many probes / many lanes**: resample + FFT batch trivially
  (one signal per block; batched radix-2 or cuFFT). In ensemble runs
  (Monte-Carlo THD distributions) each lane's final period FFTs
  independently — the reduction is one kernel;
- resampling is a grid-stride map (each output point independent given the
  sorted time array — binary search per thread).

```
kernel four_batched(lanes = probes x trials):
    parallel resample: u[lane][k] = interp(waveform[lane], t_k)
    batched FFT (per-lane)
    parallel extract: mag/phase/THD per lane (tiny reduction)
```

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Transient producer | [klu-pipeline.md](../solvers/klu-pipeline.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) — via the transient stack | `modules/analysis/src/tran/tran.zig` |
| FFT | none (analysis-support kernel, not a linear solver) | `modules/solvers/src/fft.zig` (radix-2, in-place) |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §11.6.4 (.FOUR) | **fetched, verified** — semantics (fundamental + harmonic table on transient output, same engine as the `fourier` command) |
| Windowing/leakage theory (Harris 1978) | **paywalled — derived, not source-verified** (integer-period rectangular-window argument is standard) |

**Per-section verification**

- §1 estimator, resampling, no-window rationale, phase convention:
  verified against `four.zig` source (incl. its unit tests pinning cosine
  THD=0 and square-wave ≈48.3 %).
- §2/§3: direct transcription. §4: prospective.

**Our implementation**

- `modules/analysis/src/post/four.zig` — extraction + THD;
  `modules/solvers/src/fft.zig`.
- Bench fixtures: `benchmark/fixtures/fourier/*`.
