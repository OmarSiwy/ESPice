# The wasm playground: how espice.wasm is checked

`zig build wasm` builds espice.wasm (wasm32-wasi, simd128, single-threaded,
ReleaseSmall) for the docs playground. This page records how it was
verified against the native build, and what still differs (issue #8,
2026-10-18).

## The corpus comparison

`zig build wasm-compare` runs `tools/playground/compare.js`: every deck
under `tests/fixtures` through espice.wasm under node, through the same
`docs/javascripts/playground.js` the page uses, and through the native
`espice -b -r`. A value fails when it differs from the native one by more
than 1e-9 of its variable's peak magnitude in that plot, plus 1e-15
absolute.

Build the native side for baseline x86_64:

```
zig build wasm-compare -Dgpu=false -Dcpu=x86_64 -Dhip-arch=none -Dcuda-arch=none
```

`-Dcpu=x86_64` is load-bearing. `numerics.dot` and `sum` reassociate over
stdpp's lane count, which is 2 f64 lanes on SSE2 and on simd128 but 4 on
AVX2. Against an x86_64_v3 build, 20 decks differed past 1e-9 (long
transients, AC ladders, HB/QPSS near-zero harmonics); against baseline
x86_64, none of them do. `-Dhip-arch=none -Dcuda-arch=none` is there
because `-Dcpu` also reaches the HIP kernel object, where LLVM aborts on
the x86 CPU name.

Result on 2026-10-18 (main fddd78e5 plus #8):

| | decks |
|---|---|
| match to 1e-9 | 734 (55,498,829 values, max relative deviation 1.24e-15) |
| XFAIL | 1, `tran/bench_ngspice_mosamp.sp` (below) |
| skipped | 99 (the page refuses the deck, or native espice fails it too) |

Of the 734, 721 are bitwise identical. The other 13 are device-model decks
(b3soipd, b4soi, bsim2, jfet, mos1, mos3, mos6, vbic, vdmos) differing in
the last bits. libm is not the cause: exp, log, log10, exp2, sin, cos,
tanh, atan, `std.math.pow` and C `pow` return bitwise-identical results on
200,000 inputs each for wasm32-wasi and x86_64-linux-musl. The source is
still open.

`bench_ngspice_mosamp.sp` is the one deck where it matters: its operating
point differs by about 3e-15 relative, and gear step control turns that
into 100,613 transient points on wasm against 100,616 natively (glibc and
musl builds agree with each other). compare.js lists it in `KNOWN` and
reports it as XFAIL; if it ever matches, the run fails with XPASS.

Seven native plots have no counterpart in the C API, so neither the page
nor the comparison sees them: topology-changing `.alter` and `.step` runs
(`Problem.run_results`) and the MOSRA degradation table. compare.js counts
them separately instead of failing.

## Stack size

The page runs every query on the main wasm stack, where the native build
gives each worker a 512 MiB thread stack. Painting the stack before each
deck and scanning it after, the corpus peaks at 1,214 KiB
(`tran/bench_tline_cpl3_4_line.sp`), past wasm-ld's 1 MiB default; the
MOSFET decks sit at about 1 MiB. `wexe.stack_size` is 16 MiB.

## simd128

`numerics.dot` and `axpy` built for wasm32-wasi with `+simd128` at
ReleaseSmall emit `v128.load`, `f64x2.mul` (16) and `f64x2.add` (24): the
stdpp pipelines take the vector path.

## 32-bit and single-threaded code paths

`-Dsingle-threaded` builds the native host modules as espice.wasm builds
them (the corpus and benchmark runners stay threaded: they enforce
deadlines with threads). With `-Dtarget=x86-linux-musl -Dcpu=pentium4` it
also gives a 32-bit usize on SSE2 floats; the baseline x86 CPU computes
f64 on x87 and would fail the bitwise tests for that reason alone.

- `zig build test -Dgpu=false -Dsingle-threaded=true`: unit suites pass;
  corpus 830 passed, 0 failed, 4 xfail.
- 32-bit `test-core test-solver test-output test-grammar`: pass.
- 32-bit device, frontend and analysis suites do not compile: VerA's `sim`
  and diagnostics modules assume a 64-bit usize. That is VerA's to fix;
  espice.wasm links because it never references that code.
