# Public SPICE benchmark suites for an ngspice-vs-ESPice comparison

Survey date: 2026-10-05. Every URL below was fetched on that date unless it
is marked **unverified**. "Fetched" means the page or archive returned 200
and, for the suites ranked below, the archive was downloaded or the repo
cloned and its contents listed.

What ESPice already has, for the "adds" lines:

- `tests/fixtures/**`: 799 decks with ngspice-produced `expected.json`,
  mostly small and written for one feature each. It already contains VACASK's
  `rc`, `ring`, `mul` and `graetz` benchmarks (`tests/fixtures/stress/vacask_*`)
  and synthetic scaling decks (RC ladders up to 100k, resistor grids,
  inverter chains up to 4k).
- `tests/benchmark/postlayout/gen.py`: synthetic post-layout decks.
- `tests/benchmark/postlayout/fetch.sh`: ISCAS85 c7552 on sky130 and on IHP
  SG13G2 (from ngspice's `skywater-examples.7z` and `IHP-c7552_ann.7z`),
  plus the iic-jku TT06 TDC magic extraction.
- Built-in models that QA decks can exercise: PSP 103.7, HICUM/L2 2.4.0,
  VBIC 1.3, HiSIM2 3.2, HiSIM-HV, BSIM4 (`models/`).

## Ranked recommendation

1. **ngspice's own decks: `tests/`, `examples/`, and the Quality-page
   archives** (paranoia, ISCAS85 on PTM 45 nm, KiCad test circuits).
   Native dialect, Modified-BSD so they can be vendored, a few hundred real
   decks across every analysis ngspice has, and the ISCAS85 set is a
   ready-made size ladder (261 to 3,624 gates) for wall-time scaling on BSIM4.
   No conversion, and the oracle is the simulator being compared against.
2. **Xyce_Regression, CircuitSim90 and device-QA subsets.** The only place
   the MCNC/CircuitSim90 netlists can still be downloaded (43 decks, MOS2,
   MOS3 and BJT, up to `chip2` at 46,850 unknowns). The PSP103, HICUM and
   VBIC13 directories also carry CMC `.standard` reference data. Light
   conversion. GPL-3.0, so fetch at a pinned commit and don't vendor.
3. **IBM power grid benchmarks (Nassif) plus SRAM-PG.** Real extracted
   linear grids from 30k to 1.67M nodes (IBM) and 76k to 5.9M nodes
   (SRAM-PG, Apache-2.0), DC and transient, each with a published solution.
   Plain SPICE that ngspice reads as is. They test the sparse solver and
   transient stepping on real topology at sizes the synthetic `gen.py` decks
   only imitate.
4. **CMC QA decks for the models ESPice ships**: HICUM/L2 2.4.0 (public QA
   setup and results that match ESPice's model version exactly), PSP 103.3
   (public CMC reference data, older than ESPice's 103.7), and the GF180MCU
   `fd_pr` ngspice regression (Apache-2.0, foundry reference data). They test
   device accuracy against an oracle that is not ngspice, so they can tell
   apart "ESPice differs from ngspice" and "ESPice is wrong". The `qaSpec`
   files need a small generator to turn them into ngspice decks.
5. **IEEE P2427 / Infineon `adsbenchmark`.** Five medium-size analog and
   mixed-signal blocks (bandgap, LDO, PLL, SAR ADC, MIPI-like PHY) on PTM
   BSIM3 models with Verilog-A checkers. Nothing else on this list is a
   realistic analog block with Verilog-A in the testbench. HSPICE dialect
   with Spectre-syntax model includes, so moderate conversion. MIT licence
   at the repo level, but the file headers say "All rights reserved"
   (see that section).

Not ranked: the VACASK benchmark set (four of its five top-level circuits are already
in the corpus, and c6288 is also in ngspice's ISCAS85 set, but its README is
the best published ngspice timing methodology to copy), gnucap and
Qucs-test (foreign dialects, low yield), TAU/ISPD contests (no SPICE decks of
their own, or the decks are IBM PG again), and Spectre/HSPICE demo decks
(not public).

---

## 1. ngspice tests, examples and Quality-page archives

- **URLs**
  - Repo: `https://git.code.sf.net/p/ngspice/ngspice` (cloned at
    48f34a8b, 2026-10-02); browse at
    https://sourceforge.net/p/ngspice/ngspice/ci/master/tree/tests
  - Quality page: https://ngspice.sourceforge.io/quality.html
  - Archives: https://ngspice.sourceforge.io/tests/paranoia.7z (1.0 MB),
    https://ngspice.sourceforge.io/tests/iscas85Circuits.7z (0.9 MB),
    https://ngspice.sourceforge.io/tests/kicad-test-circuits.7z (2.9 MB),
    https://ngspice.sourceforge.io/tests/paranoia_parallel.7z
- **Contents**
  - `tests/`: 114 `.cir` decks with 108 `.out` reference outputs, by device
    (bsim1-4, bsim3soi*, bsimsoi, hisim, hisimhv1/2, hfet, jfet, mes, mesa,
    mos6, vbic) and analysis (filters, polezero, sensitivity, transient,
    transmission, resistance), plus `tests/regression/` (parser, subckt
    and lib processing, func, temper, pz, sens, model) and xspice.
  - `examples/`: 731 files: cider, xspice, digital, measure, Monte_Carlo,
    noise, transient-noise, optran, rf, soa, TransmissionLines, vdmos, vbic,
    osdi, `IHPOpenSourcePDK` (19-stage ring oscillator, c7552 on IHP),
    `SkywaterOpenSourcePDK`, and `klu/Circuits/85`, the ISCAS85 set.
  - ISCAS85 (`examples/klu` and `iscas85Circuits.7z`, same content):
    c432, c499, c880, c1355, c1908, c2670, c3540, c5315, c6288, c7552, each as
    a plain and an annotated (`_ann`) netlist. 261 to 3,624 standard-cell
    instances over a 143-transistor cell library, PTM 45 nm HP BSIM4
    (level 54, version 4.7), `.tran 1ps 1ns`, pulse inputs. Generated by
    `spicegen.pl` (Jingye Xu, UIC). Several decks set `GMIN` as high as
    1e-4, so compare both simulators under identical options and don't read
    the waveforms as physically meaningful.
  - `paranoia.7z`: 209 netlists in 19 directories (cider, control_structs,
    delta-sigma, digital, measure, memristor, Monte_Carlo, optran, pll,
    pton, transient-noise, TransImpedanceAmp, TransmissionLines, vbic,
    vdmos, xspice and others), driven by `paranoia_test.sh` under valgrind.
  - `kicad-test-circuits.7z`: 9 KiCad projects, 17 schematic and netlist files (op-amps,
    Sallen-Key, rectifier, laser driver, GaN, PSpice-model imports).
- **Licence**: Modified BSD for source, tests and examples (`COPYING`),
  except KLU (LGPL-2), XSPICE (public domain) and numparam (LGPL-2). The
  paranoia script header says "License: New BSD". Vendoring into Apache-2.0
  is fine with the BSD notice kept. The ISCAS85 decks and the PTM 45 nm card
  carry no licence of their own: `fetch.sh` already treats ISCAS as
  fetch-only, so do the same here.
- **Dialect**: ngspice. Control blocks (`.control`/`.endc`) are common in
  `examples/` and paranoia and need ESPice's control-language support or a
  split into analysis cards.
- **Oracles**: `tests/*.out` are text dumps from an older ngspice build;
  regenerate them with the pinned ngspice instead. Examples and paranoia
  carry none; ngspice itself is the oracle.
- **Maintained**: yes; last commit two days before this survey, and the
  Quality-page archives resolve.
- **Effort**: low. Point the existing ngspice oracle harness at the files;
  sort decks into pass, refuse (control-heavy, XSPICE digital, CIDER) and
  KNOWN GAP. ISCAS85 drops straight into `zig build bench`.
- **Adds**: real user-style decks instead of single-feature fixtures; a
  BSIM4 size ladder on one technology (the existing c7552 decks are one
  size); XSPICE, CIDER, measure and Monte Carlo decks that show where
  ESPice refuses. Check overlap first: some fixtures were already derived
  from ngspice tests (`tests/fixtures/regression/bsim4.out`).

## 2. Xyce_Regression (including CircuitSim90 / MCNC)

- **URL**: https://github.com/Xyce/Xyce_Regression (cloned at bbde4027,
  2026-08-10). Docs:
  https://xyce.sandia.gov/documentation-tutorials/running-the-xyce-regression-suite/
- **Contents**: 13,067 files, 4,113 `.cir` netlists, gold outputs in
  `OutputData/` (3,320 `.prn`/`.gs` files), Perl and CMake harness. Largest
  directories: Certification_Tests (bug regressions, 3,265 files), Output,
  XDM (HSPICE/Spectre/PSpice translation tests), MEASURE*, SENS, YLIN, PCE,
  MIXED_SIGNAL, HB, homotopy, LTRA, NOISE, FOURIER, and per-model directories
  (BSIM3/4/6, BSIM-CMG 108/110/111, BSIMSOI3, PSP102/103, HICUM, MEXTRAM,
  VBIC13).
  - `Netlists/CircuitSim90/`: the MCNC CircuitSim90 suite with
    `circuitsim93.pdf`. 43 decks: `BJT/vreg`; `MOS2/` (ab_ac, ab_integ,
    ab_opamp, cram, e1480, g1310, gm6, hussamp, mosrect, mux8, nand, pump,
    reg0, ring, schmitfast, schmitslow, slowlatch, toronto); `MOS2_LARGE/`
    (add20, add32, chip2, dac, fadd32, mem_plus, pc_frame, pchip, ram2k,
    smult20, sqrt, sram, voter, voter25); `MOS3/` (arom, gm1-gm19, jge,
    mike2, rich3, todd3). The README gives sizes, from small up to `chip2`
    at 46,850 unknowns and 18,816 MOS2 devices, and notes which ones need GMIN
    stepping or take hours. That makes them a convergence suite as well as
    a size ladder. Most have Xyce `.prn` gold output.
  - `PSP103/`, `HICUM/`, `VBIC13/`: CMC QA-derived decks with `.standard`
    reference files from the model developers.
- **Licence**: GPL-3.0-or-later (repo README; Sandia/NTESS copyright).
  The CircuitSim90 netlists predate that and have no licence of their own.
  Don't vendor into the Apache-2.0 tree: fetch at a pinned commit, the way
  `fetch.sh` handles ISCAS.
- **Dialect**: Xyce. The CircuitSim90 decks are close to SPICE2/3; seen
  changes are `.options timeint ...`, `{v(2)+2.0}` expressions in `.print`,
  and Xyce `.print` formats. Elsewhere expect `.STEP`, `YLIN`, Xyce
  `.OPTIONS` blocks and Xyce-only devices; most non-CircuitSim90
  directories test Xyce features and aren't worth converting.
- **Oracles**: Xyce `.prn` gold and CMC `.standard` files. For the
  ngspice-vs-ESPice comparison, regenerate with ngspice and keep the Xyce
  gold as a third opinion where they disagree.
- **Maintained**: yes (pushed 2026-08-10; history re-rooted at 7.9).
- **Effort**: low to medium for CircuitSim90 (a sed-level translator plus
  `.save` for the expression prints); medium for the CMC directories; high
  and not worth it for the rest.
- **Adds**: the historical stress suite (MOS2/MOS3 convergence, 10k to 50k
  unknowns), with device models ESPice's corpus covers only in small decks.
  The original NCSU host is gone (see section 12).

## 3. IBM power grid benchmarks (Nassif, ASP-DAC 2008) and SRAM-PG

- **URLs**
  - Primary: https://web.ece.ucsb.edu/~lip/PGBenchmarks/ibmpgbench.html,
    files under `.../PGBenchmarks/ibmpg/` (README.txt, MD5SUMS.txt,
    `ibmpg1.spice.bz2` 350 KB, ...). Mirror:
    https://github.com/thesukantadey/IBM_power_grid_benchmarks (no licence,
    includes the paper PDF).
  - SRAM-PG: https://github.com/ShenShan123/SRAM-PG (Apache-2.0, git-lfs;
    paper arXiv:2404.05260).
  - THU PGBench (thupg1-10, 5M to 60M nodes, "compatible with IBM PG"):
    https://tiger.cs.tsinghua.edu.cn/PGBench/index.html, **unverified**
    (connection refused on every attempt; known only from search snippets
    and citing papers).
