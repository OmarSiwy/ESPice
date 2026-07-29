# 6. Parameters and sweeps

Hard-coded values make a deck hard to change. `.param` names a value once;
expressions compute the rest from it.

```text
.param name=value [name=value ...]
```

A parameter is used inside `{braces}`, and its value may be an expression
of numbers, other parameters and functions:

```spice
--8<-- "examples/expressions.sp"
```

```text
  Measurements for AC Analysis

f3db                =   9.97623e+02
Parameters and expressions: 3 devices
  AC Analysis: 41 points, 4 variables
```

R is computed from the corner frequency you asked for, and the measured
corner lands within 0.3 % of 1 kHz (the gap is the sweep's interpolation
between points).

## Expressions

| Kind | What is available |
|---|---|
| Arithmetic | `+ - * /`, `^` and `**` for powers, parentheses |
| Comparison and logic | `< > <= >= == !=`, `&&`, `\|\|`, `!`, and `cond ? a : b` |
| Functions | `sqrt abs min max pow pwr exp ln log log10 sin cos tan atan tanh floor ceil` |
| Statistics | `agauss gauss unif aunif limit` (nominal value unless Monte Carlo is on; see [chapter 9](monte-carlo.md)) |

`log` is the natural logarithm, like `ln`; use `log10` for base 10.
`pow(x, y)` is |x|^y in the ngspice dialect, while `x^y` keeps the sign of
x for an integer power, as ngspice does. `pwr(x, y)` is sign(x)·|x|^y.

In a behavioural `B` source, expressions can also read `v(node)`,
`v(a,b)`, `i(Vsource)`, `time` and `temper`.

The ngspice dialect also accepts an expression in single quotes
(`R1 a b '2*rval'`) and a bare parameter name as a value (`R1 a b rval`).
The HSPICE dialect takes only those two forms: braces are an error there.
See [dialects](../using/dialects.md).

## Scope

A `.param` at the top level is global. Parameters on a `.subckt` line, or
on `.param` cards inside a subcircuit, are local to each instance, and an
`X` card's `name=value` pairs override them for that instance.

## `.step`: run everything again with a new value

`.step` reruns every analysis in the deck once per value:

```text
.step param name list v1 v2 ...
.step param name start stop step
.step [lin|dec|oct] param name start stop points-or-step
.step temp list t1 t2 ...
.step Vsource list v1 v2 ...
```

```spice
--8<-- "examples/step_param.sp"
```

```text
  Measurements for AC Analysis

f3db                =   1.58788e+03

  Measurements for AC Analysis

f3db                =   7.93938e+02

  Measurements for AC Analysis

f3db                =   3.96908e+02
RC corner against R, with .step: 3 devices
  AC Analysis (rval=1000): 21 points, 4 variables
  AC Analysis (rval=2000): 21 points, 4 variables
  AC Analysis (rval=4000): 21 points, 4 variables
```

Each run gets its own plot, named for the point, and each `.meas` card is
evaluated per run. Doubling R halves the corner, as 1/(2πRC) says. Several
`.step` cards make a grid; the last one varies fastest.

## Exercises

1. In `expressions.sp`, change `f0` to 20k. What does the `.meas` line
   report, and what do you change to fix it?
2. Write a `.param` that sets `rpar` to R1 and R2 in parallel, for
   `.param r1=3k r2=6k`.
3. Use `.step` to run `diode_iv.sp` (chapter 3) at −40, 27 and 125 °C.

??? tip "Answers"

    1. The `.ac` card stops at 10 kHz, below the new corner, so the
       response never falls 3 dB inside the sweep and ESPice prints
       `Error: measure  f3db : out of interval`. Extend the sweep to 100k.
    2. `.param rpar={r1*r2/(r1+r2)}`, which is 2k.
    3. `.step temp list -40 27 125`. You get three DC plots, named
       `(temp=-40)`, `(temp=27)` and `(temp=125)`.
