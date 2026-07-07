# GPU device evaluation

`src/analysis/gpu.zig` evaluates device planes on the GPU and hands them to
the host solver. The input is the Newton iterate `x` and the time `t`. The
output is the four planes (`g`, `rhs`, `c`, `q`) in the circuit's own slices,
bit for bit what the device kernels computed, with the ground pin added. The
sparse LU, the Newton update, the gates and the transient's LTE all stay on
the host (AGENTS.md, CPU/GPU sharing). The kernels are the host's `evalRange`
compiled for the device through `Sink(D, true, ...)`. The GPU boundary
(tapes, Model/Instance PODs, the `model_of` row tape, pattern CSC, plane
layout) is frozen, so every table here is built beside it. Each kernel reads
an instance's Model as `models[model_of[id]]`: instances whose cards bind
equal Models share a row on the device as on the host (docs/devices/abi.md,
Shared Models).

## Which batches go to the device

A batch is resident when it has a GPU payload (`eval.gpuEligible`) and its
model has a kernel image in this build. Everything else stamps on the host,
on top of the downloaded planes.

- `gpuEligible` refuses `mutable_eval`, Newton-history hooks and `State`
  without `limit`, unless VerA declares that state `.path_latch` (the
  §5.6.1.2 latches alone: b3soidd, b3soifd, hicumL2, hisim2, kinduc, mes),
  which is what the state and control kernels carry. It admits
  held-variable devices without `limit` (bsim4va, psp103; vbic13_4t
  limits and stays on the host). Their state kernel runs once per
  converged solve, from `GpuHook.update_states`, never fused into
  the per-iterate limit pass, and `stateCtl(.revert)` takes it back on a
  rejected step.
- VerA ABI 5 passes `SimState` to every kernel by value (eval, state, charge
  tape), so the cores that read `analysis()` or `$abstime` are resident too:
  the Meyer MOS models (mos1/2/3/6/9) and jfet2.
- `build.zig` emits images for every model up to 1 MB of source, so every
  model in `models/` gets one. The cold JIT costs and the reason for the
  limit are in the comment on `gpu_max_model_bytes`.

## One eval

```
x → pinned x → d_x ─┐
clear staging ──────┤
eval kernel per batch (one thread per instance, 64-wide blocks)
   writes each contribution to its own staging cell (tape order)
reduce level 1: pieces of ≤ 64 contributions   ─┐ explicit [start, end)
reduce level 2: each plane cell's pieces        ─┘ ranges, trash skipped
download g|rhs|c|q (one copy) → pinned buffer the circuit's planes point into
host batches stamp on top, ground pin
```

- **Deterministic scatter.** Atomics reorder the sum from pass to pass, and
  Newton cannot converge on a stamp that is not a function of x. The staging
  permutation (`Order`) sorts contributions by destination cell and keeps the
  serial CPU order. A run of at most 64 sums exactly as the CPU does.
  `ESPICE_GPU_EVAL_CHECK` replays each eval and reports any cell that moved.
- **Explicit ranges.** Ground and structural-zero contributions land in a
  trash tail that no range covers. The earlier layout summed each trash tail
  into a pad cell: on mos1_2000 that pad took 1,600 pieces on one thread,
  104 µs of a 170 µs eval. With explicit ranges both levels together take
  40 µs, and the reduce kernel issues its loads eight at a time ahead of the
  in-order adds.
- **Pinned landing planes.** While a context lives, the circuit's `g_vals`,
  `rhs`, `c_vals` and `q_vec` point into page-locked memory. The one download
  is the whole plane update, with no host clear and no host add. `deinit`
  copies the last planes back into the circuit's own allocations. There are
  two such buffers; see the next section.
- **Block width.** Compact models use ~255 registers a thread, so a 256-wide
  block fills an SM. 2000 inverters then ran on 8 of 24 SMs. Per eval at
  width 64 against 256: bsim4va 679 µs against 866, psp103 1071 against 1284,
  bsim3 267 against 328 (eval plus limit). `ESPICE_GPU_BLOCK` overrides it.
- **LTE tape.** The transient bounds its step by per-device charges
  (`q_tape`), and the eval kernel's frozen arguments have no slot for them.
  `arp_qtp_<model>` (`QTapeKernel`) computes the same `RealFor` charges at
  the eval's x. It is queued with every `evalQ`, so the tape comes down on
  the same wait. Before this, the GPU path fell back to the row-plane LTE,
  and its step grid drifted from the CPU's after the first step-size
  decision (bsim4_2000 differed by 0.23 relative). With the tape, it keeps
  the CPU's grid: 1.2e-11 relative on bsim4_2000, 7e-14 on psp103_2000.