- **Contents**
  - IBM: DC ibmpg1-6 (30,638 to 1,670,494 nodes) with `.solution` files
    and voltage-map GIFs; ibmpg7/8 (about 1.46M nodes, no solution);
    transient ibmpg1t-6t with `.output` files. ibmpg1 is R, V (vias and
    pads as 0 V sources) and I, ending in `.op`. ibmpg1t adds C and L,
    pulse current sources, `.tran 1e-11 1e-8`, and `.print` of 20 probe
    nodes.
  - SRAM-PG: four SRAM post-layout PDNs (SSRAM 76k nodes; Ultra8T, Sandwich
    and SP8192W at 4.5M to 5.9M nodes and up to 10M resistors), DC and
    transient netlists, each with a solution file.
- **Licence**: IBM files carry none; the UCSB page says "All rights
  reserved". Fetch, don't vendor. SRAM-PG is Apache-2.0 and vendorable,
  though at hundreds of MB it belongs in a fetch script anyway.
- **Dialect**: plain SPICE that ngspice reads. The transient pulses use
  comma-separated arguments (`pulse(2.18e-05, 0.0547, 2e-10, ...)`).
  `.opti nopage acct` and `.width out=512` are SPICE2 leftovers to strip or
  ignore.
- **Oracles**: yes, both suites. The IBM DC solutions are given to 5
  significant digits; the TAU 2011 contest scored at 0.1 mV.
