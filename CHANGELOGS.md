# Changelog

Newest first. Bullets only, one line each. Every fix cites its GitHub issue,
`(#123)`; open one first if none exists.

## Unreleased

- Debug builds load `.hdl` Verilog and Verilog-A devices instead of panicking in `Thread.spawn` (#24).
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
- Debug builds evaluate B-source `abs`, `min`, `max` and `?:`, and model conditionals on device values, as release builds do; Zig 0.17's self-hosted backend took the true arm at a zero condition (#25).
- A `.step` whose every point needs its own circuit runs just those points, instead of writing past the query table (#132).
- Running out of memory during a transient, PSS, HB, DC homotopy or sweep step reports `OutOfMemory` instead of a convergence failure such as `TimestepTooSmall` (#134).
- A run whose implicit operating point fails reports that failure, not `DependencyFailed` (#135).
- `.tran` with MATEX fails the step instead of hanging when the Krylov matrix overflows to inf (#125).
- Device evaluation no longer copies a deduplicated model row onto itself, undefined behaviour in release builds (#122).
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
