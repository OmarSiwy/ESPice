# PSS-family cleanup and performance review

All six owned files were read in full. No builds, tests, benchmarks, or profilers were run. The findings below are proposals, ranked by potential payoff on workloads that exercise each cost; this ordering needs profiling. Work-count and storage ratios are analytical, not measured speedups. Line references describe the files after this cleanup.

| File | Cleanup outcome |
|---|---|
| `src/analysis/pss/hb.zig` | Reused the shared zero-fill for the DC seed; removed an unused private import. |
| `src/analysis/pss/pac.zig` | Reused shared copy/zero helpers, including FFT fixture setup; removed the unused local vector width. |
| `src/analysis/pss/pnoise.zig` | Reviewed and unchanged; the nearby AC PSD helper has different DC behavior. |
| `src/analysis/pss/pss.zig` | Removed a redundant stack copy of the read-only LU RHS and used the existing f64 solver alias. |
| `src/analysis/pss/pxf.zig` | Reused the shared copy helper in initialization and FFT fixture setup; removed the unused local vector width. |
| `src/analysis/pss/qpss.zig` | Removed an overwritten zero-fill, an unread private context field, an unused private import, and a temporary used only to discard a result. |

Public APIs, numerical expressions, thresholds, convergence limits, and guards were preserved. The PAC/PXF input copies retain an explicit `x_init[0..n]` bound. QPSS assigns every `w_td[row*nf+s]` before reading it. PSS passes disjoint arena slices for the LU RHS and solution.

GPU reachability was checked against implementation, rather than the older module comments: `Circuit.eval` and `evalNewton` route through `GpuHook.eval_planes` to `gpu_context.zig`'s `evalOnGpu`, which launches device evaluation kernels and downloads planes. The current `GpuContext.hook` leaves `simulate_tran` and frequency-solve hooks unset. QPSS `matvec` uses previously sampled Jacobians and launches no device kernel. Dense spectral solves also remain on the CPU.

## Replace per-source PNoise solves with an adjoint solve

- **Where**: `src/analysis/pss/pnoise.zig:214-267`, `sweep`.
- **Now**: Each frequency, sideband, and time sample factors one `2*n` admittance matrix, then clears an RHS and runs `dense_lu.solveFactored` for every noise source. This repeats quadratic triangular-solve work and matrix reads to obtain only one output-node transfer.
- **Change**: Reuse the adjoint strategy already implemented in `src/analysis/ac/noise.zig`: after factorization, call the existing `dense_lu.solveFactoredT` with an output selector, then obtain each source transfer from its two terminal entries. Retain the sample-major `src_g`/`src_i`, source-wise accumulators, sideband folding, and final reduction order. Account for the complex output using the real-expanded transpose identity.
- **Why it is faster**: One adjoint triangular solve replaces `n_srcs` forward solves; each source then needs constant-size terminal arithmetic. LU factorization cost stays unchanged.
- **Est. payoff**: Approximately `n_srcs` times fewer triangular solves, potentially several-fold on the source-solve portion for many-source circuits. Total runtime share and speedup are unknown, needs profiling; cubic factorization may dominate instead.
- **Risk**: Transpose solves change floating-point operation order. Preserve ground handling and the existing RHS overwrite behavior if both terminals name the same non-ground node; naive terminal subtraction would change that case. Keep the current near-DC skip and flicker clamp. CPU-only change, no frozen GPU layout changes.
- **CPU / GPU / both**: CPU.

## Preserve sparsity through spectral matrix construction

