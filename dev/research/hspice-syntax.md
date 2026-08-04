# HSPICE netlist syntax: lexical and grammatical rules

Survey date: 2026-10-17. This note collects the HSPICE input rules a parser
needs, each with an example, the source that states it and, where it differs,
what ngspice does. It is meant to be enough to audit `src/frontend/lines.zig`
(the `hspice` dialect) and to write a PEG reference grammar for differential
testing. Rule ids (`L3`, `E2`, ...) are for cross-referencing; they mean
nothing outside this file.

Synopsys does not publish the manuals. The copies below are university
mirrors of shipped PDFs; every page number is the printed page. Where two
versions disagree both are quoted, and the disagreement is listed in "Open
questions / ambiguities" at the end.

## Sources

Primary (Synopsys manuals):

- **UG08**: *HSPICE User Guide: Simulation and Analysis*, B-2008.09,
  <https://cseweb.ucsd.edu/classes/wi10/cse241a/assign/hspice_sa.pdf>.
  Ch. 4 "Input Netlist and Data Entry" (pp. 39-79), ch. 8 "Elements"
  (pp. 127-178), ch. 9 "Sources and Stimuli" (pp. 179-271), ch. 10
  "Parameters and Functions" (pp. 273-292).
- **UG06**: *HSPICE Simulation and Analysis User Guide*, Y-2006.03,
  <http://www.rudraj.it/hspice_sa.pdf>. Ch. 3; used to show how rules changed.
- **SH01**: *Star-Hspice Manual*, Release 2001.2,
  <https://www.ee.columbia.edu/~kinget/EE3081_F02/documentation/hspice.pdf>.
  Ch. 3 "Specifying Simulation Input and Controls" (pp. 3-2 to 3-16) and
  ch. 20 (model selector, p. 20-9).
