# Quasi-Periodic Steady State (QPSS)

Steady state under multiple incommensurate tones (mixers, blockers,
intermod).

`src/analysis/pss/qpss.zig` implements two-tone harmonic balance with a
2-D DFT operator and matrix-free GMRES. Its preconditioner approximates
the harmonic grid using the dominant tone; full multidimensional
preconditioning, MFT shooting, autonomous variants, QPAC/QPnoise, and a
GPU DFT-sandwich kernel remain targets.

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

## 2. Flow and extensions

1. Identify fundamentals + harmonic budget per tone.
2. Implemented QP-HB path: initialize the spectral coefficients to zero, then
   Newton on the 2-D spectral residual with matrix-free GMRES and a
   simplified dominant-tone preconditioner.
3. Target MFT path: PSS at the carrier first, then Newton on the cycle-boundary
   system; each iteration's $2K_2{+}1$ cycle integrations are independent
   (the natural parallel axis).
4. Output spectra at the retained mix products. Future QPAC/QPnoise
   analyses would linearize about the QPSS orbit as PAC/pnoise do about PSS.

## Solvers used and extensions

| Phase | Solver doc | Impl |
|---|---|---|
| QP-HB operator apply (2-D DFT sandwich) | [lptv-block-solves.md](../solvers/lptv-block-solves.md) §"Matrix-free application" | `src/analysis/pss/qpss.zig` |
| QP-HB preconditioner | [structured-preconditioners.md](../solvers/structured-preconditioners.md) §"Multi-tone generalization" | `src/analysis/solvers/preconditioner.zig`; dominant-tone approximation, full per-mix-product factors remain a target |
| GMRES core | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/analysis/solvers/gmres.zig` |
| MFT: monodromy products per carrier cycle, multi-RHS replay, subspace recycling across cycles | [monodromy-krylov.md](../solvers/monodromy-krylov.md) | requirement — the $2K_2{+}1$ independent cycles are the GPU lane axis |

---

**Sources fetched**: Kundert rf-sim.pdf (fetched — eqs. 25–28, quasi-
periodic HB §4.1.3, MFT §4.1.6 verified). MFT boundary-condition detail
beyond the fetched prose: derived, not source-verified (Kundert/White/
Sangiovanni book is paywalled). **Implementation status:** two-tone QP-HB
is present; MFT shooting and the extensions listed above remain targets.
