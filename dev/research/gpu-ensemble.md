# GPU ensemble mode: prototype measurements (#99)

Measured 2026-10-17 on an RTX 4060 Laptop GPU (8 GiB, 24 SMs, driver
595.71, CUDA 13.2, PCIe 4.0 x8) and an i9-14900HX (8 P-cores, 16 E-cores,
32 threads). The ESPice binary is the default GPU build (ReleaseFast) at
f8998e0. #101 (live `.param` values, re-bin per point) landed after the
measurements; it changes how per-point values get in, not what is measured.

The target is post-layout: extracted netlists with up to millions of
transistors and ten R or C per transistor. The question has two parts.
First, does one such point run faster with device evaluation (and the
device LU) on the GPU than on the CPU at its best thread count? Second,
does batching N same-pattern points (Monte Carlo, corners x Jacobian)
still pay once one point fills the GPU? A secondary section keeps the
small-circuit ensemble measurements (5 to 1,000 transistors per point).

## Answer

**One post-layout point.** The GPU wins device evaluation by 1.7x at 10k
transistors and 2.3x from 100k to 500k, against eight P-cores. It barely
moves the run: 1.12 to 1.22x wall time. From 100k up the host LU is 60 to
80 % of the run and grows faster than the circuit (14 % of a 100k run is
eval, 7 % of a 500k run). Removing eval entirely would cap the 500k
speedup at 1.22x. The existing device LU (`gpu_lu.zig`) is slower than the
host at 10k and 100k, and declines from 300k on (its tables cost 4 bytes
per multiply-add and it refuses past 400M).

**1M transistors** was not run. Extrapolated from 100k to 500k: about 9
GiB of device memory (more than this card has, so not even one point fits)
and about 19 GB of host memory, too close to what this shared machine had
free. The extrapolated LU is 7 to 10G multiply-adds per refactor, 5.5 to
8 s per Newton iteration on one core, against about 0.35 s of GPU eval
(0.8 s on eight P-cores).

**Ensembles at post-layout scale: no.** The eval kernel is saturated by
10k instances (200 ns per instance there, 147 ns at 100k), so N points
cost N times one point; batching saves launches and nothing else. The card
holds 8 points of 100k eval-only, 2 of 300k, none of 1M. The LU is one
large factor per point, so a pivot-tape replay with one thread per point
is useless: each thread would run 107M multiply-adds serially. Run points
one after another, each filling the GPU; stream or tile one point when it
outgrows the card.

**Crossover.** The hypothesis holds on this card against the engine as
it is: the GPU's eval costs a fixed 279 us per iteration plus 305 ns per
PSP103 instance, against 18 us plus 659 ns for the CPU at its best thread
count, so the GPU wins device evaluation from about 740 instances on and
keeps a 2x lead to 1M (the CPU's slope rises 25 % at 1M, the GPU's stays
flat). Two things limit what that buys. The CPU slope is that high only
because one circuit's eval scales 1.7 to 2.0x on eight cores; against an
ideal 24-core host (63 ns per instance) the GPU's slope is the larger one
and there is no crossover at any size. And the whole run is set by the
host LU, which is superlinear (exponent rising from 1.07 to 2.2 between 1k
and 500k): the GPU leads the total by 1.09 to 1.25x, most at 30k to 100k,
and the lead shrinks toward 1.05x at 1M.

**Projected for FP64 cards (not measured).** The PSP103 eval kernel runs
at about 22 % of this card's FP64 peak, so FP64 rate is not its only
limit. Scaled from the measured flop and byte counts, an H100's eval slope
is 12 to 35 ns per instance with the matrix assembled on the device (33 to
56 ns with a host LU), which crosses an ideal 24-core CPU at 5k to 9k
instances (9k to 39k with a host LU). The V100 and A100 never cross it
with a host LU. The LU refactor could get about 18x faster than one host
core on an H100 if the 400M cap goes; at post-layout size that, not
eval, sets the run.

**Mixed precision (hypothetical).** FP32 throughout cannot meet a 1e-12 A
KCL residual. FP32 Jacobians with FP64 residuals kept Newton iteration
counts and DC answers (to 1e-9) on 11 of 12 decks checked on the CPU, but
lost a diode bridge transient, so the step needs an FP64 fallback. On the
4060 it would move the eval slope only from 247 to 170 to 220 ns. The
note gives the A100 test protocol.

**Small circuits** (secondary section): the batched GPU run beats one CPU
thread from N = 1 to 30, but loses to 24 CPU processes on every deck.

Recommendation:

1. Do not build an ensemble mode that batches points on the GPU. At
   post-layout size one point fills the device; for small circuits, CPU
   processes win.
2. The post-layout bottleneck is the per-point LU: host refactor at
   0.77 ns per multiply-add on one core, the multicore refactor not
   admitted (F/n is 85 at 100k and 196 at 300k, under its 300 bar), and the
   device LU capped at 400M multiply-adds with slow triangular solves.
   That is where GPU or host effort pays.
3. BSIM4 is still host-only under a GPU backend (`gpuEligible` rejects
   models that hold variables and limit), so a sky130 BSIM4 post-layout
   deck puts only its R and C on the device. On the GPU path the host
   batches then evaluate on one thread whatever `ESPICE_THREADS` says
   (BSIM4 10k chain: 6.0 ms per eval on the host against 1.9 ms per
   iteration for the whole eval on eight P-cores).

## Post-layout: one point

**Decks.** `tests/benchmark/postlayout/gen.py chain psp103 <size>`:
parallel 50-stage inverter chains on PSP103 (GPU-resident), every net
split into pi segments with coupling caps and the rails extracted as a
mesh. The `.tran` window is cut to 50 ps from `uic` (100 ps with an
operating point at 10k), so every deck runs about 145 Newton iterations.
The per-iteration costs below are the transient's `--timing-in-depth`
split divided by its iteration count.

