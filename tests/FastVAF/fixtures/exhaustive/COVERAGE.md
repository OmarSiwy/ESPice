# Exhaustive coverage — the semantic suite

Every fixture here is a **Verilog-A testbench**: a module that states its own
expectations, prints them, and is driven over operating points its own `//!`
lines declare. Run it with

```sh
zig build exhaustive                # check every transcript
zig build exhaustive -- 04_         # only the fixtures matching `04_`
zig build exhaustive -- --bless     # (re)write them, then READ the diff
```

## What a fixture looks like

```verilog
//! param is = 1e-14
//! bias V(c) = 0
//! sweep V(a) = 0, 0.6
`include "check.vh"
module ex081_diode(a, c);
  inout a, c; electrical a, c;
  parameter real is = 1e-15 from (0:inf);
  real vt;
  analog begin
    vt = $vt;
    `CHECKR("$vt at 300.15 K", vt, 0.025864925786328753, 1e-15);
    I(a, c) <+ is * (limexp(V(a, c) / vt) - 1.0);
  end
endmodule
```

and its transcript is

```
$vt at 300.15 K got=0.025864925786328753 want=0.025864925786328753 ok=1
  res[a] = 1.187187e-4
    d res[a]/d x[a] = 4.589949e-3
```

Two independent claims per fixture, and neither is a snapshot of the compiler:

1. **The model's own checks.** `ok=1` is the assertion. The `want` column is
   derived from the LRM or from a reference implementation and written into the
   `.va` by hand, so a reviewer can verify it without running anything.
2. **The residual and the Jacobian**, which is what the solver actually sees.
   For a resistor it is Ohm's law; for the diode above it is `Is/Vt·e^(V/Vt)`.

`//! print none` drops the second when a fixture is about the language rather
than about a device.

## Directives (src/tb.zig)

| Line | Effect |
|---|---|
| `//! param name = v, …` | §3.4 parameter override; also sets `$param_given` |
| `//! bias V(node) = v` | hold an unknown fixed across the sweep |
| `//! sweep V(node) = a, b, …` | operating points; several lines take the cartesian product, last fastest |
| `//! temp K` | §9.10 `$temperature` |
| `//! time t, …` | §9.10 `$abstime`; `dt` from consecutive entries, and `updateState` runs after each |
| `//! wave V(node) = a, b, …` | one value per `//! time`; a short list holds its last |
| `//! analysis dc\|tran\|ac\|…` | §4.6.1 `analysis()` |
| `//! print none\|residual` | whether the harness adds the residual dump |

`V(a)`, `I(a)`, `x[a]` and a bare `a` all name the unknown `a`.

## Coverage

