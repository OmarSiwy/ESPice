# Auxiliary input file syntax: Touchstone, RLGC, .vec, .data, .ic0, .control

Survey date: 2026-10-17. The purpose is a PEG grammar per format that can
serve as its executable spec, the way Zig's `doc/langref/grammar.peg` is
checked against the real parser. Each section gives the lexical rules, a
PEG sketch, the semantic constraints a PEG cannot express (counts, order),
and the places where ESPice's reader departs from the source. Every rule
cites a manual version and page.

## Sources

All fetched on the survey date and read as text (`pdftotext -layout`).

| Tag | Document | URL |
|---|---|---|
| TS1.1 | IBIS Open Forum, *Touchstone File Format Specification* Rev 1.1 (copyright 2002, page footer 10/1/2003) | https://ibis.org/connector/touchstone_spec11.pdf |
| TS2.0 | IBIS Open Forum, *Touchstone File Format Specification* Version 2.0, ratified 2009-04-24 | https://ibis.org/touchstone_ver2.0/touchstone_ver2_0.pdf |
| SI | Synopsys, *HSPICE Signal Integrity User Guide* A-2007.12 | https://ece.iisc.ac.in/~dipanjan/E8_262/hspice_si.pdf |
| STAR | Avant!, *Star-Hspice Manual* Release 2001.2 | https://www.ee.columbia.edu/~kinget/EE3081_F02/documentation/hspice.pdf |
| SA | Synopsys, *HSPICE User Guide: Simulation and Analysis* B-2008.09 | https://cseweb.ucsd.edu/classes/wi10/cse241a/assign/hspice_sa.pdf |
| CR | Synopsys, *HSPICE Reference Manual: Commands and Control Options* E-2010.12 | https://nthuee.org/archive/AIC/106%E8%AC%9D%E5%BF%97%E6%88%90/Hspice/hspice_cmdref.pdf (same text: https://cseweb.ucsd.edu/classes/wi10/cse241a/assign/hspice_cmdref.pdf) |
| NG | *Ngspice User's Manual* Version 47+ (development, 2026-09-28) | https://ngspice.sourceforge.io/docs.html |
| SKRF | scikit-rf `skrf/io/touchstone.py` at `aa156629` (secondary) | https://github.com/scikit-rf/scikit-rf/blob/master/skrf/io/touchstone.py |

Page numbers are the printed page numbers of the manual, not PDF page
indices. Xyce's Touchstone reader was not consulted; scikit-rf was enough as
a second reader, and ngspice reads no Touchstone files.

Code references are to the working tree at `66ec7fe` plus the uncommitted
changes listed in `git status` on the survey date.

---

## 1. Touchstone 1.0 (`.sNp`)

### Lexical rules

- Case-insensitive throughout (TS1.1 §2 rule 1, p.3; TS2.0 rule 1, p.4).
- Printable ASCII 0x20-0x7E plus tab and line terminators only (TS1.1 §2
  rule 2). TS1.1 names the terminators as "carriage-return or
  carriage-return/line-feed"; TS2.0 rule 2 (p.4) widens this to LF, CR+LF
  or a lone CR. Tabs are allowed but "strongly discouraged" (TS1.1).
- `!` starts a comment that runs to the end of the line, on its own line or
  after the last value (TS1.1 §2 rule 3 and §3 "Comment Lines", p.10;
  TS2.0 p.6, which says the comment rules are identical for 1.0 and 2.0).
- Blank lines are allowed (TS2.0 rule 9, p.4; TS1.1 says nothing, but its
  Example 5 has blank lines between frequency points, p.8).
- Numbers: scientific notation is allowed, with no precision limits (TS2.0
  rule 6, p.4). Neither version mentions SPICE scale suffixes, and no
  example uses one. The TS1.1 template
  `<frequency value> <N11>, <N21>, <N12>, <N22>` (p.6) has commas, but the rule two lines above it says entries are separated by
  whitespace, and every example uses whitespace.
- Angles are in degrees (TS1.1 §2 rule 5).

### Option line

`# <frequency unit> <parameter> <format> R <n>` (TS1.1 §3, p.4-5;
TS2.0 p.6-7):

- Exactly one option line counts: "additional option lines after the first
  one will be ignored" (TS1.1 p.4; TS2.0 p.6, "shall be ignored").
- In a 1.0 file it must be the first non-comment line (TS1.1 p.4), and
  TS2.0 p.7 adds "non-blank" and "shall precede any data lines".
- Tokens are separated by one or more whitespace characters. Apart from the
  leading `#` and the value after `R`, they may appear in any order. A
  missing token takes its default: `GHz S MA R 50`. A bare `#` is a legal
  option line (TS1.1 p.5).
- Units: `Hz kHz MHz GHz`. Parameters: `S Y Z H G` (TS2.0 p.7 and p.13
  restrict H and G to 2-ports). Formats: `DB MA RI`. `R n` takes a positive
  number of ohms (TS2.0 p.6: "a real, positive number").
- In 1.0, R is the S reference and also the normalization of Y, Z, H and G
  data: Example 2 in TS1.1 (p.7) gives Z normalized to 75 Ω, and TS2.0 p.7
  confirms that 1.0 normalizes Y and Z while 2.0 does not.