- **CR10**: *HSPICE Reference Manual: Commands and Control Options*,
  E-2010.12,
  <https://nthuee.org/archive/AIC/106%E8%AC%9D%E5%BF%97%E6%88%90/Hspice/hspice_cmdref.pdf>.
  Ch. 2 (one entry per dot command, alphabetical) and ch. 3 (options).
  The B-2008.09 edition (<https://cseweb.ucsd.edu/classes/wi10/cse241a/assign/hspice_cmdref.pdf>)
  was downloaded but only spot-checked; newer editions (2013, 2014) found
  on eetop/usermanual.wiki mirrors refused the download (403/ACL).

Primary (open-source implementations of the dialect):

- **XDM**: Xyce XDM netlist translator, <https://github.com/Xyce/XDM>,
  commit `b6394a0275eb94f39b86584fa1e0fa9a3766ed23`. Files:
  `src/c_boost/xyce/HSPICEGrammar.hpp` (Spirit line grammar, cited `H:`),
  `src/c_boost/xyce/parser_interface.hpp` (line reader, `P:`),
  `src/c_boost/xyce/hspice_parser_interface.cpp` (`C:`),
  `src/c_boost/expr/hspice_arithmetic_grammar.hpp` (expressions, `A:`),
  `src/python/xdm/inout/readers/HSPICENetlistBoostParserInterface.py` (`Py:`).
  It is a loose recognizer for translation, not a faithful HSPICE lexer;
  claims marked *(inferred)* come from reading the PEG-like Spirit rules,
  not from running them (Boost was not available to build it).
- **NG**: ngspice master, commit `940bb50fab46de3c2618508735f1db208064d3be`
  (2026-10-16), paths relative to the source root; behaviour marked
  **[44.2 run]** was confirmed by running the installed ngspice-44.2 in batch
  mode. **NGM**: *ngspice User's Manual*, "Version 47+" development build
  (PDF dated 2026-09-28).
- **XRG**: *Xyce Reference Guide* 7.9,
  <https://xyce.sandia.gov/files/xyce/Xyce_Reference_Guide_7.9.pdf>.

Secondary, noted but not read for this survey:
[tree-sitter-spice](https://github.com/ChrisVilches/tree-sitter-spice)
(ngspice-oriented), [netlist-db](https://github.com/zao111222333/netlist-db)
(a Rust HSPICE parser, "under building"),
[spice-netlist-ls](https://github.com/smprather/spice-netlist-ls)
(multi-dialect formatter/LSP). None of them cites the HSPICE manual for its
rules.

## 1. From physical lines to statements

HSPICE reads a file as physical lines, joins continuations, drops comments,
and only then tokenizes. This stage is not context-free (continuation and
title depend on line position), so a reference grammar should run it as a
separate pass and apply the PEG of sections 2-6 to each logical statement.

### L1. Title line

- **Rule.** The first line of the top-level netlist is the title, whatever it
  contains; it is never executed. `.TITLE text` on line 1 is an optional
  spelling of the same thing. The first line of an *included* file is an
  ordinary line.
- **Example.** `.ABC Title Line` on line 1 is a title, not a command.
  `.TRAN 1n 10n` on line 1 is a title and no transient runs.
- **Source.** UG08 p. 45 (Table 4: "First line of a netlist: any character:
  Title or comment line. The first line of an included file is a normal line
  and not a comment"); UG08 p. 55 ("If any statement appears as the first line
  in a file, simulation interprets it as a title, and does not execute it");
  CR10 `.TITLE` p. 312 (`.TITLE string_of_up_to_73_characters`, or up to 80
  without `.TITLE`). `.ALTER` does not accept `.TITLE`; its title is the rest
  of the `.ALTER` line (CR10 `.ALTER` p. 33, up to 80 characters).
- **ngspice.** Same first-line rule. XDM turns the logical line that contains
  physical line 1 into the title, so a `+` line after it is appended to the
  title (C:58-61), and a blank line 1 is skipped so no title is found
  (P:132-136). The HSPICE manuals are silent on both cases.

### L2. Whole-line comments

- **Rule.** A line whose first character is `*` is a comment. A line whose
  first non-blank character is `$` is a comment (the inline rule L3 applied at
  the start of a line).
- **Example.**
  ```
  * RF=1K GAIN SHOULD BE 100
  $ MAY THE FORCE BE WITH MY CIRCUIT
  $+ LMIN=3.5 LMAX=4.5      (a commented-out continuation line)
  ```
- **Source.** UG08 pp. 55-56 ("comments that are not the first line of the
  netlist require an asterisk (*) as the first character in a line or a
  dollar sign ($) directly in front of the comment anywhere on the line");
  UG08 p. 46 Table 4 (`*` first character: comment line). SH01 p. 3-9 says
  "an asterisk (*) as the first **nonblank** character"; UG08 says "first
  character". The `$+ LMIN=...` example is SH01 p. 20-9. UG06 p. 31 adds `#`
  as the comment character for HSPICE RF only; UG08 drops it.
- **ngspice.** `*` in column 1, `#` in column 1 (turned into `*`), and a line
  with only whitespace before `$`, `;` or `//` becomes a comment
  (NG `src/frontend/inpcom.c:3592` `inp_stripcomments_line`, `:3600-3602`,
  `:3666-3685`). A leading character from `=[]?()&%$"!:,\f` is replaced by
  `*` with a warning (`inpcom.c:9297-9316`). XDM trims the line first, so
  `*`, `$` and `//` start a comment in any column (P:161).

### L3. Inline `$` comments

- **Rule.** `$` starts a comment that runs to end of line when it is
  preceded by whitespace, a comma, or the end of a valid numeric value. A `$`
  inside a name is part of the name. The numeric case means a number followed
  directly by `$` ends the number: trailing unit letters are dropped (L13),
  but a scale factor still applies.
- **Example.**
  ```
  R12 1 0 1MEG $ FEED BACK
  .PARAM a=1w$comment     $ a=1  ("w" is a unit, ignored)
  .PARAM a=1k$comment     $ a=1e3 ("k" is a scale factor)
  R1 1$ 2 1k              $ error: "1$ 2 1k" -> node "1", comment " 2 1k"
  R1 2 1$ 1k              $ warning: read as "R1 2 1" with no value
  ```
- **Source.** UG08 p. 56 ("If it is not the first nonblank character, then the
  dollar sign must be preceded by either: Whitespace, Comma (,), Valid numeric
  expression. You can also place the dollar sign within node or element
  names"); UG08 p. 60 (the two `R1 ... 1$` examples); UG08 p. 42 Table 3 (`$`:
  "Included only" in node, instance and parameter names, "avoid if after a
  number in node name"; delimiter role "In-line comment"). The same text is in
  UG06 p. 41. SH01 p. 3-3 is stricter: "entering a dollar sign ($), preceded
  by one or more blanks".
- **Quotes.** None of the manuals says whether `$` inside `'...'` or `"..."`
  is a comment. XDM keeps it as part of the expression (H:130-135).
- **ngspice.** `$` is a comment only if the previous character is space, comma
  or tab (`inpcom.c` in `inp_stripcomments_line`:
  `(d[-2] == ' ') || (d[-2] == ',') || (d[-2] == '\t')`). So the HSPICE
  "after a number" case `1k$c` is a syntax error in ngspice, and the node name
  `a$b` is legal **[44.2 run]**. Inside quotes `$`, `;` and `//` are not
  comments (`inpcom.c:3617-3630`); `.param s1='1 + 2 $ 3'` is a syntax error
  at `$` **[44.2 run]**. In ps mode `$` is an ordinary character. XDM attaches
  `$...` as an inline comment with optional whitespace before it (H:846), and
  whether `$` ends a token depends on the token type: identifiers stop at `$`
  (H:101-102), node names accept `$` after the first character (H:109-110),
  unquoted expressions absorb it *(inferred)*.

### L4. Other comment characters

- **Rule.** HSPICE documents only `*` and `$`. `;` is a legal character in
  node, instance and parameter names (UG08 p. 45 Table 3, "; semi-colon:
  Included only"). `//` is not mentioned anywhere.
- **Example.** `.include 'biasckt.inc'; $ semicolon ignored` works only
  because of rule D7 (text after `.include 'file'` is ignored), not because
  `;` is a comment (UG08 p. 41).
- **ngspice.** `;` ends a line anywhere outside quotes (`inpcom.c:3632`), and
  `//` does too, including inside an unquoted `.include` path
  (`Sub//Inc.sp` becomes `Sub`) **[44.2 run]**. XDM accepts `//` comments
  whole-line and inline (H:170, H:174) and keeps `;` out of identifiers
  (H:101).
- **The `*` mid-line puzzle.** CR10 `.BA_ACHECK` p. 36 says a wildcard node
  pattern "must be quoted ... because in HSPICE syntax, all characters after
  unquoted '*' are treated as comments and are ignored". That contradicts `*`
  as multiplication in unquoted expressions (`W=w1*2`) and `**` as power
  (UG08 p. 40). See Open questions.

### L5. `+` continuation

- **Rule.** A line whose first non-blank character is `+` continues the
  previous statement; the `+` is replaced by a separator. Comment lines (`*`
  or `$`) between the statement and its `+` lines do not break the
  continuation. A `+` line may itself carry only a `$` comment.
- **Example.**
  ```
  .MODEL n1 NMOS $ this is an example of an inline comment
  * This is a comment line and the following line is a continuation
  + LEVEL=3

  Pxxx p n port=portnumber
  + $ **** Voltage or Power Information ********
  + [DC mag] [AC mag phase]
  ```
- **Source.** UG08 p. 40 ("enter a plus (+) sign as the first non-numeric,
  non-blank character in the next line"); UG08 p. 56 (the `.MODEL` example,
  with a `*` line between the statement and its `+ LEVEL=3`); UG08 p. 185
  (the P element syntax with `+ $ ...` lines); CR10 `.LIB` p. 151 (a `$`
  comment line between two `+` lines of a `.PARAM`). SH01 p. 3-3 has the
  same "first nonnumeric, nonblank character" wording.
- **ngspice.** `inp_stitch_continuation_lines` (`inpcom.c:674`) allows leading
  whitespace before `+` (`:683`), replaces `+` by a space, and skips lines
  starting with `#`, `$`, `*` and blank lines between continuation lines
  (`:698-717`). A column-1 `;` line is *not* skipped, because it only becomes
  `*` later (`inp_check_syntax`, `:9319`); `r2 1 0` / `; c` / `+ 2k` loses the
  `2k` **[44.2 run]**. XDM also lets comment lines (P:161-168) and blank lines
  (P:159) sit inside a continuation, and appends a line that starts with `)`
  to the previous statement ("dangling parentheses in .MODEL statements,
  allowable in HSPICE/PSPICE", P:169-174). The `)` rule is not in any HSPICE
  manual.

### L6. Backslash continuation

- **Rule.** A line ending in whitespace followed by `\` or `\\` continues on
  the next line, which does not need a `+`. This works inside quoted strings
  (expressions, paths). A single `\` keeps the whitespace at the join; `\\`
  removes the whitespace between the joined lines, so a path or a token can
  be split mid-word.
- **Example.**
  ```
  Evco osc 0 VOL='voff+gain*\\
  SIN(6.28*freq*(1+V(control))*TIME)'
  ```
- **Source.** UG08 p. 40 ("To continue all HSPICE or HSPICE RF statements,
  including quoted strings (such as paths and algebraics), use a single
  whitespace followed by a backslash ( \) or a double backslash ( \\) at the
  end of the line ... A single backslash preserves white space"); SH01 p. 3-3
  ("The single backslash preserves white space and the double backslash
  squeezes out any white space between the continued lines. The double
  backslash guarantees that path names are joined without interruption");
  UG08 p. 44 Table 3 (`\` and `\\` "requires a whitespace before to use as a
  continuation", "Continuation character for quoted strings (preserves
  whitespace)"); UG08 p. 279 ("The continuation character for quoted
  parameter strings, in HSPICE, is a double backslash (\\). (Outside of quoted
  strings, the single backslash (\) is the continuation character.)"); the
  `Evco` example is UG08 p. 663, which has no whitespace before `\\`.
- **ngspice.** Only `\\` continues (`chk_for_line_continuation`,
  `inpcom.c:2872`; trailing whitespace after it is allowed). It blanks the two
  backslashes and gives the next line a `+` prefix (`:1910-1918`), so the join
  always inserts a space; a single `\` is not a continuation. NGM §2.4.5
  (p. 54): `.title`, `.lib` and `.include` cannot be continued. XDM: `\\`
  joins with no space and is checked first (P:201-216; comment at P:202:
  "inline comments cannot occur after in-expression continuation character
  "\\" in HSPICE"); `\` joins with a space after inline comments are stripped
  (P:217-257); a `+` line after a line ending in `\` is not treated as a
  continuation (P:175).

### L7. Case

- **Rule.** Input is case-insensitive except file names and paths (in
  quotes). Since the 2009.09 release file names after `.INC` and `.LIB` are
  case-sensitive.
- **Example.** `.LIB 'MOS.LIB' TT` and `.lib 'MOS.LIB' tt` read the same
  section of the same file; `.lib 'mos.lib' tt` is a different file on UNIX.
- **Source.** UG08 p. 40 ("Netlist input processing is case insensitive,
  except for file names and their paths"; "ignores differences between upper
  and lower case in input lines, except in quoted filenames"); CR10
  `.INCLUDE` p. 144 and `.LIB` p. 151 ("Any file name following an .INC
  command is case sensitive beginning with the 2009.09 release"); CR10
  `.HDL` p. 132 (module names follow Verilog-A case rules). Whether the
  contents of a `str('...')` string parameter keep case is not stated.
- **ngspice.** `inp_read` (`inpcom.c:1705-1886`) lowers every line, including
  text inside double quotes, except whole lines starting with `.lib`/`.inc`
  (`:1824`) and some `.control` and XSPICE cases. Section names are compared
  with `strcasecmp` (`:539`).

### L8. Line and name length

- **Rule.** UG08 p. 40 says both "HSPICE and HSPICE RF do not limit the
  identifier length, line length, or file size" and "An input statement, or
  equation can be up to 1024 characters long". Names, node names and paths are
  up to 1024 characters (UG08 pp. 41, 47, 59); element names up to 1023 after
  the key letter (UG08 p. 57); file names up to 1024 (UG08 p. 39). Expressions
  are limited to 1024 characters (UG08 p. 50) or 256 (SH01 p. 3-6).
- A reference grammar should impose no length limit; HSPICE's own limits
  conflict.

### L9. End of input

- **Rule.** `.END` ends a simulation run; text after `.END` on the same line,
  and lines after it, are a comment. A file may hold several runs, each ended
  by its own `.END`. `.ALTER` blocks must come after everything else and
  before `.END`. A missing `.END` is an error. A library file must not contain
  `.END`.
- **Example.**
  ```
  MOS OUTPUT
  ...
  .END MOS OUTPUT
  MOS CAPS              <- title of the second run
  ...
  .END MOS CAPS
  ```
- **Source.** CR10 `.END` p. 94 ("Text that follows the .END command is
  regarded as a comment only. An input file that contains more than one
  simulation run must include an .END command for each simulation run");
  UG08 p. 40 (missing `.END` is an error; last `.ALTER` must come before
  `.END`); UG08 p. 67 ("A HSPICE or HSPICE RF library cannot contain the .END
  statement"); UG08 "Ending a Netlist" p. 70. That the line after an `.END`
  is the next run's title follows from L1 and the CR10 example; the manual
  does not say it in words.
- **ngspice.** `.end` is matched, turned into a comment, and reading *does
  not stop*; one `.end` is appended at the very end (`inpcom.c:1901-1907`,
  `:1961`). Cards after `.end` stay in the circuit **[44.2 run]**. `.end`
  inside an include file is commented out the same way.

## 2. Tokens

### T1. Delimiters

- **Rule.** Token delimiters are tab, blank, comma, `=` and parentheses.
  Single and double quotes delimit expressions and file names. `:` delimits
  element attributes (`M1:VGS`). `.` separates hierarchy levels in node and
  instance paths.
- **Example.** These are the same source:
  ```
  V1 1 0 AC=10V,90
  VIN 1 0 AC 10V 90
  ```
  and so are `PULSE(0 5 2N 2N 2N 98N 200N)` and `PULSE 0 5 2N 2N 2N 98N 200N`.
- **Source.** UG08 p. 46 ("Input token delimiters are: tab, blank
  (whitespace), comma (,), equal sign (=), and parentheses ( )"); SH01 p. 3-4
  (same); UG08 p. 183 (the two AC forms); UG08 p. 230 for the FOSTER form
  ("parenthesis, commas, and slashes are separators—they have the same
  meaning as a space"; `/` is a separator only there and in LAPLACE/POLE).
- **Not a plain delimiter everywhere.** Parentheses cannot be pure
  whitespace: `.param x=cos(2)+sin(2)` is legal (CR10 `.PARAM` p. 240,
  example 7) and so are `v(a,b)`, `POLY(2)`, `PWL(1)` and `AND(2)`. The `=`
  must stay significant to pair a keyword with its value (`TC1=0.001`), and
  it is optional in many places (`<C=>capacitance`, `<TC1=>val`, PWL `R` and
  `R=`). See the grammar notes in section 7.
- **ngspice.** ngspice does not treat `=` or parentheses as whitespace in
  general; each card parser handles them. XDM has no global delimiter rule
  either: whitespace is only space and tab (H:178), and each rule lists where
  `=`, `,` and parentheses may appear (H:239-240, H:1063-1064, H:701-721).

### T2. Quoting and braces

- **Rule.** `'...'` and `"..."` both delimit an expression or a file name.
  Curly braces are *not* expression delimiters: HSPICE converts `{` `}` to
  `[` `]` in names. String values use `str('...')`.
- **Example.**
  ```
  .PARAM pWidth='nWidth * npRatio'
  .temp '105 + 3*mytemp'
  .PARAM fltmod=str('bpfmodel')
  m1 vout vin vdd vdd str(pmod) w=4u l=5u
  ```
- **Source.** UG08 p. 46 ("Single (‘) or double quotes (“) delimit
  expressions and filenames"); UG08 p. 41 ("When you use curly braces ( { } ),
  HSPICE converts them to square brackets ( [ ] ) automatically"; reserved
  "() = " ‘"); UG08 p. 44 Table 3 (`{}`: "Auto-converts to square brackets";
  `""` and `‘’` are "Expression and filename delimiter", illegal in names);
  UG08 p. 287 ("The single quotes (‘), double quotes (“), or curly brackets
  ( {} ) do not work for these kinds of delimiters. Instead, use the
  sp1=str('string') keyword"); CR10 `.TEMP` p. 309; CR10 `.PARAM` p. 237.
- **ngspice.** `{expr}` is the native expression syntax. `inp_change_quotes`
  (`inpcom.c:3693`) rewrites alternating `'` into `{` `}` on every non-comment
  line outside `.control` and `.lib` lines. Double quotes are not expression
  delimiters. XDM accepts `'...'` and `"..."` (H:130-135) and does not treat
  `{...}` as an expression delimiter (only in its Xyce-style `B` source,
  H:752-754).

### T3. Numbers

- **Rule.** A number is an integer or real, optionally with an exponent
  (`E` or `D`), *or* with a scale factor, not both. Scale factors are
  case-insensitive: `T`=1e12, `G`=1e9, `MEG` or `X`=1e6, `K`=1e3,
  `MIL`=25.4e-6, `M`=1e-3, `U`=1e-6, `N`=1e-9, `P`=1e-12, `F`=1e-15,
  `A`=1e-18. Trailing letters after the number and scale are a unit comment
  and are not checked.
- **Example.** `10pf`, `10PF` = 1e-11; `1x` = `1meg` = 1e6; `2.5mil` =
  63.5e-6; `5ns` = 5e-9; `1.5VOLTS` = 1.5; `1e-6u` is illegal; `1d3` = 1000.
- **Source.** UG08 p. 48 Table 6 (scale factors, including "MEG or X");
  UG08 p. 49 ("Numbers can use exponential format or engineering key letter
  format, but not both (1e-12 or 1p, but not 1e-6u). To designate exponents,
  use D or E ... Trailing alphabetic characters are interpreted as units
  comments. Units comments are not checked"); SH01 p. 3-5 (same rules);
  CR10 `.END` p. 94 (`V2 2 0 1.5VOLTS`).
- **The `A` trap.** UG08 p. 49: "Scale factor A is not a scale factor in a
  character string that contains amps. For example, HSPICE interprets the
  20amps string as 20e-18mps ..., but it correctly interprets 20amps as 20
  amperes". The sentence contradicts itself as printed; read it as "write
  `20amps` and HSPICE treats it as 20 A" but it does not say how. See Open
  questions.
- **What `1e-6u` does.** The manual only says "not both". It does not say
  whether that is an error or the `u` is a unit comment.
- **ngspice.** Device-line numbers go through `INPevaluate`
  (`src/spicelib/parser/inpeval.c:13-203`): `e`/`E`/`d`/`D` exponents,
  T G K U N P F A, `M` milli unless followed by `EG` (meg) or `IL` (mil),
  **no `X`** (`1x` = 1 **[44.2 run]**), rest of the token ignored, so
  `1e3k` = 1e6. Expression numbers go through numparam `fetchnumber`/
  `parseunit` (`src/frontend/numparam/xpressn.c:640`, `:608`): `sscanf("%lG")`
  (so `{0x10}` = 16), T G K M(EG) U N P F A, **no MIL** (`{1mil}` = 0.001
  while `R 1 0 1mil` = 2.54e-5) and no X **[44.2 run]**. NGM §2.1.3.2-3
  (pp. 48-49) lists T G Meg K mil m u n p f a. XDM's number rule
  (H:113-119) takes a single suffix letter from `afpnumkxg` (no T, MEG or
  MIL, no suffix after an exponent) and is only used for `.DATA` rows and
  `.DC` sweep values; elsewhere values are opaque text.

### T4. Names: elements, nodes, parameters

- **Element names** start with the element key letter (section 4) followed by
  up to 1023 characters (UG08 pp. 57, 63). Subcircuit instances start with `X`.
- **Node names** may be numbers or names. Node numbers run from 0 to
  999999999999999; 0 is ground (UG08 p. 59). Leading zeros in node numbers
  are ignored (SH01 p. 3-4; UG06 p. 32).
- **Parameter names** must begin with a letter; after that, digits and some
  special characters (UG08 pp. 41, 49).
- **Characters.** UG08 pp. 42-45 Table 3 is the authority. Summary for
  HSPICE (not HSPICE RF):

  | Char | Node name | Instance name | Param name | Delimiter role |
  |---|---|---|---|---|
  | `~ ! @ # & \| < >` | anywhere (`!`,`@`,`#` even first) | not first | not first | none |
  | `$` | not first; avoid after a digit | not first | not first | inline comment (L3) |
  | `%` `^` `?` | not first | not first | not first | `^` is power, `?` wildcard |
  | `*` | not first (avoid) | not first | not first (avoid) | comment, wildcard, `**` power |
  | `+` `-` | not first | not first | not first (avoid) | `+` continuation |
  | `_` `/` | anywhere | not first | `_` not first, `/` illegal | none |
  | `[ ]` | not first | not first | not first | none |
  | `{ }` | converted to `[ ]` | not first | not first | |
  | `\` | not first | not first | illegal | continuation (L6) |
  | `:` `;` | not first | not first | not first | `:` element attribute |
  | `.` | **illegal** (hierarchy separator) | not first | not first | keyword lead, hierarchy |
  | `( ) , = " '` blank, tab | illegal | illegal | illegal | token delimiters |

  The "Note" on UG08 p. 42: avoid `* - + ^ /` in parameter names. SH01
  p. 3-3 gives a shorter list: names may contain `! # $ % * + - / < > [ ] _`;
  node names may begin with `# _ ! %`. UG06 p. 32 lets node names begin with
  `! # % * / < > _ ? | . &`.
- **Ground.** `0`, `GND`, `GND!` and `GROUND` are the global ground (UG08
  p. 60; SH01 p. 3-4); UG08 p. 63 also names `!GND`. CR10 `.SUBCKT` p. 300
  lists `0, gnd, ground, gnd!`. Any other name is a separate node: "0 and 0.3
  are different nodes, 1A and 1 are different nodes, 2~ and 2 are different
  nodes" (UG08 p. 60).
- **Trailing letters on node numbers (conflict).** UG08 p. 59: "HSPICE or
  HSPICE RF ignores letters that follow numbers in node names"; UG08 p. 60:
  "1A and 1 are different nodes"; UG08 p. 63: "Node designations that start
  with the same number, followed by any letter, are the same node. For
  example, 1c and 1d are the same node". SH01 p. 3-4: "node 1A is the same as
  node 1. Exception: Star-Hspice recognizes the following special alphabetic
  trailing characters (d, e, f, g, i, m, n, o, p, u, x, k, t)". UG06 p. 32:
  "node 1A is the same as node 1". See Open questions.
- **Hierarchy.** `X1.X2.n1` is node `n1` inside instance `X2` inside `X1`
  (UG08 p. 46). A node name containing `.` is a top-level node unless it
  matches a real path (UG08 p. 60). `<subckt-num>:<name>` (e.g. `10:M5`) is an
  abbreviated path usable in `.PRINT`, `.IC`, `.NODESET` (UG08 pp. 63-64).
  `.OPTION HIER_DELIM` changes `^` to `.` only for Cadence ADE output (CR10
  p. 494); it does not change input syntax.
- **Wildcards.** `*` and `?` are wildcards in `.PRINT`, `.PROBE`, `.IC`,
  `.NODESET` (and `.LPRINT`/`.CHECK` in RF); a wildcard must begin with a
  letter or digit (`.PROBE v(*)` is right, `.PROBE *` is wrong) (UG08 pp.
  41, 61-62).
- **ngspice.** `gnd` is renamed to `0` automatically (`inp_fix_gnd_name`,
  `inpcom.c:2383`) unless `no_auto_gnd` or ps mode; `gnd!` and `ground` get
  no special treatment there. Hierarchy separator in output is `.`.
- **Recommendation for the grammar.** Lex a name as a maximal run of
  characters that are not delimiters (T1), not quotes, and not a `$` that
  satisfies L3. Do the "may not start with" checks as a validation pass, since
  the manual's table is advice ("avoid") as often as it is a rule.

### T5. Reserved words

- `time`, `temper`, `hertz` are predefined variables and cannot be redefined
  (`.param temper=100` is illegal) (UG08 p. 283). "Do not use any of the time
  keywords as a parameter name or node name" (UG08 p. 41).
- Independent-source values cannot use a parameter named `AC ACI AM DC EXP
  PAT PE PL PU PULSE PWL R RD SFFM SIN` (UG08 p. 180).
- Controlled-source keywords must not be node names: `DELAY`, `VCVS`,
  `OPAMP`, `TRANSFORMER` (UG08 pp. 233-235), `VCCS`, `VCR`, `VCCAP` (UG08
  p. 251).
- ngspice has its own list (NGM §2.11.6), not compared here.

## 3. Expressions and parameters

### X1. Where expressions go and how they are delimited

- **Rule.** A quoted expression (`'...'` or `"..."`) can replace any value in
  the netlist. An unquoted expression is allowed when it begins with a letter
  and contains no spaces; a single parameter name is a "simple expression".
- **Example.**
  ```
  .PARAM Pi2='2*Pi'
  .param x=cos(2)+sin(2)              (unquoted: starts with a letter)
  M1 ADDR SIG1 GND SBS N1 w1+w l1+l   (positional unquoted expressions)
  r1 n1 0 R='1k/sqrt(HERTZ)'
  G1 1 0 cur='((1-(a0*v(gate)))/b0)'
  ```
- **Source.** UG08 p. 278 ("In HSPICE, an algebraic expression, with quoted
  strings, can replace any parameter in the netlist"); CR10 `.PARAM` p. 238
  ("Enclose a complex expression in single quotes to invoke the algebraic
  processor, unless the expression begins with an alphabetic character and
  contains no spaces. A simple expression consists of a single parameter
  name"); UG08 p. 59 (the `w1+w` example); CR10 `.PARAM` p. 240 example 7;
  UG08 p. 50 (element expressions that reference `v()`/`i()` are allowed only
  in R, C, L, E and G; `I1 1 0 cur='...'` is "Incorrect").
- **Output statements.** Expressions in `.PRINT`/`.PROBE`/`.MEASURE` use
  `PAR('expr')`, optionally named: `.PRINT DC v(3) gain=PAR('v(3)/v(2)')`
  (UG08 p. 276, p. 279).
- **ngspice.** Expressions are `{...}`; `'...'` is rewritten to `{...}` (T2).
  Unquoted expressions are only accepted in some contexts by numparam.

### X2. Operators

- **Documented set** (UG08 pp. 279-283, Table 19): `+ - * /`, `**` (power;
  also written `^`, UG08 p. 43 Table 3 and p. 40), relational `< <= > >=`,
  `== !=`, logical `&& ||`, ternary `cond ? x : y`. No unary `!` is listed,
  no `%`.
- **Precedence is not documented** in any of the versions read. The only hint
  is the `.IF` guideline: "complex Boolean expressions must not be ambiguous.
  For example, change (a==b && c>=d) to ( (a==b) && (c>=d) )" (UG08 p. 72),
  which suggests relational versus logical precedence is not reliable.
- **Power semantics.** `x**y`: if x<0, x to the integer part of y; if x=0,
  0; if x>0, x^y. `pow(x,y)`: x to the integer part of y. `pwr(x,y)`:
  sign(x)·|x|^y (UG08 p. 280).
- **De facto precedence in the two open implementations** (lowest to
  highest):

  | | XDM (A:322-350) | ngspice numparam (`xpressn.c:673` `fetchoperator`) | ngspice B-source (`inpptree-parser.y:59-68`) |
  |---|---|---|---|
  | 1 | `\|\|` and `&&` (same level) | `?` then `:` | `,` |
  | 2 | `!= == >= <= > <` | `\|\|` | `?:` (right-assoc) |
  | 3 | `+ -` | `&&` | `\|\|` |
  | 4 | `* /` | `== != <> < > <= >=` | `&&` |
  | 5 | `** ^` | `+ -` | `== !=` |
  | 6 | ternary, unary `±`, atoms | `* / % \` | `< <= > >=` |
  | 7 | | `^ **` | `+ -` |
  | 8 | | | `* /` |
  | 9 | | | unary `- !` |
  | 10 | | | `^` (`**` lexed as `^`) |

  All binary operators are left-associative in both XDM and numparam, `^`
  included: numparam gives `2^3^2` = 64 **[44.2 run]**. Unary minus differs:
  XDM parses `-2**2` as `(-2)**2` = 4 (unary minus is in `factor`), numparam
  treats a leading `-` as `0 - ...` so `-2^2` = -4, but `2*-3^2` = 18
  **[44.2 run]**. ngspice's `^` in hs mode: x<0 gives `pow(x, round(y))`,
  x=0 gives 0, else `pow` (`xpressn.c:787` `operate`; `ptfuncs.c:91`
  `PTpowerH`). HSPICE says "integer part", ngspice rounds. ngspice's `pwr` is
  unsigned in numparam and signed in the B-source parser.
- **Xyce.** `^` is boolean XOR and `**` is power by default (XRG p. 164,
  Table 2-32); `-hspice-ext math` switches to HSPICE meanings and makes `log`
  the natural log (XRG p. 837).

### X3. Built-in functions and variables

UG08 pp. 279-282 Table 19: `sin cos tan asin acos atan sinh cosh tanh abs
sqrt pow pwr log log10 exp db int nint sgn sign def min max val lv* lx* v()
i()`, plus the operators in X2. Notes that change evaluation: `sqrt(-x)` =
-sqrt(|x|); `log(x)` = sign(x)·ln|x|; `log10` and `db` likewise signed;
`sign(x,y)` = sign(y)·|x|; `def(x)` is 1 if parameter x is defined;
`val(r1)`, `val(rload.temp)`, `val(nmos:mos1.rs)` read element and model
values. Variables: `time`, `temper`, `hertz` (UG08 p. 283). Monte Carlo
functions (`agauss`, `aunif`, `gauss`, ...) are covered under `.PARAM`
distribution functions (CR10 `.PARAM` p. 237) and are not listed in Table 19.

- **ngspice.** numparam functions (`xpressn.c:91` `fmathS`) include `ln` and
  natural `log`, `pwr` unsigned, at most 3 arguments per call; the B-source
  list is in `inpptree.c:136-176`. Neither implements `def`, `val`, `db` or
  `sign(x,y)` per this survey's reading.

### X4. `.PARAM`

Forms (CR10 `.PARAM` pp. 237-240; UG08 pp. 274-277; aliases `.PARAMETER`,
`.PARAMETERS`):

```
.PARAM name=1e-12                        simple
.PARAM name='expr'   .PARAM a=b          algebraic
.PARAM f(x,y)='sqrt((x*x)+(y*y))'        user function
.PARAM CentToFar (c) ='(((c*9)/5)+32)'   (space before "(" is fine)
.PARAM mcVar=Agauss(1.0,0.1,1)           distribution function
.PARAM vtx=OPT1(.7,.3,1.0)               optimization guess, low, high[, delta]
.PARAM fltmod=str('bpfmodel')            string
.PARAM f(a,b)=POW(a,2)+a*b g(d)=SQRT(d)  several on one line
+ h(e)=e*f(1,2)-g(3)
```

- Several assignments per line, separated by blanks (UG08 p. 277).
- `.PARAM` with no assignment is illegal (CR10 p. 240, example 10).
- The last definition wins, even for references earlier in the file, with no
  warning (UG08 p. 49, p. 274). Yet "You must define a parameter before you
  use that parameter to define another parameter" (UG08 p. 49). Resolution
  order: literals, then expressions, then function calls (UG08 p. 275).
- User functions: must not reuse a built-in name; every function used inside
  must be defined earlier; `off` voids all user functions (UG08 p. 277).
  Nesting depth and argument count limits conflict between pages (Open
  questions).
- **ngspice.** Multi-assignment lines are split (`inp_split_multi_param_lines`,
  `inpcom.c:5757`); `.param f(x)=` becomes `.func` (`:2945`); a `.param` that
  uses `temper` becomes a `.func` (`:8029`); a top-level `.param` using
  agauss/gauss/aunif/unif/limit is evaluated once (`inp_fix_agauss_in_param`,
  `:8406`).

### X5. Scoping

- **Rule.** `.OPTION PARHIER=GLOBAL|LOCAL`, default GLOBAL. Passing order,
  highest priority first (UG08 p. 275 Table 18):

  | PARHIER=GLOBAL | PARHIER=LOCAL |
  |---|---|
  | analysis sweep parameters | analysis sweep parameters |
  | `.PARAM` (top level / library) | `.SUBCKT` call (instance) |
  | `.SUBCKT` call (instance) | `.SUBCKT` definition (default) |
  | `.SUBCKT` definition (default) | `.PARAM` (top level / library) |

  So under the default GLOBAL rule a top-level `.PARAM Wid=5u` overrides both
  the `.SUBCKT Inv A Y Wid=0` default and an instance `x2 A Y2 Inv Wid=1u`
  (UG08 pp. 285-286 example 2; pp. 290-292, Table 22: r1/r2/r3 all 1.0 under
  GLOBAL, 1/2/3 under LOCAL). A `.PARAM` inside a subcircuit is local to it
  and global to subcircuits below it (UG08 p. 284).
- **Example.** `.OPTION PARHIER=LOCAL` (CR10 p. 582).
- **ngspice.** No `parhier`; scoping is local-masks-global with nesting up to
  10 (NGM §2.11.4), which matches HSPICE LOCAL, not the HSPICE default.

## 4. Element cards

General rules:

- Nodes and model name come first, then keyword parameters in any order
  (UG08 p. 130 for R, p. 135 for C, p. 143 for L).
- `M=val` is the parallel multiplier on every element including `X`, except
  voltage sources; it must be positive; it multiplies hierarchically (UG08
  pp. 58, 74-75). `S=val` is the subcircuit scale when `.OPTION HIER_SCALE=1`
  (UG08 pp. 75-76).
- A model name may be given as `str(pname)` (UG08 p. 289).
- The optional fourth node of Q, J and M (`<ns>`, `<nb>`) and the optional
  model name of R/C/L make positional parsing ambiguous: the parser has to
  know which names are models (or subcircuits under `.OPTION MACMOD`). HSPICE
  resolves `C1 1 2 CAPXX` in favour of a model named `CAPXX` over a parameter
  `CAPXX` (UG08 p. 136).
- Letters differ from ngspice: `B` is an IBIS buffer, `P` a port, `S` an
  S-parameter element, `W` a lossy (RLGC) transmission line. In ngspice `B`
  is the arbitrary behavioral source, `S`/`W` are switches, `P` is the coupled
  multiconductor line, and `A` (XSPICE) has no HSPICE counterpart.

| Letter | Form (UG08) | Notes |
|---|---|---|
| R | `Rxxx n1 n2 [mname] [R=]val [TC1 [TC2]] [TC=] [SCALE=] [M=] [AC=] [DTEMP=] [L=] [W=] [C=] [NOISE=]` (p. 128) | `R='expr'` may use `v()`, `i()`, `time`, `hertz`, `temper` (p. 132); `R='...' CONVOLUTION=0\|1\|2 FBASE= FMAX=` (p. 132); skin effect `R=val Rs=val` (p. 133). Positional `TC1 TC2` after the value. |
| C | `Cxxx n1 n2 [mname] [C=]val [[TC1=]val] [[TC2=]val] [SCALE=] [IC=] [M=] [W=] [L=] [DTEMP=]` (p. 133); `C='expr' [CTYPE=0\|1]`; `Cxxx n1 n2 POLY c0 c1 ...` | POLY coefficients cannot be parameters (p. 134). `C='...' CONVOLUTION=` (p. 137). |
| L | `Lxxx n1 n2 [L=]val [[TC1=]val] [[TC2=]val] [SCALE=] [IC=] [M=] [DTEMP=] [R=]`; `L='expr' [LTYPE=]`; `POLY c0 c1 ...`; `NT=turns` (p. 141) | Model name may follow the value (`<L=>inductance <mname>`, p. 289). |
| K | `Kxxx Lyyy Lzzz [K=]coupling`; `Kxxx Li Lj [K=]IDEAL`; core form `Kaaa Lbbb [Lccc ...] mname [MAG=]` (pp. 144-146) | ngspice expands >2 inductors to pairs (`inpcom.c:7077`). |
| D | `Dxxx n+ n- mname [[AREA=]area] [[PJ=]val] [WP= LP= WM= LM=] [OFF] [IC=vd] [M=] [DTEMP=]`, or `W= L=` forms (p. 162) | |
| Q | `Qxxx nc nb ne [ns] mname [area] [OFF] [IC=vbe,vce] [M=] [DTEMP=]`, or `AREA= AREAB= AREAC= VBE= VCE=` (p. 164) | 3 or 4 nodes; `IC=` takes a comma list. XDM also accepts `[sub]` in brackets (H:1168). |
| J | `Jxxx nd ng ns [nb] mname [[AREA=]area \| W= L=] [OFF] [IC=vds,vgs] [M=] [DTEMP=]` (p. 167) | |
| M | `Mxxx nd ng ns [nb] mname [[L=]length] [[W=]width] [AD= AS= PD= PS= NRD= NRS= RDC= RSC=] [OFF] [IC=vds,vgs,vbs] [M=] [DTEMP=] [GEO=] [DELVTO=]` (p. 169) | **Positional order is L then W**; `.OPTION WL` swaps it (CR10 p. 723). ngspice has no positional L/W. |
| X | `Xyyy n1 ... subnam [par=val ...] [M=val] [S=val]` (pp. 47, 74-76) | Subcircuit name is the last positional token; no `PARAMS:` keyword is documented. ngspice in hs mode does not strip `params:` and fails on it (`inpcom.c:3910`) **[44.2 run]**. Undefined subcircuits are searched for as `<subnam>.inc` (UG08 p. 77). |
| V, I | `Vxxx n+ n- [[DC=]dcval] [tranfun] [AC=acmag [acphase]]`, I adds `[M=]` (p. 180) | `AC=1,90`, `AC 1 90` (p. 183). `tranfun` keywords: `AM DC EXP PAT PE PL PU PULSE PWL SFFM SIN` (and `PRBS`/`LFSR`, p. 184). No DC value: the t=0 transient value is used (p. 184). |
| E | see E1 below | |
| F | `Fxxx n+ n- [CCCS] vn1 gain [MAX= MIN= SCALE= TC1= TC2= M= ABS= IC=]`; `POLY(ndim) vn1 ...`; `PWL(1) vn1 ...`; `gatetype(k) vn1,...vnk`; `DELAY vn1 TD=` (p. 240) | |
| G | see E1 below | |
| H | `Hxxx n+ n- [CCVS] vn1 transresistance ...`; `POLY`, `PWL(1)`, gate, `DELAY` (p. 257) | |
| B | `Bxxx nd_pu nd_pd nd_out nd_in ... buffer=n file='f.ibs' model='name' ...` (p. 176) | IBIS buffer, HSPICE only. |
| P | `Pxxx p n port=N [DC mag] [AC mag phase] [HB ...] [transient] [Z0=] [RDC=] [RAC=] ... [power=]` (p. 185) | Ports numbered 1..N without gaps. |
| S | `S1 nd1 nd2 s_model2` (p. 47) | S-parameter element. |
| T, U, W | `W1 in1 0 out1 0 N=1 L=1` (p. 47) | Transmission lines. |

### E1. E and G (voltage-controlled) forms

UG08 pp. 226-235 (E) and pp. 245-251 (G). `[VCVS]` and `[VCCS]` are
optional keywords; `LEVEL=n` can replace a function keyword:

```
Exxx n+ n- [VCVS] in+ in- gain [MAX=] [MIN=] [SCALE=] [TC1=] [TC2=] [ABS=1] [IC=]
Exxx n+ n- [VCVS] POLY(NDIM) in1+ in1- ... p0 p1 ... [options]     (also POLY=NDIM)
Exxx n+ n- [VCVS] PWL(1) in+ in- [DELTA=] x1,y1 x2,y2 ... x100,y100 [IC=]
Exxx n+ n- [VCVS] AND|NAND|OR|NOR(k) in1+ in1- ... x1,y1 ...
Exxx n+ n- [VCVS] DELAY in+ in- TD=val [SCALE=] [TC1=] [TC2=] [NPDELAY=]
Exxx n+ n- LAPLACE in+ in- k0, k1, ..., kn / d0, d1, ..., dm
Exxx n+ n- POLE in+ in- a az1, fz1, ... / b, ap1, fp1, ...
Exxx n+ n- FREQ in+ in- f1 a1 ph1 ... [DELF=] [MAXF=] [LEVEL=] [ACCURACY=]
Exxx n+ n- FOSTER in+ in- k0 k1 (ReA1, ImA1)/(Rep1, Imp1) ...
Exxx n+ n- VOL='expr'              (VOL, VALUE are synonyms)
Exxx n+ n- noise='expr'   |   Exxx n+ n- noise data=dataname
Exxx n+ n- OPAMP in+ in-          =  Exxx n+ n- in+ in- level=1
Exxx n+ n- TRANSFORMER in+ in- k  =  Exxx n+ n- in+ in- level=2 k

Gxxx ... same linear/POLY/PWL/gate/DELAY/LAPLACE/POLE/FREQ/FOSTER, plus [M=]
Gxxx n+ n- [VCCS] NPWL(1)|PPWL(1) in+ in- ... [SMOOTH=1|2]
Gxxx n+ n- VCR in+ in- transfactor ...      (LEVEL=1, voltage-controlled resistor)
Gxxx n+ n- VCCAP PWL(1) in+ in- ...         (LEVEL=2 NPWL, LEVEL=3 PPWL)
Gxxx n+ n- CUR='expr'              (CUR, VALUE are synonyms)
```

- `POLY(n)` and `POLY=n` are both legal (UG08 p. 217). With one coefficient a
  1-D POLY means P1 (P0=0) (UG08 p. 218).
- In LAPLACE, POLE and FOSTER, the `/` splits numerator from denominator and
  commas are separators (UG08 pp. 227-230). PWL pairs are written `x,y`.
- `VOL=` is listed only as a parameter (UG08 p. 235) and in examples
  (`Evco out 0 VOL='...'`, UG08 p. 237; `E1 ee 0 vol=f(v(1), v(2))`, p. 239);
  `CUR, VALUE` likewise (UG08 p. 250; `Gdio 5 0 CUR='1e-14*(EXP(V(5)/0.025)-1.0)'`,
  p. 255).
  No syntax line gives the full option list for these forms.
- `TABLE` is not an HSPICE E/G keyword in UG08; it is PSpice. HSPICE uses
  `PWL(1)`. XDM accepts both `TABLE` and `VALUE`/`VOL`/`CUR` (H:1359-1394)
  and has no LAPLACE, POLE, FREQ, DELAY, OPAMP, TRANSFORMER, NPWL/PPWL or
  `SCALE=`/`TC1=` tail.
- **ngspice.** `inp_compat` (`inpcom.c:6181`, doc comment `:6138`): blanks
  `vcvs`/`vccs`/`cccs`/`ccvs` only when the token count is exactly right
  (`replace_token`, `:7371`); `value=` becomes `vol=`; `vol=`/`cur=` becomes
  an E/G of gain 1 driven by a generated B source; `TABLE` becomes an XSPICE
  `pwl` model; `FREQ` becomes an XSPICE `xfer` model (`:2610`);
  `and(`/`or(`/`nand(`/`nor(` become `multi_input_pwl` (`:2466`); LAPLACE is
  not translated (`:10071`; NGM §5.2.5 says use `s_xfer`). XRG p. 233: VOL is
  a synonym for VALUE on the Xyce E source, CUR on the G source.

### E2. Independent source functions

UG08 pp. 189-210. Parentheses are optional everywhere (they are delimiters):

```
PU[LSE] [(] v1 v2 [td [tr [tf [pw [per]]]]] [)] [PERJITTER= [SEED=]]
SIN [(] vo va [freq [td [q [j]]]] [)]
EXP [(] v1 v2 [td1 [t1 [td2 [t2]]]] [)]
PWL [(] t1 v1 [t2 v2 ...] [R[=repeat]] [TD=delay] [)]
PL  [(] v1 t1 [v2 t2 ...] [R[=repeat]] [TD=delay] [)]     (value-first ASPEC form)
PWL (TIME, PV)  with  .DATA name / TIME PV / t1 v1 ... / .ENDDATA
SFFM [(] vo va [fc [mdi [fs]]] [)]
AM [(] sa oc fm fc [td] [)]
PAT [(] vhi vlo td tr tf tsample data [RB=val] [R=repeat] [)]
PAT [(] vhi vlo td tr tf tsample [comp1 ... compn] [RB=] [R=] [)]
```

- `R` with no value repeats from the start; `R 60n` and `R=60n` both work
  because `=` is a delimiter (UG08 p. 200 example: `pl 0v 60n, 0v 120n, ...,
  r 60n`). PWL pairs may be comma-separated
  (`pwl 60n 0v, 120n 0v, 130n 5v, ... , r`).
- PAT data is a b-string (`b1011`, `b0m1z`); nested components use square
  brackets; the b-string, `R` and `RB` cannot be parameters (UG08 pp. 207-210).
  `.PAT name=data` defines named patterns (UG08 p. 210).
- `PE`, `PL`, `PU` are short forms (reserved list, UG08 p. 180; PU = PULSE,
  UG08 p. 189; PL = ASPEC PWL, p. 199).
- **ngspice.** No `PAT`, `PL`, `PU`; PWL `r=` and `td=` exist with different
  rules (not surveyed here). XRG: Xyce supports PAT without `RB`, `ENCODE`,
  `RD_INIT` (XRG, independent sources). XDM recognizes only PULSE SIN EXP
  PWL SFFM and swallows `R`/`TD=` as opaque tokens *(inferred)*.

## 5. Dot cards

Keywords are case-insensitive. Aliases come from the CR10 entry titles.

### D1. Subcircuits

```
.SUBCKT subnam n1 n2 ... [par=val ...]        ...  .ENDS [subnam]
.MACRO  subnam n1 n2 ... [par=val ...]        ...  .EOM  [subnam]
.SUBCKT subnam n1 ... [param=str('string')]
.SUBCKT analyses_sb start=p1 stop=p2 steps=p3   (isomorphic analyses: .DC/.AC/.TRAN inside)
```

- `.MACRO`/`.EOM` is the same as `.SUBCKT`/`.ENDS` (CR10 p. 164, p. 102).
- `.ENDS` without a name "Terminates all subcircuit definitions that begin
  with a .SUBCKT command" (CR10 p. 98); `.EOM` without a name likewise for
  `.MACRO` (CR10 p. 102).
- Port lists cannot contain ground; duplicate ports are an error
  (`.subckt ABC in in out`), duplicates are made at the call instead
  (UG08 p. 78).
- Subcircuit definitions may nest and may appear inside `.IF` blocks (UG08
  p. 73).
- Header continuation is ordinary: `.macro dlatch` / `+ D Q Qbar CL CLBAR
  flip=vcc` (UG08 p. 76).
- **ngspice.** `.macro`/`.eom` are rewritten to `.subckt`/`.ends` *after*
  numparam processing (`inpcom.c:2898`, run at `:1149`), so `.macro` with
  parameters or `m=` fails **[44.2 run]**. `X1 (a b)` is rewritten to
  `X1 a b` (same function). XDM: `name [(] nodes [)] *(p=v)` (H:1121-1127).

### D2. `.MODEL`

```
.MODEL mname type [LEVEL=n] [pname=val ...]
.MODEL mname type ( [LEVEL=n] pname=val, pname=val ... )
.MODEL mname OPT [METHOD=...] ...
.model mname mosra level=...
```

- Parentheses around the parameter list are optional, and parameters may be
  separated by blanks or commas: "For legibility, enclose the parameter
  assignment list in parentheses and use either blanks or commas" (CR10
  p. 215).
- Types (CR10 p. 214): `AMP C CORE D L NJF NMOS NPN OPT PJF PLOTQ PMOS PNP R U
  W S`, plus a Verilog-A module name after `.HDL` (CR10 p. 132).
- **Binning.** Models with a common root and an extension (`NCH.1`, `NCH.2`,
  `NCH.A`) plus `LMIN LMAX WMIN WMAX` are selected automatically for an
  element that names the root `NCH`; the first model whose range contains the
  element's W and L wins (SH01 pp. 20-9 to 20-10, example `SELECTOR.SP`).
  "If model names contain periods (.), the automatic model selector might
  fail" (CR10 p. 213). `.OPTION WNFLAG` chooses W or W/NF for the bin (CR10
  p. 724). So `.` is legal inside a model name and must not be read
  as a hierarchy separator there.
- **ngspice.** In hs mode `wnflag` defaults to 1 (`inpcom.c:931-960`,
  `inp.c:2909`, `inpgmod.c:269`) and unused bins are pruned (`subckt.c:623`,
  `inp.c:1170`). XDM: `name type [(] [p=v] *([,] p=v) [)]` (H:1063-1064);
  bin lookup falls back to `name.1` (`XDMFactory.py:609-611`).

### D3. File inclusion and libraries

```
.INCLUDE 'path/file'      (.INC, .INCL)
.LIB 'path/file' entry    (library call)
.LIB entry  ...  .ENDL [entry]       (library definition, in a library file)
.DEL LIB 'path/file' entry   |   .DEL LIB libnumber entry
```

- File names must be quoted, "Otherwise, an error message is generated"
  (CR10 `.INCLUDE` p. 144, `.LIB` p. 151). But UG08 p. 51 says quotes are
  needed only "when they begin with a number (0-9)", CR10 `.DATA` p. 66 says
  use simple names without quotes, and the CR10 `.IF` example (p. 143) writes
  `.INCLUDE /myhome/subcircuits/diode_circuit1` unquoted. Accept both.
- Everything after `.include 'file'` and after `.lib 'file' entry` on the
  same line is ignored (`.lib 'mos25l.l' tt, $ comma ignored`); the same holds
  for `.enddata`, `.end`, `.endl`, `.ends` and `.eom` (UG08 pp. 40-41).
- A relative path in a nested `.INCLUDE` or `.LIB` starts from the parent
  file's directory; a path relative to the working directory is also found,
  with a warning (CR10 p. 144; UG08 p. 67).
- Entry names cannot start with a digit; if a file has two entries with the
  same name only the first is loaded (CR10 p. 150). `.ENDL` may repeat the
  entry name (`.ENDL TT`) (CR10 p. 97).
- Library rules (UG08 p. 67): no `.ALTER` in a library; no `.END`; a library
  cannot call its own entry name in the same file (CR10 p. 152 example 3:
  `.LIB 'file3' MOS7` inside `.LIB MOS7` of `file3` is illegal); nesting depth
  is unlimited.
- Subcircuit search order for an undefined `X` call: the input file, then
  `.INC`/`.LIB` files, then `<call_name>.inc` in the input file's directory,
  then `.OPTION SEARCH` directories (UG08 p. 67, p. 77).
- **ngspice.** `.lib file section` is expanded by `expand_section_ref`
  (`inpcom.c:3948`), relative to the including file, cached by realpath
  (`read_a_lib`, `:554`); recursion works in every mode except lt/ps/s3
  (`:1951`), not only hs as NGM §12.11.10 claims **[44.2 run]**. A section
  header is `.lib name` with exactly one token (`:530`); the `.endl` name is
  not checked. `.lib file` without a section fails as "unimplemented dot
  command" in default and hs modes **[44.2 run]**. XRG p. 50: Xyce `.LIB`
  follows HSPICE. XDM's `.INCLUDE` file name allows only `[a-zA-Z0-9.\/:_-]`
  (H:184-186).

### D4. Other structural cards

| Card | Syntax and rules | Source | ngspice |
|---|---|---|---|
| `.GLOBAL` | `.GLOBAL node1 node2 ...` | CR10 p. 114 | supported |
| `.OPTION`, `.OPTIONS` | `.OPTION opt1 [opt2 ...]`; `opt` alone means `opt=1`; last definition wins | CR10 p. 235 | supported (option set differs) |
| `.TEMP`, `.TEMPERATURE` | `.TEMP t1 [t2 ...]`; several values or several `.TEMP` cards sweep; value may be `'expr'` | CR10 pp. 309-310; UG08 p. 66 | one value only; extra tokens give a warning and 27 °C (`inp.c:1247-1275`) |
| `.DATA` ... `.ENDDATA` | inline: `.DATA name p1 p2 ...` then value rows; external: `.DATA name MER` or `LAM` with `FILE='f' p=col ...` `[OUT='f']`; up to 50 parameters, 10 files | CR10 pp. 64-69 | not implemented |
| `.ALTER` | `.ALTER [title]`; blocks after the main netlist, before `.END`; no `.PRINT`/output cards and no E F G H I V elements inside | CR10 p. 33; UG08 pp. 68-69 | not implemented |
| `.IF` `.ELSEIF` `.ELSE` `.ENDIF` | `.IF (cond)` ... `.ELSEIF (cond)` ... `.ELSE` ... `.ENDIF`; nestable; may hold `.SUBCKT`, `.INC`, `.LIB`; may not hold `.END .ALTER .GLOBAL .DEL LIB .MALIAS .ALIAS .LIST .NOLIST .CONNECT` | CR10 p. 142; UG08 pp. 71-73 | outer `( )` become `{ }` (`inp_dot_if`, `inpcom.c:7990`); NGM §2.15 forbids `.SUBCKT .INC .LIB .PARAM` inside |
| `.PROTECT`, `.PROT` / `.UNPROTECT`, `.UNPROT` | bracket an encrypted region; no arguments | CR10 pp. 258, 324 | not surveyed |
| `.CONNECT` | `.CONNECT node1 node2`; node1 replaces node2; same hierarchy level | CR10 p. 61 | not surveyed |
| `.HDL` | `.HDL "file" [module] [alias]`; module and alias may be unquoted; tokens after the alias are ignored; `.va` assumed | CR10 p. 132 | dropped with a warning (`inpcom.c:1472`) |
| `.TITLE` | line 1 only (L1) | CR10 p. 312 | |
| `.END` | L9 | CR10 p. 94 | L9 |

Two `.DATA` details a line reader must handle:

- Data rows inside a `.DATA` block need not start with `+`. CR10 shows both
  `+ 50u 30u 1.2v 1.2pf` rows (p. 67, example 1) and bare rows
  (`0 0.1 1.5u`, p. 67 example 2; `FILE='file1' p1=1 ...` without `+`,
  p. 69). The row count per line need not match the parameter count; values
  are read in order (CR10 p. 65).
- Rows carry unit letters (`1.2v`, `1.2pf`), so T3 applies.

`.IF` cannot split a statement: a `+` line after `.if (...)` does not continue
the statement before it (UG08 p. 73, the `r 1 0` / `.if` / `+ 10k` example).

## 6. Analysis cards (what the parser needs)

All from CR10. `type` is `LIN`, `DEC`, `OCT` or `POI`; `POI` takes a list of
values instead of start/stop. Parameterized forms take `'expr'` or `"expr"`
values.

```
.DC var1 START=start1 STOP=stop1 STEP=incr1
.DC var1 start1 stop1 incr1 [SWEEP var2 type np start2 stop2]
.DC var1 start1 stop1 incr1 [var2 start2 stop2 incr2]
.DC var1 type np start1 stop1 [SWEEP DATA=datanm]
.DC DATA=datanm [SWEEP var2 start2 stop2 incr2]
.DC var1 type np start1 stop1 [SWEEP MONTE=MCcommand]   |   .DC MONTE=MCcommand
.DC DATA=datanm OPTIMIZE=opt RESULTS=meas MODEL=optmod
                                                     (CR10 pp. 71-73)
.AC type np fstart fstop [SWEEP var [START=]start [STOP=]stop [STEP=]incr]
.AC type np fstart fstop [SWEEP var type np start stop]
.AC type np fstart fstop [SWEEP DATA=datanm]   |   .AC DATA=datanm [SWEEP ...]
.AC type np fstart fstop [SWEEP MONTE=MCcommand]     (CR10 pp. 25-27)
.TRAN tstep1 tstop1 [tstep2 tstop2 ...] [START=val] [UIC]
      [SWEEP var type np pstart pstop | SWEEP var start stop step
       | SWEEP DATA=datanm | SWEEP MONTE=MCcommand]
.TRAN DATA=datanm [SWEEP ...]                        (CR10 pp. 313-315)
.NOISE v(out) vin [interval | inter=x] [listckt=] [listfreq=] ...  (CR10 p. 230)
.OP [format time ...] [interpolation]                (CR10 p. 233)
.PRINT antype ov1 [ov2 ...]     .PROBE likewise      (CR10 p. 252)
```

- `MCcommand` is `val`, `val firstrun=num`, `list num`, or
  `list(num1:num2 num3 num4:num5)` with optional parentheses (CR10 p. 72).
- `var` is a source name, an element or model parameter, a `.PARAM` name, or
  `TEMP` (CR10 p. 73).
- Multiple `.TRAN` time pairs (`tstep1 tstop1 tstep2 tstop2 ...`) are legal,
  so `.TRAN` arity is not fixed.

## 7. Notes for a PEG reference grammar

The manuals describe tokens, not a grammar, and three behaviours above cannot
be pure PEG: the title line (L1), continuation joining (L5, L6) and `.END`
truncation (L9). Run these as a pass that turns physical lines into logical
statements, then parse each statement:

1. Line 1 of the top file is the title; stop.
2. Drop lines whose first character is `*` (or first non-blank, see Open
   questions) and lines whose first non-blank character is `$`. Do not let
   them end a pending statement.
3. Strip an inline `$` comment per L3, outside quotes.
4. If the line ends in whitespace + `\\`, join the next line with no space; if
   it ends in whitespace + `\`, join with the whitespace kept. Do this before
   step 3 when inside an open quote.
5. A line whose first non-blank character is `+` is appended to the pending
   statement with a separator.
6. Inside a `.DATA` block, every line up to `.ENDDATA` is a row of that block.
7. On `.END`, stop the run; the next line, if any, is the next run's title.

Statement-level PEG sketch (separators per T1; the comma, `(` and `)` are
separators in positional lists, but a `(` right after a name inside a value
opens a call; this split is this note's reading, not a documented rule):

```
Statement   <- Sep* (DotCard / Element) Sep* !.
Sep         <- [ \t,()]
Item        <- Pair / Value
Pair        <- Name Sep* '=' Sep* Value
Value       <- Quoted / StrCall / Bare
Quoted      <- "'" (!"'" .)* "'" / '"' (!'"' .)* '"'
StrCall     <- [sS][tT][rR] '(' Quoted ')'          # str('x'), case-insensitive
Bare        <- (Call / BareChar)+
Call        <- NameStart NameChar* '(' (Call / !')' .)* ')'
BareChar    <- ![ \t,=()'"] .
Name        <- NameStart NameChar*
Number      <- Mantissa (Exponent / Scale)? Unit?
Mantissa    <- [0-9]+ ('.' [0-9]*)? / '.' [0-9]+
Exponent    <- [eEdD] [+-]? [0-9]+
Scale       <- MEG / MIL / [tTgGxXkKmMuUnNpPfFaA]   # MEG and MIL before M
Unit        <- [a-zA-Z]*                          # ignored, L3 still ends it at '$'
Element     <- [rRcClLkKdDqQjJmMxXvViIeEfFgGhHbBpPsStTuUwW] Name (Sep+ Item)*
DotCard     <- '.' Keyword (Sep+ Item)*
```

`Call` must exclude the keywords that take a parenthesized *list* rather than
a call: source functions (`PULSE PU SIN EXP PWL PL SFFM AM PAT`), `POLY`,
`PWL`/`NPWL`/`PPWL`, gate types, `LAPLACE`/`POLE`/`FREQ`/`FOSTER`, and the
model type after `.MODEL name`. Each card's arity and keyword set then comes
from sections 4-6.

## Open questions / ambiguities

1. **`*` as a comment.** UG08 p. 46/56: first character of the line. SH01
   p. 3-9: first non-blank character. CR10 `.BA_ACHECK` p. 36: "all
   characters after unquoted '*' are treated as comments", which cannot be
   true where `*` is multiplication or `**` power. Likely only in wildcard
   pattern contexts; needs an HSPICE run.
2. **`$` after what.** UG08/UG06: whitespace, comma or "valid numeric
   expression"; SH01: one or more blanks. "Valid numeric expression" is not
   defined: does `x=a+b$c` end at `$` (the expression is not numeric)? Does
   `'1+2'$c` count? Is `$` inside quotes a comment? XDM keeps `$` inside
   quotes; ngspice keeps it inside quotes and rejects it after a digit.
3. **`\` versus `\\`.** UG08 p. 40 says both work for all statements; UG08
   p. 279 says `\\` inside quotes and `\` outside. UG08 p. 44 and p. 40 want a
   whitespace before the backslash; the UG08 p. 663 example has none. Whether
   `\\` deletes leading whitespace of the next line, trailing whitespace of
   this one, or both, is not stated (SH01: "squeezes out any white space
   between the continued lines").
4. **"first non-numeric, non-blank character"** for `+` (UG08 p. 40, SH01
   p. 3-3). The "non-numeric" part is unexplained; it may be a relic of
   numbered card decks. Is `12 + foo` a continuation?
5. **Trailing letters on node numbers.** SH01 and UG06: `1A` is node `1`
   (with exceptions for scale-factor letters in SH01). UG08 p. 59 says the
   same, UG08 p. 63 says `1c` = `1d`, but UG08 p. 60 says `1A` and `1` differ.
   Probably changed between 2006 and 2008 with stale text left behind.
6. **Quoting of file names.** CR10 says `.INCLUDE`/`.LIB` names must be
   quoted; UG08 p. 51 says only names that start with a digit; CR10's own
   `.IF` and `.HDL` examples are unquoted.
7. **Text after `.END` in an included file**, and `.END` inside an included
   file: the manuals only forbid `.END` in library files.
8. **Operator precedence and associativity**, the binding of unary minus
   against `**`, and whether `^` is exactly `**`. None is documented; XDM and
   ngspice disagree on `-2**2`.
9. **Function limits.** Nesting: "up to three levels" (UG08 p. 50, CR10
   p. 238) versus "not more than two deep" (UG08 p. 276). Arguments: "up to
   two" (UG08 p. 50, SH01 p. 3-6) versus "up to 20 (and in many cases, more
   than 20)" (UG08 p. 277).
10. **Parameters defined after use.** "Last definition wins, even if later
    than a reference" and "define a parameter before you use it to define
    another" are both on UG08 p. 49.
11. **Unquoted expressions.** CR10 p. 238 allows an unquoted expression that
    starts with a letter and has no spaces. Are parentheses and commas inside
    it (`cos(2)+sin(2)`, `max(a,b)`) exempt from the T1 delimiter rule? The
    examples say yes for parentheses; commas are not shown.
12. **The `A` scale factor and "amps".** The UG08 p. 49 note contradicts
    itself as printed. The SH01 node-number exception list (`d e f g i m n o
    p u x k t`) also suggests some letters are read as scale factors in node
    numbers.
13. **`1e-6u`.** "Not both" (UG08 p. 49): error, or `u` read as a unit
    comment?
14. **Length limits.** UG08 p. 40 says there is no line-length limit and also
    that a statement can be up to 1024 characters; expressions are 1024
    (UG08) or 256 (SH01).
15. **Dangling `)` lines.** XDM joins a line starting with `)` to the
    previous `.MODEL` and cites HSPICE/PSpice; no HSPICE manual mentions it.
16. **`$`, `;` and `//` inside an unquoted path.** HSPICE does not say. ngspice
    cuts an unquoted `.include` path at `//`.
17. **Newer manuals.** Every rule here comes from 2001-2010 manuals. Later
    editions (2013+) could not be downloaded; behaviour may have changed,
    as the 2009.09 file-name case change shows.
