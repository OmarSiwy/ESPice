# Future plans

Work left over from the production-readiness session. The state at the time of
writing is 717 of 719 corpus decks passing and 390 unit tests green. Each item
says where to start.

## Conformance

### Failing decks
- `dc/device_vbic_forced_output` and `noise/device_vbic_noise_scale`: known
  gaps. We keep VBIC 1.3 physics, while ngspice ships an older VBIC, so the
  gap is a difference between model versions and should not be force-matched.
  The decks stay marked `KNOWN GAP`.
- `tran/bench_ngspice_mosamp` and `tran/device_mesa_oscillator` now pass
  against converged references. Follow-ups:
  - At mosamp's original options (abstol=10n, vntol=10n), espice is less
    accurate than ngspice: 4.9e3x off on v(66) against ngspice's 1.3e3x.
    espice takes 169 steps where ngspice takes 2316, because ngspice cuts
    dt/8 while the MOS2 slews. Compare our LTE estimate with ngspice's
    `CKTterr` on the 5.0–5.7 µs settling tail (issues.md F1, group 14).
  - Trapezoidal integration rings on currents through sources that see only
    capacitance, in both simulators, and the ringing does not shrink with
    reltol. A damping option (xmu-style, or a damped step after breakpoints)
    would let espice beat ngspice at default settings.
  - The MESA deck now runs at reltol=1e-7 and takes about 7 s instead of
    0.1 s, and its i(vnoise) tolerance was widened to rtol 1e-2, atol 1e-9.
    Wrong answers still fail it by 3.6x to 300x. Add a separate fast deck
    that checks the period at default options.

### Semantics that are still off
- `.ic` holds are not scaled during source stepping.
- hfet1 keeps ngspice's `cdhat` / `ggdpp` quirk only in part. See
  `docs/devices/models.md`.
- The f32 GPU Jacobian is off by default because 4 decks fail with it on.
- Errors from option cards do not name their line.
- The DC sweep ignores `.nodeset`.
- PWL current sources do not round their breakpoints like VSRCaccept does.
- The autonomous Krylov path (50 or more unknowns) has no test deck.

## HSPICE and VACASK features

`docs/plan/hspice-comparison.md` and `docs/plan/vacask-comparison.md` track
the full matrix. Open items:

- **Behavioural sources (WIP, not landed).** Branch
  `worktree-agent-a625f5c142f0914fa`, commit `0d7e3e0e`. It holds:
  - a shared expression tape (`models/native/btape.zig`) with `time`, `temper`
    and a smoothed TABLE;
  - `i()` probes;
  - E/F/G/H VALUE/POLY/TABLE/PWL/VCR/VCCAP lowered to B cards;
  - LAPLACE (state space), a charge-output B source, and DELAY.

  It does not build: `models/native/laplace.zig` still fails. To land it:
  1. Get the build passing, run `zig build test`, and snapshot-compare it
     against main. Existing B-source decks are at risk because probes now
     dedupe by matrix row.
  2. Write oracle decks: ngspice for VALUE/POLY/TABLE/`i()`/`time`/`temper`
     and for noise with a current-source input, analytic for LAPLACE, DELAY,
     VCR and VCCAP. Make `hspice/laplace_source` run instead of expecting an
     error.
  3. VCR (factor read as a resistance) and VCCAP (Q = C·V) come from reading
     the manual. Check them against HSPICE and record them in `docs/`.
  4. POLE, FREQ, OPAMP, NPWL/PPWL, the logic gates and TRANSFORMER are
     still refused.
