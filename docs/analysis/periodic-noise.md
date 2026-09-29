# Periodic Noise (PNoise)

Noise analysis about a periodic operating point: LPTV transfer functions,
sideband folding, cyclostationary sources.

## 1. Mathematical specification

### Linear periodically-varying (LPTV) small-signal system

Let $v_L(t)$ be the T-periodic steady state (from PSS) with
$f_L = 1/T$. Linearizing the circuit DAE about $v_L(t)$ gives the LPTV
system for a perturbation $v_s$:

$$
G(t)\,v_s(t) + \frac{d}{dt}\big(C(t)\,v_s(t)\big) = u_s(t),
\qquad
G(t) = \frac{\partial i}{\partial v}\Big|_{v_L(t)},\quad
C(t) = \frac{\partial q}{\partial v}\Big|_{v_L(t)},
$$

with $G, C$ T-periodic. The defining property of an LPTV system (Kundert
rf-sim.pdf eqs. 48-49): a small complex exponential input
$u_s(t) = U_s e^{j2\pi f_s t}$ produces output at **all sidebands of the
harmonics**,

$$
v_s(t) = \sum_{k=-\infty}^{\infty} V_{sk}\, e^{j2\pi (f_s + k f_L) t},
$$

so there is a doubly-indexed family of transfer functions
$H_k(f_s) = V_{sk}/U_s$: input at $f_s$, output at $f_s + k f_L$ -
each $k$ is a different frequency translation (mixing).

### Noise folding

A noise source with PSD $S_u(f)$ injected into an LPTV network contributes
to the output at analysis frequency $f$ from **every sideband**
$f_m = f + m f_L$: noise originally at $f_m$ is translated down/up to $f$
by the $-m$-th harmonic of the periodic operating point. For uncorrelated
stationary sources $s$,

$$
S_{v,o}(f) \;=\; \sum_s \sum_{m=-\infty}^{\infty}
\big| H_{s,m}(f + m f_L) \big|^2 \, S_s(f + m f_L),
$$

where $H_{s,m}$ is the transfer from source $s$ at the sideband to the
output at $f$. Truncation to $|m| \le M$ sidebands is the pnoise
`maxsideband` parameter. Cyclostationarity of device noise (a MOS channel's
thermal PSD $4kT\gamma g_m(t)$ varies over the cycle because the bias does)
enters through the periodic modulation of the source conductance; modulated
noise develops correlations *between* sidebands, and a full treatment
carries the correlation matrix of sideband pairs (Kundert rf-sim.pdf §4.2
and the cyclostationary-noise paper: sampled/modulated noise is
characterized by harmonics of its time-varying autocorrelation).

### Adjoint LPTV computation (the SpectreRF way)

