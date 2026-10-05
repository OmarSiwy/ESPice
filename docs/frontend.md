# Frontend

Netlist bytes in, passive `Prepared = {circuit: device.Circuit, deck:
core.Deck}` out. The frontend has no tokenizer/parser split and builds no
syntax tree: logical lines are split into fields and read straight into flat
tables, subcircuits are flattened while reading, and expressions fold to
numbers as they are read.

    bytes ─include─▶ bytes ─fold case─▶ logical lines ─split─▶ fields ─switch(first byte)─▶ tables

| Stage | File (`src/frontend/`) | In | Out |
|---|---|---|---|
| expand | `source.zig` | bytes + origin path | bytes (`.include`/`.lib` inlined; Spectre skips this pass) |
| lines | `lines.zig` | bytes | lowercased copy, logical lines, field iterator, SPICE numbers |
| netlist | `netlist.zig` + `expr.zig` + `csr.zig` | lines | `Netlist` (below) |
| analyses | `analyses.zig` | `Netlist.deck.analyses` + node rows | `[]Query`, deck options |
| build | `prepare.zig` + `builder.zig` + `spice.zig` | `Netlist` | `Prepared` |

| File | Responsibility |
|---|---|
| `source.zig` | File reads, relative includes and library sections |
| `lines.zig` | Dialect line rules, case folding, the field splitter and numeric suffixes |
| `expr.zig` | Expressions as postfix: compile, fold, subtree walks |
| `csr.zig` | The bipartite hypergraph (adapted from cktImg) |
| `netlist.zig` | Lines to nets × devices, models and analysis cards; parameter scopes, subcircuit frames, model bins |
| `measure.zig` | `.meas` card text to `core.Measure`; HSPICE `.check`, `.dout` and `.biaschk` to violation-counting measures |
| `pattern.zig` | HSPICE PAT sources rewritten to PWL before parsing |
| `vec.zig` | HSPICE `.vec` files to PWL sources and `.dout` cards, during expansion |
| `analyses.zig` | Analysis cards and `.options` to queries |
| `spice.zig` | SPICE device selection: card letter and `.model` LEVEL to a device name, following ngspice |
| `builder.zig` | `NetBuilder`: card binding, net-to-row mapping and circuit topology |
| `prepare.zig` | `prepare` (source and HDL loading), `build` (`Prepared`), `resolveQueries` (appended cards) |
| `root.zig` | Public frontend exports and test registration |

The name pool is `core`'s `InternPool` (`src/core/intern.zig`). The device
catalog and the per-Problem `Library` of device types are
`src/device/Library.zig`; runtime HDL compilation and loading is
`src/device/loader.zig`. The frontend decides which device a card names; the
device module owns what a device is.

The dialect picks the line splitter (comments, continuations), the quote and
brace set of the field splitter, number suffixes, and whether the source is
case-folded. Card keywords go through one `StaticStringMap`
(`netlist.zig cards`), shared by the three dialects because they accept the
same cards. Keywords are looked up lowercased in every dialect.

File I/O stays separate from dialect splitting. The `netlist` build module
imports only `core`, so its tests and `zig build bench-frontend` read decks
without linking any device code. Frontend tests are in
`src/frontend/tests/` (netlist, builder, prepared circuits, device
selection); `zig build test-frontend` runs them.

## Netlist: data in, data out

`netlist.zig` reads the logical lines in three walks, each needing what the
previous one found:

1. declarations: `.subckt` bodies as line ranges, global `.param`, `.model`,
   directives, foreign (`.hdl`) paths;
2. devices: top-level cards become hyperedges; an `X` card re-reads its
   subcircuit's lines under a frame (port map, name prefix, parameter scope),
   so subcircuits are always flattened, named as ngspice names them
   (`r.x1.r1`, net `x1.a`), 32 levels deep at most. Model bins and `.option
   scale` are applied after the walk;
3. analyses: node names resolved to net ids.

Output, all in the parse arena:

