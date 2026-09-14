# Benchmark results — espice vs ngspice, Xyce and VACASK

## Speed headline

| statistic | raw wall clock | floor-corrected |
|---|---|---|
| decks ranked | 237 | 52 |
| espice faster | 220 | 36 |
| geometric mean | 1.63x | 1.59x |
| arithmetic mean | 1.93x | 3.38x |

185 of the 237 ranked decks have no corrected ratio: after subtracting both
process floors, what is left is smaller than the floor measurement's own
min-to-median spread, so any ordering of the two engines there is a
measurement of the scheduler. They are blank, not ranked. Timings are
**minimum of N**, not median — see the note below.

7 decks change winner between min-of-N and median-of-N on the raw ratio.
That is the size of the effect that put seven false "espice is slower" rows
into `docs/perf/baseline-446268a.md`: the minimum is the sample least
contaminated by other load, the median is whatever the box was doing.

### Uncertainty

The floor was measured twice on the same deck with the same statistic:
once before the sweep (used for every `*` column above) and once after it.
Re-deriving the corrected headline against the CLOSING floor gives
**1.57x over 56 decks** against **1.59x over 52**. That spread is the
error bar on the corrected number, and it is not small: a wall-clock floor
on a shared machine is a measurement, not a constant.

Measured process floor (two devices, one `.op`), subtracted from every `*` column:

| binary | opening min | opening median | closing min | closing median |
|---|---|---|---|---|
| zp-cpu | 3.25ms | 5.25ms | 3.43ms | 5.46ms |
| zp-gpu | 3.16ms | 5.47ms | 3.42ms | 5.31ms |
| ngspice | 6.30ms | 10.50ms | 6.25ms | 10.07ms |
| xyce | 43.36ms | 47.01ms | 42.20ms | 46.15ms |
| vacask | - | - | - | - |

The floor is wall clock, so it carries fork/exec, page-in and the runner's
own `timeout` wrapper as well as the simulator's startup — and it carries
them on BOTH sides, including the pipe-drain the runner puts on espice and
not on the references. Everything constant per process therefore cancels in
the subtraction, which is the point.

## Pairwise matrix

Until this run the runner only ever called its comparator with espice as the
CANDIDATE. Every reference-vs-reference cell was structurally absent, and an
absent cell reads as agreement in every summary ever written out of this file
— including `docs/perf/ref-sims-2026-09-10.md`'s "no fixture where ngspice is
the outlier", which the instrument could not have observed either way.

All six unordered pairs of the four engines are now scored, with the same
comparator, the same gate, and no per-fixture tolerance. **36** fixtures are
contested somewhere in the matrix; on **31** of them two REFERENCES disagree
with each other; on **29** one engine sits further from every other than any
of them sit from each other.

`comparePlots` is directed: the reference supplies the error denominator (its
own peak and span) and the grid the other engine is resampled onto, and the
two directions of one pair can differ by more than 10x. Each cell below is
therefore the WORSE of both directions — the same "worst kept" rule the
comparator already applies across variables and across plots, and the only
reduction that makes the six numbers on a row comparable to each other.
The espice PASS/FAIL columns in the main table are unchanged and still
directed; nothing about this defect justifies restating them.

`furthest` names an engine that is further from every other engine than any
of them are from each other. That is the shape a reference makes when it has
converged to a different MODEL rather than a different answer, and such a
reference should recuse itself rather than vote — on `devices/mos6_inverter`
Xyce's own grid-to-grid motion is 100x smaller than its distance from both
other engines. But furthest is not wrong: on `ensemble/pvt_corners` the same
column names Xyce, and the grid refinement in
`docs/perf/pvt-arbitration-2026-09-10.md` shows Xyce is the engine that is
RIGHT there. The column points at what to investigate. It is never an input
to PASS/FAIL.

| fixture | ng/xy | ng/vc | ng/esp | xy/vc | xy/esp | vc/esp | furthest |
|---|---|---|---|---|---|---|---|
| bypass/gated_branch | **FAIL** 2.83e-3 (1.72e-2) | - | 1.22e-4 (4.51e-4) | - | **FAIL** 2.85e-3 (1.73e-2) | - | xy |
| bypass/idle_ladder | **FAIL** 1.03e-3 (7.29e-3) | - | 1.81e-4 (1.85e-3) | - | **FAIL** 1.20e-3 (8.32e-3) | - | xy |
| convergence/ota_cutoff_abstol | **FAIL** 2.76e0 (5.89e0) | - | **FAIL** 2.07e1 (6.70e1) | - | **FAIL** 1.41e1 (4.56e1) | - | esp |
| devices/coupled_tlines | - | - | **FAIL** 3.77e-2 (1.04e-1) | - | - | - | - |
| devices/hfet_inverter | - | - | **FAIL** 3.21e-3 (3.35e-2) | - | - | - | - |
| devices/jfet2 | **FAIL** 1.63e-3 (3.53e-3) | - | 5.65e-12 (1.00e-11) | - | **FAIL** 1.63e-3 (3.53e-3) | - | xy |
| devices/mos6_inverter | **FAIL** 2.48e-2 (1.02e-1) | - | **FAIL** 2.20e-3 (3.27e-2) | - | **FAIL** 2.34e-2 (9.65e-2) | - | xy |
| devices/mos6_simpleinv | **FAIL** 1.15e-2 (3.67e-2) | - | 4.64e-6 (6.27e-5) | - | **FAIL** 1.15e-2 (3.67e-2) | - | xy |
| devices/mos9 | **FAIL** 3.70e-3 (9.87e-3) | - | 1.04e-15 (3.47e-15) | - | **FAIL** 3.70e-3 (9.87e-3) | - | xy |
| devices/vbic_forced_output | - | - | **FAIL** 1.33e-3 (4.76e-3) | - | - | - | - |
| digital/clamp | **FAIL** 4.89e-3 (1.76e-2) | - | 2.18e-5 (1.07e-4) | - | **FAIL** 4.89e-3 (1.76e-2) | - | xy |
| ensemble/pvt_corners | **FAIL** 4.56e-2 (2.09e-1) | - | **FAIL** 9.47e-3 (1.18e-1) | - | **FAIL** 3.02e-2 (1.17e-1) | - | xy |
| medium/rc_ladder_50 | **FAIL** 1.43e-3 (9.65e-3) | - | 1.17e-4 (8.87e-4) | - | **FAIL** 1.43e-3 (9.65e-3) | - | xy |
| ngspice/mosamp | **FAIL** 2.71e-3 (2.26e-2) | - | **FAIL** 5.82e-3 (2.12e-2) | - | **FAIL** 4.72e-3 (2.86e-2) | - | esp |
| ngspice/rca3040 | **FAIL** 7.50e-3 (2.44e-2) | - | **FAIL** 4.51e-3 (1.04e-2) | - | **FAIL** 8.32e-3 (2.51e-2) | - | xy |
| ngspice/rtlinv | **FAIL** 2.05e-3 (1.35e-2) | - | 4.11e-4 (1.46e-3) | - | **FAIL** 2.08e-3 (1.42e-2) | - | xy |
| power/rectifier | **FAIL** 2.66e-3 (4.98e-2) | - | 7.41e-6 (9.53e-5) | - | **FAIL** 2.66e-3 (4.98e-2) | - | xy |
| regression/options_tnom | **FAIL** 1.07e-2 (1.07e-2) | - | 9.92e-8 (9.92e-8) | - | **FAIL** 1.07e-2 (1.07e-2) | - | xy |
| scaling/inverter_chain_1k | **FAIL** 1.84e-1 (1.80e0) | - | **FAIL** 4.02e-2 (7.57e-1) | - | **FAIL** 1.56e-1 (1.80e0) | - | xy |
| scaling/inverter_chain_256 | **FAIL** 1.83e-1 (9.69e-1) | - | **FAIL** 2.83e-2 (4.41e-1) | - | **FAIL** 1.38e-1 (9.64e-1) | - | xy |
| scaling/inverter_chain_4k | **FAIL** 1.77e-1 (1.80e0) | - | - | - | - | - | - |
| scaling/parallel_inverters_100 | **FAIL** 7.12e-3 (3.72e-2) | - | 5.74e-4 (8.98e-3) | - | **FAIL** 8.39e-3 (4.09e-2) | - | xy |
| scaling/parallel_inverters_2000 | **FAIL** 7.06e-3 (3.64e-2) | - | **FAIL** 5.83e-4 (1.17e-2) | - | **FAIL** 8.35e-3 (4.10e-2) | - | xy |
| scaling/parallel_inverters_500 | **FAIL** 7.21e-3 (3.78e-2) | - | 5.74e-4 (8.98e-3) | - | **FAIL** 8.40e-3 (4.03e-2) | - | xy |
| scaling/rc_chain_500 | **FAIL** 1.24e-3 (7.57e-3) | - | 1.27e-4 (1.34e-3) | - | **FAIL** 1.24e-3 (7.57e-3) | - | xy |
| scaling/rc_ladder_100k | **FAIL** 2.45e-3 (1.03e-2) | - | 2.25e-11 (2.36e-10) | - | **FAIL** 2.45e-3 (1.03e-2) | - | xy |
| scaling/rc_ladder_10k | **FAIL** 2.13e-3 (1.02e-2) | - | 2.25e-11 (2.36e-10) | - | **FAIL** 2.13e-3 (1.02e-2) | - | xy |
| scaling/rc_ladder_1k | **FAIL** 2.30e-3 (7.98e-3) | - | 2.25e-11 (2.36e-10) | - | **FAIL** 2.30e-3 (7.98e-3) | - | xy |
| tline/cpl3_4_line | - | - | **FAIL** 1.73e0 (2.86e0) | - | - | - | - |
| tline/cpl_ibm2 | - | - | **FAIL** 5.81e-2 (1.41e-1) | - | - | - | - |
| tline/delay_line | **FAIL** 5.03e-3 (5.00e-2) | - | **FAIL** 1.99e-3 (5.00e-2) | - | **FAIL** 2.40e-3 (2.50e-2) | - | xy |
| tline/ideal_tline | **FAIL** 5.34e-3 (1.82e-2) | - | **FAIL** 1.16e-3 (1.76e-2) | - | 2.63e-15 (2.41e-14) | - | ng |
| tline/terminated | **FAIL** 1.49e-3 (1.00e-2) | - | **FAIL** 7.04e-4 (1.00e-2) | - | 9.88e-16 (1.66e-14) | - | ng |
| vacask/graetz | 2.76e-5 (1.29e-4) | **FAIL** 1.89e-1 (4.27e-1) | 1.55e-6 (9.47e-5) | **FAIL** 1.89e-1 (4.27e-1) | 2.76e-5 (1.13e-4) | **FAIL** 1.89e-1 (4.27e-1) | vc |
| vacask/mul | **FAIL** 1.32e-4 (2.14e-2) | **FAIL** 8.19e-1 (9.97e-1) | **FAIL** 9.12e-5 (2.40e-2) | **FAIL** 8.19e-1 (9.97e-1) | **FAIL** 1.29e-4 (2.28e-2) | **FAIL** 8.19e-1 (9.97e-1) | vc |
| vacask/ring | - | **FAIL** 5.36e-1 (7.60e-1) | - | - | - | - | - |

