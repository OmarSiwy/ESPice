# Design review: data-oriented-design audit, engine half

- **Change**: audit of `src/solver/`, `src/analysis/` and `src/device/` against the `data-oriented-design` skill (Six Questions, layout, memory, parallel, types checklists). One mechanical fix applied; the rest proposed.
- **Domain skill(s)**: `data-oriented-design`, with `spice-engine` (solver, Newton, transient) and `gpu-kernel-optimization` (the host side of the GPU contexts).
- **Hot/cold**: hot where the code cites a measurement. Evidence: `refactorColumns` and `solve` hoist fields because the reloads cost 35% of `refactorColumns` on `scaling/parallel_inverters_100` (sparse_lu.zig:907-910); ParEval was profiled on `chain_psp103_10k` and bare PSP103 decks (#137, #138, dev/analysis/refactoring.md "ParEval"); the host refactor's spin cost was measured on `chain_psp103_10k` under load (lu_kernels.zig:580-584); device eval layouts carry per-model callgrind numbers (eval.zig:900-909). Everything else is cold until profiled.
- **Stages run**: R2 (data) and R8 (proof plan) over the tables below; R10 on the applied commit. No seam or boundary moved, so R1, R4, R5 and R9 do not apply.
- **Frozen boundary (§2.9)**: no finding goes through the scatter tapes, the Model/Instance PODs, `model_of`, pattern CSC or the plane layout. Nothing here needs an ABI bump.

Overall: the hot tables are already in the shape the skill asks for. They are SoA, use u32 handles, have measured hot/cold splits and `W == 1` oracles, and the layout decisions are written down with numbers. The findings that remain are in the threaded code (counters that share cache lines) and in one per-step allocation on the GPU host path. The one APPLIED fix is a field reload that the neighbouring functions had already fixed.

## Data (R2): the Six Questions per table

| Table | Owner | In → out | How many | Widths (range) | Access pattern | Lifetime | Parallel | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| analysis `Circuit` planes `g_vals`, `c_vals` (nnz+1), `rhs`, `q_vec` (n+1) | analysis/Circuit.zig | x → planes (device pass); planes → solver | nnz to ~10⁷, n to ~10⁶ | f64; slots u32 (< 2³²) | streamed whole: clear, stamp scatter, `combinePlanes`, factor | query (`Circuit.gpa`, executor allocator) | ParEval stages per tape position; reduce over 16-cell blocks | pass: SoA, one plane per quantity, trash slot in place of a ground branch |
| `Batch` | device/abi.zig:166 | batch → eval call | one per device type | ≤ 64 B, asserted (abi.zig:187-192) | walked once per Newton iteration, every field of one batch read together | session (frozen) or query (instantiated) | per batch | pass: AoS justified, one line per type |
| `DeviceBatch(D)` Model/Instance/tapes | device/eval.zig:1541 | x, Model, Instance → stamps | instances per type | `model_of`, tapes u32; Model/Instance frozen PODs | Instance and Model read whole per instance; tapes gathered | query | `evalRange` per instance range | pass, frozen (§2.9) |
| `SparseLu` (`lp/li/lx`, `up/ui/ux`, `udiag`, `prow`, tape `[3]u32`) | solver/sparse_lu.zig | A values → L, U | nnz(L+U) | indices u32, values f64; `base_lu: usize` (could be u32 like `lp`, no payoff) | refactor replays the column order; tape ≤ 2048 flops stays in L1 (measured) | query (`Workspace`) | serial; multicore refactor in lu_kernels | pass, with one reload finding (F4, applied) |
| `LaneLu(W)` | solver/lane_lu.zig | W value planes → W factors | nnz(L+U) × W | `@Vector(W, f64)` per entry | replays the base pattern | per frequency block | lanes = frequency points (§2.10) | pass; `base: *const SparseLu` is a stored pointer (F7) |
| `Bbd` per-block metadata (8 u32 columns) and dense arena | solver/bbd.zig:46-53 | blocks → Schur complement | nb ≥ 8 blocks, s ≤ 64, border ≤ 512 | u32 offsets (arena < 2³² f64, checked) | all 8 columns read together per block | query | blocks independent until the Schur sum | minor (F6) |
| Transient history `q_hist[4]`, `i_prev`, `qt_hist` | analysis/tran/tran.zig:166-276 | q, i → companion, LTE | n or LTE sites | f64 | streamed by `companionAt` / `stepBound`, vector kernels with `W == 1` oracles | query | no (sequential in t, §2.10) | pass: rotation by slice swap, no copies; one O(n) copy per step (F8) |
| `Waveform.rows` | analysis/tran/types.zig:66 | x[probes] → result rows | accepted points × probes | f64, `len`/`capacity` u32 | appended once per accepted point, row-major as published | result | no | pass; arena growth already marked `ponytail:` |
| Sweep lanes `x_lanes` | analysis/sweep/lanes.zig | params → lanes × n solutions | lanes × n | f64 | lane k written once, read by the warm start and the probes | query | lanes serial by design (§2.10) | pass; O(lanes·n) already marked `ponytail:` |
| `NoiseSource` rows | device/abi.zig:92 | devices → noise rows | generators | node u32, group u32, f64 ×4, table slice | every field of a row is read per point (`transfer`, `sourcePsd`) | per noise query (scratch) | no | pass: AoS justified |
| `Library` (`names`, `vtables`, `digital`) | device/Library.zig | HDL load → `DeviceType` | one per type (u16 ids) | `DeviceType` backing int | cold lookups | Problem | n.a. | pass: SoA and cold |
| Device catalog | device/catalog.zig | comptime decls → rows | built-ins | comptime | comptime only | static | n.a. | pass |
| ParEval staging, `Gather`, counters | analysis/par_eval.zig | stamps → staged → planes | tape entries | positions u32 (checked < 2³²) | staging written once per pass; reduce gathers in tape order | query | lanes claim chunks and blocks | fail on counter placement (F1) |
| Host refactor sync buffer | solver/lu_kernels.zig:42-45, 133-137 | column done stamps, tickets | 4 + 3n u32 | u32 | ticket `fetchAdd` per column; spins on producer stamps | query | lanes = host threads | needs measurement (F2) |

Transforms (the hot ones):

- `Circuit.stamp: x, batches → g_vals, c_vals, rhs, q_vec`
- `ParEval.run: x, batches, tapes → stage → planes`
- `SparseLu.refactor: col_ptr, vals → lx, ux, udiag`
- `SparseLu.solve / solveT: b → x`
- `LaneLu(W).refactor / solve / solveT: V planes → V factors → V solutions`
- `integrator.companionAt: q0, q1, q2, i_prev → rhs`
- `integrator.stepBound: q_hist, i_prev → dt bound`
- `GpuContext.pullStepped / pushStepped / syncInstances: device Instance bytes ↔ host Instance bytes`

## Findings, ranked by expected payoff

### F1. ParEval's shared counters sit on one cache line beside the pass arguments (PROPOSED)

`analysis/par_eval.zig:121-139`. `quit`, `epoch`, `sleepers`, `next_task`, `next_block`, `stamped` and `done` are adjacent `std.atomic.Value` fields, followed by the `job_*` pass arguments. In one pass every lane `fetchAdd`s `next_task` once per chunk (about 8 chunks per lane), then `stamped`, then `next_block` per reduce block, then `done`. Meanwhile the other lanes spin on `stamped` (`waitCount`) or on `epoch`, and read `job_batches`, `job_planes` and `job_x` on every chunk. Each `fetchAdd` takes the line exclusive, so every spinner and every reader of a `job_*` field misses on its next access. The #138 dig measured 4.5-5.3% of cycles in the barrier spin on `chain_psp103_10k` at 8 lanes. That figure includes this line traffic, but the dig did not separate it out.

Fix: give each counter that one lane writes while others read its own line, and keep the read-only `job_*` fields away from all of them:

```zig
next_task: std.atomic.Value(u32) align(std.atomic.cache_line),
next_block: std.atomic.Value(u32) align(std.atomic.cache_line),
stamped: std.atomic.Value(u32) align(std.atomic.cache_line),
done: std.atomic.Value(u32) align(std.atomic.cache_line),
epoch: std.atomic.Value(u32) align(std.atomic.cache_line), // with `sleepers`, both rarely written
```

This costs about 5 × 128 B on one heap object per query.

Why not applied: it is a layout change in a hot path, and §2.13 requires a measured before/after. The fix is cheap, but its payoff is not known.

Measurement plan: `zig build bench` on `stress/scaling_inverter_chain_4k` and a bare PSP103 10k deck at `--threads 1, 4, 8, 16`; `perf stat -e mem_load_l3_hit_retired.xsnp_fwd` (the counter #138 used) before and after; wall time per Newton iteration from `--timing-in-depth`. The planes must stay byte-identical at every lane count, which the existing ParEval tests already check (1 to 24 lanes).

### F2. The host multicore refactor's ticket shares a line with the first done stamps; stamps are packed 16 per line (PROPOSED)

`solver/lu_kernels.zig:42-45, 133-137, 172, 190-192`. The sync buffer is `[ticket, fail, lsolve ticket, usolve ticket, done[0..n], done[n..2n], done[2n..3n]]` in u32. Every column takes the refactor ticket with an `atomicRmw` on `sy[0]`, and `done[0..11]` share that line. Beyond the header, `done[k]` stamps for 16 consecutive pivot steps share one line. A thread publishing step k invalidates the line for every thread spinning on k±15, and with dynamic tickets those are exactly the neighbouring steps other threads are working on.

Two fixes, each needing its own measurement:
- (a) **Cheap:** set `sync_header = 16` so the four header words fill one 64-byte line and the stamps start on the next. The cost is 48 bytes, and the change is shared by the host and device kernels (`gpu_lu.zig:220` clears `sync_header * 4` bytes and follows automatically).
- (b) **Expensive:** stride the stamps one per line. That makes the buffer 16× larger (6.4 MB at n = 100k), so it pays only if c2c traffic on the stamps is measured to be large.

Why not applied: (a) touches the GPU LU, which §2.9 says to verify with the default GPU build and `zig build test-gpu`. Both are speed claims without a number.

Measurement plan: `ESPICE_LU_PAR=1 ESPICE_LU_PAR_STATS=1` on `chain_psp103_10k` and `stress/scaling_parallel_inverters_2000`; `perf c2c record` on the host refactor; refactor wall time from `--timing-in-depth`; `zig build test-gpu` unchanged.

### F3. The GPU host path allocates and frees a full Instance-bytes buffer on every accepted step (PROPOSED)

`analysis/gpu.zig:1764-1765, 1788-1789, 1819-1820`. `pullStepped` (called from `updateStates`, gpu.zig:1651, once per accepted transient point), `pushStepped` and `syncInstances` each do `self.gpa.alloc(u8, host.len)` / `free` per batch per call. `host.len` is the whole Instance array, megabytes at 40k instances. An allocation that size goes straight to `mmap`/`munmap`, so each call also pays page faults on first touch. This is per-step work that a reusable buffer would hoist out of the loop (skill memory checklist: "nothing allocates per-iteration that an arena or reused buffer could hoist").

Fix: one `dev: []u8` per `BatchGpu`, the same length as `base`, allocated where `base` is allocated (gpu.zig:849) and freed with it. All three call sites then download into `bg.dev`.

Why not applied: §2.9 says anything touching `analysis/gpu.zig` is verified with the default (GPU) build and `zig build test-gpu`, and agents cannot build here.

Measurement plan: a transient on a stepped batch with `has_status` and `--backend cuda` (a `.tran` over the PSP103 10k deck if its model is host-stepped; otherwise the `hdl/` deck that exercises `pullStepped`); `perf stat -e page-faults` and wall time per accepted step, before and after.

### F4. `SparseLu.solveT` reloaded every slice header through `self` inside its loops (APPLIED, 6ee9fa8a)

`solver/sparse_lu.zig` (`solveT`, and `pinv`/`udiag` in `solve`), `solver/lane_lu.zig` (`solve`, `solveT`). `refactorColumns` and `solve` already hoist `w`, `lp`, `up` and `y` into locals because a store through `y` may alias `self`; the reloads measured 35% of `refactorColumns`. `solveT` was missed: it read `self.y`, `self.up`, `self.lp`, `self.udiag` and `self.pinv` inside the loops and accumulated into `self.y[k]` in memory. `solveT` is the adjoint solve of `.noise` (scalar fallback, freq_solve.zig:313), `.sens`, `.dcmatch` and `.tf`.

The fix hoists the headers and keeps a running `yk`, the same form as `LaneLu.solveT`, which is its bitwise per-lane twin. U is strictly upper and L strictly lower, so `ui[p] != k` and `li[p] != k`: the subtractions are the same ones in the same order, and the results are bitwise unchanged. Checked with `ast-check` only (agents cannot build). The gate run is the integrator's: `zig build test-solver -Dgpu=false` (the `LaneLu(W)` vs scalar replay test and the SparseLu residual tests cover it), then the full ReleaseSafe gate.

No speedup is claimed. Measurement plan: callgrind Ir on `zig build test-solver --filter solveT`, or `.noise` on `sweep_opamp_wl_200` with the scalar path forced.

### F5. Per-iteration hook walks (pass, no change)

`analysis/walk.zig`, `Circuit.advanceIteration`, `checkConvergence`, `predictFirstIterate`. Each Newton iteration walks `[]Batch` up to five times, testing an optional hook per batch. That is O(device types) per iteration, and `Batch` is one line (asserted), so the walks read lines that are already cached. Bucketing by hook would save nothing measurable. No change.

### F6. BBD per-block metadata: 8 parallel columns read together, three of them derivable (LOW, PROPOSED as "do nothing unless profiled")

`solver/bbd.zig:46-53, 166-173`. The block loop reads `blk_start`, `blk_s`, `blk_m`, `blk_a_off`, `blk_w_off`, `blk_f_off`, `blk_piv_off` and `blk_loc_off` together for each block. By Rule 2 that is the AoS case. Also, `w_off = a_off + s²`, `f_off = w_off + s·m` and `piv_off = Σ s` can be derived. Per block, though, the work is a dense O(s³) factor with s ≤ 64, so 8 metadata loads per block are noise. Recommendation: leave it unless a profile of a BBD deck shows the metadata. If it is ever touched, drop the three derivable columns rather than converting to AoS.

### F7. Stored pointers outside the §2.12 allowed list (owner decision)

§2.12 allows only these stored pointers: `Batch` vtable, slices into owned storage, `ParamRef.ptr` and `Circuit.lin.x_ptr`. Found in these modules:

- `LaneLu.base: *const SparseLu` (lane_lu.zig:30). A borrow with a lifetime contract ("must outlive self"), and `planesMatch` asserts the shape on every call.
- `analysis.Circuit.par_eval`, `gpu`, `lu`, `display` (Circuit.zig:137-146). Borrowed executor-owned contexts: one each per query, never a table row.
- `Session.topology`, `deck`, `templates: []*const Circuit`; `Row.executor: ?*Executor` (session.zig:94, 105-123); `Executor.topology`, `deck`.
- `Display.out`, `Waveform.sink`, `Executor.stream`: writers.

None of these is a cross-object reference into a growable table, which is what Principle 5.1 forbids: each is a borrow of a singleton or of a heap object with a stable address. `Row.executor` is the nearest to a table reference. A worker thread holds the Executor's address, though, so a handle would need a stable pool anyway. Recommendation: add "borrowed per-query contexts and writers" to the §2.12 allowed list rather than convert them. This is an owner decision because §2.12 is binding.

### F8. One O(n) copy per accepted transient step (LOW, PROPOSED)

`analysis/tran/tran.zig:489` copies `ckt.q_vec` into `q_hist[0]` after every accepted step. Binding the q plane to `q_hist[0]` before the step would remove it, but the plane binding is shared with ParEval and the GPU (`bindPlanes`), so the change crosses owners. At O(n) per step against a device eval of O(instances × n_u²), the expected payoff is under 1%. Measurement plan before anyone touches it: callgrind on `stress/scaling_rc_ladder_100k` (n = 100k and cheap devices, the worst ratio), counting `copySimd` Ir per step.

### F9. Widths (pass)

All index columns are u32 with stated capacities (CSC slots, tape positions checked against 2³² in `ParEval.init`, BBD arena offsets checked in `Bbd.init`). `DeviceType` ids are u16-backed. `SparseLu.base_lu: usize` holds an L+U count that `lp`/`up` already bound to u32. Narrowing it saves 4 bytes in a one-per-query struct, so leave it. `abi.NoiseGen` uses `usize` row/col, but it exists only at comptime (`D.noise_gens`), so the width costs nothing at runtime.

## Containment (R6)

No change to error sets or checks. F1-F3 add no checks. F4 keeps `solveT`'s three asserts.

## Proof (R8)

| Abstraction / change | Rung | Probe verdict | Data size | Code size | Benchmark (before → after) |
| --- | --- | --- | --- | --- | --- |
| F4 hoist (6ee9fa8a) | 1 | n.a. (no abstraction) | 0 | expect smaller | not measured, no claim |
| F1 counter padding | 1 | n.a. | +~640 B per query | 0 | plan above |
| F2(a) sync header | 1 | n.a. | +48 B | 0 | plan above |
| F3 reusable buffer | 1 | n.a. | +Instance bytes per stepped batch, resident (replaces a per-step mmap of the same size) | ~0 | plan above |

## Checklist

| # | Check | Source | Verdict | Evidence |
| --- | --- | --- | --- | --- |
| 1 | bytes-in/bytes-out stated for every hot transform | DOD review: transformation | pass | Transforms list above |
| 2 | collections match access pattern (SoA unless all fields read together) | DOD: layout | pass, F6 minor | Six Questions table |
| 3 | no pointer that could be an index | DOD: layout; §2.12 | owner decision | F7 |
| 4 | no bool or rare field in a hot struct | DOD: layout | pass | `Batch` ≤ 64 B asserted; `current_row` is its own column, loaded as `@Vector(W, bool)` (converger.zig:706) |
| 5 | every field width justified by a range | DOD: types | pass | F9 |
| 6 | no vtable in a hot loop that could be an enum | DOD: layout; §2.1 | pass | `Batch.eval` is rung 7, once per batch per pass (S2) |
| 7 | nothing allocates per iteration that a reused buffer could hoist | DOD: memory | fail | F3 |
| 8 | nothing grows element-wise in a loop | DOD: memory | pass | `Waveform` pre-sized, doubling marked `ponytail:`; `PatternBuilder.reserve` |
| 9 | per-thread hot data on separate cache lines | DOD: parallel | fail | F1, F2 |
| 10 | shared mutable state that could be partitioned | DOD: parallel | pass | ParEval staging is per position; reduce blocks 16-cell aligned |
| 11 | hot loops vectorize or the blocker is named | DOD: verify | pass | `companionAt`, `stepBound`, `updateAndNorm`, `combinePlanes`, `LaneLu` all explicit `@Vector` with `W == 1` oracles |
| 12 | frozen GPU boundary untouched | §2.9 | pass | no finding crosses it |

## Proposed issues

**1. ParEval: put the claim and barrier counters on their own cache lines**
Body: `analysis/par_eval.zig:121-139` places `epoch`, `sleepers`, `next_task`, `next_block`, `stamped` and `done` on one or two cache lines beside the read-only `job_*` pass arguments. Every chunk claim (`next_task.fetchAdd`), reduce-block claim and barrier increment invalidates the line for every spinning lane and every lane about to read `job_x`/`job_planes`. #138 measured 4.5-5.3% of cycles in the barrier spin on `chain_psp103_10k` at 8 lanes without isolating this cause. Fix: `align(std.atomic.cache_line)` on each written counter, `job_*` after them. Acceptance: `perf stat -e mem_load_l3_hit_retired.xsnp_fwd` and per-iteration eval time from `--timing-in-depth` on a PSP103 10k deck at 4, 8 and 16 threads, before and after; the planes stay byte-identical at 1 to 24 lanes (existing test).

**2. Host multicore refactor: separate the ticket line from the done stamps**
Body: `solver/lu_kernels.zig` `sync_header = 4` puts the refactor ticket (`atomicRmw` per column) on the same line as `done[0..11]`, and stamps pack 16 per line, so publishing step k invalidates spinners on k±15. Step 1: `sync_header = 16` (48 bytes; shared with the device kernel, `gpu_lu.zig` follows). Step 2, only if `perf c2c` shows stamp traffic: one stamp per line. Acceptance: `ESPICE_LU_PAR=1` refactor time on `chain_psp103_10k` and `scaling_parallel_inverters_2000` before and after, `perf c2c` HITM counts, `zig build test-gpu` unchanged.

**3. GPU context: reuse one download buffer per stepped batch instead of allocating per step**
Body: `analysis/gpu.zig` `pullStepped`, `pushStepped` and `syncInstances` allocate and free a buffer the size of the whole Instance array on every call. `pullStepped` runs once per accepted transient point, so a 40k-instance batch maps and unmaps megabytes per step and page-faults them in. Fix: a `dev: []u8` per `BatchGpu`, sized like `base` and allocated with it. Acceptance: page faults and wall time per accepted step on a host-stepped, status-latching batch under `--backend cuda`, before and after; `zig build test-gpu` and CUDA-vs-CPU results unchanged.

## Accepted exceptions

None requested.