- **W and S elements (WIP, not landed).** Branch
  `worktree-agent-a88282e1f6b249fdd`, commit `7accb00d`. Only its three
  standalone `zig test` files have been run: `wline.zig`, `ydata.zig` and
  `sparam.zig`.
  - The W element (`models/native/wline.zig`) supports RLGCMODEL and
    RLGCFILE for N up to 4.
    - DC, AC and noise are exact, including Rs·√f and Gd. The `fgd` formula
      is a guess from a garbled manual equation.
    - Transient reuses TXL (N=1) or CPL (N=2..4) on R0/L0/G0/C0.
  - The S element (`src/frontend/sparam.zig`, `models/native/ydata.zig`)
    reads Touchstone 1.0.
    - Transient uses vector fitting plus passivity enforcement, which is
      HSPICE's `RATIONAL_FUNC=1`, not its IFFT default.
    - In `.ac` it is exact at the data points.
  - The dense QR eigen solver moved to `core.eigen`, which changes a public
    API.

  To land it:
  1. Build, run the unit suites and the corpus, and compare snapshots.
     `hspice/w_element.sp` still expects the old error and has to be
     rewritten.
  2. Add oracle decks:
     - RLGC with Rs/Gd in `.ac` against the closed-form ABCD;
     - a matched lossless line as a pure delay;
     - `device_coupled_tlines` rewritten as a W card, reusing its ngspice CPL
       oracle;
     - an N=1 W line against an ngspice TXL run;
     - an S element built from an analytic network.
  3. Build a transient model for Rs/Gd by fitting Yc and the propagation term
     with delay extracted. Until then Rs/Gd are refused in time-domain decks.

  Other gaps:
  - tabular W models, FQMODEL, CITI and Touchstone 2.0;
  - noise from lossy W lines and S elements;
  - DELAYHANDLE;
  - interpolation in magnitude/angle (we interpolate Y in real/imaginary);
  - data files named inside an `.include` resolve against the top deck's
    directory;
  - IBIS was only scoped, never built;
  - a docs page for W/S, and the E2/E3 status in hspice-comparison.
- **HSPICE P elements.** Put z0 in series in DC, tran and HB (a hidden node
  plus a noiseless resistor), and stop `sp.zig` and `hb_lptv.zig` from adding
  it twice. Then `.hblsp` and `.hblin` noise.
- **`.meas` over NOISE:** not read yet.
- **Noise:**
  - trannoise `SAMPLES>1`, SDE and TIME;
  - a `.ptdnoise` TIME sweep;
  - `.sample BETA`;
  - phase-noise flicker, METHOD 1 and 2, and `.acphasenoise`.
- **Multitone HB:**
  - SUBHARMS, SS_TONE and SWEEP;
  - complex output;
  - small-signal analyses on top of multitone.
- **Optimization:**
  - bisection and pass/fail;
  - LEVEL>1;
  - inequality goals;
  - optimization combined with `.step`.
- **Variants:** external `.data` files and the other limits listed in
  hspice-comparison.
- **`.lin`:**
  - `.net`;
  - mixed-mode;
  - K and MU;
  - Touchstone files that are not 50 Ω.