| Fixture | LRM | What it pins |
|---|---|---|
| `010_display_formats` | §9.4.2–9.4.4 | every conversion, width, precision, escape, `%m`, `$write`'s missing newline |
| `011_severity_tasks` | §9.7.3 | `$info`/`$warning`/`$error`/`$fatal` carry their level; `$finish`/`$stop` stay void |
| `012_directives` | src/tb.zig | every `//!` line is observable in the transcript |
| `020_real_arithmetic` | §4.1, §4.2.4 | precedence, associativity, `**` right-associativity, `%` sign rule |
| `021_integer_arithmetic` | §3.2, §4.2.4 | truncation toward zero, `%` sign, abs/min/max |
| `022_comparison_logic` | §4.2.5–4.2.7 | relational/equality/logical, all yielding integer 0/1 |
| `023_bitwise_shift` | §4.2.8–4.2.9 | and/or/xor/xnor/not, `<<`/`>>` incl. a negative operand |
| `024_conditional_operator` | §4.2.10 | both arms, nesting, a real condition |
| `025_type_conversions` | §4.2.1, §9.11 | real→int ROUNDS (both signs), `$rtoi` TRUNCATES, promotion |
| `040_exp_log_pow` | §4.3.1 | exp/ln/`log` is base 10/sqrt/pow/hypot |
| `041_rounding_selection` | §4.3.1 | floor/ceil/abs/min/max, exactly |
| `042_trigonometric` | §4.3.2 | sin/cos/tan/asin/acos/atan/atan2 across quadrants |
| `043_hyperbolic` | §4.3.2 | sinh/cosh/tanh and the three inverses |
| `044_limexp` | §4.5.13 | agrees with exp below the knee; value and slope continuous at x=80; finite above |
| `060_ddt_charge` | §4.5.3, §5.6.1.2 | `ddt` becomes `q()`; resistive residual is zero; dq/dV is the capacitance |
| `061_ddx_derivative` | §4.5.14 | symbolic partials, including w.r.t. the branch's other node |
| `062_idt_integral` | §4.5.4 | the accumulated integral equals `k*t` step for step, and the `ic` form offsets it |
| `063_transition` | §4.5.8 | the implemented first-order lag: 0, ½, ¾, ⅞, … exact in binary |
| `064_slew` | §4.5.9 | rate limiting at `rise*dt` per step, then holding at the input |
| `065_absdelay` | §4.5.7 | out(t) = in(t − td), with the startup clamped to 0 |
| `066_laplace_dc_gain` | §4.5.11 | DC gain is b0/a0 exactly; the step response is monotone and settles there |
| `067_zi_sample_hold` | §4.5.12 | piecewise-constant output on the filter's own T, not the solver's step |
| `068_idtmod` | §4.5.5 | the integral reduced modulo m, wrap included |
| `069_last_crossing_direction` | §4.5.10 | `+1` answers the RISING crossing only; a falling one leaves `t_last` alone |
| `070_event_hold` | §5.10 | a variable assigned under `@(cross(...))` keeps its value on every later step — `real` and `integer` |
| `080_resistor` | §5.6 | the contribution→KCL-stamp path, by Ohm's law |
| `081_diode` | §5.6, §4.5.13 | an exponential I-V and its conductance over decades |
| `082_voltage_source` | §5.6 | a potential contribution's extra unknown and its ±1 stamps |
| `083_controlled_sources` | §5.6 | a transconductance lands in an OFF-DIAGONAL Jacobian entry |
| `084_indirect_contribution` | §5.6.7 | the nullor row is the constraint alone |
| `085_conditional_contribution` | §5.8, §5.6.1.3 | accumulation as a phi; the sweep crosses the threshold |
| `086_named_branch` | §3.12 | a named branch is the same topology as its node pair |
| `087_internal_node` | §3.6.3 | an internal net is an unknown but not a terminal |
| `088_mfactor` | §9.18 | `$mfactor` reaches the model |
| `100_parameters` | §3.4, §9.19 | defaults, overrides, localparam, aliasparam, `$param_given` |
| `101_analog_function` | §4.7 | inlining is per-call: no state leaks between call sites |
| `102_loops` | §5.9 | `for`/`while` really iterate — including when the ONLY consumer is a display task |
| `103_case_statement` | §5.7 | matching arm, `default`, multi-label arms |
| `120_environment` | §9.10, §9.15 | `$temperature`, `$vt` (both forms), `$abstime`, `$simparam` defaults |
| `121_analysis_kind` | §4.6.1 | which spellings answer true; `"static"` covers dc |
| `122_bit_conversions` | §9.11 | `$rtoi`/`$itor`, the exact `$realtobits`/`$bitstoreal` round trip, `$clog2` |
| `123_math_system_names` | §9.14 | `$ln` … are the SAME functions as the bare spellings |

## Bugs this suite found

Each of these was a wrong answer no snapshot test could have caught, because the
snapshot would have frozen the wrong answer:

- **Loop-carried values were hoisted into the shared core** (`codegen.isCommon`).
  The common declaration ran the loop to completion and returned one snapshot;
  a unit that re-materialized the same loop then read its counter and exit
  condition from a cache already holding their FINAL values, so the loop ran
  zero times. `102_loops` printed `for sums 1..5 got=0 want=15`.