Cells read `rms (max)`. `-` is a comparison that could not be made at all —
one of the two engines did not run the deck. `N/A` is a comparison that was
attempted and came back incomplete; it is neither agreement nor disagreement
and does not enter the `furthest` test at either end.

## Reference simulators

| column | version | binary |
|---|---|---|
| ngspice | ngspice-44.2 : Circuit level simulation program | `/nix/store/bywwgg84ccx0544z9qrfm4zc4ls30ghd-ngspice-44.2/bin/ngspice` |
| xyce | Xyce Release 7.10.0-opensource | `/nix/store/7glhfffprbvfz11bi9pd1fr5np8nw5df-xyce-7.10.0/bin/Xyce` |
| vacask | This is vacask unknown. | `/nix/store/g5ial84gcp2da9h7y63r4c6dc1iqip57-vacask-unstable-2026/bin/vacask` |

ngspice runs its DEFAULT solver unless `--ngspice-klu` is passed. That is
deliberate and measured: KLU is slower on every deck in this suite
(parallel_inverters_100 513M -> 555M Ir, mos6_inverter 149M -> 163M,
rc_ladder_10k 2.60G -> 3.98G). KLU's ordering and BTF analysis pay off at
1e5+ unknowns, not on a 105x105 matrix, so the default is ngspice's
STRONGEST configuration here and the reference is not a strawman.

Pass: per-variable RMS ≤ 1e-3, max ≤ 1e-2; error normalized by max(peak, span, 1).
N/A: unvalidated (missing signals, mismatched point counts, or a reference plot with no counterpart).
SKIP: that reference did not run the fixture (VACASK only runs where a `vacask.sim` deck exists).
GPU timings exclude reported CPU fallback.

Every timing column is the **minimum** of N repeats, not the median.
`cpu/ng` and `gpu/ng` are raw wall clock; `cpu/ng*` and `gpu/ng*` subtract
each binary's own process floor from both sides first, and are blank where
what remains is inside the floor's own noise.