- **Where**: `src/analysis/pss/hb.zig:72-113`, `solve` workspace; `src/analysis/pss/hb.zig:288-383`, spectral assembly/solve; `src/analysis/pss/pac.zig:91-160`, sampling/FFT, and `src/analysis/pss/pac.zig:182-245`, conversion solve; `src/analysis/pss/pxf.zig:84-147`, sampling/FFT, and `src/analysis/pss/pxf.zig:160-218`, conversion solve.
- **Now**: Circuit CSC planes expand to dense `n*n` samples, including structural zeros. PAC/PXF retain `N*n*n` complex coefficients per plane and factor a dense matrix of dimension `2*n*(2*H+1)` per frequency. HB allocates a dense `[n*(2*H+1)]²` Jacobian despite assembling only harmonic diagonals and DC-to-harmonic couplings. Dense storage drives cache misses and memory traffic; LU work grows cubically with the expanded dimension.
- **Change**: Capture samples by existing circuit CSC slot, transform only those slots, and construct a separate host spectral CSC pattern once. Use the existing direct sparse solver with symbolic reuse and numeric refactorization at each frequency/Newton step. For HB, encode exactly the currently retained DC/harmonic blocks; do not introduce omitted intermodulation terms. Preserve PXF's transposed assembly and all harmonic-bin guards.
- **Why it is faster**: Sampling/FFT storage scales with circuit `nnz` instead of `n²`; the solver processes the spectral pattern and its fill rather than every dense entry.
- **Est. payoff**: Sample storage/work can shrink by roughly `n²/nnz`. Multi-fold solve improvements are plausible for large sparse circuits with limited fill; small or highly filled systems may lose. These phases can dominate large spectral analyses, but their actual runtime share is unknown, needs profiling.
- **Risk**: Sparse ordering and pivot selection change numerical behavior. Structural zero omission can also affect non-finite arithmetic. Retain dense fallback and compare convergence, singular cases, and spectra before adoption. Keep the frozen circuit CSC and GPU scatter tapes unchanged; the expanded pattern must be separate host storage.
- **CPU / GPU / both**: CPU.

## Reuse a linearized period for shooting derivatives

- **Where**: `src/analysis/pss/pss.zig:189-262`, `integrateOnePeriod`; `src/analysis/pss/pss.zig:329-446`, `shootingMatvec` and `denseFdSolve`.
- **Now**: Every dense Jacobian column or GMRES directional derivative reintegrates a perturbed circuit for a full period. Each step repeats nonlinear device evaluations and Newton solves. This is a serialized dependency chain multiplied by the number of derivative directions.
- **Change**: Prototype a discrete tangent model of the existing fixed-step trapezoidal period map. Record the accepted per-step G/C and companion-state information once per shooting iterate. Differentiate the actual companion update, then propagate directions through cached step systems using reused factors. Begin with charge-bearing circuits without history; retain the finite-difference implementation as the oracle and fallback.
- **Why it is faster**: Derivative directions reuse one nonlinear trajectory and step linearizations, replacing repeated nonlinear period integrations with linear propagation. Timesteps and shooting iterations remain sequential.
- **Est. payoff**: Potentially several-fold on derivative construction when repeated Newton evaluations dominate. The dense path currently performs `n` perturbed periods per outer iteration; the Krylov count follows its matvec calls. Total share and attainable speedup are unknown, needs profiling.
- **Risk**: This is a numerical-method proposal, not a cleanup. The derivative must include initial charge history, accepted-state semantics, limiting, and any source/history dependence. An analytic derivative need not match the current finite-difference result or convergence path. GPU benefit comes from fewer calls through the existing device-evaluation kernel, not from a currently available whole-period GPU solver. Preserve the frozen device ABI.
- **CPU / GPU / both**: both.

## Factor QPSS transforms into their two grid dimensions

