# Analysis Documentation

Per-analysis specs: mathematical formulation, flow, CPU pseudo-code, GPU
pseudo-code, plus a **Solvers used** section cross-referencing
[docs/solvers/](../solvers/README.md). Every file ends with fetched
sources, per-section verification status, and pointers to our
implementation + bench fixtures.

## Index — core analyses

| Doc | Covers | Impl status |
|---|---|---|
| [operating-point-homotopy.md](operating-point-homotopy.md) | Newton + device limiting, dynamic gmin stepping, source stepping, PTC, JFNK rung | implemented (PTC: documented, not implemented) |
| [dc-sweep.md](dc-sweep.md) | Swept-source continuation, warm start, nested sweeps, ladder fallback | implemented |
| [transient-integration.md](transient-integration.md) | BE/trap/Gear-2, TR-BDF2, LTE step control (`CKTterr`), breakpoints, charge conservation | implemented (TR-BDF2: documented, not implemented) |
| [tolerance-system.md](tolerance-system.md) | reltol/abstol/vntol/chgtol semantics, errpreset-style bundles (`Tolerances` profiles) | implemented |
| [ac-small-signal-noise.md](ac-small-signal-noise.md) | AC sweep (stacked-real), adjoint noise analysis | implemented |
| [tf.md](tf.md) | DC transfer function: gain, Rin, Rout via forward + adjoint solve | implemented |
| [sensitivity.md](sensitivity.md) | DC/AC sensitivity: direct vs adjoint vs FD; our FD choice | implemented (DC FD; adjoint + AC: documented targets) |
| [pole-zero.md](pole-zero.md) | Pencil $(G,C)$ eigenproblem, $-G^{-1}C$ reduction, Hessenberg + Francis QR | implemented (poles; zeros/QZ: documented) |
| [s-parameters.md](s-parameters.md) | Port formulation, z0 Thevenin terminations, wave extraction | implemented |
| [stability.md](stability.md) | Return ratio, Middlebrook/Tian probes, gain/phase margins | implemented (single-injection probe; Tian double-injection: documented target) |
| [distortion.md](distortion.md) | Volterra small-signal disto, FD-of-analytic-Jacobian kernel, HD2 | implemented (HD2; HD3/IM: documented) |
| [fourier-thd.md](fourier-thd.md) | .FOUR harmonic extraction: final-period resample, FFT, THD | implemented |
| [ensemble-sweeps.md](ensemble-sweeps.md) | Monte Carlo / corners / temperature: lane batching, seed policy, statistics | implemented |
| [transient-noise.md](transient-noise.md) | Time-domain noise synthesis ($\sigma = \sqrt{4kTg/2h}$), BE rationale, `.noise` correlation | implemented (thermal; flicker: documented gap) |
| [pss-shooting-harmonic-balance.md](pss-shooting-harmonic-balance.md) | Shooting-Newton PSS, matrix-free Krylov shooting, harmonic balance | implemented (FD-Jacobian shooting + dense HB; Krylov shooting: documented target) |
| [periodic-noise.md](periodic-noise.md) | LPTV small-signal, sideband folding, cyclostationary noise, adjoint pnoise | implemented (frozen-time LPTV approximation; full LPTV/adjoint: documented target) |
| [pac.md](pac.md) | Periodic AC: harmonic conversion matrix over the PSS orbit | implemented (settling PSS front end) |
| [mpde-envelope.md](mpde-envelope.md) | MPDE multirate formulation, Fourier-envelope, sample-envelope following | partial (sample-envelope variant, quasi-static inner; MPDE/Fourier-envelope: documented target) |
| [matex-exponential-integrators.md](matex-exponential-integrators.md) | Exponential integrators, Krylov e^{Ah}v, I-/R-MATEX | implemented (explicit linear R-MATEX; I-MATEX/nonlinear/GPU paths remain targets) |
| [pxf.md](pxf.md) | Periodic transfer function (adjoint PAC) | implemented (dense adjoint conversion matrix; matrix-free/time-domain/GPU extensions remain targets) |
| [qpss.md](qpss.md) | Quasi-periodic steady state (QP-HB, MFT shooting) | implemented (two-tone QP-HB with GMRES; MFT/full multidimensional preconditioning remain targets) |
| [dcmatch.md](dcmatch.md) | Pelgrom mismatch offset via adjoint sensitivity | implemented (finite-difference stamps; analytic stamps/AC mismatch remain targets) |

## Beat-Spectre checklist mapping (RESEARCH.md §2)

| # | Checklist item | Doc(s) |
|---|---|---|
| 1 | TR-BDF2 / strict LTE control + errpreset-style tolerance bundles | [transient-integration.md](transient-integration.md), [tolerance-system.md](tolerance-system.md) |
| 2 | Robust OP homotopy chain: gmin → source → pseudo-transient | [operating-point-homotopy.md](operating-point-homotopy.md) |
| 3 | Krylov-shooting PSS + pnoise (SpectreRF core) | [pss-shooting-harmonic-balance.md](pss-shooting-harmonic-balance.md), [periodic-noise.md](periodic-noise.md), [pac.md](pac.md), [pxf.md](pxf.md) |
| 4 | Multirate/envelope for RF (MPDE) | [mpde-envelope.md](mpde-envelope.md), [qpss.md](qpss.md) |
| 5 | Parallel/GPU transient (megakernel angle) | §4 of [transient-integration.md](transient-integration.md) + §4 of every doc; kernel spec in `src/analysis/eval/engine.zig` |
| — | Past-Spectre: matrix-exponential integrators | [matex-exponential-integrators.md](matex-exponential-integrators.md) |
| — | AC + adjoint noise (baseline capability) | [ac-small-signal-noise.md](ac-small-signal-noise.md) |
| — | Spectre-suite parity: sp/stb/pz/tf/sens/disto/four/MC/dcmatch | [s-parameters.md](s-parameters.md), [stability.md](stability.md), [pole-zero.md](pole-zero.md), [tf.md](tf.md), [sensitivity.md](sensitivity.md), [distortion.md](distortion.md), [fourier-thd.md](fourier-thd.md), [ensemble-sweeps.md](ensemble-sweeps.md), [dcmatch.md](dcmatch.md) |

## Shared machinery

Nonlinear analyses use `src/analysis/solvers/converger.zig`
(one `Tolerances` bundle, one acceptance kernel, direct-Newton + JFNK
strategies) and, on GPU, the cooperative megakernel in
`src/analysis/eval/engine.zig` (batched SoA device eval, on-device
GMRES, CPU-identical acceptance gates). Linear-solver theory lives in
[docs/solvers/](../solvers/README.md); each analysis doc's **Solvers
used** section maps its phases onto those docs and
`src/analysis/solvers/*`.
