# GPU ensemble mode: prototype measurements (#99)

Measured 2026-10-17 on an RTX 4060 Laptop GPU (8 GiB, driver 595.71, CUDA
13.2, PCIe 4.0 x8) and an i9-14900HX (8 P-cores, 16 E-cores, 32 threads).
The ESPice binary is the default GPU build (ReleaseFast) at f8998e0. #101
(live `.param` values, re-bin per point) landed after the measurements; it
changes how per-point values would get in, not what is measured here.

The question: run N points that share one circuit topology (Monte Carlo
samples, corners x Jacobian points) as one batched problem on the GPU,
with one batched device eval and one batched refactor per Newton
iteration, instead of N CPU runs. Is that faster, and from what N?

## Answer

Not on this hardware, at any N or circuit size measured.

- **Against one CPU thread** the batched GPU run wins from N = 1 to 30,
  depending on circuit size, and reaches up to 4.9x (PSP103) and 8.6x
  (BSIM3).
- **Against N CPU runs spread over the cores** (24 processes, which is how
  anyone would run N independent points) it loses on every corners deck,
  by 1.3x to 10x. The CPU runs scale 11 to 17x over one thread; the GPU never
  got past 8.6x at any N, so the Monte Carlo decks lose too (inferred from
  that scaling; par24 was run only on the corners decks).
- The device eval alone, before any LU, already takes longer than the whole
  parallel CPU ensemble: 32.3 s against 12.4 s on the largest PSP103 deck,
  1.77 s against 0.63 s on the largest BSIM3 deck. A free batched LU would
  not close that gap.
- The cause is FP64 throughput. A consumer Ada GPU runs FP64 at 1/64 of
  its FP32 rate, about 0.2 TFLOPS. Measured, a PSP103 instance evaluates in
  0.25 us on the GPU (batched, 55,000 instances per launch) and in 0.88 us
  on one P-core, so the whole GPU is worth about 3.5 cores.
- The batched refactor kernel (pivot-tape replay, one thread per point)
  breaks even with one CPU core at N = 250 to 400 on every pattern from
  n = 10 to n = 8,505, and saturates at 15 to 28x one core. If the matrix
  values cross PCIe every iteration, the bus caps it at about 4x one core,
  so the values have to be assembled on the device.

Recommendation: do not build a GPU ensemble mode for consumer GPUs. Spend
the effort on host-thread parallelism across sweep points (`sweep/lanes.zig`
runs lanes serially today). Re-measure with the kept harness on an
FP64-class card (A100, H100: FP64 at 1/2 of FP32) before reopening.

## Method

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

## Results: corners x Jacobian (55 points)

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

## Results: Monte Carlo, by N

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

### Break-even N per circuit size

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

## Results: batched refactor and solve kernel

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

## Design questions

### Transient lockstep

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

### Newton lockstep

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

### Memory and batch size

Per point the device holds the LU values, the matrix, five n-vectors and the
device planes: `8 (L+U + nnz + 5n)` bytes plus the eval state. Sampled with
`nvidia-smi`, a PSP103 chains10 point (1,000 instances) costs 6.1 MiB of
eval state on top of a 338 MiB context, so about 6 KiB per PSP103
instance; the LU side adds 1.2 MiB. An 8 GiB card then holds about 1,000
such points. The BSIM3 chains10 stack of 55 points used 164 MiB in all.
Batch size is `floor((VRAM - context - shared tables) / per_point)`, capped
at the N where the kernels saturate (2,048 to 8,192 here). The VRAM cap
binds only on the largest circuits.

### Determinism

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

### Place in the module DAG

The proxy shows the device side needs no ABI change: points are more
instances, with per-point Model rows (bit-identical rows still share one
through `model_of`), and #101 supplies per-point parameter values. So:

- `analysis` owns the ensemble driver: the point table, the convergence and
  step masks, the peel to the host path. It sits beside `sweep/lanes.zig`,
  which already owns the structural lane axis for MC, temp, sens and
  dcmatch.
- The batched replay kernel goes beside `analysis/gpu_lu.zig`, which
  already owns the device LU and its Gompute plumbing. Its scalar oracle is
  the same function at one point (stride 1), checked against
  `SparseLu.refactor` + `solve`, as `LaneLu(1)` is in `solver`.
- `solver` keeps the host oracle and the pivot tape; `device/eval.zig`
  keeps evaluating through `evalRange`, now over points x instances.

## What was not measured

- A real ensemble engine. The stacked proxy has no masks, no peel and no
  batched LU; the batched LU kernel was timed apart from the eval, and the
  two were not combined in one run.
- BSIM4 and sky130 decks.
- A data-center GPU. The answer above depends on FP64 throughput and should
  be re-measured there with the kept harness before anything is built.
- The `psp103_chains10_cj_tran` lockstep check (55 singles plus two stacked
  GPU runs, about 15 minutes); the chain50 check covers the same circuit.
- The tran BSIM3 checks in the original sweep reported only the last-row
  difference (1.99 V, a node mid-edge at t = 4 ns); the numbers above come
  from rerunning them with crossing times.

## Reproducing

```sh
G=tests/benchmark/ensemble
python3 $G/gen.py --selftest
python3 $G/gen.py /tmp/ens psp103 chain50 cj tran 0
python3 $G/run.py zig-out/bin/espice /tmp/ens singles par24 cpu1 cuda cudalu check
```

On NixOS the CUDA runtime needs `LD_LIBRARY_PATH=/run/opengl-driver/lib`.