- **Integer literals were truncated to 32 bits** (`Ast.ExprStore.addInt`) while
  the MIR, codegen and the device contract all carry an `i64`. `4294967296`
  lowered to `0` and `2147483648` to a negative number. Found by `122`.
- **`$bitstoreal` was typed as an integer** in both `Lower.sysFuncTy` and
  `codegen.callTy`. §9.11 Table 9-8 makes it bits→REAL; the mistyping put an
  `S` expression in an `i64` slot, so any model calling it failed to compile.
  Found by `122`.
- **Display-task operands were not sliced** (`codegen.callArgIsValue`), so under
  `--display=emit` every operand rendered as an undefined leaf. Found by `022`.
- **A unit whose target is defined in only one arm returned `undefined`**
  (`codegen.emitUnitBody`). For `if (c) I <+ transition(x)` the operator's INPUT
  unit returned an undefined value on the not-taken path, and `updateState`
  pushed it straight into the operator's history — undefined behavior in a
  shipped device, on a pattern every compact model uses. Found while writing
  `065`.
- **Filter kernels leaked `pub` into device.zig** (`codegen.emitFile`). They are
  embedded from a real Zig file, so they arrived already public and
  `contract.rejectStrayPubDecls` rejected `zBilin` — meaning NO model using
  `laplace_*` or `zi_*` could pass `--check` or `--emit-so`. The cascade
  coefficient reader `…__sec` is public ON PURPOSE (it is the transfer function
  a host needs for .ac/.noise), so the contract now allows that one by name.
  Found by `066`.
- **§5.10 event-assigned variables did not persist** (`Lower.declareVarDecl`).
  A module variable was re-initialised from its declaration at the top of every
  evaluation, so `@(cross(...)) x = V(p);` — whose entire purpose is to capture a
  value and keep it — collapsed back to the initializer on the very next step.
  `vbic13_4t` computes `tiniK`, `imaxMod`, `scaleFac`, `VBICtype` and nine more
  inside `@(initial_step)` and used all of them as ZERO on every step after the
  first. `070_event_hold` pins it. The conformance suite passed the whole time:
  it shape-checks Verilog-A fixtures, and no shape distinguishes a reset from a
  hold.
- **`last_crossing` ignored its direction argument** (`codegen.emitStateMachine`).
  It tested `(prev < 0) != (in < 0)`, which fires on any sign change, so
  §4.5.10's `+1` reported falling crossings. `069_last_crossing_direction` pins
  it; `cross` two cases below always decoded the same argument correctly, and the
  two now share `crossTest`.

## Known gaps

- **An analog operator under a RUNTIME condition is accepted, and wrong.**
  §5.8 requires the condition be an analysis-or-constant expression; FastVAF
  does not diagnose the violation and feeds the operator `0` on every step its
  branch was off. Every fixture here is therefore written without such a guard.
  Full write-up and repro in [../TODO.md](../TODO.md).
- **A §5.10 held variable must be declared at MODULE level.** One declared in a
  §5.3.2 named block inside the analog block still resets every evaluation: its
  declaration is lowered once per execution of the block, so a slot keyed on the
  source name would collide with itself under a §6.6.1 unrolled `for`. See the
  `ponytail:` note on `Lower.markHeldVars` for the upgrade path.
- **`$strobe` under a conditional** is dropped with W0851 and cannot be
  fixtured here; see `check.vh` for the idiom that replaces it.
- **`7 % -3`** is rejected by proof.zig (E0601): a negated integer literal loses
  its constant range, so a divisor §4.2.4 makes obviously nonzero looks
  unbounded. Noted in `021`.
- **Noise** (§4.6.4) and **AC stimulus** (§4.6.3) contribute nothing to a
  residual, so a DC transcript cannot observe them.
