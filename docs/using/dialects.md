# Dialects

ESPice reads three netlist dialects. Pick one with `--tokenizer`:

```sh
espice deck.sp                        # ngspice, the default
espice --tokenizer=hspice deck.sp     # or hs
espice --tokenizer=spectre deck.scs   # or scs
```

The dialect is a property of the whole run: an `.include`d file is read in
the same dialect as the deck that includes it (a Spectre `include` picks
Spectre or SPICE mode per file, below). All three share one card
table, so most of the language is the same; the dialect changes how lines
are split and a handful of meanings.

## At a glance

| | ngspice | HSPICE | Spectre |
|---|---|---|---|
| First line | title | title | title |
| Case | ignored | ignored | kept |
| Statements | SPICE cards | SPICE cards | Spectre statements; SPICE cards after `simulator lang=spice` |
| Line comment | `*`, `#`, `$` or `;` at line start, or a line holding only a `//` comment | `*` or `$` at line start | `*` in the first column, or a `//` line |
| Inline comment | `;` or `//` anywhere; `$` after a blank or comma | `$` after a blank, a comma or a number | `//` |
| Continuation | `+` on the next line; `\\` at line end joins with no blank | `+` on the next line; ` \` at line end, or `\\` to join with no blank | `+` on the next line, or `\` at line end |
| Quotes | `'...'` and `"..."` keep comment characters | `'...'` and `"..."` keep `$` | `"..."` strings |
| Expressions | `{...}`, `'...'` or a bare parameter name | `'...'`, a bare parameter name, or after `key=` an unquoted one that starts with a letter and holds no blank (`w=l*2`); braces are name bytes, as in HSPICE, so `{...}` is no expression, and a behavioural (`VOL=`, `TABLE`) or `.meas` card holding one is refused | bare (`r=2*a`) |
| `M` / `m` suffix | milli, either case | milli, either case | `M` mega, `m` milli |
| `x` suffix | none | mega | none |
| Includes, `.alter` | `.include`, `.lib`, `.alter` | `.include`, `.lib`, `.alter` | `include "f" [section=s]`; no `.alter` |
| Default TNOM, circuit temperature | 27 °C, 27 °C | 25 °C, run at TNOM | 27 °C, 27 °C |

The ngspice and HSPICE suffix tables are `t g meg k m mil u n p f a`
(case-insensitive), and `d` works as an exponent (`1d-3`). HSPICE forbids
an exponent and a suffix in one number, so an HSPICE deck that writes
`1e-6u` is refused; ngspice reads it as 1e-12. Spectre's are case-sensitive: `P` (peta), `T`, `G`,
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
- In `.param` expressions `x^y`, `x**y`, `pow(x, y)` and `pwr(x, y)` are
  |x|^y, as ngspice's numparam computes them; a B source reading a probe
  keeps the sign of x for a constant integer power.
- `.option seed=N` without a Monte Carlo sweep draws the statistical
  functions once from the seed, instead of folding them to their nominal.
- Unknown `.option` names are ignored with one warning each.

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
| `.save [TYPE=NODESET\|IC] [FILE=] [LEVEL=] [TIME=]` | writes the operating point as `.nodeset` (or `.ic`) cards | output vector selection |
| `SFFM(vo va fc mdi fs)` | HSPICE's argument order | ngspice's `(vo va fm mdi fc)` |
| `AM(...)` | `(va vo mf fc td)` | ngspice's `(vo vmo vma fm fc td phasem phasec)` |
| `sqrt(-x)`, `log(-x)`, `log10(-x)`, `pow(x, y)` | `-sqrt(x)`, `-log(x)`, `-log10(x)`, x to the integer part of y | NaN, NaN, NaN, \|x\|^y |
| `P` element | a port: a V card numbered for `.lin` (`P1 in 0 port=1 z0=50`) | a coupled transmission line (CPL) |
| `S` element | an S-parameter block from Touchstone or CITI data | voltage-controlled switch |
| `W` element | a W-element lossy line from an RLGC file or table | current-controlled switch |
| `B`, `U` elements | refused (IBIS buffers, lumped lines) | B source, URC line |

HSPICE features that ESPice reads in every dialect, because none of them
collides with an ngspice spelling:

- **Runs and sweeps:** `.alter` blocks (cumulative, one run each, plots
  named `(alter=n)`); `.data` tables with `SWEEP DATA=name`; `SWEEP
  MONTE=n` and `MONTE=list(...)`; `SWEEP OPTIMIZE=` with `.param p =
  name(init, lo, hi[, dels[, grid]])` (the grid is ESPice's) and `.meas ... GOAL=`.
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
  `.vec` vector files, rewritten to PWL sources and `.dout` checks. A
  pattern nests at most 32 `[ ]` levels, counted through the `.pat` names
  it reads.
- **Checks and reports:** `.check rise|fall|slew|setup|hold|edge|irdrop`,
  `.dout`, `.biaschk`, `.power`, `.stim`.
- **Statistics:** `agauss`, `gauss`, `aunif`, `unif`, `limit`; `DEV` and
  `LOT` tolerances on `.model` values; the `.variation` block.
- **Other:** `.load` (inline a saved `.ic`/`.nodeset` file), `.option
  search='dir'`, `.connect`, `.global`, `.mosra` and `.appendmodel`
  (reliability aging), `.sample`, `.option runlvl|accurate|fast`,
  `gmindc`, `absv`, `relv`, `absi`, `method=bdf`.

## Spectre

`--tokenizer=spectre` reads Spectre netlists: the first line is the title
and case is kept (`R1` and `r1` are different elements). ESPice reads each
Spectre statement as the SPICE card it stands for, so a Spectre deck and its
SPICE counterpart build the same circuit. It reads:

- instances, `name (nodes) master key=value ...` (parentheses optional),
  of the primitives (`resistor`, `capacitor`, `inductor`, `vsource`,
  `isource`, `vcvs`, `vccs`, `ccvs`, `cccs`, `mutual_inductor`, `iprobe`,
  `bsource`, ...), of models, of subcircuits and of `ahdl_include`d
  Verilog-A modules;
- `parameters`, `model` (with `{ 1: ... 2: ... }` bin groups), `subckt` /
  `inline subckt` ... `ends`, `real f(real a) { return ... }`, `if` /
  `else`, `global`, `ic`, `nodeset`, `save`, `options`;
- `include "file" [section=name]`: a `.scs` file, or one opening with
  `simulator lang=spectre`, reads as Spectre, any other as SPICE, and the
  includer's mode resumes after it;
- `simulator lang=spice` ... `simulator lang=spectre`: SPICE cards with
  HSPICE's line rules;
- the `tran`, `dc`, `ac` and `noise` analyses. `tran` reads `stop`,
  `step`, `start`, `maxstep`, `method` (`euler`, `trap`, `traponly`,
  `gear2`, `gear2only`; it sets the deck's `.options method`, so it applies
  to every transient), `skipdc=yes|no` (`yes` starts from the `ic`
  statements, as SPICE's `uic`) and `errpreset=moderate` (the default).

Refused with `UnsupportedCard`: the other analyses (`pss`, `hb`, `sweep`,
`montecarlo`, ...), any other `tran` parameter or value (named in the
error, such as `errpreset=conservative` or `method=trapgear2`), child statements in an analysis's `{ }`, `alter`,
`altergroup`, `paramset`, `atan2`, the bitwise operators, and an
`inst:terminal` signal in `ic` or `nodeset`. `statistics` blocks are read
and set aside with a warning; `info`, `set`, `shell`, `check`, `checklimit`,
`assert` and `paramtest` are accepted and ignored. `/* ... */` is not a
comment in Spectre.

```text
--8<-- "examples/spectre_rc.scs"
```

```sh
espice --tokenizer=spectre spectre_rc.scs
```

```text
// RC low-pass in Spectre syntax: the first line is the title: 3 devices
  AC Analysis: 51 points, 4 variables
```

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
| `.vec` edges with no rate given | 0.1 ns | 0.1 ns |
| `.measure DERIV` | ngspice 45 rejects it | slope of the sample pair around the point |
| `.measure ERR3` | the manual gives no reduction | RMS, as `ERR1` |
| `.meas` with `-r` in batch mode | ngspice refuses | always evaluated and printed |
| HSPICE `.mt0`, `.ic0` listings, `.err` files | written | not written; results print on stdout |

The HSPICE features above follow the HSPICE manuals; most have not been
run against HSPICE itself, so treat an HSPICE-only result with the same
care as any new simulator's.