- **Where**: `src/analysis/pss/qpss.zig:232-340`, `buildBasis2D`, `idft2D`, and `dft2D`.
- **Now**: Both transforms perform direct sums over all `nf = nf1*nf2` mix products for every sample/node, costing `O(n*nf²)` each. The two full basis planes cost `2*nf²` doubles. IDFT additionally gathers basis elements with stride `nf`.
- **Change**: Apply separable complex transforms along the `nf1` and `nf2` axes with caller-owned intermediate slabs. Reuse `solvers.fft.bluestein` for the odd axis lengths, with reusable chirp/work buffers, or first compare separable direct transforms for small grids. Reorder signed harmonic bins explicitly, preserve the forward `1/nf` scaling, and take the same real projection in IDFT.
- **Why it is faster**: Separable direct transforms reduce work toward `O(n*nf*(nf1+nf2))`; FFT-based axes reduce it further for large grids. Axis-sized basis/chirp data also replaces the quadratic basis footprint.
- **Est. payoff**: At the default `11*11` grid, `nf/(nf1+nf2)` is about 5.5 as a direct-sum term-count ratio, not a runtime prediction; complex arithmetic and intermediate passes add cost. Transform runtime share within GMRES is unknown, needs profiling.
- **Risk**: Operation order, normalization, conjugate pairing, and signed-bin mapping are load-bearing. Existing tests intentionally expose the one-sided projection behavior. This requires differential validation against the current transforms. Coupled harmonics remain one system; they are not independent nonlinear solve lanes. No current GPU transform kernel is involved.
- **CPU / GPU / both**: CPU.

## Vectorize QPSS matrix products across contiguous samples

- **Where**: `src/analysis/pss/qpss.zig:464-474`, `matvec` time-domain G*v product.
- **Now**: The loop order is sample, row, column, while `g_td[(row*n+col)*nf+s]` and `v_td[col*nf+s]` store samples contiguously. Advancing columns jumps by `nf` doubles and creates a scalar accumulation chain. The actual product costs `O(n²*nf)` per GMRES matvec.
- **Change**: Iterate row, then a tile of samples, then columns. Keep a vector accumulator over the sample tile, load contiguous G and v sample vectors, and advance columns in the original order within each lane. Store the sample tile once. Use the same kernel at width one as the oracle and retain a tail path.
- **Why it is faster**: Adjacent samples share cache lines and execute independent multiply-add sequences without horizontal reductions. This uses the current element-major G layout rather than transposing a large buffer.
- **Est. payoff**: A few-fold on this product is plausible when sample count fills vectors; no measured estimate. The product's share of total QPSS time depends on `n` relative to `nf` and GMRES iterations, and is unknown, needs profiling.
- **Risk**: Preserve column order, separate multiply/add behavior, tails, and non-finite handling. Check assembly and a differential case before landing. The samples are independent within this fixed Jacobian product; the harmonic solve remains coupled. No frozen GPU layout is touched.
- **CPU / GPU / both**: CPU.

## Batch device evaluations for already-known orbit samples

- **Where**: `src/analysis/pss/hb.zig:181-197`, `solve` sample capture; `src/analysis/pss/qpss.zig:372-397`, `computeResidual`; `src/analysis/pss/pnoise.zig:146-171`, `sweep` sample capture.
- **Now**: Each known sample calls `ckt.eval` separately. With the current GPU context, each call stages/uploads x, launches device-type kernels, downloads G/RHS and possibly C/Q, then synchronizes. HB and QPSS repeat these host/device round-trips during nonlinear iterations; PNoise does them during orbit capture.
- **Change**: Add a shared batched plane-evaluation path for these fixed sample buffers, scheduling independent samples in bounded tiles. Reuse `devices/engine.zig` evaluation logic with separate output planes per sample, retain model/instance/scatter data on the device, and download a tile of required planes together. Capture C from exactly the same samples as today. Keep serial capture for devices whose evaluation has inter-sample state dependencies.
- **Why it is faster**: Batching amortizes kernel launch and synchronization latency over many samples and allows larger transfers. It avoids parallelizing the sequential Newton settling or shooting loops.
- **Est. payoff**: Several-fold on sample capture is plausible for many small samples dominated by launch latency; for large compute-bound devices the gain may be small. Capture's total runtime share is unknown, needs profiling. QPSS matvec itself contains no device evaluations, so this does not save launches per GMRES matvec.
- **Risk**: Separate mutable device state, preserve mixed CPU/GPU batch accumulation and CPU fallback, and verify the final observable circuit planes. Add scheduling around the shared kernel without changing Model/Instance PODs, scatter tapes, or existing plane layouts. This requires coordinated work beyond these six files.
- **CPU / GPU / both**: GPU.

