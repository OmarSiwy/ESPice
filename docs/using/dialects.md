# Dialects

ESPice reads three netlist dialects. Pick one with `--tokenizer`:

```sh
espice deck.sp                        # ngspice, the default
espice --tokenizer=hspice deck.sp     # or hs
espice --tokenizer=spectre deck.scs   # or scs
```

The dialect is a property of the whole run: an `.include`d file is read in
the same dialect as the deck that includes it. All three share one card
table, so most of the language is the same; the dialect changes how lines
are split and a handful of meanings.

## At a glance

| | ngspice | HSPICE | Spectre |
|---|---|---|---|
| First line | title | title | a card (no title) |
| Case | ignored | ignored | kept |
| Line comment | `*` at line start | `*` at line start | `//`, or `*` at line start |
| Inline comment | `$` or `;` anywhere | `$` after a blank | `//`, and `/* ... */` |
| Continuation | `+` on the next line | `+` on the next line, or `\\` at line end | `+` on the next line, or `\` at line end |
| Quotes | `'...'` | `'...'` and `"..."` | `"..."` |
| Expressions | `{...}`, `'...'` or a bare parameter name | `'...'` or a bare parameter name; braces are not read | as ngspice |
| `M` / `m` suffix | milli, either case | milli, either case | `M` mega, `m` milli |
| `x` suffix | none | mega | none |
| `.include`, `.lib`, `.alter` | yes | yes | no |
| Default TNOM, circuit temperature | 27 °C, 27 °C | 25 °C, run at TNOM | 27 °C, 27 °C |

The ngspice and HSPICE suffix tables are `t g meg k m mil u n p f`
(case-insensitive). Spectre's are case-sensitive: `P` (peta), `T`, `G`,
`M` (mega), `K` or `k`, `m` (milli), `u`, `n`, `p`, `f`, `a` (atto), and
`%` or `c` for 10^-2.

## ngspice

The default dialect follows ngspice 45, including the conveniences the
open PDKs (sky130, GF180, IHP SG13G2) are written against:

- `.endl` closes the open `.lib` section whatever name follows it.
- `.if` / `.elseif` / `.else` / `.endif` keep the first branch whose
  condition is nonzero.
- `.model <name> psp103va` (the OSDI module name) selects the built-in PSP
  103.
- An R card whose braced value reads `v(`, `i(`, `time`, `temper` or
  `hertz` becomes a behavioural B source, as ngspice's `inp_compat` does.
- In expressions, `pow(x, y)` is |x|^y while `x^y` keeps the sign of x for
  an integer power.
- `.option seed=N` without a Monte Carlo sweep draws the statistical
  functions once from the seed, instead of folding them to their nominal.
- Unknown `.option` names are ignored, as in ngspice.

The sky130 PDK decks run as written.

## HSPICE

A small HSPICE deck: parameters used bare, `PULSE` without parentheses, an
untyped `.measure` and an `.alter` run:

```text
--8<-- "examples/hspice_alter.sp"
```

```sh
espice --tokenizer=hspice hspice_alter.sp
```

```text
  Measurements for Transient Analysis

t50                 =   1.39130e-09

  Measurements for Transient Analysis

t50                 =   2.77759e-09
RC step response in the HSPICE dialect: 3 devices
  Transient Analysis: 2012 points, 4 variables
  Transient Analysis (alter=1): 2012 points, 4 variables
```

The `.alter` run doubles R, and the 50 % crossing moves from RC ln 2 =
1.39 ns to 2.77 ns.

`--tokenizer=hspice` changes the line syntax (above) and these meanings:

| Input | HSPICE dialect | ngspice dialect |
|---|---|---|
| no `.option tnom`, no `.temp` | TNOM 25 °C, circuit at TNOM | 27 °C both |
| `.temp t1 t2 t3 ...` | every analysis once per temperature, plots named `<plot> (temp=t)` | three numbers: a DC temperature sweep |
| `.tran s1 t1 s2 t2 ...` | one run to the last stop | `tstep tstop tstart tmax` |
| untyped `.measure name func ...` | measures the last `.tran`, `.ac` or `.dc` card | rejected |
| TARG without `TD=` in `.measure` | inherits TRIG's `TD` | `TD=0` |
| unknown `.option` names | one warning each | ignored |
| `.save [TYPE=NODESET\|IC] [FILE=] [LEVEL=] [TIME=]` | writes the operating point as `.nodeset` (or `.ic`) cards | output vector selection |
| `SFFM(vo va fc mdi fs)` | HSPICE's argument order | ngspice's `(vo va fm mdi fc)` |
| `P` element | a port: a V card numbered for `.lin` (`P1 in 0 port=1 z0=50`) | a coupled transmission line (CPL) |
| `S` element | an S-parameter block from Touchstone or CITI data | voltage-controlled switch |
| `W` element | a W-element lossy line from an RLGC file or table | current-controlled switch |
| `B`, `U` elements | refused (IBIS buffers, lumped lines) | B source, URC line |

HSPICE features that ESPice reads in every dialect, because none of them
collides with an ngspice spelling:

- **Runs and sweeps:** `.alter` blocks (cumulative, one run each, plots
  named `(alter=n)`); `.data` tables with `SWEEP DATA=name`; `SWEEP
  MONTE=n` and `MONTE=list(...)`; `SWEEP OPTIMIZE=` with `.param p =
  name(init, lo, hi)` and `.meas ... GOAL=`.
- **Analysis cards:** `.op t1 t2 ...` (operating points at times),
  `.dc ... POI`, `.ac POI`, `.four f v(a) v(b) ...`, `.fft`, `.lin`,
  `.net`, `.sn`/`.snac`/`.snxf`/`.snnoise`/`.snosc`, `.hb TONES= NHARMS=`,
  `.hbosc`, `.hbac`, `.hbxf`, `.hbnoise`, `.hblin`, `.phasenoise`,
  `.acphasenoise`, `.ptdnoise`, `.lstb`, `.dcmatch`, `.acmatch`,
  `.dcsens`, `.trannoise`, `.pz v(out) src`, `.noise v(out) src [inter]`.
- **Measurements:** `INTEGRAL`, `DERIVATIVE`, `ERR`, `ERR1`-`ERR3`, `PARAM=`,
  `TRAN_CONT`/`AC_CONT`/`DC_CONT`, `EM_AVG`, `par('expr')`, values that name
  earlier results, `TD=TRIG`, and measures of FFT, LSTB, DCMATCH, ACMATCH,
  PHASENOISE and PTDNOISE plots.
- **Digital stimuli:** `PAT (vhi vlo td tr tf tsample data)` sources and
  `.vec` vector files, rewritten to PWL sources and `.dout` checks.
- **Checks and reports:** `.check rise|fall|slew|setup|hold|edge|irdrop`,
  `.dout`, `.biaschk`, `.power`, `.stim`.
- **Statistics:** `agauss`, `gauss`, `aunif`, `unif`, `limit`; `DEV` and
  `LOT` tolerances on `.model` values; the `.variation` block.
- **Other:** `.load` (inline a saved `.ic`/`.nodeset` file), `.option
  search='dir'`, `.connect`, `.global`, `.mosra` and `.appendmodel`
  (reliability aging), `.sample`, `.option runlvl|accurate|fast`,
  `gmindc`, `absv`, `relv`, `absi`, `method=bdf`.

## Spectre

`--tokenizer=spectre` reads SPICE cards with Spectre's lexical rules: no
title line, case kept (so `R1` and `r1` are different elements),
C-style comments and Spectre's case-sensitive suffixes. The card syntax is
still SPICE's (`R1 a b 1K`, `.ac dec 10 10 1M`); Spectre's own instance
syntax (`r1 (a b) resistor r=1k`), `simulator lang=` switching and its
analysis statements are not read. `.include`, `.lib` and `.alter` are not
expanded in this dialect.

```text
--8<-- "examples/spectre_rc.scs"
```

```sh
espice --tokenizer=spectre spectre_rc.scs
```

```text
: 3 devices
  AC Analysis: 51 points, 4 variables
```

The summary starts with `:` because a Spectre deck has no title.

## What is not supported, or differs

ESPice refuses what it cannot simulate with `UnsupportedCard`, naming the
line; it never drops a card silently. Output-only cards (`.print`,
`.plot`, `.probe`, `.graph`, `.width`, `.title`, `.protect`,
`.unprotect`) are accepted and ignored, because every vector is written
anyway.

| Input | ngspice or HSPICE | ESPice |
|---|---|---|
| OSDI (`pre_osdi`, `.osdi_include`) | loads a compiled `.osdi` | refused with `OsdiUnsupported`, naming the `.hdl` card to use instead; see [Verilog-A](devices.md#your-own-verilog-a) |
| `.control` ... `.endc` | runs ngspice scripts | skipped with a warning (`pre_osdi` inside it is still an error) |
| E/G `FREQ`, `OPAMP`, `NPWL`, `PPWL`, `AND`, `NAND`, `OR`, `NOR`, `TRANSFORMER` | HSPICE behavioural forms | refused |
| `0e400` (zero mantissa, huge exponent) | NaN (0 × inf) | 0 |
| URC model with `K <= 0` or `K = 1` | NaN or meaningless ladder | `InvalidParameterValue` |
| URC card without `l=` | zero length | unit length |
| Verilog-A `$simparam("gmin")` during gmin stepping | the deck gmin | the stepped gmin |
| a `.temp` list and a single `.temp` in one deck | no list form | the last card wins |
| `.ic` with `.tran` but without `uic` | held during the transient's operating point | used only under `uic` |
| `.store` | checkpoints the process | warning; no checkpoint written |
| `.powerdc` | per-instance port currents | refused |
| `.connect` inside a subcircuit | joins nets | refused (top level only) |
| `.option search` on a `+` continuation line | read | missed: only the first physical line is read |
| a `.param` or `.model` inside a subcircuit's `.if` | conditional | applies unconditionally |
| `PAT` Z states, K-strings, `R=-1`, LFSR; `.vec` bidirectional signals, Z/L/H inputs | supported | refused |
| PWL with `r=` past 64 points | repeats | refused |
| `.dout` with no threshold | n/a | 1.65 V |
| `.vec` edges with no rate given | n/a | 0.1 time units |
| `.measure DERIV` | ngspice 45 rejects it | slope of the sample pair around the point |
| `.measure ERR3` | the manual gives no reduction | RMS, as `ERR1` |
| `.meas` with `-r` in batch mode | ngspice refuses | always evaluated and printed |
| HSPICE `.mt0`, `.ic0` listings, `.err` files | written | not written; results print on stdout |

The HSPICE features above follow the HSPICE manuals; most have not been
run against HSPICE itself, so treat an HSPICE-only result with the same
care as any new simulator's.
