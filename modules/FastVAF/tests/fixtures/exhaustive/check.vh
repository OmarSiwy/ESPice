// Shared self-check macros for the exhaustive testbenches. LRM §10.3 `define.
//
// A fixture states its OWN expectation and prints the comparison, so the golden
// transcript is readable rather than merely diffable:
//
//     `CHECK("tanh(0.5)", tanh(0.5), 0.46211715726000974, 1e-15);
//     -> tanh(0.5) got=0.46211715726 want=0.46211715726 ok=1
//
// The trailing `;` is the CALL SITE's, as it is for every Verilog macro: a
// `define expands to text, and §5.1 wants a statement terminator.
//
// `ok=1` is the assertion. A reviewer checks the WANT column against the LRM or
// a reference implementation once; after that a regression turns `ok=1` into
// `ok=0` and the runner fails on the diff.
//
// WHY THE VERDICT IS A NUMBER AND NOT A BRANCH. `if (ok) $strobe("PASS")` is the
// obvious shape and it does not work here: FastVAF hoists a module's display
// tasks into one straight-line unit, so a task under a conditional is dropped
// with W0851 (LRM §9.4.6 makes emission a property of the solve, which compiled
// device code has no way to consult). A comparison is an integer in Verilog-A
// (§4.2.5), so making the verdict an OPERAND keeps everything unconditional.

`ifndef FASTVAF_CHECK_VH
`define FASTVAF_CHECK_VH

// Absolute tolerance. Use for values near or at zero.
`define CHECK(NAME, GOT, WANT, TOL) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, WANT, (abs((GOT) - (WANT)) <= (TOL)))

// Relative tolerance, for values whose magnitude is the point (currents that
// span decades, exponentials). `1e-30` floors the denominator so a want of zero
// does not divide by it.
`define CHECKR(NAME, GOT, WANT, RTOL) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, WANT, \
          (abs((GOT) - (WANT)) <= (RTOL) * (abs(WANT) + 1e-30)))

// Exact equality. For integers and for reals the LRM defines to the last bit
// (§4.2.1.1 conversions, §4.3.1 floor/ceil/abs, a literal round-trip).
`define CHECKX(NAME, GOT, WANT) \
  $strobe("%s got=%g want=%g ok=%d", NAME, GOT, WANT, ((GOT) == (WANT)))

// Integer form of the same, so the transcript shows `12` and not `12.0000`.
`define CHECKI(NAME, GOT, WANT) \
  $strobe("%s got=%d want=%d ok=%d", NAME, GOT, WANT, ((GOT) == (WANT)))

`endif