## Make PAC and PXF time-series reads contiguous

- **Where**: `src/analysis/pss/pac.zig:104-160`, `analyze` capture and FFT; `src/analysis/pss/pxf.zig:97-147`, `analyze` capture and FFT.
- **Now**: Dense time samples are stored sample-major, but each element's FFT reads `mats[k*n*n+elem]`, striding by an entire matrix. This causes cache-line underuse and repeated cache misses once the sample slab grows. It happens twice, for G and C.
- **Change**: Tile-transpose the captured samples into element-major time series before the FFT stage, or capture tiles through a dense scratch matrix. Keep the existing full complex FFT, sample order, normalization multiplication, and coefficient scatter. If sparse sampling is adopted, use the same layout with CSC slot replacing dense element.
- **Why it is faster**: Each FFT receives a contiguous series; a tiled transpose makes the layout conversion a streaming pass instead of many strided gathers.
- **Est. payoff**: A few-fold on gathering is plausible beyond cache capacity; the extra transpose can lose on tiny circuits. FFT preparation's total runtime share is unknown, needs profiling, especially against settling and dense LU.
- **Risk**: Compare the extra memory/pass cost and retain precise sample-to-bin mapping. Replacing the full FFT with `fftReal` is a separate numerical change and was not done. Existing GPU plane layouts remain unchanged; this is a host-side staging layout.
- **CPU / GPU / both**: CPU.

## Share PAC and PXF preparation when both analyses run

- **Where**: `src/analysis/pss/pac.zig:68-160`, `analyze`; `src/analysis/pss/pxf.zig:65-147`, `analyze`.
- **Now**: Both implementations separately settle the same kind of frozen-time trajectory, capture G/C, and Fourier-transform it. Running PAC and PXF with matching settings recomputes this preparation. The signed harmonic-to-bin helper is duplicated too, but its scalar cost is minor.
- **Change**: Introduce a caller-owned prepared LPTV snapshot used by both analyses, containing G/C coefficients, dimensions, and the exact preparation settings. Make the existing public analysis entry points retain their current behavior; offer shared preparation only in a coordinated API change. A shared helper should live below both leaves in the dependency DAG. Do not replace these settling loops with `pss.solve`, which integrates a different map.
- **Why it is faster**: A paired analysis can reuse the same preparation once, eliminating repeated Newton evaluations, orbit capture, and FFT work. Sharing source text alone would not produce that runtime benefit.
- **Est. payoff**: Roughly half the preparation work for a matching PAC/PXF pair; no benefit for a single analysis. Preparation's share of the paired run is unknown, needs profiling.
- **Risk**: Snapshot reuse needs a precise validity contract covering models, temperature, source configuration, initial conditions, limiting/history state, and all preparation options. API additions are forbidden in this cleanup, so even the smaller cross-file helper extraction was deferred. Avoid aliases to mutable live circuit planes.
- **CPU / GPU / both**: both; preparation currently reaches GPU device evaluation when enabled.

## Borrow QPSS spectral views instead of copying four slabs

- **Where**: `src/analysis/pss/qpss.zig:457-498`, `matvec`; `src/analysis/pss/qpss.zig:578-619`, `solve` scratch allocation.
- **Now**: Each matvec copies v into `v_re`/`v_im`, transforms into `w_re`/`w_im`, then copies those slabs back to w. Four `n*nf` scratch planes consume memory and create extra bandwidth/cache traffic before charge terms are added.
- **Change**: Borrow const real/imaginary slices of v directly, and pass real/imaginary slices of w as the DFT destinations. Remove the four intermediate arena regions after auditing every callback call for aliasing. Current GMRES calls use separate input and output storage.
- **Why it is faster**: The transform and charge calculations can use the already matching stacked-real layout, eliminating four slab copies per matvec and `4*n*nf` doubles of scratch.
- **Est. payoff**: Likely a few percent on bandwidth-sensitive matvecs; small when the quadratic DFT/G*v work dominates. Actual share is unknown, needs profiling.
- **Risk**: An aliased v/w call would overwrite input needed by the charge calculation; the existing copies protect that case. A future callback change could invalidate the assumption. Arena sizing and slice offsets require careful validation, so this was left as a proposal.
- **CPU / GPU / both**: CPU.

