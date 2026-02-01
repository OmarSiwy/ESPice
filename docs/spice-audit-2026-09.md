# SPICE audit 2026-09-06 — root causes, not bandaids

One session, spice-audit branch. Method: full-corpus baseline first, then
every failure traced to a mechanism before any fix; agent audits verified
models line-by-line against ngspice 44.2 C sources (/tmp/ngspice-src).
Reports: /tmp/audit-{mos-legacy,bjt-jfet-mes,llvm-time}.md.

## The two lies in the old numbers

1. **Every CPU benchmark measured unoptimized code.** `standardOptimizeOption`
   defaulted to Debug AND `exe.use_llvm = false` pinned the self-hosted
   backend, which has no optimizer — `-Doptimize=ReleaseFast` changed
   nothing. ngspice (-O2) raced espice's debug codegen. Fixed: ReleaseFast +
   LLVM by default (Debug keeps self-hosted for iteration).
2. **Release carried full DWARF** — measured ~2/3 of the 12-minute LLVM
   compile (DI maintenance is superlinear in function size: exponent 2.0 vs
   1.2 stripped) and 115 MB of a 128 MB binary. Stripped: 184 s build, 12 MB.

## Correctness mechanisms found (each measured before/after)

- **VerA collapse chains** (bsim4 3.5e3 → 1.7e-3; also un-wedged every DC
  sweep, 1000x): two `V(a,b)<+0` shorts sharing a node (rgateMod=0) were
  aliased last-write-wins; the dangling KVL row stamped ±1 garbage onto a
  KCL row. Union-find in the emitted collapse(). VerA f6b428c.
- **$param_given never bound** (all models): derived defaults dead, PMOS
  bsim4 cards reset to NMOS, TOX-given zeroing gate caps. Landed with the
  bsim3 merge, plus Zig-primitive escapes (`u0Z`,`u1Z`,`u10Z`) card aliases.
- **Parenless waveforms** (`vs a 0 dc=0 sin 0 50 100k`): unparsed → flat DC
  (vacask/mul err 1.00 → 2.8e-5).
- **.options ignored wholesale** → parsed (reltol/abstol/vntol/gmin/trtol/
  chgtol/itl*/method/maxord/temp).
- **.dc second sweep variable + TEMP** (outer loop): 2-var fixtures ran at
  vgs=0 before; point counts now match ngspice exactly.
- **Topology diagnoses**: weighted union-find over V/L shorts (error only on
  INCONSISTENT KVL cycles), current-source cutset, capacitor island — named
  errors, ngspice-setup-class.
- **Runtime .hdl loading dead end-to-end** (3 bugs): missing gompute module
  for the .so's dyn build; swallowed ErrorBundle; ABI pre-check compared the
  orchestrator's cache key against the engine's type-layout hash (unrelated
  formulas). verilogA fixtures now exact.
- **Model equations vs ngspice C** (agent-verified, fixture-proven): diode
  IKF form + ISR/NR; bsim1 was ~4 decades dead (spurious 1e-4, wrong Cox
  scaling); mos2 VMAX used gate overdrive for drain excess; mos3 CLM gate;
  jfet IS(T) XTI; mos9 KP/PHI derivations; mesa pnjlim arg swap; BJT pe/me/
  pc/mc aliases; mos6/mos9 PMOS spell polarity `mtype`.
- **Fixture bugs in our own corpus**: diode_bridge had NO ground (both
  engines agreed to 2.6 µV differentially; the 2.47e2 was null-space);
  hfet_inverter's ngspice golden violates ngspice's own equations by 0.55 mA
  (hfetload.c reverse-mode vgs/vgd bug — nodeset pins the true state);
  schmitt's "espice 5 ns lag" was the golden's own LTE (tmax pinned).
- **Native LTRA** (recursive convolution, ngspice ltraload port): replaces
  the N-section Bergeron cascade; tline fixtures 1.3-3.3 s → 20-30 ms.
  Accuracy tuning was interrupted mid-agent — WIP on `ltra-native` branch.

## Known divergences, tracked (task list)

- mosamp: vds=0-seam Newton 2-cycle — ngspice fetlims vgd in inverse mode,
  VerA's $limit ladder is static-order (#14, needs conditional $limit).
- Inverter mid-edge cluster (pvt/parallel_inverters/mos6_inverter): Meyer
  caps not averaged with previous accepted step — mos1.va documents the
  shortcut (#15).
- mesa/mes/hfet C·ddt(V) lowered as ddt(C·V) → spurious V·dC/dv (Cgg up to
  2.17x): freeze-coefficient design specced, agent interrupted (#8).
- b4soi/b3soipd/hisim: model-version deltas vs ngspice's C (bsimsoi VA port
  vs B3SOI PD), not plumbing.
- espice raws carry no branch currents → several gummel/transfer "passes"
  are vacuous; ngspice trap-ringing artifacts (pvt undershoot −0.165 V)
  count against us in the comparator.

## Perf levers left (measured, ranked)

1. VerA temp-expr hoisting: pow/log/exp ≈ 20% of BJT transients (#16).
2. SIMD sparse refactor replay: 32% of fourbitadder (#17).
3. Waveform streaming to the raw writer: 760 MB → ~ngspice's 220 (#13).
4. Per-model LLVM objects (buildsplit branch, bit-identical, unmerged):
   caching granularity; strip already took the headline win.
5. VerA `--outline-chunk` (landed upstream, default off): GPU kernels
   compile 70-110x faster — the lever for re-admitting big models to GPU
   emission (#18).