**Configurations.** `cpu1`: one thread pinned to a P-core. `cpu8P`: eight
threads pinned to the eight P-cores (the best count measured on this CPU,
`dev/devices/gpu-evaluation.md`). `cuda`: device eval, one host thread,
host LU. `cudalu`: as `cuda` with `ESPICE_GPU_LU=1`. Device memory is the
peak `nvidia-smi` reading above idle; host memory is max RSS.

Per Newton iteration, milliseconds:

| FETs | R + C | n | L+U | refactor multiply-adds | eval cpu1 | eval cpu8P | eval cuda | GPU vs 8P | host LU | device LU |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 10k | 105k | 124,925 | 1.38M | 4.5M | 9.9 | 6.1 | 3.6 | 1.71x | 8.0 | 14.2 |
| 100k | 1.04M | 1.25M | 14.5M | 107M | 99.3 | 72.3 | 32.1 | 2.25x | 136 | 153 |
| 300k | 3.13M | 3.74M | 46.0M | 734M | 297 | 215 | 95.1 | 2.26x | 625 | declined |
| 500k | 5.2M | 6.23M | 81.5M | about 2.3G | - | 390 | 171 | 2.28x | 1,868 | declined |

"host LU" is factor plus solve on one thread (eight threads do not change
it: the multicore refactor is not admitted). "device LU" is the median
device call (refactor, solves, transfers) from `ESPICE_GPU_LU_BENCH`. At
100k the device refactor kernel beats the host refactor (59 against
111 ms), but the device triangular solves lose (84 against 16 ms). The
500k multiply-add count is estimated from its host refactor time at the
300k rate.

Whole run, seconds, and memory:

| FETs | wall cpu1 | wall cpu8P | wall cuda | cuda vs 8P | LU share of cuda run | device memory | host RSS |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 10k | 17.2 | 14.5 | 11.9 | 1.22x | 58 % | 0.43 GiB | 0.2 GB |
| 100k | 45.6 | 36.7 | 32.9 | 1.12x | 60 % | 1.18 GiB | 1.9 GB |
| 300k | 172.0 | 145.1 | 129.8 | 1.12x | 70 % | 2.83 GiB | 5.6 GB |
| 500k | - | 380.1 | 336.8 | 1.13x | 80 % | 4.57 GiB | 9.4 GB |

The 10k run includes its operating point (688 iterations), which the
larger decks skip with `uic`.

One device eval at 100k (`ESPICE_GPU_STATS=phases`): upload and clear
1.6 ms, kernels 14.7 ms, two reduces 3.6 ms, plane download 9.8 ms. The
download is the PCIe link at its limit: 132 staged cells (1,056 bytes) per
PSP103 instance per eval, measured at 15.8 GB/s.

## Post-layout: is there a crossover?

The hypothesis: GPU time is a large fixed cost plus a small slope per
device, `T(N) = a + b N`, so past some size N* the GPU wins and keeps
winning. N* = (a_gpu - a_cpu) / (b_cpu - b_gpu); if b_gpu >= b_cpu there is
no crossover at any size.

Two sweeps, all on the transient's Newton iterations (about 2.3 per
accepted step on every deck here, so per step is 2.3x these numbers):

- **Bare PSP103 instances** (`N` transistors in parallel between two
  fixed sources, the postlayout generator's PSP103 card, `.tran 1p 10p`,
  116 iterations; 30 to 1M): device evaluation alone, nothing else in the
  matrix.
- **The post-layout chain** (1k to 500k transistors, ten R or C per
  transistor): device terms, LU, and the whole iteration.