| Table | Layout | Rows |
|---|---|---|
| `pool` | `InternPool`: name bytes, `u32` offsets, a map keyed by the dense `Name` id | every net and device name, once |
| `graph` | `BipartiteHypergraph(Net, Device)` | nets are vertices, ground is vertex 0; devices are hyperedges whose members are the pins in terminal order, repeats kept; CSR both ways |
| `graph.edges` | `MultiArrayList`: `kind` (card letter), `name`, `model`, `positional`, `kv` (spans), `subckt_type`, `subckt_instance` (for BBD) | one per flattened device, file order |
| `order` + `kind_starts` | `[]EdgeId` counting-sorted by card letter | the builder's stamping order |
| `values`, `kvs` | flat `[]Value`, `[]Kv` | positional values and `key=value` pairs of devices, models and cards |
| `ops`, `consts` | flat postfix `[]Op` + `[]f64` pool | expressions that do not fold to a number (behavioural sources, unresolved names) |
| `models` | `[]Model`: `name`, `kind`, `kv` (read together), plus a name map | one per `.model` card |
| `deck.analyses` | `[]Analysis`: `kind`, `args`, output nets, `.pz` ports | one per analysis card, file order |
| `deck.config`, `deck.ic`, `deck.foreign`, `deck.title` | small | deck configuration |

Topology (`pool`, `graph`, the value and expression tables, `models`) and
deck data (`deck`) are separate fields, so a consumer that only builds the
circuit never touches the deck, and the reverse.

The six data-design questions for these tables:

1. In: lowercased lines. Out: the tables above. The builder turns them into
   a `Circuit`; `analyses.zig` turns `analyses` into queries once rows exist.
2. How many: devices and nets up to ~10^6 (the stress decks reach 2·10^5),
   2 to 10 params per device, models from a handful to a PDK's thousands,
   analyses under ten, expressions that survive folding: a few per deck.
3. Width: every id (`VertexId`, `EdgeId`, `Name`, model, span start/len) is
   `u32`, the ceiling `Circuit` already has; `kind` is the card letter
   (`u8`); subcircuit type `u16` and instance `u32`.
4. Access: the builder visits devices by letter bucket and reads a device's
   name, pins, values and model together. Params are AoS (`Kv`) for that
   reason; device payload is SoA in the graph because analyses and BBD
   tagging read single columns.
5. Lifetime: one parse arena, released after `build`. `Prepared` copies what
   it keeps into the session arena.
6. Parallel: no. Parsing is a sequential walk; the builder is the cost.

## Expressions

There is no expression tree. An expression is compiled from its text to
postfix, parameters are spliced in from the scope where they were defined,
and the postfix is folded on a value stack. A number is stored as a number.
Only an expression that does not fold keeps its ops in `ops`/`consts`;
behavioural sources are the only consumer that reads inside them
(`builder.zig` probe and polynomial extraction walk the postfix by subtree).
`v(a,b)` probes hold net ids, mapped through the subcircuit frame. A zero
switch still disables a stochastic or geometry term (`0*agauss(...)` folds to
0), as in the nominal PDK corners. `agauss`, `gauss`, `unif`, `aunif` and a
two-argument `limit` fold to their nominal, the first argument, in every
dialect; Monte Carlo sampling is future work (hspice-comparison C3).

A resistor, capacitor or inductor value that did not fold, an undefined name
with no `.model` behind it, is `UnresolvedParameter`. It used to fall back to
the 1 mOhm (or zero) default of a missing value.

## Unsupported input

A card ESPice cannot simulate is `UnsupportedCard`, logged with the line as
written; nothing is dropped silently. That covers dot cards outside `cards`
(`.alter`, `.lstb`, `.data`, `.control`, ...), an E/F/G/H card whose first
control word is a behavioural keyword (`poly`, `value`, `vol`, `laplace`,
`delay`, `vcr`, ...: ngspice's inpcom.c list plus HSPICE's), and in the
HSPICE dialect the B, P, S, U and W letters, which HSPICE reads as IBIS
buffers, ports, S-parameter blocks and lossy lines. Output-only cards
(`.print`, `.plot`, `.probe`, `.graph`, `.width`, `.title`, `.protect`
and friends) are accepted and ignored, since every vector is written. An
analysis card that fails to build logs its line before the error.

## Divergences from ngspice

These are deliberate. None of them changes speed, so there is nothing to
measure; the test named beside each one pins it.

