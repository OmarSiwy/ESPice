# ESPice against VACASK: features, speed, and what to build next

VACASK is Árpád Bűrmen's simulator from the EDA Laboratory at the University
of Ljubljana. It loads Verilog-A models compiled to OSDI by OpenVAF-Reloaded,
reads a Spectre-like netlist, and sequences analyses from a control block.
This page compares it with ESPice as each stands today, ranks the features
ESPice lacks, explains where VACASK's speed comes from, and lists what
ESPice has that VACASK does not.

Scope and sources:

- ESPice: `main` at `31d202c`. Code paths are relative to the repository
  root.
- VACASK: source at `4942182` (2026-09-28), cloned from
  <https://codeberg.org/arpadbuermen/VACASK>. Paths such as
  `lib/coretran.cpp:1500` refer to that commit.
- The installed binary used by `zig build bench`
  (`/nix/store/g5ial84gcp2da9h7y63r4c6dc1iqip57-vacask-unstable-2026`) is
  older than the source. It runs `hb` but rejects `pss` and `hbnoise`
  ("Analysis type 'pss' not found"). The benchmark numbers below come from
  that binary. PSS, PAC and HB noise landed in VACASK within the last ten
  weeks: `lib/anhbac.cpp` on 2026-07-20, `lib/anpss.cpp` on 2026-07-24,
  `lib/anhbnoise.cpp` on 2026-09-16 and `lib/anpac.cpp` on 2026-09-25 (from
  `git log --diff-filter=A`). VACASK is moving quickly, so this page is a
  snapshot.