## Waits per transient step

The converger announces `Circuit.evalFollows(x, t)` when the next eval is
already certain before the limit pass: on the first iterate or when the
delta gate already failed. It also announces it before the predictor's
limit pass and before the state query that precedes `evalQ`. The GPU context
then queues that eval behind the limit (or query) kernels. When the host
limiters are done with x, one wait covers both. The prefetched planes land
in the second pinned buffer, because the converger still reads the current
residual after the limit pass. `evalOnGpu` takes the prefetch only when the
x bytes and t match. `stateCtl(.commit)` and `.revert` stay queued and
unwaited, since every caller discards their result.

The device runs the same launches in the same order, so outputs are bitwise
identical to the unfused sequence (`ESPICE_GPU_NOFUSE` runs it for A/B):

| deck | waits before | waits after | per accepted step |
|---|---|---|---|
| mos1_2000 (MOS forced resident) | 2711 | 1239 | 11.5 → 5.3 |
| stress/scaling_parallel_inverters_2000 | 6738 | 3077 | 11.6 → 5.3 |
| bsim3_2000 | 1724 | 981 | 7.4 → 4.2 |
| bsim4_2000 | 2276 | 1292 | 9.5 → 5.4 |
| psp103_2000 | 1996 | 1458 | 7.6 → 5.6 |
| stress/vacask_ring | 169265 | 127421 | 8.3 → 6.2 |

Wall time moved by less than the noise on this machine: 0.49 → 0.47 s on
mos1_2000, 1.94 → 1.81 s on bsim4_2000. The ~15 µs a wait costs is small
next to device time once the reduce is fixed. bsim4va and psp103 have no
limit kernel, so their Newton evals have nothing to share a wait with.

## Choosing the backend

`--backend cuda` (or `hip`) always runs resident batches on the device.
`--backend auto` prices the query first (`GpuContext.Cost`), before the first
driver call:

- `expectedEvals` in `executor.zig` guesses the query's eval count: four per
  transient step at the deck's step, three per dc point, 30 for an operating
  point, one for small-signal analyses. Below 20, it declines.
- The host side is measured. The best of three serial evals of the eligible
  batches, into scratch planes at a spread x, is divided over the ParEval
  lanes. At x = 0 every MOSFET sits in cutoff and evaluates twice as fast.
- The device side is modelled per eval: a fixed launch-and-wait cost, the
  bus for x and the planes, the staging clear and reduce, and the kernels at
  0.12 of the host time. Driver setup is added once per process (~350 ms:
  cuInit, the context, module loads).
- The GPU wins only when 1.3 × (setup + evals × GPU per eval) is less than
  evals × CPU per eval, and the GPU is at least 2x faster per eval. The
  second test is there because the probe moves by up to 2x under load, and
  because `stress/scaling_rc_ladder_100k` (200,000 resistors and
  capacitors) runs slower per step on the GPU path than its eval times
  predict.
- An image over 1 MB of PTX that the driver has not compiled yet stays on
  the CPU, and a note says how to compile it.

The constants and their measurements are next to their definitions at the
top of `gpu.zig`. The model is static. A deck whose step count the guess
misses by a lot can be mispriced; see the `ponytail:` note on
`expectedEvals`.

JIT caching: gompute loads PTX with `cuModuleLoadData`, so the driver
compiles each image once and caches the result in `~/.nv/ComputeCache`. Its
default cap (256 MiB on older drivers) can evict a compact model's cubin. `init` raises
`CUDA_CACHE_MAXSIZE` to the 4 GiB maximum unless the user set it. For images
over 1 MB, `~/.cache/espice/gpu-jit/<hash>` records that the cache holds the
image, which is what `auto` checks. Measured cold compiles: bsim4va 15 s,
psp103 35 s, hisimhv_va 1001 s. Warm module loads take milliseconds.

## Measurements

