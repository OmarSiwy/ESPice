Static review of all five assigned files. No builds, tests, assembly generation, benchmarks, or profilers were run. Findings are ordered by expected benefit on the workloads named below, not by measured whole-program cost. All timing estimates need profiling; operation and storage counts come from the source.

| File | Review and cleanup |
| --- | --- |
| `src/analysis/tran/envelope.zig` | Read in full; unchanged. Quasi-static stepping, rollback, extraction reductions, and public helpers retained. |
| `src/analysis/tran/matex.zig` | Read in full; removed an unused import and unreferenced private dense-assembly function; removed Arnoldi's duplicate dimension argument; reused the shared row-copy kernel, the waveform data leaf, and `std.ArrayList`; replaced an empty error-union success branch with `catch`. |
| `src/analysis/tran/tran_noise.zig` | Read in full; removed unused SIMD declarations. Seeded RNG, noise arithmetic, and allocation behavior retained. |
| `src/analysis/tran/tran.zig` | Read in full; replaced a manual slice swap with `std.mem.swap`. |
| `src/analysis/tran/types.zig` | Read in full; removed an unused SIMD-width declaration. Public types, fields, methods, capacity policy, and probe-major storage retained. |

A concurrent edit changed `tran.zig`'s accepted-step reread from `Circuit.eval` to `Circuit.evalQ` while this review was underway. That edit was preserved and is not part of this cleanup's claimed changes. The findings below account for the current call. Its changed non-charge plane postconditions and callback visibility still need the centralized review.

Reuse checks covered the repository, including private arithmetic in `solvers/gmres.zig`, `analysis/pss/pss.zig`, and `analysis/sweep/sens.zig`. Those helpers are not an accessible, interchangeable public primitive: length policies and reduction order or fallback vector widths differ. A future common solver-leaf helper could remove duplication after preserving those contracts; this pass adds no public API. `solvers.types.wfRms` integrates over time, whereas `envelope.extractRMS` averages samples, so it is not a replacement. `std.Random.DefaultPrng` would change the transient-noise sequence. Public helpers and forwarding APIs remain even when current callers are sparse.

## Vectorize MATEX multiplication across output columns

- **Where**: `src/analysis/tran/matex.zig:205-213`, `denseMatMul`; `src/analysis/tran/matex.zig:81-202`, `expmSmall`.
- **Now**: The `i,j,k` loop reads `B[k*m+j]` with an `m`-element stride and maintains one scalar dependency chain per output. Every exponential invokes four multiplications for the Padé construction plus one per squaring. At larger Krylov dimensions, strided reads and serialized multiply-adds can dominate the small-matrix work.
- **Change**: Process a vector of adjacent `j` columns per row. Broadcast `A[i*m+k]`, load adjacent elements of row `B[k*m..]`, and advance `k` in the original order for each output lane. Use a `W == 1` instantiation as the oracle and preserve the scalar tail. Keep this private to MATEX unless another owner needs the same contract.
- **Why it is faster**: Each B load supplies adjacent useful elements, and independent output columns provide SIMD lanes without parallelizing the floating-point reduction.
- **Est. payoff**: A several-fold kernel improvement is a hypothesis for dimensions with many full vectors, needs measurement. The fraction spent in dense multiplication versus sparse solves is unknown, needs profiling; small Krylov dimensions may see little benefit.
- **Risk**: Do not reassociate `k`, change Padé coefficients or scaling, or introduce FMA contraction. Matrix aliasing, odd dimensions, singular fallback, and all existing numerical cases require differential verification and an assembly check. This is a future kernel change, not part of the cleanup.
- **CPU / GPU / both**: CPU. These matrix multiplies currently execute on the host.

## Finish charge-only rereads on threaded and GPU paths

