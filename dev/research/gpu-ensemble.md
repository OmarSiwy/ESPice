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

**Datacenter extrapolation (not measured).** The PSP103 eval kernel runs
at about 22 % of this card's FP64 peak, so FP64 rate is not its only
limit. Scaled to an H100 from the measured flop and byte counts, the eval
kernel gets 4.5 to 16x faster and the LU refactor could get about 18x
faster than one host core, if the 400M cap goes. For a post-layout point
the GPU case is the LU, not ensemble batching (see "FP64").

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

## FP64 and the datacenter extrapolation

Measured flop counts (`perf stat` FP_ARITH counters, FMA counted as two,
from the difference between 10k and 20k parallel instances on fixed
sources, one P-core):

| model | FP64 flops per instance per Newton iteration | instructions | CPU time | GPU kernel time |
|---|---:|---:|---:|---:|
| PSP103 | 9,300 | 11,800 | 893 ns (10.4 GFLOPS) | about 143 ns (65 GFLOPS) |
| BSIM4 | 6,100 | 9,000 | - | host only |

The GPU kernel time is the per-iteration eval (247 ns per instance, 100k
bare PSP103 instances) times the kernels' 58 % share of a phased eval. The
4060 Laptop peaks at about 0.30 TFLOPS FP64 (24 SMs x 2 FP64 lanes x 2
flops x 3.1 GHz), so the kernel uses about 22 % of it. FP64 rate is a large
part of the kernel's time, not all of it; the rest is latency and the
large per-thread state (`dev/devices/gpu-evaluation.md`, "Limits"). Device
state is 5.3 KiB per bare PSP103 instance, and each eval downloads 1,056
bytes per instance.

**Extrapolation to an H100 SXM (not measured; FP64 34 TFLOPS without
tensor cores, 3.35 TB/s, 132 SMs at about 1.98 GHz, 80 GB, PCIe 5.0 x16 at
about 55 GB/s):**

- Eval kernel: the FP64 share (22 %) shrinks 113x; the remaining 78 %
  scales between SM count x clock (3.5x, if it stays latency bound) and
  memory bandwidth (13x). That gives 9 to 32 ns per instance per iteration,
  4.5 to 16x the 4060.
- Plane download: 1,056 bytes per instance per eval at 55 GB/s is 19 ms
  per eval for 1M instances. With the kernel at 9 to 32 ms per iteration,
  the bus becomes the limit unless the matrix is assembled on the device
  (`dev/solvers/gpu-lu.md` option (f)).
- LU at 1M (multiply-adds extrapolated to 7 to 10G): the host takes 5.5
  to 8 s per refactor. A device refactor moving 24 bytes per multiply-add
  at 3.35 TB/s has a 50 to 70 ms floor; the 4060's ran 6x above its own
  floor, which would put an H100 at 0.3 to 0.45 s, about 18x the host
  core. The tables (28 to 40 GB at 4 bytes per multiply-add) fit in 80 GB,
  but only if the 400M cap is raised.
- A 1M point per iteration then comes to roughly 0.05 to 0.1 s of eval
  plus 0.3 to 0.45 s of LU on an H100, against about 0.8 s of eval and 5.5
  to 8 s of LU on eight P-cores. The gain comes from the LU. With about 8
  eval-only 1M points (2 with LU tables) in 80 GB, batching across points
  still has nothing to amortise.

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

**Stacked decks** (`tests/benchmark/ensemble/gen.py`). N electrically
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

Configurations (`tests/benchmark/ensemble/run.py`), times are the sum of
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

- 1M transistors (device and host memory, above), and any post-layout
  deck other than the PSP103 chain. BSIM4 decks would put only their R and
  C on the GPU.
- Any datacenter GPU: every H100 number above is an extrapolation.
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
# small-circuit ensembles
G=tests/benchmark/ensemble
python3 $G/gen.py /tmp/ens psp103 chain50 cj tran 0
python3 $G/run.py zig-out/bin/espice /tmp/ens singles par24 cpu1 cuda cudalu check
```

The post-layout timings above cut each deck's `.tran` to 50 ps (100 ps
at 10k). On NixOS the CUDA runtime needs
`LD_LIBRARY_PATH=/run/opengl-driver/lib`.
