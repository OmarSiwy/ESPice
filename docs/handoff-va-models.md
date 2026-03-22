# Handoff: Verilog-A model cleanup, attribution, native-line migration

Branch `worktree-agent-a4d63279396fb619c` (base `bcc13b3`).

## Gates used

- Comment/format-only changes: the Zig vera generates is byte-identical to the
  base (vera run with the build's flags, `--jac-f32` for mos1/mos6).
- Structural changes (MOS/BSIM layout, bjt rename): default `zig build`, then
  all 616 fixture decks run before and after. Every rawfile and exit code is
  bit-identical.
- `zig build test`: the same 518/616 fixture passes as clean main, and 297/297
  unit tests pass. It exits 1 only because of the 98 fixture failures main
  also has. VerA `--check --contract` is clean, with no new warnings.

## Per-model status

Attribution categories:
- **own**: "Verilog-A implementation: Omar El-Sawy, University of Waterloo" only.
- **derived**: that line plus "Based on: ngspice ..., original model/originator"
  and the ngspice copyright notice (Regents of the University of California
  and others, modified BSD).
- **third-party**: original notices and body untouched, plus one note naming
  the ESPice flattening/adaptation by Omar El-Sawy.

| model | status | attribution |
|---|---|---|
| capacitor, inductor | rewritten (header, units) | own |
| resistor, vcvs, vccs, cccs, ccvs, kinduc, cswitch, vswitch, bsource, vsource, isource | rewritten (comments, formatting) | derived |
| tline, lossy_tline, coupled_tlines, diode, jfet, jfet2, mes | rewritten (comments, formatting) | derived |
| gummel_poon (was bjt) | rewritten + renamed | derived |
| mos1 | rewritten; reference layout of the MOS family | derived |
| mos2, mos3, mos6, mos9, bsim1, bsim2, bsim3 | rewritten into mos1's layout (section order, shared local names, di/si nodes, polarity parameter `type`) | derived |
| hfet1, hfet2, mesa, vdmos | cosmetic (header, comments) | derived |
| bsim4va, bsimsoi_va, hisim2_va, hisimhv_va, hicumL2_va, vbic13_4t | untouched body + adaptation note | third-party |

Notes:
- bsim4va.va is Cogenda's VA-BSIM48 and carries **CC-BY-NC 4.0**, a
  non-commercial license. Check it before any commercial use.
- bsim2 keeps its original contribution order. The family's canonical order
  moved its DC sweeps by 1 ulp.
- Parameter declaration order is unchanged everywhere. It is the `.mc`/`.sens`
  list and sets the Monte Carlo draw order.
- The polarity renames (mos3 `dev_type`, mos6/mos9 `mtype`, bsim2 `type_`, all
  to `type`) leave the `dev_type`, `mtype` and `typeZ5f` branches of
  `frontend/builder.zig setPolarity` dead. They are harmless: each is a
  comptime-false branch. Removal is left to the frontend owner.
- vsource.va and isource.va fell below the 20 KB `heavy_model_bytes` line in
  build.zig. That changes only GPU compile scheduling, not runtime.
- Attributions written from memory that should be checked: T. Ytterdal
  (hfet1/hfet2), Holger Vogt and Dietmar Warning (vdmos), Quarles/Gillespie
  (mos9), Colin McAndrew et al. (VBIC).
- Remaining differences inside the MOS family are real differences in the
  arithmetic, kept on purpose:
  - junction depletion charge arrangement (mos1 `jchg`, mos2/mos3/mos9
    `qdep` variants, mos6)
  - reverse-bias junction current (mos1 flat, mos3/mos9 cubic)
  - Meyer halves vs full-and-average
  - KP(T) form

## Native line models → .va (models/native/, NOT built)

`ltra.va`, `txl.va` and `coupled_ltra.va` are written in idiomatic Verilog-A.
Each gap is labelled `VERA-GAP:` at the top of the file and at the construct
that needs it. The native `.zig` models remain the ones built and used.

| file | compiles on pinned VerA | VERA-GAP features |
|---|---|---|
| ltra.va | no (`erfc` unknown, E0512) | 1. `erfc()` builtin (RC kernels)<br>2. memory-backed arrays: VerA scalarizes arrays, so this file emits 96 MB of Zig<br>3. growable history instead of a fixed cap<br>4. per-timepoint cache that survives Newton iterations and is dropped on rejection<br>5. dynamic timer re-arming: only the first wavefront breakpoint lands<br>6. held `analog initial` results: setup reruns on every evaluation |
| txl.va | vera `--emit-zig --check` passes (26 MB of Zig), but the ESPice build fails: see below | 2, 4, 6<br>8. held integer variables keep their integer type (VerA bug) |
| coupled_ltra.va | no (array slices as function arguments, E0511, 9 call sites) | 7. array-slice function arguments<br>plus 2, 4, 6. With temporaries in place of the slices, N=2 compiles. |

The existing .va lines only partly cover the native ones:
- tline.va covers LTRA's LC case exactly.
- lossy_tline.va only approximates RLC (lumped half-R).
- Nothing implements the TXL Padé method or the CPL modal fit.

## TXL validation (stopped when the budget ran out)

Validation ran in a scratch copy (`models/txl.va` registered, Y card routed
to it). **txl.va does not build in ESPice.** The `-Dgpu=false` build ran
8 min and failed with 3 errors. The generated txl.zig is 26 MB.

1. A VerA bug: the held integer loop variable `k` is emitted as a real
   (`inst.txl__held__k = m.f3`, found R, expected i64). The other held
   integer, `nh`, is fine.
2. `src/analysis/eval.zig` ~1674: the comptime branch quota on the `knobs`
   StaticStringMap is exceeded.
3. `src/analysis/eval.zig` ~2791: the comptime branch quota in `setParam` is
   exceeded.

Workarounds exist in the scratch copy only (a separate held loop variable
`kz`, raised quotas). The rebuild with them was killed before it finished, so
**no TXL deck has run on the .va**. The native baseline passes both TXL decks
(about 0.03–0.05 s each). Recommendation: don't switch.

## What's left

1. TXL: fix the VerA held-integer typing bug (or keep the `kz` workaround).
   Raise the two eval.zig comptime quotas. Then rebuild and run
   `bench_tline_txl1_1_line` and `bench_tline_txl2_3_line` against native.
   Weigh the 26 MB device's build time against the
   O(history)-per-iteration slowdown (gap 4) before switching the Y card.
2. VerA features 1–7 above, in VerA, not here.
3. Optional: sharing the MOS junction helpers through an `include` needs
   build.zig to track the included file as a vera input.