Median wall seconds of 3 runs, whole process, on an RTX 4060 Laptop and an
i9-14900HX. The machine carried a load average of 40-60 from other builds
throughout, so single numbers can move by 2x; per-eval device times above
are steadier. "Before" is `--backend cuda` at `a13ceb3`, when bsim4va and
psp103 had no image and ran on the host, and the other eligible batches paid
the old reduce. The `*_2000` decks are not in the corpus. Each is
`stress/scaling_parallel_inverters_2000` with the model cards swapped:
default-parameter LEVEL=49 (VTH0 ±0.35), 54, 1040 (the `vacask_ring`
cards) and 73, a 10 fF load per output, `.tran 0.1n 20n`.

| deck | before cuda | cpu 1 thr | cpu 8 thr | cuda warm | cuda cold | auto picks |
|---|---|---|---|---|---|---|
| bsim3_2000 | 0.58 | 1.36 | 0.88 | 0.63 | 1.5 | GPU |
| bsim4_2000 | 17.9 | 7.8 | 3.0 | 1.9 | 12.8 | GPU |
| psp103_2000 | 15.4 | 18.9 | 5.5-28 | 3.3 | 40.2 | GPU |
| hisimhv_2000 | 80.0 | 40.5 | 21.2 | 18.1 | 1001 JIT | GPU once compiled |
| mos1_2000 | 1.7 | 0.43 | 0.58 | 0.91 | | CPU |
| stress/scaling_parallel_inverters_2000 | 2.0 | 1.49 | 1.71 | 1.50 | 1.2 | CPU |
| stress/scaling_inverter_chain_4k | 10.7 | 5.5 | 9.8 | 8.4 | | CPU |
| stress/scaling_rc_ladder_100k | 4.9 | 3.8 | 13.9 | 6.4 | | CPU |
| stress/sweep_opamp_wl_5000 | 1.7 | 0.68 | 0.70 | 0.85 | | CPU |
| stress/vacask_ring | 4.3 | 4.5 | 2.5 | 23.8 | | CPU |

These were measured before ABI 5, with the MOS models off the device: the
mos1 decks put only their capacitors on the GPU, so `cuda` there only adds the round trip, and
`auto` declines. Heavy compact models are where the GPU wins today: 2.5-5x
over one host thread and 1.2-1.7x over eight.

## Checking the GPU path

`zig build test-gpu` runs the numeric corpus with `--backend cuda` against
the same expectations as `zig build test`. At `29ae485` plus this work it
scores 599/616. The failing set is the CPU run's 13 known failures plus 4
timeouts, and no deck that passes on the CPU fails on the GPU:

- `dc/device_hisimhv` timed out on its 1001 s cold JIT and passes once the
  driver cache holds the image.
- `stress/vacask_graetz`, `vacask_mul` and `vacask_rc` have one to four
  devices and a million transient steps. An explicit `--backend cuda` pays
  ~50 µs of launch and wait per eval there, against microseconds on the host,
  which is why `auto` keeps them on the CPU.

Raw outputs of the whole corpus on both backends (CPU against CUDA):

- 32 decks with resident batches differ in value.
- The rest are bitwise equal: the device path sums in the CPU's order.
- The worst differences are oscillators and digital edges, whose step grids
  part after the first ULP-level difference: `stress/vacask_ring` (1.3
  relative, a ring oscillator's phase), `tran/bench_tran_fourbitadder` (0.11,
  at edges) and `tran/device_hfet_inverter` (1.4e-4).
  `tran/device_mesa_oscillator` differs by 2.8e-5 on the same grid, from
  contraction and fast-math on the device. All four pass or fail the same
  way on both backends.
- Everything else agrees to 5.3e-12 or better.

mos1 and mos6 no longer take the f32 Jacobian on the GPU by default. Once
they were resident (VerA ABI 5), `-Djac-f32-gpu=mos1,mos6` failed four decks
under `--backend cuda` that pass in f64: `disto/bench_disto_mos_cs` (2nd
harmonic off 0.8%), `stress/scaling_inverter_chain_256` and `_4k` (~1%) and
`stress/scaling_parallel_inverters_2000` (`i(vdd)[1]` off 10%). The option
stays for experiments.

## Post-layout results

Extracted netlists put a lot of RC between the transistors: the matrix
grows 4-12x per transistor and the LU fills, so the solve competes with
device evaluation. These decks measure where that leaves the GPU path.