- **Maintained**: frozen datasets, still downloadable (UCSB page updated
  March 2020; SRAM-PG pushed April 2024).
- **Effort**: low. Fetch and decompress; for scoring, a parser for the
  `node value` solution format; at the top sizes, check that both
  simulators' parsers and memory hold up (ibmpg6 alone is around 1.7M
  nodes).
- **Adds**: real (not generated) grid topology, a non-ngspice oracle, and
  sizes one to two orders of magnitude past `scaling_rc_ladder_100k`.
  Linear only, so it measures parse, assembly, ordering, factorization and
  the timestep loop, not device evaluation.

## 4. CMC model QA decks

The CMC QA process (spec: "CMC Compact Model QA Specification" release 1.3,
2007, https://nanohub.org/groups/needs/File:cmcQa_release1.3_2007Jun21.pdf)
describes each test in a simulator-neutral `qaSpec` file (pins, bias
sweeps, temperatures, outputs, model-parameter files) and ships reference
results as `*.standard` tables. Turning a `qaSpec` into ngspice decks takes
a small generator; CMC's `runQaTests.pl` does that, but no public
standalone copy was found (**unverified**).

| Model | Public QA? | Source | Fit with ESPice |
|---|---|---|---|
| HICUM/L2 | Yes: v2.4.0, v2.34, v2.33, v2.32, v2.31 setups and results | https://www.iee.et.tu-dresden.de/iee/eb/hic_new/hic_modtest.html; e.g. `.../forsch/Models/qa_setup_hicumL2V2p4p0.zip` (15 KB: `qaSpec` + 13 parameter sets) and `qa_results_hicumL2V2p4p0.zip` (2.8 MB, 182 `.standard` files: DC, AC, noise, 6 temperatures) | Exact version match with `models/hicumL2_va.va` (2.4.0). Best single QA target. |
| PSP | Yes for 103.2/103.3 only | https://www.cea.fr/cea-tech/leti/pspsupport/Pages/CurrentRelease.aspx; `Documents/Level%20103.3.3/psp_VA_and_CMC_ref_data.tar.gz` (7,580 files, 16 `qaSpec`, sym/asym n/p, with and without self-heating) | ESPice ships 103.7. Current releases (103.8.x tarballs) contain Verilog-A code only. Run the 103.3 QA against a 103.3 build, or use the Xyce PSP103 decks. |
| BSIM4, BSIM-CMG | No | https://bsim.berkeley.edu/models/bsim4/, https://www.bsim.berkeley.edu/models/bsimcmg/; the BSIM4 4.8.2/4.8.3 and BSIM-CMG 112.1.0 tarballs hold code and manuals only | ECL-2.0 code. No reference results; ngspice is the oracle. Xyce has BSIM4/BSIM-CMG directories. |
| VBIC 1.3, Mextram 505 | Members only | Mextram: https://www.eng.auburn.edu/~niuguof/mextram/codes/index.html (QA suite for CMC members) | Xyce `VBIC13/` (90 files) and `MEXTRAM/` are the public substitute. |
| HiSIM2 / HiSIM-HV | Not checked in depth | https://www.hisim.hiroshima-u.ac.jp/ (registration) | ngspice `tests/hisim*` decks exist. |
| GF180MCU devices | Yes, against foundry data | https://github.com/google/globalfoundries-pdk-libs-gf180mcu_fd_pr, `models/ngspice/testing/` | See below. |

GF180MCU `fd_pr` regression: Apache-2.0. ngspice regression runners for MOS
IV/CV, BJT beta/IV/Cj, diodes, MIM and MOS caps and resistors, compared
against `180MCU_SPICE_DATA` (foundry-simulator reference tables as `.xlsx`
and `.nl_out`), plus a standard-cell `sc_regression` (inverter, nand, ...)
and a smoke test. The models are BSIM4 and the netlists are ngspice. It needs
Python plus the xlsx data; an adapter that emits ESPice-runnable decks is
medium effort. It adds a second process (GF180) beside sky130 and IHP, with
foundry reference data instead of ngspice.

- **Dialect**: `qaSpec` is neutral; the generated decks would be ngspice.
- **Licence**: HICUM QA zips and PSP QA data carry no Apache-compatible
  grant (PSP ships an `IP_NOTICE_DISCLAIMER_LICENSE` in its vacode; read it
  before vendoring anything). Fetch, don't vendor. GF180 is Apache-2.0.
- **Effort**: medium. A `qaSpec` to `.sp` generator (bias sweeps, `biasList`
  outer loops, temperatures, AC and noise tests), then a table comparison
  against `.standard` files at CMC's tolerances.
- **Adds**: device-level accuracy against developer reference data, across
  temperature and self-heating. The corpus checks devices only against
  ngspice, whose own Verilog-A or C ports can be the thing that is wrong.

## 5. IEEE P2427 analogue benchmark circuits / Infineon `adsbenchmark`

- **URLs**: https://sagroups.ieee.org/2427/analogue-benchmark-circuits
  (fetched; direct curl returns 403 to non-browser agents);
  https://github.com/Infineon/adsbenchmark (v4.0, pushed 2022-06-24).
  Older v2.2 (ams 350 nm, ITC 2017):
  `https://sagroups.ieee.org/2427/wp-content/uploads/sites/302/2019/03/analog_benchmark2017_v2.2.tar_.gz`,
  **unverified** (link read off the page, not downloaded).
- **Contents**: BANDGAP, LDO, PLL, SARADC, PHY. Each has a `top.hsp` and a
  `tb_*.hsp` testbench, model includes `mosfets.scs` (PTM BSIM3, level 49)
  and `bip_nom.scs`, Verilog-A checker modules, and defect lists
  (`ref/defect_open.txt`, `defect_short.txt`) for fault simulation.
  Medium-size analog/mixed-signal blocks with corners.
- **Licence**: the repo's `LICENSE` is MIT, but each file header reads
  "(c) 2020 Infineon Technologies AG. All rights reserved" with a
  disclaimer. Treat it as fetch-only until that conflict is resolved, or ask
  Infineon.
- **Dialect**: HSPICE netlists (`.GLOBAL` with `!` names, `.inc`, `.PARAM`);
  the model files open with `simulator lang = spice` (Spectre-wrapped SPICE
  cards); Verilog-A checkers. ngspice needs the `!` names renamed and the
  `simulator lang` line dropped; ESPice also needs VerA to compile the
  checkers (ngspice needs OSDI for them).
- **Oracles**: only the defect lists, which are for fault coverage and
  are not waveforms. ngspice is the oracle.
- **Maintained**: no (last push 2022), but obtainable.
- **Effort**: medium (HSPICE to ngspice cleanup, Verilog-A checkers).
- **Adds**: realistic analog blocks (PLL lock, SAR conversion, LDO
  transient) with Verilog-A in the loop, at sizes between the corpus and
  the post-layout decks.

## 6. VACASK benchmark set (Árpád Bűrmen)

- **URL**: https://codeberg.org/arpadbuermen/VACASK, `benchmark/` (cloned
  at 7eeb9d2e, 2026-10-05; Codeberg serves scrapers junk, so use git).
  GitHub mirror: https://github.com/pepijndevos/VACASK. Papers:
  https://fides.fe.uni-lj.si/~arpadb/MIDEM2025/midem2025.pdf,
  https://wiki.f-si.org/images/f/fd/Vacask.pdf.