"Device" is eval + load + update from `--timing-in-depth` (the GPU's
limiting and the CPU's single-thread limiting both land in update). The
CPU is shown at 1 thread, at 8 threads on the P-cores, and at 24 threads.
"Best CPU" is the fastest of the three at each size, which is the CPU at
its best thread count.

**Device term, bare PSP103, ms per Newton iteration:**

| N | cpu1 | cpu8P | cpu24 | best CPU | GPU | GPU vs best CPU |
|---:|---:|---:|---:|---:|---:|---:|
| 30 | 0.045 | 0.627 | 0.034 | 0.034 | 0.285 | 8.4x slower |
| 100 | 0.125 | 0.635 | 0.290 | 0.125 | 0.367 | 2.9x slower |
| 300 | 0.358 | 1.249 | 0.696 | 0.358 | 0.392 | 1.1x slower |
| 1k | 1.243 | 1.450 | 0.662 | 0.662 | 0.499 | 1.3x faster |
| 3k | 3.735 | 1.929 | 1.624 | 1.624 | 1.000 | 1.6x faster |
| 10k | 12.81 | 7.381 | 6.994 | 6.994 | 3.492 | 2.0x faster |
| 100k | - | 65.45 | 106.2 | 65.45 | 32.41 | 2.0x faster |
| 300k | - | 180.8 | 293.3 | 180.8 | 102.6 | 1.8x faster |
| 1M | - | 685.3 | - | 685.3 | 331.0 | 2.1x faster |

Fits (weighted by relative error, all sizes):

| backend | a (fixed, per iteration) | b (per instance) | marginal b, 300k to 1M |
|---|---:|---:|---:|
| best CPU | 18 us | 659 ns | 721 ns (cpu8P) |
| GPU (4060) | 279 us | 305 ns | 326 ns |

**N* = 740 PSP103 instances** for device evaluation. The shape holds:
the GPU's fixed cost is 15x one CPU thread's (launches, syncs, the plane
download's latency), and its slope is half the CPU's. Past 1M it stays
that way. The CPU's slope rises 25 % between 300k and 1M (581 to 721 ns
marginal: its working set leaves the caches), while the GPU's stays flat,
so the eval ratio holds at about 2x out to 1M. The fixed cost is measured
at 279 us per iteration here, not the 50 us first assumed.

b_cpu is 659 ns, not 880 / 24 = 37 ns, because evaluating one circuit does
not scale across cores in the engine: eight P-cores give 1.7 to 2.0x one
thread on these decks, and 24 threads are slower than eight from 10k up
(E-cores, and twice the RSS). Against an ideal 24-core CPU slope, 63 ns
(the 14x the small-circuit ensembles reached as separate processes),
b_gpu = 247 to 305 ns is the larger slope, and there is **no crossover at
any size** on this card. So the crossover exists against the engine as it
is, and the size of the GPU's lead is bounded by how badly one circuit's
eval scales on the host. A host ParEval that scaled would erase it.

**Post-layout chain, ms per Newton iteration:**

| FETs | device: best CPU | device: GPU | LU: CPU (host) | LU: GPU run (host) | total: best CPU | total: GPU | total ratio |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1k | 0.661 (cpu24) | 0.598 | 0.706 | 0.655 | 1.367 | 1.252 | 1.09x |
| 3k | 2.384 (cpu24) | 1.272 | 2.433 | 2.134 | 4.687 (cpu8P) | 3.406 | 1.38x |
| 10k | 7.002 (cpu8P) | 4.733 | 8.955 | 8.551 | 15.96 | 13.28 | 1.20x |
| 30k | 26.63 (cpu8P) | 14.49 | 34.74 | 34.67 | 61.37 | 49.15 | 1.25x |
| 100k | 82.43 (cpu8P) | 42.76 | 140.0 | 136.3 | 222.4 | 179.1 | 1.24x |
| 300k | 245.8 (cpu8P) | 126.7 | 657.1 | 624.7 | 902.9 | 751.5 | 1.20x |
| 500k | 451.4 (cpu8P) | 226.0 | 2,024 | 1,868 | 2,475 | 2,094 | 1.18x |

Fits on the chain (cpu8P against GPU):

| term | CPU | GPU | crossover |
|---|---|---|---|
| device, linear | a = 0.32 ms, b = 791 ns per FET | a = 0.13 ms, b = 437 ns per FET | under 1k: the GPU leads at every size measured |
| LU, power law | 1.09e-4 ms x N^1.24 | 9.4e-5 ms x N^1.25 | none: both are the host LU |
| total, power law | 5.5e-4 ms x N^1.14 | 2.9e-4 ms x N^1.18 | GPU leads at every size, by a shrinking margin |

On the chain the GPU's device term leads from 1k up, because the per-FET
work includes about ten R and C, which the GPU also evaluates. The LU is
the same host LU on both backends, and it is superlinear and getting
steeper: local exponents 1.07 (1k to 10k), 1.19 (10k to 100k), 1.41
(100k to 300k), 2.2 (300k to 500k). So the total ratio peaks near 1.25x
at 30k to 100k and falls after that, toward 1.05x at 1M (extrapolated:
device 0.9 s against 0.45 s, LU about 9 s). The crossover exists for the
total too, but the LU term flattens it: past 100k the GPU's lead in the
whole run shrinks with size instead of growing.

## Post-layout: ensembles

**VRAM-bound N.** A chain point costs 8.9 KiB of device memory per
transistor (marginal, 300k to 500k, R and C included) over a 0.35 GiB
context. On this 8 GiB card that is N = 8 at 100k, 2 at 300k, 1 at 500k
and 0 at 1M (8.8 GiB, extrapolated). Adding the device LU (4 bytes per
refactor multiply-add of tables plus 8 bytes per L+U entry) brings 100k
down to 5 points, and from 300k it is over the 400M cap anyway. An 80 GB
card holds about 8 eval-only 1M points.

**Does batching pay once a point fills the GPU?** No. Per-instance kernel
time stops falling by 10k instances (200 ns at 10k, 147 ns at 100k, 160 ns
for 100k bare PSP103 instances), which is where the kernel stops being
latency bound (`dev/devices/gpu-evaluation.md`, "Limits"). Above that, N
points take N times as long, plus N times the plane download. What
batching saves is launch and sync overhead, a few hundred microseconds per
eval against tens of milliseconds of work.

**Design.** At this scale the shape is one point at a time on the device.
A point bigger than the card streams: eval in instance tiles whose planes
are scattered as they land, since the eval already reduces into staging
cells per instance and the scatter needs no other tile. The LU is the part
that does not tile cleanly, and it already dominates.

**What the batched pivot-tape replay buys.** Nothing for post-layout. The
replay kernel of the secondary section gives each point one GPU thread
that runs the whole refactor serially. That breaks even with a CPU core at
250 to 400 points on small patterns, and a 107M multiply-add refactor per
thread would need thousands of resident points that do not fit. The useful
form at this size is the level-scheduled refactor `gpu_lu.zig` already
has, which parallelises inside one matrix. Folding a few points into its
levels (columns x points per level) would hide level latency: its 100k
refactor runs 59 ms where moving the 107M multiply-adds' operands once
(about 24 bytes each at 256 GB/s) would take about 10 ms. But only about
5 such points fit, and its solves, not its refactor, are its slow half.
Raising the 400M cap, faster device solves, and a host refactor that
parallelises at F/n under 300 matter more than a point axis.

## Projected: GPUs built for FP64

Everything in this section is a projection from the 4060 measurements, not
a measurement.

**Measured inputs (4060, PSP103, per instance per Newton iteration):**

| input | value | how |
|---|---:|---|
| FP64 flops | 9,300 | `perf stat` FP_ARITH counters on one P-core, FMA counted as two, 20k minus 10k bare instances |
| instructions (CPU) | 11,800 | same |
| BSIM4 FP64 flops | 6,100 | same (BSIM4 is host-only on the GPU path) |
| CPU time, one P-core | 893 ns (10.4 GFLOPS) | eval-only deck, 100k |
| GPU slope, whole eval | 247 ns | 100k bare instances: 143 ns kernels, 36 ns upload and reduces, 68 ns plane download |
| GPU kernel FP64 rate | 65 GFLOPS, 22 % of peak | the 4060 Laptop peaks at about 0.30 TFLOPS FP64 (24 SMs x 2 FP64 lanes x 2 x 3.1 GHz) |
| device state | 5.3 KiB per instance | `nvidia-smi`, 10k to 100k bare instances |
| plane download | 1,056 B per instance per eval | 132 staged cells, at 15.8 GB/s (PCIe 4.0 x8) |
| GPU fixed cost | 279 us per iteration | fit above |

**Model.** The kernels spend 22 % of their time on FP64 work, which scales
with the card's FP64 rate. The other 78 % (latency, the large per-thread
state in local memory) scales somewhere between the card's SM count x
clock (if it stays latency bound) and its memory bandwidth (if it becomes
bandwidth bound); the two ends give the ranges below. Upload and reduces
scale with bandwidth. With a host LU, the plane download crosses PCIe at
the card's link rate; with the matrix assembled on the device it does not.
The fixed cost is taken as the 4060's 279 us.

