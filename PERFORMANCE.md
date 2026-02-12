# ESPice performance findings

CPU and GPU performance improvements identified across the whole `src/` tree by an 18-way parallel Codex (gpt-6-astra) audit, September 2026. Each area was reviewed against the repo's data-oriented-design, branchless, and simd-first rules.

## How to read this

Findings were produced by reading the code, **not by running a profiler**.
No timing measurement backs any entry here. Every payoff estimate is a
work-count argument or an order-of-magnitude guess, and the reports say so
per finding. Treat this as a ranked list of *hypotheses to measure*, not a
list of known wins.

Per-area detail — mechanism, proposed change, risk, and payoff reasoning —
lives in `docs/perf/<area>.md`. This file is the index.

**80 findings across 9 areas; 13 touch the GPU path.**

The repo rule still applies: a performance claim ships with a
`zig build bench` before/after in the commit message. Nothing below has one.

---

## Devices (device kernels, LTRA/TXL native, ParEval)

Detail: [`docs/perf/arpice-devices.md`](docs/perf/arpice-devices.md)

- Share LTRA coefficient generation across identical history grids — `src/devices/ltra_native.zig:432-726` · CPU
- Separate native line caches from fixed history storage — `src/devices/ltra_native.zig:107-137` · CPU
- Reuse TXL exponentials for duplicated poles — `src/devices/txl_native.zig:299-302` · CPU
- Tile the ordered CPU lane reduction — `src/devices/engine.zig:2491-2531` · CPU
- Balance CPU partitions using device evaluation cost — `src/devices/engine.zig:2239-2273` · CPU
- Combine device state flags before the global atomic — `src/devices/engine.zig:2092-2171` · GPU
- Iterate only present CPL convolution entries — `src/devices/coupled_ltra.zig:906-1039` · CPU
- Add processor hints to ParEval's short spin waits — `src/devices/engine.zig:2405-2452` · CPU
- Check duplicate HDL registration before generating device text — `src/devices/loader.zig:82-109` · CPU

## Solvers — direct (sparse/dense/lane LU, ordering, BBD)

Detail: [`docs/perf/arpice-solvers-direct.md`](docs/perf/arpice-solvers-direct.md)

- Tile large dense factorizations — `src/solvers/dense_lu.zig:38-55` · CPU
- Replay fabricated pivots in frequency lanes — `src/solvers/lane_lu.zig:93-148` · CPU
- Batch the border right-hand sides of each block — `src/solvers/bbd.zig:320-331` · CPU
- Tile the serial Schur dot products — `src/solvers/bbd.zig:298-317` · CPU
- Cache exact row occupancy during full factorization — `src/solvers/sparse_lu.zig:184-196` · CPU
- Reuse Tarjan scratch for per-block AMD — `src/solvers/order.zig:83-173` · CPU
- Narrow validated BBD slab offsets after an API review — `src/solvers/bbd.zig:65-79` · CPU

## Solvers — iterative (GMRES, preconditioner, Newton, FFT)

Detail: [`docs/perf/arpice-solvers-iter.md`](docs/perf/arpice-solvers-iter.md)

- Reuse constant Jacobians in GPU Newton assembly — `src/solvers/converger.zig:178-219` · CPU+GPU
- Share sideband ordering and symbolic setup — `src/solvers/preconditioner.zig:117-137` · CPU
- Reuse FFT setup across equal-length transforms — `src/solvers/fft.zig:205-308` · CPU
- Hoist the unchanged Newton-vector norm out of Arnoldi — `src/solvers/newton_core.zig:218-236` · CPU
- Retain frequency-lane workspace across batch calls — `src/solvers/freq_solve.zig:237-319` · CPU
- Accumulate each GMRES solution block in registers — `src/solvers/gmres.zig:295-317` · CPU
- Compute the diagnostic residual norm only when requested — `src/solvers/converger.zig:200-233` · CPU
- Scan waveform extrema together — `src/solvers/types.zig:199-217` · CPU
- Build harness coordinate maps once — `src/solvers/dev_harness.zig:347-398` · CPU

## Transient analysis

Detail: [`docs/perf/arpice-tran.md`](docs/perf/arpice-tran.md)

- Vectorize MATEX multiplication across output columns — `src/analysis/tran/matex.zig:205-213` · CPU
- Finish charge-only rereads on threaded and GPU paths — `src/analysis/tran/tran.zig:749-767` · CPU+GPU
- Reuse MATEX endpoint source work — `src/analysis/tran/matex.zig:499-507` · CPU+GPU
- Give Arnoldi posterior checks their own adequate scratch — `src/analysis/tran/matex.zig:302-362` · CPU
- Tile waveform conversion while preserving probe-major storage — `src/analysis/tran/tran.zig:823-831` · CPU
- Remove the envelope's redundant inner snapshot after validating rollback — `src/analysis/tran/envelope.zig:120-129` · CPU
- Separate noise sampling fields from injection fields — `src/analysis/tran/tran_noise.zig:106-123` · CPU
- Reduce transient-noise recorder over-allocation — `src/analysis/tran/tran_noise.zig:174-184` · CPU
- Remove MATEX's unused vector allocation — `src/analysis/tran/matex.zig:653-663` · CPU

## Periodic steady state (PSS/HB/PAC/PNoise/PXF)

Detail: [`docs/perf/arpice-pss.md`](docs/perf/arpice-pss.md)