### Data

- Each frequency point is a frequency followed by N² pairs (TS1.1 p.6).
  The pairs are MA, DB (20·log10|x| with an angle) or RI, as the option line
  says.
- N = 1 or 2: the whole point goes on one line. The 2-port order is
  `N11 N21 N12 N22`: "'21' data precedes '12' data" (TS1.1 p.6).
- N = 3 or 4: one matrix row per line, row-major: `N11 N12 N13 / N21 ...`
  (TS1.1 p.7-8). Columns need not line up (p.9).
- N ≥ 5: at most 4 pairs per line, every matrix row starts on a new line,
  and a row wraps onto further lines after 4 pairs (TS1.1 p.9-10; TS2.0
  p.17, "Rules for Version 1.0 Files").
- Frequencies must be strictly increasing: "All data sets must be arranged
  in increasing order of frequency" (TS1.1 general rule 4, p.6).
- TS2.0 rule 5 (p.13) adds that a frequency may only appear at the start of
  a line.
- HSPICE does not follow the per-line layout in its own example. SI Ch.2
  Example 6 (p.48) wraps a 2-port point onto two lines of two pairs each.
  A reader that has to load HSPICE-era files should therefore treat the data
  as a token stream and count values, which is the 2.0 rule (TS2.0 p.13:
  "a new frequency point is expected every 2n²+1 values").

### Noise block (2-ports only)

- Allowed only in 2-port files, after all the network data (TS1.1 p.10;
  TS2.0 p.23).
- Five values per row: `freq NFmin(dB) |Γopt| ∠Γopt(deg) Rn/R`. The option
  line format does not apply: Γopt is always magnitude and angle. Rn is
  normalized to R in 1.0 (TS1.1 p.10; TS2.0 p.24).
- The noise block starts at the first frequency less than or equal to the
  last network frequency (TS1.1 p.11; TS2.0 p.24). TS1.1 p.10 also says
  "less than" in the x1 description, but the governing sentence on p.11
  says "less than or equal".