The CPU slope has two references: the engine as measured (659 ns per
instance, eight P-cores) and an ideal 24-core host (63 ns: 880 ns over the
14x that separate processes reach).

| card | FP64 TF | HBM TB/s | link GB/s | slope, device-assembled LU | slope, host LU | N* vs engine CPU | N* vs ideal CPU, device LU | N* vs ideal CPU, host LU | eval per iteration at 1M (device / host LU) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| RTX 4060 Laptop (measured) | 0.30 | 0.26 | 15.8 | 179 ns | 247 ns | 740 (measured) | never | never | 0.18 s / 0.33 s (host LU measured) |
| V100 | 7.8 | 0.90 | 12 | 43-79 ns | 133-169 ns | ~450 | 13,000 to never | never | 43-80 ms / 133-169 ms |
| A100 | 9.7 | 1.94 | 25 | 20-60 ns | 63-103 ns | ~440 | 6,200-94,000 | never | 21-60 ms / 64-103 ms |
| H100 SXM | 34 | 3.35 | 50 | 12-35 ns | 33-56 ns | ~420 | 5,100-9,300 | 8,700-39,000 | 12-35 ms / 33-57 ms |
| MI300X | 81.7 | 5.3 | 50 | 7-15 ns | 29-36 ns | ~410 | 4,700-5,400 | 7,600-9,800 | 8-15 ms / 29-37 ms |

Against the CPU at 1M: the engine takes 685 ms of device time per
iteration on eight P-cores (measured), an ideal 24-core host 63 ms.

What the table says:

- Against the engine's CPU, every card crosses over at a few hundred
  instances, because the host side scales so poorly.
- Against an ideal CPU, an FP64 card crosses over at 5k to 10k instances
  if the matrix is assembled on the device. With a host LU, the plane
  download over PCIe keeps the V100 and A100 from ever crossing, and puts
  the H100 at 9k to 39k.
- The first-cut projection that scaled the whole 250 ns slope with FP64
  rate (H100 at 1.7 ns per instance, 35x the ideal CPU) overstates the
  gain: only 22 % of the kernel time is FP64, so the H100 lands at 12 to
  35 ns, 1.8 to 5x under the ideal CPU's 63 ns, not 35x.

**The whole simulation is set by the LU.** Device eval at 1M on an H100 is
12 to 57 ms per iteration. The chain's host LU extrapolates to about 9 s
per iteration at 1M (5.5 to 9 s depending on the fit), unchanged by any
GPU. A device refactor moving 24 bytes per multiply-add at 3.35 TB/s has a
50 to 70 ms floor for the 7 to 10G multiply-adds of a 1M chain. The
4060's refactor ran 6x above its own floor, which would put an H100 at
0.3 to 0.45 s, about 18x the host core. Its tables (4 bytes per
multiply-add, 28 to 40 GB) fit in 80 GB but not under the current 400M
cap. On an FP64 card the whole-run gain at post-layout size is about how
far the LU goes onto the device, not about eval.

## Mixed precision (hypothetical)

Nothing here is an engine change. The real test needs an A100-class card,
which we do not have, so this is an analysis, a CPU-side check of one
step, and a protocol.

**Why FP32 throughout fails.** Newton converges when KCL balances at every
node to about abstol, 1e-12 A. At a node where milliamp currents cancel,
FP32's relative error of about 6e-8 leaves about 6e-11 A of rounding in
the residual: 60x abstol, so the convergence test can never pass. The
same holds for charge sums and the integrator's history. FP32 can carry
work whose error Newton tolerates, and nothing else.

**The candidate split.**

1. *Device derivatives in FP32, values in FP64.* A mixed `Dual(N, F)` with
   an f64 value lane and f32 derivative lanes. The Jacobian then carries
   relative errors of about 6e-8; inexact-Jacobian Newton still converges
   to the FP64 answer, because the residual it drives to zero stays FP64,
   as long as the error in J^-1 times the residual contracts, roughly
   cond(J) x 6e-8 < 1. Share of eval work that moves: in a `Dual(N, F)` an
   add costs one value op and N derivative ops, a multiply one and 3N, and
   a transcendental 20 to 40 value ops and N. With PSP103's N, 70 to 90 %
   of the 9,300 flops per instance per iteration sit in derivative lanes
   (estimated from that op mix, not measured).
2. *The LU in FP32 with FP64 refinement.* Factor in FP32 (or TF32 on tensor
   cores, dense fronts only), then iterative refinement or GMRES-IR with
   FP64 residuals. Plain refinement converges while cond(A) x 6e-8 < 1,
   about cond 1e7; GMRES-IR reaches further. Circuit matrices with gmin
   (1e-12 S) beside on-transistor conductances (1e-3 S) and ideal sources
   can exceed 1e7. A refinement that has not converged in a fixed number
   of steps falls back to an FP64 factor of that matrix.
3. *Double-float emulation* (an f32 pair, about 48-bit mantissa) as the
   fallback for work that must stay accurate on a card with weak FP64.
   It only pays where FP64 is 1/32 rate or worse, as on the 4060.
4. *Stays FP64:* the residual, the convergence test, transient charges and
   integration history, the solution x, and the LTE estimate.

**CPU check of step 1 (measured).** A throwaway build rounded every
Jacobian value to FP32 just before the factor (`converger.zig`, after
the load check; the residual untouched), so the LU sees an FP32-accurate
Jacobian in FP64 arithmetic. Not committed.

