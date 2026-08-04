# ngspice netlist syntax, for a PEG grammar

Survey date: 2026-10-17. Sources, both read locally:

- **Manual**: *Ngspice User's Manual, Version 47+ (development version)*,
  dated 2026-09-28 (`ngspice-manual.pdf` from ngspice.sourceforge.io,
  converted to text). Cited as "manual §x.y".
- **Source**: ngspice git `https://git.code.sf.net/p/ngspice/ngspice`,
  branch `pre-master-48`, head commit `940bb50` (committed 2026-10-16 by
  dwarning, "inpcom.c: evaluate .param with agauss etc. once, as
  documented"); `git ls-remote` confirmed this is the upstream branch head.
  It is upstream's development branch for ngspice-48, so it carries
  features the 44.2 release lacks (`.pac`/`.pnoise`/`.pxf`/`.psp`,
  `.hb`-family cards, `.dc @inst[param]`, extra `.meas` functions, an
  `nport` N device, `r=`/`td=` on I sources). Those are tagged
  **[pre-48]** below. Cited as `file:function` or `file:line`, with line
  numbers at that commit; paths are relative to `src/`.
- **Behaviour checks**: the claims marked *(verified)* were run through the
  installed `ngspice-44.2` (`ngspice -b`). 44.2 is older than the source read
  here; every verified claim also matches the code at `940bb50`.

Where the manual and the source disagree, this page follows the source and
records both in "Open questions / ambiguities".

## 0. How ngspice actually parses (read this first)

ngspice has no single grammar. A deck goes through about thirty textual
rewriting passes before any device parser sees it, and every pass works on
raw strings. A PEG that describes the *input* language has to state, as
grammar, what those passes accept. The order matters because later passes
see earlier rewrites. The main passes, in order (`src/frontend/inpcom.c`):

| # | Pass | Function | What it does to the text |
|---|---|---|---|
| 1 | Physical line read | `readline` (2328) | Drops leading spaces/tabs, drops every `\r`, splits at `\n` |
| 2 | Per-line read loop | `inp_read` (1320) | Blank-line skip, `@` stops the file, `.title`, `.lib`→`.inc` (lt/ps), `.hdl`/`.biaschk` dropped, `.include` recursion, **lower-casing**, `.end` detection, `\\` continuation marking |
| 3 | Library sections | `expand_section_references` (4062) | `.lib file sec` inlining (not in lt/ps/s3 modes) |
| 4 | End-of-line comments | `inp_stripcomments_deck`/`_line` (3554, 3592) | `$`, `;`, `//`, `#` |
| 5 | Continuation | `inp_stitch_continuation_lines` (674) | `+` lines joined |
| 6 | Syntax check | `inp_check_syntax` (9258) | Bad leading chars → `*`, block-pairing checks, bare `ac` → `ac ( 1 0 )` |
| 7 | Compat (whole deck) | `ltspice_compat_a`, `pspice_compat_a` (`inpcompat.c`) | Only with `ngbehavior` `lta`/`psa` |
| 8 | Quotes and `params:` | `inp_fix_for_numparam` (3888) | `'…'` → `{…}`, strips user `params:`, re-inserts `params:` on `.subckt` |
| 9 | Whitespace squeeze | `inp_remove_excess_ws` → `inp_remove_ws` (3924, 3828) | Removes spaces around `=`, and around operators and `,` inside `{}` |
| 10 | Multi-param split | `inp_split_multi_param_lines` (5757) | One `.param` line per assignment |
| 11 | `.macro`, `( )` on X/.subckt, `.param f(x)=` | `inp_fix_macro_param_func_paren_io` (2898) | Normalises to `.subckt`/`.func` |
| 12 | Statistical / `temper` params | `inp_fix_agauss_in_param`, `inp_fix_temper_in_param` | `.param` → `.func` where needed |
| 13 | `.func` expansion | `inp_expand_macros_in_deck` (4880) | Textual macro substitution |
| 14 | Auto-bracing | `inp_fix_param_values` (4933) | `name=ident` → `name={ident}` |
| 15 | Param reordering | `inp_reorder_params` (5700) | Dependency order |
| 16 | X-line params | `inp_fix_inst_calls_for_numparam` (4311) | `x … sub a=1` → positional actuals |
| 17 | Ground | `inp_fix_gnd_name` (2383) | `gnd` → `0` |
| 18 | Device compat | `inp_compat` (6181), `inp_bsource_compat` (7412), `inp_dot_if` (7990), `inp_temper_compat` (7474), `inp_meas_control` (10262) | E/G/R/C/L expression forms → B sources, B expressions prepared for numparam |
| 19 | Subcircuit expansion + numparam | `subckt.c`, `numparam/spicenum.c`, `xpressn.c` | `{…}` evaluated to numbers, X lines flattened |
| 20 | Device/dot parsers | `spicelib/parser/inp2*.c`, `inpdomod.c`, `inp2dot.c` | Tokenise with `INPgetTok`/`INPgetNetTok`/`INPevaluate` |

**Recommendation for the grammar.** Write it in two layers, as Zig's
langref grammar separates tokenising from parsing:

1. **Line layer** (§1): physical lines → logical lines (comments stripped,
   continuations joined, case folded). This is a deterministic function and
   can be specified as a PEG over characters that emits logical lines.
2. **Card layer** (§2-§4): one PEG rule per card kind over a logical line,
   with the expression sub-grammars (§2) as separate rules.

Mode-dependent rules (§5) are best expressed as separate rule variants
selected by a mode flag, rather than one rule set with semantic predicates.

## 1. Lexical layer

### 1.1 Physical lines

- Lines end at `\n`. Every `\r` anywhere in the line is dropped, and so are
  all leading spaces and tabs (`inpcom.c:readline`, 2328: "Leading spaces
  away"). So indented lines, including indented `*` comments and indented
  `+` continuations, behave exactly like unindented ones *(verified)*.
- A UTF-8 BOM (3 bytes) or UTF-16LE BOM at the start of a file is removed;
  UTF-16LE files are read by dropping NUL bytes (`inp_read`, first-line
  handling; `readline`). After reading, `utf8_syntax_check` stops on invalid
  UTF-8 (manual §2.1.2.1).
- In `inp_casefix` (`inpcom.c:3503`, applied later to dot lines from
  `inp.c:884`), a non-printable non-space byte becomes `_`; a line made of
  one such byte becomes `*`.

```
PhysLine  <- [ \t]* Body '\n'?        # leading blanks dropped, '\r' deleted anywhere
```

### 1.2 Title line

- The **first line of the top-level file is always the title**, whatever it
  contains (manual §2.4.1, §2.1.1). An element line or a dot card there is
  silently treated as the title. If the first line starts with `.param` or
  `.meas`, ngspice aborts with "title line is missing"
  (`inp_check_syntax`, 9276).
- A blank first line is kept as an (empty) title: the blank-line skip in
  `inp_read` only applies once a first card exists
  (`call_depth != 0 || cc != NULL`, 1416).
- The title **is lower-cased** like every other line (it passes through
  the same casing loop in `inp_read`). `My TITLE Upper` prints as
  `Circuit: my title upper` *(verified)*.
- `.title <text>` anywhere replaces the title; the last one wins, and the
  `.title` line becomes a comment (`inp_read`, 1432; manual §2.4.1). Its
  text is captured before lower-casing, so **`.title Mixed Case` keeps its
  case** *(verified)*, unlike a first-line title. Since
  it is found at read time, before continuation stitching, `.title` cannot be
  continued with `+` (manual §2.4.5 says the same).
- Included files have no title line: their first line is an ordinary line.

```
Deck      <- TitleLine Line* EOF
TitleLine <- (!'\n' .)* '\n'          # verbatim, but lower-cased
```

### 1.3 Blank lines and the `@` terminator

- A line that is empty after leading-blank removal is dropped (`inp_read`,
  1415). Blank lines may therefore sit between continuation lines.
- **A line whose first character is `@` ends the current file**: the rest
  of that file is not read, silently (`inp_read`, 1423:
  `if (*buffer == '@') break;`). This is undocumented *(verified: a resistor
  after an `@stop` line was not in the circuit)*.

### 1.4 Case folding

Done line by line in `inp_read` (1704-1895), before comments are stripped:

- **Everything is lower-cased** except:
  - lines starting `.lib` or `.inc` (so `.include`, `.inc`, `.incpslt`):
    the whole line keeps its case, file names included;
  - inside `.control` sections or command files: lines starting `write`,
    `wrdata`, `codemodel`, `osdi`, `pre_osdi`, `snp`, `pre_snp`, `echo`,
    `shell`, `source`, `cd`, `load`, `setcs`, `strcmp`, `strstr`;
  - `plot`/`gnuplot`/`hardcopy` keep the case of the token after
    `title`/`xlabel`/`ylabel`; `print`/`eprint`/`eprvcd`/`asciiplot` keep the
    case after `>`;
  - XSPICE `.model` lines whose type is one of `filesource vcd_source
    table2d table3d xfer d_state d_source d_process d_cosim`, and CIDER
    models: text inside double quotes keeps its case
    (`is_xspice_model`, 424; `keep_case_of_cider_param`, 225).
- **Double-quoted strings are not protected in general.** `.param
  s="AbC"` becomes `s="abc"`. Only the special lines above keep the case of
  quoted text.
- Manual §2.1.3.4: node names are case-insensitive in batch mode. That
  follows from the folding above.

PEG consequence: match keywords case-insensitively and treat every
identifier as lower-case, except in `.include`/`.lib` lines and the quoted
strings of the listed code models.

### 1.5 Comments

Full-line comments (after leading-blank removal):

| First char | Effect | Source |
|---|---|---|
| `*` | Comment | manual §2.4.3; `inp_stripcomments_line` |
| `#` | Comment (rewritten to `*`) | `inp_stripcomments_line` (3601); `inp_stitch_continuation_lines` |
| `$` | Comment | `inp_stitch_continuation_lines` (skips it); `inp_check_syntax` rewrites it to `*` |
| `;` | Comment, silently *(verified)* | `inp_check_syntax` (9312) |
| one of `= [ ] ? ( ) & % " ! : ,` or form feed | Rewritten to `*` with a warning (fatal under `set strict_errorhandling`) | `inp_check_syntax` (9295); manual §2.1.2.2 lists `=[]?()&%$§\"!:` |

End-of-line comments (`inp_stripcomments_line`, 3592), scanned left to
right **outside single- and double-quoted strings only** (a quote can be
escaped with a preceding `\`). **Braces do not protect**: `{x $ y}` loses
` $ y}` *(verified)*.

| Introducer | Condition | Example |
|---|---|---|
| `$` | Previous char is space, tab or `,`. Not in ps mode (`ngbehavior` containing `ps`). Inside `.control`/command files: only `$ ` (followed by a space) | `R1 a b 1k $ load` comments; `.param y=3$c` is **not** a comment and fails *(verified)* |
| `;` | Anywhere, no whitespace needed, except right after a closing quote (see below) and as the first character of the line (handled by the full-line rule) | `Re 1 0 2k;comment` |
| `//` | Anywhere, no whitespace needed, also inside braces | `.param n1=1 //new value` |

- After cutting, trailing blanks are removed. A line that holds only a
  comment becomes a `*` line (3672-3688).
- `.lib file section` references are expanded (pass 3) **before** comments
  are stripped; only two blank-separated tokens are read, so `.lib f.lib tt
  $ x` works but `.lib f.lib tt;x` looks for section `tt;x`
  (`expand_section_ref`, 3948).
- Quirk: the `;` test looks one character ahead of the scan position, and
  the scan jumps past a quoted string, so a `;` **directly after a closing
  quote is not seen**: `.param d='a*10';comment` fails with "= sign
  expected" *(verified)*. `'a*10' ;comment` works.
- `R1 1 0 1k$x` happens to work, but not because `$x` is a comment: the
  value token `1k$x` is read as a number with trailing junk (§1.10).
- `.include` lines are stripped earlier, in `inp_read` (1500), with
  `inc=TRUE`: the scan skips `.include` and starts at the file name (it
  skips the name too only if the name starts with `$`). Quoted names are
  protected by the quote rule; in an **unquoted path a `;` or `//` cuts the
  name** (`/a//b.lib` becomes `/a`). Quote such paths.
- Manual §2.4.4 says `$ ` (dollar plus space) is the documented form and a
  bare `$` is "accepted". The source condition is the character *before*
  `$`, not after (see Open questions).

```
EolComment <- ( [ \t,] '$' / ';' / '//' ) (!'\n' .)*     # outside '..' and ".."
```

### 1.6 Continuation lines

- A line whose first non-blank character is `+` continues the previous
  logical line. The `+` becomes a space and the rest is appended
  (`inp_stitch_continuation_lines`, 674; manual §2.4.5). Leading blanks
  before the `+` are allowed (they are gone after `readline` anyway).
- **Comment lines (`*`, `#`, `$`) and blank lines between a line and its
  continuations are skipped and deleted**, so this is one logical line
  *(verified)*:

  ```
  Rf 1 0
  * comment between
     + 3k
  ```

- End-of-line comments are stripped from each physical line **before**
  stitching (pass 4 precedes pass 5), so `+ a b ; comment` is safe.
- A `+` line with no preceding regular line gets the error "Illegal
  continuation line: ignored."
- Shell style: a line whose last two non-blank characters are `\\` is
  continued by the next line: the two backslashes become spaces and the next
  line gets a `+` prefix (`chk_for_line_continuation`, 2872; `inp_read`,
  1909). Not for lines starting `*` or `$`.
- Because `.title`, `.include`/`.inc` and old-style `.lib` are handled in
  pass 2, before stitching, they cannot be continued (manual §2.4.5).
- Continuations are joined inside `.control` blocks too.

```
LogicalLine <- FirstLine ( (CommentLine / BlankLine)* ContLine )*
ContLine    <- '+' Rest              # '+' -> ' '
```

### 1.7 `.end`

- `.end` is recognised when the line starts `.end` (any case) followed by
  end of line or whitespace (`inp_read`, 1903), so `.end of deck` counts,
  while `.ends`, `.endc`, `.endl`, `.endif` do not.
- **Lines after `.end` are not ignored.** `inp_read` turns `.end` into a
  comment, keeps reading, and appends a fresh `.end` after the last line of
  the file (1960). A resistor placed after `.end` is part of the circuit
  *(verified: `Rg` after `.end` changed `i(v1)`)*. The manual (§2.4.2) only
  says `.end` "must always be the last" line.
- A missing `.end` is accepted (no `.end` is appended then, and nothing
  needs it).

### 1.8 Field delimiters and tokenisers

Manual §2.1.3.1: "Fields on a line are separated by one or more blanks, a
comma, an equal (=) sign, or a left or right parenthesis." The device
parsers implement that with three tokenisers (`spicelib/parser/inpgtok.c`).
Which one is used decides what a field may contain:

| Tokeniser | Used for | Skipped before token | Ends token | Notes |
|---|---|---|---|---|
| `INPgetNetTok` | instance names, node names, model names on `.model` | blank, tab, `=`, `(`, `)`, `,` | blank, tab, `\r`, `=`, `,`, `(`, `)` (the `(` stop is **[pre-48]**; 44.2 keeps `(` inside the token) | Liberal: `+`, `-`, `*`, `/`, `^`, `{`, `}`, `[`, `]`, `!`, `<` … are all name characters |
| `INPgetTok` | keywords, parameter names, model type, analysis words | same | same, plus `*`, `/`, `^`, and `+`/`-` unless they look like part of a number | `nch-1` would end at `-` |
| `INPgetUTok` | numbers (called by `INPevaluate` with gobble) | same | same as `INPgetTok`; a token may also be wrapped in `"…"` or `'…'` | |

- All three, with `gobble=1`, also swallow `=` and `,` after the token, so
  `=` and `,` really are whitespace in instance and model lines:
  `R1 a b r=1k`, `R1 a b r 1k` and `pulse(0,1,0)` versus `pulse 0 1 0` all
  tokenise the same.
- **Parentheses are whitespace for the device parsers**, but several
  text passes look for literal parentheses before that (e.g. `v(…)` in
  B sources, `.model … type(…)`, `POLY(n)`, `pwl(…)`), so the grammar should
  still accept them as optional brackets where the cards document them.
- `inp_remove_ws` (pass 9) also deletes blanks around every `=`, and
  around `+ - * / ( ) < > ? : | & ^ ! % \` and `,` *inside braces*. So
  `rval = 100k` equals `rval=100k`, and `{ a + b }` equals `{a+b}`.

### 1.9 Quoting

- **Single quotes become braces** on every line outside `.control`, except
  comments and `.lib` lines (`inp_fix_for_numparam` → `inp_change_quotes`,
  3693): each `'` alternately becomes `{` and `}`. `.param pop='pp+p'`
  is `.param pop={pp+p}`. Consequences: single quotes cannot nest, and an
  apostrophe inside a double-quoted string is converted too.
- **Double quotes** delimit strings for string-valued parameters
  (manual §2.11.1, §2.11.3) and file names. On dot lines other than
  `.param`, `.model`, `.subckt` (and `x` lines, `.plot`, `.print`),
  `inp_casefix` replaces the two quote characters by spaces (`inpcom.c:3503`,
  called from `inp.c:887`).
- `.include`/`.lib` file names may be wrapped in `"…"` or `'…'`
  (`get_quoted_token`, 7706); this is how a path with spaces is written.
- Braces `{…}` nest; the brace matcher counts depth (`inp_spawn_brace`,
  3477; `numparam/spicenum.c:stripbraces`).

### 1.10 Numbers

There are **three different number readers**. A PEG for "SPICE number"
should be `INPevaluate`'s, and the numparam reader is a separate rule.

**`INPevaluate`** (`spicelib/parser/inpeval.c:14`): used for every value
field of device and dot lines and for B-source numbers.

```
SpiceNumber <- [+-]? ( Digit+ ('.' Digit*)? / '.' Digit* )
               ( [eEdD] [+-]? Digit* )?      # exponent digits optional
               Scale? Junk
Scale       <- [tT] / [gG] / [kK] / [uU] / [nN] / [pP] / [fF] / [aA]
             / [mM][eE][gG] / [mM][iI][lL] / [mM]
Junk        <- (!Delim .)*                    # rest of the token is ignored
```

| Suffix | Factor | | Suffix | Factor |
|---|---|---|---|---|
| T | 1e12 | | m | 1e-3 (M also: milli) |
| G | 1e9 | | u | 1e-6 |
| Meg | 1e6 | | n | 1e-9 |
| K | 1e3 | | p | 1e-12 |
| mil | 25.4e-6 | | f | 1e-15 |
| | | | a | 1e-18 |

Facts the table in manual §2.1.3.2 does not show:

- `D`/`d` is accepted as the exponent letter: `1d3` = 1000 *(verified)*.
- The exponent may have no digits: `1e` = 1 *(verified)*, `1e+` = 1.
- `5.` = 5, `.5` = 0.5, and **`.` alone is 0 with no error** (`'.'` passes
  the first-character check and nothing after it is required).
- A leading `+` or `-` is allowed. A sign followed by anything other than a
  digit or `.` is an error ("number looks like just a sign").
- Anything after the scale factor is ignored, as the manual says
  (§2.1.3.3: `10V`, `10Hz`, `1kHz`). This includes **`1k5` = 1000**
  *(verified)*, except in `lt` mode where R, C and L values use RKM notation
  (`INPevaluateRKM_R/_C/_L`, `inp2r.c:83`, `inp2c.c:75`; manual §2.1.3.3).
- No hex: `0x10` reads as 0. No `inf`/`nan`.
- A `:` right after the integer part ends the number (`1:` = 1), kept for
  ternaries.
- **Not an expression.** `R3 a 0 2*3` gives "unknown parameter (*)"
  *(verified)*: the value token ends at `*` and the rest is parsed as
  parameters. Expressions need braces or quotes.

**numparam `fetchnumber`** (`numparam/xpressn.c:640`): used inside `{…}`.

- Reads with `sscanf("%lG")`, so it accepts **C hex floats and hex
  integers**: `{0x10}` = 16 *(verified)*.
- Scale factor from `parseunit` (608): `T G K MEG M U N P F A` only.
  **No `mil`: `{1mil}` = 1e-3** (the `M` branch) *(verified)*, while
  `1mil` outside braces is 25.4e-6. Manual §2.11.5's suffix table for
  expressions lists only g, meg, k, m, u, n, p, f (no t, no a); the source
  also has `t` and `a`.
- After the suffix, all following letters (`alfa`: letters, `_`, `[`, `]`,
  bytes ≥ 0x80) are swallowed.
- A number must start with a digit or `.` (a leading sign is an operator,
  §2.2).

**`INPevaluateRKM_*`** (lt mode only): `4k7` = 4700, `2R2` = 2.2,
`100R` = 100; also `L` as milli for R.

### 1.11 Names

- **Instance names**: the first character selects the device (manual §2.3,
  Table 2.2); the rest is arbitrary and contains no delimiter. Since lines
  are lower-cased, `R1` and `r1` are the same instance.
- **Node names** (`INPgetNetTok`): any run of characters other than blank,
  tab, `=`, `,`, `(`, `)`. `a+`, `b-`, `in-`, `+vcc`, `n.1` and `x1.out` are
  valid *(verified: `a+`, `b-`)*. The manual (§2.1.3.4) additionally forbids
  `% [ ] < > ~ { } '` in node names; those restrictions come from other
  stages (XSPICE port syntax uses `[ ] % ~`, braces and quotes get rewritten
  by passes 8 and 19), not from the tokeniser. The grammar should use the
  manual's stricter set.
- **Ground**: `0`. `gnd` is accepted: `.global gnd` is prepended to the deck
  (`inp_read`, 1939), and `inp_fix_gnd_name` (2383) rewrites the token `gnd`
  to `0` anywhere after the first token of a line, when preceded by a blank,
  `(` or `,` and followed by a blank, `)` or `,`. `set no_auto_gnd` turns
  this off (manual §2.1.3.5). Not in ps mode inside a subcircuit that has
  `gnd` on its `.subckt` line. In KiCad mode `/gnd` and `/0` also become `0`.
- **`00` is not ground.** Node names are strings, so `0` and `00` differ
  (manual §2.1.3.5) *(verified)*.
- **Parameter identifiers in numparam** (`xpressn.c:fetchid`, `alfa`,
  `alfanum` in `mystring.c:150`): start with a letter, `_`, `[`, `]` or a
  byte ≥ 0x80; continue with those, digits, and `.`. The manual (§2.11.1)
  instead allows `! # $ % [ ] _` after the first letter. B-source identifier
  scanning (`inp_modify_exp`, 7653) does allow `! # $ % _ [ ]`.
- Reserved words, not usable as parameter names (manual §2.11.6): `not and
  or div mod defined sqr sqrt sin cos exp ln log log10 arctan abs pwr time
  temper hertz`, plus every built-in function name.

## 2. Expressions

ngspice has three expression languages with different grammars (manual
§2.11.7, §2.16):

| Language | Where | Evaluated | Parser |
|---|---|---|---|
| numparam | inside `{…}` / `'…'`, `.param`, `.func`, subckt params, `.if` | once, at subcircuit expansion | `numparam/xpressn.c:formula` (876), a precedence state machine |
| ASRC ("B-source") | `B … v=`/`i=`, and the E/G/R/C/L forms that `inp_compat` turns into B sources | every Newton iteration | `spicelib/parser/inpptree-parser.y` (bison) + `inpptree.c:PTlex` (1403) |
| control | `.control` scripts, `let`, `if` | after simulation | `frontend/parse.c` — out of scope here |

### 2.1 Where braces are needed

- A value position (positional or `name=`) holds a SPICE number, a brace
  expression `{…}` or a quoted `'…'` (→ braces), manual §2.11.2.
- **Auto-bracing**: on every non-comment line except B lines, `.option*`,
  `set`, `.control` blocks, `.cmodel`, CIDER models, lines containing
  `ic.file`, and `.param` lines that already contain `{`,
  `inp_fix_param_values` (4933) wraps the token after each `=` in braces,
  unless it starts with a digit, `{`, `.`, `"`, a sign followed by a digit or
  `.digit`, or the words `true`/`false`. The token runs to the next blank
  outside parentheses. So `R1 a b r=rval` works *(verified)*, and so does
  `w=l*2`, but `w=2*l` is left unbraced (it starts with a digit) and then
  fails or truncates as in §1.10. `[…]` vectors and `<…>` complex values get each element
  braced. In `.meas`, `=v(…)`/`=i(…)` are left alone.
- **Positional values are never auto-braced**: `R1 a b rval` reads `rval`
  as a model name.
- Every `{…}` remaining on a non-`.param` line (including `.model` lines and
  dot cards) is replaced by its value, printed as `% 23.15e`
  (`spicenum.c:stripbraces`, `xpressn.c:double_to_string`). Braces cannot
  build node names (manual §2.11.2). In `.meas`, `{LAST}` passes through as
  `last` (`nupa_substitute`, 1341).

### 2.2 numparam expression grammar

Source: `numparam/xpressn.c:formula` (876), `fetchoperator` (673),
`operate` (761). Manual §2.11.5.

Precedence, tightest first:

| Level | Operators | Assoc | Notes |
|---|---|---|---|
| atom | number, identifier, `f(args)`, `( expr )` | | |
| unary | `!` | prefix | binds to the next atom **before** `^`: `!2^0` = `(!2)^0` |
| 2 | `^`, `**` | **left** | `2^3^2` = 64 *(verified)* |
| 3 | `*` `/` `%` `\` | left | `%` is C `fmod`-like (`x - y*trunc(x/y)`); `\` is `trunc(abs(x/y))` |
| 4 | `+` `-` | left | |
| 5 | `==` `!=` `<>` `<` `<=` `>` `>=` | left | **all one level** (C splits equality and relational) |
| 6 | `&&` | left | result 0 or 1 |
| 7 | `\|\|` | left | |
| 8/9 | `c ? x : y` | | the `?`/`:` accumulator trick in `formula` (1048) |

Unary minus is not a real operator:

- A leading `-` (expression start, after `(`, or after `,`) is binary minus
  with a zero left operand at level 4, so `-2^2` = `-(2^2)` = -4
  *(verified)* and `-a*b` = `-(a*b)`.
- A `-` directly after another binary operator sets a flag that only a
  **numeric literal** consumes: `2^-1` = 0.5 and `a*-2` work, but
  `{2*-p}` fails with "wrongly determined negation" *(verified)*. Write
  `2*(-p)`.
- A unary `+` is accepted only where binary `+` from zero works.

Other rules:

- `=` alone is equality (`fetchoperator` folds `==` into `=`), but `=` cannot
  appear in a `.param` value since pass 10 treats it as an assignment.
- Function call: a name from the built-in list followed by `(`. Arguments
  are split at the **first two** top-level commas: one, two or three
  arguments; with four or more the middle ones are silently dropped (`arg3`
  "kludge", 940). A one-argument function given two arguments uses the last.
- Booleans: 0 is false, anything else true; results are 1 or 0 (manual
  §2.11.5).
- `^` depends on the mode (manual §2.11.5; `operate`, 790): default
  `pow(fabs(x), y)`; hs: `x<0 → pow(x, round(y))`, `x==0 → 0`; lt: `x<0`
  and `y` near-integer → `pow(x, round(y))`, else 0.

```
Expr     <- Ternary
Ternary  <- Or ('?' Or ':' Ternary)?
Or       <- And ('||' And)*
And      <- Cmp ('&&' Cmp)*
Cmp      <- Add (CmpOp Add)*                    # single level
CmpOp    <- '==' / '!=' / '<>' / '<=' / '>=' / '<' / '>' / '='
Add      <- '-'? Mul (('+' / '-') Mul)*         # leading '-' is 0 - Mul...
Mul      <- Pow (('*' / '/' / '%' / '\\') Pow)*
Pow      <- Unary (('^' / '**') ('-' Number / Unary))*   # left-assoc
Unary    <- '!'* Atom
Atom     <- Number / Call / Ident / '(' Expr ')'
Call     <- FuncName '(' Expr (',' Expr (',' Expr)?)? ')'
Ident    <- [a-z_\[\]\x80-\xff] [a-z0-9_.\[\]\x80-\xff]*
```

(`'-' Number` after any binary operator, not only `^`, is the
negation-flag rule; a PEG can express it as a `NegNumber` atom allowed
only right after a binary operator.)

**Built-in functions** (`xpressn.c:fmathS`, 91):

```
sqr sqrt sin cos exp ln arctan abs pow pwr max min int log log10
sinh cosh tanh ternary_fcn agauss sgn gauss unif aunif limit ceil floor
asin acos atan asinh acosh atanh tan nint vec var
```

Semantics: `int` truncates, `nint` rounds half to even, `log` = `ln`
(natural), `pwr(x,y)` = `pow(|x|,y)`, `sqr(x)` = x²,
`ternary_fcn(c,a,b)`, `agauss(nom,avar,sigma)`, `gauss(nom,rvar,sigma)`,
`unif(nom,rvar)`, `aunif(nom,avar)`, `limit(nom,avar)`. `vec(name)` and
`var(name)` take a string argument (a vector in the current or `const`
plot, an interpreter variable) and must come last in the list. Manual
§2.11.5 lists the same set (it omits `sqr` and `log10` in the table but
reserves them in §2.11.6).

**Strings** (manual §2.11.1, §2.11.3; `string_expr`, 1147): a string
expression is a sequence of `"…"` literals and string-valued parameter
names (bare or in `{}` with no space), concatenated: `.param both={str1}"
and "str2`. Only top-level `.param` assignments may concatenate. In a
`.model` string, `"{infile}"` substitutes the value without quotes.

### 2.3 `.param`

Manual §2.11.1. Source: `inp_split_multi_param_lines` (5757),
`nupa_assignment` (`xpressn.c:1458`), `getexpress` (1392).

```
ParamCard  <- '.param' ( Assign ( ','? Assign )* )
Assign     <- Ident '=' Value
Value      <- '{' Expr '}' / "'" Expr "'" / StringExpr / BareExpr
```

- Several assignments per line, separated by blanks or `,`
  (`.param a=1, b=2 c='a+b'` *(verified)*).
- **Splitting rule**: when a line has two or more assignments, each value
  runs to the first blank or `,` outside `{}`/`()`/`"…"`. That is why
  manual §2.11.1 warns `.param a = 123 * 3  b = sqrt(9)` sets `a` to 123:
  `* 3` is lost. With **one** assignment on the line nothing is split and
  numparam reads to the end, so `.param q = 123 * 3` gives 369
  *(verified)*; the manual's "won't work" example `.param c = a + 123`
  also works when it is alone on the line.
- In numparam, a value ends at `,`, `;`, `)` or `}` at depth 0
  (`getexpress`, 1428).
- `.param name(args) = body` is rewritten to `.func` (pass 11).
- Assignments are sequential: a parameter must be defined before use, and
  cannot reference itself (manual §2.11.1), but pass 15 reorders `.param`
  lines by dependency first (`inp_reorder_params`), so in practice textual
  order matters less than the manual implies.
- The historical `&` line prefix for `.param` is deprecated
  (manual §2.11.7).

### 2.4 `.func`

Manual §2.12. Source: `inp_get_func_from_line` (4485),
`inp_expand_macros_in_deck` (4880), `inp_do_macro_param_replace` (4619).

```
FuncCard <- '.func' Ident '(' (Ident (',' Ident)*)? ')' '='? Body
Body     <- '{' Expr '}' / "'" Expr "'" / Expr
```

- Zero parameters are allowed (`f()`); an empty slot after a comma is an
  error. The `=` is optional ("unwanted and non advertised").
- The body has **all braces and all whitespace removed**.
- `.func` is a textual macro: every call `f(a,b)` on any line of the same
  scope, B sources included, is replaced by the body with the parameters
  substituted; an argument containing an operator is wrapped in `()`.
  Formal names inside `v(…)`/`i(…)` are not substituted.
- Scope: functions defined at the top level are visible everywhere;
  functions inside a `.subckt` are visible in it and its nested
  subcircuits. Order does not matter: `.func` after use works
  *(verified)*.
- On `.model` lines the search starts after `.model name type`, so
  `type(…)` is not taken as a call.

### 2.5 Subcircuit parameters, X lines, scope

Manual §2.11.3, §2.11.4, §2.6. Source: `inp_fix_subckt` (3734),
`inp_get_subckt_name` (4083), `inp_get_params` (4102),
`inp_fix_inst_line` (4159), `nupa_subcktcall` (`xpressn.c:1568`).

```
SubcktCard <- '.subckt' Name Node* ( 'params:'? ParamDef+ )?
ParamDef   <- Ident '=' Value
XLine      <- 'x' Name Node* SubName ( 'params:'? ParamDef* )
```

- **Where the node list ends**: on `.subckt` and X lines, the first
  `name=` pair (found by the first `=` that is not part of `==`, `!=`, `<=`,
  `>=`) starts the parameter section. For an X line, the subcircuit name is
  the **last token before that first `name=`**, or the last token of the
  line if there is none. Nodes are everything between the instance name and
  the subcircuit name.
- `params:` is optional on both lines. It must be preceded by whitespace.
  It is stripped and re-inserted canonically (pass 8) in all modes except
  hs and spice3.
- Optional parentheses around the node list: `.subckt name (1 2 3)` and
  `x1 (1 2 3) sub` (`inp_fix_macro_param_func_paren_io`). Also `.macro` =
  `.subckt` and `.eom` = `.ends`.
- **Actual parameters are matched by name** against the `.subckt`
  defaults; the X line is rewritten to list all values positionally.
  **An unknown name on the X line is silently ignored** *(verified:
  `bogus=5`)*, except `m`, which is added to the subcircuit
  (`inp_fix_subckt_multiplier`, 4227). Actuals that are not a number,
  `{…}` or `"…"` get wrapped in braces.
- Values: SPICE number, brace expression or double-quoted string. In
  `nupa_subcktcall`, an actual starting with something other than a letter,
  digit, `.`, `"` or `{` gives "symbol not understood".
- Scope (manual §2.11.4): `.param` outside any `.subckt` is global;
  `params:` defaults and `.param` inside a `.subckt` are local and mask
  globals; nesting depth up to 10 per the manual. Subcircuit and model names
  are global. `.subckt` definitions may nest (`inp_check_syntax` tracks
  depth).

### 2.6 B-source (ASRC) expression grammar

Sources: `spicelib/parser/inpptree-parser.y` (grammar),
`inpptree.c:PTlex` (1403), `inpptree.c` function table (139),
`inpcom.c:inp_bsource_compat` (7412) and `inp_modify_exp` (7560); manual
§5.1.

Bison precedence, loosest first (`inpptree-parser.y`):

```
%left   ','
%right  '?' ':'
%left   TOK_OR                 ||
%left   TOK_AND                &&
%left   TOK_EQ TOK_NE          ==  !=  <>
%left   TOK_LE TOK_LT TOK_GE TOK_GT
%left   '-' '+'
%left   '*' '/'
%left   NEG '!'                unary -, unary +, !
%left   '^'                    ^ and **
```

So, unlike numparam: equality is looser than relational (C-like); unary
minus binds looser than `^` (`-2^2` = -4, same result as numparam) and `^`
is **left**-associative (`2^3^2` = 64 *(verified)*); a ternary is
right-associative; there is no `%` and no `\`.

```
BExpr   <- Tern
Tern    <- Or ('?' Tern ':' Tern)?
Or      <- And ('||' And)*
And     <- Eq ('&&' Eq)*
Eq      <- Rel (('==' / '!=' / '<>') Rel)*
Rel     <- AddB (('<=' / '<' / '>=' / '>') AddB)*
AddB    <- MulB (('+' / '-') MulB)*
MulB    <- Neg (('*' / '/') Neg)*
Neg     <- ('-' / '+' / '!') Neg / PowB
PowB    <- Prim (('^' / '**') Prim)*                 # left-assoc
Prim    <- Number / VRef / IRef / FCall / Name / '(' BExpr ')'
VRef    <- [vV] '(' NodeTok (',' NodeTok)? ')'
IRef    <- [iI] '(' DevTok ')'
FCall   <- Name '(' BExpr (',' BExpr)* ')'
```

Lexer and pre-processing facts:

- `v(a)`, `v(a,b)` and `i(vname)` are recognised by `sscanf` patterns
  before anything else; inside the parentheses a name is any run of
  characters other than blank, tab, `,`, `(`, `)` (PTlex, 1559-1592).
- Numbers go through `INPevaluate` (so `2meg`, `1mil`, `1d3` all work,
  §1.10). A failed number becomes a name, delimited by blank, tab,
  `( ) ^ + - * / ,`.
- Before parsing, `inp_bsource_compat` + `inp_modify_exp` rewrite the
  right-hand side: braces are dropped, every number is reprinted as
  `%18.10e`, and **every bare identifier other than a function name
  (followed by `(`), `time`, `temper`, `hertz`, `pi`, `e`, `pwl` becomes
  `({name})`**, i.e. a numparam parameter evaluated at expansion time.
  Tokens are re-joined with blanks, which is why `a<b` without spaces
  still lexes. Rewriting stops at `tc1=`, `tc2=`, `reciproctc=`, `m=`,
  `reciprocm=`; `temp=`/`dtemp=` are passed through.
- Built-in functions: `abs acos acosh asin asinh atan atanh cos cosh exp ln
  log log10 sgn sin sinh sqrt tan tanh u uramp ceil floor nint u2 pwl
  pwl_derivative pow pwr min max ddt`, plus `ternary_fcn` and `gauss`
  (special-cased in `PT_mkfnode`), and the internal `eq0 ne0 gt0 lt0 ge0
  le0`. `log` is natural log here too. Constants: `pi`, `e`. Variables:
  `time`, `temper`, `hertz` (`PT_mksnode`, 1324).
- The PWL form `v=pwl(…)` / `i=pwl(…)` skips the rewrite (`=pwl(` test,
  7437).

### 2.7 numparam vs B-source, side by side

| Feature | numparam `{…}` | B-source |
|---|---|---|
| `-2^2` | -4 | -4 |
| `2^3^2` | 64 (left) | 64 (left) |
| `!` vs `^` | `!` tighter | `^` tighter |
| `==` vs `<` | same level | `==` looser |
| `%`, `\` | yes | no |
| `<>` | yes | yes |
| `a*-b` | error | ok |
| hex `0x10` | 16 | syntax error (lexes as `0`, then `10`) |
| `1mil` | 1e-3 | 25.4e-6 |
| function args | ≤ 3 | any |
| node voltages | no | `v()`, `i()` |
| `log` | natural | natural |

## 3. Element lines

### 3.1 The generic instance grammar

Every element line is `name nodes… tail`. The first character of the name
picks the parser (`spicelib/parser/inppas2.c:INPpas2`, 92-265, upper-cases
it and switches). Accepted letters: A (XSPICE builds) B C D E F G H I J K L
M N (OSDI builds) O P Q R S T U V W Y Z. X lines are expanded by the front
end before this. Any other letter gives "unknown device type - error".

All devices except K pairing, P, Y and A finish with `INPdevParse`
(`inpdpar.c:37`):

1. **At most one leading bare number** (`INPevaluate`). What it sets depends
   on the device: R resistance, C capacitance, L inductance, K coefficient,
   V/I dc, E/F/G/H gain, D/Q/J area, Z area (not for MES level 1). S, W, T,
   O, U and B silently drop it. M and N reject it ("no unlabeled parameter
   permitted on mosfet", `inp2m.c:157`). A second bare number is read as a
   parameter *name*: `V1 1 0 1 2` gives "unknown parameter (2)" *(verified)*.
2. Then `name value` pairs in any order; later repeats overwrite. The name
   is read with `INPgetTok`, the value according to the parameter's declared
   type (`INPgetValue`, `inpgval.c:16`):
   - flag (`off`, `on`, `thermal`): no value;
   - real/integer: one number (integers are rounded);
   - real/integer vector (`ic`, `ac`, `pulse`, `sin`, `pwl`, `distof1`, …):
     **numbers until the first token that is not a number**. A `)` does not
     end the vector: `sin(0 1 1k) 5` equals `sin(0 1 1k 5)` *(verified)*. An
     empty vector is an error;
   - instance (`vname` of F/H/W, inductors of K): one name;
   - parse tree (B sources): the rest of the line as an expression.
3. Because `=`, `(`, `)` and `,` are separators (§1.8), `name=value`,
   `name value`, `name=(v1,v2)` and `name v1 v2` are all the same:
   `R1 1 0 resistance 2k`, `C1 2 0 1p ic 0.5`, `Q1 c b e qm ic=0.6, 5.0`,
   `R4 (3, 4) 1k` all parse *(verified)*.

```
Element   <- Letter NameRest (Sep Node)* (Sep Model)? (Sep LeadNum)? (Sep Param)*
Param     <- ParamName ((Sep / '=')+ Value)*     # count decided by the device table
Sep       <- [ \t,=()]+
```

**Node count and model position cannot be decided syntactically for D, Q,
M, N, R, C, L.** The backend looks each token up in the `.model` table
(`INPlookMod`, `inplkmod.c:19`):

| Letter | Nodes | Model token | Source |
|---|---|---|---|
| R C L | 2 | optional; after the optional value, the next token is a model only if a `.model` of that name exists. A token spelled `r`/`c`/`l` means `r=value` | `inp2r.c:160-208`, `inp2c.c:81`, `inp2l.c:79` |
| D | 2, or 3 (third = thermal `tj`) | first token at index ≥ 2 that names a model; required | `inp2d.c:46-63` |
| Q | 3-5 (BJT ≤ 4, VBIC 5); missing substrate/thermal nodes tied to ground | first token at index ≥ 3 that names a model; required | `inp2q.c:54-81` |
| M | 3 (VDMOS) to 7 (B4SOI) | first token at index ≥ 3 for which `INPgetMod` or binning `INPgetModBin` succeeds | `inp2m.c:75-108` |
| J, Z | 3 | 4th token | `inp2j.c:41`, `inp2z.c:49` |
| S | 4 | 5th token, mandatory | `inp2s.c:49` |
| W | 2 + controlling source name | 4th token | `inp2w.c:47` |
| O | 4 | 5th token | `inp2o.c:49` |
| U | 3 | 4th token | `inp2u.c:45` |
| Y | 4 (n1 g1 n2 g2) | 5th token | `inp2y.c:63` |
| P | 2N+2 | the token after the nodes | `inp2p.c:56` |
| N | 1 to the module's terminal count | the last token before the first token containing `=` | `inp2n.c:44-104` |
| A | from the code model | **the last token on the line** | `xspice/mif/mif_inp2.c:211` |
| X | variable | the last token before the first `name=` (§2.5) | `inpcom.c:inp_get_subckt_name` |
| T E G F H V I B K | fixed | none | |

A second, text-only node counter (`inpcom.c:get_number_terminals`, 5273)
is used for subcircuit expansion and unused-model removal, and it can
disagree with the backend: `D1 1 10 dmod 2` (positional area) makes the
front end think the model is `2`, deletes `.model dmod` as unused, and then
fails with "could not find a valid modelname", unless another line also
uses `dmod` *(verified)*. **Grammar recommendation**: parse `name tok+
param*` and resolve nodes versus model in a semantic pass that knows the
model names, as the table says.

### 3.2 Per letter

Forms the front end rewrites before the backend sees them are marked
→ with the rewriting function. Manual section numbers are given per device.

**R, resistor** (manual §3.3.1-3.3.5; `inp2r.c:INP2R`)
```
R <- 'r' Name Node Node Value? Model? RParam*
RParam: r resistance ac temp dtemp l w m tc tc1 tc2 tce scale noisy noise bv_max
```
`R1 1 2 100`, `R2 5 7 1k ac=2k`, `RMOD 3 7 rmodel l=10u w=1u`,
`R1 a b r=1k`, `R1 a b {rv*2}`, `R1 a b rmod 1k` (value after model).
- A line with nothing after the two nodes is **dropped with a warning**,
  not an error ("is not a valid resistor instance line, ignored!",
  `inp2r.c:72`) *(verified)*. Same for C and L.
- `tc=a b` (two blank-separated numbers) is spliced to `tc=a tc2=b`
  (`inp2r.c:101-152`); `tc=1m,2u` fails with "unknown parameter (2u)"
  *(verified)*; ps mode rewrites the comma form.
- → **Behavioral R** (`inp_compat`, 6836): if the text after the nodes
  contains `v(`, `i(`, `temper`, `hertz` or `time`
  (`b_transformation_wanted`, 5861), the value must be `{…}` or `'…'`
  (fatal otherwise) and the line becomes a B source
  `br1 a b i=v(a,b)/(expr) …`, keeping `tc1`, `tc2`, `m`.
- lt mode: RKM values (`4k7`).

**C, capacitor** (manual §3.3.6-3.3.9; `inp2c.c`)
```
C <- 'c' Name Node Node Value? Model? CParam*
CParam: c capacitance cap ic temp dtemp w l m tc1 tc2 scale bv_max
```
`CBYP 13 0 1uf`, `COSC 17 23 10u ic=3v`, `C1 15 5 cstd`, `C1 1 0 c=1p`.
→ behavioral: `q={expr}` anywhere on the line is a charge form; otherwise
the `b_transformation_wanted` test selects a capacitance form
(`inp_compat`, 6918).

**L, inductor** (manual §3.3.10-3.3.13; `inp2l.c`)
```
L <- 'l' Name Node Node Value? Model? LParam*
LParam: l inductance ic temp dtemp m tc1 tc2 scale nt
```
`LLINK 42 69 1uh`, `LSHUNT 23 51 10u ic=15.7ma`. → behavioral form
(`inp_compat`, 7018). `.option rseries` adds a series R
(`inp_add_series_resistor`, 7756).

**K, coupling** (manual §3.3.12; `inp2k.c`)
```
K <- 'k' Name LName LName Value? ('k' Value / 'coefficient' Value)?
   / 'k' Name LName LName LName+ Value        # → split into pairs (inp_compat, 7077)
```
`K43 LAA LBB 0.999`, `K1 L1 L2 k=0.5`. The parser does not enforce
0 < k ≤ 1.

**V, I, independent sources** (manual §4.1; `inp2v.c`, `inp2i.c`,
`devices/vsrc/vsrc.c:12-52`, `isrc/isrc.c`)
```
V <- 'v' Name Node Node LeadNum? SrcParam*
SrcParam <- 'dc' Num                       # 'c' also for I
          / 'ac' Num? Num?                 # [mag [phase]]
          / 'acmag' Num / 'acphase' Num
          / ('distof1' / 'distof2') Num Num?
          / ('pulse' / 'sin' / 'sine' / 'exp' / 'pwl' / 'sffm' / 'am'
             / 'trnoise' / 'trrandom') Num Num+          # vector, ≥ 2 numbers
          / 'r' Num / 'td' Num             # PWL repeat point / delay
          / 'm' Num                        # I only
          / 'external' Str?                # shared-library builds
          / 'portnum' Int / 'z0' Num / 'pwr' Num / 'freq' Num / 'phase' Num   # RF port builds
```
`VCC 10 0 dc 6`, `V1 1 0 dc=1`, `V2 2 0 sin 0 1 1k` (no parentheses),
`V3 3 0 1 ac 2 45`, `V3 3 0 (dc 1) ac=1,45`, `VMEAS 12 9` (dc 0)
*(verified)*.
- Keywords in any order, with or without `=`, parentheses or commas. The
  parentheses are decoration only (vector rule above).
- **A bare `ac` with no number becomes `ac ( 1 0 )`** (`inp_check_syntax`,
  9435) *(verified)*.
- **A bare `distof1`/`distof2` is an error** (empty vector), although the
  manual's own example `IIN1 1 5 AC 1 DISTOF1 DISTOF2 0.001` (§4.1) uses it
  *(verified)*.
- `ac` with 3 numbers is an error. Waveforms need at least 2 numbers.
- PWL `r=` must equal one of the time points. Manual §4.1.4: `r`/`td` only
  on V; the pre-48 source also has them on I (44.2 rejects `r=` on I
  *(verified)*) **[pre-48]**.
- Waveform argument lists: PULSE(V1 V2 TD TR TF PW PER NP) §4.1.1 (with
  `xs` mode the 8th value is a phase); SIN(VO VA FREQ TD THETA PHASE)
  §4.1.2; EXP(V1 V2 TD1 TAU1 TD2 TAU2) §4.1.3; PWL(T1 V1 …) §4.1.4;
  SFFM(VO VA FC MDI FM TD PHASEM PHASEC) §4.1.5; AM(VO VMO VMA FM FC TD
  PHASEM PHASEC) §4.1.6; TRNOISE(NA NT NALPHA NAMP RTSAM RTSCAPT RTSEMT)
  §4.1.7; TRRANDOM(TYPE TS TD P1 P2) §4.1.8; EXTERNAL §4.1.9.
- RF port: keywords `portnum` and `z0`; there is no `port=` (§4.1.11).

**E, VCVS** (manual §4.2.2, §5.2; `inp2e.c`). Backend form only:
`E name n+ n- nc+ nc- gain?` (param `gain`). Everything else is rewritten:

| Form | Example | Rewrite |
|---|---|---|
| Keyword | `E1 n1 n2 vcvs n3 n4 5` | `vcvs` dropped (`inp_compat`, 6217) |
| VALUE | `E41 4 0 value={V(3)*V(3)-Offs}` (`=` optional) | `value` → `vol=` (6222) |
| VOL | `E41 4 0 vol='V(3)*V(3)-Offs'` | E + B source (6457-6491); expression from the first `{` to end of line; no brace → fatal |
| TABLE (PSpice) | `ECMP 11 0 TABLE {V(10,9)} = (-5mV, 0V) (5mV, 5V)` | E + B + XSPICE `pwl` model (6245-6382) |
| TABLE (LTspice) | `Egain out 0 in1 in2 TABLE = (0, 0, 1, 1, 2, 4)` | XSPICE `pwl` (6383-6441) |
| POLY | `ENL 100 101 POLY(2) 3 0 4 0 0.0 13.6 0.2 0.005` | XSPICE `spice2poly` (`xspice/enh/enhtrans.c`), XSPICE builds only |
| SPICE2 poly | `E1 2 0 1 0 0 2` (extra numbers after the gain) | `poly(1)` inserted (`inp_poly_2g6_compat`, 10023), then POLY |
| AND/OR/NAND/NOR | `EAND o 0 and(2) in1 0 in2 0 (0.5, 0) (2.8, 3.3)` | XSPICE `multi_input_pwl` (`inp_chk_for_multi_in_vcvs`, 2466) |
| FREQ | `EX 1 0 FREQ {V(20,21)} = DB (1e7Hz, 1.6e-7, -18.6) …` | XSPICE `xfer` (`replace_freq`, 2610) |
| LAPLACE | `ELP 4 0 LAPLACE {V(1)} {…}` | **unsupported**: no rewrite exists (manual §5.2.5 agrees) |

**G, VCCS** (manual §4.2.1, §5.3; `inp2g.c`): backend `G name n+ n- nc+ nc-
gain? (gain|m)*`. Same rewrites as E with `vccs`, `value` → `cur=`, `CUR=`
(6688-6735), TABLE (PSpice form only), POLY, FREQ. With `cur={…} m=k` the
`m` value becomes the gain of a helper G (`g1 0 5 g1_int1 0 2`)
*(verified)*; `m=` must come after the expression.

**F, CCCS / H, CCVS** (manual §4.2.3-4.2.4): `F name n+ n- vname gain?
(gain|m)*`, `H name n+ n- vname gain?`. Keywords `cccs`/`ccvs` dropped;
`POLY(n) v1 … vn coeffs` → XSPICE; a gain containing `temper` → B source
(6747-6826).

**B, behavioral source** (manual §5.1; `inp2b.c`, `devices/asrc`)
```
B <- 'b' Name Node Node ('v' / 'i') '=' BExpr BParam*
BParam: temp dtemp tc1 tc2 reciproctc m reciprocm
```
`B1 0 1 i=cos(v(1))+sin(v(2))`, `B5 2 0 v = V(1) < {Vlow} ? {Vlow} : V(1)`.
Exactly one of `v=`/`i=`. The expression starts at the first `=` and ends
at the first `tc1=`, `tc2=`, `m=`, `reciproctc=` or `reciprocm=`
(`inp_modify_exp`); `temp=`/`dtemp=` do not end it. Grammar and lexing in
§2.6.

**D, diode** (manual §7.2; `inp2d.c`)
```
D <- 'd' Name Node Node Node? Model Num? DParam*
DParam: off temp dtemp ic area pj perim w l m lm lp wm wp thermal
```
`DBRIDGE 2 10 diode1`, `DCLMP aa cc dmod area=3.0 ic=0.2`. A positional area
is accepted by the backend but fragile (§3.1). In ps mode D has 2 nodes
unless `thermal` is present.

**Q, BJT** (manual §7.3.1; `inp2q.c`)
```
Q <- 'q' Name Node Node Node Node? Node? Model Num? QParam*
QParam: off icvbe icvce area areab areac m ic temp dtemp
```
`Q23 10 24 13 qmod ic=0.6, 5.0`, `Q50A 11 26 4 20 mod1`,
`Q1 7 1 0 sub qmod 2` *(verified)*.

**J, JFET / Z, MESFET** (manual §7.4.1, §7.5.1): `J name nd ng ns model
Num? (off|ic|area|m|temp|dtemp)*`; `Z name nd ng ns model Num?
(area|m|ic|icvds|icvgs|off)*`. The positional area of Z is **silently
ignored for MES level 1** (`inp2z.c:93`) *(verified)*.

**M, MOSFET** (manual §7.6.1, §7.7; `inp2m.c`)
```
M <- 'm' Name Node Node Node Node? Node{0,3} Model MParam*
MParam (mos1): m l w ad as pd ps nrd nrs off icvds icvgs icvbs temp dtemp ic
```
`M1 24 2 0 20 type1`, `M31 2 17 6 10 mosn l=5u w=2u`. No leading number.
The model name may be a binning base (`nch` → `nch.1` …, §4.2).

**N, Verilog-A/OSDI** (manual §9; `inp2n.c`)
```
N <- 'n' Name Node+ Model (PName '=' Value)*
```
`Np1 z a vdd vdd bsimbulk_osdi_p l=0.1u w=1u`. Model = the token before the
first token containing `=` (or before the parameter name if `=` stands
alone). Binning supported. **[pre-48]**: also hosts an `nport` device.

**X, subcircuit call**: §2.5.

**S / W, switches** (manual §3.3.15): `S name n+ n- nc+ nc- model
(on|off)*`; `W name n+ n- vname model (on|off)*`. The model is positional
and mandatory (`ON` in its place is taken as a model name).

**T, lossless line** (manual §6.1; `inp2t.c`): `T name n1 n2 n3 n4
(z0|zo|td|f|nl|v1|v2|i1|i2|ic)*`, no model. `T1 1 0 2 0 z0=50 td=10ns`. A
leading number is dropped silently.

**O, lossy line (LTRA)** (manual §6.2): `O name n1 n2 n3 n4 model
(v1|v2|i1|i2|ic)*`.

**U, uniform RC line** (manual §6.3): `U name n1 n2 n3 model (l|n)*`. U
digital devices (`U2 AND(2) $G_DPWR $G_DGND 4 5 6 M2 IOM2`, manual §10.1)
exist **only in ps mode and only inside a `.subckt`** (translated by
`frontend/udevices.c`); elsewhere `U` is the RC line (manual §10.1.3).

**Y, TXL** (manual §6.4.1; `inp2y.c`): `Y name n1 g1 n2 g2 model (len
Num)?`. Only `len`, compared with `strcmp`.

**P, CPL** (manual §6.4.2; `inp2p.c`): `P name ni1…niN gnd1 no1…noN gnd2
model (len|length Num)?`; N = (tokens before `len` − 2) / 2.

**A, XSPICE code model** (manual §8.1.1; `xspice/mif/mif_inp2.c:MIF_INP2A`)
```
A      <- 'a' Name Conn* Model           # Model = LAST token of the line
Conn   <- '%' PType? (Vec / Port) / Vec / Port / 'null'
Vec    <- '[' (('%' PType)? Port)+ ']'
Port   <- '~'? Node Node?                # two nodes for %vd %id %gd %hd
PType  <- 'v' / 'vd' / 'i' / 'id' / 'g' / 'gd' / 'h' / 'hd' / 'd' / 'vnam' / UdnType
```
`a1 1 2 amp`, `a1 %v(1) %v(2) amp`, `a21 %i[1 %vd(2 5) 7 10] 3 sum2`,
`a1 [~1 2] 3 nand1`. The tokeniser is `MIFgettok`
(`xspice/mif/mifutil.c:63`): `( ) , =` are separators and `% [ ] ~ < >`
are one-character tokens, so `%vd(3 4)` equals `%vd 3 4`. The connection
count and scalar/vector shape come from the code model, not the syntax.
`null` is allowed only where the model permits it, and not inside `[]`.
There are **no instance parameters**: anything extra is "Too many
connections".

## 4. Dot cards

Dispatch (`inp2dot.c:INP2dot`, 1162) compares the first token exactly
(`strcmp`, lower-case). **An unknown dot card is fatal**: "unimplemented dot
command '.foo'", then "Simulation interrupted due to error!" *(verified)*.
So `.step`, `.data`, `.alter`, `.connect` and a `.lib name … .endl` block
written in the main netlist all abort. Messages that say "ignored" are
still fatal: `inp_dodeck` (`frontend/inp.c:1558-1600`) stops at the first
card carrying any error string, unless the line contains `.model` (then
it is only a warning).

### 4.1 Structural cards

**`.subckt` / `.ends`** (manual §2.6; `subckt.c`): grammar in §2.5.
- `.ends` takes an optional name, which is not checked.
- Definitions nest (`find_ends`, `doit`; 21 expansion passes); the syntax
  check warns past 10 levels.
- `.model` names inside become `<subckt>:<model>`; `.param`/`.func` are
  scoped; `.save`/`.ic`/`.nodeset` node names are translated per instance.
  Every other dot line inside a definition is copied verbatim per
  instance. Manual §2.6.1 says control lines may not appear inside; the
  source does not reject them.
- Count mismatch is fatal ("Mismatch of .subckt ... .ends").

**`.model`** (manual §2.5, §3.2.3; `inpdomod.c:INPdomodel`, `inpgmod.c`)
```
ModelCard <- '.model' Sep NetTok Sep TypeTok '('? (Sep? MParam)* ')'?
MParam    <- PName ((Sep / '=')+ Value)?
```
- Parentheses are optional (separators). `.model d1 d is 1e-14` parses.
- Types: `npn pnp d njf pjf nmf pmf nhfet phfet urc vdmos vdmosn vdmosp
  nmos pmos nsoi psoi r res c l sw csw ltra txl cpl ndev numd nbjt numos
  poly`, plus any XSPICE code-model or OSDI module name. Unknown type →
  "unknown model type - ignored".
- **`level` and `version` are found by substring search** on the text after
  the type (`inpfindl.c:INPfindLev`, `inpfindv.c:INPfindVer`), so a
  parameter whose name contains `level` is picked up instead. Level is
  rounded, defaults to 1; version defaults to `default`. Version selects
  BSIM3/BSIM4/HiSIMHV variants by string prefix (`version=3.2.4` → BSIM3v32).
- An instance parameter on a `.model` line sets an instance default
  (manual §3.2.2). An unknown model parameter is a warning ("unrecognized
  parameter - ignored"), not fatal. A bare number is skipped.
- **Duplicate model names: the first definition wins, silently**
  (`inpmkmod.c:INPmakeMod`).
- **Binning** (`inpgmod.c:INPgetModBin`, 254): an instance model `nch` with
  no exact match matches `nch.<digits>`. Only BSIM3, BSIM4, HiSIM2 and
  HiSIMHV are binnable. The instance needs `l=` and `w=`, the model all of
  `lmin lmax wmin wmax`. Both ends are inclusive with 1e-9 absolute
  tolerance. With overlapping bins the model defined **last** wins (the
  table is LIFO).
- ps/lt modes strip `mfg=` etc.

**`.include` / `.inc` / `.incpslt`** (manual §2.8-2.9; `inp_read`, 1493)
```
IncludeCard <- '.inc' [a-z]* Sep Path
Path        <- '"' (!'"' .)* '"' / "'" (!"'" .)* "'" / (![ \t] .)+
```
- Matched by the prefix `.inc`, so `.incfoo` also includes. Case is
  preserved. Processed at read time, so it works anywhere, **including
  inside `.control` and inside a false `.if` block** (always included).
- Path resolution (`inp_pathresolve_at`, 2160): `$VAR` expansion,
  absolute, `~/`, then relative to the **current working directory**, then
  the including file's directory, then each `sourcepath` entry, then the
  directory of the last include. Every file read appends its directory to
  `sourcepath` (`add_to_sourcepath`, 10179). Manual §2.8 mentions only
  relative-then-`sourcepath`.
- `.end` in an included file has no effect.

**`.lib`** (manual §2.10; `expand_section_ref`, 3948)
```
LibRef <- '.lib' Sep Path Sep Section          # in any file
LibDef <- '.lib' Sep Section EOL Line* '.endl' Rest   # only inside the library file
```
- A reference inserts the lines of section `Section` (case-insensitive
  match) of the file; nested references resolve relative to the library
  file. The file is read once (cached by real path). Missing file, section
  or `.endl` is fatal. Lines outside any section are never used.
- Expanded before comment stripping (§1.5).
- lt/ps: `.lib file` is `.inc file`, no sections. s3: not expanded.

**`.global`** (manual §2.7): `.global node+`, split at blanks only
(`vdd,vss` is one name). `0` is always global; `.global gnd` is
auto-inserted.

**`.control` / `.endc`** (manual §12.4.3): the lines between are removed
from the netlist and run as interpreter commands (`inp.c:792-870`).
Nested `.control` is fatal. Inside the block: no quote-to-brace, no
auto-bracing, no whitespace squeeze (except `echo`), only `$ ` comments,
and case is kept for the commands listed in §1.4. The block content is the
control language, out of scope for this grammar. Outside a block, a line
starting `*#` is also a command. Caveat: lines starting `option` inside
`.control` are pulled out as netlist options (`options.c:inp_getopts`).

**`.if` / `.elseif` / `.else` / `.endif`** (manual §2.15; `inp_dot_if`,
7990; `inp.c:dotifeval`)
```
IfBlock <- '.if' Sep? '(' Expr ')' Lines ('.elseif' Sep? '(' Expr ')' Lines)*
           ('.else' Rest Lines)? '.endif' Rest
```
- The first `(` and the last `)` become braces (missing either is fatal),
  numparam evaluates the expression, and the result is read with `atoi`,
  so **`0.5` is false**.
- Evaluated after subcircuit expansion, so `.if` inside a subcircuit sees
  instance parameters. Nesting works.
- The manual's restrictions (no `.subckt .inc .lib .param` inside) are
  pass-order effects: includes are already expanded, `.param` lines are
  hoisted out of the block (pass 15), subcircuits extracted.

**`.end`**: §1.7. **`.title`**: §1.2.

### 4.2 Parameters

`.param`, `.func`: §2.3-2.4. Additionally, all `.param` cards of a scope
are **hoisted to the start of the scope and sorted by dependency**
(`inp_reorder_params`, 5700), so use before definition works; manual
§2.11.1 says otherwise.

**`.csparam`** (manual §2.13): `.csparam (Ident '=' Value)+`; each pair
becomes `let ident = value` in the `const` plot (`inp.c:1107`).

**`.temp`** (manual §2.14): `.temp Num` (also `.temp=Num`). Read after
load; the last one wins; trailing junk (`.temp 25 50`) gives a warning and
**27 °C** (`inp.c:1247`). Overrides `.options temp`.

### 4.3 Options

```
OptionsCard <- ('.options' / '.option' / '.opt') (Sep Opt)*
Opt         <- Name (Sep? '=' Sep? OptVal)?
OptVal      <- '"' (!'"' .)* '"' / '(' ... ')' / Num / Word
```
- Matched by prefix `.opt`. Lines **without** `{` are removed before
  expansion (`options.c:inp_getopts`, 221), so `.options` inside a
  subcircuit is global; they are parsed by the control-language lexer, and
  **unknown names are silently kept as variables**. Lines **with** `{` stay
  in the deck, are evaluated by numparam, and go to `INPdoOpts`, where an
  unknown option is fatal ("unknown option - ignored").
- Options that change parsing: `rseries`, `scale`/`scalm` (hs/spe, early),
  `wnflag`, `seed`, `cshunt`, `rshunt`, `savecurrents`.

### 4.4 Initial conditions

```
IcCard      <- '.ic' (Sep 'v' Sep Node Sep Num)*
NodesetCard <- '.nodeset' (Sep 'v' Sep Node Sep Num)* (Sep 'all' Sep Num)?
```
(`inppas3.c:INPpas3`; manual §11.2). `.ic v(11)=5 v(4)=-5`,
`.nodeset all=1.5`. Separators make `.ic v 1 2.5` legal. No `i(…)`, no
`v(a,b)`: anything else is ".ic syntax error" (fatal). Unknown node: warning.

### 4.5 Output cards

- **`.save`** (manual §11.6.1; `dotcards.c:ft_dotsaves`):
  `.save (all | v(n[,m]) | i(src) | name | @dev[param] | name#branch)+`.
  `i(x)` → `x#branch`; `v(a,b)` saves `a` and `b`.
- **`.print` / `.plot`** (manual §11.6.2-11.6.3): `.print antype ov+`;
  `.plot antype (ov ('(' lo ',' hi ')')?)+`. `antype` is matched as a
  prefix of plot names. Batch mode only. `v(x,0)` → `v(x)`.
- **`.four`** (manual §11.6.4): `.four freq ov+` (prefix `.four`).
- **`.width out=N`**, **`.probe`** (manual §11.6.5), `.sndprint`,
  `.sndparam` (§11.6.8).

**`.meas` / `.measure`** (manual §11.4; tokenised by
`measure.c:measure_parse_line`, 546, dispatched by
`com_measure2.c:get_measure2`, 2003)
```
Meas      <- ('.meas' / '.measure') Sep AnType Sep Result Sep Body
AnType    <- 'tran' / 'ac' / 'dc' / 'sp'          # chkAnalysisType, 146
Body      <- TrigTarg / Find / When / Stat / Deriv / ParamM / Margin / Err
TrigTarg  <- ('trig' / 'delay') Sep TrigSpec Sep 'targ' Sep TrigSpec
TrigSpec  <- Vec (Sep Std)* / 'at=' Num (Sep Std)*
Find      <- 'find' Sep Vec (Sep 'at=' Num (Sep Std)* / Sep 'when' Sep WhenCl)
When      <- 'when' Sep WhenCl
WhenCl    <- Vec '=' (Vec / Num [avfc]?) (Sep Std)*
Stat      <- ('avg' / 'min' / 'max' / 'min_at' / 'max_at' / 'pp' / 'rms'
             / 'integ' / 'integral') Sep Vec (Sep Std)*
Deriv     <- ('deriv' / 'derivative') Sep Vec (Sep 'at=' Num / Sep 'when' Sep WhenCl)
ParamM    <- ('param' / 'expr') '=' '{' Expr '}'
Margin    <- ('phase_margin' / 'phasemargin' / 'gain_margin' / 'gainmargin') Sep Vec (Sep Std)*   # [pre-48]
Err       <- ('err' / 'err1' / 'err2' / 'err3') ...                                              # [pre-48]
Std       <- ('rise' / 'fall' / 'cross') '=' (Int / 'last') / 'last'
           / ('val' / 'td' / 'from' / 'to' / 'at') '=' Num
Vec       <- Name / [vi] '(' ... ')' / ('vdb' / 'vm' / 'vp' / 'vr' / 'vi') '(' ... ')' / 'par(' "'" Expr "'" ')'
```
- Words are split at blanks, or commas outside parentheses; a word ending
  in `=` is glued to the next one. Function words are case-insensitive.
- `Std` values are plain numbers (braces must already be evaluated). RISE,
  FALL and CROSS are mutually exclusive; the last one given wins. `LAST`
  alone means `cross=last`.
- The first word of a TRIG/TARG spec is the vector unless it starts with
  `at` (prefix match, so a vector named `at…` is misread). Each spec needs
  `at`, `rise`, `fall` or `cross`.
- A WHEN right-hand side is a vector if one has that name, else a number
  with an optional unit letter from `avfc` (`INPevaluate2`); arithmetic is
  rejected.
- `param=`/`expr=` measures are evaluated after all others; earlier results
  are visible as parameters.
- In `.meas`, `{LAST}` is passed through as `last`, and `=v(…)`/`=i(…)` are
  not auto-braced (§2.1).
- Manual §11.4 omits `delay`, the margin and `err` functions, and says
  `sp` is for the interactive `meas` only; the source accepts `sp` on
  `.meas`.

### 4.6 Analysis cards

(`inp2dot.c`; sweep keywords via `INPapName` with exact `strcmp`, so
`dec`/`oct`/`lin` must be spelled exactly and `decade` is fatal.)

| Card | Grammar | Source | Manual |
|---|---|---|---|
| `.op` | `.op Rest` (rest ignored) | `dot_op:120` | §11.3.5 |
| `.dc` | `.dc Src Start Stop Step (Src2 Start2 Stop2 Step2)?` | `dot_dc:280` | §11.3.2 |
| `.ac` | `.ac (dec\|oct\|lin) N Fstart Fstop` | `dot_ac:178` | §11.3.1 |
| `.tran` | `.tran Tstep Tstop (Tstart (Tmax)?)? ('uic')?` | `dot_tran:405` | §11.3.10 |
| `.noise` | `.noise 'v' '(' Node (',' Ref)? ')' Src (dec\|oct\|lin) N F1 F2 (PtsPerSummary)?` | `dot_noise:19` | §11.3.4 |
| `.tf` | `.tf ('v(' N1 (',' N2)? ')' / 'i(' VSrc ')') InSrc` | `dot_tf:344` | §11.3.9 |
| `.pz` | `.pz N1 N2 N3 N4 (vol\|cur) (pol\|zer\|pz)` | `dot_pz:243` | §11.3.6 |
| `.disto` | `.disto (dec\|oct\|lin) N F1 F2 (F2overF1)?` | `dot_disto:142` | §11.3.3 |
| `.sens` | `.sens OutVar Filter* ('dc' / 'ac' (dec\|oct\|lin) N F1 F2)?` | `dot_sens:455` | §11.3.7 |
| `.sp` | `.sp (dec\|oct\|lin) N F1 F2 (DoNoise)?` (RF builds) | `dot_sp:1047` | §11.3.8 |
| `.pss` | `.pss GFreq TStab OscNode Points Harms SciIter SteadyCoeff ('uic')?` | `dot_pss:649`; [pre-48] rerouted to the `pss` command (`inp.c:817`) | §11.3.12 |
| `.pac .psp .pnoise .pxf` | pss fields + sweep | `dot_pac:711` … **[pre-48]** | |
| `.hb .qpss .hbosc .phasenoise` | run as commands | `inp.c:806-846` **[pre-48]** | |

Details: `.dc` takes at most two sweeps and has no `lin/dec/oct/list`;
the source may be a V/I source, a resistor, `temp`, or `@inst[param]`
**[pre-48]**; step 0 or a missing token is "Bad syntax!". `.ac` repairs bad
values with a warning (n < 1 → 10, fstart < 0 → 1). In `.tran`, the
optional numbers are detected by number-parse failure; the next word must
be exactly `uic`, otherwise "unknown parameter on .tran - ignored" (fatal).
`.noise` output must start with `v`. Brace expressions work in analysis
cards (`.tran 1n {tstop}`), since numparam evaluates braces on every line.

### 4.7 Ignored or dropped cards

- `.hdl`, `.biaschk`: dropped at read time with a one-time warning
  (`inp_read`, 1472-1491).
- `.prot` / `.unprot`: skipped; they hide the listing in between.
- `.distribution`, `.backanno`: commented out only by ps/lt compat code;
  otherwise fatal as unknown.
- `.macro` / `.eom`: aliases of `.subckt` / `.ends`.
- `.cmodel`: alias of `.model` (`inp_fix_param_values`).
- `.probe`: consumed by `inp_probe` (`inpc_probe.c`).

## 5. Compatibility modes (`ngbehavior`)

Set with `set ngbehavior=…` in `spinit`/`.spiceinit` (manual §12.11,
§13.7; `frontend/inpcompat.c:set_compat_mode`, 61). By default no mode is
set; manual §13.7's "default value is 'all'" is wrong, `spinit.in` sets
nothing.

**Flag parsing is plain substring search** (`strstr`), in this order: `hs`
`ps` `xs` `lt` `ki` `a` `ll` `s3` `eg` `spe` `mc`. Consequences:
- `ltpsa` = `psalt` = lt+ps+a; order and separators do not matter.
- Any `a` anywhere sets "whole netlist", but `a` only matters together with
  `lt` or `ps`, so `hsa` is the same as `hs`.
- `hs` and `ps` together: warning, ps wins. **`hspice` contains `ps`**, so
  it selects ps mode **[pre-48]** (44.2 printed hs).
- `spice3` contains no `s3`, so it selects nothing, although manual §13.7
  lists it. `kicad` sets ki+a; `eagle` sets only a.
- `spe` clears ps, lt, ki, eg.

**Scope.** The `pspice_compat()`/`ltspice_compat()` text rewrites run on
each included file (no `a`) or on the whole deck (`a`, before every
numparam pass). Everything else below is **global** regardless of `a`.
Without `a`, files included from included files are rewritten twice
(duplicated prelude cards). `.incpslt file` reads one file with ps+lt
rewrites, but its parse- and evaluation-time effects (RKM, power rule) do
not apply because the flags are restored right after reading.

### 5.1 Default mode, always on

Already covered above: `$`/`;`/`//` comments, `'…'` → `{…}`, `params:`
handling, `.func`, `.param f(x)=` → `.func`, E/G `value`/`vol`/`cur`/
`table` and behavioral R/C/L → B sources (`inp_compat`, skipped only in
`s3`), `gnd` → `0`, `.lib` sections. Power: numparam `x^y` =
`pow(|x|, y)`; B-source `^` uses the lt rule (negative base, non-integer
exponent → 0) (`ptfuncs.c:PTpowerH`). `pwr` is `|x|^a` in numparam but
`sign(x)·|x|^a` in B sources (`ptfuncs.c:PTpwr`).

### 5.2 ps (PSpice)

Global (any ps):
- `.lib x` → `.inc x`, at every depth; no `.lib` sections.
- **`$` is an ordinary character** outside `.control` (only a leading `$`
  still comments the line), so `$G_DPWR` works as a node name.
- No auto `.global gnd`; `gnd` is not renamed inside a subckt whose
  `.subckt` line lists `gnd`.
- `.model`: `mfg=`, `icrating=`, `vceo=`, non-numeric `type=` removed.
- D has 2 nodes unless `thermal`; subckt names may contain `-`
  (`alfanumps`).
- B-source `exp(x)` is linearised above x = 14.

Text rewrites (`pspice_compat`, `inpcompat.c:664`):
- `ako:` models (`.model q2 ako:q1 npn (bf=60)`).
- `TABLE(…)` function inside E/G `value` → B `pwl`.
- Nested braces `{a*{b}}` → `{a*(b)}`.
- Prelude cards: `.param temp='temper'`, `.param vt=…`, `.param
  gmin=1e-12`, `.func` definitions for `limit`, `pwr` (= `pow`), `pwrs`,
  `stp`, `if(a,b,c)`, `int`. So `TEMP` and `VT` become reserved, and
  LTspice-style `if()` exists only in ps mode.
- U digital devices inside subcircuits → XSPICE (`udevices.c`).
- Commas in `params:` lists → blanks.
- `.model` level 6/7 → BSIM3 3.2.4, level 8 → BSIM4 4.5.0; `lpnp` → `pnp
  … subs=-1`; `dev=`/`lot=` tolerances blanked.
- R/L/C `TC=a,b` → `tc1=a tc2=b`.
- **Operators**: single `&` → `&&`, single `|` → `||`, `~` → `!` (not on
  `.inc`, `.lib`, A lines; also hits paths and strings); `*#` at line start
  → `* #`.
- `.model` `t_abs` → `temp`, `t_rel_global` → `dtemp`, `t_measured` → `tnom`.
- Positional area: `d1 a k dmod 7` → `area=7`; `q1 c b e [sub] qmod 1.35`.
- VSWITCH / ISWITCH models → XSPICE `pswitch` / `aswitch` (the manual
  shows `aswitch` for both).

### 5.3 lt (LTspice)

Global: `.lib` → `.inc`; `mfg=` etc. stripped; **RKM values for R, C, L**
(`4k7`, `4r7`, `r47`, `4meg7`; R has no `f`/`a` suffix, so `1f` is 1 Ω);
numparam `^`: negative base with non-integer exponent → 0. `lt` alone does
not make `$` literal.

Text rewrites (`ltspice_compat`, 1737): nested braces flattened; prelude
`.func uplim dnlim uplim_tanh dnlim_tanh`; `.backanno` commented;
`noiseless` → `noisy=0`; ideal-diode models (`ron roff vfwd …`) → XSPICE
`sidiode`. Not supported in any mode: `.step`, `Rser`/`Rpar`/`Cpar` on C
and L, `table()` in expressions (only ps), LTspice `!` directives (a
leading `!` becomes a comment).

### 5.4 hs (HSPICE)

No text-rewrite pass. Effects: `params:` is kept verbatim (no re-sort);
`m=` inside a multiplied subckt becomes `m={m*(v)}`; numparam and B `^`:
negative base → `pow(x, round(y))`, zero base → 0; `nf` divides `w` in
binning (`wnflag` default 1); `.option scale`/`scalm` read early.
Hierarchical `.lib` sections are the default behaviour, not an hs
feature.

### 5.5 Others

- **ki** (KiCad): `/gnd` and `/0` → `0`; `plot` quotes words containing `/`.
- **s3** (spice3): skips `inp_compat`, `inp_bsource_compat`, `inp_dot_if`,
  `.lib` section expansion; keeps `params:`. So no E `value=`, no
  behavioral R/C/L, no `.if`.
- **spe**: only the hs nf/scale/binning effects; no Spectre syntax.
- **xs**: PULSE's 8th value is a phase.
- **eg**, **ll**, **mc**: no syntax effect.

## 6. Open questions / ambiguities

Manual versus source (the source wins; both noted):

1. **`$` comments.** Manual §2.4.4: `$ ` (dollar space), a bare `$`
   "accepted". Source: the character *before* `$` must be blank, tab or
   `,`; nothing is required after it. `R1 a b 1k$x` only works because the
   number reader ignores junk.
2. **Continuation lines.** Manual §2.4.5: follow-up lines "have to follow
   immediately". Source: comment and blank lines in between are skipped,
   so commenting out the first line of a multi-line card glues its `+`
   lines onto the card before it.
3. **`.end`.** Manual §2.4.2: must be the last line. Source: lines after it
   are parsed *(verified)*.
4. **Leading special characters.** Manual §2.1.2.2: `=[]?()&%$§\"!:`.
   Source: `=[]?()&%$"!:,` plus form feed (no `§`, which is multibyte
   anyway), and `;` silently.
5. **`.param` splitting.** Manual §2.11.1: `.param a = 123 * 3 b = sqrt(9)`
   gives `a = 123`, and `.param c = a + 123` "won't work". Source: both
   statements are right only for multi-assignment lines; a single
   assignment is read to the end of the line (369, *verified*).
6. **Use before definition.** Manual §2.11.1: a parameter must be assigned
   before use. Source: `.param` cards are hoisted and dependency-sorted per
   scope.
7. **Parameter identifier characters.** Manual §2.11.1: letter, then
   letters, digits, `! # $ % [ ] _`. numparam (`fetchid`, `alfa`): letter,
   `_`, `[`, `]` or a byte ≥ 0x80 first; then those, digits and `.`.
   B-source identifier scanning (`inp_modify_exp`) does accept `! # $ %`.
   A grammar should use the intersection: `[a-z_][a-z0-9_]*`.
8. **Expression suffixes.** Manual §2.11.5 lists g, meg, k, m, u, n, p, f;
   numparam also has t and a, has no `mil` (`1mil` = 1e-3), and accepts C
   hex numbers.
9. **Node name characters.** Manual §2.1.3.4 forbids `= % ( ) , [ ] < > ~
   { } '`; the tokeniser only forbids blanks, `=`, `,`, `(`, `)`. The
   others break later passes (XSPICE port syntax, quote and brace
   rewriting). Use the manual's set.
10. **Include search order.** Manual §2.8: relative, then `sourcepath`.
    Source: CWD first, then the including file's directory, then the
    growing `sourcepath`, then the last include's directory.
11. **DISTOF1/DISTOF2 without values.** Manual §4.1 example uses bare
    `DISTOF1`; source rejects an empty vector.
12. **PWL `r`/`td` on I sources.** Manual §4.1.4: V only. pre-48 source:
    also I; 44.2: V only.
13. **`.temp`.** Manual §2.14: `.temp value`. Source also accepts
    `.temp=value`, and resets to 27 °C on trailing junk.
14. **`.meas`.** Function set and `sp` acceptance differ (§4.5).
15. **ngbehavior values.** Manual §13.7 lists `spice3` and a default of
    `all`; source matches substrings (`spice3` selects nothing) and has
    no default. Manual §12.11.1 says plain `ps` affects only included
    libraries; only the text rewrites are scoped that way.
16. **Model binning bounds.** Source comment: `min <= v < max`; code: both
    ends inclusive with 1e-9 tolerance.
17. **Control lines inside `.subckt`.** Manual §2.6.1: not allowed. Source:
    copied per instance.

Ambiguities a PEG has to settle by decision rather than by transcription:

- **Model versus node.** D/Q/M/N/R/C/L need the model-name set (§3.1). The
  grammar can only produce `tok+`; resolution belongs to a semantic pass.
- **Vector length.** Instance vectors take numbers until a non-number, so
  `sin(0 1 1k) 5` extends the vector. A PEG that ends the vector at `)` is
  stricter than ngspice; choose deliberately and document it.
- **Unary minus in numparam.** `a*-b` is an error in ngspice and legal in
  B sources. Accepting it in the numparam grammar is a superset; rejecting
  it matches ngspice.
- **Junk after numbers.** `1k5`, `10Volts`, `1k$x` are numbers with ignored
  junk. A strict grammar should allow only scale suffix plus letters
  (`[a-z]*`), and treat digits after the suffix (`1k5`) as ngspice does
  (ignored) or reject them.
- **Two ngspice versions.** 44.2 and pre-48 differ (`hspice` mode, `r=`
  on I, `.pss` routing, `INPgetNetTok` breaking on `(`). Pin the grammar
  to one version, and tag the newer features.
