# 1. A first circuit

A SPICE netlist is a text file that lists the parts of a circuit and how
they connect, then says which analyses to run. Here is the smallest useful
one: a 10 V source across two resistors.

```spice
--8<-- "examples/divider.sp"
```

Run it:

```sh
espice divider.sp --rawfile divider.txt --format=print
```

ESPice prints a summary on stderr:

```text
Voltage divider: 3 devices
  Operating Point: 1 points, 3 variables
```

and `divider.txt` holds the result:

```text
Operating Point: Voltage divider
Index	i(v1)	v(in)	v(out)
-----	---------------	---------------	---------------
0	-2.5e-3	1e1	7.5e0
```

`v(out)` is 7.5 V, as 10 V × 3k / (1k + 3k) says it should be. `i(v1)` is
the current through the source, −2.5 mA. SPICE measures a source's current
flowing into its positive terminal, so a source that delivers power shows a
negative current.

## The parts of a netlist

**The title line.** The first line is always the title, whatever it says.
ESPice prints it in the summary and stores it in the output file. A deck
that starts directly with an element loses that element to the title.

**Comments.** A line starting with `*` is a comment. In the ngspice
dialect, `$` or `;` also starts a comment that runs to the end of the line.

**Element cards.** Every other line that does not start with a dot is an
element. The first letter of its name says what kind of element it is (`V`
is a voltage source, `R` a resistor), and the rest of the name only has to
be unique: `R1`, `Rload` and `R_bias` are all resistors. After the name come
the nodes it connects to, then its value:

```text
R1  in  out  1k
│   │   │    └─ value: 1 kilo-ohm
│   │   └────── second node
│   └────────── first node
└────────────── name: R means resistor
```

**Nodes.** A node is any name or number. Two element terminals that name the
same node are connected. Node `0` is ground, the reference every voltage is
measured against; `gnd` and `ground` are the same node. Every circuit needs
a path to ground from every node, or it has no DC solution.

**Control cards.** A line starting with `.` is a control card. `.op` asks
for the DC operating point. `.end` marks the end of the deck; anything
after it is ignored.

**Case.** The ngspice and HSPICE dialects ignore case: `R1` and `r1` name the
same element, and result columns come out lowercase (`v(out)`).

## Values and suffixes

A value is a number with an optional scale suffix. The suffix is one of
these letters, and anything after it is ignored, so `1kOhm`, `1k` and `1000`
are the same value:

| Suffix | Scale | Example |
|---|---|---|
| `t` | 10^12 | `1t` |
| `g` | 10^9 | `2.4g` (Hz) |
| `meg` | 10^6 | `10meg` |
| `k` | 10^3 | `4.7k` |
| `m` | 10^-3 | `5m` |
| `mil` | 25.4 × 10^-6 | `10mil` |
| `u` | 10^-6 | `100u` |
| `n` | 10^-9 | `22n` |
| `p` | 10^-12 | `10p` |
| `f` | 10^-15 | `5f` |

`m` is milli, not mega. `1m` is 0.001; write `1meg` for a million. The
[dialects](../using/dialects.md) page lists the HSPICE and Spectre
differences (HSPICE also reads `x` as mega; Spectre's suffixes are
case-sensitive).

## Splitting long lines

A line that starts with `+` continues the previous line:

```text
V1 in 0
+ DC 10
```

## Exercises

1. Change R2 to 1k. What is `v(out)` now, and what is `i(v1)`?
2. Add a third resistor, `R3 out 0 3k`, in parallel with R2. Predict
   `v(out)` before you run it.
3. Delete the `R2` line. What is `v(out)`? Then add `C1 out x 1n`, where
   nothing else touches `x`, and run it again.

??? tip "Answers"

    1. `v(out)` = 5 V and `i(v1)` = −5 mA.
    2. Two 3k in parallel make 1.5k, so `v(out)` = 10 × 1.5 / 2.5 = 6 V.
    3. Without R2 no current flows through R1, so there is no drop across
       it: `v(out)` = 10 V and `i(v1)` = 0. With `C1` added, node `x` has
       no DC path to ground (a capacitor is open at DC), so the operating
       point is not unique. ESPice refuses the deck:

        ```text
        error: topology: a node has no DC path to ground (capacitor-only island) — the operating point is not unique
        Error: divider.sp: FloatingNode
        ```
