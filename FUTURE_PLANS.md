# Future plans

Open work on `main`, each item with where to start. Every corpus deck on
main passes except the two VBIC model-version decks, which the harness
reports as XFAIL. Work sitting on a feature branch is named with its
branch and is not on main until that branch merges.

## Conformance

### Failing decks
- `dc/device_vbic_forced_output` and `noise/device_vbic_noise_scale` are
  known gaps. We keep VBIC 1.3 physics and ngspice ships an older VBIC, so
  the difference is between model versions and should not be force-matched.
  Both decks stay marked `KNOWN GAP`.
- `tran/bench_ngspice_mosamp` and `tran/device_mesa_oscillator` pass
  against converged references. At mosamp's original options
  (abstol=10n, vntol=10n) espice is less accurate than ngspice, because
  ngspice's Newton fails ITL4 in the MOS2 slew and its h/8 cuts take 2316
  steps to our 169. The LTE agrees (docs/analysis/transient-integration.md);
  matching it means matching the MOS2 Newton behaviour.

### Semantics that are still off
- hfet1 keeps ngspice's `cdhat` / `ggdpp` quirk only in part. See
  `docs/devices/models.md`.
- The f32 GPU Jacobian is off by default (`-Djac-f32-gpu`, build.zig):
  with it on, four corpus decks fail under `--backend cuda`.

## HSPICE and VACASK features

`docs/plan/hspice-comparison.md` and `docs/plan/vacask-comparison.md` track
the full matrix. Behavioural E/F/G/H sources (VALUE, POLY, TABLE, PWL, VCR,
VCCAP, DELAY, LAPLACE, `i()` probes) are on main, all in Verilog-A. Open
items:

- **Controlled-source forms still refused** (`src/frontend/netlist.zig`):
  FREQ, OPAMP, NPWL/PPWL, the logic gates and TRANSFORMER. POLE is on main
  (`laplace_zp`, docs/frontend.md).
- **W and S elements** (landed for RLGC W and Touchstone 1.0 S, all
  Verilog-A: [w-s-elements.md](docs/devices/w-s-elements.md)). Left:
  - tabular W models (TABLEMODEL, UMODEL, FSMODEL, SMODEL), FQMODEL, CITI,
    Touchstone 2.0, S with more than 4 ports, mixed mode, DELAYHANDLE;
  - noise from lossy W lines and S elements (both are noiseless);
  - data files named inside an `.include` resolve against the top deck's
    directory;
  - |P| ≤ 1 is not enforced on the W propagation fit;
  - Gd·f is non-causal, so W lines with Gd fit to ~3e-2, not 1e-5;
  - the FGD roll-off follows a garbled manual equation, unconfirmed;
  - IBIS was only scoped, never built.
- **IBIS:** `feat/ibis`, not started on main.
- **`.hblsp`:** large-signal S over a power sweep. P elements carry z0 in
  HB; missing are driving a port's sine amplitude and frequency per point
  and a confirmed HSPICE definition of S12/S22.
- **`.meas` over NOISE:** not read yet. The other new analyses are.
- **Optimization** (docs/analysis/optimize.md): still refused are a
  bisection over several parameters or RESULTS cards, a bisection on a
  `GOAL <`/`>` card, OPTIMIZE with `.alter`, and `.measure ... pushout=`.
- **Variants** (docs/analysis/variants.md): `.data OUT=`, DEV/LOT
  AGAUSS/AUNIF and the blank-separated `dev/2 0.1` form, and `SWEEP`
  together with `.step`.
- **Unconfirmed against HSPICE.** Each follows the manual and has never run
  against real HSPICE:
  - `.alter` being cumulative;
  - the `.lstb` sign;
  - `.measure` over DCMATCH, ACMATCH, LSTB, PHASENOISE and PTDNOISE
    (our column names, not HSPICE's output variables);
  - `.dcxf` leaving out F/H-sensed sources;
  - DEV/LOT GAUSS values read as 3 sigma (SA Ch.20 p. 694);
  - an inequality goal adding no error while it holds (the manual gives
    only the syntax);
  - `MONTE=list(...)`, where the manual's two examples disagree;
  - VCR and VCCAP.
- **Long tail:** digital vector files, `.check` cards, `.stim`, SEARCH and
  RUNLVL/ACCURATE are on `feat/tail`. MOSRA level 1 is on main
  (docs/analysis/mosra.md). Design exploration has no branch.

## Runtime `.hdl` models

Runtime `.hdl` loading works from an installed espice (d9f1a7c9). Still
unchecked:
- The GPU build under HIP, which once failed with "capacitor.zig: 'V' is
  not marked 'pub'".
- The static musl nix build loading a model `.so` with Zig's own loader.
- Programs that embed libespice look for `share/espice` next to their own
  executable, not next to the library (`src/device/Library.zig`).
- Debug hosts refuse to build `.hdl` models with a named error, since Zig's
  self-hosted backend is untested for the model library.

## Oracles

- We need a newer VACASK binary to regenerate the hbnoise and PSS oracles.

## Performance

- Refresh the benchmarks on a quiet machine and update the README table,
  which is stale. The last run beat ngspice on 437 of 445 decks, with a median
  time ratio of 0.53.
- The device LU's `auto` bar (F/n 500) sits in an unmeasured gap between
  166 and 1,600; time a deck that lands there.
- Wire GPU graph replay into Newton (`docs/solvers/gpu-lu.md` §4.3).
  Unblocked: the pinned gompute has capture, instantiate, launch and
  update (§7 R2, gompute 96cc593).
- Host-first device bypass. The census is in
  `docs/solvers/gpu-convergence.md` §9.
- Continuation bypass, the VACASK technique, as an opt-in.
- The GPU-native convergence research program is in
  `docs/solvers/gpu-convergence*.md`. Modified Newton has been retired (§10).
- Gompute: the AMD agent-scope asm is missing, and HIP has never run on
  hardware.

## Cleanup

- A `/code-review`, `/simplify`, ponytail audit and doc-comment pass over
  what landed since the last one.

## Before publishing

- stdpp is a frozen snapshot at `../stdpp-pin1` (a `.path` dependency in
  `build.zig.zon`) until it has a git remote. Then pin it by URL; the
  owner decides when.
- `main` has not been pushed since the V1.0.0 release (`origin/main`).
- One commit already on `origin` (the V1.0.0 release) still carries an
  attribution line. It was left alone because fixing it means rewriting
  published history.
