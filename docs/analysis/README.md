# Analysis documentation

One page per analysis: the mathematical formulation, the flow through
`src/analysis/`, CPU pseudo-code, parallel design notes, and a
**Solvers used** section that maps each phase onto
[docs/solvers/](../solvers/README.md). Every page ends with its sources,
per-section verification status, and pointers to the implementation and
fixtures under `tests/fixtures/`.

Every solve runs on the host. The GPU evaluates device planes only
(`Circuit.gpu_hook.eval_planes`, `src/analysis/gpu.zig`); §4 of each page
separates what runs in parallel today (device evaluation on `ParEval`
threads or the GPU, SIMD frequency lanes) from design notes that are not
implemented.

## Core analyses

| Doc | Covers | Status |
|---|---|---|
| [operating-point-homotopy.md](operating-point-homotopy.md) | Newton with device limiting; plain, gmin, source, JFNK and OPtran rungs; PTC theory | implemented (SER-controlled PTC: not implemented) |
| [dc-sweep.md](dc-sweep.md) | Swept-source continuation, warm start, nested sweeps, ladder fallback, ngspice axis accumulation | implemented |
| [transient-integration.md](transient-integration.md) | BE/trap/Gear-2, TR-BDF2, per-state LTE (`CKTterr`), dctran.c step control, breakpoints | implemented (TR-BDF2: not implemented) |
| [tolerance-system.md](tolerance-system.md) | reltol/abstol/vntol/chgtol semantics, the residual gate and its ngspice divergence, errpreset theory | implemented (named bundles: not implemented) |
| [ac-small-signal-noise.md](ac-small-signal-noise.md) | AC sweep (stacked-real, SIMD frequency lanes), adjoint noise | implemented |
| [tf.md](tf.md) | DC transfer function: gain, Rin, Rout via forward and adjoint solve; all-source `.dcxf`/`.acxf`/`.dcinc` | implemented |
| [sensitivity.md](sensitivity.md) | DC/AC sensitivity: direct, adjoint and FD | implemented (DC adjoint with FD stamps; AC: not implemented) |
| [pole-zero.md](pole-zero.md) | Pencil $(G,C)$ eigenproblem, Hessenberg + Francis QR, column-swap zeros | implemented (QZ: not implemented) |
| [s-parameters.md](s-parameters.md) | Port formulation, z0 terminations, wave extraction | implemented |
| [stability.md](stability.md) | Return ratio, Middlebrook/Tian probes, margins | implemented (`.stb` single injection; `.lstb` Tian double injection, diff/comm modes, margins) |
| [distortion.md](distortion.md) | Volterra small-signal distortion, FD-of-analytic-Jacobian kernels | implemented (HD2, HD3, two-tone f1±f2 and 2f1−f2; resistive and charge kernels) |
| [fourier-thd.md](fourier-thd.md) | `.four` harmonic extraction: final-period resample, FFT, THD | implemented |
| [ensemble-sweeps.md](ensemble-sweeps.md) | Monte Carlo and temperature sweeps on structural lanes, seed policy | implemented |
| [variants.md](variants.md) | `.step`, `.data`/`SWEEP`, `.alter` and statistical Monte Carlo over any analysis: live parameters, `ParamRef` rows, warm-started lanes | implemented |
| [optimize.md](optimize.md) | HSPICE `OPTIMIZE=`: bounded Levenberg-Marquardt over live parameters, finite-difference points as parallel variant queries | implemented (LM only; bisection and pass/fail: not implemented) |
| [mosra.md](mosra.md) | HSPICE MOSRA aging: level 1 HCI/BTI power law integrated over a stress transient, aged reruns through `delvto`/`mulu0` variant rows | implemented (level 1, SimMode 0 and 2; equations unconfirmed against the manual) |
| [transient-noise.md](transient-noise.md) | Time-domain noise synthesis ($\sigma = \sqrt{S/2h}$), BE rationale | implemented (white part only) |
| [pss-shooting-harmonic-balance.md](pss-shooting-harmonic-balance.md) | Shooting Newton (dense FD or FD-matvec GMRES), harmonic balance, autonomous oscillators (`.snosc`, `.hbosc`) | implemented (saved-factor Krylov shooting: not implemented) |
| [periodic-noise.md](periodic-noise.md) | LPTV small-signal, sideband folding, cyclostationary sources; `.pnoise` on the shooting orbit, `.hbnoise` on the HB orbit | implemented (conversion matrix dense, or GMRES with LaneLu block-diagonal preconditioning past n·(2M+1) >= 64) |
| [pac.md](pac.md) | Periodic AC: harmonic conversion matrix over the PSS or HB orbit (`.pac`, `.hbac`) | implemented |
| [pxf.md](pxf.md) | Periodic transfer function (adjoint PAC; `.pxf`, `.hbxf`) | implemented (dense adjoint) |
| [phase-noise.md](phase-noise.md) | Oscillator phase noise by the PPV (`.phasenoise`, HSPICE METHOD=0) | implemented (white sources only) |
| [qpss.md](qpss.md) | Quasi-periodic steady state (QP-HB, MFT shooting) | implemented (two-tone QP-HB, unpreconditioned GMRES; MFT: not implemented) |
| [multitone-hb.md](multitone-hb.md) | `.hb TONES=`: any number of tones, box/diamond truncation, APFT collocation, GMRES with LaneLu block-diagonal preconditioning; large one-tone HB | implemented |
| [mpde-envelope.md](mpde-envelope.md) | MPDE, Fourier-envelope, sample-envelope following | partial (sample envelope with trapezoid inner steps) |
| [matex-exponential-integrators.md](matex-exponential-integrators.md) | Exponential integrators, Krylov $e^{Ah}v$, I-/R-MATEX | implemented (explicit linear R-MATEX) |
| [dcmatch.md](dcmatch.md) | Pelgrom mismatch offset via adjoint sensitivity | implemented (FD stamps) |

## Engine pages

| Doc | Covers |
|---|---|
| [refactoring.md](refactoring.md) | Module ownership, plane evaluation, ParEval, GPU plane hook, decisions kept on purpose, retired paths |
| [evaluation-profile.md](evaluation-profile.md) | Where a transient run's instructions go; kept and dropped host-pass kernel changes with measurements |

## Shared machinery

Nonlinear analyses converge through `src/solver/converger.zig`: one
`Tolerances` struct (`src/core/numerics.zig`), one set of acceptance gates,
and two strategies (direct Newton by default, JFNK under
`ESPICE_SOLVER=jfnk` and as rung 4 of the OP ladder). Frequency-domain
analyses share `ac/freq.zig Stream` over `FreqSolver.solveBatch`. Linear
solver theory lives in [docs/solvers/](../solvers/README.md).
