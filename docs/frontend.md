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
0), as in the nominal PDK corners.

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
scalar oracle and the tail. The differential case in
`ref/SIMD-Strategies/verify.zig` covers widths 1, 16, 32 and 64, every input
length through 257 bytes, and random non-ASCII bytes; the frontend test
checks the production function. The LLVM assembly of the production function
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
zig run ref/SIMD-Strategies/verify.zig -fllvm -OReleaseSafe -mcpu=native
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
