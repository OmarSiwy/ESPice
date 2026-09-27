# Design review: data-oriented-design audit, frontend half

- **Change**: audit of `src/core/`, `src/frontend/`, `src/output/`, `src/espice.zig` and `src/c_api.zig` against the `data-oriented-design` skill (Six Questions, layout, widths, capacities, hot/cold, arenas, per-element allocation, hash maps where a dense index works, stored pointers against AGENTS.md §2.12).
- **Domain skill(s)**: `data-oriented-design`; `compiler-construction` (netlist tables), `spice-engine` (card and variant tables).
- **Hot/cold**: cold overall. Evidence: parsing plus expansion of `stress/scaling_rc_ladder_100k.sp` is about 43 ms (dev/frontend.md, "Measuring"), and dev/frontend.md question 6 names the builder as the cost. Two paths run once per variant or trial, which is a loop over many elements: `Netlist.setLive` and `variants.Sampler` (dev/analysis/variants.md: 57-77 ms over 20 points). Four lookups are quadratic in device count and become the cost on large decks, whatever the hot/cold verdict (findings 1 and 4).
- **Stages run**: R2 (Data) as an audit. R10 for the two applied commits. Agent builds are refused (zigq exit 75), so every layout change below is PROPOSED with a measurement plan (§2.13).
- **Branch**: `audit-dod-fe`, worktree `/home/omare/Documents/Projects/Zig/espice-audit-dod-fe`, base `int-3` at 7c515efd.

## Data (R2): the Six Questions for the significant tables

| Table | Owner | Fields: width (range) | Layout | Capacity | Lifetime/arena | Producer → consumer |
| --- | --- | --- | --- | --- | --- | --- |
| `Netlist.graph` (nets × devices) | `frontend/netlist.zig` Reader | ids `u32` (`maxInt(u32)`, checked in `csr.addEdge`); `kind` `u8` (card letter); spans `u32` | SoA (`MultiArrayList`) + edge-major CSR | `u32` rows, checked | parse arena | Reader → builder, BBD tagging |
| `Netlist.values` / `kvs` | Reader | `Value` 40 B, `Kv` 56 B (computed by hand, see finding 2) | AoS rows addressed by `u32` spans (dev/frontend.md justifies AoS for `Kv`) | `u32` spans | parse arena | Reader → builder, `setLive` |
| `Netlist.ops` / `consts` | Reader | `Op` 12 B (`u8` code + 2×`u32`); `f64` | flat | `u32` | parse arena | Reader → builder (B tapes), `setLive` |
| `Live` (swept slots) | Reader | `slots: []*Value` (8 B pointers); spans, `f64`, `u64` site keys | SoA | slot count | parse arena | Reader → `setLive` per variant |
| `core.Deck.cards` (`CardRef`) | builder (producer) | `type` + `index: u32` + `name` slice: 24 B/row | AoS, unsorted, interleaved by type | none stated | session arena | builder → analysis labels, noise, sens, dcmatch |
| `core.Variants` | `variants.Planner` | `starts/refs: u32`, `values/axis: f64`, `temp_c: ?f64` (16 B) | SoA, CSR rows | `u32` rows | session arena | planner → analysis sweep |
| `Builder.node_labels` | `frontend/builder.zig` | `[]const u8` per row (16 B) | column | `u32` rows (`TooManyNodes`) | `core.gpa` staging, dies at freeze | builder → circuit intern table |
| `NetBuilder` V/I/L/AC/topo tables | builder | `u32` rows, `f64`, `u16` port number | SoA (`MultiArrayList`) | none stated | parse scratch | builder → `QueryBindings` |
| `core.Result.data` | analysis | `f64` | point-major (row per point) | `npoints * columns`, overflow-checked in `types.sampleCount` | session arena | analysis → output encoders, `.meas` |

Transforms:

- `parse: text → graph, values, kvs, ops, consts, models, deck`
- `setLive: live values, Live, ops, consts → values/kvs slots, consts rows, edge model column`
- `NetBuilder.build: Netlist → Builder protos, V/I/L/AC tables, cards`
- `measure.evaluate: Result.data (one column, strided) → f64 per card`

Already in good shape: the CSR hypergraph (`csr.zig`), the `InternPool` (bytes plus `u32` offsets, a map keyed by the dense id), the SoA `Variants`, `QueryBindings` and `Mosra` tables, the `NetBuilder` SoA source tables, the `sparam.Network` SoA, the 12-byte postfix `Op`, the `expr.fold` single reserve, and the streamed raw output.

## Findings, ranked by expected payoff

