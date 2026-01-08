# Verilog-AMS LRM fixture corpus

Two suites, answering two different questions.

## `zig build conformance` — does it compile, and is it rejected correctly?

One directory per document in `modules/FastVAF/docs`, plus `combined/` for rules
that only become meaningful when features interact. Each directory's
`COVERAGE.md` maps its source document section by section to fixtures.

An `.expected-error.txt` holds the required diagnostic substrings for a source
that must NOT generate a device; a fixture without one must compile and produce
device Zig that parses. That is the whole claim — it says nothing about what the
generated device computes.

## `zig build exhaustive` — does it compute the right answer?

[`exhaustive/`](exhaustive/COVERAGE.md) is the semantic suite, and it is written
in Verilog-A rather than in Zig. Each fixture is a component AND its testbench:
it states its own expectations, prints them with `$strobe`, and declares the
operating points it wants to be driven over in `//!` header lines. The runner
compiles it with §9.4 display tasks enabled, generates a driver from those
lines, builds a native binary, runs it, and compares the transcript with the
committed `.expected.txt`.

```sh
zig build exhaustive              # check every transcript
zig build exhaustive -- 04_       # only the fixtures matching `04_`
zig build exhaustive -- --bless   # (re)write them, then READ the diff
```

A transcript is an oracle in a way a compiler snapshot is not. The deleted
`.expected.zig` files were FastVAF's own output fed back to it, so a wrong
answer was frozen as correct. Here the fixture carries the expectation:

```
tanh(0.5) got=0.46211715726000974 want=0.46211715726000974 ok=1
  res[a] = 1.187187e-4
    d res[a]/d x[a] = 4.589949e-3
```

`want` is hand-derived from the LRM or a reference implementation and written
into the `.va`; a reviewer checks it once without running anything. Blessing a
transcript means reading the `ok=` column, not trusting a diff.

The suite has already found six wrong answers no snapshot could have caught —
they are listed at the bottom of `exhaustive/COVERAGE.md`.

## Adding a test

Write Verilog-A. Nothing else:

```verilog
//! param g = 2m
//! bias V(n) = 0
//! sweep V(p) = 0, 0.5, 1
`include "check.vh"
module ex0NN_thing(p, n);
  inout p, n; electrical p, n;
  parameter real g = 1m;
  analog begin
    `CHECK("what this proves", g * V(p, n), 2e-3 * V(p, n), 1e-18);
    I(p, n) <+ g * V(p, n);
  end
endmodule
```

then `zig build exhaustive -- --bless 0NN`, read the transcript, commit it.