## Store the identical QPSS preconditioner sample only once

- **Where**: `src/analysis/pss/qpss.zig:526-554`, `evalPrecondSamples`; `src/analysis/pss/qpss.zig:664-715`, `solve` preconditioner setup.
- **Now**: One evaluation at x=0 is copied into `nf` identical G and C sample planes, using `2*nf*nnz` doubles. `Preconditioner.init` then averages those identical samples in sample order. Replication costs allocation space and memory writes; averaging repeatedly reads the larger working set.
- **Change**: Own one copied G plane and one copied C plane, and point all existing sample descriptors at those stable snapshots. Keep `num_samples=nf` and the existing repeated-add-then-scale average exactly as implemented. Do not borrow live circuit planes that later residual evaluations overwrite.
- **Why it is faster**: Storage and replication work fall from `2*nf*nnz` to `2*nnz` doubles; repeated averaging reads can reuse the same cache lines.
- **Est. payoff**: An `nf`-fold reduction in sample storage, not an `nf`-fold solver speedup. This runs once per solve and is probably a small runtime share unless `nf*nnz` is large; unknown, needs profiling.
- **Risk**: Replacing the average with a single value or switching to `.dc_sample` changes rounding and is outside this cleanup. This storage proposal preserves the current approximate one-dimensional preconditioner and does not repair or change its mix-product mapping. Snapshot lifetimes must cover initialization.
- **CPU / GPU / both**: CPU; the one existing evaluation remains unchanged.

## Cache frequency-independent PNoise PSD terms

- **Where**: `src/analysis/pss/pnoise.zig:63-82`, `sourcePsd`; `src/analysis/pss/pnoise.zig:146-171`, sample collection; `src/analysis/pss/pnoise.zig:243-252`, PSD evaluation.
- **Now**: Every frequency and sideband recomputes thermal/shot products and, for flicker sources, `kf*pow(abs(current),af)` for the same sample/source current. The expensive power function is invariant across the sweep.
- **Change**: During sample preparation, store the completed white PSD or flicker numerator in a sample-major f64 plane. Keep kind metadata outside that hot plane. At sweep time, return the stored white PSD or divide the flicker numerator by the existing `max(abs(f_sb),1e-30)` floor. Preserve per-source accumulation order and the bounds-checked fallback to DC source values.
- **Why it is faster**: Flicker exponentiation happens once per sample/source, rather than once per frequency/sideband/sample/source. The guarded power function remains exclusive to flicker sources.
- **Est. payoff**: Power-call count can fall by roughly `n_freqs*(2*M+1)` when all sidebands are used. Overall gain is likely small before reducing linear-solve cost; PSD runtime share is unknown, needs profiling.
- **Risk**: Retain exact multiplication order, signed-current absolute values, floor behavior, and source ordering. The AC helper returns zero at nonpositive frequency instead of applying PNoise's absolute-frequency clamp, so it is not a semantics-preserving substitute. Extra storage must pay for itself.
- **CPU / GPU / both**: CPU.

## Nothing to do

- `src/analysis/pss/pnoise.zig`: no confidently safe cleanup identified; existing shared copy/zero, dense admittance, and LU helpers are already used. Its performance proposals above require separate validation.
- No file was found entirely free of potential performance work. HB, PAC, PSS, PXF, and QPSS were reviewed and changed as recorded above; PNoise was reviewed and left unchanged.
- Retain the existing charge/zero-frequency skips, harmonic-bin bounds, PSD domain clamp, pivot/convergence guards, and failure fallbacks. No branch was shown to be unpredictable, and no floating-point reduction was rewritten.