| # | Where | What is wrong (per the skill) | Fix | Status |
| --- | --- | --- | --- | --- |
| 1 | `src/core/query.zig:58` `CardRef.lookup`; callers `src/analysis/ac/noise.zig:431`, `src/analysis/sweep/sens.zig:184`, `src/analysis/executor.zig:357`, `src/frontend/variants.zig:567,641` | A linear scan keyed on `(type, index)`, called once per instance or per parameter: O(instances × cards). `.noise` labels, `.sens` columns, per-device `.dcmatch` labels and `sayNames` are quadratic in device count. A hash or scan where a dense index works: the producer (`Builder.cards`, builder.zig:269) hands out `index` densely per type. | A dense per-type name column: `Deck.card_names` plus `card_starts[type]`, so a lookup is `names[starts[t] + index]` (`""` for an unnamed add). Smaller alternative: sort `cards` by `(type, index)` once at the freeze and binary-search. | PROPOSED: crosses core, builder and analysis, needs a build and a measurement |
| 2 | `src/frontend/netlist.zig:47` `Value`, `:61` `Kv` | Width. `Value` is a tagged union whose largest arm (`Group`: two slices) sets it to 40 B; `Kv` is 56 B. Most rows are `num` (8 B of payload). `values`/`kvs` are the largest parse tables (a BSIM4 card is ~10 `Kv` rows, about 560 B/device). | Move `Group` behind a `u32` handle into a `groups` table: `Value` drops to 24 B and `Kv` to 40 B. Then make `name`/`key` interned `Name` (or `Span` into the text): 16 B and 24 B. Confirm the sizes first with a `comptime assert(@sizeOf(Value) == …)`. | PROPOSED: layout change across netlist, builder, analyses, variants |
| 3 | `src/frontend/netlist.zig:181` `Live.slots: []const *Value`; `:3780` `slot_of: AutoHashMap(*const Value, u32)` | Stored pointers, which §2.12 does not allow, and a hash map keyed by pointer identity (one probe per M-card geometry key in `modelBins`). The pointers exist because `Group` args are arena slices, not a table (the `ponytail:` note on `Group`). | After finding 2: a slot becomes `(table: enum(u8){values, kvs, group_args}, row: u32)`, and `slot_of` becomes a dense `[]u32` over `kvs` rows. | PROPOSED: depends on 2 |
| 4 | `src/frontend/builder.zig:1548` `branchRow`, called per `i()` probe in a B tape (`:2451`); `:1816` `addKinduc` | Linear name scans over the V, L and branch tables, per probe and per K card: O(B × (V+L+br)) and O(K × L). `resolveDeferred` already builds `source_index` for V names alone. | Build one name → branch-row map in `resolveDeferred` over V, L and `br` (first name wins, as the scans do now) and use it in both places. | PROPOSED: needs a build; the first-duplicate rule needs a test |
| 5 | `src/frontend/variants.zig:1223` `Sampler.strata: AutoHashMap(u64, []u32)` | A hash per draw under Latin hypercube, while `SiteDraw.value` (netlist.zig) already holds the dense site row `k`. | Key strata by site row: one flat `[sites × n]u32` table, filled lazily or at init; pass `k` through `sample`. | PROPOSED: changes the `draw.sample` signature; MC output must stay bit-identical |
| 6 | `src/frontend/builder.zig:156` `computeBbd` `index: AutoHashMap(u32, u32)` | Subcircuit instance ordinals are dense (`Reader.instances` counts them from 1), but they go through two hash operations per node. | `[]u32` of `instances + 1` entries, `none` = unseen; the bound is the largest `node_instance` value below `MULTI_INSTANCE`. | PROPOSED: needs a build; measure on `stress/scaling_inverter_chain_4k` |
| 7 | `src/frontend/spectre.zig:17` `Kinds = AutoHashMap(usize, u8)`, `:492` keyed by `@intFromPtr(card.ptr)`; read at `netlist.zig:3130` for every device card, every dialect | Hashing a pointer where a dense line index works. It is also fragile: a line that `pattern.rewrite` replaces loses its letter. | `translate` returns a `[]u8` letter column parallel to its output lines (0 = none); `readDevice` gets the row. | PROPOSED: touches the `readDevice` signature at its four call sites |
| 8 | `src/frontend/netlist.zig:965` `Reader.variants: AutoHashMap(u32 line, ArrayList(u32))` | Keyed by line number, though the key set is exactly the `local_models` rows. | `[]ArrayList(u32)` indexed by the `LocalModel` row. | PROPOSED |
| 9 | `src/frontend/builder.zig:1074-1078` `deferred: ArrayList(Netlist.View)` | Stores a fat ~140 B `View` (slices plus an optional `Model` by value) per deferred F/H/W/K/B card, where the `u32` `EdgeId` is the handle. | Store `EdgeId`s and re-resolve with `nl.device(e)` in `resolveDeferred`. First confirm that no caller hands over a rewritten `View`. | PROPOSED |
| 10 | `src/output/write.zig:654` `append` | Each appended plot copies the whole file (documented: "O(file size) per call"), so P concatenated plots (`.step` to one raw file) cost O(P²) bytes. | Keep one atomic file open across a session's appended plots, as `Session.Stream` already does for plot 0, and replace it at `finish`. | PROPOSED: owner decision (the atomic-per-plot guarantee changes) |
| 11 | `src/frontend/builder.zig:58` `Builder.node_labels: ArrayList([]const u8)` | 16 B per row, where the netlist's `Name` (4 B) identifies the same string; about 3.2 MB against 0.8 MB of staging on 200k rows. | Store `core.Name` (sentinel for internal unknowns) and resolve at the freeze. | PROPOSED: low |
| 12 | `src/core/deck.zig:74` `Variants.temp_c: []const ?f64` | An optional per row (16 B) for a rare field. | A NaN sentinel (8 B), or a sparse `(row, temp)` column. | PROPOSED: low, crosses modules |
| 13 | `src/output/measure.zig:504` `Column.get` | A per-sample check of `ops` and switch on `vectype` in loops over every sample, and strided column reads from point-major data. | Specialise the loops on `vectype` at comptime, or copy the column out once. Bench before claiming anything. | PROPOSED: low, measures run once per result |
| 14 | `src/frontend/source.zig:477` `appendData` | A fresh `cells` ArrayList per data-file row: per-row allocation in a loop. | One flat `cells` list plus `row_starts` (CSR). | PROPOSED: low |
| 15 | `src/frontend/mosra.zig:52-55` | Four `u64`-keyed maps over `(type, instance)`, where per-type dense arrays work. Runs once. | Dense per-type `[]u32`. | PROPOSED: low |
| 16 | `src/frontend/builder.zig:368` `BoundCard.model: *const anyopaque`; `prepare.zig:28,32` `tuner`/`tuning`; `espice.zig:135` `parse_arena` | Stored pointers outside the §2.12 allowed list. All are cold, and each holds the identity of a heap object. | Owner decision: add them to §2.12's list, or make `BoundCard` a `u32` row into a per-type model table. | PROPOSED: owner decision |
| A1 | `src/frontend/netlist.zig:479` `setLive` bin loop | `nl.graph.edges.get(e)` gathered all six edge columns per binned card per variant to use two of them. | Read the `kv` and `positional` columns, hoisted beside `model_of`. | APPLIED feb23ab4 |
| A2 | `src/frontend/prepare.zig:143` `keepSaved` | `allocLowerString` per published label: one scratch allocation per probe row, only to test membership. | One reused buffer, resized per label. | APPLIED 29beed2b |

