# Frontend pipeline

Netlist bytes in, passive `Prepared` circuit out. The frontend has no
tokenizer/parser split and builds no syntax tree:

    bytes ─include─▶ bytes ─fold case─▶ logical lines ─split─▶ fields ─switch(first byte)─▶ tables

| Stage | File | In | Out |
|---|---|---|---|
| expand | `source.zig` | bytes + origin path | bytes (`.include`/`.lib` inlined; spectre skips) |
| lines | `lines.zig` | bytes | lowercased copy, logical lines, field iterator, SPICE numbers |
| netlist | `netlist.zig` + `expr.zig` | lines | `Netlist` (below) |
| analyses | `analyses.zig` | `Netlist.deck.analyses` + node rows | `[]Query`, deck options |
| build | `prepare.zig` + `builder.zig` | `Netlist` | `Prepared` (frozen `Circuit`, probes, bindings, queries) |

The dialect picks the line splitter (comments, continuations), the quote
and brace set of the field splitter, number suffixes, and whether the source
is case-folded. Card keywords go through one `StaticStringMap`
(`netlist.zig cards`), shared by the three dialects because they accept the
same cards. Keywords are looked up lowercased in every dialect.

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
| `pool` | `InternPool` (`intern.zig`): name bytes, `u32` offsets, a map keyed by the dense `Name` id | every net and device name, once |
| `graph` | `BipartiteHypergraph(Net, Device)` (`csr.zig`, from cktImg) | nets are vertices, ground is vertex 0; devices are hyperedges whose members are the pins in terminal order, repeats kept; CSR both ways |
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

Six questions for the new tables:

1. In: lowercased lines. Out: the tables above. The builder turns them into
   a `Circuit`; `analyses.zig` turns `analyses` into queries once rows exist.
2. How many: devices and nets up to ~10^6 (the stress decks reach 2·10^5),
   2 to 10 params per device, models from a handful to a PDK's thousands,
   analyses under ten, expressions that survive folding: a few per deck.
3. Width: every id (`VertexId`, `EdgeId`, `Name`, model, span start/len) is `u32`,
   the ceiling `Circuit` already has; `kind` is the card letter (`u8`);
   subcircuit type `u16` and instance `u32`, the old limits.
4. Access: the builder visits devices by letter bucket and reads a device's
   name, pins, values and model together. Params are AoS (`Kv`) for that
   reason; device payload is SoA in the graph because analyses and BBD
   tagging read single columns.
5. Lifetime: one parse arena, released after `build`. `Prepared` copies what
   it keeps.
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
0), as in the nominal PDK corners.

## Build

`NetBuilder` interns nets into circuit rows by net id (no string hashing) in
the order it stamps devices, V, L, I first, F/H/W/K last because they
reference V and L cards. Its per-card tables (V, I, L, AC drives, branch
probes, AC resistances, topology) are recorded before the freeze and go
through the BBD permutation. Analysis nets map to rows through the same
table after the freeze. `Problem.append_directives` parses cards with the
same reader and resolves names against the frozen circuit's labels.

Divergences from the AST frontend, none exercised by the fixture corpus:
a syntax error inside a subcircuit that is never instantiated is not
reported; `X` card parameters that do not fold in the caller are re-read in
the callee's scope instead of being substituted in the caller first; Q/M
terminal normalisation runs for HDL devices too, where it is a no-op for
well-formed cards.
