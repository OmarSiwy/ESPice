# E1: does a GPU lane backend pay? (issue #208, phase 4 gate)

**Verdict: the gate passes.** The bsimcmg eval kernel (VerA v0.11.0, sparse
layout) costs **0.066-0.081 of one host core's time** per instance-eval on
the RTX 4060 Laptop, against the 0.2 stop line (§11 of
[`lane-batched-simulation.md`](lane-batched-simulation.md)). It costs that
only when a warp holds 32 points of one transistor (lane-innermost). In a
random thread order it costs up to 34% more.

**Recommendation.** Build the GPU lane backend, and aim it at FP64-class
GPUs. On this consumer card it is worth about one to two copies of the
24-core CPU. An A100 or H100 is projected (not measured) at 4-26x and 7-69x the 4060
on device evaluation. Leave CPU SIMD device batching off for every compact-model
family. The CPU lane path stays the deinterleaved scalar oracle that §4
already chose.

Measured 2026-10-19 on branch `gpu-e1` (59d40966 plus e2819c7a, the
`basisOf` branch-quota fix that ReleaseFast needs). The machine was an
RTX 4060 Laptop (sm_89, 24 SMs, 8 GB, FP64 at 1/64, driver 595.71, SM clock
2.64 GHz after a run) and an i9-14900HX (8P + 16E). Eight other agents
shared the machine, so the load average was 30-110. The device-kernel times
are steady across repeats (±2%). The CPU times are not, so read the CPU
ratios as conservative for the GPU.

## Method

**Deck.** `gpu-lane-e1/gen_lanes.py` writes N sweep points of §1's 24-stage
asap7 chain (`7nm_TT.pm` `nmos_rvt`/`pmos_rvt`, LEVEL 72, RC wire per
stage) into one circuit:
- 48 x N bsimcmg instances in one batch. The GPU eval kernel runs one
  thread per instance in deck order (`DeviceKernel`, `ProtoStore` keeps
  deck order), so the deck order sets each warp's contents.
- Each point has its own `vdd` and `vin`, so the circuit is N disjoint
  blocks, as N lanes are.
- `.tran 1p 100p uic`: the input edge at 50-60 ps switches the first
  stages. `uic` skips the operating point, whose 364 host factorizations
  take 7 min at N = 1024 (see "Host LU" below). One N = 1024 run with the
  operating point gave the same kernel time within 3% (10.38-10.67 ms
  against 10.35).

**Orders** (`ORDER`, `SIZING`):

| name | warp contents | stands for |
|---|---|---|
| lane coherent | 32 points of one transistor, identical sizes, identical biases | lane backend, replicated points |
| lane mixed | 32 points of one transistor, `lockstep.py`'s sizes (nfin 2-4, rw/cw 0.5-2x) | lane backend, a sizing sweep |
| lane distinct | lane mixed, plus `l` = 20-21 nm per point, so every point binds its own Model rows | lane backend, continuous sizing |
| point mixed | 16 inverters of one chain | today's order: one circuit, one thread per instance |
| shuffle mixed | random instances | the worst case, the CPU "mixed" set |