Both applied commits passed `zig ast-check` (0.17.0) only. They are not built or gated. They change no layout and no observable result, but the lead's integration gate is their first build.

## Containment (R6)

Not run as a stage. Noted along the way: `csr.Builder` checks every count against `u32` (`TooMany*`), `Branches.max = 32` and `subckt_depth_max = 16` bound the walks, and `expr.max_depth = 512` bounds recursion. No capacity constant with a unit exists for `Deck.cards`, `NetBuilder` source tables or `Sampler.strata`; findings 1 and 5 would give each one (sites × trials, instances per type).

## Test plan (R7) for the proposals

| Bug class | Oracle | Layer | Tier | Harness / file |
| --- | --- | --- | --- | --- |
| Dense card table returns the wrong name (1) | Today's linear `CardRef.lookup` as a differential oracle over a shuffled table | unit | merge | `src/core/query.zig` test |
| Value/Kv narrowing changes a parsed value (2, 3) | Fixture corpus by name (`tests/VERDICTS.tsv`) plus `frontend/tests/netlist.zig` | corpus | merge | `zig build test` |
| Name index picks a different duplicate (4) | The current first-match scan on decks with duplicate V/L names | unit | merge | `src/frontend/tests/builder.zig` |
| LHS strata change a draw (5) | Bitwise MC output of the `mc/` decks before and after | corpus | merge | `zig build test -- --filter mc/` |

## Proof (R8): measurement plan per proposal