| fixture | zp-cpu | zp-gpu | ngspice | xyce | vacask | cpu/ng | cpu/ng* | gpu/ng | gpu/ng* | zp-MB | ng-MB | xy-MB | vc-MB | cpu-max | cpu-rms | cpu | gpu-max | gpu-rms | gpu | xy-max | xy-rms | xy | vc-max | vc-rms | vc |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ac/drive_first | 3.12ms | skip | 5.89ms | 42.56ms | skip | 1.9x | - | - | - | 5.4 | 12.1 | 55.5 | - | 1.82e-16 | 1.08e-16 | PASS | - | - | SKIP | 1.82e-16 | 1.08e-16 | PASS | - | - | SKIP |
| ac/drive_second | 3.91ms | skip | 7.01ms | 43.11ms | skip | 1.8x | - | - | - | 5.4 | 12.0 | 55.5 | - | 1.82e-16 | 1.08e-16 | PASS | - | - | SKIP | 1.82e-16 | 1.08e-16 | PASS | - | - | SKIP |
| ac/mag_phase | 4.10ms | skip | 7.39ms | 45.99ms | skip | 1.8x | - | - | - | 5.5 | 12.1 | 56.1 | - | 1.82e-16 | 1.08e-16 | PASS | - | - | SKIP | 1.82e-16 | 1.08e-16 | PASS | - | - | SKIP |
| ac/multi_drive | 3.92ms | skip | 7.27ms | 46.16ms | skip | 1.9x | - | - | - | 5.4 | 12.0 | 56.0 | - | 1.82e-16 | 1.08e-16 | PASS | - | - | SKIP | 1.82e-16 | 1.08e-16 | PASS | - | - | SKIP |
| ac/no_ac_source | 3.89ms | skip | 7.12ms | 44.54ms | skip | 1.8x | - | - | - | 5.7 | 12.0 | 55.4 | - | 1.82e-16 | 1.08e-16 | PASS | - | - | SKIP | 1.82e-16 | 1.08e-16 | PASS | - | - | SKIP |
| ac/rc_lowpass | 3.57ms | skip | 8.09ms | 45.12ms | skip | 2.3x | - | - | - | 5.7 | 12.1 | 55.4 | - | 1.16e-15 | 3.81e-16 | PASS | - | - | SKIP | 1.46e-15 | 4.67e-16 | PASS | - | - | SKIP |
| adversarial/extreme_values | 4.77ms | skip | 6.52ms | 46.32ms | skip | 1.4x | - | - | - | 5.7 | 12.5 | 55.7 | - | 1.53e-15 | 4.06e-16 | PASS | - | - | SKIP | 1.53e-15 | 4.06e-16 | PASS | - | - | SKIP |
| adversarial/near_singular | 3.39ms | skip | 6.54ms | 44.12ms | skip | 1.9x | - | - | - | 5.2 | 12.1 | 55.3 | - | 0.00e0 | 0.00e0 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| adversarial/tiny_resistor | 3.39ms | skip | 6.57ms | 43.93ms | skip | 1.9x | - | - | - | 5.2 | 11.8 | 55.3 | - | 1.36e-10 | 1.36e-10 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| analog/current_mirror | 3.72ms | skip | 9.39ms | 44.51ms | skip | 2.5x | - | - | - | 6.4 | 12.5 | 54.8 | - | 1.09e-6 | 1.09e-6 | PASS | - | - | SKIP | 2.30e-5 | 2.30e-5 | PASS | - | - | SKIP |
| analog/diff_pair | 6.61ms | skip | 7.44ms | 43.28ms | skip | 1.1x | - | - | - | 5.9 | 11.8 | 55.6 | - | 1.28e-7 | 1.28e-7 | PASS | - | - | SKIP | 1.72e-5 | 1.72e-5 | PASS | - | - | SKIP |
| analog/opamp_inverting | 3.36ms | skip | 6.85ms | 44.02ms | skip | 2.0x | - | - | - | 5.6 | 12.2 | 55.4 | - | 1.11e-16 | 1.11e-16 | PASS | - | - | SKIP | 2.12e-22 | 2.12e-22 | PASS | - | - | SKIP |
| basic/rc_transient | 6.47ms | skip | 7.22ms | 43.22ms | 10.89ms | 1.1x | - | - | - | 5.4 | 12.1 | 55.4 | 12.5 | 3.02e-15 | 2.68e-15 | PASS | - | - | SKIP | 1.78e-16 | 1.03e-16 | PASS | 1.78e-16 | 1.78e-16 | PASS |
| basic/voltage_divider | 5.62ms | skip | 7.34ms | 44.06ms | skip | 1.3x | - | - | - | 5.3 | 12.2 | 55.2 | - | 0.00e0 | 0.00e0 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| bjt/cascode | 4.25ms | skip | 6.56ms | 44.26ms | skip | 1.5x | - | - | - | 5.9 | 12.4 | 55.3 | - | 1.60e-5 | 1.60e-5 | PASS | - | - | SKIP | 1.00e-5 | 1.00e-5 | PASS | - | - | SKIP |
| bjt/common_emitter | 3.75ms | skip | 6.35ms | 43.42ms | skip | 1.7x | - | - | - | 6.4 | 11.9 | 55.4 | - | 4.84e-5 | 3.74e-5 | PASS | - | - | SKIP | 1.29e-6 | 1.07e-6 | PASS | - | - | SKIP |
| bjt/diff_amp | 5.00ms | skip | 7.50ms | 45.81ms | skip | 1.5x | - | - | - | 5.9 | 12.0 | 55.5 | - | 1.05e-6 | 6.18e-7 | PASS | - | - | SKIP | 2.19e-5 | 2.15e-5 | PASS | - | - | SKIP |
| bypass/burst_clock | 8.36ms | skip | 10.33ms | 43.95ms | skip | 1.2x | - | - | - | 6.2 | 12.4 | 55.0 | - | 4.10e-12 | 3.55e-13 | PASS | - | - | SKIP | 2.29e-3 | 3.73e-4 | PASS | - | - | SKIP |
| bypass/gated_branch | 7.85ms | skip | 12.34ms | 49.76ms | skip | 1.6x | 1.3x | - | - | 6.1 | 12.0 | 55.3 | - | 4.51e-4 | 1.22e-4 | PASS | - | - | SKIP | 8.25e-3 | 1.54e-3 | FAIL | - | - | SKIP |
| bypass/idle_ladder | 8.27ms | skip | 10.99ms | 52.17ms | skip | 1.3x | 0.9x | - | - | 6.2 | 12.3 | 55.9 | - | 1.54e-3 | 1.80e-4 | PASS | - | - | SKIP | 8.32e-3 | 1.20e-3 | FAIL | - | - | SKIP |
| convergence/diode_bridge | 3.63ms | skip | 6.50ms | 42.70ms | skip | 1.8x | - | - | - | 5.9 | 12.2 | 55.4 | - | 2.75e-7 | 2.75e-7 | PASS | - | - | SKIP | 2.24e-5 | 2.24e-5 | PASS | - | - | SKIP |
| convergence/high_gain_fb | 5.25ms | skip | 5.94ms | 45.52ms | skip | 1.1x | - | - | - | 5.7 | 11.9 | 55.2 | - | 2.22e-16 | 2.22e-16 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| convergence/mos_latch_ladder | 5.28ms | skip | 7.93ms | 47.23ms | skip | 1.5x | - | - | - | 5.9 | 12.0 | 54.8 | - | 9.42e-4 | 1.95e-4 | PASS | - | - | SKIP | 4.34e-4 | 9.58e-5 | PASS | - | - | SKIP |
| convergence/mos_series_r | 4.12ms | skip | 6.57ms | 46.63ms | skip | 1.6x | - | - | - | 6.2 | 12.1 | 55.8 | - | 4.90e-7 | 7.87e-8 | PASS | - | - | SKIP | 9.72e-10 | 1.05e-10 | PASS | - | - | SKIP |
| convergence/ota_cutoff_abstol | 24.58ms | skip | 27.58ms | 110.56ms | skip | 1.1x | 1.0x | - | - | 11.7 | 14.6 | 65.6 | - | 9.96e-1 | 7.96e-1 | FAIL | - | - | SKIP | 9.94e-1 | 7.39e-1 | FAIL | - | - | SKIP |
| convergence/schmitt | 3.73ms | skip | 6.31ms | 44.45ms | skip | 1.7x | - | - | - | 5.7 | 12.0 | 55.1 | - | 3.25e-12 | 3.25e-12 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| dc_sweep/nested_sweep | 4.12ms | skip | 7.66ms | 47.84ms | skip | 1.9x | - | - | - | 5.9 | 12.1 | 55.1 | - | 3.55e-16 | 1.92e-16 | PASS | - | - | SKIP | 1.92e-12 | 1.11e-12 | PASS | - | - | SKIP |
| dc_sweep/param_sweep | 4.21ms | skip | 7.47ms | 44.60ms | skip | 1.8x | - | - | - | 6.0 | 12.1 | 55.2 | - | 3.28e-5 | 6.25e-6 | PASS | - | - | SKIP | 1.85e-5 | 9.49e-6 | PASS | - | - | SKIP |
| dc_sweep/vin_sweep | 3.72ms | skip | 6.62ms | 43.73ms | 8.86ms | 1.8x | - | - | - | 5.2 | 12.1 | 55.5 | 12.0 | 1.18e-16 | 3.88e-17 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | 4.34e-19 | 1.64e-19 | PASS |
| devices/b3soidd | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| devices/b3soidd_output | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| devices/b3soifd | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| devices/b3soifd_output | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| devices/b3soipd | 4.27ms | skip | 6.97ms | 45.91ms | skip | 1.6x | - | - | - | 7.3 | 12.6 | 56.0 | - | 3.52e-7 | 3.52e-7 | PASS | - | - | SKIP | 3.52e-7 | 3.52e-7 | PASS | - | - | SKIP |
| devices/b3soipd_output | 21.33ms | skip | 31.41ms | 71.57ms | skip | 1.5x | 1.4x | - | - | 7.3 | 12.6 | 56.3 | - | 2.05e-8 | 8.23e-9 | PASS | - | - | SKIP | 2.05e-8 | 8.23e-9 | PASS | - | - | SKIP |
| devices/b4soi | 4.47ms | skip | 6.82ms | skip | skip | 1.5x | - | - | - | 7.3 | 12.2 | - | - | 1.51e-7 | 1.51e-7 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/b4soi_output | 14.97ms | skip | 18.54ms | skip | skip | 1.2x | 1.0x | - | - | 7.3 | 12.3 | - | - | 1.27e-10 | 4.94e-11 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/bjt_npn | 3.80ms | skip | 6.26ms | 44.80ms | skip | 1.6x | - | - | - | 6.2 | 12.1 | 55.6 | - | 7.36e-8 | 7.36e-8 | PASS | - | - | SKIP | 6.20e-6 | 6.20e-6 | PASS | - | - | SKIP |
| devices/bjt_npn_early | 7.21ms | skip | 9.87ms | 72.86ms | skip | 1.4x | - | - | - | 5.7 | 12.1 | 55.5 | - | 1.43e-7 | 4.50e-9 | PASS | - | - | SKIP | 3.51e-7 | 1.86e-7 | PASS | - | - | SKIP |
| devices/bjt_npn_gummel | 4.73ms | skip | 6.49ms | 48.96ms | skip | 1.4x | - | - | - | 5.6 | 12.4 | 56.0 | - | 5.69e-8 | 1.05e-8 | PASS | - | - | SKIP | 5.91e-6 | 1.58e-6 | PASS | - | - | SKIP |
| devices/bjt_npn_high_injection | 4.56ms | skip | 8.70ms | 49.09ms | skip | 1.9x | - | - | - | 5.9 | 12.1 | 56.0 | - | 6.93e-8 | 2.98e-8 | PASS | - | - | SKIP | 5.84e-6 | 2.52e-6 | PASS | - | - | SKIP |
| devices/bjt_npn_output | 8.35ms | skip | 9.44ms | 79.96ms | skip | 1.1x | - | - | - | 5.7 | 12.1 | 55.3 | - | 5.44e-7 | 1.49e-8 | PASS | - | - | SKIP | 1.32e-6 | 4.84e-7 | PASS | - | - | SKIP |
| devices/bjt_npn_saturation | 7.12ms | skip | 8.04ms | 64.64ms | skip | 1.1x | - | - | - | 5.7 | 12.1 | 55.6 | - | 3.71e-7 | 2.18e-8 | PASS | - | - | SKIP | 3.59e-6 | 1.51e-6 | PASS | - | - | SKIP |
| devices/bjt_npn_temp | 6.35ms | skip | 7.66ms | 54.48ms | skip | 1.2x | - | - | - | 6.0 | 12.1 | 55.5 | - | 1.22e-7 | 2.52e-8 | PASS | - | - | SKIP | 1.06e-5 | 2.44e-6 | PASS | - | - | SKIP |
| devices/bjt_pnp | 5.70ms | skip | 6.81ms | 43.42ms | skip | 1.2x | - | - | - | 5.9 | 12.3 | 55.6 | - | 6.87e-8 | 6.87e-8 | PASS | - | - | SKIP | 6.05e-6 | 6.05e-6 | PASS | - | - | SKIP |
| devices/bjt_pnp_output | 9.19ms | skip | 9.46ms | 79.92ms | skip | 1.0x | - | - | - | 5.6 | 12.1 | 55.1 | - | 4.08e-7 | 1.19e-8 | PASS | - | - | SKIP | 1.23e-6 | 4.49e-7 | PASS | - | - | SKIP |
| devices/bsim1 | 6.63ms | skip | 10.73ms | skip | skip | 1.6x | 1.3x | - | - | 5.9 | 12.0 | - | - | 9.64e-6 | 9.66e-7 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/bsim2 | 8.72ms | skip | 10.06ms | skip | skip | 1.2x | - | - | - | 6.0 | 12.0 | - | - | 4.26e-6 | 8.63e-7 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/bsim2_ngspice | 9.57ms | skip | 8.94ms | skip | skip | 0.9x | - | - | - | 6.2 | 12.1 | - | - | 3.63e-7 | 1.55e-7 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/bsim3 | 5.72ms | skip | 6.63ms | 45.13ms | skip | 1.2x | - | - | - | 6.4 | 12.3 | 55.8 | - | 1.23e-16 | 1.23e-16 | PASS | - | - | SKIP | 1.12e-21 | 1.12e-21 | PASS | - | - | SKIP |
| devices/bsim3_body_effect | 6.05ms | skip | 36.19ms | 72.93ms | skip | 6.0x | 10.7x | - | - | 6.2 | 12.3 | 56.2 | - | 1.20e-13 | 3.46e-15 | PASS | - | - | SKIP | 5.03e-10 | 2.89e-10 | PASS | - | - | SKIP |
| devices/bsim3_output | 6.35ms | skip | 30.58ms | 69.21ms | skip | 4.8x | 7.8x | - | - | 6.2 | 12.0 | 56.1 | - | 1.37e-14 | 4.01e-16 | PASS | - | - | SKIP | 3.91e-10 | 1.29e-10 | PASS | - | - | SKIP |
| devices/bsim3_pmos | 6.25ms | skip | 29.68ms | 67.65ms | skip | 4.8x | 7.8x | - | - | 6.1 | 11.7 | 56.3 | - | 3.69e-14 | 1.04e-15 | PASS | - | - | SKIP | 8.89e-10 | 3.67e-10 | PASS | - | - | SKIP |
| devices/bsim3_temp | 5.99ms | skip | 33.73ms | 73.03ms | skip | 5.6x | 10.0x | - | - | 6.2 | 12.1 | 56.2 | - | 1.55e-13 | 4.09e-15 | PASS | - | - | SKIP | 7.55e-10 | 4.10e-10 | PASS | - | - | SKIP |
| devices/bsim3_transfer | 4.52ms | skip | 13.62ms | 51.92ms | skip | 3.0x | - | - | - | 6.2 | 12.4 | 56.2 | - | 8.31e-13 | 4.37e-14 | PASS | - | - | SKIP | 5.87e-10 | 4.09e-10 | PASS | - | - | SKIP |
| devices/bsim4 | 3.79ms | skip | 6.06ms | 46.83ms | skip | 1.6x | - | - | - | 6.9 | 12.4 | 55.9 | - | 3.14e-6 | 3.14e-6 | PASS | - | - | SKIP | 3.14e-6 | 3.14e-6 | PASS | - | - | SKIP |
| devices/bsim4_output | 13.32ms | skip | 19.54ms | 60.24ms | skip | 1.5x | 1.3x | - | - | 6.6 | 12.2 | 55.6 | - | 2.52e-11 | 1.67e-11 | PASS | - | - | SKIP | 1.22e-11 | 8.49e-12 | PASS | - | - | SKIP |
| devices/bsim4_pmos | 9.40ms | skip | 19.67ms | 61.30ms | skip | 2.1x | 2.2x | - | - | 6.6 | 12.3 | 56.1 | - | 5.58e-9 | 1.81e-9 | PASS | - | - | SKIP | 1.27e-9 | 3.92e-10 | PASS | - | - | SKIP |
| devices/bsim4_transfer | 6.87ms | skip | 11.16ms | 51.99ms | skip | 1.6x | 1.3x | - | - | 6.7 | 12.4 | 55.7 | - | 4.34e-9 | 1.99e-9 | PASS | - | - | SKIP | 1.42e-9 | 6.08e-10 | PASS | - | - | SKIP |
| devices/bsource | 3.64ms | skip | 6.07ms | skip | skip | 1.7x | - | - | - | 5.6 | 12.0 | - | - | 9.35e-16 | 2.74e-16 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/capacitor | 4.04ms | skip | 7.33ms | 43.50ms | skip | 1.8x | - | - | - | 5.4 | 12.1 | 55.6 | - | 1.95e-15 | 1.85e-15 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| devices/capacitor_ac | 3.65ms | skip | 7.42ms | 45.84ms | skip | 2.0x | - | - | - | 5.7 | 12.1 | 55.5 | - | 1.41e-14 | 2.17e-15 | PASS | - | - | SKIP | 1.50e-14 | 2.32e-15 | PASS | - | - | SKIP |
| devices/cccs | 3.78ms | skip | 7.65ms | 45.27ms | skip | 2.0x | - | - | - | 5.5 | 12.1 | 54.9 | - | 0.00e0 | 0.00e0 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| devices/ccvs | 3.34ms | skip | 7.41ms | 43.91ms | skip | 2.2x | - | - | - | 5.5 | 12.1 | 54.9 | - | 0.00e0 | 0.00e0 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| devices/coupled_tlines | 10.79ms | skip | 9.60ms | skip | skip | 0.9x | - | - | - | 6.0 | 12.4 | - | - | 9.62e-2 | 2.54e-2 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/cswitch | 5.08ms | skip | 7.20ms | skip | skip | 1.4x | - | - | - | 5.8 | 12.0 | - | - | 1.00e-15 | 7.02e-16 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/diode | 3.13ms | skip | 7.12ms | 44.53ms | skip | 2.3x | - | - | - | 5.9 | 12.4 | 56.2 | - | 1.51e-7 | 1.51e-7 | PASS | - | - | SKIP | 1.27e-5 | 1.27e-5 | PASS | - | - | SKIP |
| devices/diode_breakdown | 3.53ms | skip | 7.14ms | 51.50ms | skip | 2.0x | - | - | - | 5.9 | 12.0 | 55.0 | - | 2.01e-3 | 1.63e-4 | PASS | - | - | SKIP | 2.01e-3 | 1.64e-4 | PASS | - | - | SKIP |
| devices/diode_capacitance | 3.61ms | skip | 10.00ms | 43.77ms | skip | 2.8x | - | - | - | 5.9 | 12.4 | 55.7 | - | 4.65e-15 | 7.59e-16 | PASS | - | - | SKIP | 5.36e-15 | 9.18e-16 | PASS | - | - | SKIP |
| devices/diode_high_injection | 4.16ms | skip | 7.63ms | 50.65ms | skip | 1.8x | - | - | - | 5.6 | 12.2 | 55.8 | - | 5.09e-9 | 3.70e-9 | PASS | - | - | SKIP | 2.33e-4 | 1.71e-4 | PASS | - | - | SKIP |
| devices/diode_iv_sweep | 4.08ms | skip | 8.32ms | 64.80ms | 10.64ms | 2.0x | - | - | - | 5.6 | 12.1 | 55.6 | 12.1 | 2.28e-8 | 4.10e-9 | PASS | - | - | SKIP | 1.92e-6 | 3.76e-7 | PASS | 4.20e-6 | 3.46e-7 | PASS |
| devices/diode_recombination | 6.03ms | skip | 6.95ms | 51.61ms | skip | 1.2x | - | - | - | 5.7 | 12.1 | 55.3 | - | 3.63e-8 | 1.06e-8 | PASS | - | - | SKIP | 3.08e-6 | 9.08e-7 | PASS | - | - | SKIP |
| devices/diode_temp | 4.41ms | skip | 7.68ms | 64.86ms | skip | 1.7x | - | - | - | 5.7 | 12.1 | 55.4 | - | 6.02e-8 | 1.81e-8 | PASS | - | - | SKIP | 5.08e-6 | 1.65e-6 | PASS | - | - | SKIP |
| devices/hfet1 | 4.39ms | skip | 6.94ms | skip | skip | 1.6x | - | - | - | 6.0 | 12.0 | - | - | 1.00e-9 | 1.00e-9 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/hfet1_output | 5.03ms | skip | 8.70ms | skip | skip | 1.7x | - | - | - | 5.9 | 11.8 | - | - | 8.04e-4 | 2.20e-4 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/hfet2 | 3.46ms | skip | 6.41ms | skip | skip | 1.9x | - | - | - | 6.3 | 11.9 | - | - | 4.30e-8 | 4.30e-8 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/hfet2_output | 8.76ms | skip | 9.35ms | skip | skip | 1.1x | - | - | - | 6.2 | 12.1 | - | - | 3.63e-7 | 2.90e-8 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/hfet_id_vgs | 4.31ms | skip | 6.81ms | skip | skip | 1.6x | - | - | - | 6.2 | 12.0 | - | - | 8.23e-10 | 6.44e-10 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/hfet_inverter | 8.53ms | skip | 10.58ms | skip | skip | 1.2x | 0.8x | - | - | 6.3 | 12.4 | - | - | 3.18e-2 | 2.85e-3 | FAIL | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/hicum2 | 4.21ms | skip | 7.21ms | skip | skip | 1.7x | - | - | - | 6.8 | 12.2 | - | - | 3.71e-10 | 3.71e-10 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/hicum2_gummel | 6.00ms | skip | 7.96ms | skip | skip | 1.3x | - | - | - | 6.6 | 12.3 | - | - | 2.70e-12 | 2.38e-12 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/hicum2_output | 18.61ms | skip | 15.83ms | skip | skip | 0.9x | 0.6x | - | - | 6.4 | 11.9 | - | - | 4.30e-12 | 2.24e-12 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/hisim2 | 52.91ms | skip | 23.31ms | skip | skip | 0.4x | 0.3x | - | - | 8.0 | 12.4 | - | - | 4.22e-8 | 1.75e-8 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/hisimhv | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| devices/inductor | 4.47ms | skip | 9.02ms | 45.39ms | skip | 2.0x | - | - | - | 5.4 | 12.0 | 56.0 | - | 6.66e-16 | 6.59e-16 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| devices/inductor_ac | 4.76ms | skip | 6.97ms | 46.20ms | skip | 1.5x | - | - | - | 5.7 | 12.4 | 55.9 | - | 1.10e-14 | 1.99e-15 | PASS | - | - | SKIP | 1.17e-14 | 2.11e-15 | PASS | - | - | SKIP |
| devices/isource | 4.19ms | skip | 7.03ms | 43.50ms | skip | 1.7x | - | - | - | 5.4 | 12.1 | 55.1 | - | 0.00e0 | 0.00e0 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| devices/jfet | 3.33ms | skip | 6.43ms | 42.11ms | skip | 1.9x | - | - | - | 6.1 | 12.1 | 55.8 | - | 1.78e-16 | 1.78e-16 | PASS | - | - | SKIP | 2.38e-12 | 2.38e-12 | PASS | - | - | SKIP |
| devices/jfet2 | 8.26ms | skip | 9.81ms | 78.29ms | skip | 1.2x | - | - | - | 5.9 | 12.1 | 55.2 | - | 1.00e-11 | 5.65e-12 | PASS | - | - | SKIP | 3.53e-3 | 1.63e-3 | FAIL | - | - | SKIP |
| devices/jfet_output | 6.02ms | skip | 9.33ms | 78.87ms | skip | 1.5x | - | - | - | 5.9 | 11.9 | 55.7 | - | 1.65e-12 | 7.92e-14 | PASS | - | - | SKIP | 3.73e-17 | 8.94e-19 | PASS | - | - | SKIP |
| devices/jfet_transfer | 4.61ms | skip | 7.69ms | 50.87ms | skip | 1.7x | - | - | - | 5.9 | 12.0 | 56.0 | - | 1.40e-12 | 1.02e-13 | PASS | - | - | SKIP | 1.18e-10 | 8.57e-12 | PASS | - | - | SKIP |
| devices/jfet_vds_vgs | 4.89ms | skip | 7.36ms | 46.57ms | skip | 1.5x | - | - | - | 5.9 | 12.2 | 55.3 | - | 3.10e-6 | 3.48e-7 | PASS | - | - | SKIP | 1.73e-18 | 4.08e-19 | PASS | - | - | SKIP |
| devices/kinduc | 4.51ms | skip | 8.02ms | 50.23ms | skip | 1.8x | - | - | - | 5.9 | 12.1 | 55.3 | - | 2.75e-4 | 1.65e-4 | PASS | - | - | SKIP | 8.33e-4 | 1.83e-4 | PASS | - | - | SKIP |
| devices/lossy_tline | 13.62ms | skip | 12.67ms | 49.13ms | skip | 0.9x | 0.6x | - | - | 6.2 | 12.1 | 55.5 | - | 5.80e-15 | 1.44e-15 | PASS | - | - | SKIP | 2.83e-3 | 9.39e-4 | PASS | - | - | SKIP |
| devices/mesa | 3.65ms | skip | 6.71ms | skip | skip | 1.8x | - | - | - | 6.2 | 12.1 | - | - | 1.24e-6 | 1.24e-6 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/mesa_inverter | 5.86ms | skip | 7.74ms | skip | skip | 1.3x | - | - | - | 6.7 | 12.4 | - | - | 6.36e-4 | 1.55e-4 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/mesa_oscillator | skip | skip | 22.19ms | skip | skip | - | - | - | - | - | 12.1 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| devices/mesa_output | 8.91ms | skip | 9.74ms | skip | skip | 1.1x | - | - | - | 6.1 | 12.2 | - | - | 7.54e-7 | 3.38e-8 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/mesfet | 3.44ms | skip | 7.97ms | 44.18ms | skip | 2.3x | - | - | - | 6.2 | 12.4 | 55.6 | - | 1.90e-24 | 1.90e-24 | PASS | - | - | SKIP | 1.29e-16 | 1.29e-16 | PASS | - | - | SKIP |
| devices/mesfet_output | 6.41ms | skip | 9.53ms | 75.41ms | skip | 1.5x | - | - | - | 5.8 | 12.0 | 55.4 | - | 3.26e-11 | 2.85e-12 | PASS | - | - | SKIP | 2.74e-9 | 1.25e-10 | PASS | - | - | SKIP |
| devices/mesfet_subthreshold | 5.77ms | skip | 7.37ms | 46.63ms | skip | 1.3x | - | - | - | 5.9 | 12.1 | 55.3 | - | 1.69e-11 | 5.19e-12 | PASS | - | - | SKIP | 4.58e-4 | 1.59e-4 | PASS | - | - | SKIP |
| devices/mesfet_transfer | 4.42ms | skip | 7.08ms | 49.73ms | skip | 1.6x | - | - | - | 5.8 | 11.8 | 55.5 | - | 2.24e-12 | 1.91e-13 | PASS | - | - | SKIP | 1.88e-10 | 1.61e-11 | PASS | - | - | SKIP |
| devices/mos1_body_effect | 6.46ms | skip | 8.89ms | 80.66ms | skip | 1.4x | - | - | - | 5.8 | 12.1 | 55.2 | - | 1.24e-14 | 5.53e-15 | PASS | - | - | SKIP | 3.46e-12 | 2.46e-12 | PASS | - | - | SKIP |
| devices/mos1_large_signal | 5.93ms | skip | 9.44ms | 47.96ms | skip | 1.6x | - | - | - | 6.2 | 12.1 | 55.7 | - | 1.06e-4 | 9.93e-6 | PASS | - | - | SKIP | 2.65e-3 | 9.08e-4 | PASS | - | - | SKIP |
| devices/mos1_output | 6.68ms | skip | 9.62ms | 82.37ms | skip | 1.4x | - | - | - | 5.6 | 12.1 | 55.8 | - | 3.47e-15 | 1.04e-15 | PASS | - | - | SKIP | 1.92e-12 | 1.11e-12 | PASS | - | - | SKIP |
| devices/mos1_pmos | 5.42ms | skip | 9.14ms | 82.29ms | skip | 1.7x | - | - | - | 5.9 | 11.8 | 55.8 | - | 3.47e-15 | 1.04e-15 | PASS | - | - | SKIP | 1.92e-12 | 1.11e-12 | PASS | - | - | SKIP |
| devices/mos1_subthreshold | 6.59ms | skip | 8.17ms | 57.10ms | skip | 1.2x | - | - | - | 5.9 | 11.9 | 55.2 | - | 7.40e-16 | 4.07e-16 | PASS | - | - | SKIP | 3.77e-13 | 3.77e-13 | PASS | - | - | SKIP |
| devices/mos1_temp | 5.62ms | skip | 9.34ms | 78.94ms | skip | 1.7x | - | - | - | 5.8 | 12.1 | 55.7 | - | 2.21e-11 | 1.10e-11 | PASS | - | - | SKIP | 8.17e-8 | 4.03e-8 | PASS | - | - | SKIP |
| devices/mos1_transfer | 4.38ms | skip | 7.27ms | 53.55ms | skip | 1.7x | - | - | - | 5.8 | 12.1 | 55.4 | - | 1.24e-14 | 5.53e-15 | PASS | - | - | SKIP | 1.15e-12 | 1.15e-12 | PASS | - | - | SKIP |
| devices/mos2 | 7.22ms | skip | 10.74ms | 83.55ms | skip | 1.5x | 1.1x | - | - | 5.7 | 12.1 | 55.8 | - | 8.08e-11 | 2.83e-11 | PASS | - | - | SKIP | 7.89e-11 | 2.76e-11 | PASS | - | - | SKIP |
| devices/mos2_transfer | 4.59ms | skip | 7.50ms | 52.52ms | skip | 1.6x | - | - | - | 5.7 | 11.8 | 55.5 | - | 7.04e-11 | 3.05e-11 | PASS | - | - | SKIP | 6.92e-11 | 2.97e-11 | PASS | - | - | SKIP |
| devices/mos3 | 6.24ms | skip | 10.07ms | 86.64ms | skip | 1.6x | - | - | - | 5.9 | 11.9 | 55.4 | - | 2.03e-9 | 6.93e-10 | PASS | - | - | SKIP | 2.03e-9 | 6.92e-10 | PASS | - | - | SKIP |
| devices/mos3_transfer | 4.77ms | skip | 7.10ms | 54.93ms | skip | 1.5x | - | - | - | 5.9 | 12.1 | 55.8 | - | 1.02e-9 | 6.90e-10 | PASS | - | - | SKIP | 1.02e-9 | 6.89e-10 | PASS | - | - | SKIP |
| devices/mos6 | 6.99ms | skip | 9.60ms | 82.26ms | skip | 1.4x | - | - | - | 5.9 | 12.3 | 55.4 | - | 4.08e-9 | 1.92e-9 | PASS | - | - | SKIP | 2.23e-4 | 7.11e-5 | PASS | - | - | SKIP |
| devices/mos6_inverter | 15.95ms | skip | 19.29ms | 64.20ms | skip | 1.2x | 1.0x | - | - | 6.3 | 12.3 | 56.2 | - | 3.27e-2 | 2.20e-3 | FAIL | - | - | SKIP | 9.65e-2 | 2.34e-2 | FAIL | - | - | SKIP |
| devices/mos6_simpleinv | 4.62ms | skip | 7.64ms | 44.82ms | skip | 1.7x | - | - | - | 5.9 | 12.1 | 55.7 | - | 6.27e-5 | 4.64e-6 | PASS | - | - | SKIP | 3.67e-2 | 1.15e-2 | FAIL | - | - | SKIP |
| devices/mos9 | 5.94ms | skip | 10.93ms | 84.05ms | skip | 1.8x | 1.7x | - | - | 5.9 | 11.8 | 55.9 | - | 3.47e-15 | 1.04e-15 | PASS | - | - | SKIP | 9.87e-3 | 3.70e-3 | FAIL | - | - | SKIP |
| devices/mosfet_l1 | 3.45ms | skip | 6.42ms | 44.70ms | skip | 1.9x | - | - | - | 6.2 | 12.1 | 55.2 | - | 2.23e-16 | 2.23e-16 | PASS | - | - | SKIP | 3.84e-10 | 3.84e-10 | PASS | - | - | SKIP |
| devices/resistor | 3.64ms | skip | 7.20ms | 45.13ms | skip | 2.0x | - | - | - | 5.2 | 12.4 | 55.3 | - | 0.00e0 | 0.00e0 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| devices/resistor_sweep | 3.62ms | skip | 6.78ms | 48.94ms | skip | 1.9x | - | - | - | 5.2 | 12.1 | 54.9 | - | 1.95e-15 | 1.05e-15 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| devices/resistor_temp | skip | skip | skip | 43.86ms | skip | - | - | - | - | - | - | 55.2 | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| devices/switch | 4.25ms | skip | 6.23ms | skip | skip | 1.5x | - | - | - | 5.7 | 12.2 | - | - | 1.00e-15 | 7.02e-16 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/switch_hysteresis | 5.36ms | skip | 8.09ms | skip | skip | 1.5x | - | - | - | 5.7 | 12.4 | - | - | 1.01e-15 | 7.06e-16 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/tline | 4.37ms | skip | 7.85ms | 45.70ms | skip | 1.8x | - | - | - | 6.0 | 12.0 | 55.7 | - | 9.99e-16 | 3.97e-17 | PASS | - | - | SKIP | 2.22e-15 | 2.39e-16 | PASS | - | - | SKIP |
| devices/urc | 5.22ms | skip | 9.99ms | skip | skip | 1.9x | - | - | - | 5.4 | 11.8 | - | - | 1.14e-7 | 1.44e-8 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/urc_ac | 4.40ms | skip | 7.25ms | skip | skip | 1.6x | - | - | - | 5.7 | 12.2 | - | - | 9.09e-13 | 4.66e-13 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vbic | 3.89ms | skip | 6.99ms | skip | skip | 1.8x | - | - | - | 6.2 | 12.4 | - | - | 3.33e-6 | 3.33e-6 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vbic_ce_amp | skip | skip | 7.79ms | skip | skip | - | - | - | - | - | 12.2 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| devices/vbic_diffamp | 40.51ms | skip | skip | skip | skip | - | - | - | - | 7.7 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vbic_forced_output | 12.32ms | skip | 10.06ms | skip | skip | 0.8x | - | - | - | 6.2 | 12.1 | - | - | 4.76e-3 | 1.33e-3 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vbic_forward_gummel | 5.45ms | skip | skip | skip | skip | - | - | - | - | 6.2 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vbic_gummel | 6.04ms | skip | 7.14ms | skip | skip | 1.2x | - | - | - | 6.4 | 12.4 | - | - | 7.36e-8 | 1.08e-8 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vbic_noise_scale | 6.31ms | skip | 7.91ms | skip | skip | 1.3x | - | - | - | 7.0 | 12.4 | - | - | 1.19e-5 | 1.19e-5 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vbic_output | 16.97ms | skip | 11.74ms | skip | skip | 0.7x | 0.4x | - | - | 6.0 | 12.3 | - | - | 2.78e-7 | 7.33e-9 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vbic_temp | 7.48ms | skip | 8.37ms | skip | skip | 1.1x | - | - | - | 6.2 | 12.1 | - | - | 1.56e-3 | 6.96e-4 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vccs | 3.65ms | skip | 7.33ms | 43.01ms | skip | 2.0x | - | - | - | 5.7 | 12.1 | 55.7 | - | 0.00e0 | 0.00e0 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| devices/vcvs | 3.38ms | skip | 6.93ms | 42.82ms | skip | 2.0x | - | - | - | 5.6 | 11.8 | 54.9 | - | 0.00e0 | 0.00e0 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| devices/vdmos | 3.94ms | skip | skip | skip | skip | - | - | - | - | 6.0 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vdmos_output | 7.98ms | skip | skip | skip | skip | - | - | - | - | 5.6 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| devices/vsource | 3.66ms | skip | 7.18ms | 46.03ms | skip | 2.0x | - | - | - | 5.2 | 12.1 | 55.6 | - | 1.07e-15 | 7.77e-17 | PASS | - | - | SKIP | 3.38e-15 | 3.74e-16 | PASS | - | - | SKIP |
| digital/buffer_rc | 3.88ms | skip | 7.65ms | 46.86ms | skip | 2.0x | - | - | - | 5.4 | 12.1 | 55.8 | - | 2.18e-10 | 1.02e-11 | PASS | - | - | SKIP | 5.72e-4 | 1.56e-4 | PASS | - | - | SKIP |
| digital/clamp | 4.12ms | skip | 7.97ms | 47.00ms | skip | 1.9x | - | - | - | 6.2 | 12.1 | 54.9 | - | 1.07e-4 | 2.18e-5 | PASS | - | - | SKIP | 1.76e-2 | 4.89e-3 | FAIL | - | - | SKIP |
| digital/rc_filter_chain | 6.31ms | skip | 8.24ms | 47.69ms | skip | 1.3x | - | - | - | 5.4 | 12.4 | 55.4 | - | 3.24e-13 | 2.80e-14 | PASS | - | - | SKIP | 2.58e-3 | 5.85e-4 | PASS | - | - | SKIP |
| disto/bjt_ce | 3.37ms | skip | 6.67ms | skip | skip | 2.0x | - | - | - | 6.1 | 12.1 | - | - | - | - | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| disto/diode_clipper | 3.23ms | skip | 6.42ms | skip | skip | 2.0x | - | - | - | 6.0 | 12.4 | - | - | - | - | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| disto/mos_cs | 3.83ms | skip | 5.93ms | skip | skip | 1.6x | - | - | - | 6.4 | 11.6 | - | - | - | - | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| ensemble/corner_pathological | 3.62ms | skip | 6.08ms | 43.79ms | skip | 1.7x | - | - | - | 5.9 | 11.8 | 55.6 | - | 2.83e-7 | 2.83e-7 | PASS | - | - | SKIP | 2.39e-5 | 2.39e-5 | PASS | - | - | SKIP |
| ensemble/opamp_mc | 10.76ms | skip | 8.24ms | 46.23ms | skip | 0.8x | - | - | - | 6.1 | 12.2 | 56.1 | - | 2.38e-7 | 2.37e-7 | PASS | - | - | SKIP | 2.01e-5 | 2.00e-5 | PASS | - | - | SKIP |
| ensemble/pvt_corners | 9.27ms | skip | 13.09ms | 56.67ms | skip | 1.4x | 1.1x | - | - | 6.0 | 12.0 | 55.8 | - | 9.07e-2 | 3.92e-3 | FAIL | - | - | SKIP | 1.17e-1 | 3.02e-2 | FAIL | - | - | SKIP |
| ensemble/sweep_lanes | 3.47ms | skip | 6.48ms | 43.74ms | skip | 1.9x | - | - | - | 5.9 | 12.4 | 55.4 | - | 4.66e-5 | 7.78e-6 | PASS | - | - | SKIP | 2.33e-5 | 1.50e-5 | PASS | - | - | SKIP |
| fourier/clipped_sine | 6.65ms | skip | 8.74ms | 51.32ms | skip | 1.3x | - | - | - | 6.0 | 11.7 | 56.1 | - | 1.51e-5 | 2.18e-6 | PASS | - | - | SKIP | 4.31e-4 | 1.22e-4 | PASS | - | - | SKIP |
| fourier/sine_1k | 4.04ms | skip | 6.96ms | 49.33ms | skip | 1.7x | - | - | - | 5.8 | 12.2 | 55.6 | - | 9.77e-6 | 6.85e-6 | PASS | - | - | SKIP | 2.46e-4 | 1.28e-4 | PASS | - | - | SKIP |
| fourier/square_harmonics | 6.48ms | skip | 9.69ms | 61.00ms | skip | 1.5x | - | - | - | 5.7 | 12.4 | 55.8 | - | 2.70e-4 | 1.80e-5 | PASS | - | - | SKIP | 2.73e-4 | 8.63e-5 | PASS | - | - | SKIP |
| golden/ac | 3.40ms | skip | 6.59ms | 42.89ms | skip | 1.9x | - | - | - | 5.7 | 12.3 | 55.8 | - | 1.16e-15 | 3.81e-16 | PASS | - | - | SKIP | 1.46e-15 | 4.67e-16 | PASS | - | - | SKIP |
| golden/dc | 3.97ms | skip | 7.33ms | 44.48ms | skip | 1.8x | - | - | - | 5.2 | 11.8 | 55.2 | - | 1.18e-16 | 3.57e-17 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| golden/dcmatch | 3.74ms | skip | skip | skip | skip | - | - | - | - | 5.4 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/disto | 3.55ms | skip | 8.36ms | skip | skip | 2.4x | - | - | - | 6.3 | 12.0 | - | - | - | - | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/envelope | 3.50ms | skip | skip | skip | skip | - | - | - | - | 5.5 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/four | 4.99ms | skip | 6.89ms | 52.92ms | skip | 1.4x | - | - | - | 6.2 | 12.0 | 55.6 | - | 1.17e-4 | 1.46e-5 | PASS | - | - | SKIP | 2.98e-3 | 6.86e-4 | PASS | - | - | SKIP |
| golden/hb | 3.88ms | skip | skip | skip | skip | - | - | - | - | 5.8 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/matex | 3.64ms | skip | skip | skip | skip | - | - | - | - | 5.7 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/mc | 3.66ms | skip | skip | skip | skip | - | - | - | - | 5.2 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/noise | 4.15ms | skip | 7.26ms | 43.78ms | skip | 1.7x | - | - | - | 5.4 | 11.5 | 55.5 | - | 2.58e-13 | 2.58e-13 | PASS | - | - | SKIP | - | - | N/A | - | - | SKIP |
| golden/op | 3.71ms | skip | 7.04ms | 43.31ms | skip | 1.9x | - | - | - | 5.2 | 12.4 | 55.0 | - | 4.34e-19 | 4.34e-19 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| golden/pac | 5.17ms | skip | skip | skip | skip | - | - | - | - | 5.4 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/pnoise | 3.85ms | skip | skip | skip | skip | - | - | - | - | 5.5 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/pss | 4.56ms | skip | skip | skip | skip | - | - | - | - | 5.7 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/pxf | 4.26ms | skip | skip | skip | skip | - | - | - | - | 5.7 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/pz | 3.42ms | skip | skip | skip | skip | - | - | - | - | 5.7 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/qpss | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| golden/sens | 4.05ms | skip | 8.96ms | skip | skip | 2.2x | - | - | - | 5.2 | 11.8 | - | - | 2.84e-11 | 2.84e-11 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/sp | 3.90ms | skip | 7.16ms | skip | skip | 1.8x | - | - | - | 5.4 | 12.1 | - | - | 8.20e-16 | 3.92e-16 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/stb | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| golden/temp | 3.08ms | skip | 6.48ms | skip | skip | 2.1x | - | - | - | 5.2 | 11.9 | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/tf | 3.26ms | skip | 6.16ms | skip | skip | 1.9x | - | - | - | 5.4 | 12.1 | - | - | 0.00e0 | 0.00e0 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| golden/tran | 3.79ms | skip | 7.01ms | 43.61ms | skip | 1.8x | - | - | - | 5.4 | 12.1 | 55.9 | - | 1.07e-13 | 2.32e-14 | PASS | - | - | SKIP | 7.65e-4 | 2.02e-4 | PASS | - | - | SKIP |
| golden/tran_noise | 3.31ms | skip | skip | skip | skip | - | - | - | - | 5.7 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| hb/diode_clipper | 4.54ms | skip | skip | skip | skip | - | - | - | - | 6.3 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| hb/rc_single_tone | 3.61ms | skip | skip | skip | skip | - | - | - | - | 5.5 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| hb/tline_guard | 5.11ms | skip | skip | skip | skip | - | - | - | - | 6.0 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| layout/capacitive_divider_tran | 9.14ms | skip | 10.45ms | 45.82ms | skip | 1.1x | - | - | - | 5.4 | 11.8 | 55.6 | - | 2.50e-6 | 2.50e-6 | PASS | - | - | SKIP | 1.00e-5 | 3.61e-6 | PASS | - | - | SKIP |
| layout/coupled_ac | 4.34ms | skip | 6.51ms | 43.53ms | skip | 1.5x | - | - | - | 5.9 | 12.1 | 55.8 | - | 2.38e-15 | 5.65e-16 | PASS | - | - | SKIP | 2.38e-15 | 5.88e-16 | PASS | - | - | SKIP |
| layout/fanout_tran | 31.60ms | skip | 63.75ms | 219.99ms | skip | 2.0x | 2.0x | - | - | 5.7 | 12.1 | 55.8 | - | 7.06e-13 | 4.19e-13 | PASS | - | - | SKIP | 9.17e-6 | 3.32e-7 | PASS | - | - | SKIP |
| layout/mesh_op | 4.35ms | skip | 7.65ms | 46.78ms | skip | 1.8x | - | - | - | 5.7 | 12.4 | 56.0 | - | 1.22e-15 | 1.22e-15 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| layout/metal_island_tran | 11.09ms | skip | 11.51ms | 45.34ms | skip | 1.0x | 0.7x | - | - | 5.1 | 11.7 | 56.0 | - | 1.00e-12 | 7.89e-13 | PASS | - | - | SKIP | 1.11e-16 | 3.12e-17 | PASS | - | - | SKIP |
| medium/ladder_filter | 4.35ms | skip | 6.51ms | 46.14ms | skip | 1.5x | - | - | - | 5.7 | 12.4 | 56.1 | - | 4.98e-13 | 6.01e-14 | PASS | - | - | SKIP | 5.45e-13 | 6.58e-14 | PASS | - | - | SKIP |
| medium/rc_ladder_50 | 6.79ms | skip | 9.87ms | 50.93ms | skip | 1.5x | - | - | - | 5.7 | 12.1 | 55.8 | - | - | - | N/A | - | - | SKIP | 9.65e-3 | 1.43e-3 | FAIL | - | - | SKIP |
| medium/resistor_mesh | 4.18ms | skip | 11.02ms | 46.74ms | skip | 2.6x | - | - | - | 5.4 | 12.3 | 56.0 | - | 5.88e-15 | 5.88e-15 | PASS | - | - | SKIP | 1.11e-16 | 1.11e-16 | PASS | - | - | SKIP |
| mosfet/cmos_inverter | 3.81ms | skip | 6.94ms | 46.75ms | skip | 1.8x | - | - | - | 5.9 | 12.2 | 55.2 | - | 6.44e-4 | 8.37e-5 | PASS | - | - | SKIP | 2.58e-8 | 2.77e-9 | PASS | - | - | SKIP |
| mosfet/nand2 | 3.48ms | skip | 6.91ms | 44.32ms | skip | 2.0x | - | - | - | 5.8 | 11.9 | 55.6 | - | 9.58e-19 | 9.58e-19 | PASS | - | - | SKIP | 1.49e-9 | 1.49e-9 | PASS | - | - | SKIP |
| mosfet/nmos_cs | 6.46ms | skip | 8.04ms | 45.68ms | skip | 1.2x | - | - | - | 6.2 | 11.9 | 55.2 | - | 2.03e-5 | 2.84e-6 | PASS | - | - | SKIP | 4.91e-4 | 2.30e-4 | PASS | - | - | SKIP |
| ngspice/behavioral_bsrc | 3.51ms | skip | 6.33ms | 43.08ms | skip | 1.8x | - | - | - | 5.6 | 12.3 | 55.2 | - | 1.18e-15 | 3.33e-16 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| ngspice/diffpair | skip | skip | 7.68ms | skip | skip | - | - | - | - | - | 12.2 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| ngspice/fourbitadder | 40.14ms | skip | 18.18ms | 60.54ms | skip | 0.5x | 0.3x | - | - | 6.9 | 13.4 | 57.5 | - | 1.59e-4 | 2.91e-5 | PASS | - | - | SKIP | 2.13e-4 | 7.27e-5 | PASS | - | - | SKIP |
| ngspice/lowpass_filter | 3.04ms | skip | 6.83ms | 44.31ms | skip | 2.2x | - | - | - | 5.7 | 12.1 | 56.1 | - | 1.16e-15 | 3.34e-16 | PASS | - | - | SKIP | 1.75e-15 | 4.72e-16 | PASS | - | - | SKIP |
| ngspice/mosamp | 12.85ms | skip | 429.10ms | 54.81ms | skip | 33.4x | 44.0x | - | - | 6.0 | 12.2 | 56.4 | - | 2.12e-2 | 5.82e-3 | FAIL | - | - | SKIP | 2.72e-2 | 4.72e-3 | FAIL | - | - | SKIP |
| ngspice/mosmem | 5.97ms | skip | 9.40ms | 45.32ms | skip | 1.6x | - | - | - | 5.8 | 11.8 | 55.6 | - | 8.89e-4 | 2.57e-4 | PASS | - | - | SKIP | 9.70e-4 | 4.35e-4 | PASS | - | - | SKIP |
| ngspice/rc | 3.60ms | skip | 6.43ms | 45.06ms | skip | 1.8x | - | - | - | 5.5 | 12.1 | 55.2 | - | 1.58e-15 | 7.97e-16 | PASS | - | - | SKIP | 1.70e-3 | 4.15e-4 | PASS | - | - | SKIP |
| ngspice/rca3040 | 11.56ms | skip | 9.88ms | 51.19ms | skip | 0.9x | - | - | - | 6.7 | 12.3 | 55.9 | - | 7.76e-3 | 4.51e-3 | FAIL | - | - | SKIP | 2.51e-2 | 8.32e-3 | FAIL | - | - | SKIP |
| ngspice/res_array | 4.96ms | skip | 7.48ms | skip | skip | 1.5x | - | - | - | 5.7 | 11.8 | - | - | 8.64e-5 | 1.69e-5 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| ngspice/res_partition | 3.27ms | skip | 6.16ms | skip | skip | 1.9x | - | - | - | 5.5 | 12.1 | - | - | 2.55e-15 | 6.49e-16 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| ngspice/res_simple | 5.01ms | skip | 6.51ms | 44.75ms | skip | 1.3x | - | - | - | 5.2 | 12.0 | 55.4 | - | 1.36e-20 | 1.24e-20 | PASS | - | - | SKIP | 1.36e-20 | 6.06e-21 | PASS | - | - | SKIP |
| ngspice/rtlinv | 5.49ms | skip | 7.93ms | 46.25ms | skip | 1.4x | - | - | - | 6.5 | 12.0 | 55.5 | - | 1.46e-3 | 4.11e-4 | PASS | - | - | SKIP | 1.42e-2 | 2.08e-3 | FAIL | - | - | SKIP |
| ngspice/schmitt | 22.08ms | skip | 13.39ms | 76.71ms | skip | 0.6x | 0.4x | - | - | 6.5 | 12.3 | 55.8 | - | 1.59e-3 | 6.58e-5 | PASS | - | - | SKIP | 1.49e-3 | 7.59e-5 | PASS | - | - | SKIP |
| ngspice/sin_source | 4.21ms | skip | 9.52ms | 50.32ms | skip | 2.3x | - | - | - | 5.4 | 11.9 | 55.2 | - | 6.44e-15 | 3.33e-15 | PASS | - | - | SKIP | 1.13e-3 | 2.11e-4 | PASS | - | - | SKIP |
| ngspice/tran_pulse | 3.82ms | skip | 7.07ms | 46.77ms | skip | 1.8x | - | - | - | 5.4 | 12.4 | 55.7 | - | 7.65e-14 | 7.46e-15 | PASS | - | - | SKIP | 1.20e-3 | 2.60e-4 | PASS | - | - | SKIP |
| noise/amp_noise | 6.04ms | skip | 6.17ms | 43.34ms | skip | 1.0x | - | - | - | 6.1 | 12.2 | 55.7 | - | 5.59e-11 | 5.59e-11 | PASS | - | - | SKIP | - | - | N/A | - | - | SKIP |
| noise/bjt_flicker | 4.28ms | skip | 6.68ms | 45.78ms | skip | 1.6x | - | - | - | 6.2 | 12.0 | 55.8 | - | 1.47e-9 | 1.47e-9 | PASS | - | - | SKIP | - | - | N/A | - | - | SKIP |
| noise/rc_noise | 3.96ms | skip | 6.64ms | 45.45ms | skip | 1.7x | - | - | - | 6.0 | 12.3 | 55.3 | - | 2.37e-11 | 2.37e-11 | PASS | - | - | SKIP | - | - | N/A | - | - | SKIP |
| noise/resistor_noise | 3.41ms | skip | 7.23ms | 44.14ms | skip | 2.1x | - | - | - | 5.4 | 12.1 | 55.9 | - | 1.00e-12 | 1.00e-12 | PASS | - | - | SKIP | - | - | N/A | - | - | SKIP |
| op/voltage_divider | 3.84ms | skip | 6.72ms | 44.22ms | 9.39ms | 1.7x | - | - | - | 5.2 | 11.8 | 55.2 | 11.9 | 0.00e0 | 0.00e0 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | 0.00e0 | 0.00e0 | PASS |
| parser/hspice_suffix | 3.51ms | skip | 6.44ms | 43.33ms | skip | 1.8x | - | - | - | 5.5 | 12.2 | 55.9 | - | 1.07e-15 | 5.42e-16 | PASS | - | - | SKIP | 1.78e-16 | 6.50e-17 | PASS | - | - | SKIP |
| parser/ngspice_syntax | 4.47ms | skip | 8.30ms | 45.07ms | skip | 1.9x | - | - | - | 5.4 | 12.2 | 55.4 | - | 3.35e-15 | 7.47e-16 | PASS | - | - | SKIP | 2.76e-15 | 6.33e-16 | PASS | - | - | SKIP |
| parser/subckt_params | 3.92ms | skip | 7.79ms | 45.98ms | skip | 2.0x | - | - | - | 5.5 | 12.2 | 55.6 | - | 2.78e-7 | 1.50e-7 | PASS | - | - | SKIP | 1.51e-6 | 9.37e-7 | PASS | - | - | SKIP |
| power/buck_open | 5.73ms | skip | 11.77ms | 56.34ms | skip | 2.1x | 2.2x | - | - | 6.2 | 12.3 | 55.6 | - | 5.67e-6 | 1.07e-6 | PASS | - | - | SKIP | 3.37e-5 | 1.29e-5 | PASS | - | - | SKIP |
| power/rectifier | 7.74ms | skip | 15.39ms | 118.12ms | skip | 2.0x | 2.0x | - | - | 6.2 | 12.3 | 55.8 | - | 9.53e-5 | 7.41e-6 | PASS | - | - | SKIP | 4.98e-2 | 2.66e-3 | FAIL | - | - | SKIP |
| power/zener_reg | 3.72ms | skip | 7.50ms | 44.56ms | skip | 2.0x | - | - | - | 5.9 | 12.1 | 55.5 | - | 9.93e-5 | 2.15e-5 | PASS | - | - | SKIP | 6.46e-6 | 3.20e-6 | PASS | - | - | SKIP |
| promote/dense_sweep | 4.80ms | skip | 9.99ms | 74.78ms | skip | 2.1x | - | - | - | 5.7 | 12.4 | 55.5 | - | 2.21e-7 | 1.71e-7 | PASS | - | - | SKIP | 1.86e-5 | 1.44e-5 | PASS | - | - | SKIP |
| promote/long_tran | 16.67ms | skip | 42.89ms | 127.38ms | skip | 2.6x | 2.7x | - | - | 5.5 | 12.0 | 55.5 | - | 1.91e-14 | 5.93e-15 | PASS | - | - | SKIP | 1.04e-4 | 1.82e-5 | PASS | - | - | SKIP |
| promote/mc_small | 3.70ms | skip | 6.56ms | 44.61ms | skip | 1.8x | - | - | - | 5.9 | 12.0 | 55.6 | - | 3.33e-7 | 3.33e-7 | PASS | - | - | SKIP | 2.80e-5 | 2.80e-5 | PASS | - | - | SKIP |
| pss/diode_rect_driven | 3.80ms | skip | skip | skip | skip | - | - | - | - | 6.1 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| pss/rc_driven | 3.64ms | skip | skip | skip | skip | - | - | - | - | 5.7 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| pss/rlc_driven | 3.83ms | skip | skip | skip | skip | - | - | - | - | 5.9 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| pz/filt_bridge_t | skip | skip | 6.19ms | 43.10ms | skip | - | - | - | - | - | 12.0 | 55.0 | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| pz/filt_multistage | skip | skip | 6.90ms | skip | skip | - | - | - | - | - | 12.3 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| pz/filt_rc | skip | skip | 5.90ms | skip | skip | - | - | - | - | - | 12.1 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| pz/pz2 | skip | skip | 6.51ms | skip | skip | - | - | - | - | - | 11.8 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| pz/pzt | skip | skip | 6.30ms | skip | skip | - | - | - | - | - | 12.1 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| pz/rc_lowpass | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| pz/rlc_series | skip | skip | 6.93ms | skip | skip | - | - | - | - | - | 12.0 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| pz/simplepz | skip | skip | 6.50ms | skip | skip | - | - | - | - | - | 11.8 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| pz/two_pole | skip | skip | 7.17ms | skip | skip | - | - | - | - | - | 12.2 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| regression/bsim4_tnoimod1 | 4.54ms | skip | 7.36ms | 49.05ms | skip | 1.6x | - | - | - | 7.0 | 12.3 | 56.9 | - | 1.26e-8 | 1.26e-8 | PASS | - | - | SKIP | 1.26e-8 | 1.26e-8 | PASS | - | - | SKIP |
| regression/options_tnom | 4.19ms | skip | 7.40ms | 44.61ms | skip | 1.8x | - | - | - | 6.5 | 12.0 | 55.4 | - | 9.92e-8 | 9.92e-8 | PASS | - | - | SKIP | 1.07e-2 | 1.07e-2 | FAIL | - | - | SKIP |
| scaling/divider_chain | 5.04ms | skip | 9.20ms | 52.84ms | skip | 1.8x | - | - | - | 5.6 | 12.3 | 56.4 | - | 9.74e-14 | 9.74e-14 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| scaling/inverter_chain_1k | 1.608s | skip | 1.266s | 4.944s | skip | 0.8x | 0.8x | - | - | 12.4 | 17.9 | 72.8 | - | 7.57e-1 | 4.02e-2 | FAIL | - | - | SKIP | 1.00e0 | 1.56e-1 | FAIL | - | - | SKIP |
| scaling/inverter_chain_256 | 391.72ms | skip | 317.03ms | 985.32ms | skip | 0.8x | 0.8x | - | - | 7.4 | 13.5 | 59.3 | - | 4.41e-1 | 2.83e-2 | FAIL | - | - | SKIP | 9.63e-1 | 1.38e-1 | FAIL | - | - | SKIP |
| scaling/inverter_chain_4k | skip | 4.572s | 5.509s | 18.805s | skip | - | - | 1.2x | 1.2x | - | 37.1 | 125.8 | - | - | - | - | 8.97e-1 | 4.59e-2 | FAIL | - | - | - | - | - | - |
| scaling/parallel_inverters_100 | 34.92ms | skip | 42.98ms | 110.14ms | skip | 1.2x | 1.2x | - | - | 6.7 | 12.6 | 56.9 | - | 8.98e-3 | 5.74e-4 | PASS | - | - | SKIP | 2.63e-2 | 8.39e-3 | FAIL | - | - | SKIP |
| scaling/parallel_inverters_2000 | 698.46ms | 702.20ms | 799.41ms | 1.654s | skip | 1.1x | 1.1x | 1.1x | 1.1x | 18.7 | 24.2 | 89.4 | - | 1.17e-2 | 5.83e-4 | FAIL | 1.17e-2 | 5.83e-4 | FAIL | 4.10e-2 | 8.35e-3 | FAIL | - | - | SKIP |
| scaling/parallel_inverters_500 | 154.75ms | skip | 183.33ms | 369.88ms | skip | 1.2x | 1.2x | - | - | 9.0 | 15.1 | 64.2 | - | 8.98e-3 | 5.74e-4 | PASS | - | - | SKIP | 3.02e-2 | 8.40e-3 | FAIL | - | - | SKIP |
| scaling/rc_chain_500 | 16.85ms | skip | 24.93ms | 72.86ms | skip | 1.5x | 1.4x | - | - | 6.1 | 13.1 | 57.8 | - | 1.34e-3 | 1.27e-4 | PASS | - | - | SKIP | 7.33e-3 | 1.24e-3 | FAIL | - | - | SKIP |
| scaling/rc_ladder_100k | 1.906s | skip | 5.169s | 8.338s | skip | 2.7x | 2.7x | - | - | 145.3 | 220.1 | 835.4 | - | 2.18e-10 | 2.09e-11 | PASS | - | - | SKIP | 7.21e-3 | 2.45e-3 | FAIL | - | - | SKIP |
| scaling/rc_ladder_10k | 180.88ms | skip | 361.56ms | 784.22ms | skip | 2.0x | 2.0x | - | - | 18.7 | 32.9 | 131.9 | - | 2.18e-10 | 2.09e-11 | PASS | - | - | SKIP | 7.63e-3 | 2.13e-3 | FAIL | - | - | SKIP |
| scaling/rc_ladder_1k | 30.83ms | skip | 38.27ms | 93.89ms | skip | 1.2x | 1.2x | - | - | 6.9 | 14.2 | 62.8 | - | 2.18e-10 | 2.09e-11 | PASS | - | - | SKIP | 7.98e-3 | 2.30e-3 | FAIL | - | - | SKIP |
| scaling/resistor_grid | 8.12ms | skip | 18.11ms | 62.43ms | skip | 2.2x | 2.4x | - | - | 6.3 | 13.7 | 57.6 | - | 1.03e-13 | 1.03e-13 | PASS | - | - | SKIP | 1.11e-16 | 1.11e-16 | PASS | - | - | SKIP |
| scaling/resistor_grid_100x100 | 63.34ms | skip | 1.661s | 428.24ms | skip | 26.2x | 27.5x | - | - | 27.7 | 49.1 | 134.1 | - | 3.61e-12 | 3.61e-12 | PASS | - | - | SKIP | 2.22e-16 | 2.22e-16 | PASS | - | - | SKIP |
| scaling/resistor_grid_32x32 | 7.52ms | skip | 28.26ms | 75.35ms | skip | 3.8x | 5.1x | - | - | 6.9 | 14.6 | 61.5 | - | 2.89e-13 | 2.89e-13 | PASS | - | - | SKIP | 2.20e-16 | 2.20e-16 | PASS | - | - | SKIP |
| sens/bridge | 3.83ms | skip | 6.89ms | skip | skip | 1.8x | - | - | - | 4.9 | 11.9 | - | - | 1.90e-11 | 1.90e-11 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| sens/diffpair | skip | skip | 7.35ms | skip | skip | - | - | - | - | - | 12.3 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| sens/rc_lowpass | 5.71ms | skip | 7.40ms | skip | skip | 1.3x | - | - | - | 5.4 | 12.4 | - | - | 2.75e-12 | 2.75e-12 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| sens/voltage_divider | 3.86ms | skip | 7.12ms | skip | skip | 1.8x | - | - | - | 4.9 | 12.2 | - | - | 2.84e-11 | 2.84e-11 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| sp/lc_lowpass | 3.42ms | skip | 8.02ms | skip | skip | 2.3x | - | - | - | 5.4 | 11.9 | - | - | 1.06e-14 | 2.41e-15 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| sp/pi_attenuator | 4.63ms | skip | 6.48ms | skip | skip | 1.4x | - | - | - | 5.2 | 12.0 | - | - | 3.58e-16 | 1.63e-16 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| sp/rc_twoport | 3.80ms | skip | 7.25ms | skip | skip | 1.9x | - | - | - | 5.4 | 12.3 | - | - | 1.79e-15 | 4.96e-16 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| stb/bjt_shunt_fb | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| stb/vcvs_onepole | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| stb/vcvs_twopole | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| sweep/amp_bias_sweep | 5.04ms | skip | 7.49ms | 47.78ms | skip | 1.5x | - | - | - | 6.0 | 12.4 | 55.2 | - | 2.08e-5 | 1.67e-6 | PASS | - | - | SKIP | 3.84e-9 | 2.34e-9 | PASS | - | - | SKIP |
| sweep/cmos_inv_sizing | 3.95ms | skip | 6.82ms | 50.28ms | skip | 1.7x | - | - | - | 5.8 | 11.8 | 55.5 | - | 5.08e-4 | 2.74e-5 | PASS | - | - | SKIP | 1.27e-7 | 7.84e-9 | PASS | - | - | SKIP |
| sweep/nmos_wl_opt | 7.49ms | skip | 8.02ms | 45.85ms | skip | 1.1x | - | - | - | 6.5 | 12.4 | 56.4 | - | 6.34e-9 | 4.99e-9 | PASS | - | - | SKIP | 6.34e-9 | 4.99e-9 | PASS | - | - | SKIP |
| sweep/opamp_wl_1000 | 161.19ms | 422.36ms | 212.50ms | 425.12ms | skip | 1.3x | 1.3x | 0.5x | 0.5x | 33.8 | 24.8 | 185.6 | - | 1.42e-8 | 4.25e-9 | PASS | 2.49e-7 | 1.57e-7 | PASS | 5.29e-5 | 2.73e-5 | PASS | - | - | SKIP |
| sweep/opamp_wl_200 | 34.57ms | skip | 25.53ms | 114.42ms | skip | 0.7x | 0.6x | - | - | 11.7 | 14.7 | 65.8 | - | 1.42e-8 | 4.25e-9 | PASS | - | - | SKIP | 5.29e-5 | 2.73e-5 | PASS | - | - | SKIP |
| sweep/opamp_wl_5000 | 845.15ms | 1.165s | 3.996s | 3.496s | skip | 4.7x | 4.7x | 3.4x | 3.4x | 144.9 | 76.8 | 2542.4 | - | 1.42e-8 | 4.25e-9 | PASS | 2.97e-7 | 1.88e-7 | PASS | 5.29e-5 | 2.73e-5 | PASS | - | - | SKIP |
| sweep/pmos_wl_opt | 6.70ms | skip | 9.22ms | 45.34ms | skip | 1.4x | - | - | - | 6.6 | 12.5 | 56.0 | - | 1.06e-8 | 1.04e-8 | PASS | - | - | SKIP | 1.06e-8 | 1.04e-8 | PASS | - | - | SKIP |
| tf/diode_bias | 5.97ms | skip | 6.65ms | skip | skip | 1.1x | - | - | - | 6.0 | 12.2 | - | - | 5.44e-9 | 5.44e-9 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| tf/r_ladder | 4.07ms | skip | 6.22ms | skip | skip | 1.5x | - | - | - | 5.0 | 11.9 | - | - | 0.00e0 | 0.00e0 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| tf/voltage_divider | 3.76ms | skip | 6.81ms | skip | skip | 1.8x | - | - | - | 5.2 | 12.3 | - | - | 0.00e0 | 0.00e0 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| tline/cpl3_4_line | 8.07ms | skip | 18.23ms | skip | skip | 2.3x | 2.5x | - | - | 5.8 | 12.1 | - | - | 1.72e0 | 9.21e-1 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| tline/cpl_ibm2 | 8.30ms | skip | 6.79ms | skip | skip | 0.8x | - | - | - | 5.9 | 12.1 | - | - | 1.28e-1 | 4.26e-2 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| tline/delay_line | 4.46ms | skip | 7.90ms | 45.63ms | skip | 1.8x | - | - | - | 5.5 | 11.9 | 55.7 | - | 6.67e-4 | 2.66e-5 | PASS | - | - | SKIP | 2.50e-2 | 2.40e-3 | FAIL | - | - | SKIP |
| tline/ideal_tline | 5.01ms | skip | 7.73ms | 45.10ms | skip | 1.5x | - | - | - | 5.8 | 11.8 | 55.6 | - | 5.93e-16 | 2.09e-17 | PASS | - | - | SKIP | 2.41e-14 | 2.63e-15 | PASS | - | - | SKIP |
| tline/ltra1_1_line | 12.88ms | skip | 14.23ms | skip | skip | 1.1x | 0.8x | - | - | 6.7 | 12.1 | - | - | 2.16e-3 | 3.63e-4 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| tline/ltra2_2_line | 16.31ms | skip | 16.20ms | skip | skip | 1.0x | 0.8x | - | - | 7.2 | 12.1 | - | - | 9.65e-6 | 1.33e-6 | PASS | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| tline/terminated | 5.29ms | skip | 8.36ms | 48.36ms | skip | 1.6x | - | - | - | 5.8 | 12.1 | 55.3 | - | 1.00e-4 | 5.13e-6 | PASS | - | - | SKIP | 4.66e-15 | 2.85e-16 | PASS | - | - | SKIP |
| tline/txl1_1_line | 8.76ms | skip | 8.87ms | skip | skip | 1.0x | - | - | - | 6.0 | 12.1 | - | - | 5.70e-3 | 4.28e-4 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| tline/txl2_3_line | 7.85ms | skip | 10.13ms | skip | skip | 1.3x | - | - | - | 6.2 | 12.3 | - | - | 5.40e-3 | 3.54e-4 | N/A | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| topology/current_cutset | skip | skip | 6.13ms | skip | skip | - | - | - | - | - | 12.0 | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| topology/floating_node | 3.42ms | skip | 6.68ms | 45.05ms | skip | 2.0x | - | - | - | 5.4 | 12.2 | 54.9 | - | 5.00e-9 | 5.00e-9 | PASS | - | - | SKIP | 0.00e0 | 0.00e0 | PASS | - | - | SKIP |
| topology/voltage_loop | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| tran/fourbitadder | 39.62ms | skip | 18.01ms | 60.47ms | skip | 0.5x | 0.3x | - | - | 7.4 | 13.3 | 57.9 | - | 1.59e-4 | 2.91e-5 | PASS | - | - | SKIP | 2.13e-4 | 7.27e-5 | PASS | - | - | SKIP |
| tran/rc_pulse | 3.97ms | skip | 7.00ms | 47.00ms | skip | 1.8x | - | - | - | 5.3 | 12.4 | 55.3 | - | 7.65e-14 | 7.46e-15 | PASS | - | - | SKIP | 1.20e-3 | 2.60e-4 | PASS | - | - | SKIP |
| vacask/c6288 | skip | skip | skip | 45.05ms | 55.620s | - | - | - | - | - | - | 54.5 | 135.7 | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| vacask/graetz | 1.242s | skip | 2.615s | 14.633s | 2.551s | 2.1x | 2.1x | - | - | 6.1 | 12.0 | 55.5 | 12.1 | 4.91e-5 | 1.52e-6 | PASS | - | - | SKIP | 9.31e-5 | 2.76e-5 | PASS | 4.27e-1 | 1.89e-1 | FAIL |
| vacask/mul | 894.81ms | skip | 1.421s | 6.943s | 1.284s | 1.6x | 1.6x | - | - | 6.0 | 12.0 | 55.3 | 12.4 | 2.40e-2 | 9.12e-5 | FAIL | - | - | SKIP | 2.28e-2 | 1.14e-4 | FAIL | 9.97e-1 | 8.19e-1 | FAIL |
| vacask/rc | 423.30ms | skip | 1.451s | 9.908s | 1.264s | 3.4x | 3.4x | - | - | 5.4 | 12.0 | 55.4 | 12.5 | 8.23e-11 | 1.88e-12 | PASS | - | - | SKIP | 2.06e-5 | 2.41e-6 | PASS | 6.25e-5 | 2.76e-5 | PASS |
| vacask/ring | skip | skip | 134.81ms | skip | 1.589s | - | - | - | - | - | 12.2 | - | 12.8 | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| verilog/inverter | skip | skip | skip | skip | skip | - | - | - | - | - | - | - | - | - | - | - | - | - | SKIP | - | - | - | - | - | - |
| verilogA/diode_clamp | 11.15ms | skip | skip | skip | skip | - | - | - | - | 52.4 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
| verilogA/res_divider | 13.68ms | skip | skip | skip | skip | - | - | - | - | 52.3 | - | - | - | - | - | SKIP | - | - | SKIP | - | - | SKIP | - | - | SKIP |
