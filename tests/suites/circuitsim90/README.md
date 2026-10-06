# CircuitSim90 / MCNC

The MCNC CircuitSim90 benchmark netlists as kept in Xyce's regression
suite, converted to ngspice dialect by `fetch.sh`.

- Source: https://github.com/Xyce/Xyce_Regression, `Netlists/CircuitSim90/`
- Pinned commit: `bbde402756cdf542627ff7ea0056db130fcb005b` (master, 2026-08-10)
- Licence: the repository is GPL-3.0-or-later (Sandia/NTESS). The netlists
  are fetched at build time and never vendored into this tree.
- Decks: 43 (BJT 1, MOS2 18, MOS2_LARGE 14, MOS3 10). They range from
  2-node AC models up to `chip2` (46,850 unknowns, 18,816 MOS2 devices).

`zig build bench-suites -Dsuite=circuitsim90` fetches them into
`zig-out/suites/circuitsim90/<dir>/<deck>.sp` and times espice, ngspice and
VACASK on each one.

## Conversion

The decks are SPICE2/3 netlists. Only the control cards are Xyce's.

- `+` continuation lines are joined to their card first, so a dropped card
  takes its continuation lines with it.
- `.print` becomes `.save` of the nodes and branches it names. The Xyce
  `{v(x)+c}` display offsets, `v(a,b)` differences (both nodes are saved),
  `vm`/`vdb` forms and `PRECISION=`/`WIDTH=` are dropped.
- `.options device temp=T` becomes `.temp T`.
- `.options timeint`: `method=gear` (mike2) and `maxord=1` (pump) are kept.
  `reltol=1e-3` is already ngspice's default. `abstol` (a truncation-error
  tolerance in Xyce, not ngspice's current tolerance) and `nlnearconv` have
  no ngspice equivalent, so both are dropped.
- `.options nonlin`, `nonlin-tran`, `loca`, `linsol` and `dist` are Xyce
  solver, continuation and partitioning settings, so they are dropped. The Xyce README says
  add20, add32 and dac converge only with GMIN stepping. ngspice already
  falls back to GMIN stepping, then source stepping, when Newton fails, so
  no option is added; all three reach their operating point that way.
- `pc_frame` names every MOSFET `m1` and every capacitor `c1`. Each repeat
  gets a unique `_<n>` suffix, which ngspice requires.
- `smult20` (node 5592, capacitors only) and `pc_frame` (node 4512, MOSFET
  gates and one capacitor) have nodes with no DC path to ground (the Xyce
  README's "DCOP fails"). ngspice's operating point is singular on them, so
  both decks get `.options rshunt=1e12`.
- e1480 and g1310 set `utra` on their MOS2 models. ngspice warns and
  ignores it; SPICE2 never used it either.

## Exclusions

None. All 43 decks convert with their original analyses and windows.

## ngspice-45 status

Checked with `ngspice -b` from `nix develop .#benchmarking`, on a loaded
machine:

- 36 decks finish within 300 s, including pc_frame (190 s, with `rshunt`).
- add32 needs about 300 s, right at the runner's timeout (299 s on
  ngspice-44.2, killed at 300 s on 45). ram2k finishes in 765 s.
- chip2 and smult20 reach their operating point and advance in transient
  but were not run to the end. chip2 had reached 0.45 of 5 us at 300 s (on 44.2);
  smult20 had reached 38 of 400 ns after 30 minutes.
- voter25 stalls at t = 31 ns with a collapsing timestep. Without the MOS2
  `vmax` parameter it finishes in 1.5 s, so the stall is in ngspice's
  velocity-saturated MOS2 model. The Xyce README calls it quick.
- voter and mem_plus use similar MOS2 models. ngspice fails their
  operating point (GMIN and source stepping both fail). voter's transient
  operating point then stalls past 30 minutes, and mem_plus stops with
  "timestep too small". The Xyce README reports both as running.
