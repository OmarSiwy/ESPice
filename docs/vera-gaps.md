# VerA gaps for the native line models

The native transmission lines (`models/native/ltra_native.zig`,
`txl_native.zig`, `coupled_ltra.zig`) have Verilog-A transcriptions beside
them (`ltra.va`, `txl.va`, `coupled_ltra.va`). None of the three is built:
the O, Y and P cards still route to the native Zig devices. Each gap is
labelled `VERA-GAP:` in the .va file, in the header and at the construct that
needs it.

`build.zig.zon` pins VerA at `0cf8f5a5` (device ABI 6), which carries the
fixes marked below. Since `b56b06cb` it warns W0853 at every `$limit` it
declines (none left in `models/`) and reads `absdelay` through a 3-point
quadratic under `(* vera_interp = 2 *)`. The `VERA-GAP:` labels for the
fixed items can come out of the .va files; since none of the three is built,
nothing here checks that they now compile.

## Status

| # | Gap | ltra.va | txl.va | coupled_ltra.va | Status in VerA |
|---|---|---|---|---|---|
| 1 | `erfc()` | yes | | | Not a builtin, and will not become one (see below) |
| 2 | Memory-backed arrays with runtime indexing | yes | yes | yes | Landed. The history is copied to the stack for each evaluation; an in-place overlay is planned |
| 3 | Growable per-instance history | yes | | | No change reported. ltra.va keeps the native cap of 8192 plus compaction |
| 4 | Per-timepoint cache that survives Newton iterations and is dropped on rejection | yes | yes | yes | Open |
| 5 | Re-arming a timer to an earlier time (VAMS-2023 §5.10.3.3) | yes | | | Fixed |
| 6 | Held `analog initial` array results | yes | yes | yes | Open |
| 7 | Array slices as analog-function actuals | | | yes | Fixed in `a21c0b0c` |
| 8 | A held integer keeps its integer type through nested joins | | yes | | Fixed in `651a7118` |
| 9 | Generated code a host can compile in reasonable time | | yes | yes | Resolved by 2 |

## What each open item costs

**1, erfc.** VAMS-2023 lists its mathematical functions in Tables 4-14 and
4-15, and neither has `erf` or `erfc`, so VerA rejects the call. ltra.va
needs erfc for the RC-line h2 and h3' kernels. The fix is on our side:
define erfc as an analog function inside ltra.va. VerA's
`tests/fixtures/erfc.vh` is the reference implementation (series below
|x| = 1.5, continued fraction above). It is within 1.9e-13 relative of libm
on x in [-6, 6], but it does not match libm bit for bit, so the .va LTRA
cannot reproduce the native model's RC kernels exactly.

**3, growable history.** ltra.va fails the way the native model does once
a run outgrows 8192 accepted points after compaction.

**4, per-timepoint cache.** Without it, the history walk and the
convolution exponentials run on every Newton iteration instead of once per
timepoint: O(history) per iteration where the native `cache_t` makes it
O(1). This dominates run time for all three models.

**6, held `analog initial` results.** An `analog initial` result reads as
`sel(is_analog_initial, value, 0)`, so it is right only while the host keeps
`is_analog_initial` set, and then the whole setup reruns on every
evaluation: LTRA's Z0, delay and max-safe-step bisection, the TXL Padé fit,
and the CPL modal fit (Jacobi diagonalizations, degree-7 fits, 2N^3 + N^2
Padé fits).

## Build size

With memory-backed arrays, txl.va emits 325 KB of Zig in 0.16 s and
coupled_ltra.va emits 3.1 MB. Before them VerA scalarized every array, so
each `h[i]` became a select over every slot: txl.va emitted 26 MB (an
`Instance` with 10,306 fields), and LLVM ReleaseFast did not finish that
object after 12.5 hours on one thread. No TXL deck has run on the .va yet.

## Switching a card to the .va

Per model, once VerA is pinned with the fixes and the model builds:

1. Copy the .va from `models/native/` into `models/` and route the card to
   it (`addTxl`, `addCpl` and the O-card path in `src/frontend/builder.zig`).
2. Diff it against the native device on the tline decks
   (`tests/fixtures/tran/bench_tline_*`, `stress/vacask_ring`).
3. Delete the native `.zig` only when the .va matches.

The existing .va lines cover the native ones only in part: `tline.va` is
exact for LTRA's LC case, `lossy_tline.va` approximates RLC with a lumped
half-R, and nothing implements the TXL Padé method or the CPL modal fit.