- **Contents**: `rc`, `graetz`, `mul` (forced to about 1M or 500k
  timesteps), `ring` (9-stage CMOS, PSP103), `c6288` (16x16 multiplier,
  10,112 transistors, 25,380 nodes, PSP103), plus `vadistiller/` (bjtring,
  jfetring, c6288, mul, run with ngspice's built-in models and with their
  Verilog-A distillations). Per-simulator folders: ngspice, Xyce, gnucap,
  VACASK. `benchmark.py` runs them; the README gives Xyce 7.9, Gnucap
  20240220, ngspice pre-45 and VACASK times with timepoints, rejected
  steps and NR iterations.
- **Licence**: AGPL-3.0. Fetch, don't vendor. (The corpus already holds
  translated `vacask_*` decks; check that their `Origin:` lines and
  `models/LICENSES.md` cover that.)
- **Dialect**: the ngspice folders are native ngspice; the VACASK folders
  are VACASK's own language (`tests/benchmark/vacask.zig` translates the
  other way).
- **Oracles**: none; published timing tables only.
- **Maintained**: yes (commit on the survey date).
- **Effort**: low; most of it is done.
- **Adds**: c6288 at PSP103 (the ngspice ISCAS85 c6288 uses BSIM4), the
  vadistiller BJT and JFET rings, and the methodology: 6 runs with the
  first untimed, no result files written, KLU everywhere, timepoints and
  iterations reported beside wall time so speedups can be split into "fewer
  steps" and "cheaper steps".

