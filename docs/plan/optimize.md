# Optimization plan (2026-09-24)

Goal: Zig-compiler-style architecture (one flat data format per stage, u32 ids,
one intern pool), data-oriented layout, SIMD where a lane axis exists, least
code, deliberate seams, ngspice/VACASK conformance. Research notes (read-only
agents, main at e283557) are summarized here; raw notes live in the session
scratchpad.

## Rules for every change
- `zig build -Dgpu=false && zig build test -Dgpu=false` green; one GPU pass at the end.
- Outputs byte-identical on all 616 decks, EXCEPT a documented bug fix that moves
  a deck toward its reference. Roundoff-only changes (dense→sparse, FP reorder)
  are not accepted (user decision 2026-09-24).
- No passing deck may start failing (baseline: 518/616, list in f-base.txt).

## Target layout (user-confirmed)
```
core     src/core/      -> std         ids (Node{ground},Name,DeviceType,Card,QueryId), InternPool, numerics, query, deck, result
solver   src/solver/    -> core        (from analysis/solvers; only analysis imports it)
device   src/device/    -> core        3 build modules: device_abi (ir), device_eval (Dual/kernel/batch/gpu/abi), device (Library registry + loader, Circuit.freeze)
frontend src/frontend/  -> core,device netlist -> hypergraph + analyses; Keywords; SPICE letter/LEVEL table
analysis src/analysis/  -> core,device,solver   Session(circuit, deck), schemaOf, par_eval.zig
output   src/output/    -> core        encoders + one atomic write
espice   src/espice.zig -> all         facade (owns Library, pool, circuit, deck); c_api.zig; main -> espice
```
`problem/` dissolves (types → core, request/prep → frontend). Prepared splits into
`device.Circuit` + `core.Deck`.

## Work streams
A. Analysis engine cleanup, bitwise (r-engine): dead GpuHook fields and second GPU
   Newton route, ParEval → analysis/par_eval.zig, plane-clear dedup, baseName(D),
   session split (validate.zig; output limits → output), ProtoStore MultiArrayList,
   dead Hooks/vtable fields (abi_version bump), stale docs.
B. Analysis drivers cleanup, bitwise (r-drivers-a/b): pz debug print, dead GPU lane/sp/
   tran routes, RunCtx required fields, sens/dcmatch recomputeType, freq Stream (no
   N×2n materialization), mc/stb/four/envelope dead code, companion kernel ×5 → 1,
   tran/integrator.zig split, vector helpers → numerics, pss/samples.zig nnz planes
   (bitwise parts), matex buildCombinedVals/b-reuse, LaneSetup → anytype, leaks.
C. Conformance bug fixes (output-changing, gated on references): pac/pnoise setSimState,
   pnoise on PXF transfers (C5), pss i_prev per period, hb/qpss per-sample C, matex
   m_max>256 overflow + posterior scratch, sens cold OP, temp_sweep endpoint, envelope
   names, host reads u_abstol; plus r-conformance root-cause groups.
D. Model .va fixes, byte-identical (r-codegen): bsim4va tnom default (hoisting),
   bsim3 gmin placement, hfet1 leak() invariants, mesa level-4 statements into the arm.
E. Reorg (after frontend-hypergraph merges): build hygiene (wire test-frontend +
   test-output into `test`), deletions, solver/, device/ moves, Library, core/,
   espice.zig, InternPool, output encoders, AGENTS.md.
F. VerA-coupled (after VerA pins): deriv_reads/jac_const/ddx_reads host half
   (lane_of in Dual.ddxAt), fused accept (updateState+q), explicit setup call.

G. Native lines → .va (user decision 2026-09-24): per model, when ready. Move
   models/native/{ltra,txl,coupled_ltra}.va into models/ and delete the matching
   .zig only once VerA compiles it and it matches the native model on the tline
   decks (bench_tline_*, vacask_ring). Blockers (docs/vera-gaps.md): VerA
   memory-backed arrays (all three), array-slice actuals (coupled_ltra), and on
   our side an erfc analog function in ltra.va (not an LRM builtin). Until then
   the .zig models stay the O/Y/P devices.

F2. Per-ddt charge sites (VerA pin 0c4d6afc, local, not pushed; after F lands): host
   q tape per site (n_q, q_stamps, qRows for row stamping), LTE per site masked by
   q_lte, and mark .va sites `(* vera_lte = 0 *)` per ngspice's *trunc.c (mos1-9:
   qbd/qbs off; BJT/VBIC: qbe/qbc/qsub/qbcx separate sites; BSIM/HiSIM per their
   trunc routines). Targets r-drift cause #6: mos6_inverter, schmitt, rca3040,
   rtlinv, hfet, chain_256. Then stepFill (per-timepoint cache), its own pin.
   Known: qRows is one flat signed sum while the old per-row q nested three sums
   (sites, statements, contributions), so rows built from multi-site contributions
   move ≤1 ulp: bsimsoi (2.8e-16 rel), hisim2 (~1e-20 on ~1e-13 rows); hicumL2 and
   inductor only in signed zeros. Exact for bsim4va, the mos family and vbic.
   Documented, not avoided (VerA declined group ids in QStamp).

I. Small follow-ups (after F lands): `.options tnom` never reaches runtime-loaded
   devices nor the built-in resistor (output-changing, toward ngspice); analysis tests
   still build circuits through the frontend Builder (test coupling); interning of
   deck labels/result names deferred (no measured gain).

H. Multithreaded device evaluation (user-requested 2026-09-24; starts after E merges):
   ParEval (analysis/par_eval.zig) already splits instances across threads with a
   deterministic plane reduction, but it is hidden behind ESPICE_THREADS (default 1).
   1. `--threads=N` CLI flag (+ C API field), default auto; keep the env var as an
      override or delete it.
   2. Auto-engage only above a measured cost threshold (instances × per-model cost),
      so small decks never pay the two per-iteration barriers.
   3. Measure 1/4/8/16 threads on a QUIET machine: parallel_inverters_2000, a bsim4
      deck, rc_ladder_100k. Amdahl ceiling ~2.6x at 8 threads on transient decks
      (device eval 52-71%); higher on big-model decks. Byte-identical outputs across
      thread counts (the reduction order is fixed; test it).
   4. Then attack the serial remainder if it dominates (reduction bandwidth, barriers).

## Deferred (needs a user decision)
- Roundoff-changing speedups: tf/sp/disto dense→sparse, pac/pxf/pnoise LaneLu pencil,
  dcmatch reduction order, grid-factor dependency walk.
- Slot-tape compaction (FROZEN GPU layout; bit-identical, ABI bump).
- Output-changing perf: envelope coarseAdvance removal, exact PSS monodromy.