**Decks.** `tests/benchmark/postlayout/gen.py` writes synthetic extracted
decks in the shape of a DSPF back-annotation: standard cells as
subcircuits, every signal net split into pi segments from the driver pin
through each load pin (one R per segment, one ground C per node), coupling
caps to the neighbouring net, and the vdd/vss rails extracted as a mesh
(per-row rails, straps every 16 cells). Four families (50-stage inverter
chains, NAND-gated 31-stage ring oscillators, a 12-level random NAND/NOR
block and a 6T SRAM array doing write, precharge and read), each with
BSIM4 (LEVEL=54, the corpus card) and PSP103 (LEVEL=1040, the vacask_ring
card), from 1k to 100k transistors and 10k to 1M R and C.
`tests/benchmark/postlayout/fetch.sh` fetches three real ones: ISCAS85
c7552 on sky130 and on IHP SG13G2 (ngspice's own KLU benchmark: 14,942
FETs and one synthetic pi per net, no license, so never vendored), and
the iic-jku TT06 TDC, a magic extraction on sky130 (2,562 FETs, extracted
C, Apache-2.0). No GF180 extracted design turned up.

```sh
nix develop .#benchmarking
tests/benchmark/postlayout/fetch.sh zig-out/postlayout/real   # optional
zig build bench-postlayout -- --iters 3 --ngspice-klu \
    --espice cpu1=--backend=cpu,--timing-in-depth \
    --espice cpu8=ESPICE_THREADS=8,--backend=cpu,--timing-in-depth \
    --espice cuda=--backend=cuda,--timing-in-depth \
    --espice auto=--backend=auto,--timing-in-depth
```

The decks have no oracle, so they live outside `tests/fixtures`. The
runner checks agreement against ngspice and VACASK as `bench` does, and
`--timing-in-depth` now prints each query's Newton split: device eval
(including the GPU wait), matrix load, LU factor, solve, and the step
update, with n and the LU fill. `ZP_LU_STATS=1` adds the structural census
of `docs/solvers/gpu-lu.md` E1.

Setup: RTX 4060 Laptop, i9-14900HX, `96807bd` rebased on `3559781`,
ngspice-45 with `.options klu`. Other sessions were held off while timing,
and a load log every 5 s marked the runs to repeat; the numbers below come
from runs with a 1-minute load under 3 (8 when the run itself used 8
threads).

### Wall time

Seconds. 1k and real decks: median of 3 after a warm-up. 10k and 100k: one
run after a warm-up. `auto` runs with one host thread. The stop time
shrinks with size (1 ns at 1k, 0.5 ns at 10k, 0.2 ns at 100k; the rings
twice that; the SRAM always 1 ns), and the 100k decks start from `uic`.

| deck | FETs | R + C | cpu 1 thr | cpu 8 thr | cuda | auto | ngspice KLU | VACASK |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| chain_bsim4_1k | 1,000 | 10.5k | 1.95 | 1.22 | 1.70 | 1.78 | 1.56 | 3.25 |
| ring_bsim4_1k | 960 | 10.0k | 3.42 | 2.02 | 2.93 | 2.99 | 2.89 | 5.27 |
| logic_bsim4_1k | 1,084 | 8.2k | 5.35 | 4.13 | 5.40 | 5.12 | 5.65 | 14.0 |
| sram_bsim4_1k | 1,032 | 3.3k | 2.14 | 1.63 | 1.92 | 1.89 | 1.81 | 2.41 |
| chain_psp103_1k | 1,000 | 10.5k | 4.10 | 3.25 | 3.29 | 3.35 | | 5.63 |
| ring_psp103_1k | 960 | 10.0k | 7.22 | 5.66 | 5.71 | 5.73 | | 8.19 |
| logic_psp103_1k | 1,084 | 8.2k | 10.15 | 9.51 | 8.93 | 9.16 | | 21.2 |
| sram_psp103_1k | 1,032 | 3.3k | 4.20 | 3.37 | 3.67 | 3.82 | | 3.86 |
| chain_bsim4_10k | 10,000 | 105k | 16.2 | 13.6 | 9.6 | 12.2 | | |
| ring_bsim4_10k | 9,984 | 103k | 25.1 | 13.9 | 15.6 | 17.4 | | |
| logic_bsim4_10k | 10,634 | 80k | 196 | 242 | 163 | 171 | | |
| sram_bsim4_10k | 10,216 | 32k | 53.7 | 49.3 | 47.7 | 47.3 | | |
| chain_psp103_10k | 10,000 | 105k | 46.1 | 50.6 | 31.9 | 38.1 | | |
| ring_psp103_10k | 9,984 | 103k | 50.8 | 45.9 | 36.0 | 37.3 | | |
| logic_psp103_10k | 10,634 | 80k | 273 | 306 | 256 | 265 | | |
| chain_bsim4_100k | 100,000 | 1.04M | 52.5 | 37.8 | 36.0 | 35.7 | | |
| ring_bsim4_100k | 99,968 | 1.03M | 100.6 | 68.3 | 64.3 | 64.4 | | |
| c7552_sky130 | 14,942 | 71k | 33.3 | 25.3 | 21.5 | 21.9 | > 2400 | |
| c7552_ihp | 14,942 | 71k | 54.6 | 33.8 | 28.4 | 27.8 | | |
| tdc_sky130 | 2,562 | 0.7k | 4.79 | 3.64 | 3.62 | 3.85 | 228 | |

