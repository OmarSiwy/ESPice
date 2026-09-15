# Zig 0.17 self-hosted x86_64 backend miscompiles

`-Doptimize=Debug` builds every module, the device host objects included,
with the self-hosted x86_64 backend (`use_llvm = optimize != .debug` in
build.zig). This page records its miscompiles that changed our results, with
the evidence and the workaround.

## Float `!=` read twice from clobbered flags (#25)

Zig 0.17.0 (`zigq version`), x86_64-linux, i9-14900HX (AVX2, no AVX-512).

`DualFor.sel` in src/device/eval.zig computed `const pick = c.v != 0.0;`,
then used `pick` twice: splatted into the `@select` mask for the derivative
lanes, and as `if (pick) a.v else b.v` for the value. The backend lowers the
compare to a lazy flags value whose condition is "nonzero or parity" (an
unordered compare is `!=`), and materialises it twice:

```
vucomisd (0.0),%xmm0
setne  %al
setp   %dl
or     %dl,%al              ; al = pick, correct: feeds the @splat
setne  0x198(%rsp)          ; pick's stack home, read from EFLAGS again,
setp   %dl                  ; but the flags now come from `or %dl,%al`
or     %dl,0x198(%rsp)
...
testb  $0x1,0x198(%rsp)     ; `if (pick)` reads the stack copy
```

At `c == 0` the `or` leaves `al = 0`, so ZF = 1 and PF = 1, and the stack
copy reads `0 | 1 = true`. The derivative lanes take the right operand and
the value takes the wrong one. In the Debug test binary of main at fddd78e5,
358 of the 380 `DualFor(...).sel` instantiations carry this sequence.

Every model branch that VerA lowers to `sel` returned the true arm at a
false condition. Three tests caught it:

- src/tests/espice.zig "an R reading v() is ngspice's B source": the
  B source's `abs(x)` is `sel(x < 0, -x, x)`, so `abs(0.5)` was -0.5;
- src/tests/analyses.zig "bsource: expressions of several probes": the
  operating point did not converge;
- src/tests/analyses.zig "BSIM4 tnoimod1 retains DC conduction": the
  operating point did not converge.

Minimal deck, through a Debug build of the CLI (expects -4.975e-4, gave
-5.025e-4):

```
rv
v1 a 0 0.5
r1 a 0 r={1k*(1+0.01*abs(v(a)))}
.op
.end
```

**Not illegal behaviour on our side.** The source is `c.v != 0.0` on a plain
f64, and the instrumented `sel` printed `c=0 pick=true`. LLVM Debug
(`-fllvm`) and ReleaseSafe compute it correctly.

**Standalone repro.** It needs `-fstrip`: with debug info the backend
writes the compare to memory once and the code is right. The device host
objects are built stripped even in Debug (`GPU.make` in build.zig sets
`strip = true`), which is why the device code hits it and an unstripped unit
test does not.

```zig
const std = @import("std");

fn pickOf(c: f64, a: @Vector(8, f64), b: @Vector(8, f64), x: f64, y: f64) f64 {
    const pick = c != 0.0;
    const d = @select(f64, @as(@Vector(8, bool), @splat(pick)), a, b);
    std.mem.doNotOptimizeAway(d);
    return if (pick) x else y;
}

test "c == 0 picks y" {
    var c: f64 = 0.0;
    std.mem.doNotOptimizeAway(&c);
    try std.testing.expectEqual(@as(f64, 2), pickOf(c, @splat(1), @splat(2), 1, 2));
}
```

| Command (Zig 0.17.0, x86_64-linux) | Result |
| --- | --- |
| `zig test -fno-llvm -fstrip r.zig` | fails: returns 1 |
| `zig test -fno-llvm r.zig` | passes |
| `zig test -fllvm r.zig` | passes |
| `zig test -fllvm -fstrip r.zig` | passes |

With the same `sel` shape over `struct { v: f64, d: @Vector(w, f64) }`,
widths 7, 8 and 16 fail under `-fstrip` and widths 1, 2 and 4 pass.

**Workaround** (eval.zig `DualFor.sel`): `pick` comes from the bits,
`@as(u64, @bitCast(c.v)) << 1 != 0`. That is an integer compare with a
single-flag condition, and it gives the same answer as `c.v != 0.0` for
every input: ±0 is false, NaN and everything else true. LLVM's results do
not change. src/device/tests/eval.zig pins the bit trick to the float
compare, ±0 and NaN included. That unit test is not stripped, so it cannot
trigger the miscompile; the three tests above do.

Remove the workaround when a Zig release fixes the flags reuse. To check,
revert the line and run `zigq build test-espice -Dgpu=false -Doptimize=Debug`.
