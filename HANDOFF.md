# HANDOFF — ngspice compliance session (2026-07-10)

Goal: pass `zig build bench -Doptimize=ReleaseFast` accuracy vs ngspice.
Cause list with file:line evidence: `benchmark/TRIAGE.md` (clusters A tran, B
converger, C devices, D parser, E scaling). GPU-for-post-layout doc:
`docs/OVERVIEW.md` (new).

## Why the host kept crashing

Bench runner retained every parsed raw file in one suite-lifetime arena
(`benchmark/src/runner.zig:68`) — multi-GB over ~200 fixtures → host OOM →
killed Claude + agents mid-edit. **Fixed** (uncommitted, in main working
tree): per-fixture `ArenaAllocator` in the fixture loop + skip-string dupes.
Verified compiling + running. Secondary: RESULTS.md memory column was
debug-binary-inflated (DebugAllocator memsets the 4M-point tran prealloc);
always bench a ReleaseFast build. No true leak — valgrind clean.

Ops rules that would have prevented the pain:
- ONE build or bench at a time; filtered fixtures only (`-- --filter cat/name`).
- GPU build takes ~13 min. Agents must run it as blocking foreground Bash
  (timeout 600000), not background — agents that end their turn "waiting" die.

## Branch state (all based on main @ 7e767ee)

Main working tree: ~215 uncommitted files = the analysis module reorg WIP
(ac/ dc/ pss/ eigen/ helper/ split) + my runner.zig fix (gpu accuracy columns
+ per-fixture arena) + TRIAGE.md + docs/OVERVIEW.md. **Nothing merged yet.**

| branch (worktree under .claude/worktrees/) | state | result |
|---|---|---|
| `worktree-agent-a6ff8550474ab7626` @ a2b4a2a | **DONE, verified** | Parser D1-D3: hspice_suffix 2e-3→1.9e-9 PASS; behavioral_bsrc 1.0→6e-8 PASS; fourbitadder OOB-panic→runs. subckt_params still FAIL but only via tran breakpoints (fixed in tran branch). |
| `worktree-agent-a70cb164570295a41` @ 7d0492e | **DONE, verified** | Tran A1-A5: 12 fixtures→PASS (all fourier, digital except clamp rms 1.67e-3, rc_ladder_50, rc_chain_500, sin_source, tran_pulse, long_tran); ngspice/rc 2.9s→21ms + PASS. NOTE: commit builds only WITH the reorg WIP (worktree carries mirrored copy uncommitted). |
| `worktree-agent-a99466bee860cdc17` @ 615d019 | steps 1-5 committed; **6-7 half-done, uncommitted, unverified** (192 ins across gpu_abi.zig, helper/converger.zig, problem/gpu.zig, kernel.zig, gpu_solver.zig) | Converger B: e15cbac diode-breakdown NaN guard (`log(arg−2)` needs arg>2) + SingularMatrix routing; 9643709 dynamic-gmin + adaptive source stepping; 615d019 JFNK guarantee rung. Remaining: step 6 GPU kernel limiting (BatchDesc off_lim, per-outer-iter limit pass, Dual companion correction `out[ru].v += dot(out[ru].d, x−lx)`, shifted gather for residual-only FD evals); step 7 fallback hygiene (try newton after kernel+jfnk fail when n≤5000; don't read back non-finite failed GPU iterate at gpu_solver.zig:188). |
| `worktree-agent-a4afc5e4c38c9ee66` @ 7e767ee | **half-done, uncommitted, unverified** (97 ins across mos1.zig, batch.zig, converger.zig, dc.zig, engine.zig). PRE-reorg flat layout! | Devices C: agent killed twice mid-C7/C8. |

## Remaining work items

**Converger steps 6-7** — design above; full spec in TRIAGE.md B + the
uncommitted diff. Verify: OpDidNotConverge cluster (bsim4, hicum2,
vbic_ce_amp/temp, bypass/*, ngspice/diffpair mosamp mosmem rca3040,
mos6_inverter, bsim2_ngspice, diode_breakdown) on BOTH cpu and gpu columns;
gpu-rms ≈ cpu-rms.

**Devices C1-C8** (planner-verified root causes):
- C7/C8 mos1.zig:411-417: `mode = vds_raw.div(vds_eff.addC(1e-30))` → zero
  channel conductance at vds=0 → inf (cmos_inverter) and constant 4.65e-1
  (parallel_inverters). Fix: branch on `vds_raw.val() < 0`, vds_eff =
  neg()/identity (deriv ±1), mode = plain f64 ±1, delete div. Equations
  otherwise MATCH ngspice — don't touch them. Same anti-pattern later:
  bsim_soi.zig:1823, hisim_hv.zig:1310, mos2/mos9/bsim2/hisim2/vdmos/….
- C1 switch.zig:168-171: instant g toggle → port ngspice swload.c log-space
  smooth transition across VT±VH; keep FSM; extend g_pattern_override
  {0..1}×{2..3}; mirror cswitch.
- C3 tline.zig:121-128: gatherHistSignals records V(int)−V(neg), must be
  V(pos)−V(neg). Two lines. (History interp already exists.)
- C6 netlist.zig:359-372: addKinduc stores raw k; must be M=k·√(L1·L2) —
  record inductance values at parse ('l' arm ~:237).
- C2 parser.zig:397-399: move 'w' from 4-node to 2-node letter group; model
  name is positional[1] for W in netlist.zig addBranchRef.
- C5 devices/src/root.zig:74-96: add `.{ "p", .coupled_tlines }`; CPL vector
  params (bare ""-keyed values after r/l/c/g) → rm/lm/cm/gm handler.
- C4 lossy_tline: skip physics rework, document approximation.
Verify: mosfet/cmos_inverter, scaling/parallel_inverters_100, devices/switch*,
tline, kinduc, cswitch, coupled_tlines. Regressions: mos1_transfer/output,
mosfet/nand2, devices/urc.

**Not started** (TRIAGE): C9 big-model .op divergence (bsim3/vbic/jfet/mesa),
E2 factor-once caching (direct.zig:108-144), E4 GPU 4k preflight
(maxCoopBlocks=0), tran E1 waveform prealloc clamp + real allocator for
Waveform grow (leak report), runner debug-binary guard.

## Merge order (do this first, one step at a time)

1. Commit main WIP: reorg + runner fix + TRIAGE/OVERVIEW ("Analysis module
   reorg; bench runner: gpu accuracy columns + per-fixture arena").
2. `git merge worktree-agent-a6ff8550474ab7626` (parser — clean, pre-reorg
   files only).
3. `git merge worktree-agent-a70cb164570295a41` (tran — its tran/tran.zig,
   engine.zig, netlist.zig, gpu_solver.zig versions supersede reorg-WIP
   copies; take branch side on conflict).
4. Finish converger 6-7 in its worktree (it tracks the reorg layout),
   rebase/merge onto post-1-3 main, verify.
5. Finish devices in its worktree, then PORT to reorg layout on merge
   (converger.zig→helper/converger.zig, dc.zig→dc/dc.zig).
6. Full bench ReleaseFast, update TRIAGE.md checkboxes, re-baseline RESULTS.md.

Overlap warning: engine.zig touched by parser (2 lines), tran (large), and
devices (small) branches — merge parser+tran first, hand-resolve devices.
