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

### Frozen-time approximation (what this repo currently implements)

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

`src/analysis/pss/pnoise.zig`, three phases:

**Phase 1: PSS.** A simplified shooting pass finds the periodic orbit:
integrate one period with frozen-time quasi-static Newton solves at
$N = $ `pss_n_samples` uniform samples, fixed-point iterate
$x_0 \leftarrow x(T)$ up to `pss_shoot_max_iter`, converged when
$\|x(T) - x_0\|_\infty <$ `pss_shoot_tol`. (Fixed point, not shooting Newton:
adequate for mildly nonlinear circuits, immediate for LTI; the full Newton
machinery lives in `pss.zig`.) Each sample is solved under
`analysis("tran")` so time-varying sources follow their waveform
(§4.6.1). The solves are quasi-static with no charge history, so the PSS
period-seam fix of `pss.zig` does not apply here. Non-convergence does not
abort: the last trajectory is used and the result is flagged (`plotname`
carries "PSS not converged").

**Phase 2: LPTV sampling.** One `ckt.eval` per PSS sample fills both
analytic planes; `denseG`/`denseC` capture $G(t_k)$, $C(t_k)$ as dense
$n \times n$ snapshots.

**Noise sources: the in-device convention.** pnoise folds the same
device-owned noise sources the LTI analysis uses (see
[ac-small-signal-noise.md](ac-small-signal-noise.md) §2 and the model
sources in [models/](../../models/)): devices declare `noise_gens` and
`noisePsd`, and this analysis never owns a source table. Cyclostationarity
is, by this convention, the device PSD evaluated along the periodic orbit:
`collectNoiseSources` runs at every sample $x(t_k)$ and yields each
generator's white part, flicker part and exponent at $t_k$, the periodically
modulated $S_s(t)$ of §1. If the generator list changes along the orbit
(different count or nodes), the sweep fails with
`error.NoiseTopologyChanged`.

**Phase 3: swept sideband folding.** For each output frequency (log sweep)
and each sideband $m \in [-M, M]$ ($M = $ `n_sidebands`), for each sample
$k$: build the $2n \times 2n$ stacked-real admittance
$Y_k = G_k + j\,2\pi|f_m| C_k$, factor it, and solve the adjoint
$Y_k^{\mathsf T} y = e_{\text{out}}$ once; every source's transfer is then a
two-element difference of $y$. Accumulate $|H_{s,k}|^2 S_s(f_m, t_k)$, with
$S_s(f) = W_s + K_s/|f|^{e_s}$ ($|f|$ floored at 1e-30 at the DC sideband),
average over $k$, sum over sources and sidebands, and integrate the density
over the band with the trapezoid rule.

Knobs: everything the PSS has, plus `n_sidebands` (folding truncation) and
the sweep triple. The tolerance bundle governs the inner Newton solves.
Known gaps against Spectre pnoise, called out on purpose: frozen-time
averaging instead of true LPTV conversion matrices; no cyclostationary
correlation between sources; dense $n \times n$ snapshots. Multi-probe
B-source expressions are rejected with `UnsupportedBsourceExpression`
(`pnoise/noise_multiplier_*`), and the sideband-transfer formulation that
the `pnoise/lti_rc_sidebands_*` decks need is open (issues.md C5).

## 3. Pseudo-code, CPU sequential

```
pnoise(ckt, x_dc, out, f_range, M, N):
    # phase 1: PSS (fixed-point shooting, frozen-time Newton per sample)
    x0 = x_dc
    repeat up to pss_shoot_max_iter:
        traj[0..N] = integrate period (quasi-static Newton at each t_k, analysis("tran"))
        if max|traj[N] - x0| < tol: break
        x0 = traj[N]
    # phase 2: sample the LPTV planes and the sources along the orbit
    for k in 0..N:
        eval(traj[k], t_k); G[k], C[k] = dense planes
        (white, flicker, ef)[k][s] = collect_noise_sources(traj[k])
    # phase 3: sweep with sideband folding
    for f in log_sweep(f_range):
        S = 0
        for m in -M..M:
            fm = f + m*f_L
            acc[s] = 0
            for k in 0..N:                                   # period average
                A = [G[k]  -w C[k]; w C[k]  G[k]],  w = 2*pi*|fm|
                factor(A); y = solve(A^T, e_out)             # one adjoint per (m, k)
                for s in srcs:
                    acc[s] += |y_p - y_n|^2 * psd(white[k][s], flicker[k][s], ef[k][s], fm)
            S += sum_s acc[s]/N
        density(f) = S; integrate trapezoid
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
| PSS phase (frozen-time Newton per sample) | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md), [klu-pipeline.md](../solvers/klu-pipeline.md) | `converger.run` in `pnoise.runPSS` |
| Per-(frequency, sideband, sample) admittance factor and one adjoint solve | none (dense stacked-real path) | `src/solver/dense_lu.zig` (`buildComplexAdmittance`, `factorize`, `solveFactoredT`) |
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

- `src/analysis/pss/pnoise.zig`: PSS and the frozen-time LPTV sweep.
- `src/analysis/pss/pss.zig`: full shooting-Newton PSS.
- `src/analysis/ac/noise.zig`: the LTI limit it must reduce to.
- Fixtures: `tests/fixtures/pnoise/`, `tests/fixtures/noise/` (LTI reduction).