## 7. gnucap tests

- **URL**: https://github.com/gnucap/gnucap (read-only mirror; cloned at
  4acc9fc4, 2026-10-02), `tests/`.
- **Contents**: 526 `.ckt` files, 720 reference outputs in `tests/==out/`.
  Mostly small behavioural and parser tests (`bm_exp`, `bm_fit`,
  `bm_cond`, ...).
- **Licence**: GPL-3.0. Fetch only.
- **Dialect**: gnucap. SPICE-like but with gnucap source syntax
  (`exp iv= pv= td1= tau1=`), `*>` command lines and gnucap `.print`.
  Conversion is per-feature and lossy.
- **Oracles**: gnucap text output.
- **Maintained**: yes.
- **Effort**: high for the yield.
- **Adds**: little beyond ngspice's own tests. Skip.

## 8. Qucs test suite (qucs-test)

- **URL**: https://github.com/Qucs/qucs-test (pushed 2025-02-06).
  Simulators: https://github.com/Qucs/qucsator, https://github.com/ra3xdh/qucs_s.
- **Contents**: 74 projects in `testsuite/` (`DC_SW_*`, `DC_AC_*`, `TR_*`,
  `SP_*`, HICUM and BSIM4 Gummel sweeps, filters, mixers), each a schematic,
  a Qucsator netlist and a Qucsator `.dat` reference.
