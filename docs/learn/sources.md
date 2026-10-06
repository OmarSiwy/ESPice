# 2. Sources

Every circuit needs something to drive it. SPICE has independent sources,
which set a voltage or current, and controlled sources, whose output
depends on another voltage or current in the circuit.

## Independent sources

A voltage source is `V`, a current source `I`:

```text
Vname n+ n- [DC value] [AC mag [phase]] [waveform]
Iname n+ n- [DC value] [AC mag [phase]] [waveform]
```

The three parts serve different analyses:

- `DC value` is the value at the operating point and in `.dc` sweeps. A
  bare number after the nodes means the same thing: `V1 in 0 5`.
- `AC mag [phase]` is the small-signal stimulus for `.ac` and the noise
  input reference: `AC 1` is a 1 V phasor at 0 degrees.
- The waveform is the value over time in `.tran`.

A current source pushes current from `n+` through the source to `n-`, so
`I1 0 a 1m` drives 1 mA *into* node `a`.

### Waveforms

| Waveform | Arguments |
|---|---|
| `PULSE(v1 v2 td tr tf pw per)` | low, high, delay, rise, fall, width, period |
| `SIN(vo va freq td theta phase)` | offset, amplitude, Hz, delay, damping (1/s), degrees |
| `EXP(v1 v2 td1 tau1 td2 tau2)` | start, end, rise delay and time constant, fall delay and time constant |
| `PWL(t1 v1 t2 v2 ...)` | time and value pairs, linear in between; `r=` repeats, `td=` delays |
| `SFFM(vo va fm mdi fc)` | single-frequency FM (ngspice argument order) |
| `AM(va vo mf fc td)` | amplitude modulation |

Trailing arguments may be left off. A `PULSE` with no rise or fall time
uses the transient's step; with no width or period it stays high until the
end.

This deck drives five 1k loads, one per waveform, plus a DC current source:

```spice
--8<-- "examples/sources.sp"
```

```sh
espice sources.sp --rawfile sources.raw
```

```text
Independent source waveforms: 10 devices
  Transient Analysis: 526 points, 10 variables
```

Open `sources.raw` in a waveform viewer, or write `--format=csv` and plot
the columns with anything you like.

## Controlled sources

Four letters give the four linear dependent sources:

| Card | Output | Controlled by | Syntax |
|---|---|---|---|
| `E` | voltage | a voltage (VCVS) | `E1 out+ out- in+ in- gain` |
| `G` | current | a voltage (VCCS) | `G1 out+ out- in+ in- transconductance` |
| `F` | current | a current (CCCS) | `F1 out+ out- Vsense gain` |
| `H` | voltage | a current (CCVS) | `H1 out+ out- Vsense transresistance` |

`F` and `H` sense the current through a voltage source. When there is no
source in the branch you want to sense, add a 0 V one (`Vsense`) in series:
it changes nothing in the circuit and gives you a current to read.

`B` is a behavioural source: its value is any expression of node
voltages, branch currents, `time` and parameters.

```text
B1 out 0 V={v(a)*v(b)}       voltage source
B2 out 0 I={1m*tanh(v(in))}  current source
```

All of them in one deck:

```spice
--8<-- "examples/controlled.sp"
```

```sh
espice controlled.sp --rawfile controlled.txt --format=print
```

```text
Operating Point: The four controlled sources and a B source
Index	i(v1)	i(vsense)	i(b1)	i(e1)	i(h1)	v(in)	v(sense)	v(f)	v(h)	v(b)	v(e)	v(g)
-----	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------	---------------
0	-3.0000000000000005e-3	4.999999999999946e-4	-1e-3	-5.999999999999986e-3	-2.500000000000001e-4	2e0	1.9999999999999991e0	9.999999999999848e-1	2.500000000000001e-1	1e0	5.999999999999997e0	1.999999999999999e0
```

Check each against its card: `v(e)` = 3 × 2 V = 6 V. G1 pushes
1 mA/V × 2 V = 2 mA into `g`, so `v(g)` = 2 V across 1k. 0.5 mA flows
through Vsense, so F1 drives 1 mA into `f` (1 V) and H1 makes
500 Ω × 0.5 mA = 0.25 V. And `v(b)` = 2² / 4 = 1 V.

E and G also accept the classic nonlinear forms (`POLY`, `VALUE=`,
`TABLE`, `LAPLACE`, `POLE`, `DELAY`); the
[language reference](../using/reference.md#controlled-sources) lists them.

!!! warning "Keyword node names"
    In an E, F, G or H card, the word in the first control-node position is
    checked against the behavioural keywords first (`poly`, `value`,
    `table`, `laplace`, `pole`, `delay`, `vcr`, `vccap`, `vol`, `cur`, ...).
    A node named `pole` there turns the card into a POLE source and the deck
    fails with `ParseError`. Pick another node name.

## Exercises

1. In `controlled.sp`, change the gain of `F1` to `-2`. What happens to
   `v(f)`?
2. Make a 1 kHz square wave between −1 V and 1 V with 1 µs edges, using
   `PULSE`.
3. Using one `G` card and one resistor, build a voltage amplifier with a
   gain of −10 from node `in` to node `out`.

??? tip "Answers"

    1. F1 now pushes 1 mA out of `f`, so `v(f)` = −1 V.
    2. `V1 sq 0 PULSE(-1 1 0 1u 1u 0.499m 1m)`: the width plus one edge is
       half the period.
    3. `G1 out 0 in 0 10m` and `R1 out 0 1k`. G1 drives
       10 mA/V × v(in) from `out` to ground through the source, so the
       current into `out` is −10 mA/V × v(in), and across 1k that is
       −10 × v(in).