| deck | Newton iterations FP64 / FP32 Jacobian | result difference |
|---|---:|---|
| op/bench_bjt_cascode | 17 / 17 | 1e-11 relative |
| dc/bench_bjt_diff_amp | 115 / 115 | 1e-9 relative |
| op/device_bsim4 | 7 / 7 | 3e-13 relative |
| dc/device_bsim4_output | 1,354 / 1,354 | bitwise equal |
| op/device_hicum2 | 4 / 4 | 3e-11 relative |
| dc/device_hicum2_gummel | 266 / 269 | 4e-10 relative |
| tran/bench_ngspice_mosamp | 215,778 / 215,710 | 3e-5 of the signal range (time-aligned) |
| stress/vacask_mul | 1,018,450 / 1,018,456 | 6e-9 of the signal range (time-aligned) |
| stress/vacask_ring (PSP103) | 66,817 / 66,146 | rising edges 37 ps apart after 290 periods of 3.45 ns (the corpus checks the period at rtol 3e-3) |
| stress/scaling_inverter_chain_256 | 4,980 / 4,874 | rising edges 3.3 ps apart |
| stress/vacask_graetz (diode bridge) | 2,000,024 / failed | `TimestepTooSmall` after 71,937 iterations |
| post-layout chain_psp103_10k | 152 / 153 | 1.1 mV at the accepted points |

The DC and operating-point decks keep their iteration counts and move by
1e-9 or less. Transients take slightly different steps, so their results
differ at the level of the step control: 3 to 37 ps on edges, well inside
what the corpus checks. The full corpus was not rerun with the FP32
Jacobian (two queued runs were killed before they started); that is the
protocol's first item. The diode bridge is the warning: an FP32 Jacobian of a stiff,
widely scaled matrix (1u steps over 1 s, diodes switching between gmin
and on) lost Newton convergence on a step and the run died. Step 1 needs
the fallback (re-evaluate that iteration's Jacobian in FP64 when Newton
stalls) from the start, not as an afterthought.

**Predicted effect on N* (prediction, not measured).**

- *RTX 4060* (FP32 64x FP64). With 80 % of eval flops in FP32, the FP64
  share of the kernel (22 %, 31 ns per instance) drops to about 7 ns, so
  the kernel goes from 143 to about 118 ns and the slope from 247 to about
  222 ns. Halving the derivative lanes' bytes could also cut the
  latency-bound remainder, by up to 45 %, to about 172 ns. Either way it
  stays above the ideal CPU's 63 ns: no crossover against an ideal host,
  and against the engine's CPU N* moves from 740 to about 550 to 600. The
  first-cut estimate of 53 ns assumed the whole kernel was FP64 bound; it
  is not.
- *A100 / H100* (FP32 2x FP64, TF32 tensor cores). FP64 is already a
  small share of the kernel on these cards, so FP32 derivatives save
  little compute (A100 kernel 15 to 55 ns from 20 to 60; H100 9 to 32 ns
  from 12 to 35). The gain would come from halving the derivative bytes in
  a kernel that is latency or bandwidth bound, and from an FP32 or TF32 LU
  with refinement, which is where the run's time is. Predicted N* against
  an ideal CPU, with the matrix assembled on the device and if halving the
  derivative bytes cuts the non-FP64 remainder by 45 %: about 5k to 9k
  (A100) and 5k to 6k (H100), from 6k to 94k and 5k to 9k today.

**Test protocol for an A100-class card.**

1. *Decks.* The full corpus (`zig build test`, CPU and `test-gpu`); the
   post-layout families from `tests/benchmark/postlayout/gen.py` (chain,
   ring, logic, sram) on PSP103 at 10k, 100k, 300k and 1M, with BSIM4
   added once it is GPU-resident; c7552 on sky130 and IHP from `fetch.sh`;
   the bare-instance sweep (30 to 1M) of this note for the eval fits.
2. *Builds.* Default GPU build as the FP64 reference; one build option per
   step (`-Djac_f32` for mixed `Dual`, `-Dlu_f32ir` for the FP32 factor with
   refinement, `-Dlu_tf32` for tensor-core fronts), each with its FP64
   fallback live. Run each at `ESPICE_THREADS` = the host's best count.
3. *Measure.* `T(N) = a + b N` fits for device eval, power-law fits for
   the LU, and the total, per build; Newton iterations per accepted step;
   accepted steps; refinement iterations per factor and the fallback rate;
   results against the FP64 build at each deck's tolerance (the corpus
   verdicts), and for the post-layout decks the mid-swing crossing times
   against the FP64 run, compared with that deck's own truncation error
   (default against reltol 1e-5).
4. *Adopt a step only if:* no corpus verdict changes (PASS stays PASS);
   median Newton iterations per step rise under 5 % and no deck over 25 %;
   fallbacks under 1 % of iterations (or of factors, for the LU steps); no
   post-layout crossing moves more than its deck's own truncation error;
   and the measured slope (eval steps) or LU time (LU steps) improves by at
   least 1.3x at 100k and up. Otherwise drop the step and record why in
   this note.
5. The CPU check above is the protocol's step 0, already run: it found one
   corpus deck that needs the fallback.

## Design questions at post-layout scale

- **Transient and Newton lockstep** only matter if points are batched, and
  at post-layout size they are not (above). The small-circuit
  measurements below still say what lockstep would cost: shared steps add
  0 to 28 %, masked Newton 1 to 30 %, and a point that needs continuation
  must peel out.
- **Memory:** per point, 8.9 KiB of device memory per transistor for eval,
  plus 8 bytes per L+U entry and 4 bytes per refactor multiply-add if the
  device LU runs. Batch size, where it applies, is
  `floor((VRAM - context) / per_point)`.
- **Determinism:** two GPU runs of the same deck are bitwise identical
  (checked on the small decks). Device eval is not bitwise the host's, so
  long transients diverge between CPU and GPU at the level of the deck's
  truncation error. The H14 oracle compares at the deck's tolerance.