- **Where**: `src/analysis/tran/tran.zig:749-767`, `simulateInto`; `src/analysis/tran/tran_noise.zig:229-232`, `simulate`.
- **Now**: `tran` and noise both still call full `Circuit.eval`. (An `evalQ` swap was applied during this pass and then reverted: `Circuit.evalQ` exists only in a concurrently-edited `Circuit.zig`, not in HEAD, and per the Risk note below the stale-G/C/RHS contract is unresolved. It stays a proposal.) These sites consume charges after convergence while the full path also recomputes G, C, and the resistive residual. The live GPU route is `Circuit.eval` → `GpuHook.eval_planes` → `gpu_context.evalOnGpu`: upload x, stamp device batches, download G/RHS/C/Q, synchronize, and merge host planes. The installed hook leaves `simulate_tran` null.
- **Change**: Extend the existing shared charge-evaluation mechanism to ParEval with its original lane reduction order and to GPU evaluation using the common device engine. For accepted-step rereads, transfer the required Q output rather than all four planes. Evaluate whether noise can reuse `evalQ` after establishing its observable plane and state postconditions. Keep the existing full-eval fallback.
- **Why it is faster**: It removes discarded derivative/residual computations and, on GPU, unnecessary plane initialization, downloads, and merges. It does not attempt to run dependent timesteps in parallel.
- **Est. payoff**: Unknown, needs profiling. The opportunity is one reread per accepted charged-noise step, and one per accepted stateful-charge `tran` step; savings depend on the ratio of those calls to Newton evaluations and on derivative and transfer costs.
- **Risk**: Preserve the converged-point reread itself, charge accumulation order, state-latch behavior, and both current/history corrections. `simulateInto` callbacks and callers can observe Circuit planes, so retaining stale G/C/RHS is a contract issue to resolve, not an automatic safe substitution. GPU implementations must keep frozen scatter tapes, Model/Instance layouts, CSC, and plane ABI unchanged. This requires work outside the owned files in a later coordinated change.
- **CPU / GPU / both**: Both, through the existing device-evaluation path.

## Reuse MATEX endpoint source work

- **Where**: `src/analysis/tran/matex.zig:499-507`, `evalSourceRhs`; `src/analysis/tran/matex.zig:717-748`, `run`.
- **Now**: Every step evaluates source RHS at both t and t+h using a full `Circuit.eval` at x=0. It also computes both endpoint inverse actions with `approxAinvMul`. The previous accepted endpoint is the next step's starting endpoint, so a repeat endpoint evaluation and sparse matvec/solve occur across adjacent steps.
- **Change**: For a verified linear, immutable, side-effect-free source configuration, carry `b_th` into the next `b_t` and `ainv_bth` into `ainv_bt` using buffer swaps. Evaluate and solve only the new endpoint. Handle the singular-H Euler acceptance path too, and invalidate when time, source configuration, or device state makes reuse invalid. Keep the existing path for unsupported configurations.
- **Why it is faster**: It avoids one of the two endpoint evaluations and one of the four inverse-action calls per subsequent normal step. When evaluation reaches `eval_planes`, it also avoids that repeated GPU stamp and transfer cycle.
- **Est. payoff**: The eligible endpoint subset could approach half its current work; total time saved is unknown, needs profiling. The two additional inverse actions for the source slope and all Arnoldi work remain.
- **Risk**: MATEX's module description is not a runtime proof of source purity. Eval may update internal state, diagnostics, or planes; discontinuity-side conventions matter. Reuse must preserve those effects and all inverse-action numerics. This is not a semantics-preserving cleanup without that proof.
- **CPU / GPU / both**: Both for endpoint evaluation; sparse inverse actions remain CPU work.

## Give Arnoldi posterior checks their own adequate scratch

- **Where**: `src/analysis/tran/matex.zig:302-362`, `arnoldi`; `src/analysis/tran/matex.zig:376-411`, `posteriorOk`; `src/analysis/tran/matex.zig:629-651`, `run` workspace allocation.
- **Now**: `arnoldi` passes its n-element `tmp1` into `posteriorOk`, which returns false unless it has at least `7*m*m` elements. The first scheduled check, m=5, needs 175 elements. For n below the requirement at a checked dimension, the posterior cannot terminate Arnoldi, potentially causing extra sparse solves and Gram-Schmidt passes. A separate exponential scratch allocation already exists in `run`.
- **Change**: In a separate correctness/performance change, pass the existing exponential workspace into `arnoldi` for posterior checks; its lifetime does not overlap the later step exponential. Keep the size guard and the current posterior formula initially. Validate workspace bounds before tuning convergence behavior.
- **Why it is faster**: A posterior test that can actually run may terminate the basis construction earlier, reducing O(n*m²) orthogonalization and subsequent small-matrix work.
- **Est. payoff**: Unknown, needs profiling of attained dimensions and skipped checks. It can matter substantially when the size gate, rather than the posterior or lucky breakdown, prevents early termination. It may also add costly exponentials without reducing m.
- **Risk**: Enabling previously skipped checks can change m and numerical results, so it is explicitly outside this cleanup. There are adjacent bounds issues to resolve first: the final non-breakdown iteration writes `H[(j+1)*m_max+j]` beyond an allocation of `m_max*m_max`; pivots are capped by `[256]u32`; later inverse solves use `arnoldi_tmp1[0..m]` despite its n-element allocation. Define and validate the supported dimension range and retain every existing guard.
- **CPU / GPU / both**: CPU.

