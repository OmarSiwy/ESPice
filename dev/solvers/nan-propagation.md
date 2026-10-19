# NaN and Inf propagation

How a non-finite value travels through ESPice's numerics, and where it is caught.
A NaN that reads as "converged" or "small" is a wrong answer that looks right, so
every gate either refuses a non-finite input or lets it reach a check that does.
Compiled from the 2026-10-19 cleanup pass (seam-nan and the solver, device,
transient and periodic unit reports).

## Policy

- **Comparisons are written so NaN fails them.** Use `!(a <= b)` for "a exceeds b":
  any NaN makes it true, at no extra cost. Never use `a > b`, which a NaN makes false.
- **Norms propagate NaN.** `core.numerics.normInf` is an `i64` max over the sign-cleared bit
  pattern: exact, and a NaN's pattern sorts above Inf. A mix of +Inf and −Inf gives Inf, not NaN.
  There is one norm; the old NaN-skipping `normInf` and its duplicates (`pss.residualNorm`,
  `direct.maxAbs`) are gone.
- **Float `@max`/`@min` drop NaN** (`@max(0, NaN) == 0`), in strict mode too. Never build a
  norm or a convergence quantity on them.
- **Sums propagate NaN.** `core.numerics.dot` and `sum` are strict IEEE (16 independent
  accumulators, fixed pairwise combine, never fast-math), so a NaN entry always reaches the
  result. `dense_lu`, `bbd`, `lm`'s residual sum of squares, and `mhb.zig`'s
  `isNan(num.sum(r))` gate depend on that.
- **Fast-math only behind a gate in the strict caller.** Inside `@setFloatMode(.optimized)` a
  `v != v` test is deleted. Gate the result (`std.math.isFinite`, falling back to the strict
  loop) or the input (an integer bit-pattern scan); see the simd-loops skill. Current user:
  `acmatch.sensitivity`'s fused four-dot pass, which falls back to the strict dots when its
  result is not finite. The device evaluators (`evalRange`, `evalQRange`, `QTapeKernel`) are
  strict on purpose: a NaN residual must reach the LU's finiteness check unaltered.

## Where a non-finite value is caught

| Site | Behaviour |
|---|---|
| Newton gates, `converger.plausible` / `residualGate` | `!(a <= b)` refuses NaN; test "a NaN residual never converges" |
| `converger` ~185 / ~202 `normInf` | feed only the `newton_debug`/`opdbg` traces, where printing NaN is right |
| `converger.plausibleLimit` (~294) | a NaN start is bounded by `|F|·g`; harmless, because `plausible` refuses a NaN iterate |
| `converger.updateAndNorm` | maps non-finite rows to inf before its max |
| `dense_lu` | one predicate, `badPivot(p) = !(|p| >= eps² and |p| <= floatMax)`, at all three pivot sites. Strict elimination carries any NaN/Inf input into a later pivot, so every such matrix fails. The singular threshold at exactly eps² is unchanged |
| `sparse_lu` full factor | scans its input once with `normInf` before the column loop (+0.4–1%, within noise; a per-column check cost 10%) |
| `direct.maxMultiplier` | a NaN in L used to read as a safe 0.25 and skip the probe; it is now NaN, the probe runs and fails, and the full factor refuses the matrix |
| `direct.probeOne` (BBD refinement probe) | uses the NaN-propagating norm; before, a NaN solve could pass and the BBD factor was kept |
| `bbd` growth estimate (~292/315/317) | may be NaN, but a NaN block or Schur entry fails `dense_lu.factorize` first |
| `direct.refine` backward error | a NaN only stops refinement early |
| `gmres` `d_max` | a NaN diagonal fails `|diag| <= floor`, is divided through, and the solve never reports converged |
| transient LTE bound (`integrator.minDel`) | float `@min` used to drop NaN, so a step with a non-finite charge was accepted while dt grew. A running poison sum (`x - x` over every input, plus any 0/0) now forces NaN; tran retries a NaN bound like a Newton failure (revert, BE, dt/8) and skips order promotion on it |
| `tran_noise` `onoise` | `@sqrt(@max(v, 0))` turned a NaN variance into 0; now `if (v < 0) 0 else v` |
| `matex` (~69) | a NaN H now hits the existing `!isFinite` refusal instead of running expm on NaN |
| PSS shooting / HB / multi-tone HB residual | `normInf` (NaN-propagating), not the old NaN-blind norm, which let a NaN residual next to small finite entries count as converged |
| `mhb` (~739) | `isNan(num.sum(r))` gate, valid because `sum` is strict |
| `core.eigen` (~108) | unchanged: a NaN matrix gives NaN eigenvalues either way, and `@max(tol*diag, NaN)` only drops the floor |

## Known NaN-blind spots left on purpose

| Site | Why it is safe |
|---|---|
| device `snapLimited` (eval.zig ~974) | a NaN only shrinks the snap tolerance, so the snap never fires; the solver still sees the NaN |
| device pulse/pwl `@max`/`@min` | they act on source parameters, not on convergence quantities |
| `measure.zig` `sci` | non-finite values print through the old `render` path (inf/nan) |
| a NaN charge at the operating point | the first step skips the LTE check, as ngspice does; every later step rejects until dt underflows and the run fails with `TimestepTooSmall` (loud, not silent) |
| `acmatch` with \|y\| = 0 | NaN magnitude and phase spreads (0/0), as before the pass; not yet decided |

## Open holes

- **Refactor replay:** a refactor checks only its pivots, so a NaN that first appears in a U
  entry reaches the solve, hidden where that column's solution is exactly 0. Scanning U after
  every replay cost 0.4–3.6%. The fix in progress folds a branchless non-finite flag into each
  refactor kernel's U store (`SparseLu.refactorColumns`/`refactorTape`, `lu_kernels.zig`,
  `LaneLu.refactor`).
- **Overflow inside the full sparse factor** (finite inputs, an Inf mid-elimination) is caught
  only where it reaches a pivot; same store-side flag.

## Tests

- `numerics` "normInf equals a naive NaN-propagating max…" (lengths 0..200, offsets, NaN/−NaN/−Inf/−0/subnormal planted)
- `dense_lu` "a NaN or inf entry anywhere fails the factor, blocked and unblocked"
- `solver/tests` "a NaN or inf value off the diagonal fails the full factor"
- `direct` "maxMultiplier is NaN when an L entry is NaN"
- the transient `stepBound` non-finite table (BE, trap, Gear-2)
- `converger` "a NaN residual never converges"

The first four failed on the pre-pass code.