- **Place in the module DAG** (if an ensemble driver is ever built):
  `analysis` owns the driver beside `sweep/lanes.zig`, a batched replay
  goes beside `analysis/gpu_lu.zig` with its scalar oracle at one point,
  `solver` keeps the host oracle and pivot tape, and `device/eval.zig`
  evaluates points x instances through `evalRange`. Points are more
  instances, so the GPU ABI does not change.

## Small circuits: N independent points (secondary)

The first round measured ensembles of small circuits, 5 to 1,000
transistors per point, where N points rather than one point fill the GPU.
Against one CPU thread the batched GPU run wins from N = 1 to 30 and
reaches 4.9x (PSP103) and 8.6x (BSIM3). Against 24 CPU processes it loses
on every corners x Jacobian deck, by 1.3x to 10x, and the device eval
alone outlasts the parallel CPU ensemble (32.3 s against 12.4 s on the
largest PSP103 deck). The batched refactor kernel breaks even with one
core at N = 250 to 400 and is capped at about 4x one core by PCIe unless
the matrix is assembled on the device.

### Method

There is no ensemble engine yet, so the prototype is a proxy plus a
kernel.

**Stacked decks** (`gen.py`, since removed; see Reproducing). N electrically
independent copies of one circuit in one netlist, each copy with its own
sources and its own model cards, so the matrix is block diagonal and the
existing GPU path batches the points as more instances. This is exactly the
lockstep an ensemble would run: one Newton loop over all points, converged
only when every point has converged, and one shared timestep. It goes through
the frozen GPU ABI unchanged. What it does not do is batch the LU across
points: the host factors one block-diagonal matrix, or `gpu_lu.zig` factors
it level-scheduled on the device.

- Models: BSIM3 (LEVEL=49) and PSP103 (LEVEL=1040), both GPU-resident at
  f8998e0.
- Circuits: `ota` (5-transistor OTA follower, n = 10 for BSIM3, n = 50 for
  PSP103, whose internal nodes add unknowns), `chain50` (50 inverters,
  n = 55 / 855), `chains10` (ten 50-inverter chains off one input, n = 505 /
  8,505).
- Ensembles: `mc` (seeded threshold and mobility draws, N = 1 to 1024) and
  `cj` (5 corners x 11 Jacobian points: nominal plus +-2 % on five width
  groups, 55 points).
- Analyses: `.op`, and `.tran` with tmax a tenth of the run so the LTE sets
  every step.

Configurations (`run.py`, since removed), times are the sum of
each deck's `run total` (analysis only; parse and setup excluded):

| config | what runs |
|---|---|
| singles | every `single_<k>.sp` in one process, one host thread: N CPU runs back to back |
| par24 | every single in its own process, 24 at a time; wall time, so it also pays process start, parse and setup (about 2 ms each) |
| cpu1 | `stacked.sp` on the CPU, one thread: lockstep without a GPU |
| cuda | `stacked.sp`, device eval on the GPU, host LU, one host thread |
| cudalu | as cuda, with `ESPICE_GPU_LU=1` forcing the device LU |

The GPU configurations first run `single_0.sp` in the same process,
untimed, so the CUDA context and model modules are warm, as they would be
in a long-lived ensemble.

**Batched refactor kernel** (throwaway, not committed). A CUDA kernel that
replays one `SparseLu` pivot sequence (the same column loop as
`SparseLu.refactor` without the tape, then the forward and back solves) for
N points, one thread per point, values stored lane-minor
(`[entry][point]`) so a warp's loads coalesce. This is `LaneLu(W)` with the
lane axis on GPU threads. The tables came from the first full factor of
`single_0.sp` of each `cj` deck, through a dump hook in `direct.zig` that was
reverted after use. Every point scales every matrix entry by its own factor
in [0.9, 1.1). The same `__host__ __device__` function at stride 1 is the
host oracle; it matched `SparseLu` refactor + solve bitwise on all six
patterns, and the device matched it bitwise on sampled points at every N
(see Determinism for the one condition).

### Results: corners x Jacobian (55 points)

Low machine load (4.6 to 7.8). Milliseconds.

| model | circuit | n | analysis | singles | par8 | par24 | cuda stacked |
|---|---|---:|---|---:|---:|---:|---:|
| bsim3 | ota | 10 | op | 15.2 | 24 | 25 | 6.7 |
| bsim3 | chain50 | 55 | op | 156.8 | 39 | 26 | 32.8 |
| bsim3 | chains10 | 505 | op | 897.4 | 209 | 79 | 269.6 |
| bsim3 | ota | 10 | tran | 81.9 | 25 | 24 | 39.9 |
| bsim3 | chain50 | 55 | tran | 1,183.4 | 209 | 82 | 400.0 |
| bsim3 | chains10 | 505 | tran | 8,824.5 | 1,366 | 627 | 2,938.3 |
| psp103 | ota | 50 | op | 74.3 | 43 | 29 | 39.2 |
| psp103 | chain50 | 855 | op | 737.4 | 140 | 62 | 427.4 |
| psp103 | chains10 | 8,505 | op | 5,639.8 | 972 | 526 | 4,145.2 |
| psp103 | ota | 50 | tran | 280.6 | 63 | 29 | 168.1 |
| psp103 | chain50 | 855 | tran | 14,597.1 | 2,009 | 860 | 8,655.6 |
| psp103 | chains10 | 8,505 | tran | 138,162.5 | 19,738 | 12,406 | 92,346.1 |

The `ota` rows for par8 and par24 are process-start bound (55 processes of
0.3 to 5 ms of analysis each). On analysis time alone, singles / 14 (the
scaling the larger decks show) puts them at 1 to 20 ms, still under the
GPU's 7 to 168 ms. The GPU numbers also leave out CUDA context creation
and module loading, which the untimed warm-up run pays.

Where the cuda stacked time goes, on the two largest tran decks: BSIM3
chains10 spends 1,769 ms in eval plus update (the device eval is
asynchronous, so its wait lands in `update`) and 598 ms in the host LU;
PSP103 chains10 spends 32,267 ms in eval plus update and 39,655 ms in the
host LU of the 55-block matrix.

### Results: Monte Carlo, by N