## Tile waveform conversion while preserving probe-major storage

- **Where**: `src/analysis/tran/tran.zig:823-831`, `run`; `src/analysis/tran/matex.zig:886-894`, `run`; `src/analysis/tran/types.zig:52-101`, `Waveform` and its accessors.
- **Now**: Both result builders convert probe-major values to point-major rows with points outermost. For each point, consecutive probe loads are separated by `capacity*sizeof(f64)`. With many probes, source lines and translations can be evicted before the next point reuses them. The two conversion loops duplicate the same traversal.
- **Change**: In both result builders, tile the point/probe ranges, for example starting with 32×32 tiles for measurement. Within a tile, copy consecutive points from one `probeValues(k)` slice into their final row positions. Keep time values in column zero and preserve `Waveform`'s public probe-major buffer; if a shared formatter is introduced later, put it at an acyclic shared layer without changing the frozen waveform interface.
- **Why it is faster**: Tiling bounds the active source/destination working set and reuses cache lines while copying bit-identical values. Keeping the existing storage also preserves contiguous access for Fourier and measurement consumers.
- **Est. payoff**: Potentially a few-fold improvement on conversion with many probes, needs measurement; little expected with one or two probes. Conversion's share of total runtime is unknown, needs profiling, and may be small beside Newton solves.
- **Risk**: Preserve row ordering, exact bits, partial tiles, zero probes, and allocation cleanup. Changing the underlying waveform to point-major would break its public layout contract and is not proposed.
- **CPU / GPU / both**: CPU. `recordValues` has no live repository caller here, so its comment is not evidence of a running GPU drain.

## Remove the envelope's redundant inner snapshot after validating rollback

- **Where**: `src/analysis/tran/envelope.zig:120-129`, scratch allocation; `src/analysis/tran/envelope.zig:153-224`, `simulate` fine-step and rollback loops.
- **Now**: Each fine Newton attempt copies the entire x vector to `x_save`. On failure, x is restored from that snapshot, then restored again from `x_outer_save` before retrying the outer step. No successful step reads `x_save`. This adds an n-element read/write pass for each fine attempt and another n-element scratch buffer.
- **Change**: After confirming rollback observers and alias contracts, remove the inner snapshot and intermediate restoration. Retain the outer snapshot and its failure restoration, period-halving behavior, and all convergence checks. Repack the scratch block only in that follow-up change.
- **Why it is faster**: It removes one full-vector copy per fine attempt and reduces scratch storage by `n*sizeof(f64)`; the outer retry behavior can still restore the original state.
- **Est. payoff**: Unknown, needs profiling. Most relevant when n is large and quasi-static Newton is cheap; expensive device evaluations and factorization may make this copy a small fraction.
- **Risk**: Verify that no observer needs the intermediate restored state and that caller buffers and custom allocations satisfy the required non-aliasing contract. Shrinking scratch changes allocator-visible behavior and possible allocation failures, so the strict cleanup retains it. Circuit/device rollback is not redesigned here.
- **CPU / GPU / both**: CPU copying, even when the Newton evaluation underneath uses GPU stamping.

## Separate noise sampling fields from injection fields