**GPU time** is `ESPICE_GPU_STATS=phases`'s `eval` stage, which is the eval
kernels alone with a stream sync on each side, averaged over every eval of
the run (559-735 evals). It includes the resistor, capacitor and vsource
kernels of the same eval: 2N + 48N cheap threads, under 1% (the N = 2 run's
whole eval stage is 417 µs, one bsimcmg thread's latency).
`--backend cuda`, block 64 (the default).

**CPU time** is `--timing-in-depth`'s Newton `eval` over its iterations, on
the same decks in a ReleaseFast build. It covers bsimcmg plus the R and C
stamps, so it slightly favours the GPU ratio's denominator. Threads come
from `ESPICE_THREADS` (ParEval over the one batch).

**Static analysis.** `ptxas -v -arch=sm_89 -O3` (CUDA 12.9) on the
embedded PTX, `cuobjdump -sass` for the instruction mix
(`gpu-lane-e1/sass_mix.py`), and `llvm-readobj --notes` on the gfx1100
`.hsaco`.

## 1. The kernel on the 4060

### Per-instance throughput

Kernel µs per eval, and µs per instance-eval (`/ 48N`):

| N | instances | lane coherent | lane mixed | lane distinct | point mixed | shuffle mixed |
|---:|---:|---:|---:|---:|---:|---:|
| 2 | 96 | 417 (latency) | | | | |
| 1024 | 49,152 | 10,353 = **0.211** | 10,529 = **0.214** | 11,637 = 0.237 | 11,408 = 0.232 | 12,477 = 0.254 |
| 4096 | 196,608 | 37,258 = **0.190** | 38,011 = **0.193** | not measured | not measured | 51,066 = 0.260 |
| 8192 | 393,216 | not measured | not measured | | | |
| 32768 | 1,572,864 | does not fit (below) | | | | |

Not measured: the owner stopped the matrix at N ≤ 4096 (N = 8192, and the
N = 4096 distinct and point rows). The N = 1024 and 4096 rows decide the
gate. One run per cell.

- **Saturation.** The kernel saturates the card by N = 1024. Registers
  limit residency to 8 warps per SM, 6144 threads on the card, so 49k
  threads are already 8 waves. From 1024 to 4096 the per-instance cost
  drops 10%, from the tail of the last wave.
- **Divergence is not a problem in lane order.** Mixed sizes cost +1.7%
  (1024) and +2.0% (4096) over identical points. Points of one transistor
  take the same branches, and SIMT masks the few that do not, without the
  CPU lead protocol's re-runs (0.47x there). Divergence appears when a
  warp mixes transistors: point order +8%, a random order +18% (1024) and
  +34% (4096). **The lane backend must order threads lane-innermost**, as
  §4 of the design already says.
- **Block width** (N = 1024, lane coherent): 32 → 10,353 µs, 64 → 10,353,
  128 → 10,798, 256 → 11,807. Keep 64.
- **Distinct Model rows** cost +10.5% at N = 1024 (4096 not measured: the owner stopped the matrix at N ≤ 4096).
  Every thread then reads its own 22.6 KB row instead of a row the warp
  shares. That is the memory signal used in §3.
- **N = 32768 does not fit** this machine as one circuit. The device
  staging takes 4.3 KB per bsimcmg instance (`gpu-stats: stage` =
  106.7M f64 at N = 4096, 853 MB), so 6.8 GB of staging at N = 32k on an
  8 GB card. The host side needs ~1.3 GB per 1024 points (42 GB at 32k).
  The lane design keeps the staging, so on an 8 GB card N tops out near
  16k points of this circuit unless the staging changes (§4).

### Kernel resources (`arp_eval_bsimcmg`, sm_89, ReleaseFast kernel)

| | value |
|---|---|
| registers | 255 (the cap) |
| stack frame | 20,848 B (the v0.10 dense layout: 83,184 B; v0.10 sparse: 18,544 B) |
| spills in `evalRange` (static) | 19,808 B stores, 27,712 B loads |
| occupancy | 8 warps of 48 per SM (17%), register-limited at any block width |
| ptxas | 85 s wall, 2.8 GB RSS (dense: 250 s, 9.8 GB) |
| PTX | 8.5 MB; first-run driver JIT ~50 s, then cached |
| gfx1100 | 192 VGPRs, 38,216 B private segment |

**Static SASS mix** (173,480 instructions; each counted once whatever its
trip count, so this is the shape of the code, not dynamic work):

| class | share |
|---|---:|
| FP64 add/mul/fma (`DADD` 23,126, `DMUL` 24,900, `DFMA` 15,832) | 36.8% |
| FP64 compare and min/max | 1.4% |
| `MUFU` (rcp/rsq seeds for FP64 div and sqrt) | 1.1% |
| FP32-pipe (`FSEL` mostly: selecting FP64 high words) | 6.9% |
| local load/store (stack, spills) | 4.7% |
| global load/store | 2.8% |
| branches, calls, reconvergence | 11.4% |
| integer, moves, selects | 33.5% |

**Dynamic FP64 work.** There is no `ncu` here (`RmProfilingAdminOnly=1`),
so the dynamic count comes from the CPU instead. `perf stat` on one P-core
over the N = 32 deck counted 5.24G scalar, 0.15G 128-bit and 1.49G
256-bit FP64 operations: **at most 21.4k FP64 flops per instance-eval**.
That is an upper bound. It includes limiting, the gates, the LU and the
accepted-point charge reads, it counts an FMA as 2 and it counts the
padding lanes of the host's vector duals.

## 2. Host comparison

Same decks, ReleaseFast, µs per instance-eval:

| run | µs | GPU kernel ratio |
|---|---:|---:|
| 1 thread, N = 32, lane mixed | 3.13 (2.72 pinned to a P-core under perf) | |
| 1 thread, N = 1024, lane coherent | 2.89 | 0.211 / 2.89 = **0.073** |
| 1 thread, N = 1024, lane mixed | 2.93 | 0.214 / 2.93 = **0.073**; at N = 4096, 0.193 / 2.93 = **0.066** |
| 1 thread, N = 1024, shuffle | 3.13 | 0.254 / 3.13 = **0.081** |
| 24 threads (ParEval), N = 1024, lane mixed | 0.54 (5.5x one thread) | GPU = 2.8x |
| 32 threads (ParEval), N = 1024, lane mixed | 0.66 (4.5x) | |
| 24 independent 1-thread jobs (N = 32 each) | aggregate 11x one job (each job 2.2x slower) | GPU ≈ 1.3x |

The single-core figure matches §1's 3.4 µs. ParEval over one batch scaled
poorly here (load average 44-66 from other work). Independent jobs, which
is how the CPU serves sweep points today, gave 11x on 24 cores. A quiet
machine would land higher, perhaps 14-16x (8 P-cores, and E-cores at about
0.6 of a P-core). So the comparison uses **24 cores ≈ 11-16 single-core
equivalents**.

`Cost`'s `cost_kernel_ratio = 0.12` (fit on mos1 and bsim4va) is
pessimistic for bsimcmg by about 1.7x. `auto`'s per-device pricing still
holds. A better fit would price kernels per model.

## 3. Gate and roofline

**Gate:** 0.066-0.081 of host serial time, against the 0.2 stop line.
**Pass**, with 2.5-3x margin.

**What bounds the kernel on the 4060.** sm_89 issues 2 FP64 operations per
clock per SM: 24 x 2 x 2.64 GHz = 1.27e11 FP64 instructions/s
(253 GFLOP/s with FMA). At 0.193 µs per thread-eval, the card runs
5.2M thread-evals/s.
- If all 21.4k bound flops were separate FP64 instructions, the FP64 pipe
  would be 89% busy.
- If every one were half of an FMA (10.7k instructions), 44%.
- Counting FMAs once and dropping the host's padding lanes gives roughly
  12-14k instructions: 50-60% busy.
- One thread alone (N = 2) takes 417 µs. At 8 warps per SM, the FP64 pipe
  alone accounts for 0.64-1.07 ms of each wave, and a saturated wave takes
  1.17 ms (6144 threads x 0.19 µs).
- So **FP64 issue is 45-90% of the kernel time**, most likely 50-60%. The rest is memory and
  latency:
  - 20.8 KB of stack per thread x 6144 resident threads = 128 MB, four
    times the 32 MB L2, so spills go to DRAM;
  - distinct Model rows add 10%.

**Projection.** Model the per-instance time as an FP64 part f that scales
with FP64 rate and a memory part 1 - f that scales with DRAM bandwidth:
`t = 0.193 µs x (f / R_fp64 + (1 - f) / R_bw)`, for f between 0.45 and 0.9.
Occupancy carries over unchanged, because every one of these parts has
64K registers per SM.

| GPU | FP64 vector | R_fp64 vs 4060 | DRAM | R_bw | µs per instance-eval | vs 4060 | vs one host core (2.93 µs) |
|---|---|---:|---|---:|---:|---:|---:|
| RTX 4060 Laptop | 0.25 TF | 1 | 256 GB/s | 1 | 0.193 (measured) | 1x | 0.066 |
| A100 (SXM, 108 SMs) | 9.7 TF | 38 | 1.6-2.0 TB/s | 6-8 | 0.0073-0.015 | 13-26x | 0.0025-0.005 (200-400 cores) |
| H100 PCIe | 26 TF | 102 | 2.0 TB/s | 7.8 | 0.0042-0.012 | 16-46x | 0.0014-0.004 |
| H100 SXM | 34 TF | 134 | 3.35 TB/s | 13 | 0.0028-0.0075 | 26-69x | 0.001-0.0025 (400-1000 cores) |

These are PROJECTED, not measured. The table's model is the optimistic one:
it treats the non-FP64 part as bandwidth. If that part is issue and latency
bound instead (17% occupancy, integer and branch work at 45% of the static
mix), it scales with SM count x clock: A100 108 x 1.41 GHz = 2.4x the 4060,
H100 SXM 132 x 1.98 GHz = 4.1x. Then f = 0.45 gives **A100 ≈ 4x, H100 SXM
≈ 7x** the 4060 (0.046 and 0.027 µs per instance-eval). **The honest range
is A100 4-26x and H100 SXM 7-69x the 4060**, that is about 4-37x and
7-96x the whole 24-core CPU (11-16 single-core equivalents). The low end still clears the CPU.

- **Where the time goes on those parts.** The FP64 part almost vanishes
  there, so the memory part dominates. That means:
  - stack spills: a 20.8 KB frame;
  - the staging traffic (§4);
  - distinct Model rows.
- **What would raise the ceiling.** A smaller frame (fewer live derivative
  lanes per expression) and Model rows packed per distinct size (the
  design's "packed rows") raise the ceiling most. FP64 tensor cores (H100
  67 TF) do not apply to this scalar code.
- **Caveats:** unmeasured on such a part. The bandwidth term treats
  local-memory latency as bandwidth. The bigger L1 (192-256 KB) and L2
  (40-50 MB) of A100 and H100 should help spills, so the low end of each
  range is the likelier one. Run E1 on an A100 before sizing the phase-4
  CI around these numbers (`run.sh … cuda` works unchanged).

## 4. End to end: one Newton tick

**The design doc's "50 ms" is per run, not per tick.** §5.1's figure is
3477 ticks x 13 µs of graph replay and sync. Per tick it is about 13-50 µs,
nothing next to the compute below.

Measured per-eval stages of today's non-resident path (µs):

| N | x upload + staging clear | eval kernels | reduce 1 | reduce 2 | planes download |
|---:|---:|---:|---:|---:|---:|
| 1024 | 1,032 | 10,353 | 1,323 | 323 | 1,980 |
| 4096 | 4,264 | 37,258 | 5,239 | 1,291 | 7,865 |

- **Clear and reduce** cost 20-27% of the kernel. The clear zeroes 853 MB
  of staging at N = 4096, and the reduce sums the deterministic staging.
  A lane design that keeps per-contribution staging pays this every tick.
- **Upload and download** (~25% of the kernel) disappear when lane state
  stays resident. The design already assumes that.
- **Lane LU and solve** (not built; estimated). nnz(L+U) = 1385 per lane
  (11 KB of values). One refactor at N = 8192 reads and writes about
  3 x 90 MB lane-major: ~1 ms at 256 GB/s. Its ~50 MFLOP takes 0.2 ms even
  at 1/64 rate. That is **1-2% of the tick**.
- **Limiting, gates, LTE, masks:** per-lane O(n) work, a few percent. The
  bsimcmg limit kernel is a separate small kernel (not timed here).

**Projected tick at N = 8192 on the 4060:**
- eval: 393k x 0.193 µs = 76 ms (measured rate);
- clear and reduce: ~20 ms (twice the N = 4096 figures);
- LU and solve: ~1-2 ms;
- launch: < 0.05 ms;
- total **≈ 97 ms**.

§9 estimated 160 ms. Device eval dominates at ~78%, the staging reduce is
second, and the batched LU is minor.

**Per point, a full run (3477 ticks):** 97 ms x 3477 / 8192 ≈ 41 ms of
device work, ≈ 45 ms with limiting and state staging.
- One host core runs a point in 0.98 s (§1), so 24 cores take 61-89 ms per
  point at the measured 11-16 single-core equivalents.
- **The 4060 is 1.4-2x the whole 24-core CPU** and leaves the CPU free.
  Early stop (57%) helps both sides equally.
- On an A100 the eval term drops to 3-6 ms per tick. The staging
  clear-and-reduce (~3 ms when bandwidth scales) then rivals it, so phase 4
  should design the lane `Sink` without the per-contribution staging if
  datacenter parts are the target. One option is lane-strided stamps with
  each lane's instances in a fixed order, which keeps the CPU summation
  order without a clear-and-reduce pass.

**Host LU, a side finding.** Packing N points into one circuit is not a
substitute for lanes. The host factor of the merged matrix grew
superlinearly:
- 93 ms per factorization at N = 1024 (n = 299k);
- 1.39 s at N = 4096 (n = 1.2M), and 2.4 s with the shuffled order;
- the operating point's ladder at N = 1024 spent 443 s factoring.

Per-lane LU on a shared tape has none of this.

## 5. Stack frames per backend (VerA v0.11.0, sparse only)

Eval kernel, ReleaseFast. Every model temporarily removed from
`gpu_host_only` (`-Dgpu-only=…`, below). CUDA: standalone ptxas 12.9,
sm_89. gfx1100: `llvm-readobj --notes`, `.private_segment_fixed_size`.

| model | CUDA stack | ptxas wall / RSS | gfx1100 private segment | gfx1100 VGPRs | before (v0.10 dense, CUDA) |
|---|---:|---:|---:|---:|---:|
| bsimcmg | 20,848 B | 85 s / 2.8 GB | 38,216 B | 192 | 83,184 B |
| bsimbulk | 17,200 B | 39 s / 2.1 GB | 31,144 B | 192 (5630 VGPR spills) | — |
| psp103_nqs | 48,880 B | 74 s / 5.3 GB | 65,624 B | 192 | ~500 KB on gfx1100 (main's reason for host-only) |
| psp104_nqs | 50,544 B | 78 s / 5.9 GB | 68,056 B | 192 | ~500 KB on gfx1100 |
| mvsg | 47,088 B | 105 s / 5.7 GB | 79,992 B | 192 | 432,112 B |
| asmhemt | 12,912 B | 177 s / 10.9 GB | 113,368 B | 192 | 29,168 B |
| bsimsoi_va | 21,424 B | 181 s / 11.0 GB | 93,752 B | 192 | 68,080 B |

- **CUDA.** Every one fits CUDA's 262,136 B limit by 5x or more, so none
  needs `gpu_host_only` for CUDA any more.
- **gfx1100.** Every model compiles and links. The frames are 1.5-9x the
  CUDA ones, and 113 KB is the largest. No AMD card is on this machine, so
  whether HIP launches them is untested.
- **bsimbulk** builds on both backends.
- **This branch leaves `gpu_host_only` unchanged.** Dropping entries is a
  build-policy change for the owner, and it needs `test-gpu` runs for the
  models that have decks.

## 6. Recommendation

1. **Build the GPU lane backend (phase 4).** E1 passes at 0.066-0.081 of
   host serial time.
2. **Target FP64-class GPUs.** A100 and H100 project (PROJECTED) to
   4-26x and 7-69x the 4060 on eval (§3), at least 4-7x the 24-core CPU
   at the conservative end.
   - On this card the lanes are 1.4-2x the 24-core CPU per point: useful
     as offload, not a reason to buy one.
   - Keep `auto` pricing per device. Re-fit `cost_kernel_ratio` per model:
     bsimcmg measures 0.07, not 0.12.
3. **Phase 4 design points this run fixed:**
   - threads lane-innermost (a random order costs 34%);
   - state resident (removes ~25% of transfers);
   - the staging clear-and-reduce is the next cost after eval: 20-27% of
     the kernel on the 4060, comparable to eval on datacenter parts;
   - the batched LU is 1-2% and can follow `LaneLu` directly;
   - an 8 GB card caps N near 16k points of this circuit with today's
     staging.
4. **CPU SIMD device batching: off for every compact-model family**:
   bsimcmg, bsim4, psp, hisim, bsimsoi, bsimbulk, and anything whose
   derivative duals already fill the vector registers (n_u ≳ 8).
   - bsimcmg measured 0.97-1.02x coherent and 0.47x mixed.
   - The only plausible wins are cheap devices with a shared instance
     (VerA's study: diode 1.26x, mos1 1.34x, falling to 1.02-1.16x per
     instance). Revisit only if a MATCHA profile is dominated by them
     (§4's existing rule).
   - The CPU lane path stays the deinterleaved scalar oracle.
5. **Next measurement:** this E1 on an A100 or H100, to replace the
   roofline with a number.

## Reproduce

From `ESPice-gpu-e1` (worktree `.zig-cache` linked to the main checkout's).
The kernel-root filter is a temporary patch to `build.zig`, kept as
`gpu-lane-e1/gpu-only.patch` and not applied on the branch (`git apply` it
first). It adds `-Dgpu-only=<comma list>`: only those models get kernel
images, and `gpu_host_only` is ignored:

```zig
// in the option block
const gpu_only = b.option([]const u8, "gpu-only", "E1: comma list of models that get kernel images");
// replacing `if (!gpu_kernels or gpu_host_only.has(m.name)) continue;`
if (!gpu_kernels) continue;
if (gpu_only) |list| {
    var it = std.mem.splitScalar(u8, list, ',');
    const hit = while (it.next()) |n| {
        if (std.mem.eql(u8, n, m.name)) break true;
    } else false;
    if (!hit) continue;
} else if (gpu_host_only.has(m.name)) continue;
```

```sh
M=/home/omare/Documents/Projects/Zig/ESPice
PM=~/Documents/Projects/Research/MATCHA/pdks/asap7/7nm_TT.pm
# timing build (9 min warm): ReleaseFast host, CUDA kernels for the deck's models
nix develop $M -c zig build -Doptimize=ReleaseFast -Dgpu=true -Dcuda-arch=sm_89 \
  -Dhip-arch=none -Dgpu-only=bsimcmg,resistor,capacitor,vsource
# kernel matrix (one row per run; ~1 min at N = 1024, ~9 min at N = 4096, host LU bound)
export TMPDIR=/tmp
R=dev/research/gpu-lane-e1
$R/run.sh zig-out/bin/espice $PM 1024 lane mixed "100p uic" cuda     # GPU
$R/run.sh zig-out/bin/espice $PM 1024 lane mixed "100p uic" cpu 1    # host serial
$R/run.sh zig-out/bin/espice $PM 1024 lane mixed "100p uic" cpu 24   # ParEval
ESPICE_GPU_BLOCK=128 $R/run.sh zig-out/bin/espice $PM 1024 lane coherent "100p uic" cuda
# gpu_matrix.sh and cpu_matrix.sh run the rows of the tables above
# FP64 op count (perf from nixpkgs; perf_event_paranoid=2 is enough)
nix shell nixpkgs#perf -c perf stat -e cpu_core/fp_arith_inst_retired.scalar_double/,cpu_core/fp_arith_inst_retired.128b_packed_double/,cpu_core/fp_arith_inst_retired.256b_packed_double/ \
  taskset -c 4 env ESPICE_THREADS=1 zig-out/bin/espice --backend cpu -b -r /dev/null $TMPDIR/e1_32_lane_mixed_100p_uic.sp
# stack frames: Debug host (kernels still build ReleaseFast), CUDA and gfx1100
nix develop $M -c zig build -Doptimize=Debug -Dgpu=true -Dcuda-arch=sm_89 -Dhip-arch=gfx1100 \
  -Dgpu-only=psp104_nqs,psp103_nqs,asmhemt,bsimsoi_va,mvsg,bsimcmg,bsimbulk -p /tmp/zig-out-B
# then, per model, on .zig-cache/o/*/gompute_cuda_obj_<m>.s and gompute_<m>.hsaco:
nix develop $M -c ptxas -arch=sm_89 -O3 -v <m>.ptx -o <m>.cubin    # "arp_eval_<m>" stack frame
nix develop $M -c cuobjdump -sass bsimcmg.cubin > bsimcmg.sass && python3 $R/sass_mix.py bsimcmg.sass arp_eval_bsimcmg
llvm-readobj --notes gompute_<m>.hsaco    # ROCm llvm; .private_segment_fixed_size of arp_eval_<m>
```
