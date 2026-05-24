# GPU device evaluation

`src/analysis/gpu.zig` evaluates device planes on the GPU and hands them to
the host solver. The input is the Newton iterate `x` and the time `t`. The
output is the four planes (`g`, `rhs`, `c`, `q`) in the circuit's own slices,
bit for bit what the device kernels computed, with the ground pin added. The
sparse LU, the Newton update, the gates and the transient's LTE all stay on
the host (AGENTS.md, CPU/GPU sharing). The kernels are the host's `evalRange`
compiled for the device through `Sink(D, true, ...)`. The GPU boundary
(tapes, Model/Instance PODs, pattern CSC, plane layout) is frozen, so every
table here is built beside it.

## Which batches go to the device

A batch is resident when it has a GPU payload (`eval.gpuEligible`) and its
model has a kernel image in this build. Everything else stamps on the host,
on top of the downloaded planes.

- `gpuEligible` refuses `mutable_eval`, Newton-history hooks and `State`
  without `limit`. It admits held-variable devices without `limit` (bsim4va,
  psp103, vbic13_4t). Their state kernel runs once per accepted point,
  through `GpuHook.commit_held`, never per converged solve.
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

## Limits

- The kernels are latency-bound under ~6,000 instances. At 255 registers a
  thread, an SM holds 256 threads, so 4,000 bsim4 instances fill two thirds
  of one wave. bsim4va's eval keeps an 18.7 KB stack frame per thread (VerA
  dual arrays in local memory). ABI 5's sparse derivative lanes are the
  upgrade.
- The host batches stamp after the download instead of beside it. That is
  free for sources and costs their eval time for a heavy ineligible batch.
- hisim2_va (`State` history), hicumL2_va and b3soi (`State` without
  `limit`) have no kernel.