- **Licence**: none stated in the repo (Qucs itself is GPL-2.0+). Fetch
  only.
- **Dialect**: Qucsator netlist, a different language from SPICE. Every
  deck needs translation, or a re-export from the schematic through Qucs-S
  to ngspice.
- **Oracles**: Qucsator `.dat`.
- **Effort**: high. **Adds**: S-parameter and RF decks with a
  non-SPICE oracle; low priority.

## 9. TAU and ISPD contests

- **TAU 2011 power grid contest**:
  http://www.tauworkshop.com/2011/contest_2011.html,
  https://tauworkshop.com/PREVIOUS/tau_2011_contest.pdf. It used ibmpg1-6
  (section 3) and promised five new benchmarks that were never published
  as far as could be found. Nothing beyond IBM PG.
- **TAU 2013+ timing contests** (https://tauworkshop.com/2013/): timing
  graphs and libraries, not SPICE decks. TAU 2020/2021 delay calculation:
  https://github.com/geochrist/dctk (MIT, last pushed 2022-08) generates
  ngspice and Xyce decks for RC interconnect driven by ASAP7 cells. Medium
  effort; adds small RC-plus-cell decks with `.measure` delay checks.
- **ISPD 2009/2010 clock network synthesis**:
  https://www.ispd.cc/contests/09/ispd09cts.html (resolves);
  http://archive.sigda.org/ispd/contests/10/ispd10cns.html **unverified**
  (no response). Benchmarks are sink placements; contestants' solutions
  were scored with ngspice (rework-19) and PTM 45 nm. There are no
  circuit decks to take. Skip.

## 10. Open-PDK post-layout netlists (OpenROAD, sky130, gf180, IHP)

- No packaged suite of extracted netlists exists for OpenROAD or OpenLane
  flows. Extraction (magic `ext2spice`, OpenRCX SPEF) happens per design.
  The sources in use or worth using are:
  - ngspice's own c7552 decks on sky130 and IHP (already in `fetch.sh`);
  - Tiny Tapeout analog submissions with magic extraction, such as
    https://github.com/iic-jku/jku-tt06-tdc-v1 (Apache-2.0, already in
    `fetch.sh`). Other TT analog repos follow the same pattern; pick them
    one at a time;
  - GF180 standard-cell decks in `fd_pr` `sc_regression` (section 4).
  - https://github.com/IHP-GmbH/IHP-Open-DesignLib (Apache-2.0) was
    checked: the top-level tree has 43 entries and no extracted netlists
    (designs may live in submodules; not followed).