- **Unconfirmed against HSPICE:** each of these follows the manual and has
  never been run against real HSPICE:
  - `.alter` being cumulative;
  - the `.lstb` sign;
  - `.measure` over DCMATCH, ACMATCH, LSTB, PHASENOISE and PTDNOISE
    (our column names, not HSPICE's output variables);
  - `.dcxf` leaving out F/H-sensed sources;
  - DEV/LOT sigma;
  - VCR and VCCAP.
- **Long tail:** digital vector cards, `.check` cards, SEARCH, RUNLVL and
  ACCURATE, MOSRA, design exploration, IBIS and W/S details beyond what landed
  in this session (see the W and S entry above).

## Runtime `.hdl` models (WIP, not landed)

Branch `worktree-agent-aa8d73f15dbb06acd`, commit `da324431`. The
TinyTapeout_Flows session reported these problems and is waiting for this
work. It has never been built.
- The cache moves to `$ESPICE_CACHE`, `$XDG_CACHE_HOME/espice/hdl`,
  `~/.cache/espice/hdl` or `$TMPDIR`, and the `src_root` build option is
  gone.
- `zig build` installs the runtime build's sources into `share/espice/`. The
  compiler comes from `$ZIG` or PATH, and a Debug build or a wrong zig
  version now gets a clear error.
- VerA's diagnostics now print. If VerA refuses to generate code, the load
  fails with `HdlCodegenRefused`.
- `UnknownParameter` and `WrongNodeCount` are now errors.
- `pre_osdi` loads the `.va` sitting next to the `.osdi` if there is one.
  Otherwise it falls back to a built-in model with a warning, and failing
  that it errors.
- The README gets a section on using your own Verilog-A models.

To land it:
1. Build, run the tests and compare snapshots. The two new errors might
   break an existing deck in `tests/fixtures/hdl/*` or
   `qpss/idt_lowpass_two_tone`.
2. Rerun the reporter's decks (`t.sp`, `t2.sp`, `twotr.sp`, realvar/thev/`r.sp`)
   with an empty cache. They are the acceptance tests. `twotr.va` hit "local
   variable shadows declaration of 'h'" on an older build pinned to VerA
   297e97dc. The current pin, c964f644, is the same code as v0.9.0 and
   includes the fix (f4b44c69).
3. Check that the GPU build no longer fails with HIP "capacitor.zig: 'V' is not
   marked 'pub'".
4. Try the static musl nix build. It should load the model `.so` with Zig's
   own loader.
5. Check whether a bare `pre_osdi` inside `.control` reaches the list of
   external models.
6. Programs that embed libespice look for `share/espice` next to their own
   executable, not next to the library.
7. Debug builds cannot load `.hdl`. Zig's self-hosted backend is untested for
   building the model library.

## VerA (../VerA)

- VerA still has to ship two items: (b) rejecting a step from inside eval and
  (c) `$simparam` for reltol, abstol and vntol. Once both are in, re-pin
  `build.zig.zon` and wire them up.
- `.v` digital devices are expensive. The fixes are edge sensitivity, taking
  ttol from the ramp, and room for 256 pins. Also write docs for `.v` support
  and its ttol cost.
- We need a newer VACASK binary to regenerate the hbnoise and PSS oracles.

## Performance

- Refresh the benchmarks on a quiet machine and update the README table,
  which is stale. The last run beat ngspice on 437 of 445 decks, with a median
  time ratio of 0.53.
- Measure wall time for the multicore LU, the GPU LU and `--lu-fast`. The
  runners are in `zig-out/gl`.
- `vacask_graetz` falls back from fast mode on 35% of its solves.
- Wire GPU graph replay into Newton.
- Host-first device bypass. The census is in
  `docs/solvers/gpu-convergence.md` §9.
- Continuation bypass, the VACASK technique, as an opt-in.
- LU overhead on small matrices compared with KLU. This is unconfirmed.
- PSP worker lanes run 2x slower on E-cores. Compare 8 threads with 4.
- The GPU-native convergence research program is in
  `docs/solvers/gpu-convergence*.md`. Modified Newton has been retired (§10).
- Gompute: the AMD agent-scope asm is missing, and HIP has never run on
  hardware.

## Cleanup

- Make the harness report XFAIL/XPASS for `KNOWN GAP` decks instead of plain
  FAIL.
- Re-index `issues.md`.
- Update AGENTS.md: the baseline numbers, and the lane table (pac, pxf and
  pnoise now use GMRES).
- A final `/code-review`, `/simplify`, ponytail audit and doc-comment pass
  over what landed this session.
- Two branches predate the attribution rewrite and are not on main. Each tip
  has a `wip:` commit holding changes that were never committed:
  - `worktree-agent-a8390ff5b475622c8` adds GPU admission for `.path_latch`
    devices.
  - `stream-h-threads` makes ParEval bit-identical to serial and adds
    `--threads`.

  Check whether main already covers them, then either port what is missing
  or delete the branch.

## Before publishing

- Gompute is a local `.path` dependency (`../Gompute`) with local-only
  commits. Push those commits and restore a git pin; the owner decides when.
- ARPice `main` is 350+ commits ahead of `origin` and has not been pushed.
- One commit already on `origin` still carries an attribution line. It was
  left alone because fixing it means rewriting published history.
