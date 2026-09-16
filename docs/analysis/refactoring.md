# Analysis ownership and numerical work

Evaluation is in `src/analysis/eval.zig`. Imported as `device_eval` or the
runtime loader's `dyn` module, it supplies the shared evaluator. Compiled as a
per-model root, it exports either the host vtable or the GPU entry points.
Model PODs, scatter tapes, plane layout and the device ABI are unchanged.

`executor.zig` owns dispatch, signature validation, query numerical state and
its embedded worker controller. `session.zig` owns query publication, request
validation and output-schema validation. These replace separate forwarding
files. The numerical leaves still import `types.zig`, never the public root.

The controller is embedded in its pinned executor, eliminating a separate
allocation. Suppressed inner Newton checkpoints poll an atomic cancellation
flag without taking the scheduler mutex; published boundaries remain locked.
Frequency solvers retain their lane scratch across batch calls;
only a changed LU shape rebuilds the factor storage. GPU frequency hooks write
into the same caller-owned destination used by CPU fallback. A failed GPU call
is followed by a complete CPU overwrite of that batch.

## Data layout

1. Inputs are prepared circuit planes, model-generated PSDs and query requests;
   outputs are solver states and retained analysis results.
2. Numerical collections span devices, unknowns, sparse entries and frequencies.
   There is one execution controller per active query.
3. Circuit/tape indices remain u32. Array offsets and allocation lengths use
   usize. SIMD lane width follows the target's f64 width.
4. G/C and RHS/solution planes are contiguous; frequency scratch stores one
   vector per matrix entry. Control state is outside these streamed arrays.
5. Prepared topology lives with Problem. Scratch lives with its solver/query;
   published results live until Problem destruction.
6. Frequencies and independent queries are parallel axes. Newton iterations
   and transient timesteps remain sequential.

## Device noise

Devices still declare generators and compute `noisePsd`. Analysis measures
those sources through the circuit. `.noise v(node) dec N start stop` has no
input-source requirement. A legacy source token remains accepted syntactically
but has no numerical role. The request has no input branch or gain field.

The spectrum has `frequency` and `noise_density` columns (V^2/Hz). A separate
integrated result has one `noise_rms` column (V rms). Input/output-referred
columns and the input-gain solve are removed intentionally. Consumers of the
old column names must use this schema; there is no referred-noise fallback.

Every declared generator retains its position even at zero power, so periodic
sampling cannot shift a later generator into its slot. Periodic noise uses one
adjoint solve per sample and sideband to measure all generators. The existing
frozen-time approximation and independent-generator assumption remain;
transient noise still samples only the white component at operating-point PSD.

## Retired paths

Native TXL/LTRA/CPL registration and numerical history injection are removed.
Their model source files remain under `models/native/` for reference. O/Y cards
use the existing generated `lossy_tline.va`; P cards use `coupled_tlines.va`.
That model supports two conductors per port: other dimensions fail explicitly.
The limitations documented in those Verilog-A sources still apply; native
recursive-convolution behavior is no longer a fallback. Legacy history hook
slots remain in device_ir solely to preserve the frozen ABI.

The disabled OP-f64/transient-f32 experiment and its environment switch are
removed. CPU derivative width follows `jac_f32_host`; GPU derivative width
follows the model's `jac_f32` permission. Reduced derivative bases remain.
Reintroducing a phase-dependent width requires fresh numerical and benchmark
evidence rather than reactivating a dormant branch.

## Verification

All analysis tests and their fixtures live under `src/analysis/tests/`.
`root.zig` explicitly imports the 13 suites in its `test` block: circuit,
evaluation, executor, session, GPU policy, AC, transient, periodic, sweep,
Fourier, poles/zeros, solvers and integration. Related cases share a suite;
unrelated runtime implementations remain separate. Private test access is
compiled only when `builtin.is_test` is true.

`zig build test-analysis` runs the complete suite; `test-eval` and
`test-solvers` retain focused entry points. The analysis test module owns its
builder/limiter imports and generated-device object links. All 229 named tests
survived the move; the complete suite passes 235 checks, including registration
blocks. Worker tests use the production stack setting because the combined
test executable's thread-local storage exceeds their former 1 MiB override.

`Circuit.combinePlanes(W)` uses W=1 for its oracle and tail. Its differential
case is mirrored in the standalone `ref/SIMD-Strategies/verify.zig`, covering
vector boundaries and aliased output. Solver tests cover retained scratch with
changed RHS values and forward/adjoint calls. Device tests cover zero-power
source identity; Problem tests cover generated thermal noise without an input
source. No throughput claim is made by this refactor.

### Recorded checks (2026-09-16)

- `zig build` passed, including the per-model host/GPU export roots.
- Debug unit suites: analysis 103/103, evaluator 7/7, solvers 117/117,
  frontend preparation 11/11, Problem 20/21. The Problem failure is
  `output validation rejects an entire append before publishing IDs`:
  analysis emits `v(S_1_1)` while output validation expects `S(1,1)`.
  The new generated-device thermal-noise regression passed.
- ReleaseSafe direct solver tests passed 79/79. Standalone SIMD verification
  and the Circuit differential case passed; the ReleaseFast assembly contains
  `vmulpd` and `vaddpd` on ymm registers.
- The noise fixture runner against the completed executable selected 28 cases:
  5 passed, 23 failed. Fifteen still expect `Noise Spectral Density Curves`
  instead of the new device-noise schema; two require unsupported differential
  probes; five report periodic-noise value mismatches (sideband invariance and
  noise multipliers); one transient case lacks the requested time coverage.
  These fixture checks are not green. Their expectations were left untouched.

Concurrent frontend edits caused one initial compilation to report
`file contents changed during update`; the Debug preparation/Problem results
above are from the subsequent run. A duplicate optimized unit compilation was
stopped after these results were available. No benchmark was run.