- Replace per-source PNoise solves with an adjoint solve — `src/analysis/pss/pnoise.zig:214-267` · CPU
- Preserve sparsity through spectral matrix construction — `src/analysis/pss/hb.zig:72-113` · CPU
- Reuse a linearized period for shooting derivatives — `src/analysis/pss/pss.zig:189-262` · CPU+GPU
- Factor QPSS transforms into their two grid dimensions — `src/analysis/pss/qpss.zig:232-340` · CPU
- Vectorize QPSS matrix products across contiguous samples — `src/analysis/pss/qpss.zig:464-474` · CPU
- Batch device evaluations for already-known orbit samples — `src/analysis/pss/hb.zig:181-197` · GPU
- Make PAC and PXF time-series reads contiguous — `src/analysis/pss/pac.zig:104-160` · CPU
- Share PAC and PXF preparation when both analyses run — `src/analysis/pss/pac.zig:68-160` · CPU+GPU
- Borrow QPSS spectral views instead of copying four slabs — `src/analysis/pss/qpss.zig:457-498` · CPU
- Store the identical QPSS preconditioner sample only once — `src/analysis/pss/qpss.zig:526-554` · CPU
- Cache frequency-independent PNoise PSD terms — `src/analysis/pss/pnoise.zig:63-82` · CPU

## Analysis core (Circuit, AC, DC, eigen, sweep, post)

Detail: [`docs/perf/arpice-analysis.md`](docs/perf/arpice-analysis.md)

- Store only retained distortion coefficients — `src/analysis/post/disto.zig:74-103` · CPU
- Keep port and stability systems sparse — `src/analysis/ac/sp.zig:114-155` · CPU
- Evaluate only residuals during parameter differencing — `src/analysis/sweep/sens.zig:137-183` · CPU+GPU
- Upload only parameter batches that changed — `src/analysis/Circuit.zig:643-681` · GPU
- Use the existing sparse solver for large transfer-function systems — `src/analysis/dc/tf.zig:35-69` · CPU
- Reuse constant stamps across source-only continuation steps — `src/analysis/dc/dc.zig:229-235` · CPU
- Batch the pole solver's right-hand sides — `src/analysis/eigen/pz.zig:61-84` · CPU
- Bound frequency-response workspace — `src/analysis/ac/ac.zig:60-75` · CPU
- Stream CPU sweep results into compact outputs — `src/analysis/sweep/lanes.zig:51-65` · CPU
- Precompute frequency-invariant noise terms — `src/analysis/ac/noise.zig:32-40` · CPU
- Fuse sensitivity differencing with its existing dot order — `src/analysis/sweep/sens.zig:57-75` · CPU
- Advance one interpolation cursor through Fourier samples — `src/analysis/post/four.zig:64-70` · CPU

## Frontend and output writers

Detail: [`docs/perf/arpice-frontend-out.md`](docs/perf/arpice-frontend-out.md)

- Cache parameter substitution within its defining scope — `src/frontend/parser.zig:1198-1285` · CPU
- Memoize expanded device counts by remaining depth — `src/frontend/parser.zig:108-143` · CPU
- Format independent output points in bounded batches — `src/output/ascii_raw.zig:30-45` · CPU
- Store expression nodes in indexed arena columns — `src/frontend/types.zig:176-198` · CPU
- Transpose selected CITIfile columns before repeated scans — `src/output/citifile.zig:29-51` · CPU
- Tune the stream buffer for many narrow rows — `src/output/rawfile.zig:59-85` · CPU
- Avoid copying the completed include expansion — `src/frontend/source.zig:10-24` · CPU
- Copy Spectre text between comments in bulk — `src/frontend/tokenizer.zig:389-406` · CPU
- Combine lowercase copying through the standard library if SIMD is retained — `src/frontend/parser.zig:6-20` · CPU

## Top level (builder, engine, GPU context, main)

Detail: [`docs/perf/arpice-toplevel.md`](docs/perf/arpice-toplevel.md)

- Group BBD nodes with stable buckets — `src/builder.zig:93-162` · CPU
- Index numeric card entries once — `src/builder.zig:2001-2043` · CPU
- Parallelize the CPU subset of GPU evaluations — `src/gpu_context.zig:562-581` · CPU+GPU
- Stream transient plots in multi-job decks — `src/main.zig:248-277` · CPU
- Transfer charge planes only when resident batches produce charge — `src/gpu_context.zig:422-445` · CPU+GPU
- Index model names before repeated device binding — `src/builder.zig:1868-1871` · CPU
- Build sensed-source membership once — `src/builder.zig:1150-1161` · CPU
- Replay the repeated GPU command chain — `src/gpu_context.zig:501-575` · CPU+GPU
- Queue state-control flags before the host walk — `src/gpu_context.zig:746-774` · CPU+GPU

## Test suite runtime

Detail: [`docs/perf/arpice-tests.md`](docs/perf/arpice-tests.md)

- Inject allocation failures one analysis at a time — `tests/leak.zig:258-295` · CPU
- Reserve node-label capacity for the large parallel fixtures — `tests/parallel.zig:55-66` · CPU
- Use byte comparison for equal determinism snapshots — `tests/parallel.zig:29-42` · CPU
- Keep the small fixed SP output buffers on the stack — `tests/analyses.zig:699-861` · CPU
- Format synthetic node names into their final storage — `tests/test_circuit.zig:119-139` · CPU