*(derived, not source-verified: Telichevesky et al. "Efficient AC and
noise analysis of two-tone RF circuits" and Okumura et al. are paywalled)*

As in LTI noise, one adjoint solve per output/frequency serves all sources:
run the **adjoint (time-reversed) LPTV system** backward over the period
with terminal condition $e_o$ at output frequency $f$; the resulting
periodic adjoint waveform $y(t; f)$ gives every $H_{s,m}$ simultaneously by
Fourier-analyzing $y$ at each source's location: solve count
$N_{\text{pts}}$ instead of $N_{\text{pts}} \times N_{\text{src}} \times (2M{+}1)$.
On the shooting/monodromy machinery this is the transposed recurrence of
the sensitivity chain, i.e. back-substitutions on the *transposed* saved
step factors.

### Frozen-time approximation (retired)

An earlier version averaged frozen-time LTI snapshots; the conversion-matrix
sweep of §2 replaced it. Kept for the record:

Replace the true LPTV solve by an average over frozen-time LTI snapshots:
for each PSS sample $t_k$, treat $(G_k, C_k) = (G(t_k), C(t_k))$ as an LTI
network, compute $H_k(f_m) = e_o^{\mathsf T}(G_k + j2\pi f_m C_k)^{-1}
(e_p - e_n)$, and average power over the period:

$$
S_{v,o}(f) \;\approx\; \sum_s \sum_{m=-M}^{M}
\Big( \frac{1}{N}\sum_{k=0}^{N-1} |H_{s,k}(f_m)|^2 \Big)\, S_s .
$$

This captures the periodic modulation of the transfer magnitude (the
dominant pnoise effect for switched networks whose modulation is slow
compared to the signal path bandwidth) but not inter-sideband correlation
or true frequency translation dynamics; for an LTI circuit it reduces
exactly to standard noise analysis, flat and sideband-count-independent.
Negative sidebands fold via conjugate symmetry ($|H(f)| = |H(-f)|$ for real
networks).

## 2. Flow explanation

`src/analysis/pss/pnoise.zig` splits into an orbit provider and
`orbitSweep`, which takes any periodic orbit (`pac.Orbit`: N + 1 rows
[t, x(0..n)], N a power of two):

- `.pnoise` gets the orbit from the shooting PSS (`pac.orbit`, which is
  `pss.solve` recording every unknown), N = `samplesFor(pss_n_samples,
  2M + 1)`.
- `.hbnoise` (`pss/hb_lptv.zig`) gets it from harmonic balance:
  `hb.solveSpectrum` keeps every unknown's spectrum, and `hb.orbit`
  synthesizes it on N = `samplesFor(max(64, 2(2K + 1)), 2M + 1)` points,
  since HB's own 2(2K + 1)-point grid is not a power of two.

Everything after the orbit is shared:

1. `pac.linearize(ckt, orb, .noise)` samples G(t_k) and C(t_k) (and keeps
   the orbit for the `acDyn` entries) and FFTs each pattern slot.
2. `collectNoiseSources` at every sample gives each generator's white and
   flicker density; their square roots, sign(D)·sqrt(|D|) as in VACASK
   (`lib/osdiinstance.cpp:1684-1708`) so a negative density cannot become
   NaN, are FFT'd into the amplitude spectra A_k.
3. `pac.sweep(true, ...)` solves the transposed conversion matrix once per
   output frequency, driven by +1 at `out_node` and -1 at `out_neg` (the
   `v(a,b)` form); that gives H_m, every node's transfer from sideband m.
4. Folding: S(f) = Σ_s Σ_j S_n(f + j f0) |Σ_m H_m A_{m−j}|², the 1/f shape
   evaluated at the unfolded sideband.

For an LTI circuit, G, C and every source are constant, so their spectra
are exact zeros off bin 0 (a radix-2 FFT of a constant produces exact
zeros), H_m = 0 for m ≠ 0, and the fold collapses to |H_0|² S(f): no
sideband adds noise, whatever M is and whichever provider found the orbit.
That is `issues.md` C5, checked on both paths by `pnoise/lti_rc_sidebands_*`
and `hbnoise/lti_rc*` (analytic 4kTR/(1+(2πfRC)²) under a 10 V sine).

Measured agreement between the providers on a nonlinear circuit (a diode
mixer, LO 1 kHz, K = 16, M = 3, with flicker and one sideband exactly at
DC for f = 1 kHz; `src/tests/analyses.zig`): the densities differ by at
most 2.2e-4 relative over 10 Hz to 10 kHz, which is the shooting orbit's
64-step trapezoid error. The test holds them to 1e-3.

Divergences:

- `v(a,b)` outputs are differential on both `.pnoise` and `.hbnoise`
  (`pnoise/differential_rc`, `hbnoise/differential_rc`). Before this
  `.pnoise` read `v(a)` and silently dropped `b`.
- The input source (`Vsrc`) is checked but not used: there is no
  input-referred column. VACASK and HSPICE report both.
- No per-source contributions (VACASK G5).
- `.hbnoise` sidebands M default to the HB harmonic count K. HSPICE's
  `.HBNOISE` folds over the `.HB` harmonics as well; its
  `[n1, ..., nk, +/-1]` output-tone selector is not accepted, the output
  is always the baseband sideband.

Card syntax:

```
.pnoise   v(out[,ref]) Vsrc sweep f0 [M]
.hbnoise  v(out[,ref]) [Vsrc] sweep [f0 [K [M]]]
.ptdnoise v(out[,ref]) TIME=t [TDELTA=dt] sweep [LIST...=]   (HSPICE, with .sn)
```

### Periodic time-dependent noise (`.ptdnoise`)

HSPICE's `.ptdnoise` [CR .PTDNOISE] asks for the noise at one time $t$ of
the period rather than its average. A unit noise $n$ at frequency $f$
enters at $f + i f_0$ with the source amplitude's coefficient $A_i$ and
reaches the output at $f + p f_0$; the output variance at $t$ is the
integral over $f$ of

$$
S_t(f) = \sum_s S_s(f)\,\Big|\sum_p e^{j 2\pi p f_0 t}
\sum_m H^{(p)}_m A_{s,\,m-M+p}\Big|^2,
$$

$H^{(p)}_m$ the adjoint transfer from input sideband $m$ to the output at
$f + p f_0$ (`pnoise.strobed`). That costs $2M+1$ adjoint solves per
point, one per output sideband, where `.pnoise` needs one. The result is
`ptdnoise_density` over noise frequency in a plot named
`Periodic Time-Dependent Noise Analysis (time=<t>)`; averaged over $t$ it
is the power the output receives from $f$ over all sidebands, which is not
`.pnoise`'s density per output frequency, though both integrate to the same
total. `hspice/ptdnoise_diode` checks $2qV_t^2/I(t)$ at two phases of a
memoryless cyclostationary diode to 1e-4. Divergences: a TIME sweep or a
`.meas` name for TIME is refused (one card per time point); TDELTA and the
LIST keywords only shape HSPICE's strobed-jitter measure and listing, and
are checked and unused; `.MEASURE PTDNOISE` is not read.

`.hbnoise` without f0 takes f0 and K from the deck's `.hb` card, as HSPICE
does; `sweep` is `dec|oct|lin N fstart fstop`.

## 3. Pseudo-code, CPU sequential

```
orbitSweep(ckt, orb, out, out_neg, sweep, f0, M):
    lin = linearize(ckt, orb, .noise)                 # FFT of G(t), C(t)
    for k in 0..N:
        srcs[k] = collect_noise_sources(orb.state(k))
        a_white[s][k], a_flicker[s][k] = signed_sqrt(srcs[k][s])
    A_white, A_flicker = fft(a_white), fft(a_flicker)
    for f in sweep:
        H = solve(conversion_matrix(lin, f)^T, e_out - e_out_neg)   # all nodes, all sidebands
        density(f) = sum_s sum_j psd_j(|sum_m H_m[p_s - n_s] A_{m-j}|^2 for white and flicker)
    return sqrt(trapezoid_integral(density))

pnoise  = orbitSweep(pac.orbit(shooting PSS))
hbnoise = orbitSweep(hb.orbit(hb.solveSpectrum))
```

## 4. Parallel execution

Everything runs on the host today. The phase-3 loop nest is a grid of
independent solves, the most parallel analysis in the suite after AC. Not
implemented (design notes):

- (frequency, sideband, sample) triples are independent linear systems on
  identical patterns: batched build and factor/solve, or matrix-free GMRES
  per lane with a batched $G_k v + j\omega C_k v$ apply that keeps the planes
  sparse instead of dense snapshots;
- sources within a lane are already a dot against the one adjoint vector;
- PSS phase 1 is the sequential part; phase 2 sampling parallelizes over
  samples and device batches.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Orbit: shooting PSS or harmonic balance | [pss-shooting-harmonic-balance.md](pss-shooting-harmonic-balance.md) | `pac.orbit`, `hb.solveSpectrum` + `hb.orbit` |
| One transposed conversion-matrix solve per frequency | none (dense stacked-real path) | `pac.sweep(true, ...)` on `src/solver/dense_lu.zig` |
| Sparse adjoint factors (target) | [klu-pipeline.md](../solvers/klu-pipeline.md) (`solveT`) | not implemented; same shape as `freq_solve`'s adjoint `solveBatch` |

---

**Sources fetched**

| Source | Status |
|---|---|
| Kundert rf-sim.pdf (designers-guide.org) | **fetched, verified**: LPTV response eqs. 48-49, sideband/harmonic transfer functions, PAC/PXF adjoint duality, pnoise role (§4.2) |
| designers-guide.org "Noise in mixers, oscillators, samplers & logic" (cyclo-paper.pdf) | located on fetched index (theory page); not fully fetched: cyclostationary correlation statements marked derived |
| Telichevesky et al. adjoint periodic noise | **paywalled: derived, not source-verified** |

**Per-section verification**

- §1 LPTV/sideband structure: verified against rf-sim.pdf.
- §1 adjoint LPTV + cyclostationary correlation: derived, not
  source-verified.
- §1 frozen-time approximation + LTI-reduction property: verified against
  `pnoise.zig` (the reduction claim is documented and exercised by the
  resistive fixture).
- §2/§3: transcribed from `pnoise.zig`. §4: design notes.

**Our implementation**

- `src/analysis/pss/pnoise.zig`: `sweep` (shooting orbit) and `orbitSweep`.
- `src/analysis/pss/hb_lptv.zig`: `.hbnoise`, `.hbac`, `.hbxf` on the HB orbit.
- `src/analysis/pss/pss.zig`: full shooting-Newton PSS.
- `src/analysis/ac/noise.zig`: the LTI limit it must reduce to.
- Fixtures: `tests/fixtures/pnoise/`, `tests/fixtures/hbnoise/`,
  `tests/fixtures/noise/` (LTI reduction).
