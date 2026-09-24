# VerA gaps blocking the native line models

The native transmission lines (`models/native/ltra_native.zig`,
`txl_native.zig`, `coupled_ltra.zig`) have Verilog-A transcriptions beside
them (`ltra.va`, `txl.va`, `coupled_ltra.va`). None of them is built yet. This
page lists what VerA (pinned at `297e97d`) has to gain first. Every item is
also labelled `VERA-GAP:` in the .va file, both in the header and at the
construct that needs it.

## Bug: a held integer can come out typed real

Minimal repro (`vera --emit-zig --allow=W0650 --expect-module=heldint`):

```verilog
`include "disciplines.vams"
module heldint(p, n);
    inout p, n;
    electrical p, n;
    integer k;
    real x;
    analog begin
        @(initial_step) begin
            x = 0.0;
            k = 0;
        end
        if (V(p, n) > 0.0)
            if (V(p, n) > 1.0)
                if (V(p, n) > 2.0)
                    k = 1;
        I(p, n) <+ x * V(p, n);
    end
endmodule
```

`k` is held because it is assigned under `@(initial_step)`. Its end-of-block
value is a join of joins, three `if`s deep.

Actual: the core returns `k` as `S`, and `updateState` stores that into an
`i64` field, so the device does not compile (`m.f1` is `R`, the field is
`i64`):

```zig
inline fn heldint__common__core(...) struct {
    f0: S,
    f1: S,          // k
    f2: S,
} {
    ...
            h[0] = S.con(@as(f64, @floatFromInt(hi[0])));
    ...
    return .{ .f0 = t5, .f1 = h[0], .f2 = t8 };
}
pub fn updateState(...) contract.UpdateResult {
    ...
    inst.heldint__held__k = m.f1;   // i64 <- S
```

Expected: what the same module emits with two `if`s instead of three:

```zig
    f1: i64,        // k
    ...
    return .{ .f0 = t5, .f1 = hi[0], .f2 = t8 };
    ...
    inst.heldint__held__k = m.f1;
```

Cause: `lib/ir/analysis.zig` types a `phi` from its first operand in a fixed
two sweeps over value order ("Two sweeps in value order settle every acyclic
chain"). A deeper chain of joins is created outer-first, so after two sweeps
the outer phi is still at its `.real` default. Codegen then takes the core
field's type from that value (`self.an.rv(h.final)`) but picks the store form
from the declared type (`h.ty == .integer` in `updateState`), and the two
disagree. The fix belongs in the refinement: iterate to a fixpoint, as
`buildDfree` below it already does.

Where it bites: `txl.va`'s `k`. It is a loop variable used both in the
`@(initial_step)` reset loops and in the history-compaction loop four
branches deep. `txl.va` avoids it by resetting with a separate variable `kz`,
so `k` is no longer held.

## Feature gaps, per model

| # | gap | ltra.va | txl.va | coupled_ltra.va | needed for |
|---|---|---|---|---|---|
| 1 | `erfc()` builtin (E0512 today) | yes | | | the RC-line h2 and h3' kernels, bit-matching libm `erfc` |
| 2 | memory-backed arrays with runtime indexing (VerA scalarizes arrays, `lib/ir/lower.zig declareVarDecl`) | yes | yes | yes | the accepted-point histories (5 x 8192 for LTRA, 5 x 2048 for TXL, 4N x 2048 for CPL). Today every `h[i]` is a select over every slot: ltra.va emits 96 MB of Zig, txl.va 25 MB, coupled_ltra.va (N = 2) 25 MB |
| 3 | growable per-instance history (no fixed array size) | yes | | | LTRA runs of any length. The .va keeps the native CAP = 8192 plus compaction as the same ceiling |
| 4 | a per-timepoint cache that survives Newton iterations and is dropped on rejection | yes | yes | yes | running the history walk and the convolution exponentials once per timepoint (native `cache_t`), not on every Newton iteration: O(1) per iteration instead of O(history) |
| 5 | re-arming a timer to an earlier time (§5.10.3.3) | yes | | | LTRA wavefront breakpoints. `updateState` only raises a timer's `__next` and parks a fired one-shot at inf, so only the first wavefront lands |
| 6 | held `analog initial` results (today only `@(...)`-assigned variables are held, `lib/ir/lower.zig scanHeld`) | yes | yes | yes | running setup once per sub-task: LTRA's Z0, delay and maxSafeStep bisection; the TXL Padé fit (Gauss, cubic roots, Newton polish); the CPL modal fit (Jacobi diagonalizations, degree-7 fits, 2N^3 + N^2 Padé fits). An `analog initial` result reads as `sel(is_analog_initial, value, 0)`, so today it is only right while the host leaves `is_analog_initial` set, and then the whole setup reruns on every evaluation |
| 7 | array slices as analog-function actuals (E0511, `lib/ir/lower.zig funcArrayIn`) | | | yes | passing one `[i][j]` sample or series vector to `matchfit`, `multp` and `approxmode` (9 call sites). VAMS-2023 §5 allows slices, and VerA already accepts them in plain assignments |
| 8 | held integers keep their integer type (the bug above) | | yes (worked around) | | the TXL shared loop variable `k` |
| 9 | generated code a host can compile in reasonable time (follows from 2) | | yes | likely | building txl.va at all: see below |

Blocking compilation today: 1 (ltra.va), 7 (coupled_ltra.va), and 9
(txl.va; 8 is worked around). The rest compile but cost speed or
correctness: 4 and 6 dominate run time, and 5 loses LTRA breakpoints.

## TXL build attempt (gap 9)

With the `kz` workaround and the eval.zig quota fix (ccab930), txl.va was
registered as `models/txl.va` in a scratch copy with the Y card routed to it,
and built with `zig build -Dgpu=false`:

- vera emits `txl.zig` in about 6 s: 26,186,163 bytes, 385,240 lines. The
  `Instance` struct has 10,306 fields, almost all of them the scalarized
  5 x 2048 history. The core returns a 10,276-field struct.
- Zig semantic analysis of the `dev_txl` host object (`-fno-emit-bin`) passes
  in 1.5 to 2.5 min.
- LLVM ReleaseFast for that object did not finish. It was killed after
  12 h 27 min wall and 12 h 16 min CPU on one thread, at about 0.6 GB RSS.
  The rest of the build had finished.

So no TXL deck has run on the .va, and `txl_native.zig` stays the Y-card
device. The cost comes from gap 2: every runtime-indexed history access is a
select or switch over 2048 scalar slots, and each one is inlined into a single
core function. Memory-backed arrays (one `[cap]f64` per history, indexed at
run time) would shrink the emitted Zig by orders of magnitude. Until then,
txl.va is not buildable in practice, whatever the source-level gaps.