ngspice on c7552_sky130 hit a 40-minute timeout at 9.2 GB (one run).
`sram_psp103_10k` ran past 25 minutes on the CPU and was dropped from the
timing; `logic_bsim4_10k`'s 8-thread run overlapped a burst of outside
load. ngspice-45 has no PSP103, and VACASK cannot take the `.lib` PDK
decks; the 10k and 100k decks ran without references to fit the window.

Agreement (the runner's comparison at rtol 1e-3): every BSIM4 1k deck
agrees with ngspice and VACASK on all four espice columns, and the TDC with
ngspice. The PSP103
decks read DIFFER against VACASK on edges only: the 50-stage chain's last
edge lands 0.4 ps later (820.6 against 820.2 ps), the ring period differs
by 0.3 ps in 500, the SRAM bitlines by 8 mV. At the earlier 5 ps step cap
espice took about 200 steps where VACASK took 777 and the chain edge was
5 ps late, which is why the decks cap the step at 2 ps.

### Where the time goes

Share of wall time, from `--timing-in-depth` on the measured run. `eval`
includes the GPU wait (upload, kernels, reduce, plane download); `LU` is
factor plus solve; `setup` is parse, expansion and binding; `other` is
everything else (step control, LTE, charge evals after acceptance,
output).

| deck | n | LU nnz | cpu1 eval / LU / setup / other | cuda eval / LU / setup / other | GPU wait per eval |
|---|---:|---:|---|---|---:|
| chain_bsim4_1k | 4.5k | 60k | 47 / 22 / 3 / 28 | 24 / 28 / 3 / 45 | 0.22 ms |
| logic_bsim4_1k | 4.0k | 99k | 31 / 53 / 1 / 15 | 18 / 58 / 1 / 23 | 0.33 ms |
| sram_psp103_1k | 10k | 126k | 33 / 37 / 9 / 21 | 19 / 43 / 11 / 27 | 0.43 ms |
| chain_bsim4_10k | 45k | 611k | 47 / 32 / 3 / 18 | 18 / 50 / 6 / 26 | 1.8 ms |
| ring_bsim4_10k | 44k | 669k | 48 / 27 / 2 / 23 | 21 / 49 / 4 / 26 | 1.8 ms |
| logic_bsim4_10k | 39k | 1.76M | 8 / 82 / 0 / 9 | 3 / 94 / 0 / 3 | 2.4 ms |
| sram_bsim4_10k | 17k | 984k | 19 / 70 / 1 / 10 | 6 / 83 / 1 / 10 | 2.1 ms |
| chain_psp103_10k | 125k | 1.38M | 44 / 35 / 8 / 13 | 23 / 51 / 12 / 14 | 3.8 ms |
| logic_psp103_10k | 124k | 2.61M | 8 / 87 / 1 / 3 | 3 / 93 / 2 / 2 | 4.0 ms |
| chain_bsim4_100k | 446k | 6.75M | 38 / 31 / 10 / 21 | 14 / 46 / 15 / 25 | 15.6 ms |
| ring_bsim4_100k | 442k | 7.28M | 39 / 33 / 5 / 23 | 14 / 53 / 8 / 25 | 15.7 ms |
| c7552_sky130 | 117k | 871k | 39 / 17 / 29 / 15 | 15 / 26 / 42 / 17 | 3.3 ms |
| c7552_ihp | 161k | 1.23M | 58 / 15 / 14 / 14 | 23 / 30 / 28 / 20 | 7.0 ms |
| tdc_sky130 | 14k | 107k | 41 / 11 / 34 / 14 | 17 / 14 / 47 / 22 | 0.58 ms |

One device eval, stage by stage (`ESPICE_GPU_STATS=phases`, which syncs
after each stage), in µs:

| deck | staging cells | upload + clear | eval kernels | reduce | download | total |
|---|---:|---:|---:|---:|---:|---:|
| chain_bsim4_10k | 8.1M | 241 | 1,513 | 213 | 321 | 2,288 |
| c7552_sky130 | 11.2M | 391 | 2,058 | 419 | 944 | 3,812 |
| chain_bsim4_100k | 80.9M | 2,892 | 11,096 | 2,416 | 3,155 | 19,559 |

The GPU cuts device eval 1.8-2.4x at 1k and 2.7-4.9x from 10k up
(c7552_ihp: 32.0 s of host eval against 6.5 s on the device), and `auto`
took the GPU for every transient here. Under `cuda` the rest of the run
decides the wall time. On the synthetic 10k and 100k decks that rest is
the host LU, 46-94% of wall time. On the real PDK decks it is setup:
`Problem creation` takes 9.2 s of c7552_sky130's 22 s, as much as the
Newton loop.

The E1 census (first full factor of each deck; `F` counts the refactor's
multiply-adds, `S_r` is the sync-free column kernel's span of
`docs/solvers/gpu-lu.md` §4.2):

| deck | fill | F | S_r | n / S_r | widest U col | F in levels < 64 wide |
|---|---:|---:|---:|---:|---:|---:|
| chain_bsim4_10k | 2.6x | 2.9M | 2,882 | 16 | 241 | 49% |
| logic_bsim4_10k | 9.2x | 170M | 3,512 | 11 | 1,170 | 99% |
| sram_bsim4_10k | 8.2x | 40.7M | 4,759 | 3.6 | 2,117 | 99% |
| chain_psp103_10k | 1.9x | 4.5M | 3,849 | 32 | 292 | 34% |
| logic_psp103_10k | 3.8x | 201M | 3,983 | 31 | 1,269 | 99% |
| chain_bsim4_100k | 2.9x | 74M | 14,106 | 32 | 475 | 76% |
| ring_bsim4_100k | 3.2x | 70M | 13,885 | 32 | 351 | 63% |
| sram_bsim4_100k | 16.6x | 3.5G | 58,128 | 2.9 | 8,666 | 97% |
| c7552_sky130 | 1.2x | 2.0M | 49,597 | 2.3 | 49,534 | 54% |
| c7552_ihp | 1.3x | 2.5M | 62,407 | 2.6 | 62,349 | 38% |
| tdc_sky130 | 1.0x | 0.15M | 7,210 | 1.9 | 7,200 | 29% |

The builder emits `BbdInfo` for every generated deck and for c7552, and
`Bbd.init` declines all of them (`NotApplicable`); the TDC gets none. No
row or column of A holds 1,000 entries on the synthetic decks, because
their supplies are meshes; the real decks have one ideal supply node each,
and its column is the widest in U.

Against E1's rules:

- Refactor plus solve alone is at least 40% of wall time under `cuda` on
  14 of the 20 timed decks (every 10k and 100k deck, 5 of 8 at 1k), before
  adding the plane download. The download adds 14-25% of each eval (5% of
  c7552_sky130's wall time), which leaves the real decks at 14-35%. The
  gate passes on the synthetic decks and fails on the real ones, whose
  next target is setup.
- `Bbd.init` accepts none, so option (d) does not come first.
- `S_r` is within 10x of n on the SRAMs and on every real deck, where one
  supply column with 49k-62k U entries is most of the critical path. The
  gather form for wide columns (§4.2) comes before any kernel tuning.

### Bottlenecks

1. **The host LU.** At 10k transistors it is 27-87% of wall time on one
   thread and 46-94% once the GPU takes the eval. The random logic block
   refactors 170M multiply-adds per iteration (98 ms, 1,643 of them in
   `logic_bsim4_10k`). The SRAM array fills 8.2x at 10k and 16.6x at 100k
   (3.5G multiply-adds, why the 100k SRAM is out of the suite). When a
   refactor fails its growth check, the re-pivoting full factor can fill
   far worse: on the 100k chain's diverging operating point the fill went
   from 2.9x to 25x (9e10 multiply-adds a factor), which is why the 100k
   decks start from `uic`. A re-pivot now hands a displaced diagonal to
   the column that lost it and gives up past 3x the fresh fill
   ([gilbert-peierls-lu.md](../solvers/gilbert-peierls-lu.md),
   "Re-pivoting"): that operating point finishes in 210 s with fill at
   most 8.2x, where it had not finished in 45 minutes. This decides where
   GPU work goes next: the solve, not more eval.
2. **Setup on PDK decks.** Parse, subcircuit expansion and binding of the
   sky130 and IHP model libraries take 7.9-9.2 s on c7552 and 1.6 s on
   the TDC, 28-47% of the `cuda` wall time. ngspice's own profile of the
   same c7552 spent 80 of 217 s parsing (ngspice-41, KLU). Since then
   (the table above predates it) a `.model` card binds once per netlist
   model row instead of once per instance, the binder skips fields no
   card key can match, and expansion skips the dot cards of a subcircuit
   without `.if`. `Problem.init` went from 30.5G to 2.9G instructions on
   c7552_sky130 (setup 9.3 s to about 0.7 s), from 5.7G to 0.9G on the
   TDC, and from 33.4G to 10.6G on c7552_ihp. What is left on c7552_ihp
   is parsing: every PSP instance re-reads its ~390-pair `.model` card
   under its own subcircuit parameters (`pre_layout`, `rfmode`, `ng`)
   before the duplicate check folds it into an existing row, 78% of
   `Problem.init`.
3. **Eight host threads.** `cpu8` often loses to `cpu1` on the factor
   (sram_bsim4_10k: 37.7 s of LU on one thread, 42.9 s with seven more
   lanes; logic_psp103_10k: 238 against 279 s). The likely cause is the
   ParEval workers, which spin and then yield between evals while the
   single-threaded LU runs beside them. The eval itself barely scales on
   the PSP103 decks (chain_psp103_10k: 20.3 s on one thread, 21.8 s on
   eight). Profiled since: lane 0 reduced every slab alone over windows of
   300k-660k slots, 8.4 ms a pass against an 8 ms stamp; each worker
   cleared its whole window before stamping; and `count * n_u^2` gave
   lane 0 the capacitors and nothing else. ParEval now reduces in
   parallel, clears as it reduces, weighs nonlinear instances 16x, and
   parks idle workers on a futex (see
   [refactoring.md](../analysis/refactoring.md)). On short-window copies
   of these decks at load under 20, 8 threads: device eval
   chain_psp103_10k 4.0 to 1.8 s (one thread: 2.9 s), logic_psp103_10k 2.1
   to 1.5 s; CPU time 2.3-5.8x lower. The LU slowdown showed up in one of
   three runs before and none after; wall time is otherwise flat. Eval
   is faster at 4 threads (1.5 s) than at 8: a worker lane stamps PSP103
   about 2x slower than lane 0, likely E-cores or the shared L3.
   Settled 2026-10-01 (load 5-7, transient eval time from
   `--timing-in-depth`, `ESPICE_THREADS`, `taskset`; the 14900HX's
   P-cores are CPUs 0-15, two per core, the E-cores 16-31):

   | deck | 1 P | 4 P | 1 P + 3 E | 8 P | 1 P + 7 E | 4 any | 8 any |
   |---|---:|---:|---:|---:|---:|---:|---:|
   | logic_psp103_1k eval | 2.61 | 1.75 | 2.36 | 4.15 | 2.13 | 1.79 | 1.87 |
   | chain_psp103_10k eval | 8.60 | 6.56 | 9.08 | 6.95 | 8.06 | 8.23 | 7.72 |

   E-core lanes are the cause: four lanes on P-cores beat four with three
   on E-cores by 1.35x and 1.38x. Unpinned, 4 and 8 threads tie (the
   scheduler fills E-cores either way), and eval is a fifth of the wall
   time here (logic_psp103_1k: 8.75 s at 4 threads, 8.88 s at 8), so the
   thread count is not worth a default. The `8 P` cell on logic ran
   beside a build on the same cores. ParEval cuts by weight, not by
   measured lane speed; a work-stealing split is the fix if a deck's eval
   ever dominates on a hybrid CPU.

## Limits

- The kernels are latency-bound under ~6,000 instances. At 255 registers a
  thread, an SM holds 256 threads, so 4,000 bsim4 instances fill two thirds
  of one wave. bsim4va's eval keeps an 18.7 KB stack frame per thread (VerA
  dual arrays in local memory). ABI 5's sparse derivative lanes are the
  upgrade.
- The host batches stamp after the download instead of beside it. That is
  free for sources and costs their eval time for a heavy ineligible batch.