Speedup of cuda stacked over singles (one CPU thread), in parentheses with
the device LU (cudalu). These ran while three other sessions were building
(load 11 to 25), so absolute times are noisy; each row's configurations ran
back to back under the same load. Above 1 the GPU wins.

| model | circuit | analysis | N=1 | N=4 | N=16 | N=64 | N=256 | N=1024 |
|---|---|---|---|---|---|---|---|---|
| bsim3 | ota | op | 0.17 (0.16) | 0.25 (0.32) | 1.21 (0.75) | 3.56 (3.21) | 5.19 (3.75) | 7.03 (4.68) |
| bsim3 | chain50 | op | 0.15 (0.13) | 2.16 (2.24) | 1.75 (0.76) | 3.04 (2.46) | 3.23 (2.37) | - |
| bsim3 | chains10 | op | 1.04 (0.74) | 3.04 (1.41) | 3.68 (2.27) | 3.06 (2.16) | - | - |
| bsim3 | ota | tran | 0.06 (0.06) | 0.38 (0.33) | 0.82 (0.82) | 2.86 (2.78) | 7.31 (5.13) | 8.56 (7.27) |
| bsim3 | chain50 | tran | 0.27 (0.27) | 1.67 (1.82) | 3.16 (2.45) | 5.27 (4.40) | 4.10 (3.47) | - |
| bsim3 | chains10 | tran | 1.61 (0.79) | 4.80 (3.60) | 4.23 (3.40) | 3.62 (2.96) | - | - |
| psp103 | ota | op | 0.08 (0.09) | 0.25 (0.19) | 0.52 (0.40) | 2.59 (1.75) | 3.10 (2.62) | 4.92 (3.48) |
| psp103 | chain50 | op | 0.47 (0.17) | 1.45 (0.57) | 1.82 (0.98) | 2.01 (1.16) | 1.85 (1.25) | - |
| psp103 | chains10 | op | 1.50 (0.39) | 1.92 (0.62) | 1.72 (0.71) | 1.80 (0.75) | - | - |
| psp103 | ota | tran | 0.06 (0.06) | 0.21 (0.16) | 0.71 (0.60) | 1.99 (1.75) | 2.95 (2.99) | 3.26 (3.24) |
| psp103 | chain50 | tran | 0.40 (0.17) | 1.26 (0.51) | 1.72 (1.22) | 1.95 (1.49) | 1.28 (1.45) | - |
| psp103 | chains10 | tran | 1.85 (0.73) | 2.01 (1.00) | 1.85 (0.97) | 1.87 (1.02) | - | - |

The speedup flattens once the GPU eval is full: PSP103 at about 2x from
N = 4 on, BSIM3 at 3 to 5x. The host LU of the stacked matrix grows
linearly with N and takes over (PSP103 chain50 tran at N = 256: 38.4 s of
75.1 s). The level-scheduled device LU (`gpu_lu.zig`) is slower than the host
LU in all but one cell: it exposes parallelism inside one matrix, and a
block-diagonal stack of small blocks is shallow and wide, which the host
handles in microseconds.

#### Break-even N per circuit size

| circuit | n (bsim3 / psp103) | vs one CPU thread | vs 24 CPU processes |
|---|---|---|---|
| ota | 10 / 50 | 16 to 30 (op), 20 to 30 (tran) | never (up to N = 1024) |
| chain50 | 55 / 855 | 2 to 4 | never (up to N = 256) |
| chains10 | 505 / 8,505 | 1 (GPU already wins one point) | never (up to N = 64) |
| batched LU kernel only | 10 to 8,505 | 250 to 400 | about 6,000 to 8,000 (kernel only, values already on the device; 24 cores taken as 14x one core) |

The last row reads off the kernel table below. Against one core the
break-even N barely moves with circuit size, because the kernel is latency
bound until the GPU is full: below about N = 2,048 its time is one GPU
thread's serial refactor, 200 to 400 times slower than a CPU core.

### Results: batched refactor and solve kernel

Per point, nanoseconds. "host" is the same replay on one P-core (g++ -O3),
which tracks `SparseLu` (ESPice's own refactor + solve, from
`ESPICE_GPU_LU_BENCH`, was 12.5 us on bsim3 chains10, 25.6 us on psp103
chain50 and 257 us on psp103 chains10). "kernel" assumes the values are
already on the device; "+bus" adds uploading A and b and downloading x each
iteration.

| pattern | n | nnz | L+U | host | kernel N=128 | N=512 | N=2048 | saturated (N) | +bus saturated |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| bsim3 ota | 10 | 28 | 31 | 112 | 280 | 63 | 18 | 4 (32k) | 34 |
| bsim3 chain50 | 55 | 210 | 310 | 969 | 2,493 | 625 | 158 | 59 (8k) | 259 |
| bsim3 chains10 | 505 | 2,010 | 3,001 | 10,134 | 24,510 | 6,127 | 1,743 | 670 (32k) | 2,567 |
| psp103 ota | 50 | 258 | 356 | 1,041 | 2,229 | 555 | 138 | 51 (32k) | 274 |
| psp103 chain50 | 855 | 4,859 | 6,607 | 19,510 | 42,476 | 13,404 | 3,866 | 1,153 (32k) | 5,261 |
| psp103 chains10 | 8,505 | 48,509 | 64,517 | 191,956 | 591,332 | 150,082 | 38,389 | not reached (VRAM cap at 2k) | 79,525 at 2k |

Saturated, the kernel runs 15 to 28x one core (5x on psp103 chains10, where
the 6 GiB budget stops N at 2,048). With values crossing the bus every
iteration it is 3.7 to 4x one core on every pattern past the smallest: the
bus, not the kernel, is the limit. A GPU ensemble has to assemble the
matrix on the device (`dev/solvers/gpu-lu.md` option (f)) for the batched
LU to pay. At the 55 points of a corners x Jacobian run the kernel is about
5 to 6x slower per point than one core on every pattern.

### Design questions

#### Transient lockstep

