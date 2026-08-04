# The Spectre netlist language: syntax reference for a frontend

Survey date: 2026-10-17. Goal: enough of the Cadence Spectre native netlist
language (`simulator lang=spectre`, `.scs` files) to write a real frontend and
a PEG reference grammar for differential testing. Today ESPice's `spectre`
dialect (`src/frontend/lines.zig`, `spectre`) only changes tokenization
(comments, continuation, case, SI scale factors) and still parses SPICE cards.

Every rule below gives the rule, an example, a citation, and how the open
implementations differ. The section order follows the order a parser needs:
physical lines, tokens, modes and files, statements, expressions, names.

## Sources

Cadence documents (all fetched 2026-10-17; university mirrors of the vendor
PDFs, text extracted with `pdftotext -layout`). Page numbers are the printed
page numbers.

- **UG**: *Virtuoso Spectre Circuit Simulator User Guide*, Product Version
  5.1.41, July 2004. Chapter 3 "SPICE Compatibility" (pp. 41-56), chapter 4
  "Spectre Netlists" (pp. 57-78), chapter 5 "Parameter Specification and
  Modeling Features" (pp. 79-125), chapter 6 "Analyses", chapter 7 "Control
  Statements". <https://web.eecs.utk.edu/~dbouldin/protected/spectreuser.pdf>
  (the 4.4.6 edition, June 2000, is at
  <https://web.eecs.utk.edu/~dbouldin/courses/651/spectreuser.pdf>).
- **R5**: *Spectre Circuit Simulator Reference*, Product Version 5.0,
  September 2003. Component and syntax chapters; these are the `spectre -h`
  texts. <http://eece.cu.edu.eg/~fhussien/Spectre_tutorial.pdf>
- **R11**: *Virtuoso Spectre Circuit Simulator Reference*, Product Version
  11.1, September 2011. "Analysis Statements" and "Syntax" chapters.
  <https://amarketplaceofideas.com/wp-content/uploads/2015/09/Virtuoso-Spectre-Circuit-Simulator-Reference.pdf>
- **R19**: *Spectre Circuit Simulator Reference*, Product Version 19.1,
  January 2020. The newest primary text found; "Analysis Statements" and
  "Other Simulation Topics" chapters.
  <https://ee.kpi.ua/~yv/edu/ok/book/spectre_refManual.pdf>
- **K**: Kundert, *The Designer's Guide to SPICE and Spectre*, Appendix B
  "Spectre Netlist Language" (author's excerpt, pp. 357-362).
  <https://designers-guide.org/analysis/dg-spice/chB.pdf>

No newer User Guide (the "Spectre Classic Simulator, Spectre APS, Spectre X
and Spectre XPS User Guide" that R19 cross-references) was found on a public
mirror. Where R19 and UG disagree, R19 is the later word.

Open implementations (cloned 2026-10-17):

- **gnucap**: `apps/lang_spectre.cc` plus the shared line reader
  `lib/ap_construct.cc` and number parser `lib/ap_convert.cc`, savannah
  master `874f2d5` (2024-02-20). Its manual page:
  <http://gnucap.org/dokuwiki/doku.php/gnucap:manual:languages:spectre>.
- **XDM** (Xyce netlist translator): `src/c_boost/xyce/SpectreGrammar.hpp`,
  `src/c_boost/expr/spectre_arithmetic_grammar.hpp`, commit `b6394a0`
  (2023-08-11), <https://github.com/Xyce/XDM>. A line-at-a-time Boost.Spirit
  translator grammar, not a full parser.
- **NLP**: NyanCAD NetlistParse.rs, `crates/netlist-syntax/src/spectre_*.rs`,
  commit `a71091f` (2026-10-13), <https://github.com/NyanCAD/NetlistParse.rs>,
  MIT. A Rust port of the Julia `NyanSpectreNetlistParser.jl` from Cadnip.jl
  (itself descended from JuliaHub's CedarEDA parser). Lossless CST, a
  precedence-climbing expression parser, and about 150 Spectre test decks
  under `tests/corpus/spectre/` with expected CST dumps. This is the most
  complete open Spectre grammar found.
- **VACASK** (Árpád Bűrmen, EDA Lab, University of Ljubljana):
  <https://codeberg.org/arpadbuermen/VACASK>, commit `da17a59` (2026-10-15),
  `lib/dfllexer.l`, `lib/dflparser.y`, `docs/input-*.md`, `docs/cir-*.md`.
  Its native syntax is "Spectre-like" and deliberately different. When built
  with `-DCADNIP_PARSERS=ON` it reads real Spectre files through NLP (pinned
  at `d565fd3`), as includes only (`include "models.scs" lang=spectre`,
  `docs/input-include.md`).

Not found: an ANTLR or tree-sitter Spectre grammar of any substance, and
OpenVAF has no netlist parser.

## 1. Physical lines

### 1.1 Statements are lines

A newline ends a statement. Fields are separated by blanks, tabs,
punctuation or continuation characters; `=`, `(`, `)` and `:` are
significant [UG p.59]. So `r1 (a b) resistor r = 1k` and
`r1(a b)resistor r=1k` both tokenize; a PEG should treat horizontal
whitespace as insignificant between tokens and the newline as a terminator.

Divergences: VACASK also ignores newlines inside `()`, `[]` and `{}`
[VACASK `docs/input-overview.md`]. Spectre documents no such rule, and its
brace blocks (`sweep ... {`, `if (...) {`) depend on newlines being
significant inside braces.

### 1.2 Title line

The first line of the top-level netlist is the title, "used verbatim when
labeling output. Any statement you place in the first line is ignored as a
comment" [UG p.29; again UG p.50: "In both Spectre and Spice, the first line
is always the title card"]. An included file has no title line: "The first
line is not a comment title line, even in SPICE mode" [UG p.73].

UG p.50 also says Spectre recognizes a Spectre file because it "starts with
the line `simulator lang=spectre`" or ends in `.scs`, which conflicts with a
discarded line 1. Every Cadence example starts with a `//` comment and puts
`simulator lang=spectre` on line 2 [UG p.28, p.95, p.136]. See Open questions.

Divergences: NLP has no title line in Spectre mode (only a SPICE-start
`.cir` file gets one). XDM treats line 1 of the top file as title. VACASK
always has a title line. gnucap has none.

### 1.3 Comments

- `//` starts a comment to end of line, at line start or after a space
  anywhere in the line [UG p.59: "placing a space and double slash (//)
  anywhere in the line"].
- `*` as the first character starts a comment line [UG p.59: "You can also
  use an asterisk (*) to indicate a comment line. The preferred style is
  using //"]. Elsewhere `*` is multiplication.
- `/* ... */` block comments are **not documented** anywhere in UG, R5, R11
  or R19 (searched all four). Treat them as unsupported in Spectre mode.

```
// BJT ECP Oscillator
* also a comment
R1 (b1 0) resistor r=10k   // trailing comment
```

Divergences: NLP lexes `*` as a comment only when the previous token is a
newline (so `  * x` with leading blanks is not a comment) and `//` anywhere,
no space required; it also swallows `//pragma protect begin_protected` ...
`end_protected` regions [NLP `spectre_lexer.rs`, `lex_star`, `lex_slash`].
gnucap: a line starting with `*` or `//` is a comment
[`find_type_in_string`]. XDM: `//` or a leading `*`. VACASK: `//` and
`/* */`, no `*` comments (it is always an operator) [`dfllexer.l`].
**ESPice today strips `/* */` in Spectre mode** (`stripBlockComments`); that
is a VACASK-ism, not Spectre.

### 1.4 Continuation

- A backslash as the last character of a line joins the next line; this is
  the preferred style [UG p.59; examples UG p.71, p.212].
- A `+` at the start of the next line also continues the statement in
  Spectre mode [UG p.59: "You can use a plus sign (+) to indicate line
  continuation at the beginning of the next line"]. PDK-style libraries in
  the Cadence docs use it [R11 p.352-353, R19 p.498 sample library; UG
  p.104-105].
- A statement cannot start in one file and end in another [UG p.73; R19
  p.493].
- Inside `include`, "a space and then a backslash-escaped newline" may sit
  between `include` and the file name [UG p.73].

```
model NPNbjt2 bjt \
    type=npn is=3.38e-17 bf=205
parameters RSHSP=200 RSHPI=5k
+   SPDW=0 SNDW=0
```

Divergences: gnucap's reader accepts both forms for every language
[`ap_construct.cc` `getlines`]. NLP folds `\`+newline in the lexer and a
leading `+` in the token layer (its module comment says "no `+`
continuation", but `get_next_action` does fold it). VACASK: `\` only.

### 1.5 C preprocessor lines

`#include "file"` and `#define` are handled by CPP only when Spectre runs
with `-E`; otherwise `#include` is an error [UG p.72-73; R19 p.493]. Example
`#define PROCESS_CORNER TYPICAL` [UG p.112]. A frontend can reject `#` lines
or run a preprocessor pass first.

### 1.6 Encrypted blocks

`protect`/`unprotect` (also `prot`/`unprot`) delimit encrypted regions in
Spectre mode, `.protect`/`.unprotect` in SPICE mode; `visible`/`invisible`
expose operating points [R11 p.332-334]. Out of scope beyond "skip with a
diagnostic".

## 2. Tokens

### 2.1 Case

Spectre mode is fully case-sensitive, and all keywords are lower case
[UG p.59; UG p.50; K p.358]. SPICE mode lowercases everything except
quoted strings [UG p.59]. `myModel` and `mymodel` are two different models
in Spectre mode [UG p.50].

`simulator lang=spectre insensitive=yes` marks models and subcircuits
converted from SPICE so that lookups compare in lower case [UG p.50, p.52].

### 2.2 Names (identifiers)

Rules [UG p.60]:

- Except for node names, names start with a letter or underscore. Node
  names may also be integers.
- If a node name is an integer, leading zeros are significant (`007` is not
  `7`).
- Then any number of letters, digits and underscores.
- No other characters (blanks, punctuation, `\`, `+`, `-`, `//`, `*`)
  unless escaped with a backslash. The exception is `!`, as in `vdd!`.
- Names longer than 200 characters are allowed [UG p.50].

Escapes [UG p.62]: a backslash before any printable ASCII character,
including space and tab, puts that character in the name. Old libraries can
also use the shape "digits, then letters/underscores/escapes, then a digit,
then underscores/digits/escapes", for names like `\2N2222`. Schematic bus
bits come out of ADE as escaped names such as `net\<3\>`; that use follows
from the same rule.

```
Q1 (c b e) \2N2222
I0 (a\<0\> b) inv
vdd! is a node name; so is 007, distinct from 7
```

Divergences: NLP identifier chars are letters, digits, `_`, `$`, `!`; start
is letter or `_` (or `$`); a `\` not followed by a newline starts an escaped
identifier that runs to the next whitespace [NLP `spectre_lexer.rs`]. Note
the consequence it documents: `a!=b` lexes as `a!` `=` `b`. XDM: any run of
characters except `:;(){}[],= \t` and `//` [`SpectreGrammar.hpp`
`raw_identifier`]. VACASK: `[A-Za-z_$][A-Za-z0-9_$]*` plus single-quoted
identifiers (`'3.3V'`, `''` escapes a quote) [VACASK
`docs/input-identifiers.md`]; no `!`, no backslash escapes.

### 2.3 Reserved words

Netlist keywords cannot be instance, subckt, model or function names;
built-in constants cannot be node, instance, subckt, model, function or
parameter names [R11 p.349; R19 p.495]. R19's list (p.495-497):

- Constants: `M_1_PI M_2_PI M_2_SQRTPI M_DEGPERRAD M_E M_LN10 M_LN2
  M_LOG10E M_LOG2E M_PI M_PI_2 M_PI_4 M_SQRT1_2 M_SQRT2 M_TWO_PI P_C
  P_CELSIUS0 P_EPS0 P_H P_K P_Q P_U0`.
- Netlist keywords: `altergroup correlate else end ends export for function
  global ic if in inline input invisible library local march model nodeset
  out output parameters paramset plot print pwr real return save sens
  statistics subckt to truncate vary visible`.

R11 also lists `prot`, `unprot`; UG p.60-61 also lists the function names
(`abs`, `sin`, ...) and `vary`, and adds "do not use the name of an
analysis (such as `tran`) or built-in primitive (such as `resistor`)".

Reserved parameter names (cannot be declared): `temp tnom scale scalem freq
time` [R11 p.361; R19 p.508].

From release 5.0.32, instances, models, nets, subckt parameters, enum
values and netlist parameters may share a name ("multiple namespace")
[UG p.61], but R11 p.360 and R19 still say a parameter name must not match
an instance name. Keywords are only reserved by position: `model`, `subckt`
etc. are recognized as the first token of a statement; analysis and control
type names (`tran`, `options`, `info`) only as the second token.

Divergences: NLP keywords double as identifiers wherever an identifier is
expected (`tran tran tran=tran` lexes and parses) [NLP lexer test table].
VACASK reserves its own words only at line start [VACASK
`docs/input-reserved.md`].

### 2.4 Numbers and scale factors

Literal forms [UG p.83-84]:

- Integer or decimal: `5`, `3.26`, `.5`.
- Exponent: `2.65e3`, `5.32e-4`, `1E-14`, `3.04E6`.
- Scale factor: `5u`, `3.26k`, `4.2m`.
- "You cannot use both scale factors and exponents in the same parameter
  value" [UG p.83]: in `1.234E-3p` the `p` is ignored.

Spectre-mode (SI) scale factors, case-sensitive [UG p.84; K Table B.1]:

| Suffix | Factor | | Suffix | Factor |
|---|---|---|---|---|
| `T` | 1e12 | | `%` | 1e-2 |
| `G` | 1e9 | | `c` | 1e-2 |
| `M` | 1e6 | | `m` | 1e-3 |
| `K` | 1e3 | | `u` | 1e-6 |
| `k` | 1e3 | | `n` | 1e-9 |
| `_` | 1 | | `p` | 1e-12 |
| | | | `f` | 1e-15 |
| | | | `a` | 1e-18 |

K Table B.1 also lists `P` = 1e15; UG 5.1.41 omits it. Lower-case `g` and
`t` are not SI factors.

Units [UG p.84]: letters after a scale factor are ignored units. Units
without a scale factor are rejected: `c=1pf` and `l=1uH` are fine,
`r=50Ohms` is an error, write `r=50_Ohms`. A consequence: `1meg` is `1m`
with unit `eg`, i.e. 1e-3, not 1e6. `1.0M` is 1e6 in Spectre mode and 1e-3
in SPICE mode [UG p.84 Caution].

SPICE-mode factors, case-insensitive: `t g meg k m mil u n p f`; any other
suffix is treated as 1.0 [UG p.84; K Table B.2].

Data files (PWL `file=`, noise files, S-parameter files) do not accept
scale factors [UG p.83, p.75].

Divergences:

- gnucap SI mode: `M`=1e6, `m`=1e-3, `P`=1e15, but accepts both cases for
  `u n f a k g t`; after an exponent no suffix is read; letters after the
  suffix are skipped, so `1meg` = 1e-3; `%` = 1e-2; `_` and `c` are not
  handled [`ap_convert.cc`].
- NLP lexes a number greedily with every following identifier char
  (`23pf`, `0.3MHz`, `6_Ohms`, `1N3064` are each one NUMBER token) and
  leaves scaling to later stages; also accepts Verilog-style `'h` bases.
- XDM: suffix set `PTGMKkcmunpfa` (case-insensitive in some branches) then
  an optional unit from `fHsV` only.
- VACASK: `meg` and `x`/`X` = 1e6, `mil` = 25.4e-6, `k`/`K`, no `%`, `c`,
  `P` or `_`; `inf`/`nan`; hex `0x..`; an integer cannot have leading zeros
  [VACASK `docs/input-numbers.md`, `dfllexer.l`]. VACASK's `1meg` is 1e6.
- ESPice today (`lines.zig` `spectre.parseNum`): matches UG plus `P`, and
  `1meg` = 1e-3 (tested). `_` falls through to scale 1, which is right.

### 2.5 Strings

Strings are double-quoted and are required for file names and labels
[UG p.80, p.120, p.135]. Examples: `file="Spara.data"`, `parameters
b="bottom"` [R11 p.315], `message="center frequency must be ..."` [UG p.99].
A backslash escapes a quote inside a string:
`export slewrate=oceanEval("slewRate(v(\"vout\"),10n,t,30n,t,10,90 )")`
[UG p.174-175]. Include file names expand `~`, `$VAR`/`${VAR}` and `%`
codes [R19 p.493].

Divergences: NLP strings are `"`-only with `\` escaping the next char.
VACASK: C-style escapes plus `<<<MARK ... >>>MARK` heredocs.

### 2.6 Punctuation and operators

`( ) [ ] { } = : , . ! ? ;` plus the expression operators of section 6.
`.` is the hierarchy separator in node and instance names (`X1.n3`), `:`
separates an instance from a terminal or output parameter (`M1:d`,
`L1:1`, `D3:oppoint`), `[...]` is a vector, `{...}` a block.

## 3. Language modes and files

### 3.1 `simulator lang=`

```
simulator lang=spectre [insensitive=yes|no]
simulator lang=spice
```

- Takes effect immediately and stays in effect until the end of input or
  the next `simulator lang` [UG p.53]. It "affects all subsequent input
  regardless of whether the command is part of an if statement" [UG p.53].
- It may appear anywhere an instance statement may; it does not have to be
  first [UG p.53]. In SPICE mode it is still written without a dot [UG p.53
  example].
- Spectre syntax in SPICE mode, or SPICE syntax in Spectre mode, is an error
  [UG p.53, p.52].
- The default is SPICE mode unless the file name ends in `.scs` [UG p.53,
  p.50; R19 p.493].
- Spectre-mode statements may name models and subcircuits defined by SPICE
  `.model`/`.subckt` in a SPICE region [UG p.52].
- "Parameter names must be lowercase if you want to instantiate components
  from SPICE mode" [UG p.97].

Divergences: gnucap accepts `simulator lang=...` in Spectre mode and
`.simulator lang=spectre` in SPICE mode (its test decks use both)
[`tests/lang_spectre.1.gc`]; it maps `simulator` to its `options` command.
NLP hands off to its SPICE parser at `simulator lang=spice` and back at the
next `simulator lang=spectre`.

### 3.2 What "SPICE mode" means

Spectre's SPICE reader accepts SPICE2G6 (per the SPICE 2G User's Guide),
SPICE3e batch syntax, and "common extensions found in other simulators such
as PSPICE and HSPICE" [UG p.41, p.51]. Documented resolutions [UG p.56]:

- Node `00` is a string (SPICE3), not zero (SPICE2).
- Leading spaces are ignored (SPICE2), not a comment (SPICE3).
- `.lib` is the HSPICE section include, not the PSPICE model search file.
- `.alter` follows SPICE2 (relisted lines), not SPICE3.
- A parameter given on a subcircuit instance wins over a global parameter.
- Spectre parameters may be appended to SPICE cards:
  `Rload out 0 1k isnoisy=no` [UG p.54].
- `*spectre: <spectre text>` lines are Spectre input hidden from other
  SPICE simulators [UG p.54-55].
- Parameters passed into a subckt must be declared on the `.subckt` line
  [UG p.55].

R19 adds `pspice_include "file"` (`.pspice_include` in SPICE mode), which
reads the file in PSPICE mode with PSPICE defaults [R19 p.511].

For ESPice, "SPICE mode" in a Spectre deck is closest to its existing
`hspice` dialect.

### 3.3 `include`

```
include "filename"
include "filename" section=sectionName
```

- The file name must be quoted; relative paths resolve against the
  including file's directory, then `-I` paths [UG p.73; R19 p.493].
- The included file starts in SPICE mode unless it ends in `.scs` or starts
  with `simulator lang=spectre`; the including file's mode is restored at
  the end [UG p.72-73; R19 p.493].
- Includes nest [UG p.73].

Divergences: VACASK resolves including-dir, then CWD, then
`SIM_INCLUDE_PATH`.

### 3.4 `library` / `section`

The library definition lives in a separate file [UG p.75; R19 p.498: "The
definition of a library section is prohibited in the netlist"]. One library
per file, any number of sections [R11 p.352; R19 p.498].

```
library corner_lib
section tt
model nch bsim3v3 type=n mobmod=1 capmod=2 version=3.1
+ xj=1.7e-7 vsat=7.99e4
endsection
section ss
...
endsection
endlibrary
```

- `endsection [name]` and `endlibrary [name]`; the optional names must
  match [UG p.75-76; R11 p.352]. (UG p.76 prints the closer as
  `library [libraryName]`, a typo for `endlibrary`, which its own example on
  p.115 uses.)
- Section bodies are any statements; each section must itself switch to
  Spectre mode unless the file is `.scs` [R19 p.498].
- References nest; `include ... section=` may appear inside `altergroup`
  [UG p.76].

Divergences: VACASK has `section`/`endsection` but no `library` wrapper;
NLP parses `library`, `section` and `include ... section=`.

### 3.5 `ahdl_include`

`ahdl_include "file.va"` loads a Verilog-A (or SpectreHDL) module whose
name then works as an instance master [UG p.72; R19 p.541]. VACASK's
equivalent is `load "x.osdi"`.

## 4. Statement forms

### 4.1 Dispatch

Spectre statements are identified by position, not by a leading letter:

1. First token is a keyword: `simulator`, `include`, `ahdl_include`,
   `library`, `section`, `endsection`, `endlibrary`, `model`, `subckt`,
   `inline subckt`, `ends`, `parameters`, `global`, `save`, `ic`,
   `nodeset`, `real` (function), `if`, `statistics`, `prot`/`unprot`.
2. Otherwise the first token is a **name**, and the statement is decided by
   what follows:
   - an analysis or control type keyword (`dc ac tran noise xf sp pz pss
     pac pnoise pxf ... sweep montecarlo alter altergroup check checklimit
     info options set shell paramset paramtest assert ...`) as the second
     token, or after a parenthesized node list for analyses that take nodes;
   - otherwise it is an instance (`name nodes master params`).

UG groups these as instance, analysis, control and model statements
[UG p.58]. Analyses and control statements use the instance shape with a
type keyword as the master [UG p.66, p.69].

Divergences: gnucap decides with `find_type_in_string`: keyword first, else
after `)`, else the word before the first `name=`, else the second word.
NLP does the same split with a dry-run parse (`parse_other`,
`count_bare_units`). Both treat analyses as named statements.

### 4.2 Instance

```
name [(]node1 ... nodeN[)] master [param=value ...]
```

[UG p.62; R11 p.315 for the same shape with `analogmodel`]

- Parentheses around the node list are optional [UG p.62; K p.360].
- The first letter of `name` carries no meaning [UG p.62].
- `master` is a built-in primitive, a model, a subcircuit, or an AHDL
  module [UG p.63]. `analogmodel modelname="x"` picks the master from a
  string parameter [R11 p.315].
- Parameters may also be wrapped in optional parentheses: `(c=10E-12)`
  [UG p.63].
- Zero nodes are legal: `x1 s1 p4=8` instantiates a port-less subckt
  [UG p.85, p.87]; `k1 mutual_inductor coupling=0.9 ind1=l1 ind2=l2` takes
  no nodes [R5 p.577]; `checkFreqs paramtest errorif=...` has no terminals
  [UG p.99].
- Without parentheses, the master is the last bare word before the first
  `name=` (or the last word on the line). Both gnucap and NLP use exactly
  this rule; Cadence states no rule, but nothing else is consistent with
  `Q8 vcc 1 NPNdiode` [UG p.137] and `x1 s1 p4=8`.
- Nodes may be hierarchical (`c1 xa.mid 0 capacitor c=0.2p`), forward
  references are allowed, and relative paths resolve from the current scope;
  hierarchical *terminals* in the node list are not supported [UG p.63-64].
- Every subckt has an implicit `m` (multiplicity) parameter; `m` may be
  any positive real; it is instance-only, never a model parameter [UG p.63,
  p.65]. Declaring `m` on a `parameters` line is an error and `m` cannot be
  used in expressions inside the subckt [R11 p.380; R19 p.533].

```
C1 (2 3) capacitor c=10E-12F
Q1 (o1 i1 b2) npn
M1 (4 pin 1 1) nmos w=402.4u l=7.6u
Ro   (d     c)   resistor   r=4k   m=4
Q14 vcc 13 15 vee NPNbjt
x1 (out 0) LoadOutput m=5
```

Divergences: VACASK spells multiplicity `$mfactor`, which a subckt must
declare and forward [VACASK `docs/cir-mfactor.md`, `input-include.md`];
VACASK lets subckt and OSDI instances leave trailing terminals unconnected
(they become internal nodes) [VACASK `docs/cir-instance.md`]; gnucap grounds
missing nodes with a warning [`parse_ports`].

### 4.3 Built-in primitives used by typical netlists

Node order and key parameters, from the `spectre -h` text in R5 (page of
the "Instance Definition"):

| Master | Nodes | Key parameters | R5 |
|---|---|---|---|
| `resistor` | `1 2 [0]` | `r l w m scale tc1 tc2 trise isnoisy` | p.629 |
| `capacitor` | `1 2` | `c w l m scale tc1 tc2 trise ic area` | p.283 |
| `inductor` | `1 2` | `l r m trise ic isnoisy` | p.373 |
| `vsource` | `p n` | see below | p.682-686 |
| `isource` | `p n` | same waveform set as vsource | p.380 |
| `vcvs` | `p n ps ns` | `gain m min max abs` | p.681 |
| `vccs` | `sink src ps ns` | `gm m min max abs` | p.678 |
| `ccvs` | `p n` | `rm probe port probes ports m` | p.288 |
| `cccs` | `sink src` | `gain probe port probes ports m` | p.286 |
| `mutual_inductor` | none | `coupling ind1 ind2` | p.577 |
| `port` | `p n` | `r num type mag ...` (vsource waveforms) | p.602 |
| `switch` | `t0 t1 ...` | | p.643 |
| `iprobe` | `in out` | | |
| `diode` | `a c` | via `model x diode ...` | |
| `bjt`, `vbic`, ... | `c b e [s]` | via model | |
| `mos1..3`, `bsim3v3`, `bsim4`, `bsimsoi`, `bsimcmg`, `psp103`, `hisim2`, ... | `d g s b` | via model, `w l ...` | |

R11 p.38-39 lists every primitive allowed in an `altergroup` (`bjt`,
`bsim3v3`, `bsim4`, `bsimcmg`, `hisim2`, `psp103`, `vbic`, `resistor`,
`vsource`, ...), which doubles as a master-name list.

vsource/isource waveform parameters [R5 p.682-686]:

- `dc` (default 0), `type=dc|pulse|pwl|sine|exp` (default `dc`), `delay`.
- Pulse: `val0 val1 period rise fall width`.
- PWL: `wave=[t0 v0 t1 v1 ...]` or `file="name"`, `offset scale stretch
  allbrkpts pwlperiod twidth`.
- Sine: `sinedc ampl freq sinephase ampl2 freq2 sinephase2 fmmodindex
  fmmodfreq ammodindex ammodfreq ammodphase damp`.
- Exp: `val0 val1 td1 tau1 td2 tau2`.
- Small signal: `mag phase xfmag pacmag pacphase`. Noise: `noisefile
  noisevec`. Also `m tc1 tc2 tnom`.
- "If you do not specify the DC value, it is assumed to be the time=0 value
  of the waveform" [R5 p.686]. Parameters of several waveform types may
  coexist; `type` selects, and `alter` can switch it [R5 p.686].

```
vpulse1 (1 0) vsource type=pulse val0=0 val1=5 period=100n rise=10n fall=10n width=40n
vpwl1 (1 0) vsource type=pwl wave=[1n 0 1.1n 2 1.5n 0.5 2n 3 5n 5] pwlperiod=5n
v4 in 0 vsource type=pwl file="test.in"
Vt1 (t1 nvg) vsource mag=0
```

Behavioral elements [R11 p.317-322]: `bsource` with one of `c= g= i= l=
phi= q= r= v=`; `resistor`, `capacitor`, `inductor` accept the same
behavioral expressions directly. Behavioral expressions may use `$time`,
`v(a)`, `v(a,b)`, `i("inst:index")`, `ddt()`, `idt()`.

```
res  (n1 n2) resistor r=100*(1+(1/2)*v(n1,n2))
vsrc (n1 n2) bsource v=10.0*sin(2*pi*freq*$time)
cccs1 (n3 n4) bsource i=gain*i("vsrc:0")
```

Divergences: VACASK `vsource` takes `type="sine"` as a string
[VACASK `docs/cir-instance.md`]; gnucap's Spectre mode rejects SPICE-style
positional source values [gnucap manual page].

### 4.4 `model`

```
model name master [param=value ...]
```

[UG p.71; K p.360]. `master` is a primitive or an AHDL module. Parameters
may be expressions of netlist parameters [UG p.72]. A parameter that is
both an instance and a model parameter acts as a default when given on the
model and overrides when given on the instance [UG p.72].

```
model NPNbjt bjt type=npn bf=100 js=0.1fA
model dnp diode is=3.1e-10 n=1.12 cjo=3.1e-8 vj=.914
model fast_1x1 mos3 type=n vto=(temp >= 27_C) ? 0.8 : 0.77
```

Model groups (binning, "auto model selection") [UG p.108]: the opening
brace ends the `model` line, each member is `label: params`, selection uses
`lmin <= l < lmax` and `wmin <= w < wmax`, first match wins, and the chosen
model is `ModelName.label`:

```
model ModelName ModelType {
1:     lmin=2 lmax=4 wmin=1 wmax=2 vto=0.8
2:     lmin=1 lmax=2 wmin=2 wmax=4 vto=0.7
}
```

Divergences: XDM parses group members as `binned_model_dir` (`digits :
params`). NLP accepts `model` with no master and bare flag parameters
(`model RMOD resistor tc1 5`, a relaxation it labels "Rust-led"); neither is
documented by Cadence.

### 4.5 `subckt` and `inline subckt`

```
[inline] subckt Name [(] node1 ... nodeN [)]
[parameters name1=value1 ... nameN[=valueN]]
  instance, model, ic, nodeset, analysis, control statements,
  nested subckt definitions
ends [Name]
```

[UG p.94, p.99; R11 p.380-382; R19 p.533]

- Port parentheses are optional; empty parens `subckt sweepVcc()` and no
  ports at all (`subckt s1`) both occur [UG p.138, p.85].
- Subckt parameters may omit a default: `parameters R MULT=1`,
  `parameters WE LE MULT=1 dIS=0 dBF=0` [UG p.105; R11 p.380: "referred to
  by name, optionally followed by an = sign and a default value"].
- Parameters are declared "on the first line of a subcircuit definition"
  (after the header) [UG p.85], but multi-line `parameters` with `+` or
  repeated `parameters` lines are used in Cadence's own examples [UG p.104].
- Models and subckts defined inside are local to it and shadow outer
  names [UG p.96]. A model whose parameters depend on subckt parameters is
  expanded per instance and named `<flattened subckt>.<model>` [UG p.97].
- Subckts may contain analyses and control statements; calling the subckt
  runs them [UG p.137-139].
- `inline`: the member whose name equals the subckt name takes the caller's
  name instead of a hierarchical one; an inline subckt that holds only a
  model of the same name exports a parameterized model one level up
  [UG p.99-104; R11 p.381-383].

```
subckt twisted (p1 n1 p2 n2)
parameters zodd=50 zeven=50 veven=1 vodd=1 len=0
odd (p1 n1 p2 n2) tline z0=zodd vel=vodd len=len
ends twisted

inline subckt bjtmod (c b e s)
parameters le=1u we=2u area=le*we trise=0
model mod1 bjt type=npn bf=100+(le+we)/2*(area/1e-12)
bjtmod (c b e s) mod1 trise=trise
ends bjtmod
```

Divergences: VACASK subckt parameters must all have an expression, and an
instance cannot override a "dependent" (non-constant) parameter [VACASK
`docs/cir-subckt.md`]; Spectre lets a caller override any declared subckt
parameter. gnucap reads only `subckt` (no `inline`); its body loop ends at
`ends`. NLP requires a plain identifier as subckt name.

### 4.6 `parameters`

```
parameters p1=1 p2=2 c10=c1+c2
```

[UG p.85; R11 p.359; R19 p.506]

- Allowed at top level and inside subckts. Top-level parameters must have
  values; subckt parameters optionally have defaults [R19 p.506].
- Values may be constants, expressions, references to earlier parameters,
  and strings (`parameters b="bottom"`) [R11 p.315].
- "Parameters must be declared before they are used" [UG p.85; R19 p.506].
  A subckt defined before a top-level parameter must not reference it;
  altergroups need all parameters declared before subckt definitions
  [UG p.85].
- Inheritance: a subckt sees every parameter of its enclosing scopes; a
  local redeclaration shadows, and an uninstantiated override uses the local
  default, not the parent value [UG p.85-86; R19 p.506].

```
simulator lang=spectre
parameters p1=1 p2=2
r2 1 0 resistor r=p1+p2          // 3
x1 s1 p4=8
subckt s1
parameters p1=4 p3=5 p4=6
r2 1 0 resistor r=p2             // inherited: 2
r5 1 0 resistor r=p1+p2/p3       // 4.4
ends
```

Divergences: NLP accepts bare flag parameters (`parameters swap=0 ch_pwr0
ch_pwr1`) and a `;` after a value (`-6.4u ;`), both found in real files
[NLP `parse_parameter`]. VACASK evaluates constant defaults first and
dependent parameters in order, regardless of declaration order
[VACASK `docs/cir-subckt.md`].

### 4.7 Functions

```
real myfunc( real a, real b ) {
return a+b*2+sqrt(a*sin(b));
}
```

[UG p.92-93; R11 p.339; R19 p.481]

- Top level only; real arguments and result only; the keyword `real` types
  every argument; a single `return` statement; the body may reference
  arguments, other functions, `temp` and `tnom`, but no netlist parameters.
- Declared before use. Defining a built-in's name overrides it with a
  warning.

Divergences: NLP requires the newline layout of the Cadence example (`{`,
newline, `return expr [;]`, newline, `}`); whether Spectre accepts a
one-line body is not documented.

### 4.8 `global`

```
global gnd vdd vss
global 0 vdd!
```

The first name is the ground node; without a `global` statement ground is
`0`; ground is always global [R5 p.871; R11 p.340; R19 p.482]. Older texts
allow at most one `global`, and it must be the first statement (after an
optional `simulator lang=spectre`) [R5 p.871; R11 p.340; UG p.46: "Multiple
global statements cause fatal errors"]. R19 p.482: "Multiple global
statements are supported." UG examples put `global` before `simulator
lang=spectre` [UG p.74, p.95, p.136].

Divergences: VACASK adds a `ground` directive (several names may be
ground) and keeps `0` as ground; its `global` does not name ground
[VACASK `docs/cir-nodes.md`]. Spectre has no `ground` statement.

### 4.9 Analyses

```
Name [(]node1 ... nodeN[)] analysisType parameter=value ...
```

[UG p.66; R19 analysis chapter]. The name is required and must be unique
[UG p.68]. Most analyses take no nodes; `noise`, `xf`, `pnoise`, `pxf`,
`pss`, `hb`, `hbnoise`, `envlp`, `qpnoise` take an optional output pair `[p n]`
[UG p.67; R11 Definitions]. Spectre has no default analysis; analyses run in
netlist order; repeats of a type are allowed [UG p.68].

R19 analysis and control types (p.3-6): `ac acmatch alter altergroup check
checklimit cosim dc dcmatch envlp hb hbac hbnoise hbsp hbstb hbxf info lf
loadpull montecarlo noise options pac pnoise psp pss pstb pxf pz qpac
qpnoise qpsp qpss qpxf reliability set shell sp stb stress sweep tdr thermal
tran uti xf`. Older ones also have `fourier`, `pdisto`, `sens`.

Sweep parameters, shared by every sweeping analysis [UG p.165-168; R11
p.46 for `dc`; R19 p.406-408 for `sweep`]:

- Limits: `start` (default 0) and `stop`, or `center` and `span`.
- Steps: `step` or `lin` (default 50) for linear; `dec` or `log` (default
  50) for logarithmic; `values=[...]`; R19 adds `valuesfile`.
- No step parameter: linear when `stop/start < 10`, else logarithmic.
- Limits plus `values` are merged and sorted.
- What to sweep: `dev=inst`, `mod=model`, `sub=subckt-inst` with
  `param=name`; `param=temp` or a top-level parameter name alone; `freq`
  fixes the frequency when a small-signal analysis sweeps something else;
  `paramset=name` (sweep only). With no `dev/mod/param`, frequency-sweeping
  analyses sweep frequency.

```
OpPoint dc
Drift dc start=0 stop=50.0 step=1 param=temp
SwpVccDC dc dev=Vcc values=[0 2 6 7 8 10]
cmLoopGain ac start=1k stop=1G dec=10
Sparams sp center=0.15MHz span=0.3MHz lin=100 ports=[Pin Pout]
FindNoise (out gnd) noise start=1 stop=1MHz
dmNoise noise start=1k stop=1G dec=10 oprobe=Edif oportv=1 iprobe=Vdif iportv=1
OscResp tran stop=80us maxstep=10ns method=trap
XferVsTemp xf start=0 stop=50 step=1 probe=Rload param=temp freq=1kHz
```

`sweep` and `montecarlo` contain child analyses in braces; "The opening
brace is required at the end of the line defining the sweep"; sweeps nest
[UG p.165, p.168; R19 p.406]. `montecarlo` bodies may hold `export`
statements [UG p.168].

```
swp sweep param=temp values=[-50 0 50 100 125] {
oppoint dc oppoint=logfile
}
mc1 montecarlo variations=process seed=1234 numruns=200 {
sw1 sweep param=temp values=[-50 27 100] {
dcop1 dc
tran1 tran start=0 stop=1u
export slewrate=oceanEval("slewRate(v(\"vout\"),10n,t,30n,t,10,90 )")
}
}
```

Divergences: NLP parses analyses but **not** the brace body of `sweep` or
`montecarlo` (its corpus avoids it); its analysis keyword set stops at
`dc ac noise xf sp tran tdr pz envlp pac pdisto pnoise pss pxf sens fourier
dcmatch stb sweep montecarlo` (no `hb`, `qpss`, ...). VACASK puts analyses
in a `control ... endc` block as `analysis name type params`, with `sweep`
as a separate keyword [VACASK `docs/cmd-*.md`]. gnucap maps `label type
args` onto its own commands and writes output to `label.type`; `- type`
means unlabelled.

### 4.10 Control statements

Shape: `Name type parameter=value ...` [UG p.69]. Types: `alter altergroup
assert check checklimit ic info nodeset options paramset save set shell
statistics` [UG p.68-69], plus `paramtest` [UG p.98-99], `quantity` and
`node` [UG p.77-78].

- `alter`: one parameter per statement; `dev`/`mod`/`sub`/`param`/`value`
  [R11 p.37]. `SetTemp alter param=temp value=27` [UG p.69];
  `dmEnablePulse alter dev=Vdif param=type value=pulse annotate=no`
  [UG p.113].
- `altergroup`: `Name altergroup [params] {` ... `}` containing parameter,
  model, instance and `options` (only `temp tnom scale`) statements; no
  topology change, no analyses, `export`, `paramset`, `save` or `sens`; not
  inside subckts; may contain `include ... section=` and `simulator
  lang=spice` [R11 p.38; UG p.70, p.76].
- `options`: `Name options param=value ...` [UG p.212]. ADE writes
  `simulatorOptions options ...`; Cadence examples use `spectre options` /
  `Spectre options` [UG p.113, p.136]. R19 MTS mode scopes `options temp
  tnom scale scalem` given inside a subckt to that subckt [R19 p.501].
- `info`: `Name info what=... where=...` [UG p.207]. ADE writes
  `modelParameter info what=models where=rawfile`, `element info
  what=inst`, `outputParameter info what=output`, `designParamVals info
  what=parameters`, `primitives info what=primitives`, `subckts info
  what=subckts` (names seen in XDM's directive list).
- `set` (deferred options), `shell`, `check what=...`, `checklimit`,
  `assert`: same named shape.
- `paramtest`: an instance with no terminals:
  `TooHot paramtest warnif=(temp > 55) message="..."` [UG p.116].
- `paramset`: a data block, top level only, brace at line end; first row
  names top-level parameters, each later row is one sweep point
  [UG p.166; R19 p.509].

```
data paramset {
p1 p2 p3
5 5 5
4 3 2
}
```

### 4.11 `save`, `ic`, `nodeset`

```
save X[:param] ... [depth=num] [sigtype=node|dev|subckt|all]
     [devtype=type] [subckt=master] [exclude=[patterns]] [compression=no|yes]
ic signal=value ...
nodeset signal=value ...
```

[R11 p.366-367; R19 p.517; UG p.201-202]. These three have **no name
field**: the keyword is the first token.

- A signal is a node (`out`, `7`), a hierarchical node (`OpAmp1.comp`,
  `X3.7`), or `inst:terminal` with a terminal index (`L1:1`) or name
  (`m1:s`), or `inst:currents`, `inst:oppoint`, `inst:<op param>`, or
  `inst:int_d` (internal node) [R11 p.366; UG p.101, p.201].
- `*` and `?` are wildcards in `save` patterns [R11 p.366].
- `save vcc` saves the node when a node and an instance share the name
  [UG p.61].

```
save 7 out OpAmp1.comp M1:currents D3:oppoint L1:1 R4:pwr
save *:c devtype=bjt
ic 7=0 out=1 OpAmp1.comp=5 L1:1=1.0u
nodeset Voff=0 X3.7=2.5 M1:int_d=3.5 L1:1=1u
```

### 4.12 `if` (structural conditional)

```
if (condition) statement1 [else statement2]
if (cond) {
  statements
} else if (cond) {
  statements
} else {
  statements
}
```

[UG p.109-111; R11 p.345-346; R19 p.491]

- Statements are instances or nested `if`s, or a braced list; the condition
  is evaluated during flattening [R19 p.491].
- Multiple statements need braces; branches end with newlines; a newline
  between `if` and its condition needs a continuation [UG p.110].
- A braceless `else` binds to the closest unmatched `if` [R19 p.491].
- Duplicate instance names are allowed only when both branches are a single
  instance with the same terminals and the same primitive [R19 p.491].
- A sweep that flips a condition is an error (topology change) [UG p.111].

```
if (rseries == 0) {
c1 (a b) capacitor c=c
if (gparallel != 0) gp1 a b resistor r=1/gparallel
} else {
r2 (a x) resistor r=rseries
c2 (x b) capacitor c=c
}
```

Divergences: VACASK uses `@if cond` / `@elseif` / `@else` / `@end` line
directives instead [VACASK `docs/cir-conditional.md`]. NLP requires
braces (braceless bodies are an error in its corpus,
`conditional/err_braceless.scs`) and accepts `{` on the next line.

### 4.13 `statistics`

```
statistics {
  process {
    vary rshsp dist=gauss std=12 percent=yes
    vary uuu dist=unif N=10 percent=yes
  }
  mismatch {
    vary xisn dist=gauss std=0.5
  }
  correlate param=[rshsp rshpi] cc=0.6
  truncate tr=6.0
}
statistics {
  correlate dev=[m1 m2] param=[xisn xisp] cc=0.8
}
```

[UG p.176-181]

- Keywords `statistics process mismatch vary truncate correlate`; braces
  delimit blocks [UG p.176].
- `vary NAME dist=gauss|lnorm|unif {std=v | N=v} [percent=yes|no]`
  [UG p.178].
- `correlate param=[...] cc=v` and `correlate dev=[...] [param=[...]]
  cc=v` [UG p.180]; `truncate tr=v` [UG p.179].
- Several `statistics` blocks accumulate [UG p.180]. `std`, `N`, `cc`, `tr`
  may be expressions [UG p.179, p.181].
- Only parameters with numeric declared values may vary [UG p.179].

NLP parses it (`parse_statistics`, `parse_stat_group`, `parse_vary`); XDM
skips it as a comment by brace counting.

## 5. Parameter values

A parameter value is one of [UG p.80]:

- a real or integer expression (literals, operators, netlist parameters,
  built-in constants and functions);
- the name of an instance or model (`probe=Rload`, `dev=Vcc`);
- the name of a component parameter (`param=dc`);
- a quoted string;
- an enumerated name (`type=pulse`, `region=fwd`, `save=allpub`,
  `method=trap`).

So an unquoted identifier on the right of `=` is syntactically one thing
(a name) and gets its meaning from the parameter's type. UG's example
`h1 3 0 ccvs probe=xyz rm=xyz` binds the instance `xyz` to `probe` and the
parameter `xyz` to `rm` [UG p.61]. A parser should keep it as a name and let
the binder decide.

Vectors [UG p.80-81, p.90; R19 p.477]:

- `[v1 v2 ...]` on the right of `=`; elements space-separated; may mix
  numbers and parameter names; may not be empty.
- Any element other than a constant, a parameter, or a unary `+`/`-` of
  one must be parenthesized: `values=[0.5 1 +p2 (sqrt(p2*p2))]`.
- R19: space separation is "for clarity, though this is not mandatory".
  UG p.208 shows `infotimes=[x1, x2...]` with commas. See Open questions.
- Vectors of names: `ports=[Pin Pout]`, `exclude=[X1* X2*]`,
  `dev=[m1 m2]`.

Where expressions may appear: on the right of `=`, or inside a vector on
the right of `=` [UG p.86-87; R19 p.474]: instance, model and analysis
parameters, `ic`/`nodeset` values, `parameters` values. No braces or quotes
are needed around an expression (unlike HSPICE `'...'`/`{...}`).

Divergences: XDM also accepts `name=re,im` complex pairs. VACASK vectors
are comma-separated (`[1, 2, 3]`), it has `{...}` heterogeneous lists, and
zero-based indexing `v[i]` [VACASK `docs/expr-vectors.md`].

## 6. Expressions

### 6.1 Operators

Decreasing precedence, all left-associative except `**` and `?:` (right);
nonzero is true; relational and equality yield 1 or 0; `&&` and `||` do
**not** short-circuit [UG p.87-88; R11 p.336; R19 p.475]:

| Level | Operators |
|---|---|
| 1 (tightest) | unary `+` `-` |
| 2 | `**` |
| 3 | `*` `/` |
| 4 | binary `+` `-` |
| 5 | `<<` `>>` |
| 6 | `<` `<=` `>` `>=` |
| 7 | `==` `!=` |
| 8 | `&` (bitwise, integer operands) |
| 9 | `~^` or `^~` (bitwise XNOR) |
| 10 | `\|` (bitwise) |
| 11 | `&&` |
| 12 | `\|\|` |
| 13 | `cond ? x : y` |

Unary minus binds tighter than `**` in this table, so `-2**2` is `4`.
Not listed: logical `!`, bitwise `~`, `^` (XOR) and `%` (modulo; use
`fmod`). R11 p.336 mislabels the `*`/`/` row "Sum, Difference"; ignore.

```
r6 (1 0) RESMOD r=(p1 ? p4+1 : p3)
model fast_3x3 mos3 type=n vto=(temp >= 27_C) ? 0.98 : 0.81
```

Divergences:

- NLP: unary binds to a primary (as in the table), but its precedence puts
  `^`/`^~`/`~^` *between* `|` and `&` and adds `%` at the `*` level; no
  unary `!` [NLP `spectre_syntax_kind.rs` `prec`].
- XDM: accepts `^` as power next to `**`.
- VACASK: unary binds *below* `**` (`-2**2` = `-4`), adds `!` and `~`,
  `^` is XOR, `&&`/`||` short-circuit [VACASK `docs/expr-operators.md`].

### 6.2 Built-in functions

R19 p.476-477: `log ln log10 exp sqrt min max abs pow int floor ceil fmod
sgn sign sin cos tan asin acos atan atan2 hypot sinh cosh tanh asinh acosh
atanh` (`sign(x,y)` = `sgn(y)*fabs(x)`). UG p.88-89 lacks `ln sgn sign`;
R11 p.337 prints `ifloor` where R19 has `floor`. Domains: `exp(x)` for
`x < 80`, `log` for `x > 0`, etc. Plus user functions (§4.7) and, in
behavioral expressions only, `v() i() ddt() idt() $time` [R11 p.317].

### 6.3 Built-in constants and predefined parameters

`M_E M_LOG2E M_LOG10E M_LN2 M_LN10 M_PI M_TWO_PI M_PI_2 M_PI_4 M_1_PI
M_2_PI M_2_SQRTPI M_SQRT2 M_SQRT1_2 M_DEGPERRAD` and `P_Q P_C P_K P_H
P_EPS0 P_U0 P_CELSIUS0` [UG p.91-92; R11 p.328-329; R19 p.466].

`temp` (circuit temperature, °C) and `tnom` are predefined parameters usable
in any expression and in user functions; expressions using them are
re-evaluated when they change [UG p.93; R19 p.507].

`pi` appears in an R11 bsource example (`2*pi*freq*$time`, p.321) but is
not in any constant list. See Open questions.

### 6.4 Name resolution

- A name in an expression resolves to a parameter of the current subckt
  scope, then enclosing scopes, then top level [UG p.85-86].
- Parameters are declared before use (no forward references); models,
  subckts and nodes may be referenced before their definition (`x1 s1` and
  `r6 ... RESMOD` precede their definitions in UG p.87; `c1 xa.mid 0` comes
  before `xa` in UG p.64).
- Instance overrides replace subckt defaults; `m` is implicit (§4.2).

## 7. Nodes and hierarchy

- Ground is `0`, or the first name of the `global` statement (§4.8).
  `gnd` is ground only when declared so (`global gnd ...`). There is no
  documented built-in `gnd` alias in Spectre mode.
- Node names are names or integers; leading zeros matter (`00` is not `0`)
  [UG p.60; UG p.56 for SPICE mode].
- `!` is legal in names (`vdd!`), conventionally for globals; it does not
  by itself make a node global [UG p.60].
- `.` is the hierarchy separator: `X1.q1`, `I3.op3`, `M2.cap1`, numeric
  leaves `X3.7` [UG p.63-67, p.100, p.201].
- `:` separates an instance from a terminal (by index from 1, or name) or
  an output: `m1:1`, `m1:s`, `q1:b`, `m1:currents`, `m1:oppoint`,
  `m1:vbe`, `R4:pwr`, `M1:int_d` [UG p.101; R11 p.366-367].
- Inherited connections / net expressions exist but are documented
  elsewhere (*Inherited Connections Flow Guide*) [UG p.78].

## 8. Draft PEG

A starting point assembled from the rules above; `NL` is a significant
newline, `_` is horizontal whitespace and trivia (`\`-newline, `//`
comments, a newline followed by `+`). Semantic choices are marked `#`.

```
Netlist     <- Title? (Stmt / NL)* EOF          # Title only in the top-level file
Stmt        <- Simulator / Include / AhdlInclude / Library / Section
             / Global / Parameters / Model / Subckt / Function
             / Save / Ic / Nodeset / If / Statistics / Named
Simulator   <- 'simulator' 'lang' '=' ('spectre' / 'spice') Param* NL
Include     <- 'include' String ('section' '=' Name)? NL
AhdlInclude <- 'ahdl_include' String NL
Library     <- 'library' Name NL Stmt* 'endlibrary' Name? NL
Section     <- 'section' Name NL Stmt* 'endsection' Name? NL
Global      <- 'global' Node+ NL
Parameters  <- 'parameters' ParamDecl+ NL
ParamDecl   <- Name ('=' Expr)?                  # no default only inside subckt
Model       <- 'model' Name Name (Param* NL / '{' NL ModelMember* '}' NL)
ModelMember <- (Name / Integer) ':' Param+ NL
Subckt      <- 'inline'? 'subckt' Name Ports? NL Stmt* 'ends' Name? NL
Ports       <- '(' Node* ')' / Node+
Function    <- 'real' Name '(' ('real' Name (',' 'real' Name)*)? ')'
               '{' NL? 'return' Expr ';'? NL? '}' NL
Save        <- 'save' (Signal / Param)+ NL
Ic          <- 'ic' (Signal '=' Expr)+ NL
Nodeset     <- 'nodeset' (Signal '=' Expr)+ NL
Signal      <- Node (':' (Name / Integer))?
If          <- 'if' '(' Expr ')' Branch ('else' (If / Branch))?
Branch      <- '{' NL? Stmt* '}' NL? / Stmt
Statistics  <- 'statistics' '{' NL StatItem* '}' NL
StatItem    <- ('process' / 'mismatch') '{' NL StatItem* '}' NL
             / 'vary' Name Param+ NL / 'correlate' Param+ NL
             / 'truncate' Param+ NL / NL
Named       <- Name ( NodeList? AnalysisKw Param* Block? NL       # analysis
                    / ControlKw Param* Block? NL                  # control
                    / InstanceTail )
Block       <- '{' NL Stmt* '}'                  # sweep, montecarlo, altergroup, paramset
InstanceTail <- '(' Node* ')' Name Param* NL
             / (Bare &Bare)* Bare Param* NL      # last Bare is the master (must be a Name)
Bare        <- Node !'='                         # a word not followed by '='
NodeList    <- '(' Node* ')'
Param       <- '('? Name '=' Value ')'?
Value       <- Vector / Expr                     # String and enum names are Exprs
Vector      <- '[' VecElem* ']'
VecElem     <- Number / Name / [+-] (Number / Name) / '(' Expr ')' / String
Node        <- (Name / Integer) ('.' (Name / Integer))*
Expr        <- Or ('?' Expr ':' Expr)?
Or          <- And ('||' And)*
And         <- BitOr ('&&' BitOr)*
BitOr       <- Xnor ('|' Xnor)*
Xnor        <- BitAnd (('~^' / '^~') BitAnd)*
BitAnd      <- Eq ('&' Eq)*
Eq          <- Rel (('==' / '!=') Rel)*
Rel         <- Shift (('<=' / '>=' / '<' / '>') Shift)*
Shift       <- Add (('<<' / '>>') Add)*
Add         <- Mul (('+' / '-') Mul)*
Mul         <- Pow (('*' / '/') Pow)*
Pow         <- Unary ('**' Pow)?                 # right-assoc
Unary       <- [+-] Unary / Primary
Primary     <- Number / String / Name '(' (Expr (',' Expr)*)? ')' / Name / '(' Expr ')'
Number      <- ([0-9]+ ('.' [0-9]*)? / '.' [0-9]+)
               ([eE] [+-]? [0-9]+ / [TGMKk_%cmunpfa] [A-Za-z_]*)?   # P per K
Name        <- (NameStart / Escape) (NameChar / Escape)*
NameStart   <- [A-Za-z_]
NameChar    <- [A-Za-z0-9_!]
Escape      <- '\' [\x20-\x7e]
String      <- '"' ('\' . / [^"\\\n])* '"'
```

Known gaps in this draft: `Named` must try analysis and control keywords
before `InstanceTail`; in node position an integer (`007`, `3`) is a name
with its leading zeros kept, never a `Number`, and a digit-led word such as
`2n` has no documented meaning there (Open question 10).

## 9. Differential-testing material

- NLP `tests/corpus/spectre/` (MIT): about 150 decks drawn from the Cadence
  manuals, grouped by feature (`instance`, `model`, `subckt`, `analysis`,
  `conditional`, `control_named`, `control_save_ic`, `funcdecl`,
  `include_global`, `library`, `statistics`, `params_expr`,
  `arrays_langswitch`, `protect`), with `err_*` negative cases and expected
  CST dumps under `tests/expected/spectre/`. It is a ready accept/reject
  oracle for a PEG, minus its documented relaxations (bare flag model
  parameters, missing master) and gaps (sweep/montecarlo bodies).
- gnucap `tests/lang_spectre.*.gc`: small decks mixing Spectre and SPICE
  mode.
- Every example quoted above is from a Cadence manual and can be turned into
  a fixture with its citation.

## 10. What a minimal-but-real frontend needs, in priority order

1. Line layer: title line in the top file, `//` and line-start `*`
   comments, `\` and leading-`+` continuation; drop `/* */`.
2. Case-sensitive names with `!` and `\` escapes; integer node names with
   significant leading zeros; SI numbers with units and `_`.
3. Statement dispatch by position: keyword-first statements vs
   `name ... master|type`.
4. Instances with and without parentheses, zero-node instances, `m`.
5. `model name master params`, then model groups `{ 1: ... }`.
6. `subckt`/`inline subckt`/`ends [name]` with optional parens and
   `parameters` (defaults optional), nested definitions, local models.
7. `parameters` with expressions, scoping and inheritance; strings as
   values; enum names as values.
8. The expression grammar of §6, vectors with the parenthesis rule, the
   built-in functions and `M_`/`P_` constants, `temp`/`tnom`.
9. `simulator lang=spice|spectre` switching per file, `include` (with
   `.scs` / SPICE-mode default and mode restore), `include ...
   section=`, `library`/`section`/`endsection`/`endlibrary`.
10. `global` (first name is ground), `save`, `ic`, `nodeset`.
11. Primitives: `resistor capacitor inductor vsource isource vcvs vccs ccvs
    cccs mutual_inductor diode bjt mos* bsim3v3 bsim4 psp103 vbic` and the
    vsource/isource waveform parameter set.
12. Analyses `dc ac tran noise xf sp stb pss pac pnoise pxf` with the
    shared sweep parameters, then `alter`, `options`, `info` (accept and
    ignore unknown control types with a warning).
13. Structural `if`/`else`, `statistics` blocks (parse; Monte Carlo can
    come later), `real` functions, `sweep`/`montecarlo` brace bodies,
    `altergroup`, `paramset`.
14. `ahdl_include` once Verilog-A loading by path is wired to the
    frontend.

PDK model files (items 1-11 plus 13's `statistics` and `if`) and
ADE-generated testbenches (items 1-12) are covered by the first twelve.

## Open questions / ambiguities

1. **Title line vs. `simulator lang=spectre` on line 1.** UG p.29 and p.50
   say line 1 of the top netlist is always a title; UG p.50 also says a
   Spectre file is recognized by *starting* with `simulator lang=spectre`.
   Hand-written decks often put `simulator lang=spectre` on line 1.
   Suggested rule until a real Spectre run decides it: in the top-level
   file, line 1 is a title unless it is a `simulator` statement or a
   comment.
2. **`+` continuation in Spectre mode.** UG p.59 documents it, but a line
   starting with `+` could also be an expression continuation such as
   `+p2` in a vector broken across lines. Taking UG literally (leading `+`
   always continues) is what gnucap and NLP do.
3. **`/* */`.** Undocumented in every Cadence text checked. ESPice currently
   strips them; decide whether to keep that as a lenient extension or
   reject.
4. **Inline `//` without a preceding space** (`a//b`). UG p.59 says "a space
   and double slash"; NLP and ESPice strip `//` anywhere outside strings.
5. **`P` = 1e15.** In K Table B.1 and gnucap, absent from UG p.84.
6. **`1meg`.** By UG's unit rule it is 1e-3; VACASK reads 1e6. Spectre's
   actual behaviour (maybe a warning) is unverified.
7. **Unary minus vs `**`.** The Cadence table makes `-2**2` = 4; VACASK
   gives -4. Needs a Spectre run to confirm the table is literal.
8. **Logical `!`, bitwise `~`, `^`, `%`.** Not in any Cadence operator
   table, yet `!=` exists and real PDK files may use `!`. NLP and VACASK
   disagree on `^` precedence.
9. **Commas in vectors.** R19 p.477 says spaces are "not mandatory"; UG
   p.208 shows `infotimes=[x1, x2...]`. Whether `[1,2]` means two elements
   is unclear.
10. **Numeric-looking node names** (`2n`, `1N3064`). Nodes may be integers
    and names may not start with digits unless escaped, so `2n` should be
    illegal as a node; NLP lexes it as one NUMBER and accepts it in node
    position. UG p.62's "digits, letters, digit, ..." exception for
    `\2N2222` is worded ambiguously (with or without the backslash).
11. **`global` placement and count.** R5/R11/UG: once, first statement.
    R19: multiple allowed. UG examples place it before `simulator
    lang=spectre`, i.e. in SPICE mode.
12. **Parameter vs instance namespace.** UG p.61 (5.0.32+) allows shared
    names; R11 p.360 and R19 forbid a parameter named like an instance.
13. **`pi`.** Used unqualified in R11's bsource examples, absent from the
    constant tables.
14. **One-line function bodies and braceless `if` bodies.** Cadence's
    definition allows a single unbraced instance after `if (...)`; NLP
    rejects it. Function bodies are only ever shown multi-line.
15. **Single-line sweep bodies.** UG p.207 prints `tempSweep sweep ...
    {dc1 dc dcInfo info what=oppoint ...}` on one line, against the "brace
    at end of line" rule; probably a typesetting artifact.
16. **`;` after parameter values and bare flag parameters.** NLP reports
    both in real netlists; Cadence does not document either.
17. **`gnd`.** No built-in alias is documented; ADE emits `global 0 ...`
    and `0`. Some flows may still rely on `gnd` being ground via
    `global gnd`.
18. **Newer syntax.** R19 is from 2020. Anything added later (Spectre X
    netlist features, newer analyses) is not covered here; a current
    `spectre -h <topic>` dump would close the gap.
