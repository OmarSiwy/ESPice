# Open work streams

What is left of the optimization plan. The rules below apply to every stream.
Finished work is described in the topical docs, with its measurements.

## Rules for every change

- `zig build && zig build test` green at every commit.
- Outputs byte-identical on all 616 decks, except a documented bug fix that
  moves a deck toward its reference. Roundoff-only changes (dense to sparse,
  reordered floating-point sums) are not accepted without a user decision.
- No passing deck may start failing.

## F. VerA-coupled host work (after the next VerA pin)

- The host half of VerA's derivative metadata (`deriv_reads`, `jac_const`,
  `ddx_reads`), with `lane_of` in `Dual.ddxAt`.
- A fused accept (`updateState` plus the charge re-read in one pass).
- An explicit setup call. VerA's contract ABI 4 refuses a host that skips
  setup, so this is required by the pin, not optional.

## F2. One charge slot per `ddt()` site (after F)

Targets the remaining transient drift in `issues.md` F9 (mos6_inverter,
schmitt, rca3040, rtlinv, hfet, inverter_chain_256): ngspice truncates each
charge separately, while the host q tape keeps one per terminal.

- Host q tape per site (`n_q`, `q_stamps`, `qRows` for row stamping) and an
  LTE per site masked by `q_lte`.
- Mark .va sites `(* vera_lte = 0 *)` to follow ngspice's `*trunc.c`:
  mos1 to mos9 exclude qbd and qbs; BJT and VBIC keep qbe, qbc, qsub and qbcx
  as separate sites; BSIM and HiSIM follow their trunc routines.
- Known cost: `qRows` is one flat signed sum where the per-row q nested three
  sums (sites, statements, contributions), so rows built from multi-site
  contributions move by up to 1 ulp: bsimsoi 2.8e-16 relative, hisim2 about
  1e-20 on rows near 1e-13, hicumL2 and the inductor only in signed zeros.
  Exact for bsim4va, the MOS family and VBIC. VerA declined group ids in
  `QStamp`, so this is documented rather than avoided.
- Status: the host tape and the marks for mos1-9, hfet1, jfet2, BJT, VBIC
  and the diode (one site) landed. BSIM1-4, B3SOI and HiSIM stay unmarked:
  their trunc routines check terminal charges (qb, qg, qd) that fold the
  junction charges in or out by instance flags (`rbodyMod`, HiSIM's
  `qbd`/`qbs` merge), which a compile-time `q_lte` cannot follow, so they
  keep every site checked.
- Then the per-timepoint cache (`stepFill`), on its own pin.

## G. Native transmission lines to Verilog-A

Move `models/native/{ltra,txl,coupled_ltra}.va` into `models/` and delete
the matching `.zig` one model at a time, only once VerA compiles it and it
matches the native model on the tline decks. Status and remaining VerA gaps:
[vera-gaps.md](../vera-gaps.md). Until then the native `.zig` models stay the
O, Y and P devices.

## H. Multithreaded device evaluation

`ParEval` (`src/analysis/par_eval.zig`) already splits instances across
threads with a deterministic plane reduction, but only `ESPICE_THREADS`
(default 1) turns it on.

1. A `--threads=N` CLI flag and C API field, default auto. Keep the
   environment variable as an override or delete it.
2. Engage automatically only above a measured cost threshold (instances times
   per-model cost), so small decks never pay the two per-iteration barriers.
3. Measure 1, 4, 8 and 16 threads on a quiet machine: parallel_inverters_2000,
   a bsim4 deck, rc_ladder_100k. The Amdahl ceiling is about 2.6x at 8
   threads on transient decks (device evaluation is 52 to 71% of the run),
   higher on big-model decks. Outputs must be byte-identical across thread
   counts; the reduction order is fixed, so test it.
4. Then the serial remainder (reduction bandwidth, barriers) if it dominates.

## I. Small follow-ups

- Analysis tests still build circuits through the frontend `builder` module
  (build.zig wires it into `test-analysis`). A device-level assembly API
  would remove the last analysis-to-frontend test edge.
- `Circuit.evalNewtonCpu` zeroing and the per-executor ordering: see the
  follow-ups in [solver-perf-2026-09.md](../solvers/solver-perf-2026-09.md).

## Deferred until a user decision

- Roundoff-changing speedups: tf, sp and disto dense to sparse; a LaneLu
  pencil for pac, pxf and pnoise; the dcmatch reduction order; a supernodal
  or sorted DFS in the grid factor.
- Slot-tape compaction. Bitwise, but it touches the frozen GPU layout and
  needs an ABI bump.
- Output-changing speedups: removing envelope's `coarseAdvance`, exact PSS
  monodromy.
- Interning deck labels and result names through the InternPool: they are
  output strings the writers print verbatim, every Result already borrows or
  copies them once, and an id table would add a pool lookup per write with
  no measured gain.