Measured option: one shared step for all points (the stacked deck's step
control accepts a step only when every point's LTE passes, so the step is
the minimum over points). When the points share a stimulus, as MC and
corner points do, their edges coincide and the step count barely moves:
BSIM3 chains take 90 steps per single and 90 to 92 stacked; PSP103 chains
262 per single and 296 to 336 stacked (+13 to +28 %, growing with N). The
fixed or replayed grid (#97 item 5) and regrouping by step were not
measured; at under 30 % extra steps they are not needed for these
ensembles. They would matter for points with different stimuli.

Accuracy: lockstep results differ from the per-point runs by about the
deck's own truncation error. Against a reltol = 1e-5, tmax = 50 ps run of
point 0, the default single misses mid-swing crossings by up to 240 ps
(BSIM3 chain50) and 47 ps (PSP103 chain50); lockstep point 0 misses by
323 ps and 37 ps. Lockstep against single over all 55 points: 393 ps with
23 crossing-count mismatches (BSIM3 chain50), 24 ps and none (PSP103
chain50). OTA tran and every `.op` agree to under 1.3 uV. Comparisons must
therefore use the deck's tolerance, not the single run as an exact
reference.

#### Newton lockstep

Masked lockstep (iterate until every point converges) cost 1 to 30 % in
iterations whenever every point converged on plain Newton: the mean
per-point count over the stacked count was 0.70 to 0.99 in most cells,
0.52 for BSIM3 chain50 tran at N = 256, and above 1 for PSP103 OTA `.op`,
where the stack needed fewer iterations than the average point. The
stacked proxy does not mask, so converged points keep paying their eval;
masking would save that eval but not the wall time of the slowest point.
The failure case is a point that needs continuation: in BSIM3 chain50
`.op` at N = 256 one or more points left plain Newton, the whole stack went
down the gmin and source-stepping ladder, and the lockstep took 242
iterations against a 44 mean (4.35x the singles' CPU time). So: masked
lockstep for the plain Newton rung, and a point that fails it peels to the
scalar host path (the lane doctrine), never dragging the batch through
continuation.

#### Memory and batch size

Per point the device holds the LU values, the matrix, five n-vectors and the
device planes: `8 (L+U + nnz + 5n)` bytes plus the eval state. Sampled with
`nvidia-smi`, a PSP103 chains10 point (1,000 instances) costs 6.1 MiB of
eval state on top of a 338 MiB context, so about 6 KiB per PSP103
instance; the LU side adds 1.2 MiB. An 8 GiB card then holds about 1,000
such points. The BSIM3 chains10 stack of 55 points used 164 MiB in all.
Batch size is `floor((VRAM - context - shared tables) / per_point)`, capped
at the N where the kernels saturate (2,048 to 8,192 here). The VRAM cap
binds only on the largest circuits.

#### Determinism

- Fixed batch size: two cuda runs of every checked stacked deck were
  bitwise identical.
- Any batch size: the replay kernel runs each point in its own thread in
  the same operation order as the host, so a point's result does not depend
  on N or on its slot, provided the compiler does not contract `a - b * c`
  into an FMA. nvcc does by default: with contraction, 2 to 13,806 of the
  sampled solution entries (three points per N) differed from the host;
  with `-fmad=false` none did. Zig does not
  contract without `@setFloatMode(.optimized)`, so a Gompute-compiled replay
  keeps this property.
- CPU against GPU (H14): the device eval is not bitwise the host's, and on
  long transients the step sequences diverge. BSIM3 chains10 tran: 61 ps
  and 190 crossing-count mismatches over 27,500 node traces, the same order
  as the deck's own truncation error. BSIM3 chain50 tran: 0.08 ps, no
  mismatched counts. PSP103 tran and every `.op`: within 1.2e-13 V. The oracle has to compare at the deck's tolerance.

## What was not measured

- 1M transistors on the post-layout chain (device and host memory, above),
  and post-layout families other than the chain. The 1M point of the
  crossover is bare PSP103 instances. BSIM4 decks would put only their R
  and C on the GPU.
- Any FP64-class GPU: every V100, A100, H100 and MI300X number is a
  projection.
- Mixed precision on a GPU. The FP32-Jacobian check ran on the CPU on 12
  decks; the full corpus with it was not run (two queued runs were killed
  before they started).
- A real ensemble engine. The small-circuit proxy has no masks, no peel
  and no batched LU; the batched LU kernel was timed apart from the eval.
- The `psp103_chains10_cj_tran` lockstep check (about 15 minutes); the
  chain50 check covers the same circuit.

## Reproducing

```sh
# post-layout, one point
python3 tests/benchmark/postlayout/gen.py /tmp/pl chain psp103 100k
ESPICE_THREADS=8 taskset -c 0,2,4,6,8,10,12,14 zig-out/bin/espice --backend=cpu --timing-in-depth /tmp/pl/chain_psp103_100k.sp
ESPICE_THREADS=1 ESPICE_GPU_LU=0 zig-out/bin/espice --backend=cuda --timing-in-depth /tmp/pl/chain_psp103_100k.sp
ESPICE_GPU_LU=1 ESPICE_GPU_LU_BENCH=20 zig-out/bin/espice --backend=cuda /tmp/pl/chain_psp103_100k.sp
# small-circuit ensembles: the scripts were deleted by the commit
# "bench: delete the ensemble proxy scripts (#185)"; restore them from its parent
c=$(git log -1 --format=%H --grep='delete the ensemble proxy scripts')
mkdir -p /tmp/ensbin
git show "$c^:tests/benchmark/ensemble/gen.py" > /tmp/ensbin/gen.py
git show "$c^:tests/benchmark/ensemble/run.py" > /tmp/ensbin/run.py
python3 /tmp/ensbin/gen.py /tmp/ens psp103 chain50 cj tran 0
python3 /tmp/ensbin/run.py zig-out/bin/espice /tmp/ens singles par24 cpu1 cuda cudalu check
```

The post-layout timings above cut each deck's `.tran` to 50 ps (100 ps
at 10k). On NixOS the CUDA runtime needs
`LD_LIBRARY_PATH=/run/opengl-driver/lib`.