- **"CANDE"**: no suite by that name was found (searches returned
  LLM-netlist datasets only). **Unverified**; the name may be wrong.

## 11. Spectre and HSPICE demo decks

Neither vendor publishes its demo or regression decks. The HSPICE `demo/`
tree and Spectre's RF workshop material ship with licensed installs only.
The public HSPICE-dialect material found is the Infineon set (section 5)
and the XDM translation tests in Xyce_Regression (section 2), which are
HSPICE/Spectre/PSpice inputs written for Xyce's translator. No usable public
Spectre suite.

## 12. Older suites and leads that did not pan out

- **CircuitSim90 at NCSU**: http://www.cbl.ncsu.edu/CBL_Docs/csim90.html
  no longer resolves (connection failure). Use the Xyce_Regression copy
  (section 2).
- **Quarles benchmark set** ("Benchmark Circuits: Results for Spice3",
  ERL M89/47, 1989) and the Berkeley **qxdir** set: listed on
  https://ngspice.sourceforge.io/bench.html, but that page links nothing;
  no downloadable copy was found. **Unverified / likely lost.** Most of
  these circuits were also Spice3f5 test decks and may survive in ngspice
  `tests/`.
- **MCNC netlists at SMU** (https://s2.smu.edu/~manikas/Benchmark.html):
  floorplanning and placement benchmarks, not SPICE.
- **"SPICE benchmark circuits" by Bucher**: no such suite found. The
  closest match is the compact-model benchmark tests (Gummel symmetry,
  AC symmetry, self-heating, noise) used in MOSFET model QA; those are
  covered by section 4. **Unverified.**
- **Academic convergence benchmarks**: the papers (HomSPICE, variable-gain
  homotopy, the 4-transistor Schmitt trigger with 9 DC solutions) describe
  their circuits in the text but publish no netlist suite. The practical
  convergence suite is CircuitSim90 `MOS2_LARGE` (its README records which
  decks need GMIN stepping), Xyce `HOMOTOPY/` (59 files) and ngspice
  `examples/optran`.
- **spicesmith** (https://github.com/apullin/spicesmith): a random-circuit
  generator for differential SPICE testing with an ngspice adapter. Created
  2026-10-03, no licence, nothing to vendor; the idea (Csmith for
  netlists) is the useful part.
- **LLM netlist datasets** (Masala-CHAI arXiv:2411.14299, AMSNet
  arXiv:2405.09045, AnalogGenie): topologies without testbenches or
  oracles. Not benchmark material.