- **Where**: `src/analysis/tran/tran_noise.zig:106-123`, `NoiseHook.assemble`; `src/analysis/tran/tran_noise.zig:193-201`, `simulate` sampling loop.
- **Now**: Sampling reads `conductance` from each shared `NoiseSource`, while every Newton assembly reads only `node_p`/`node_n`. The shared struct also holds kind, current, kf, and af, which these loops do not use. Both passes stride over irrelevant fields, and sampling repeats the temperature/conductance prefix of the thermal scaling expression each attempt.
- **Change**: Build a simulation-lifetime private SoA with `node_p: []u32`, `node_n: []u32`, and one `[]f64` thermal-prefix column in original source order. Compute the exact existing left-associated prefix `4.0*k_boltzmann*temp_k*conductance` once, then retain `sqrt(prefix*bandwidth)` and the current scalar `rng.randn()` sequence. Keep the shared public `NoiseSource` unchanged; preserve the source-loop length as `usize` because no u32 source-count limit is established.
- **Why it is faster**: Injection streams only endpoints, sampling streams only coefficients, and invariant multiplication is removed from repeated steps. This targets cache traffic and redundant computation without changing random draws.
- **Est. payoff**: Likely modest unless source tables exceed cache or noise injection is a significant fraction of Newton assembly; unknown, needs profiling. Box-Muller logarithm, square root, and cosine still execute, so shrinking the table does not imply a large sampling speedup.
- **Risk**: The source data and temperature must remain immutable over the simulation. Preserve the original multiplication grouping, ground guards, source order, and per-source add-then-subtract ordering; aggregating currents per row or splitting positive/negative passes can change floating-point accumulation. Added allocation and snapshot semantics make this a proposal only.
- **CPU / GPU / both**: CPU. Noise sampling and residual injection are host loops even with device evaluation enabled.

## Reduce transient-noise recorder over-allocation

- **Where**: `src/analysis/tran/tran_noise.zig:174-184`, `simulate`; `src/analysis/tran/tran_noise.zig:89-97`, `Recorder.record`; `src/analysis/tran/tran_noise.zig:269-275`, `run` result shrink.
- **Now**: Initial capacity is `16*t_stop/dt_init`, clamped to the existing limits, even though accepted dt can grow by 1.5 until `dt_max`. With many probes this reserves a large point-major block and may force allocator work or copying when the final result shrinks. Allocation is outside the timestep loop; the per-record cost appears only on growth.
- **Change**: Measure capacity utilization on existing noise fixtures, then choose a noise-specific initial estimate reflecting the actual step-growth policy while retaining doubling and all timestep limits. Do not directly substitute `tran.initialCapacity`: its factor, minimum, and adaptive-controller assumptions differ.
- **Why it is faster**: Less reserved storage and less allocator pressure can reduce memory cost; avoiding unnecessary realloc movement helps when the allocator cannot shrink in place. Untouched reserved pages alone do not prove cache or page-fault savings.
- **Est. payoff**: Potentially a large reduction in reserved waveform storage; runtime effect unknown, needs profiling and allocator measurement. Mostly relevant to long traces with many probes, not the Newton kernel.
- **Risk**: The full `SimResult.rows` allocation is public and its length is observable. Capacity changes also move allocation-failure points, so this belongs in a separate behavior change. No capacity constant was changed in this pass.
- **CPU / GPU / both**: CPU allocation and recording.

## Remove MATEX's unused vector allocation

- **Where**: `src/analysis/tran/matex.zig:653-663`, `run` temporary vectors.
- **Now**: `y_vec` allocates n f64 elements and is then only freed. Reconstruction writes directly into `x_new`. Repository-wide reference search found no consumer of this local buffer, so the allocation adds allocator work and reserved storage without contributing to the solve.
- **Change**: Remove the `y_vec` allocation and its matching defer in a follow-up that permits allocator-observable changes. No replacement buffer or struct is needed.
- **Why it is faster**: It removes one allocation/free pair and `n*sizeof(f64)` reserved bytes. Since the buffer is not touched, it does not represent n elements of per-step memory traffic.
- **Est. payoff**: Negligible steady-state kernel impact; setup and total runtime payoff unknown, needs profiling. The concrete benefit is reduced reserved memory.
- **Risk**: This changes which allocator calls and OutOfMemory paths occur. It is intentionally left in place under the strict requirement to preserve every function's observable behavior.
- **CPU / GPU / both**: CPU.

## Nothing to do

- `src/analysis/tran/envelope.zig`: clean for this semantics-preserving pass; extraction helpers have distinct contracts and their reduction order stays intact. The rollback-copy proposal above is deferred.
- `src/analysis/tran/types.zig`: clean after unused-width removal; its probe-major SoA, u32 counts, owned slices, and doubling fallback match current consumers. The conversion proposal concerns the consuming `run` functions, not a storage redesign.

All remaining owned files were reviewed and changed as listed above. No additional safe dead-code or public-API deletion was found. Branches guarding sparse zero-column skips, ground nodes, expensive solves, square-root/log domains, breakpoints, and convergence were retained. No new numerical or SIMD kernel was introduced.