| Input | ngspice | ESPice | Test |
|---|---|---|---|
| `0e400` (zero mantissa, exponent past f64) | 0 × inf = NaN | 0, at any exponent; `1e400` is still inf | `lines.zig` "number literals read as ngspice's INPevaluate" |
| URC model with `K = 1` | lump sizing divides 0 by 0, so the ladder is NaN resistors | `InvalidParameterValue` | `tests/builder.zig` "cards the builder refuses instead of misbinding" |
| URC model with `K <= 0` | no meaningful ladder | `InvalidParameterValue` | same branch (`!(k > 0) or k == 1` in `builder.zig addUrc`) |
| URC card without `l=` | length 0, so 0-ohm lumps | unit length | none |
| Verilog-A `$simparam("gmin")` during gmin stepping | the deck gmin (ngspice steps `CKTdiagGmin`) | the stepped gmin; see [operating-point-homotopy.md](analysis/operating-point-homotopy.md) | `hdl/veriloga_simparam_homotopy.sp` |
| a `.temp` list and a single `.temp` in one deck | no list form (the list is HSPICE's) | the last card wins, list or single value | `analyses.zig` "deckOptions: a NaN RUNLVL fails, and the last .temp card wins" |

For the URC cases, a deck that relied on ngspice's behaviour has to give a
valid `K` (the default is 1.5), and `l=0` to get ngspice's zero length. A
deck that mixed `.temp` forms and meant the earlier list has to drop the
later single card.

## Pole-zero sources

`E|G name out+ out- POLE in+ in- a az1,fz1 ... / b ap1,fp1 ...` [SA
E-element Pole-Zero Function] is H(s) = a (s - z1)...(s - zn) / (b (s -
p1)...(s - pm)) with each root s = -alpha + j 2 pi f, in every dialect. The
builder hands the roots to `laplace_zp` (`models/vcvs_pole.va`,
`vccs_pole.va`, the `LAPLACE_ZP` body of `vcvs_laplace.va`) with the gain
a/b times the product of -r over the nonzero roots, since laplace_zp's
terms are (1 - s/r). Unused root slots hold an infinite root, whose term is
exactly 1. Where this differs from HSPICE, or the manual is silent:

- A complex root needs its conjugate on the same side, written out as the
  manual's examples do; a lone one is `UnpairedPoleRoot`, paired exactly as
  VerA pairs at run time (within 1e-9 relative), so no accepted card
  evaluates to NaN.
- At most 8 roots a side, and no more zeros than poles
  (`UnsupportedLaplaceOrder`). `SCALE=` and `M=` (G only) are read; `MAX=`,
  `MIN=`, `TC1=` and `TC2=` are refused (`UnsupportedLaplaceParameter`).
- A pole at s = 0 has no DC value; the operating point takes 0 there, as
  VerA does for every laplace filter.

The syntax comes from memory of the manual's Pole-Zero Function section and
its examples. It has not been checked against the manual text or a real
HSPICE run.

Oracle decks: `tests/fixtures/hspice/pole_source.sp` (DC and AC),
`pole_step.sp` (transient), `invalid/pole_unpaired_root.sp`.

## HSPICE dialect

`--tokenizer=hspice` also switches these semantics [CR = HSPICE Command
Reference, SA = Simulation and Analysis guide]:

| Input | HSPICE dialect | ngspice dialect |
|---|---|---|
| no `.option tnom`, no `.temp` | TNOM 25 degC, circuit at TNOM [SA Ch.20] | 27 degC both |
| `.temp t1 t2 ...` | every query once per temperature, plots named `<plot> (temp=t)` | three numbers: a DC temperature sweep |
| `.tran s1 t1 s2 t2 ...` | one run to the last stop [CR .TRAN]; the SPICE `tstep tstop tstart tmax` reading only when `s2` and `t2` are both below `t1` and no `START=` | ngspice |
| untyped `.measure name func ...` | the last `.tran`/`.ac`/`.dc` card | rejected |
| unknown `.option` names | one warning each | ignored, as ngspice does |
| `.save [TYPE=NODESET\|IC] [FILE=] [LEVEL=] [TIME=]` | writes the operating point as `.nodeset` (or `.ic`) cards [CR .SAVE] | output vector selection |

HSPICE `.save` writes after the run, beside the output file (the working
directory without one), to FILE= or `<deck stem>.ic0`: every `v(node)`
of the first `.op` result, else of row 0 of the first transient (its
operating point) or DC sweep (its first point); TIME= reads the first
transient at that time, interpolated. LEVEL=TOP drops subcircuit nodes,
NONE saves nothing, SELECT saves every node. `.load [FILE=] [RUN=]`
[CR .LOAD] inlines such a file before parsing, like `.include`, in every
dialect; a file not there yet is skipped with a warning, and RUN= is
accepted and unused (ESPice does not number `.alter` runs' files).
`.store` [CR .STORE] is accepted with a warning: HSPICE checkpoints the
process for an OS-level restore on a wall-clock schedule, which does not
change results, and ESPice writes no checkpoint. Divergence: ESPice's
`.ic` holds nodes only under UIC (`.tran ... uic`), so a loaded TYPE=IC
file forces the operating point only there; HSPICE and ngspice also hold
`.ic` nodes during the transient's operating point.

In both dialects: `.global` nets join through every subcircuit level;
`.connect a b` joins two top-level nets (a subcircuit's `.connect` is
refused); `.dcvolt` is `.ic`, and takes bare `node value` pairs too;
`.nodeset` holds its nodes through a 1e10 S conductance for the operating
point's first Newton solve, then releases them, as ngspice's cktload.c does
in MODEINITJCT/INITFIX (the DC sweep's own points do not read it yet).
`.option gshunt`/`cshunt` add an R and a C from every net to ground
(`r.gshunt.<net>`, `c.cshunt.<net>`), `delmax` caps the transient step when
the `.tran` card gives no tmax, and `gmindc`, `absv`, `relv`, `absi` and
`method=bdf` alias `gmin`, `vntol`, `reltol`, `abstol` and Gear.
Divergence: ESPice's `.tran` segments share the finest segment's step cap.
`.option runlvl`, `accurate` and `fast` set the transient's `trtol`
(docs/analysis/tolerance-system.md, "HSPICE RUNLVL").

`.option search='dir'` [CR .OPTION SEARCH] adds a directory where
`.include`, `.lib` and `.load` look for a file not found beside the file
naming it; each `search=` adds one, tried in deck order, and a relative
one resolves against the deck's directory. Only the top-level deck's
`.option` lines are read, and only their first physical line (a `search=`
on a `+` continuation is missed). Not done: HSPICE's lookup of an
undefined subcircuit `name` as `name.inc` in the search path, and
`$installdir` expansion. Follows the manual; unconfirmed against HSPICE.
Fixture: `tests/fixtures/hspice/search_lib.sp`.

### HSPICE analysis forms

These forms are read in every dialect, because none of them collides
with an ngspice spelling. A form that borrows from another card (the
first `.ac`, `.tran` or `.sn`) fails with `MissingAnalysisCard` when the
deck has none. `analyses.zig CardContext` holds what they borrow.

| Card | Runs as | Divergence |
|---|---|---|
| `.noise v(out) src [inter]` | `.noise` over the `.ac` sweep | `src` must be a V card |
| `.noise ... dec N f1 f2 pts` (ngspice), nonzero `pts` or `inter` | adds the contribution columns below | published at every frequency, not every `pts`-th |
| `.dc var LIN\|DEC\|OCT np start stop`, `POI np v...`, `START= STOP= STEP=` | an explicit point list per level | `SWEEP`, `DATA=` and `MONTE=` are the variant runner's |
| `.ac POI np f1 ... fn` | the listed frequencies | they must be positive and ascending |
| `.pz v(a[,b]) src` | `.pz` driven at the source's own nodes, `vol` for a V card, `cur` for an I card, poles and zeros | an `i(...)` output is refused |
| `.op [format] t1 t2 ...` | one transient per time, run to it with the `.tran` card's step capped at t/50, published as `Operating Point (time=<t>)`; `t = 0` is the DC point | the snapshot is not written as an `.ic0` file |
| `.four f v(a) v(b) ...` | one query per output, plots `Fourier Analysis v(a) (THD = ...)` | none |
| `.sn TRES= PERIOD=` / `TONE= NHARMS=` | `.pss`, PERIOD/TRES steps a period | TRINIT, MAXTRINITCYCLES, NUMPEROUT and NHARMS are read and unused |
| `.snac sweep`, `.snxf v(out) sweep`, `.snnoise v(out) src sweep [n1 ±1]` | `.pac`, `.pxf`, `.pnoise` at the `.sn` tone | `.snnoise` measures only the n1 = 0 band |
| `.fft v(a[,b]) [START= STOP= NP= FORMAT= WINDOW= ALFA= FREQ= FMIN= FMAX=]` | the `.tran` resampled on NP points, windowed, one FFT (`post/fft.zig`) | see below |

Noise contributions follow ngspice's names and units: `onoise_<inst>_<gen>`
and `onoise_<inst>` in V/sqrt(Hz) in the spectrum, `v(onoise_total_...)` and
`v(inoise_total_...)` in V rms in the integrated plot, each generator
integrated on its own power-law fit. The generator names are the models'
LRM §4.6.4 `name` arguments (`thermal`, `id`, `rs`), which match ngspice's
suffixes for the resistor and diode; generators of one instance that share
a name form one column. Divergence: ngspice also lists generators the model
does not have at that bias (a resistor's zero `_1overf`); ESPice lists what
the model declares. HSPICE's per-subcircuit sums (`listckt`) are not built.

`.fft` publishes the `.ft#` data: every bin from DC to NP/2 as one complex
column named for the output, in a plot `FFT Analysis v(out)`. Bin k ≥ 1
holds 2·X[k]/Σw, so a bin-centred tone reads its amplitude under any window,
with the sine phase HSPICE's listing shows (0 for a `sin` source; `.four`
reports the cosine phase). NORM divides by the largest non-DC bin. The
windows are HSPICE's table [SA Ch.15 Table 56], its Gaussian taken
literally. Divergences: samples come by linear interpolation, as `.four`
takes them, where HSPICE interpolates to second order; FREQ, FMIN and FMAX
only shape HSPICE's printed listing and are checked, not used.

`.measure fft` reads that plot [CR .MEASURE FFT]: `FIND vm(out) AT=f` and
the other `v?` forms, and THD, SNR, SNDR, ENOB and SFDR with NBHARM,
MINFREQ, MAXFREQ and BINSIZ. The fundamental is the largest non-DC bin; its
harmonics are its bin multiples up to NBHARM and MAXFREQ; DC is left out of
the noise. THD is the ratio the SA formula gives, not percent.

`.measure dcmatch|acmatch|lstb|phasenoise|ptdnoise` read those analyses'
plots by column name: `total_3sigma` and `<card>@<param>` (DCMATCH),
`acm_mag`/`acm_phase`/`acm_re`/`acm_im` (ACMATCH), `phnoise`,
`ptdnoise_density`. A bare `FIND col` with no `AT` or `WHEN` reads a
one-row plot (DC mismatch, the LSTB margins); the swept plots take the
usual forms. LSTB's margin keywords and `lstb(db)` are in
[stability.md](analysis/stability.md). The manual names HSPICE's own
output variables (`DCm_*` and the like), which we do not have; these are
our columns, unconfirmed against HSPICE (`hspice/meas_match`,
`hspice/meas_lstb`, `hspice/meas_ptdnoise`, `phasenoise/meas_phasenoise`).

### HSPICE digital stimuli

A V or I card's `PAT (vhi vlo td tr tf tsample data)` [SA Ch.9 "Pattern
Source"; CR .PAT] is rewritten into the PWL that draws it before the line
is parsed (`frontend/pattern.zig`). `data` is b-strings of 0, 1 and M,
`[...]` nested structures and `.pat` names, each followed by optional R=
and RB=, which apply to the component just before them (so a name's own
R/RB can be overridden where it is used). Each bit holds for tsample from
td on, the first bit also through the delay; a change ramps over tr
(rising) or tf (falling) centred on the bit boundary, which gives the
manual's first transition at td + N·tsample − tr/2. vhi, vlo and the times
may be parameter expressions. Not read: Z states (no high-impedance
source), K-strings and ENCODE=DW8b10b, R=−1 (forever), and LFSR. A pattern
needs at most 31 level changes: the source models hold 64 PWL points.
These fail the deck with a warning naming the card. Fixture:
`hspice/pattern_source.sp`; unconfirmed against HSPICE.

`.vec 'file'` [CR .VEC; SA Ch.9 "Specifying a Digital Vector File"] is
expanded with the includes (`frontend/vec.zig`, found through SEARCH like
them): each input bit becomes `vvec_<bit> <bit> <vref> pwl(...)` and each
output bit a `.dout <bit> VTH (...)` card, or `VOL VOH` when the file sets
no VTH, as HSPICE converts them. Read: RADIX (1 to 4 bits per digit),
VNAME (`a`, `b[3:0]` naming `b3`..`b0`, `c[[1:0]]` naming `c[1]`, `c[0]`),
IO `i`/`o`, TUNIT, PERIOD, TDELAY, IDELAY, ODELAY, SLOPE, TRISE, TFALL,
VIH, VIL, VOH, VOL, VTH, VREF and OUT 0, each with a hex mask over the
digits, `;` comments and `+` continuations. Tabular states 0 and 1 drive
VIL and VIH, X and U drive VIL as the manual's table says; an input holds
its first row's state from t = 0 and starts each ramp at row time + delay.
Not read: bidirectional signals (IO `b`, ENABLE, OPTION CBC), Z, L and H
inputs (they need TRIZ/OUT resistances), a nonzero OUT, Verilog-sized
values, and `.param` names inside the file. Divergence: the manual gives
no default edge rate; ESPice uses 0.1 time units (0.1 ns). Fixture:
`hspice/vec_stim.sp`; unconfirmed against HSPICE.

### HSPICE checks and power reports

`.check`, `.dout`, `.biaschk` and `.power` become transient measures
(`frontend/measure.zig parseCheck`, `netlist.zig readPower`), printed with
the `.meas` results. A check prints its violation count, `<kind><N>_<node>`
(`setup4_d = 1`; N counts the check cards), with one indented line per
violation before it. HSPICE writes violations to the `.err` file; it has no
count. These follow the manual [CR .CHECK, .DOUT, .BIASCHK, .POWER] and are
unconfirmed against HSPICE. Fixtures: `hspice/checks.sp`, `hspice/power.sp`.

A transition is read between the logic thresholds `hi_th` and `lo_th` of
the card's `(hi lo hi_th lo_th)`, else of the last `.check GLOBAL_LEVEL`
before it (a threshold ending in `%` is that share of hi - lo above lo). A
rise leaves `lo_th` and reaches `hi_th` without falling back; its time is
the midpoint of the two crossings, its duration their distance.

| Card | Violation |
|---|---|
| `.check rise\|fall\|slew (min max) nodes` | a rise, fall, or either, whose duration is outside [min, max] (SLEW's rate limits are the same window) |
| `.check setup (ref RISE\|FALL d RISE\|FALL) nodes` | a node edge of the second kind in [t − d, t] of a reference edge at t |
| `.check hold (...)` | a node edge in [t, t + d] |
| `.check edge (ref RISE\|FALL min max RISE\|FALL) nodes` | a reference edge with no node edge in [t + min, t + max] |
| `.check irdrop (v d) nodes` | each stretch below v (v < 0) or above v (v ≥ 0) longer than d; d = 0 counts every one |
| `.dout nd... [VTH \| VLO VHI] (t s ...)` | a state 0 or 1 the node does not hold at t: above VTH is 1, else 0; with VLO VHI, at or below VLO is 0, at or above VHI is 1. X, U and Z are don't-care |
| `.biaschk 'expr' [max=\|limit=] [min=] [tstart=] [tstop=]` | each stretch of the expression outside [min, max], named `biaschk<N>` |

Divergences: IRDROP's volt_val is read as an absolute level, as the
manual's example (`-2` means below −2 V) reads; its "VDD drop" wording may
mean relative to the supply. `.dout` without a threshold uses 1.65 V, the
`.vec` VTH default. Not read: node wildcards (`vin*`), the element, region
and size forms of `.biaschk` (they need device terminal voltages and
operating regions, which no result carries), `simulation=op|dc`, NOISE=
and AUTOSTOP. `.powerdc` is refused: its per-instance port currents are
not in any result.

`.power signal [REF=] [FROM=] [TO=]` prints `power<N>_avg`, `_rms`, `_max`
and `_min` over the window (the whole run by default). A bare name is a
top-level voltage source, and its signal is the power it absorbs,
v(n+, n−)·i(source), negative while it delivers; any other signal
(`i(v1)`, `par('...')`) is read as written. REF= only labels HSPICE's
table and is dropped. Divergence: HSPICE's `x1.in` port signals (an
instance's port power) are not read.

`.stim [tran] pwl|data` [CR .STIM; SA Ch.11 "Reusing Simulation Output as
Input Stimuli"] writes the first transient's signals, after the run, to
`<filename>.pwl<N>_tr0` (one PWL source per signal) or `.dat<N>_tr0` (one
`.data dataname` table, with a `time` column under INDEPOUT), beside the
output file like `.save`; N counts the cards of each form from 0, and
FILENAME= defaults to the deck's stem. Signals are any `.meas` output
variable, sampled at the INDEPVAR= times, at NPOINTS evenly spaced times
over FROM..TO, or at every transient point in FROM..TO, interpolated
linearly. A signal with no `name=` is named after its variable (`v(a)` is
`v_a`); a `par()` signal must be named, and a PWL source's name must start
with V or I. A PWL source of `v(a,b)` defaults to terminals a and b (b = 0
for `v(a)`); others need NODE1=. Not read: the AC, DC and VEC forms,
`.option numdgt` and INGOLD (values print in full precision), and sweep
numbers past `_tr0`. A PWL source's table holds 64 points; a longer PWL
(on any V or I card) continues in sources of its later segments, each
starting on the last point of the one before and holding the change from
there, in series with a V card and in parallel with an I card
(`builder.zig` `pwlTail`, fixture `tran/pwl_long`). `r=` repeat is refused
past 64 points, as are sensed and port sources.
Test: `src/tests/espice.zig` (".stim writes PWL sources and a .data
table"); unconfirmed against HSPICE.

## PDK conveniences

These follow ngspice 45, because the open PDKs (sky130, GF180, IHP SG13G2)
are written against it:

- `.endl` closes the open `.lib` section whatever name follows it
  (inpcom.c). GF180 closes `.lib dio` with `.endl diode`.
- `.if`/`.elseif`/`.else`/`.endif` keep the first branch whose condition is
  nonzero (inp.c recifeval). Top-level conditions are evaluated in walk 1
  against the `.param` cards above them; inside a subcircuit they are
  evaluated per `X` instance in `expand`, under the instance's parameters.
  Divergence: a `.param` or `.model` inside a subcircuit's `.if` applies
  unconditionally, since subcircuit dot cards are read once in walk 1.
- `.model <name> psp103va` (the OSDI module name) selects the built-in
  PSP 103, as ngspice does after loading `psp103va.osdi`.
- An R card whose braced value reads `v(`, `i(`, `time`, `temper` or
  `hertz` becomes ngspice's B source `i={v(n1,n2)/(eq)*(m)}` with its
  `tc1`/`tc2` and `reciproctc=1` (inpcom.c `inp_compat`); a B card takes
  `key=value` parameters after a braced expression; in a B tape `pow()` is
  |x|^y while `^` keeps the sign for an integer power (ptfuncs.c); `pwr(x,y)`
  is sign(x)·|x|^y. With `.option seed=N` and no `MONTE` sweep the
  distributions are drawn once from the seed instead of folding to their
  nominal. The sky130 resistors and mismatch sections depend on these; see
  [sky130.md](sky130.md).
- `.meas`/`.measure` cards are parsed by `measure.zig` into `core.Measure`
  rows (`deck.measures`) and evaluated after the run by
  `src/output/measure.zig`, a port of com_measure2.c: the same event
  counting, interpolation, Simpson/trapezoid panels and print format, so
  results match ngspice byte for byte on the same waveform. HSPICE's
  `INTEGRAL`, `DERIVATIVE`, `PARAM=` (arithmetic over other results and
  global parameters, evaluated after the other cards as ngspice's
  measure.c does) and `ERR`/`ERR1`/`ERR2`/`ERR3` [CR .MEASURE] are read
  too; `GOAL` and `WEIGHT` are accepted and unused. Divergences: `DERIV`
  returns the slope of the sample pair around its point, where ngspice 45
  rejects it; the manual gives ERR3 no reduction, so ESPice returns its
  RMS as for ERR1; ngspice refuses `.meas` in batch mode with `-r`;
  espice always prints them, and reports a failed card on stderr in a
  shorter form.
- The rest of HSPICE's `.MEASURE` [CR .MEASURE]: `VAL`, `TD`, `FROM`, `TO`
  and `AT` may name earlier results (`from=t10 to='t90+1n'`), resolved when
  the card runs; `TD=TRIG` counts TARG events from the trigger time; in the
  HSPICE dialect a TARG without `TD` inherits TRIG's (ngspice keeps 0, and
  an explicit `TD=0` on TARG reads as omitted); `REVERSE` is accepted, as a
  negative result already reports a target before its trigger;
  `par('expr')` stands for a vector anywhere one is read, arithmetic over
  `v(a[,b])`, `i(x)` and parameters, evaluated per sample; `EM_AVG` is
  max(I+, I-) - R min(I+, I-) over the window, I+/I- the trapezoidal means
  of the positive and negative parts (each segment split at its zero) and R
  `.option em_recovery` (default 1), with window ends at samples as AVG's.
  `TRAN_CONT`/`AC_CONT`/`DC_CONT` report the named event and every later
  one (CROSS=1 when none is named) as `name[1]`, `name[2]`, ...; a PARAM
  card reads the first. HSPICE writes these to `.mt0` columns, a format
  ESPice does not produce. Not read: pushout bisection, and the PHASENOISE,
  PTDNOISE, LSTB, ACMATCH and DCMATCH keyword forms.

## Build

`NetBuilder` maps nets to circuit rows by net id (no string hashing) in the
order it stamps devices: V, L and I first, F/H/W/K last because they
reference V and L cards. Its per-card tables (V, I, L, AC drives, branch
probes, AC resistances, topology) are recorded before the freeze and go
through the BBD permutation. Analysis nets map to rows through the same table
after the freeze. `Problem.append_directives` parses cards with the same
reader (`resolveQueries`) and resolves names against the frozen circuit's
labels.

Controlled-source binding indexes names instead of scanning: control names
form one sorted slice queried by case-insensitive binary search, and
deferred binding builds one exact-name map of the native voltage-source rows.
Its `u32` values keep the first duplicate name and exclude runtime-loaded
cards skipped during native source construction. Both indexes die with parse
scratch. Missing and unknown controls keep their errors, and
case-insensitive sensing stays distinct from exact-name binding. The
measurement is in [preparation-performance.md](Problem/preparation-performance.md).

Known divergences from the retired AST frontend, none exercised by the
fixture corpus: a syntax error inside a subcircuit that is never instantiated
is not reported; `X` card parameters that do not fold in the caller are
re-read in the callee's scope instead of being substituted in the caller
first; Q/M terminal normalisation runs for HDL devices too, where it is a
no-op for well-formed cards.

## Layout and SIMD

Device payload is SoA in the hypergraph's edge table; positional values and
`key=value` pairs are rows of two flat tables, addressed by `u32` spans. Net
and model names are hashed once, in the frontend; the builder maps a net to
its circuit row through a `u32` array. Subcircuit definitions are line
ranges, re-read per instance. Parse scratch dies when preparation completes;
published metadata belongs to the session arena. GPU device layouts and
scatter tapes are not touched.

ASCII normalization and newline counting share one streaming vector pass
(`lines.zig normalize(W, ...)`). The newline predicate becomes a bit mask
followed by `@popCount`; this avoids the wrong line counts vector
boolean-to-integer reduction gave under the Debug backend. `W = 1` is the
scalar oracle and the tail. The frontend test checks the production function against its
`W = 1` oracle. The LLVM assembly of the production function
contains `vpcmpeqb`, `vpmovmskb` and `popcnt`.

The field splitter is scalar, driven by a 256-entry break table.

Retired: per-word SIMD in the field splitter. It classified 16 bytes anew for
each short token, then used a width-1 tail. Cachegrind on a 20,005-device RC
prefix reported 86,436,501 instructions against 81,433,895 for the scalar
word scan (6.1% more), with identical 533,666 L1 data misses (one warmup and
one measured parse and expansion; LLVM ReleaseFast, x86_64_v3; simulated
I1/D1 32 KiB 8-way 64-byte lines, LL 8 MiB 16-way). Reconsider token SIMD
only with measured gains on both short-token and long-token decks; mask
caching adds state this result does not justify.

## Measuring

```sh
zig build bench-frontend -- tests/fixtures/stress/scaling_rc_ladder_100k.sp 11
zig build bench-frontend -- tests/fixtures/stress/scaling_inverter_chain_4k.sp 11
```

`bench-frontend` (`tests/benchmark/frontend.zig`) times parsing plus
subcircuit expansion, excluding file loading, device binding and simulation.
Each iteration owns a fresh arena; it reports the median time, arena capacity
and a device-count checksum.

The AST frontend's last build refactor was measured with this harness (LLVM
ReleaseFast, x86_64_v3, 11 iterations on `scaling_rc_ladder_100k.sp`): 42.848
ms before, 45.443 ms after, both reserving 143,648,772 arena bytes with
checksum 2,400,012, on a loaded machine with large run-to-run variation. It
established no throughput change, and no frontend throughput claim rests on
it. The hypergraph frontend described here later replaced that AST
frontend.
