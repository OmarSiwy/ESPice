# Changelog

Newest first. Bullets only, one line each. Every fix cites its GitHub issue,
`(#123)`; open one first if none exists.

## Unreleased

- C API: `espice_result_view` sets `*data` to NULL and `*len` to 0 on a NULL or stale handle too; `ESPICE_CANCELLED` is documented as reserved, since no C call cancels a query (#76).
- `--format=touchstone` on an `.sp` whose ports have different z0 writes Touchstone 2.0 with each port's `[Reference]`, instead of `R 50` for all (#60).
- CLI: `-tokenizer=hspice` (single dash, joined value) works as the docs say; a streamed transient or AC run without an output path checks its row count too (#88).
- API: queries appended through `Problem` or the C API are checked as the netlist checks them: node and branch rows in range for every analysis, temperatures above absolute zero, `xmu` in [0, 0.5], `0 <= tstart < tstop`; a batch past the row space is `TooManyQueries` (#55).
- `.meas sp` measures the S-parameter plot, AT= may name an earlier result (`find v(a) at=t50`), PARAM prints six significant digits as ngspice does, and `.dout` reports running out of memory instead of a malformed card (#69).
- CSV quotes headers such as `S(1,1)_re`, PSF escapes quotes and backslashes, and CITIfile declares `VAR FREQ` and every `DATA` up front with one `BEGIN`/`END` block each, so scikit-rf reads it (#61).
- `.meas tran_cont x find v(a) at=1n` (and DERIV) prints its one value instead of looping forever (#68).
- On a GPU backend, sources, switches, transmission and delay lines, Laplace and pole filters, S-parameter and W elements, mosvar and r3_cmc evaluate on the GPU instead of the host (#139).
- On a GPU backend, MVSG devices evaluate on the CPU: their kernel's stack frame (432 KB) is over CUDA's limit, so the launch failed (#139).
- mosvar, hicumL2_va, asmesd and asmesd_dio get GPU kernels; a source-size gate that counted their whole upstream release left them out (#139).
- `--backend auto` runs a deck whose large GPU kernel the driver has not compiled yet entirely on the CPU, instead of leaving that one model on the host (#139).
- `ESPICE_THREADS` > 1 gives the same bytes as one thread: threaded device evaluation sums every stamp in the serial order, and threads claim work dynamically instead of a fixed split; device ABI 28 (#137, #138).
- `set_params` runs a point on an earlier call's circuit when it selects the same model bins, so a sizing loop that keeps crossing a bin edge holds two circuits instead of one per crossing (#129).
- Monte Carlo: a B source reading a sampled `.param` takes each trial's draw, as a resistor reading it does; it kept the nominal value (#133).
- `.step` and `set_params` points, and `.dcmatch` groups from a PDK's mismatch, keep the parameter-write path when a live value sits at zero (sky130's mismatch terms at the nominal corner) instead of rebuilding the circuit per point or per site (#130).
- `--backend cuda` stages device state at the converged iterate like the CPU, not one limit pass ahead: `tran/device_hfet_inverter` drifted 0.34% (#15).
- The bordered-block-diagonal solver refines its solves when a block is ill-conditioned and falls back to the sparse LU when refinement cannot recover them; it could lose 5 digits silently (#136).
- C API: a destroyed or foreign `espice_problem` returns the new `ESPICE_INVALID_HANDLE` instead of undefined behaviour; `espice_destroy` returns a status (#143).
- `--backend cuda` evaluates BSIM4 (LEVEL 14/54, sky130), VBIC and MOS levels 1/2/3/6/9 on the GPU: held variables and limiting now live in device state; device ABI 27 (#140).
- API: `Options.hdl_toolchain.cache_dir` sets where `.hdl` builds are cached, in place of `$ESPICE_CACHE` and its fallbacks.
- A resistor `.model` card's `TC1`, `TC2`, `TCE` and `TNOM` apply to its instances; they were ignored (#159).
- Spectre `tran` maps `method=`, `skipdc=yes|no` and `errpreset=moderate`, and refuses any other parameter by name instead of dropping it (#151).
- `.options abstol=0`, `vntol=0` and `chgtol=0` run as in ngspice; `reltol=0` and `trtol=0` fail at their card instead of as a bare `InvalidQueryOptions` (#150).
- `.tf` with a current output `i(Vx)` reports the resistance Vx sees, where it reported the negated conductance (#149).
- `.options tnom` (and HSPICE's default TNOM of 25 C) reaches R `tc1`/`tc2`; it was ignored at 27 C (#146).
- `.four` phases use ngspice's sine reference: `sin(0 1 1k)` reads 0 degrees, was -90 (#148).
- `.four` analyses the last period of the deck's `.tran` (stop time, `uic`, `.ic`) instead of its own 5-period run (#147).
- C and L instance `ic=` seeds a `.tran ... uic` start instead of being dropped (#145).
- The device layout hash covers structs held by value across the device boundary (`NoiseSource.table`); device ABI 28, so cached `.hdl` builds rebuild once (#32).
- `.hdl`/`.include` load `.vams` and `.veriloga` files, and any HDL extension in upper or mixed case, as the frontend already routed them (#34).
- `models/psp103_nqs.va` carries the PSP/CMC notice, and `models/LICENSES.md` records where `vbic13_4t` comes from (#17).
- The `.hdl` build cache keys a `.va` and a `.v` source apart, so one can no longer be handed the other's cached device (#33).
- The device layout hash covers structs held by value across the device boundary (`NoiseSource.table`); device ABI 27, so cached `.hdl` builds rebuild once (#32).
- Bench: VACASK plots pair by point count before file order, and its subcircuit nets (`x1:inner`) are scored as `v(x1.inner)` (#109).
- Bench: poles and zeros are scored as sets, and a repeated signal name (CPL/TXL port currents) is scored by its last column (#87).
- Bench: the ngspice and VACASK adapters read decks of any size, and the power-grid suite's `.spiceinit` turns on KLU (#7).
- Bench: ngspice reads a `.spiceinit` beside the deck instead of always running with `-n` (#6).
- A transient whose operating point needs OPtran (a capacitor-only node) starts from an x that satisfies KCL at
  t = 0, not from the 1 us settle's sources and timers (#53).
- Playground: espice.wasm gets a 16 MiB stack (the corpus peaks at 1.2 MiB, past the 1 MiB default), pole-zero runs with no poles and `.load`/`.vec`/`FILE=` decks report cleanly, and `zig build wasm-compare` checks it against the native espice over the corpus (#8).
- On 32-bit targets (the wasm playground) `.tran` with MATEX and envelope runs no longer fail `InvalidQueryOptions`, and Monte Carlo draws match the 64-bit build; `-Dsingle-threaded` builds and tests the playground's code paths natively (#8).
- Optimized parameters can stay on a grid: `opt1(init, lo, hi, dels, grid)`, an ESPice extension, keeps every simulated value and the result on multiples of `grid` (#95).
- An optimization whose start point fails prints the goal errors it measured, not uninitialized memory; the docs explain PARMIN for SI-unit sizing (#96).
- An LM optimization whose trial point cannot be simulated or measured fails, keeping the best point so far, instead of retrying it (#29).
- BISECTION and PASSFAIL optimization over a window near the f64 range no longer test inf as the midpoint (#30).
- A `.meas` TRIG or TARG without VAL never fires, as in ngspice (its level is 1e99, not 0) (#28).
- `.matex` starts from the transient operating point, as `.tran` does, not the `.dc` one (#27).
- `.options gmin` (HSPICE `gmindc`) is the junction shunt of the diode, BJT, JFET, MESFET, HFET, VDMOS and MOS level 1/2/3/9 devices, as in ngspice; they kept 1e-12 S (#78).
- `.tran` follows ngspice's step options: `maxord=1` is backward Euler under trap too, and the default tmax is min(tstep, (tstop - tstart)/50) (#56).
- `.options rshunt=R` adds a resistor from every node to ground, as in ngspice (#11).
- `.ac dec` ends on `fstop` as ngspice does (`.ac dec 3 10 730` ends at 730), and `lin N f f` is one point (#26).
- `.ac`, `.noise` and `.tf` on a small circuit with a disabled device branch (HICUM/L2 with RBX, RE and RCX at 0) run instead of failing `Singular` (#160).
- MOS level 3 and 9 report channel thermal noise; with RD/RS absent only the load resistor's noise was reported (#155).
- MOS level 2 takes NLEV (default 2) and GDSNOI, so its flicker noise matches ngspice 45 instead of the spice3 form, 670x high on a 10 um device (#156).
- BSIM2 (LEVEL=5) with RSH = 0 gives the right `.ac`, `.tf` and `.sens` gain; a 1e12 S stand-in short had rounded gds to 1.2e-4 S (#157).
- A MOS level 6 card with neither KC nor TOX keeps KC = 5e-5 and conducts, as in ngspice (#158).
- Under a GPU backend, refactors of 50M multiply-adds or more (100k-transistor post-layout netlists) use the device LU by default (#141).
- The device LU has no 400M multiply-add cap; an epoch whose tables do not fit in host or device memory stays on the host LU (#141).
- The device LU's triangular solves run across the whole GPU: 4x faster on a 100k-transistor post-layout chain, where the device LU now beats the host LU (#141).
- API: `Options.display` (a `*std.Io.Writer`) and C `display` + `display_user` (a callback) receive `.hdl` display-task lines instead of stdout (#127).
- C API: `.hdl` models compile from a C handle; its Io had no allocator or environment, so the build failed as `CompilerGone` (#127).
- The column ordering compacts its workspace, so patterns from n = 2000 no longer fail with `OutOfWorkspace`, and keeps the natural order where AMD would fill more (#46).
- The tridiagonal engine hands a pivot under 1e-3 of its column to the pivoting LU, a zero pivot tolerance no longer accepts a zero pivot, and a capped re-pivot keeps no old pivot the refactor would refuse (#45).
- Frequency solves (AC, noise, S-parameters) re-pivot when a replayed pivot falls below 1e-3 of its column, where pivots down to 1e-12 were accepted (scaled residuals up to 8e3) (#44).
- `FreqSolver.factorEach` on sparse systems holds a frequency whose A(ω) is singular instead of failing with `SingularMatrix`, and holds only the frequencies no pivot tape replays (#43).
- The per-frequency block factorization (`FreqSolver.factorEach`) holds a singular dense block as the identity instead of reading undefined pivots, and an empty system solves nothing (#42).
- FFT spectra stay within a few eps of N per bin on long transforms; a 2^20-point transform had drifted to 9e3 eps (#41).
- `ESPICE_SOLVER=jfnk` keeps the direct Newton contract: a residual past 1e154 still takes its step, the device load test gates acceptance, and gmin goes only where the gmin-stepping rung stamps it (#31).
- GMRES (the PSS and QPSS Krylov solves) never reports convergence on an infinite right-hand side, and solves right-hand sides near 1e300 or 1e-200 instead of returning zero (#40).
- Debug builds evaluate B-source `abs`, `min`, `max` and `?:`, and model conditionals on device values, as release builds do; Zig 0.17's self-hosted backend took the true arm at a zero condition (#25).
- A `.step` whose every point needs its own circuit runs just those points, instead of writing past the query table (#132).
- Running out of memory during a transient, PSS, HB, DC homotopy or sweep step reports `OutOfMemory` instead of a convergence failure such as `TimestepTooSmall` (#134).
- A run whose implicit operating point fails reports that failure, not `DependencyFailed` (#135).
- `.tran` with MATEX fails the step instead of hanging when the Krylov matrix overflows to inf (#125).
- Device evaluation no longer copies a deduplicated model row onto itself, undefined behaviour in release builds (#122).
- Third-party compact models are built from their upstream releases, unmodified, pinned by link and hash in `build.zig.zon`: PSP 103.8.2/104.1, JUNCAP2, BSIM-IMG, BSIM-CMG, BSIM-BULK, BSIM-SOI 101.0, L-UTSOI, HiSIM_HV/SOI/SOTB, HICUM/L2 3.2 and L0, Mextram 505.6, ASM-HEMT, ASM-ESD, MVSG, DIODE_CMC, R2/R3_CMC and MOSVAR; new LEVELs 72/76/77/78 (M), 6 (Q, D) and OSDI module names on `.model`.
- `.noise` reads a `ddx()` inside a Verilog-A noise power (a channel noise's gm) instead of 0: MOS3, MOS9 and JFET2 channel noise now match ngspice (#119).
- `.hdl` Verilog-A, VerA pin df3bd51d -> 7971b23e: a `$simparam` used as a parameter default answers per LRM 9.15 instead of reading 0 (VerA#51).
- `.noise` reads a `ddx()` inside a Verilog-A noise power (a channel noise's gm) instead of 0: MOS3, MOS9 and JFET2 channel noise now match ngspice (#119).
- `.hdl` Verilog-A, VerA pin 53e61b89 -> df3bd51d: `ddx()` inside a noise power reads its partial in
  `noisePsd` (VerA#32), `$port_connected`/`$param_given` may control analog operators (VerA#33).
- `.hdl` Verilog-A devices with more than 64 unknowns compile and run (dense Jacobian, one
  derivative lane per unknown) (#117).
- `bench-suites -Dsuite=cmcqa`: the HICUM and PSP noise tests, one `.noise` deck per bias point (#18).
- `bench-suites -Dsuite=cmcqa`: the GF180 Rds, MOS CV, BJT, diode, MIM/MOS capacitor and resistor regressions, 2,234 more decks (#18).
- `bench-suites -Dsuite=cmcqa`: PSP parameter cards keep their exponent signs (`NSUBO=3.0E+23` was read as `3.0E`) (#18).
- `zig build test-gpu` runs one deck at a time; eight concurrent CUDA contexts ran latency-bound decks 9x slower and into the timeout (#15).
- `.dcmatch`, `.acmatch` and `.dcsens` without a `.variation` block read a PDK's mismatch from the `agauss`-style calls in its models; sky130 fell back to unit variance, now a warning when nothing else applies (#100).
- A `.variation` sigma may be an expression over `.param`s and the device's `w`, `l` and `m`, for Pelgrom scaling per device (#100).
- A `MONTE=` sweep draws the `agauss`/`gauss`/`unif`/`aunif` calls inside `.model` cards per trial; sky130's
  `*_mm` mismatch ran nominal in every trial (#100).
- `OPTIMIZE=` under `--jobs` above 1 runs each trial point with its Jacobian points in one round, same
  output: a 128-stage chain fit 1.81 s to 1.71 s, `rc_delay_fit` 13.9 to 10.1 ms at `--jobs=3` (#97).
- `OPTIMIZE=` on a `.dc` card takes its Jacobian from direct sensitivities of the trial point's own sweep, not one sweep per parameter: a two-parameter common-source fit 2.5x fewer instructions, 7 iterations instead of 16 (#97).
- `OPTIMIZE=` starts each point's operating point from the one of the iterate its step left: a 32-stage chain fit 3.6% fewer instructions (#97).
- API: `Options.live_params` + `Problem.set_params`, and C `live_params` + `espice_set_params`, change
  global `.param` values on a live Problem without a re-parse: a sky130 sizing point 6 ms, was 87 (#101).
- A binned MOSFET whose L/W reads a swept or set `.param` takes the bin each point selects, on its
  own circuit, where `.step` used to refuse it (#101).
- `.vec`: VNAME names fill bits (`radix 144`, `<[4:1]>` groupings), V1, V2... without VNAME, `tunit 2 ns`,
  IO `u`, TSKIP, Z on outputs; SLOPE defaults to 0.1 ns, VOH/VOL replace VTH, plain numbers only (#121).
- `--tokenizer=spectre` reads Spectre netlists: a title line, instances, `parameters`, `model` groups,
  `subckt`, functions, `if`/`else`, `include ... section=`, `simulator lang=spice` regions, tran/dc/ac/noise (#121).
- HSPICE lines: a `$` line, `$` after a number or comma, and quoted `$` read as HSPICE does; ` \`
  continues with a blank, `\\` without; a commented line no longer continues (#121).
- ngspice lines: `#`/`;` comment lines, `//` and quote-aware `;`/`$` comments, `\\` joins, `@` and a stray
  `+` as ngspice reads them; cards after `.end` are read (#121).
- Numbers take the `a` (atto) suffix and the `d` exponent; expressions take `%`, `\`, `<>`, `.func`
  and `.param f(x)=`, and 13 more numparam functions; `.macro`, `.parameters`, `.temperature` (#121).
- Nested `.subckt` definitions flatten; a diode's thermal node is read; Touchstone and RLGC files
  are checked as their specs say (option line, record counts, conductor count) (#121).
- `.data` MER/LAM files resolve through `.option search=`, skip `*`/`$` lines and refuse a cell that
  is not a number; `.load` defaults to the top deck's `.ic0`, and `FILE=x.ic` means `x.ic0` (#121).
- `.hdl` models print their `$strobe`/`$display`/`$write`/`$warning`/`$info` lines to
  stdout once per accepted point (OP, DC point, transient step), `%m` as the instance (#102, device ABI 26).
- API: `Options.hdl_toolchain`, and C `espice_create_options.zig_path`/`share_path`, set the
  Zig compiler and `share/espice` directory `.hdl` builds use; empty keeps `$ZIG` (#13).
- `.hdl`: a source named more than once (several `.lib` sections) compiles once per deck.
- API: `Problem.ready_queries` and `copy_result` fail with `error.BufferTooSmall` on a short
  buffer (`ready_count` gives the size); GPU backend messages go through `std.log` (#13).
- `.dc <param> start stop step` sweeps a `.param` (HSPICE `.DC`), with the parameter as
  the plot axis (#94).
- `.sens` names its columns as ngspice does: only R, C, L, V and I have a bare principal
  column, so a diode IS is `v(d1:is)`; the multiplier column is `v(r1_m)` (#71).
- A device whose `limit` keeps Newton history (a generated `$limit` with state) no longer
  converges its OP to the limited image: the INITFIX pass does not stage state (#53).
- `.hdl` Verilog-A, VerA pin 2692a15b -> 53e61b89 (GitHub main, package 0.9.0): 164
  upstream commits (connect modules on primitives, wide regs, $fdebug/$debug per iteration,
  absdelay revert, deep-nesting limits).
- `.matex` no longer returns NaN on stiff circuits: a round-off Krylov breakdown is caught,
  and a step that needs more than `m_max` vectors or comes out non-finite fails with
  `MatexDidNotConverge` (#51).
- VBIC decks are checked against VACASK running the VBIC 1.3 reference Verilog-A; the
  ngspice VBIC 1.2/45 differences (avalm, excess phase, noise density total) are recorded
  in dev/devices/models.md (#16, #86).
- MOS1 has noise (RD/RS, channel per NLEV with GDSNOI, flicker per NLEV, KF/AF); MOS3 takes
  mos3noi.c's NLEV forms; BSIM4 matches ngspice 45's default NOIC (8.75e9), clamps the
  flicker DelClm and the tnoiMod=1 npart_theta, and scales Rd/Rs noise as b4noi.c does;
  `.noise` with a current-source input names its total `i(inoise_total)` (#84, #80).
- BSIM4 at exactly zero bias keeps its junction capacitance and the dVdseff/dVd partial
  (gds and the channel cap at vds = 0); HFET2's gds at vds = 0 is no longer 0 (#47).
- `m=` multiplies every device: on models without an `m` of their own (BSIM4, BSIM-SOI,
  HICUM, HiSIM) and where `m` is a shape (diode grading, HFET/MESA knee) it is the
  instance's `$mfactor`, scaling every stamp, charge, AC term and noise source; BJT and
  JFET2 junction gmin and BSIM2 channel noise scale with m as in ngspice (#48).
- Source stepping in the operating-point ladder scales the independent V and I sources;
  it ran at full sources before, so a deck that only source stepping solves failed (#104).
- The JFET channel no longer runs `limvds`, which clamped a negative vds even at the fixed
  point (inverse mode read 1.225 mA for 0.625); limited values within a few ulps of the
  iterate are the iterate, so converged points skip the limiting correction (#49).
- MOS levels 1-9 match ngspice 45 on card spellings and temperature: `U0`/`UO` on every
  level, `DELVT0` on 3 and 9, instance `temp=`/`dtemp=` on 1, 2, 6 and 9, MOS6 `TNOM` in
  degC, `LAMBDA0=0` kept, PHI from ni(TNOM) on 3 and 9, MOS2 VMAX with the TNOM mobility (#114).
- A bare number after a Q, D, J or Z card's model name is the area, as ngspice reads it (#113).
- Diodes take `area`, `pj`/`perim`, `jsw`/`ns`, `cjp`/`php`/`mjsw`/`fcs`, `ikr`, LEVEL=3
  `w`/`l`/`xw` and plate caps, instance `temp`/`dtemp`, and the reverse cubic tail; JFET2
  follows the circuit temperature and drops a drain-source gmin ngspice lacks (#79).
- LTRA, TXL and CPL runs whose delay spans more accepted points than the history holds
  (8192 LTRA, 2048 TXL/CPL) keep the entries the delay still reads; a full history drops
  the point that loses least instead of the oldest live one (#105).
- `.hdl` Verilog-A, VerA pin v1.0.0 -> 2692a15b: an instance port may connect a bit- or
  part-select of a vector net (`.d0(r[0])`, `.d(bus[7:4])`, `r[i +: 4]`), which was E0906;
  a `$table_model` capture is kept only from an accepted iteration (VerA VD-095), not from
  the first Newton iterate; a VAMS 2.x `{...}` laplace/zi coefficient vector is refused
  (E0572: write `'{...}`) (#116).
- An operating point whose Newton ran away (node voltages near 1e24 V) is
  refused instead of being published with exit 0; the ladder falls through to
  gmin stepping (#3).
- `zig build wasm`: espice.wasm (CPU, single-threaded, built-in models) and
  cktimg.wasm for the docs playground; `docs/playground.md` runs every spice block.
- Nix flake: `nix run github:OmarSiwy/ESPice`, `packages.espice` (CPU) and
  `espice-cuda` (CUDA), `overlays.default`, smoke `checks`; CI pushes builds
  to the `omarsiwy` Cachix cache.
- User documentation at https://omarsiwy.github.io/ESPice/: a SPICE tutorial,
  the CLI, dialect and card reference, analyses, devices, output, GPU, errors,
  the C API and the benchmarks, with runnable examples in `docs/examples/`.
- `zig build c-example` builds and runs the C API example; the package exports
  `libespice` as a named lazy path for Zig consumers.
- The developer design notes moved from `docs/` to `dev/`.
- `.hdl` parameters named with `__`, a leading or trailing `_`, or a capital
  `Z` bind from the instance card instead of failing as unknown (#2).
- `bench-suites -Dsuite=cmcqa`: 3,218 single-device decks from the public CMC QA
  sets (HICUM/L2 2.4.0, PSP 103) and the GF180MCU BSIM4 regression, each with
  its reference results.
- `bench-suites -Dsuite=circuitsim90`: the 43 MCNC CircuitSim90 decks (MOS2,
  MOS3, BJT; up to chip2) from Xyce_Regression, converted to ngspice dialect.
- `bench-suites -Dsuite=ngspice`: 353 decks from ngspice-45's `tests/` and
  `examples/` and the Quality-page archives (paranoia, ISCAS85 on PTM 45 nm
  BSIM4, KiCad).
- `bench-suites -Dsuite=powergrid`: IBM power grids (ibmpg1-3, ibmpg1t) and
  SRAM-PG ssram with their reference solutions; `POWERGRID_LARGE=1` adds
  ibmpg4-8, ibmpg2t-6t and the multi-million-node SRAM-PG designs.

## 1.0.0 (2026-10-05)

- Zig 0.17.0. VerA (by its `v1.0.0` tag), Gompute and stdpp are pinned by git
  URL and content hash; `zig build --fork=<path>` builds against a local checkout.
- Licensed Apache-2.0. Models keep their own licences; see
  `models/LICENSES.md` (`bsim4va` is CC-BY-NC).
- stdpp pipelines carry the hot elementwise loops again, each with a scalar
  oracle test.
- Noise: table generators, `PsdTerm.coeff`, to-ground generators and
  correlated sources work in every noise analysis (device ABI 24).
- Verilog-A models see the stepped gmin and source scale during operating-point
  homotopy (`$simparam`), a documented divergence from ngspice.
- Verilog-A internal nets publish as `v(<instance>#<net>)` (device ABI 25).
- `--backend cuda|hip` fails, naming the detected hardware, instead of falling
  back to the CPU; `auto` still falls back.
- GPU instance sync merges host and device changes, so a parameter written
  after a GPU eval survives.
- C API: argument errors return `ESPICE_INVALID_ARGUMENT`.
- sky130 PDK decks run as written; PWL sources past 64 points chain instead of
  truncating; an OSDI card is an error naming the `.hdl` card to use.
- BSIM4 gets ngspice-style voltage limiting.
- A transient that ends within 100 ulps of `tstop` finishes, as in ngspice.
- About 90 hardening fixes across the parser, solvers, analyses, output and
  device loader (overflows, NaN guards, leaks, crashes on malformed decks),
  with over 300 new unit tests. Corpus: 797 of 799 decks pass.
- `zig build bench` passes each deck's dialect and reads empty plots;
  `test-gpu` skips decks with nothing GPU-eligible. README benchmark charts
  against ngspice and VACASK.
- `zig build bench-suites` fetches external SPICE suites at pinned revisions
  (`tests/suites/`) and benches ESPice against ngspice and VACASK on them.
- Release CI installs Zig 0.17.0 instead of 0.16.0, and the tarballs ship
  `LICENSE` and `CHANGELOGS.md` (#1).
- Removed `ref/` (SIMD notes and the standalone `verify.zig`) and `.agents/`;
  SIMD differential tests live in each module's `zig build test` suite.