| Proposal | Benchmark (before → after) |
| --- | --- |
| 1 | A `.noise` deck and a `.sens` deck at 20k devices (generated like the `stress/` decks); callgrind instruction counts of label building, then `zig build bench` wall time. |
| 2, 3 | `zig build bench-frontend -- tests/fixtures/stress/scaling_rc_ladder_100k.sp 11` and the sky130 inverter chain: median time and arena capacity (the harness prints both). |
| 4 | A generated deck with 10k K cards over 10k L cards, and one with 10k B sources reading `i()`; callgrind of `NetBuilder`. |
| 5 | A sky130 `.dcmatch` or MC deck with `sampling_method=lhs`, 100 trials; callgrind of `setLive`. |
| 6, 7, 8 | `bench-frontend` on `stress/scaling_inverter_chain_4k.sp` and a Spectre stress deck. |
| 10 | A `.step` deck with 1000 points writing binary raw: wall time and bytes copied. |

## Checklist

| # | Check | Source | Verdict | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Every function's transformation stateable | DOD checklist | pass | transforms above |
| 2 | No pointer that could be an index | DOD checklist, §2.12 | fail | findings 3, 7, 16 |
| 3 | Every field width justified by a range | DOD checklist | fail | finding 2 (`Value`/`Kv`), 11, 12 |
| 4 | No hash map where a dense index works | DOD checklist | fail | findings 1, 5, 6, 7, 8, 15 |
| 5 | Nothing allocates per iteration that a reused buffer could hoist | DOD checklist | fail → partly fixed | A2 applied; 14 proposed |
| 6 | Collections match the access pattern (SoA) | DOD Rule 2 | pass | csr, Variants, NetBuilder tables are SoA; `Kv` AoS justified in dev/frontend.md |
| 7 | No quadratic lookups on per-device paths | DOD measurement.md | fail | findings 1, 4 |
| 8 | Every table has a capacity | Principle 17, `assertions` | fail | `Deck.cards`, `Sampler.strata` (Containment) |
| 9 | Arena lifetimes match phases | DOD Rule 6 | pass | parse arena / session arena / `core.gpa` staging, each documented at its owner (builder.zig:40) |

## Proposed issues

1. **Card names: a dense per-type table instead of a linear `CardRef.lookup`.** Body: `CardRef.lookup` (src/core/query.zig:58) scans all cards per call, and noise labels (analysis/ac/noise.zig:431), sens columns (analysis/sweep/sens.zig:184), dcmatch labels (frontend/variants.zig:567, 641) and `sayNames` (analysis/executor.zig:357) call it once per instance or parameter, which is O(N²) in device count. Builder hands out `index` densely per type (builder.zig:269), so `Deck` can carry `card_names` plus `card_starts[type]` and answer in O(1). Oracle: the current scan, run as a differential test. Measure on a 20k-device `.noise` deck and a `.sens` deck (callgrind, then bench).
2. **Netlist values: narrow `Value` (40 B) and `Kv` (56 B), and turn `Live.slots` pointers into handles.** Body: `Group` (two slices) sets the union size. Moving it behind a `u32` into a `groups` table gives 24 B and 40 B, and interning `name`/`key` gives 16 B and 24 B. That in turn lets `Live.slots` (`[]*Value`, outside the §2.12 allowed list) become `(table, row)` handles, and lets `modelBins`'s pointer-keyed `slot_of` map become a dense array. Measure with `bench-frontend` (time plus arena bytes) on the 100k RC ladder and on a sky130 deck. Gate: the corpus verdicts by name.
3. **Builder: index branch rows by name once.** Body: `branchRow` (builder.zig:1548) and `addKinduc` (:1816) scan the V, L and branch tables linearly per `i()` probe and per K card. Build one first-match name → row map in `resolveDeferred`, beside `source_index`. Test duplicate names against the current scan.
4. **Frontend: dense tables for four id-keyed hash maps.** Body: `Sampler.strata` (variants.zig:1223, keyed by site; the site row is already known in `SiteDraw`), `computeBbd`'s instance index (builder.zig:156; ordinals are dense), Spectre `Kinds` (spectre.zig:17, keyed by line address; a rewritten line loses its letter) and `Reader.variants` (netlist.zig:965, keyed by line; the key set is the `local_models` rows). Each becomes a dense array. MC output must stay bit-identical. Measure with `bench-frontend` and an LHS MC deck.
5. **Output: appending P plots copies O(P²) bytes.** Body: `write.append` (output/write.zig:654) rewrites the whole file per plot to keep each publish atomic. A `.step` sweep into one raw file is quadratic. Option: hold one atomic file across the session's appended plots and replace it at `finish`. This changes the per-plot atomicity guarantee, so the owner decides.