- Speed data comes from three places: a full `zig build bench` run at
  `96807bd` (266 decks shared with VACASK; the run's markdown is not checked
  in, so the rows used here are quoted inline), the post-layout tables in
  [gpu-evaluation.md](../devices/gpu-evaluation.md#post-layout-results), and
  two runs of `vacask_ring` made for this page. Those two runs were
  single runs on a loaded machine (load average 55 to 105 on 32 cores). Use
  their counters (steps, iterations, evaluations), which load cannot move,
  and treat their wall times as indicative only.

## 1. Feature matrix

"Yes" means the feature runs in the code today. The ngspice column is from
the ngspice-45 source (`src/spicelib/analysis/*.c`) and covers analyses only.

### Analyses

| Analysis | VACASK | ESPice | ngspice |
|---|---|---|---|
| DC operating point | `op` | `.op`, five-rung ladder (`dc/op.zig`) | yes |
| DC sweep | `sweep` + `op` over any parameter, option or variable, nested to any depth (`docs/cmd-sweep.md`) | `.dc` over V, I, R, C, L or TEMP, two levels (`dc/dc.zig`) | V, I, R, TEMP |
| DC small-signal response | `dcinc` | `.dcinc` (`dc/xf.zig`) | no |
| DC transfer function | `dcxf`: every independent source to one output in one run, plus `zin`/`yin` per source | `.tf`: one source (`dc/tf.zig`); `.dcxf` every source (`dc/xf.zig`) | `.tf` |
| AC | `ac` | `.ac`, SIMD frequency lanes (`ac/freq.zig`) | yes |
| AC transfer function | `acxf`: all sources, `tf`/`zin`/`yin` over frequency | `.acxf` (`ac/xf.zig`) | no |
| Stability | `acstb`: current and voltage injection, forward and reverse loop gain, DUT y-parameters (`docs/cmd-analysis-acstb.md`) | `.lstb`: `acstb`'s algorithm plus diff/comm modes and margins (`ac/lstb.zig`); `.stb` single injection | no |
| S-parameters | `acsp`, ports from source and series-resistor pairs | `.sp`, ports from `portnum` (`ac/sp.zig`) | `.sp` |
| Small-signal noise | `noise`, with per-instance and per-source contributions `n(inst)`, `n(inst,contrib)` and power gain | `.noise`: total output and input-referred only (`ac/noise.zig`) | yes, per device |
| Pole-zero | no | `.pz` (`eigen/pz.zig`) | yes |
| Distortion | no | `.disto`, HD2/HD3 (`post/disto.zig`) | yes |
| Sensitivity | no | `.sens` DC adjoint (`sweep/sens.zig`) | yes |
| DC mismatch | no | `.dcmatch` (`dc/dcmatch.zig`) | no |
| Transient | `tran`: Euler, trap, Adams-Moulton, BDF/Gear | `.tran`: BE, trap, Gear-2 (`tran/tran.zig`) | yes |
| Fourier | no (Python postprocessing) | `.four` (`post/four.zig`) | yes |
| Transient noise | white and flicker, ZOH (Voss-McCartney) or SDE (Lorentzian sums) (`lib/tdn*.cpp`) | white only, BE (`tran/tran_noise.zig`) | noise sources on V/I |
| Exponential integrator | no | `.matex`, linear circuits (`tran/matex.zig`) | no |
| Envelope | no | `.envelope`, sample-envelope following (`tran/envelope.zig`) | no |
| PSS | `pss`: single shooting with the monodromy matrix integrated alongside, driven and autonomous (oscillator, period solved) (`lib/corepss.cpp`) | `.pss`: shooting, dense FD monodromy below 50 unknowns, matrix-free GMRES above; driven, and autonomous with the period solved and one node pinned (`.pss v(osc)`, `.snosc`) (`pss/pss.zig`) | `.pss`, experimental |
| Harmonic balance | `hb`: any number of tones, box/diamond/hybrid truncation, APFT collocation, sparse block Jacobian on KLU or SuperLU_MT (`lib/corehb*.cpp`) | `.hb`: one tone dense (`pss/hb.zig`); `.hb TONES=` any number of tones, box/diamond (hybrid) truncation, APFT collocation, matrix-free block Jacobian by GMRES with a LaneLu block-diagonal preconditioner, also taken by large one-tone circuits (`pss/mhb.zig`, [multitone-hb.md](../analysis/multitone-hb.md)); magnitudes only | no |
| Quasi-periodic steady state | `hb` with two or more tones | `.qpss`: two tones, GMRES without a preconditioner (`pss/qpss.zig`) | no |
| Periodic AC | `pac` (shooting) and `hbac` (HB, multi-tone) | `.pac` (shooting) and `.hbac` (one-tone HB); conversion matrix dense, or GMRES with a LaneLu block-diagonal preconditioner past n(2M+1) >= 64 | no |
| Periodic transfer function | no | `.pxf` (shooting) and `.hbxf` (HB) | no |
| Periodic noise | `hbnoise` (HB, multi-tone) | `.pnoise` (shooting) | no |
| HB noise | `hbnoise` | `.hbnoise` (one tone; `pss/hb_lptv.zig`) | no |
| Monte Carlo | `mc ... endmc` loop around any analyses; `gauss`/`agauss`/`unif`/`aunif` in expressions; Latin hypercube by default (`docs/cmd-analysis-mc.md`) | `.mc`: Gaussian on each device's primary value, DC only (`sweep/mc.zig`) | via control scripts |
| Temperature sweep | `sweep option="temp"` | `.temp` lanes, `.dc TEMP` | `.dc TEMP` |
| Stored solutions | `store=`/`nodeset=`/`ic=` across analyses; `opsolve=0` linearizes at a stored point | no; one OP per Problem is shared by the queries that need it | no |

### Devices and models

| | VACASK | ESPice |
|---|---|---|
| Model mechanism | OSDI shared objects from OpenVAF; `load "x.va"` compiles on demand (`docs/cir-loading.md`) | VerA compiles `models/*.va` at build time into host and GPU code; `.hdl` loads `.va` at run time through VerA into a cached `.so` (`src/device/loader.zig`) |
| OSDI loading | yes, the only path | no. `.osdi_include` parses and is then dropped (`src/frontend/prepare.zig:68-77`) |
| Builtin devices | sources, controlled sources, mutual inductance, expression-defined behavioral sources compiled to Verilog-A (`docs/dev-builtin*.md`) | R C L K V I E G F H S W, B as an expression tape (up to 8 probed nets, no `i()` probes, no `time`) (`models/native/bsource.zig`), native lossy lines O/Y/P, URC |
| Compact models shipped | BSIM3v3, BSIM4.8, BSIM-BULK 106.2, PSP 103.4, VBIC 1.3 (3, 4 and 5 terminals), plus VADistiller conversions of the SPICE diode, BJT, JFET 1/2, MESFET, MOS 1/2/3/6/9, VDMOS (`docs/dev-3rdparty.md`, `docs/dev-spice.md`) | 41 `.va` models: the same SPICE set plus BSIM1/2, B3SOI FD/DD, BSIM-SOI, HiSIM2, HiSIM-HV, HICUM L2, HFET1/2, MESA, JFET2, lossy and coupled lines (`models/`) |
| Transmission lines | ideal line only (`devices/tline_ideal.va`) | LTRA, TXL, CPL (native), T, URC |

### Netlist language

| | VACASK | ESPice |
|---|---|---|
| Native syntax | Spectre-like, with a control block | ngspice and HSPICE dialects; Spectre lexing only (`src/frontend/lines.zig:8`) |
| SPICE input | only as `include ... lang=ngspice` when built with `CADNIP_PARSERS` (off by default), or through the `python/ng2vc.py` converter | the root deck, including `.lib` PDK files |
| Parameters | integers, reals, strings, vectors and lists; 62 builtin functions (`docs/expr-functions.md`) | reals; about 20 functions; `agauss`/`gauss` resolve only when a zero multiplier erases them, the nominal PDK corner `0*agauss(...)` (`src/frontend/expr.zig:285-288`, `:372`) |
| Hierarchy | parameterized subcircuits, nested definitions, `$mfactor`, user global and ground nodes | `.subckt` with `params:`, flattened, 32 levels |
| Conditionals | `@if/@elseif/@else/@end`, may change topology | `.if/.elseif/.else/.endif`, per instance inside a subckt |
| Binning | automated | `nm.N` bins by length and width |
| Changes without reload | `alter`, `var`, `options`, topology re-elaboration between analyses (`docs/cmd-alter.md`, `docs/cmd-elaboration.md`) | `append_directives` on a live Problem (C API); no `.alter` |
| Unknown cards | errors | ignored without a message: `.step`, `.alter`, `.nodeset`, `.func`, `.control` (`src/frontend/netlist.zig:779`) |
| Measurements | none built in; Python via `postprocess` | `.meas` (trig/targ, find/when, avg, rms, pp, integ, min/max) |
| Embedded files | `embed "x" <<<FILE ... >>>FILE` | no |

### Options, convergence, output, APIs, parallelism

| | VACASK | ESPice |
|---|---|---|
| Newton convergence | delta check plus a residual check (on by default), tolerances per Verilog-A nature, five relative-reference modes (`docs/cmd-options-relref.md`) | delta and residual gates with global `vntol`/`abstol` (`src/solver/converger.zig:277`) |
| OP homotopy | gdev and gshunt adaptive gmin stepping, SPICE3 gmin, adaptive and SPICE3 source stepping (`lib/homotopy.cpp`) | dynamic gmin, adaptive source stepping, JFNK, pseudo-transient (`dc/op.zig`) |
| Nodesets | yes, forced by row-norm-scaled diagonal terms (`lib/coreopnr.cpp:797-893`) | no |
| Output formats | SPICE raw, binary or ASCII | binary raw, ASCII raw, CSV, Touchstone, PSF ASCII, FSDB, SST2, CITIfile, print |
| Embedding | C++ static library `simlib` (`docs/cpp-api.md`) | C ABI `include/espice.h`, enums checked against Zig at comptime (`src/c_api.zig:18-36`) |
| Scripting | Python postprocessing, `rawfile.py`, PDK and Xschem converters | none |
| Device evaluation threads | none; OpenMP deliberately kept out of the evaluator (`CMakeLists.txt:196-212`) | ParEval lanes (`ESPICE_THREADS`), GPU planes on CUDA/HIP |
| Solver threads | SuperLU_MT for HB and HB small-signal only (`docs/startup-options.md`) | BBD factor threads (`ESPICE_SOLVER_THREADS`) |
| Query parallelism | control block runs in order | `--jobs=N` runs the ready query frontier concurrently |
| Frequency points | one complex KLU refactor and solve per point (`lib/coreac.cpp`) | SIMD lanes replaying one pivot tape (`LaneLu`) |

## 2. Gaps ranked by user value

Sizes: S is under 300 lines of Zig, M is 300 to 1,000, L is over 1,000.
Each sketch follows the lane-axis doctrine and the data rules in `AGENTS.md`.

### G1. Sweeps and alters over any analysis (L)

Status: landed as hspice-comparison C1-C3 ([variants.md](../analysis/variants.md)).

VACASK sweeps any instance, model or subcircuit parameter, option or
circuit variable around any analysis, to any depth, and changes them
between analyses without reparsing. ESPice sweeps sources, R/C/L and
temperature, and only inside `.dc` and `.temp`. `.step` and `.alter` are
ignored without a message. This is the most common thing a designer asks
of a simulator after `.op`, `.ac` and `.tran`, and every PDK corner or
sizing study needs it.

The frontend folds expressions to constants during binding, so today there
is nothing to re-evaluate. The foundation is a table of live parameters:

- Data in: global `.param` names and subckt parameters that a `.step` or
  `.alter` targets. Data out: the device parameters whose values depend on
  them, rewritten through `ParamRef.set`.
- Layout: SoA rows `{ref: u32 (index into collectParams), code: u32 (offset
  into a postfix pool), len: u16, scope: u32 (subckt instance)}` plus a CSR
  from each steppable name to its dependent rows in topological order.
  Built once in the parse-scratch arena, kept in the session arena. Only
  rows that depend on a steppable name exist, so the table is empty for
  decks that sweep nothing.
- A `Step` query wraps any inner query kind. Per point it writes the value,
  replays the dependent rows, calls `ckt.recompute()` (or `recomputeType`
  for the touched device types), and runs the inner analysis. The result
  is one plot per point in raw, the way ngspice writes `.step`.
- A change that alters topology (a `.if` on a stepped name, an `m` that
  crosses zero) returns `TopologyChanged`, and that point re-prepares the
  Problem. VACASK does the same with partial re-elaboration.
- `.alter` is a single-point `Step`. The C API gets the diagonal route:
  `espice_set_param(problem, name, value)` followed by the usual advance.
- Points are independent, so `--jobs` can run them concurrently once each
  worker owns a Circuit copy. `ParamRef.ptr` points into frozen storage, so
  sharing one Circuit across workers is not an option. Run them serially
  first.

### G2. Statistical Monte Carlo over any analysis (M, after G1)

Status: landed as hspice-comparison C1-C3 ([variants.md](../analysis/variants.md)).

PDK decks describe process and mismatch variation with `agauss` and `gauss`
inside `.param` and subckt defaults. VACASK's `mc` loop redraws every
distribution call site per sample (Latin hypercube by default) and runs any
analyses inside the loop. ESPice resolves `agauss` only in the nominal
corner `0*agauss(...)`, where a zero multiplier erases it
(`src/frontend/expr.zig:372`); any other use leaves the parameter
unresolved. Its `.mc` perturbs each device's primary value and runs DC
only.

- A generator table, SoA: `kind: u8` (gauss, agauss, unif, aunif), `nom`,
  `var`, `sigma: f64`, `scope: u32`. A call inside a subckt default is one
  site per instance, since that is how mismatch works in PDK decks. A
  global `.param` call is one site per run.
- Trial k draws every site (plain or Latin hypercube: one stratified
  permutation per site), writes the drawn values into the G1 table, replays
  the dependents and runs the inner query. The PRNG stays seeded per
  query, as in `sweep/mc.zig`.
- Trials are structural lanes (`sweep/lanes.zig`) when the inner analysis
  is DC. For other analyses they are G1 points.
- The existing `.mc N variation` stays as the no-generator fallback.

### G3. `.nodeset` (S)

`.nodeset` is standard SPICE and ESPice drops it without a message, which
can send a bistable circuit to the wrong operating point with no warning.
VACASK forces nodesets through diagonal terms scaled by the row norm
(`lib/coreopnr.cpp:797-893`, `nr_nsforce = 10`) and then releases them.
The ESPice version is a rung 0 in the `dc/op.zig` ladder: one Newton solve
with `G_ii += g_force` and `rhs_i += g_force * v_i` on the named rows, then
the plain ladder from that point. The `.ic` plumbing already parses the same
`v(n)=x` syntax. Until this lands, the frontend should reject `.nodeset`
rather than drop it.

### G4. HB noise (explicitly requested; phase A is M, phase B is L)

VACASK's `hbnoise` (`lib/corehbnoise.cpp:469-700`) builds the HB conversion
matrix, runs one adjoint solve per offset frequency, folds each noise source
through the Toeplitz matrix of its modulation function's harmonics, and sums
|w|²·S(|f + f_i|) over sidebands. The modulation function comes from the
device's noise density along the orbit: m(t) = sign(D)·sqrt(|D|/2)
(`lib/osdiinstance.cpp:1684-1708`, where D is OSDI's one-sided PSD). That
is the same model `pss/pnoise.zig` already implements on a shooting orbit,
so most of HB noise exists in ESPice already.

Six questions, answered for phase A:

1. In: the HB solution `x_hat` (n·(2K+1) reals), the noise sources along
   the orbit, the offset sweep. Out: output density per offset frequency,
   and, with G5, per-source contributions and gain.
2. How many: n up to about 10⁴, K up to 32, sidebands M up to 31, N orbit
   samples up to 256, a few sources per device, around 100 frequencies.
3. Widths: node indices u32, harmonic and sideband counts u16, sideband
   offsets |m − j| ≤ 2M, which fits i16.
4. Access: the folding loop reads `h[m*n + node]` for a source's two nodes
   across m, and `amp_hat[bin*S + s]`. Source-major outer, sideband inner,
   as in `pnoise.zig` today.
5. Lifetime: everything is per-query scratch.
6. Parallel: frequencies are independent. Threads per frequency point
   first; phase B turns them into lanes.

Phase A, on today's `hb.zig`:

- Split `hb.solve` so the whole `x_hat` is reachable:
  `solveSpectrum(ckt, x_hat_out, options, alloc)` with `solve` reduced to
  probe extraction on top. Callers can then stop after the solve or keep
  going, which is the granularity rule of `api-design`.
- Add `hbOrbit(x_hat, n, K, f0, n_samples) pac.Orbit`. It IDFTs `x_hat`
  onto a uniform power-of-two grid `N = ceilPow2(max(4K + 2, 2(2M + 1)))`
  (HB's own grid is 2(2K+1) points, not a power of two) and writes the
  `[t, x(t)]` rows `pac.Orbit` expects. It costs O(n·K·N) using the cos/sin
  tables `hb.zig` already builds.
- Split `pnoise.sweep` into the orbit provider and an
  `orbitSweep(ckt, orb, sources, freqs, density, options, alloc)` that takes
  an `Orbit` by value. `pnoise` becomes `pac.orbit` plus `orbitSweep`;
  `hbnoise` becomes `hb.solveSpectrum` plus `hbOrbit` plus `orbitSweep`.
- Everything after the orbit is reused unchanged: `pac.linearize(ckt, orb,
  .noise)` (G(t), C(t) and the `acDyn` terms FFT'd per slot),
  `collectNoiseSources` at each sample, `pac.spectra` on the source
  amplitudes, `pac.sweep(true, ...)` for the adjoint conversion-matrix
  solve, the sideband folding loop, and `sourcePsd`.
- Card `.hbnoise v(out[,ref]) [Vsrc] sweep f0 [K] [M]`, a new `Kind`,
  `schemaOf` and a C enum entry (the header enum is checked at comptime).
- Three fixes belong in the shared loop first, so both analyses get them:
  drive `out_neg` with −1 for differential outputs (pnoise is single-ended
  today); compute the input-referred gain from the same adjoint at the
  `Vsrc` rows (pnoise parses `Vsrc` and never reads it); and take
  `sign(D)·sqrt(|D|)` so a negative density does not turn into NaN.
- Settle `issues.md` C5 (LTI sidebands add noise) before building on the
  folding loop.
- Tests: an LTI RC under a large sine must give `hbnoise` equal to `.noise`
  at every frequency; a diode mixer must give `hbnoise` equal to `pnoise`
  where both orbits converge (a differential test between the two orbit
  providers); and fixtures with VACASK as the oracle, which needs a VACASK
  pin at or after `c19d96c`.

Phase A inherits both dense solves: HB's O((n(2K+1))²) Jacobian and the
per-frequency (2(2M+1)n)² conversion LU in `pac.sweep`. That is fine for
the RF front-end cells HB noise is usually run on and rules out large
circuits.

Phase B, the scalable version, is also what multi-tone HB, `hbac` and fast
PAC/PXF/pnoise need. Status: landed except complex phasor output; see
[multitone-hb.md](../analysis/multitone-hb.md) for what was built and its
measurements.

- The HB Jacobian as a sparse block matrix: the circuit's CSC pattern with
  each nonzero widened to a (2K+1)² block. VACASK stores exactly this, with
  fully dense blocks (`lib/cscblkmatrix.cpp`), and factors it with KLU or
  SuperLU_MT.
- ESPice can go further with GMRES preconditioned by the block-diagonal
  linear part `G₀ + jkω₀C₀`, k = 0..K. Those K+1 matrices share one pattern
  and differ only in ω, which is the shape `LaneLu` already factors as
  frequency lanes. HB harmonics are coupled through the nonlinearity, so the
  Newton system is not a lane axis, but its preconditioner is.
- The conversion matrix for `hbnoise`, `hbac`, `pac`, `pxf` and `pnoise`
  has the same block structure with `G_{p−q} + jω_p C_{p−q}`. The same
  preconditioner at ω_p = ω + pω₀ replaces the dense LU, and lifts the
  "dense and serial per frequency" ceiling noted at `pac.zig:54`.
- Multi-tone: generalize the spectrum to box/diamond truncated mixing
  products. `qpss.zig`'s nonuniform transform covers two tones; VACASK's
  oversampled pool with greedy orthogonal selection (`lib/corehbcoloc.cpp`)
  covers any number.
- Output complex phasors. `hb.zig` discards phase today.

### G5. Observability: noise contributions and device operating-point values (S and M)

VACASK reports `n(inst)` and `n(inst,contrib)` for `noise` and `hbnoise`,
and `p(inst,outvar)` saves device output variables (gm, vth, ids) along any
analysis. ESPice's `.noise` emits totals only, and there is no way to read a
device's operating-point values.

- Noise contributions (S): `ac/noise.zig` already forms each source's
  |y_p − y_n|²·S per frequency before summing. Keep the per-source terms
  as columns, named from the device's `noise_gens` entries. The same
  columns fall out of the pnoise and hbnoise folding loop.
- Operating-point values (M): this needs VerA to export a model's output
  variables as a per-instance table (name, slot) filled during `eval`. The
  host side is a `.save @m1[gm]` label resolved to (batch, instance, slot)
  at preparation, and a gather into the result after each accepted point.
  Blocked on VerA; file it in [vera-gaps.md](../vera-gaps.md).

### Further gaps

| Gap | User value | Sketch | Size |
|---|---|---|---|
| Oscillator PSS | high for RF | Add T to the shooting unknowns with phase condition αᵀΔx₀ = 0, α = ẋ(0); the period sensitivity is ẋ(T) from the last trapezoid step. Bordered system through the existing dense or GMRES path in `pss.zig`. | M |
| Complete `.stb` | medium | Two right-hand sides per factorization (current and voltage injection) through `FreqSolver.solveBatch`, then VACASK's y-parameter formulas for Wf, Wr, W. Add gain and phase margins as a result row. | S |
| All-source transfer functions (`dcxf`/`acxf`) | medium | One adjoint solve per frequency gives `tf(src)` for every source at once. `zin`/`yin` need one extra solve per source; batch those as right-hand sides on the same lane factor. | S |
| Flicker transient noise | medium | Voss-McCartney ZOH rows or a sum of Lorentzian SDEs per flicker source (`lib/tdnzohflicker.cpp`, `lib/tdnsdeflicker.cpp`); move off BE to the transient integrator's method. | M |
| OSDI loading | medium | A host-only Batch type over `OsdiDescriptor`: params set through the descriptor, `eval` per instance, Jacobian pointers resolved into plane slots once. No GPU and no dual-number AD. Lets users run OpenVAF-compiled models unchanged. | L |
| B-source `i()` and `time` | medium | A branch-current control port (the probed V source's branch row) and a `time` opcode reading `SimState.t` in `bsource.zig`'s tape. | S |
| Python | medium | A ctypes wrapper over `espice.h` with NumPy views of `result_view`. | S |
| BSIM-BULK 106, VBIC 5-terminal | low to medium | Add the `.va` sources if VerA compiles them; license check first. | S each |
| Per-nature tolerances | low | Carry a nature id per unknown from VerA and read `abstol` per row in the converger. | S |

## 3. Where VACASK is faster, and why

### The measured picture

On the 266 decks both simulators finished in the `96807bd` bench run,
ESPice was faster on all 266, median ratio 0.41 (0.40 over the 233 that
agree). Most of those decks take 5 to 20 ms, so the ratio mostly reflects
process start. The larger decks that agree: `sweep_opamp_wl_5000` at 0.15,
`bridge_capacitor_transient` 0.27, `vacask_rc` 0.29, `fanout_tran` 0.29,
`resistor_grid_100x100` 0.50. Six of the eleven decks where VACASK took
over 100 ms read DIFFER (the inverter chains, the parallel inverters and
both RC ladders), so their ratios, down to 0.05 on `inverter_chain_4k`, are
not like-for-like.

VACASK comes closest on PSP103 transients, and is ahead of
single-threaded ESPice on two of them. On the post-layout decks
([gpu-evaluation.md](../devices/gpu-evaluation.md#wall-time)), the
single-thread ratio ESPice/VACASK is 0.60, 0.65, 0.38 and 0.89 for the
BSIM4 chain, ring, logic and SRAM decks, and 0.73, 0.88, 0.48 and 1.09 for
the PSP103 ones:

| Deck | ESPice 1 thread | ESPice best | VACASK | Source |
|---|---:|---:|---:|---|
| `sram_psp103_1k` | 4.20 s | 3.37 s (8 threads) | 3.86 s | gpu-evaluation.md |
| `vacask_ring` (9-stage PSP103 ring, 1 µs) | 3.21 s | | 2.62 s | this page, one loaded run each |

The bench could not compare `vacask_ring` because the translator does not
convert `{w}` expressions. Running VACASK's own copy of the deck
(`benchmark/ring/vacask/runme.sim`) against `tests/fixtures/stress/vacask_ring.sp`
gives these counters:

| | VACASK | ESPice |
|---|---:|---:|
| Accepted points | 26,040 | 20,740 |
| Rejected points | 1 | 1,236 (LTE) |
| Newton iterations | 81,949 | 67,137 |
| PSP instance evaluations in Newton | 1,006,380 | 1,208,466 |
| Evaluations skipped by continuation bypass | 468,702 | 0 |
| Charge-only evaluations after each converged attempt | 0 | 395,568 |
| LU refactors | 81,948 | 67,137 |

ESPice takes 20% fewer steps and 18% fewer Newton iterations, and still
makes about 59% more device evaluation calls: 1.60 million full or
charge-only against 1.01 million. (The charge-only count is 21,976 converged
attempts times 18 instances; `evalQ` runs before the LTE check, so rejected
attempts pay for it too.) The wall time follows the evaluation count. ESPice's time per
PSP evaluation is not the problem: 1,607 ms over 1.21 million evaluations
is 1.3 µs each, while VACASK's 1,905 ms of eval-and-load over 1.01 million
is 1.9 µs each (both taken under load). Per LU call ESPice looks slower,
4.9 µs per refactor and 1.9 µs per solve against KLU's 1.3 µs and 0.5 µs, at
n = 156 and 1,200 nonzeros. That comparison was under load, and it does
not hold up: on the same matrices in isolation ESPice is the faster one
(see item 3 below).

### How VACASK gets its speed

Its gains over ngspice come from reusing work, not from the numerics, and
the evaluator is single-threaded.

Continuation bypass is the main one, and it is on by default
(`nr_contbypass = 1`, `lib/options.cpp:108`). After an accepted timepoint
(`lib/coretran.cpp:1923-1927`), between sweep points with no topology
change (`lib/an.cpp:323-334`) and in each homotopy step
(`lib/hmtpgmin.cpp`, `lib/hmtpsrc.cpp`), the first Newton iteration skips
every bypassable instance's `eval` and loads the contributions stored at the
last iteration. Only the reactive part is re-integrated with the new
coefficients (`lib/osdiinstance.cpp:1298-1305`, `1391-1420`). Devices that
use `$bound_step`, `$abstime` or breakpoints are excluded
(`lib/osdifile.cpp:211-241`). Newton always runs at least two iterations,
because the delta check is skipped at iteration 1
(`lib/nrsolver.cpp:319-320`), so the bypass removes a third to a half of all
evaluations. On c6288, with the residual check off, it cuts 63.19 s to
48.34 s (`benchmark/README.md:106-107`).

The linear solver is KLU used refactor-first. `klu_analyze` runs once per
topology with KLU's defaults (AMD, BTF, scaling, pivot tolerance 0.001;
`include/solklu.h:101-117`). Every Newton iteration tries `klu_refactor` on
the stored pivots and does a full factor only when that fails
(`lib/nrsolver.cpp:246-268`). There is no pivot-growth check. ESPice's
`direct.zig` works the same way and adds a growth monitor, so this is
parity.

Stamps go through pointers resolved once: each OSDI Jacobian entry's
address in KLU's value array is bound at setup
(`lib/osdiinstance.cpp:629-700`), and ground entries write to a scratch
"bucket", so stamping has no branches (`include/cscmatrix.h:156-170`).
ESPice's scatter tapes do the same job; its load is 20 ms of 2.9 s on
`vacask_ring`. Transient loads use `load_jacobian_tran`, which writes
G + α·C in one pass (`lib/osdiinstance.cpp:1525-1534`).

VACASK integrates charges from the last Newton evaluation and runs no
charge-only pass after acceptance. ESPice re-reads q at the solution
(`evalQ`, `tran/tran.zig:381`), which
[transient-integration.md](../analysis/transient-integration.md) measured
as a large accuracy gain on `vacask_graetz` and `vacask_mul`. On
`vacask_ring` that pass is a quarter of ESPice's evaluation calls, though a
charge-only call is cheaper than a full one.

Some costs VACASK accepts on purpose. The residual check costs 20% on c6288
(57.98 s against 48.34 s without it, `benchmark/README.md:87-88`).
Inactive-instance bypass is off by default and gains 3% when on (46.74 s).
HB uses dense blocks and hand-written O(nt³) block products
(`include/densematrix.h:682-760`).

### Where VACASK scales better

| Area | ESPice | VACASK |
|---|---|---|
| Harmonic balance | Dense Jacobian: O((n(2K+1))²) memory, O((n(2K+1))³) per Newton step. At n = 200 and K = 8 that is 3,400 unknowns, 92 MB and about 13 billion multiply-adds per iteration. Derived from the algorithm, not measured. | Sparse block matrix on KLU, or SuperLU_MT with threads |
| PAC, PXF, pnoise | One dense (2(2M+1)n)² LU per frequency | Sparse complex KLU (`lib/corepac.cpp:636`) |
| Oscillators | No autonomous PSS | Period solved with the waveform |
| Sweeps | Structural lanes cold-start from zero (`sweep/lanes.zig:32`) | Elaborated circuit, KLU symbolic analysis and last solution kept across points, first iteration bypassed (`lib/an.cpp:250-334`) |

### VACASK choices worth adopting

Ranked by expected gain. Every item changes results at roundoff or
tolerance level, and `plan/optimize.md` requires byte-identical outputs, so
each one lands behind an option, is measured on the corpus, and is recorded
as a divergence if it becomes the default.

1. Continuation bypass for transient, sweeps and homotopy. Skip the
   first Newton evaluation at each new timestep and reuse the planes of the
   last evaluation, re-stamping only the companion terms for the new α and
   history. On `vacask_ring` that is 20,740 × 18 = 373k of 1.21M Newton
   evaluations. At 1.3 µs each that is about 0.5 s of a 3.2 s run, before
   the GPU path, whose staging buffer already holds the contributions. The
   interaction with ESPice's predictor matters: VACASK starts Newton from
   the previous solution (`tran_predictor = 0`), so its bypassed iteration
   linearizes near the right point. ESPice extrapolates (`tran.zig:326`),
   and the reused planes belong to the previous point. A cleaner variant
   for ESPice: replace the charge-only `evalQ` at acceptance with a full
   evaluation at the solution, then start the next step's Newton there
   with that evaluation as iteration 1. The first iteration is then exact,
   and the extra evaluation pays for itself by removing the Newton one.
   Measure it against the predictor on iterations per step.
2. Warm-started sweep lanes. Seed lane k from lane k−1's solution
   instead of zero in `lanes.solveLanes`, and bypass the first evaluation
   as in item 1. Monte Carlo and temperature lanes move the solution only
   slightly per lane.
3. Small-matrix LU overhead: refuted (2026-10-01). 400 consecutive
   Newton matrices dumped from each deck, then `SparseLu.refactor` plus
   `solve` against KLU 1.3.8's `klu_refactor` plus `klu_solve` (SuiteSparse
   5.13, defaults, one `klu_analyze` and `klu_factor` first), the same
   values in the same order, no refactor failures on either side:

   | deck | n | nnz | ESPice µs | KLU µs | ESPice Ir | KLU Ir |
   |---|---:|---:|---:|---:|---:|---:|
   | vacask_graetz | 10 | 32 | 0.23 | 0.25 | 2,200 | 4,440 |
   | vacask_mul | 12 | 36 | 0.27 | 0.37 | | |
   | vacask_ring | 156 | 878 | 3.76 | 5.09 | 51,600 | 93,500 |
   | bench_tran_fourbitadder | 451 | 2,475 | 10.5 | 14.3 | | |

   Wall time is the mean of 200 passes at a load of 3; Ir is per call
   from callgrind, setup subtracted. ESPice's small-matrix tape (one flat
   multiply-subtract list, `refactorTape`) takes about half KLU's
   instructions, and the column path (fourbitadder, no tape) still wins
   by 1.36x. The 4.9 µs above was load. What the tiny decks did pay was
   the plane reset: a `memset`/`memcpy` call per plane per evaluation,
   now inline stores up to 64 entries (`numerics.zeroSimd`).
4. Sparse block HB with a lane preconditioner (G4 phase B). This is a
   scalability item for HB and the periodic small-signal family more than a
   speed item on today's decks.

Not worth copying: inactive-instance bypass (3% on c6288, and the GPU
path gains little from skipping threads, see
[gpu-convergence-fields.md](../solvers/gpu-convergence-fields.md) §3.2),
and VACASK's lenient LTE rejection (`tran_redofactor = 2.5` rejects only
when the step exceeds 2.5 times the LTE optimum). It explains VACASK's 1
reject against ESPice's 1,236, but VACASK then takes 26% more accepted
points, so ESPice makes fewer attempts overall.

## 4. What ESPice has that VACASK lacks

Each claim was checked against VACASK's analysis sources (`lib/an*.cpp`:
`ac`, `acsp`, `acstb`, `acxf`, `dcinc`, `dcxf`, `hb`, `hbac`, `hbnoise`,
`noise`, `op`, `pac`, `pss`, `tran`), its analysis table
(`docs/cmd-analysis-overview.md`) and a source grep.

| ESPice feature | VACASK | Evidence |
|---|---|---|
| GPU device evaluation (CUDA, HIP) | none | no CUDA/OpenCL/HIP in `lib/`, `include/`, `simulator/` or `CMakeLists.txt` |
| Multithreaded device evaluation | single-threaded by design | `CMakeLists.txt:196-212`; `docs/startup-options.md` "Parallelism" |
| Concurrent queries (`--jobs`) | control block runs in order | `docs/cmd-overview.md` "Execution model" |
| SIMD frequency lanes for AC, noise, SP, STB | one KLU refactor per frequency | `lib/coreac.cpp` |
| Pole-zero | no | not in `lib/an*.cpp` |
| Distortion (`.disto`) | no | not in `lib/an*.cpp` |
| Fourier/THD (`.four`) | no, Python postprocessing | not in `lib/an*.cpp` |
| `.meas` | no, Python postprocessing | `docs/cmd-postprocess.md` |
| DC sensitivity, DC mismatch | no | not in `lib/an*.cpp` |
| Periodic transfer function (`.pxf`) | no | no `pxf` anywhere in the source |
| Shooting-based periodic noise | HB-based only | `hbnoise` only; no noise analysis on the shooting core |
| Envelope, MATEX | no | not in `lib/an*.cpp` |
| SPICE decks as input, including `.lib` PDKs | Spectre-like native syntax; SPICE only as an include in builds with `CADNIP_PARSERS` (off by default) or via `ng2vc.py` | `docs/input-include.md:89-216` |
| Nine output formats | SPICE raw only | `docs/cmd-options-output.md` (`rawfile`) |
| Stable C ABI | C++ static library | `docs/cpp-api.md` |
| HICUM L2, HiSIM2, HiSIM-HV, BSIM-SOI, B3SOI, BSIM1/2, HFET, MESA | not shipped | `docs/dev-3rdparty.md`, `docs/dev-spice.md` |
| Lossy and coupled transmission lines (LTRA, TXL, CPL), URC | ideal line only | `devices/tline_ideal.va` |
| JFNK and pseudo-transient OP rungs | gmin and source stepping only | `lib/homotopy.cpp:8-12` |

Claims that do not hold, so do not make them:

- `.sp`: VACASK has `acsp`.
- `.stb`: VACASK's `acstb` is more complete (both loop-gain directions and
  the DUT y-parameters).
- `.tf`: VACASK's `dcxf` and `acxf` cover every source and add impedances.
- `.qpss`: VACASK's `hb` takes any number of tones.
- Transient noise: VACASK also models flicker noise.
- Runtime Verilog-A: VACASK compiles `.va` on `load` through OpenVAF.
