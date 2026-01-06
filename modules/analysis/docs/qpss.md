# Quasi-Periodic Steady State (QPSS) — future, not implemented

Steady state under multiple incommensurate tones (mixers, blockers,
intermod).

## 1. Mathematical specification

A circuit driven at incommensurate $f_1, f_2$ (e.g. RF + LO) settles to a
2-fundamental quasiperiodic response (Kundert rf-sim.pdf eq. 25):

$$
x(t) = \sum_{k}\sum_{l} X_{kl}\, e^{j2\pi(k f_1 + l f_2)t},
$$

truncated to $K_i$ harmonics per fundamental →
$K = \prod_i (2K_i + 1)$ coefficients (practical ceiling: 3–4
fundamentals). Two solution families:

**Quasi-periodic HB**: the HB residual
([pss-shooting-harmonic-balance.md](pss-shooting-harmonic-balance.md) §1)
over the 2-D harmonic grid, $\Omega$ now $\mathrm{diag}(j2\pi(kf_1+lf_2))$;
device evals on a 2-D time grid (multidimensional DFT). Direct extension
of `hb.zig`'s machinery with the basis generalized.

**Mixed frequency-time (MFT) / quasi-periodic shooting** (rf-sim §4.1.6):
write the response as a periodically-modulated carrier ($f_1$ carrier,
$f_2$ envelope, rf-sim eq. 27); the waveform is recovered from
$2K_2{+}1$ carrier cycles evenly spaced over the modulation period. The
unknowns are the states at the start of those cycles; the boundary
condition is a **delay/frequency-domain relation between cycle endpoints**
(the sample envelope is band-limited, so endpoint states interpolate
through a DFT matrix), and each Newton residual evaluation integrates
$2K_2{+}1$ *independent* carrier cycles — shooting with a small dense
spectral coupling.

Oscillator variants add the fundamental(s) as unknowns with phase
constraints, as in autonomous HB/shooting.

## 2. Flow (target)

1. Identify fundamentals + harmonic budget per tone.
2. QP-HB path: init from single-tone HB at the dominant tone; Newton on
   the 2-D spectral residual; matrix-free Krylov with block preconditioner
   (per-mix-product $(G_0 + j\omega_{kl}C_0)$).
3. MFT path: PSS at the carrier first, then Newton on the cycle-boundary
   system; each iteration's $2K_2{+}1$ cycle integrations are independent
   (the natural parallel axis).
4. Outputs: spectra at all mix products (intermod, conversion gain,
   blocker desensitization); QPAC/QPnoise linearize about the QPSS orbit
   exactly as PAC/pnoise do about PSS.

## Solvers used (requirements — analysis not implemented)

| Phase | Solver doc | Impl |
|---|---|---|
| QP-HB operator apply (d-dim FFT sandwich of per-sample SpMVs, level-d block-Toeplitz) | [lptv-block-solves.md](../solvers/lptv-block-solves.md) §"Matrix-free application" | requirement — dense LU is infeasible at $nK$; Krylov is a prerequisite, not an optimization |
| QP-HB preconditioner (d-dim block-circulant, per-mix-product sparse factors) | [structured-preconditioners.md](../solvers/structured-preconditioners.md) §"Multi-tone generalization" — **hard requirement** | per-block factors via [klu-pipeline.md](../solvers/klu-pipeline.md) |
| GMRES core | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `converger.zig` (reuse) |
| MFT: monodromy products per carrier cycle, multi-RHS replay, subspace recycling across cycles | [monodromy-krylov.md](../solvers/monodromy-krylov.md) | requirement — the $2K_2{+}1$ independent cycles are the GPU lane axis |

---

**Sources fetched**: Kundert rf-sim.pdf (fetched — eqs. 25–28, quasi-
periodic HB §4.1.3, MFT §4.1.6 verified). MFT boundary-condition detail
beyond the fetched prose: derived, not source-verified (Kundert/White/
Sangiovanni book is paywalled). **Status: future — not implemented**
(builds on `hb.zig` basis generalization or `pss.zig` + Krylov shooting).