- Each noise row sits on one line (TS2.0 p.24, "In both Version 1.0 and
  Version 2.0"), and noise frequencies increase (TS2.0 p.24).
- SKRF detects noise data with a strict `<` and only for rank 2 in 1.0
  files (`touchstone.py` around line 530). A file whose first noise
  frequency equals the last network frequency is therefore misread by
  scikit-rf, though it is legal under the spec.

### Touchstone 2.0 in brief

- `[Version] 2.0` must be the first non-comment, non-blank line (TS2.0
  p.6). It is followed by the option line and then `[Number of Ports]`.
- Further keywords: `[Two-Port Data Order] 12_21|21_12` (required for
  2-ports), `[Number of Frequencies]`, `[Number of Noise Frequencies]`,
  `[Reference]` (per-port impedances), `[Matrix Format] Full|Lower|Upper`,
  `[Mixed-Mode Order]`, `[Begin Information]`/`[End Information]`,
  `[Network Data]`, `[Noise Data]` and `[End]` (TS2.0 p.6-12).
- Keywords start in column 1 (TS2.0 rule 7, p.4).
- No limit on pairs per line. Y, Z, H and G data are not normalized, and
  neither is the noise Rn (TS2.0 p.7, p.24).
- A 1.0 reader can recognise a 2.0 file by a line starting with `[`.

### PEG (1.0, with a lenient data body)

```peg
# Lexical
EOL        <- '\r\n' / '\n' / '\r'
WS         <- [ \t]+
Comment    <- '!' (!EOL .)*
End        <- WS? Comment? (EOL / !.)
Digit      <- [0-9]
Number     <- [+-]? (Digit+ ('.' Digit*)? / '.' Digit+) ([eE] [+-]? Digit+)?

# Structure
File       <- Blank* OptionLine Body !.
Blank      <- WS? Comment? EOL
OptionLine <- WS? '#' (WS? OptionTok (WS OptionTok)*)? End
OptionTok  <- Unit / Param / Format / Ref
Unit       <- ([gG] / [mM] / [kK])? [hH] [zZ] !Word
Param      <- [sSyYzZhHgG] !Word
Format     <- ([dD] [bB] / [mM] [aA] / [rR] [iI]) !Word
Ref        <- [rR] WS Number
Word       <- [A-Za-z0-9_.+-]
Body       <- (Blank / ExtraOption / DataLine)*
ExtraOption<- WS? '#' (!EOL .)* (EOL / !.)       # ignored: TS1.1 p.4
DataLine   <- WS? Number (WS Number)* End
```

Ordered choice settles the `H`-parameter vs `Hz` clash: `Unit` is tried
before `Param`, and both end in `!Word`.

Constraints outside the PEG:

1. Each of `Unit`, `Param` and `Format` should appear at most once; the spec
   does not cover repeats (open question 1).
2. Read the DataLine numbers as one stream. Network records hold 1 + 2N²
   values. The network data ends at the first record whose frequency is not
   greater than the one before it. When N = 2, the remainder must be noise
   rows of exactly 5 values, one per line, with increasing frequencies. For
   any other N, or when the remainder is not a whole number of noise rows,
   the file is malformed.
3. Strict 1.0 line layout (one line per 1- or 2-port point; one row per
   line for N = 3 or 4; at most 4 pairs per line and every row on a new line
   for N ≥ 5) is a lint, not a parse rule, because HSPICE's own example
   breaks it.
4. R > 0. Every frequency ≥ 0 and finite. The spec does not rule out 0 Hz;
   HSPICE's noise example starts at 0 (SI p.48).

### ESPice reader: `src/frontend/sparam.zig` `parseTouchstone`

Matches the spec on the defaults, case folding, `!` comments, `[`
rejection of 2.0 files, normalization of 1.0 Y and Z data, the 2-port
`21/12` order (line 116) and token-stream data. Discrepancies:

- **T1. A glued option token is lost** (sparam.zig:73). `_ = it.next()`
  drops the whole first token, so `#MHz S RI R 50` drops `#MHz` and keeps
  the default GHz. That silently scales every frequency by 1000. SKRF strips
  only the `#` (`line.lower()[1:]`).
- **T2. Every option line applies, and the last one wins** (sparam.zig:72-82).
  The spec says the first one counts and later ones are ignored.
- **T3. The option line may come after data and still applies to it**
  (sparam.zig:72; the conversion happens after the loop, from line 97). In a
  1.0 file the option line must come first.
- **T4. Network data ends silently at a non-ascending frequency for any
  port count** (sparam.zig:91-95). Anything after that is dropped unchecked:
  a non-monotonic N-port, duplicate frequencies, noise rows in a non-2-port
  file, or a short trailing record (`(nf + 1) * stride <= len`). The spec
  requires increasing frequencies and allows noise only for 2-ports, so
  these should be errors, not truncations. Noise rows are not checked to
  hold 5 values.
- **T5. `std.fmt.parseFloat` accepts more than the spec's numbers**
  (sparam.zig:84). It takes `inf`, `nan`, hex floats (`0x1p3`) and digit
  underscores (`1_000`); checked on Zig 0.16. Frequencies are checked for
  finiteness (line 102), but a `nan` S value passes into the fit.
- **T6. A lone CR is not a line ending** (sparam.zig:66). Lines are split on
  `\n` and `\r` is trimmed, so a CR-only file (allowed by TS2.0 rule 2) is
  one line, and the first `!` comments out everything after it.
- **T7. H and G parameters are refused** (sparam.zig:78, "unknown
  option"). This is a capability limit, not a misread, but the message
  should say "H/G parameters not supported" instead of looking like a
  syntax error.
- Not a discrepancy: the reader ignores line layout, which is the right
  call given SI p.48 (see "Data" above).

---

## 2. HSPICE W-element RLGC file (`RLGCFILE=`)

### Rules

Primary: SI Ch.3 "Specifying the RLGC Model in an External File", p.106-109,
Table 4. STAR p.18-24 to 18-26 has the same text.

- The format is order-dependent: N, then the lower triangles of L, C, Ro,
  Go, Rs and Gd, in that order (SI Table 4, p.107).
- N is the number of signal conductors and must equal the element card's N.
  L and C are required. Ro, Go, Rs and Gd are optional and default to 0, but
  "if you specify an optional parameter, then you must specify all preceding
  parameters, even if they are zero" (SI p.107).
- Units per unit length: L in H/m, C in F/m, Ro in Ω/m, Go in S/m, Rs in
  Ω/(m·√Hz), Gd in S/(m·Hz) (SI Table 4).
- Each triangle is listed row-wise: `a11 / a21 a22 / a31 a32 a33`, as the
  `example.rlc` listing shows (SI p.108).
- `*` comments out the rest of the line. Numbers may be separated by
  space, tab, newline, `,`, `;`, `(`, `)`, `[`, `]`, `{` or `}` (SI p.107).
- "The RLGC file format does not support scale suffixes, such as n
  (10^-9) or p (10^-12)" (SI p.109). The file "cannot include any
  parameters" (SI p.106).
- There is no continuation character; newlines are ordinary separators.

### PEG

```peg
RlgcFile <- Sep* Number (Sep+ Number)* Sep* !.
Sep      <- [ \t\r\n,;()\[\]{}] / '*' (!'\n' .)*
Number   <- [+-]? ([0-9]+ ('.' [0-9]*)? / '.' [0-9]+) ([eE] [+-]? [0-9]+)?
```

Constraints: the first number is N, a positive integer. The count of the
rest is k·N(N+1)/2 with k from 2 to 6. Matrix k is L, C, Ro, Go, Rs, Gd in
order. A number must be followed by a separator or the end of the file, so
`1e-9n` is an error rather than `1e-9` followed by garbage.

### ESPice reader: `src/frontend/builder.zig` `parseRlgcFile` (2741-2763)

Matches the spec on comments, the separator set, ordering, the 2-6 matrix
rule and the lack of suffixes. Discrepancies:

- **R1. Numbers go through `std.fmt.parseFloat`** (builder.zig:2750), so
  `inf`, `nan`, hex floats and underscores are accepted (same as T5).
- **R2. N > 4 is reported as a malformed file** (builder.zig:2756 returns
  `InvalidParameterValue`; builder.zig:1451 logs "malformed RLGC file").
  N ≤ 4 is ESPice's `wfit.max_n` limit, not a spec rule, so the message
  misleads. The RLGCMODEL path says "N must be 1 to 4" (line 1440).

---

## 3. HSPICE digital vector file (`.vec`)

### Sources and structure

SA Ch.9 "Specifying a Digital Vector File and Mixed Mode Stimuli", p.261-271.
CR Ch.4 "Digital Vector File Commands", p.735-766: ENABLE p.736, IDELAY
p.737, IO p.739, ODELAY p.740, OUT/OUTZ p.742, PERIOD p.743, RADIX p.744,
SLOPE p.745, TDELAY p.747, TFALL p.749, TRISE p.751, TRIZ p.753, TSKIP
p.754, TUNIT p.755, VIH p.757, VIL p.758, VNAME p.759, VOH p.761, VOL
p.763, VREF p.765, VTH p.766.

A file has three parts: Vector Pattern Definition, Waveform
Characteristics and Tabular Data (SA p.261).

### Lexical rules

- Keywords are case-insensitive (SA p.261).
- `;` starts a comment, anywhere on a line (SA p.268).
- A line starting with `+` continues the previous line, as in netlists
  (SA p.268).
- Tokens are separated by whitespace. Within IO strings, masks and data
  rows, whitespace only groups digits for readability:
  `IO I I I IIII OOOO OOOO` means the same as `IO IIIIIIIIIIIIIII`
  (CR RADIX example, p.744), and `TDELAY -1.2 0 1 F 0000 00000000` is one
  mask (CR IDELAY, p.737-738).

### Statements

| Statement | Syntax and meaning | Source |
|---|---|---|
| RADIX | `RADIX d...`, each digit 1-4 is one vector of that many bits (radix 2, 4, 8 or 16). Exactly one RADIX, and it must be the first non-comment line. Digits may be glued (`radix 144` is three vectors) or spaced. | CR p.744; SA p.261 |
| VNAME | `VNAME name...`. A name is `id` or a bus `id[[hi:lo]]`. The innermost `[a:b]` is the index range and expands in the order written, MSB first. The brackets around it are kept: `a[[0:3]]` gives `a[0]`..`a[3]`, `VB<[4:1]>` gives `VB<4>`..`VB<1>`, and `vb[12:1]` gives `vb12`..`vb1`. Grouping symbols `{}`, `()` and `[]` may nest around the range. One name can span several radix digits: `RADIX 444444` with `VNAME A[[0:23]]`. With no VNAME the signals are named V1, V2, .... If there are several VNAME lines, the last wins. | CR p.759-760; SA p.271 |
| IO | `IO c...` with one of `i o b u` per vector (input, expected output, bidirectional, unused). With no IO line every vector is an input. The last IO line wins. | CR p.739 |
| TUNIT | `TUNIT [fs|ps|ns|us|ms]`, default ns. The CR also lists `tunit 999ns`, `tunit .99ps`, `tunit .99e+6ps`, `tunit 999 ns` and `tunit .99 ps` as legal, and `tunit .99eps` and `tunit .99 e+6ps` as errors. The last TUNIT wins. It scales PERIOD, the delays, SLOPE, TRISE, TFALL and the absolute times. | CR p.755-756; SA p.269 |
| PERIOD | `PERIOD t`. Tabular rows then omit the time and row k sits at k·t, starting at 0. | CR p.743; SA p.265-266 |
| TSKIP | `TSKIP`. With PERIOD, rows keep a time field that is ignored. | CR p.754 |
| ENABLE | `ENABLE [~]sig mask`. Names the controlling input (radix 1) for bidirectional bits. Every `b` vector needs one. | CR p.736 |
| OPTION CBC | `OPTION CBC`. Context-based direction of `b` vectors: 0, 1 or Z makes it an input; H, L, U or X an output. | SA p.267-268 |
| TDELAY / IDELAY / ODELAY | `KEY t [mask]`. TDELAY applies to inputs and outputs. IDELAY and ODELAY are the input and output delays of bidirectional bits; HSPICE ignores IDELAY on outputs and ODELAY on inputs, with a warning. Default 0. | CR p.737-741, 747-748; SA p.266-267 |
| SLOPE | `SLOPE t [mask]`, the rise and fall time of inputs. "If you do not specify the SLOPE command, the default slope value is 0.1 ns." | CR p.745 |
| TRISE / TFALL | `KEY t [mask]`. Override SLOPE for inputs. | CR p.749-752 |
| OUT / OUTZ | `OUT r [mask]`, series resistance of inputs in Ω, default 0. | CR p.742 |
| TRIZ | `TRIZ r [mask]`, the impedance of an input in state Z, default 1000M. Suffixes such as `15.1Meg` are allowed. | CR p.753; SA p.269 |
| VIH / VIL | Input high and low levels, defaults 3.3 and 0. | CR p.757-758; SA p.270 |
| VOH / VOL | Output high and low thresholds. The text gives defaults of 2.64 and 0.66; the argument tables say 2.66 and 0.64. "If you do not define either VOH or VOL, HSPICE uses VTH (default or defined)." | CR p.761-763; SA p.270 |
| VTH | `VTH v [mask]`, output threshold, default 1.65. | CR p.766; SA p.270 |
| VREF | `VREF name [mask]`, the reference node of input sources, default 0. The CR syntax line omits the mask, but its examples use one. | CR p.765 |

Masks have one hex digit per radix digit, and the digit's low bits (MSB
first) select that vector's bits (CR TFALL and TRISE examples, p.749-752).
With no mask, the statement applies to every signal it is meaningful for.

`.PARAM` names may stand for the values of PERIOD, the delays, SLOPE,
TRISE, TFALL, OUT, OUTZ, TRIZ, VIH, VIL, VOH, VOL and VTH (SA p.268-270).
The time group takes plain numbers in TUNIT units, so `.param p=10ns` is
read as 1e-8 ns. OUT and TRIZ follow HSPICE number syntax.

### Tabular data

- A row is `[time] value...`, with one digit per radix digit (SA p.262).
  Rows must be in chronological order.
- Input states (SA Table 15, p.263): `0`, `1`, `X`/`x` and `U`/`u` (drive
  to 0); `Z`/`z` (high impedance through TRIZ); `L` and `H` (resistive drive
  through OUT).
- Expected-output states (SA Table 16, p.263-264): `0`, `1`, `X`/`x` and
  `U`/`u` (don't care), and `Z`/`z` ("Expect HIGH IMPEDANCE (don't care)").
- Verilog-sized values: `<size>'<b|o|h><digits>`, where X and Z fill 1, 3 or
  4 bits. An MSB of 0, X or Z extends with itself; an MSB of 1 extends with
  0 (SA p.264-265).

### PEG (after continuation joining and `;` stripping)

```peg
VecFile   <- (WS? Line? EOL)* !.
Line      <- Radix / Vname / Io / Tunit / Period / Tskip / Enable / Cbc
           / Wave / Vref / DataRow
Radix     <- 'RADIX'i (WS [1-4]+)+
Vname     <- 'VNAME'i (WS VName)+
VName     <- Ident Group?
Group     <- Open* '[' Int ':' Int ']' Close*   # innermost [a:b] is the range
Open      <- [[{(<]
Close     <- [\]})>]
Io        <- 'IO'i (WS [iobuIOBU]+)+
Tunit     <- 'TUNIT'i WS (Number WS?)? TimeUnit !Word
TimeUnit  <- [fFpPnNuUmM] [sS]
Period    <- 'PERIOD'i WS Value
Tskip     <- 'TSKIP'i !Word
Enable    <- 'ENABLE'i WS '~'? Ident Mask
Cbc       <- 'OPTION'i WS 'CBC'i
Wave      <- WaveKey WS Value Mask?
WaveKey   <- ('TDELAY'i / 'IDELAY'i / 'ODELAY'i / 'SLOPE'i / 'TRISE'i
           / 'TFALL'i / 'OUTZ'i / 'OUT'i / 'TRIZ'i / 'VIH'i / 'VIL'i
           / 'VOH'i / 'VOL'i / 'VTH'i) !Word
Vref      <- 'VREF'i WS Ident Mask?
Mask      <- (WS [0-9a-fA-F]+)+
DataRow   <- (Number WS)? State (WS? State)*
State     <- Verilog / [0-9a-fA-FxXzZuUlLhH]+
Verilog   <- Int "'" [bBoOhH] [0-9a-fA-FxXzZ_]+
Value     <- Number / Ident                     # Ident: a .PARAM name
Number    <- SpiceNumber                        # TRIZ 15.1Meg: suffixes allowed
Ident     <- [A-Za-z_] [A-Za-z0-9_]*
Word      <- [A-Za-z0-9_]
WS        <- [ \t]+
EOL       <- '\r'? '\n'
```

Keywords come before `DataRow` in the ordered choice. That matters under
PERIOD, where a data row can start with a letter (`a`, `x`, `h`).

Constraints outside the PEG:

1. RADIX is the first statement and appears exactly once.
2. VNAME names consume bits in order. A bus covers |hi − lo| + 1 bits and a
   plain id one vector, and the total must equal the bits RADIX declares.
3. IO and every mask carry one character per radix digit, after whitespace
   is removed.
4. A data row carries one state digit per radix digit, plus a leading time
   unless PERIOD is set without TSKIP. Each digit is valid in its radix, and
   a Verilog value fills a whole vector.
5. Row times increase.

### ESPice reader: `src/frontend/vec.zig` `expand`

The module comment lists what it does not read: IO `b`, ENABLE, OPTION CBC,
Z/L/H inputs, nonzero OUT, Verilog values and `.param` names. These are
outside that list and differ from the manual (all except V7 confirmed by
running `zig-out/bin/espice` on small files):

- **V1. VNAME names are matched to RADIX tokens, not to bits**
  (vec.zig:83, 91-100). `radix 11` with `vname a b` fails, and so do the
  CR's own examples `RADIX 1 1 4 1234 1111 1111` with 15 names (p.744) and
  `radix 144` with `vname a x[[3:0]] y[[3:0]]` (p.736). Whitespace in RADIX
  carries no meaning in the manual.
- **V2. A second RADIX line adds vectors** (vec.zig:79-89). The CR allows
  one RADIX, as the first non-comment line. Only RADIX after data rows is
  refused.
- **V3. Missing VNAME is an error** (vec.zig:169). The CR defaults the
  names to V1, V2, ....
- **V4. VNAME grouping is limited to `[a:b]` and `[[a:b]]`**
  (vec.zig:206-217). `VB<[4:1]>` and `a{[3:0]}` fail, though the CR shows
  them (p.760). The doc comment at vec.zig:204 says `name[hi:lo]` expands
  to `name<hi>`, but the code (correctly, per SA p.271) produces `name12`
  with no brackets.
- **V5. TUNIT with a multiplier is refused** (vec.zig:110-112).
  `tunit 2 ns` and `tunit 999ns` are legal per CR p.755-756.
- **V6. IO `u` (unused) is refused** (vec.zig:106).
- **V7. The SLOPE default is in the wrong unit** (vec.zig:25-28). The code
  uses 0.1 time units, and its comment says the manual gives no default.
  CR p.745 gives 0.1 ns, an absolute time, so a file with `tunit ps` gets
  0.1 ps edges instead of 100 ps.
- **V8. The default output threshold is wrong** (vec.zig:171). With no
  VTH line, `.dout` gets the VOL/VOH pair (0.66/2.64). The CR (p.761, 763)
  says VTH (1.65) applies unless VOH or VOL is given. The code also prefers
  VTH whenever it is given, even alongside VOH or VOL.
- **V9. An expected output `Z`/`z` is refused** (vec.zig:153-155). SA
  Table 16 makes it don't-care, like X and U.
- **V10. TSKIP is refused, and the module comment does not list it**
  (vec.zig:145-151).
- **V11. Numbers go through `std.fmt.parseFloat`** (vec.zig:248-250), so
  `inf`, `nan` and hex floats are accepted and HSPICE scale suffixes are not.
  The CR's `TRIZ 15.1Meg` (p.753) only gets through because TRIZ values are
  never parsed (vec.zig:143). Whether VIH or the delays may carry suffixes
  is not stated (open question 10).

---

## 4. HSPICE `.data`: inline blocks and external files

### Card syntax

From CR `.DATA`, p.64-70:

```
.DATA datanm pnam1 [pnam2 ...]          inline
+ pval1 [pval2 ...]
.ENDDATA

.DATA datanm MER                        concatenated files
+ FILE='f1' p1=col [p2=col ...]
+ [FILE='f2' p1=col ...] ... [OUT='fileout']
.ENDDATA

.DATA datanm LAM                        column-laminated files (HSPICE only)
+ FILE='f1' p1=col ... [FILE='f2' ...] [OUT='fileout']
.ENDDATA
```

- Lines inside the block may omit the `+`. CR Examples 2 and 3 (p.67-68)
  put the names and the values on bare lines after `.DATA vdot`, and the
  MER and LAM examples (p.69-70) write `FILE=...` lines with no `+`.
- Inline: the parameter count sets the column count. "The number of data
  values per line does not need to correspond to the number of parameters";
  values are read N at a time "however the values are formatted" (p.65-66).
  At most 50 parameters per `.DATA` (p.65).
- Names must be declared with `.PARAM` (p.65). Data names are unique.
- FILE: up to 10 files (p.64, p.70). Quotes are optional, but needed when
  the name starts with a digit (p.66).
- `col` is a 1-based column number.
- MER concatenates rows in file order. A later file that does not assign a
  parameter reuses the earlier column: `FILE='file2' p1=1` and a bare
  `FILE='file3'` both inherit `p2=3 p3=4` from file1 (p.69). Files with
  fewer columns give 0 for the missing parameters (p.69).
- LAM puts files side by side, row for row. Row and column counts may
  differ, and missing points are 0 (p.69-70).
- OUT writes the merged table as an inline `.DATA` block (p.64).
- The external data file format itself is not specified beyond "columns of
  data". The examples show whitespace-separated columns, one row per line.

### PEG (card level, after continuation joining; `+` optional inside)

```peg
DataBlock  <- '.DATA'i WS Name (WS External / Inline) EndData
External   <- ('MER'i / 'LAM'i) !Word (Sep FileGroup)+ (Sep OutSpec)?
FileGroup  <- 'FILE'i Eq FileName (Sep ParamCol)*
ParamCol   <- !('FILE'i / 'OUT'i) Ident Eq Int
OutSpec    <- 'OUT'i Eq FileName
Inline     <- (Sep Ident)+ (Sep Value)*            # names first, then values
EndData    <- Sep '.ENDDATA'i Rest
Eq         <- WS? '=' WS?
Sep        <- (WS / EOL '+'? )+
FileName   <- "'" [^']* "'" / '"' [^"]* '"' / [^ \t\r\n'"]+

ExtFile    <- (WS? Row? WS? EOL)* !.
Row        <- Cell ((WS / WS? ',' WS?) Cell)*
Cell       <- SpiceNumber
```

Constraint: in `Inline`, the value count should be a multiple of the name
count (the CR does not say what happens to a partial last row).

### ESPice reader: `src/frontend/source.zig` `appendData` (292-375); inline `.data` in `src/frontend/netlist.zig` `readBlock` (1815)

ESPice rewrites MER and LAM into an inline block. The inheritance rule,
zero fill, `+`-optional lines and quoted or bare file names all match the
CR. Differences:

- **D1. The 10-file and 50-parameter limits are not enforced.** This is
  harmless and listed only for completeness.
- **D2. FILE paths resolve only against the directory of the file that
  holds the card** (source.zig:308). `.option search` is not consulted,
  although `.include` and `.load` use it (`locate`). The CR says nothing
  either way (open question 4).
- **D3. External file cells are copied verbatim** (source.zig:313-316).
  A `*` or `$` comment line or a header row in the data file turns into
  cells, and `readBlock` then fails with a confusing UnsupportedCard. The
  CR does not cover comments in data files (open question 5).
- OUT= is refused with a message (source.zig:321-325); that is documented.

---

## 5. HSPICE `.ic0` files (`.save` / `.load`)

### Rules

- `.SAVE [TYPE=NODESET|IC] [FILE=f] [LEVEL=ALL|TOP|SELECT|NONE]
  [TIME=t]` (CR p.266-267). The default TYPE is NODESET and the default
  LEVEL is ALL.
- The file name format is `save_file.ic#` (CR p.266; SA p.18: "output_file.ic#,
  where # is 0 to 9999"). `FILE='6230_lrmf.ic'` writes `.ic0`, `.ic1`,
  ... once per `.alter` run (CR p.267 Example 3).
- `.LOAD [FILE=f] [RUN=PREVIOUS|CURRENT]`. The default is `design.ic0`,
  "where design is the root name of the design". With `FILE=design.ic`,
  RUN picks the `.ic#` per `.alter` (CR p.158-159).
- What HSPICE writes (SA Appendix B, `Example.ic0`, p.910):

```
* "simulator" "HSPICE"
* "version" "A-2008.03 32-BIT"
* "format" "HSP"
* "rundate" "15:39:17 04/07/2008"
* "netlist" "example.sp "
* "runtitle" "example hspice netlist using a linear cmos
* amplifier"
* time= 0.
* temperature= 25.0000
*** BEGIN: Saved Operating Point ***
.option
+ gmindc= 1.0000p
.nodeset
+ clamp= 2.6200
+ in= 0.
+ infilt= 2.6200
+ inv1out= 2.6200
+ inv2out= 2.6199
+ vdd= 5.0000
***   END: Saved Operating Point ***
```

  The file is plain netlist text, meant to be inlined. It uses bare node
  names with `name= value`, a `.option` card that carries `gmindc`, values
  in HSPICE number syntax (`1.0000p`, `0.`) and no `.end`. Netlist rules
  allow it: `.NODESET node1 val1 ...` and `.NODESET V(node1)=val1`
  (CR p.228), `.IC V(node1)=val1` (CR p.138), and HSPICE treats `=` as a
  separator.

### PEG (netlist subset)

```peg
Ic0File   <- (Comment / OptionCard / InitCard / Blank)* !.
Comment   <- '*' (!EOL .)* EOL
Blank     <- WS? EOL
OptionCard<- '.option'i Rest EOL Cont*
InitCard  <- ('.nodeset'i / '.ic'i) (WS Assign)* WS? EOL Cont*
Cont      <- '+' (WS? Assign)+ WS? EOL
Assign    <- ('V'i '(' Node ')' / Node) WS? '='? WS? SpiceNumber
Node      <- [^ \t\r\n=()]+
```

### ESPice: reader `source.zig` `appendLoad` (265-282), writer `espice.zig` (around 480-492)

Running the built binary showed that `.load` reads HSPICE's layout
(`.ic` + `+ a= 2.0000`) correctly, including when a `.param` has the same
name as the node. Differences:

- **L1. The default file name comes from the file holding `.load`**
  (source.zig:273, `std.fs.path.stem(path)`). When `.load` sits in an
  included file, the default is `<include stem>.ic0`. HSPICE (CR p.158) and
  ESPice's own writer (espice.zig:160, `stem(self.origin)`) both use the top
  deck's root name, so the round trip breaks.
- **L2. No `.ic#` numbering.** `FILE=design.ic` is read as the literal name
  `design.ic`, not `design.ic0`, and RUN= is accepted and ignored. This is
  documented as unsupported (source.zig:262-264); HSPICE would look for
  `design.ic0`.
- The writer emits `.nodeset v(n)=val` (or `.ic`), one card per node, with
  two `*` header lines and no `.option gmindc`. HSPICE can read that, so
  it is not a discrepancy, only a different layout.

---

## 6. ngspice `.control` blocks

From NG §2.4.5 (continuation), §12.4.3 (control mode) and §13.4.3
("Add-on to circuit file"); command list in §13.5, control structures in
§13.6:

- `.control` and `.endc` each sit on their own line. Every line between
  them is one interpreter command, `name args...`.
- `*` lines are comments (§13.4.3 example).
- `+` continuation works but lower-cases the continued text (the NG note
  under the gnuplot example in §13).
- `#` is an ordinary character, as in `vcc#branch` (§12.4.3).
- Control structures (`while`/`repeat`/`dowhile`/`foreach`/`if` ...
  `end`) nest inside the block.
- A `.control` block may live in an `.include`d file (§12.4.3).

```peg
ControlBlock <- WS? '.control'i Rest EOL (!EndC CmdLine)* EndC
EndC         <- WS? '.endc'i Rest (EOL / !.)
CmdLine      <- WS? (!EOL .)* EOL
```

ESPice (`netlist.zig` 1083-1097) reads exactly this shape: it honours
`pre_osdi` and `osdi` and warns on every other command. No discrepancy
for the syntax.

---

## Spec-vs-code discrepancies (summary)

| # | Where | What |
|---|---|---|
| T1 | sparam.zig:73 | `#MHz` (no space) drops the unit, so frequencies are read as GHz |
| T2 | sparam.zig:72-82 | Later option lines override; spec: first wins, later ignored |
| T3 | sparam.zig:72, 97+ | Option line after data accepted and applied retroactively |
| T4 | sparam.zig:91-95 | Non-ascending frequency silently ends data for any N; trailing records and noise rows unchecked |
| T5 | sparam.zig:84 | `parseFloat` accepts `nan`, `inf`, hex and `_` |
| T6 | sparam.zig:66 | CR-only line endings not recognised |
| T7 | sparam.zig:78 | H/G refused as an "unknown option" rather than as unsupported |
| R1 | builder.zig:2750 | `parseFloat` accepts `nan`, `inf`, hex and `_` |
| R2 | builder.zig:2756, 1451 | N > 4 reported as "malformed RLGC file" |
| V1 | vec.zig:83, 91-100 | VNAME names matched to RADIX tokens, not bits; CR's own examples fail |
| V2 | vec.zig:79-89 | Repeated RADIX accumulates; spec allows exactly one, first |
| V3 | vec.zig:169 | Missing VNAME is an error; spec defaults to V1, V2, ... |
| V4 | vec.zig:204-217 | Nested bus grouping (`VB<[4:1]>`) refused; doc comment misstates `name[hi:lo]` |
| V5 | vec.zig:110-112 | `TUNIT 2 ns` / `TUNIT 999ns` refused |
| V6 | vec.zig:106 | IO `u` refused |
| V7 | vec.zig:25-28 | SLOPE default 0.1 time units; CR: 0.1 ns absolute |
| V8 | vec.zig:171 | Default output check uses VOL/VOH; CR: VTH unless VOH or VOL is given |
| V9 | vec.zig:153-155 | Expected-output `Z` refused; SA: don't-care |
| V10 | vec.zig:145-151 | TSKIP refused and not listed as unsupported |
| V11 | vec.zig:248-250 | `parseFloat` accepts `nan`, `inf` and hex; suffixes refused |
| D1 | source.zig appendData | 10-file and 50-parameter limits not enforced (harmless) |
| D2 | source.zig:308 | FILE= ignores `.option search` |
| D3 | source.zig:313-316 | Comment or header lines in data files become cells |
| L1 | source.zig:273 vs espice.zig:160 | `.load` default stem is the including file's, not the design's |
| L2 | source.zig:262-282 | `FILE=x.ic` not mapped to `x.ic0` (documented) |

## Open questions

1. **Repeated option tokens in Touchstone** (`# GHz MHz S`): the spec is
   silent. Last-wins (current behaviour) or error? A grammar would have to
   pick one.
2. **Space after `#`**: the spec's examples always have one, and only the
   separation *between* parameters is specified. Accept `#GHz` (as SKRF
   does) or reject it? It must not misread it either way (T1).
3. **IDELAY/ODELAY on plain input/output vectors**: CR says IDELAY is
   ignored on outputs and ODELAY on inputs, but SA p.267 says both apply
   only to bidirectional signals. ESPice applies IDELAY to inputs. HSPICE's
   behaviour on a pure input is unverified.
4. **External `.data` and `.load` path search**: neither CR entry says
   whether `.option search` or the working directory applies. ESPice uses
   the card's directory for `.data` and `locate` (deck directory, then
   search dirs) for `.load`. `.save` writes beside the output file (SA p.18:
   "output_file.ic#"), so with `-r elsewhere/out.raw` the default `.load`
   misses the file it wrote.
5. **External data file lexis**: are comments (`*`, `$`), header rows,
   scale suffixes or `,` separators allowed? The CR shows only bare numeric
   columns.
6. **Mask digits wider than their vector** (`F` on a 1-bit vector): ESPice
   takes the low bits. The CR examples never do this, so error or ignore is
   undecided.
7. **VOH/VOL defaults**: the CR argument tables say 2.66/0.64 and the
   description text says 2.64/0.66 (SA p.270 agrees with the text). ESPice
   uses the text values.
8. **VNAME plain name on a multi-bit vector** (`RADIX 4` with `VNAME C`):
   the CR never shows it. Does it name all 4 bits `C` (an error), or expand
   to C3..C0?
9. **Touchstone 0 Hz and the noise boundary**: HSPICE's noise example
   (SI p.48) starts noise at 0 Hz after network data that also starts at 0.
   That is legal (≤ the last network frequency), but a reader that rejects
   0 Hz or uses a strict `<` (SKRF) splits the file differently.
10. **Scale suffixes in `.vec` values**: SA p.268-270 says the time group
    takes plain numbers in TUNIT units, and the CR's TRIZ examples use
    `Meg`. Nothing says whether `VIH 3.3v` or `TDELAY 1n` is legal.
