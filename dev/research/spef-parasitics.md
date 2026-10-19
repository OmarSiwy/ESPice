# SPEF/DSPF parasitics on a template (batch feature 4)

Research pass, 2026-10-19. No code changed. Paths are relative to each repo:
ESPice `main` (e1d5bfd2), GPurify `~/Documents/Projects/Rust/GPurify` (40ff66c0),
MATCHA `~/Documents/Projects/Research/MATCHA`.

**Recommendation in one paragraph.** Parsing is the easy part. GPurify's DSPF
is already valid ESPice SPICE, and ESPice already runs 1M-element R+C decks
(dev/devices/gpu-evaluation.md:439-458). The real work is the per-point
parameter path. Today it costs O(all device parameters) per point and
O(names × live) to look names up, and it re-plans when a value reaches zero.
Ship a `.parasitics` directive that loads the elements as fixed-topology
R/C/L cards, each addressed by index `P + i` in the same `values[count][P+E]`
row as the live params. Write those values through a prebuilt index → field
table, clamp R at a floor, and keep C = 0 as a zero stamp. Before building
it, ask the owner whether MATCHA needs ESPice to parse SPEF at all (Q1).

## 1. What GPurify emits

Writers live in `src/export/parasitic.rs` (SPEF :364, :393; DSPF :707) and
`src/export/netlist.rs` (`write_spice` with `Detail::WithParasitics`, :81).
CLI: `--format spef|dspf` (`src/cli/args.rs:126-131`, `src/cli/mod.rs:178-187`).
Sample: `tests/golden/pex/*.spef` (27 goldens, no DSPF goldens).

Common to all three:
- Nodes are `net:i`, where `i` counts from the net's first node (parasitic.rs:6-7, :803).
  There are no `*I` or `*|I` instance-pin lines. **Device terminals are lumped
  on `net:0`.** `ParasiticNetwork` has no terminal-to-node column, so
  netlist.rs:297-301 attaches every terminal at the net's first node.
- Elements come out in canonical order: near node, far node with ground first,
  then kind (parasitic.rs:420-424). This order is stable as long as the nodes
  are stable.
- Units are fF, Ω and pH with six decimals. NaN and inf are refused before
  anything is written (parasitic.rs:82).
- A label that names several nets, or a net with several labels, is refused
  (export/mod.rs `SplitLabel`/`ShortedLabels`), so net names are one-to-one.

SPEF subset (parasitic.rs:540-688; golden `PEX_COUPLING_C.spef`):
- The header is `*SPEF "IEEE 1481-1998"`, then `*DESIGN`, `*DATE`, `*VENDOR`,
  `*PROGRAM`, `*VERSION` and `*DESIGN_FLOW`, followed by
  `*DIVIDER /`, `*DELIMITER :` and `*BUS_DELIMITER [ ]`.
- Units: `*T_UNIT 1 NS`, `*C_UNIT 1 FF`, `*R_UNIT 1 OHM`,
  `*L_UNIT 0.000001 UH` (= pH).
- **No `*NAME_MAP`, `*PORTS` or `*I`, and no `*D_PNET`.**
- Each net is one block: `*D_NET <net> <total C>`, then `*CONN` with exactly
  one `*P <net> B`, then `*CAP`, `*RES` and `*INDUC` sections, then `*END`.
- `*CAP` rows are `id node C` (to ground) or `id node node C` (coupling).
  **A coupling cap is listed in both nets' sections**, each with its own
  net's node first (cefc71e8, parasitic.rs:8-10, :562-575). A reader must
  count it once.
- Corners: `write_spef_corners` writes `min:typ:max` triplets for every value
  (parasitic.rs:375-415).
- Two things SPEF cannot express travel as comments in the first net's
  block: `// mutual <node> <node> <pH>` and
  `// substrate <node> <node|0> <Ω>`. A plain SPEF reader loses them.

DSPF subset (parasitic.rs:690-800):
- Header lines `*|DSPF "1.4"`, `*|DESIGN`, ..., `*|DIVIDER /`,
  `*|DELIMITER :` and `*|GROUND_NET 0`.
- Per net, `*|NET <net> <C>f` and one `*|S (net:i L<layer>)` per node. There
  are no `*|P` or `*|I` lines.
- Then plain SPICE cards: `R<k> a b <Ω>`, `C<k> a b|0 <v>f`, `L<k> a b <v>p`,
  `K<k> L<a> L<b> <k>`. Each prefix numbers from 1 on its own.
- DSPF is the complete form. It carries L, K and substrate R as real cards.
  **Prefer DSPF**, and accept SPEF only for the GPurify subset.

The full IEEE 1481 and DSPF formats are larger (name maps, `*I` pin nodes,
`*D_PNET`, ports with direction and load, `*R_NET`). GPurify uses none of
them. Supporting `*NAME_MAP` costs about 20 lines. `*I`/`*|I` pin
attachment is a separate feature (Q3).

**MATCHA today** already models parasitics as a fixed skeleton of `.param`s.
`Topology.parasitic_params` (crates/matcha/src/model.rs:113) holds one value
per element, `run/params.rs:49-57` asserts the count is fixed per run, and
MATCHA/ARCHITECTURE.md:83-85 states it as an invariant. Every generator
returns `parasitic_params: Vec::new()` today (tile/netlist.rs:120,
bram/topology.rs:348, sizing/mod.rs:62), so no generator emits extracted
R/C yet. MATCHA links GPurify in-process (Cargo.lock:1110,
macromaster/src/views.rs:2), so it can get a `ParasiticNetwork` in
canonical order without going through a file.

## 2. ESPice today

**Frontend.** `prepare.prepare` (src/frontend/prepare.zig:80-99) expands
`.include`/`.lib` (source.zig) and then parses once with
`netlist.parseLive(..., live)`. `lines.zig:2-4` makes only `=`, `(`, `)` and
`,` one-byte fields, so `net:3` is one word. Lines starting with `*` are
comments (lines.zig:426, :553, :721), so the `*|` lines vanish. Hierarchical
nodes are `path.node` (netlist.zig:3226). **So GPurify's DSPF, or its
`write_spice` output (`.subckt TOP` with devices on `net:0` and `Rp`/`Cp`
cards), can be `.include`d today.** Three things block that route for this
feature:
- The values are literals.
- Bare DSPF card names (`R1`, `C1`) can collide with the template's own cards.
- A bare DSPF lands at top level, while the nets belong to the role's
  subcircuit. Its `net:0` also never meets the template's net `net`.

No SPEF, DSPF or `.dspf_include` support exists (grep finds only the
benchmark description at dev/devices/gpu-evaluation.md:398).

**Live params.**
- `Options.live_params` (src/espice.zig:67) reaches `parseLive`, which
  registers each name as a live slot before any card reads it
  (netlist.zig:1205-1216, `Live` at :201).
- C entry points: `espice_create_options.live_params`
  (include/espice.h:99, src/c_api.zig:286-319) and `espice_set_params`
  (espice.h:207-216, c_api.zig:453).
- `Problem.set_params` (espice.zig:368) calls `Tuning.set`
  (src/frontend/variants.zig:993-1083), which:
  1. resolves every name by a linear case-insensitive scan of
     `nl.live.names` (:1001-1006). For E names that is **O(E²)** compares
     per point, 10⁸ at E = 10k;
  2. re-evaluates every live slot and checks `.if` conditions and kept
     values (`Planner.load`, :378-416);
  3. writes the parameters straight through (the "identity" fast path,
     `probeIdentity` :434-470) when each moved slot maps 1:1 to a device
     field. `R a b {p}` maps 1:1: `r` is a Model field read at eval
     (models/resistor.va:31, :52), and the capacitor's `c` likewise
     (capacitor.va:7, :9). Otherwise it rebuilds and diffs;
  4. **appends a row of `(ref, value)` writes to the variant table on every
     call, kept until `deinit`** (:1066-1074; espice.zig:365). At
     E = 10k × 10⁶ points that is about 10¹⁰ writes.
- Each query's executor then runs `installVariant`
  (src/analysis/executor.zig:159-176). It copies the template circuit,
  calls `collectParams()` (**one ~64 B `ParamRef` per sweepable field of
  every device**, about 8-10 per resistor, after unsharing every Model row:
  src/device/abi.zig:39-52, :350-353; eval.zig:1702-1714), writes the row,
  and runs `recompute()` over all devices.

**Zero values.**
- A card resistance is floored to |R| ≥ 1e-12 at build time (`resistanceFloor`,
  builder.zig:2194-2196, used at :1380). The `.va` declares
  `r from (0:inf)`.
- In the planner, a slot whose value reaches, leaves or crosses zero forces a
  rebuild (`crossesZero`, variants.zig:717-719, used at :390-405). A slot that
  is zero at nominal maps nothing in the probe (:437-442), so every later
  point takes the rebuild-and-diff path.
- `sameTopology` (variants.zig:1191) compares the pattern. C = 0 keeps the
  capacitor's pattern (the builder drops no zero C, builder.zig:1007-1009),
  so it costs only a rebuild, never a refusal. A rebuild per point is the
  slow path.

**Verdict on "DSPF through the existing SPICE parser".** Yes for the cards.
A GPurify DSPF parses as-is once its values become `{param}` references and
it sits in a subcircuit scope. No for the point path at 10k-100k elements:
the per-point costs above scale with E (or E²), not with what moved.

## 3. Design

### 3.1 Attach

Add a directive, so the CLI, `.data` sweeps and the C API all get it:

```
.parasitics 'role.dspf' [scope=x1] [rmin=1m]
```

- **Format** is sniffed from the first line (`*|DSPF` or `*SPEF`). Path
  resolution is the same as `.include` (source.zig).
- **Scope:** every node `n` in the file becomes `scope.n`, and an empty
  scope means top level. This matches the role's subcircuit instance in a
  MATCHA testbench. Several directives with different scopes are allowed
  (one role instantiated twice).
- **Net aliasing:** `net:0` is the template node `scope.net`, which is
  GPurify's own lumping (netlist.rs:297-301). Every other `net:i` is a new
  internal node. A net in the file that the template lacks is an error
  (`UnknownNet`), not a silently floating island. A template net absent from
  the file stays as it is.
- **Elements:** each element becomes an R, C or L device (K couples two of
  them) with a generated name `P.<scope>.<i>`. The name cannot collide,
  because no SPICE card letter is `P` followed by `.` (check the HSPICE
  P-port card, Q8).
- **Reading SPEF:** coupling caps are deduplicated on the unordered node pair
  plus value (the cefc71e8 mirror). The typ value of a triplet is kept unless
  `corner=min|max` is given. `// mutual` and `// substrate` comments are
  parsed only with `gpurify=1` (Q5).
- **Implementation:** a small reader (`frontend/parasitics.zig`) produces a
  table `{kind, a, b, value}` that the builder adds with `addDevice` at the
  point it builds cards. It is not text spliced into the deck.
  `prepare.zig:92-97` is where `.include` text is expanded. The directive is
  read there like `.data` files (`loadData`, :102-113).

A create option is not needed: MATCHA writes the deck text, and a directive
also covers the CLI.

### 3.2 Stable indices

- Element `i` is the i-th element in **file order**, after coupling-cap
  dedup and across all kinds. For GPurify that is canonical order, which is
  stable while the layout's nodes are stable (parasitic.rs:420-424). Several
  directives concatenate in deck order.
- Its parameter index is `P + i`, where P is `live_params.len`. That is
  exactly the lane doc's indexing rule ("SPEF/DSPF set R/C by array index
  maps onto the same `values` row", lane-batched-simulation.md:680-684). The
  proposed `espice_batch_evaluate(values[count][P+E])` needs no new argument.
- Add `espice_parasitic_count(h, &E)` and
  `espice_parasitic_info(h, i, &kind, a, b)`, so MATCHA can assert that its
  skeleton matches. This is the same assertion as `run/params.rs:49`.
  Optionally add `espice_parasitic_values(h, file_bytes, out[E])`, which maps
  a per-point SPEF/DSPF onto the template's indices by `(kind, a, b)` and
  returns `REFUSED` when the element sets differ. This is only needed if
  MATCHA passes files rather than values (Q1).
- `.data` and `.step` reach an element by name: `.parasitics` also declares
  the live names `P.<scope>.<i>`, so a CLI sweep can set them. These names
  are not looked up per point (see 3.3).

### 3.3 Value path, with no re-plan

Parasitic values never go through the expression planner. At template build:
1. Resolve each element once to its device field. That is a
   `(batch, model row, field)` triple, which needs that device's Model row
   unshared (resistor, capacitor and inductor rows; the MOSFET rows can stay
   shared).
2. Keep the result as `[]*f64` (E pointers, 8 B each) per circuit copy.
   Alternatively keep `[]u32` offsets that a copy rebases.

Per point:
- Validate (finite) and clamp:
  - R: `max(|R|, rmin)`, sign kept only if negatives are enabled. The default
    `rmin` is 1e-12 (the card floor, builder.zig:2194); suggest 1 mΩ
    (restemp.c's default) for conditioning (Q6).
  - C: zero is allowed, since it keeps the stamp.
  - L: zero is refused, because the inductor's branch row stays.
  Then write E doubles, set a dirty bit on the touched batches, and
  `recompute` only those batches.
- Never append a variant row. A point is a value vector, not a variant. This
  needs P0's `espice_batch_evaluate` to apply values to its own circuit copy
  rather than through `Tuning.set` (its rows grow without bound, see item 4
  in §2).
- Topology is fixed by construction. No value can collapse a node, because
  the clamp keeps R off zero and C/L keep their patterns. `crossesZero` and
  the rebuild never run for parasitics.

The same index table also fixes the general live-param cost. An index-based
`set` that skips the name scan (variants.zig:1001) and the per-point
`collectParams` (executor.zig:165) helps every MATCHA size param too.

### 3.4 Net-name reduction

- Names are interned once per node (`r.intern`, netlist.zig:3226). A
  100k-node file costs about 100k strings of about 20 B, which only the
  parse arena keeps.
- **Structural reduction only.** Values vary per point, so value-based
  reduction (TICER, dropping small C) would change the topology per point.
  What can run once:
  - Merge series resistor chains whose inner nodes have no C and no other
    connection. The merged R is the sum of the elements' values, so its value
    is a fixed linear combination. That needs a tiny `[]u32` map from merged
    element to its source indices, with no float state.
  - Drop elements whose both ends are the same node.
- **Not proposed for v1.** GPurify networks are already per-segment minimal,
  and the LU handles 1M R+C (gpu-evaluation.md:439-458).

### 3.5 Memory per template

These figures are estimates from the struct layouts and were not measured.
Resistor Model ≈ 104 B (11 f64 + bools, `.zig-cache/vera-check/resistor.device.zig:637-650`),
Instance ≈ 32 B.

| Item | Per element | 10k | 100k |
|---|---:|---:|---:|
| Model + Instance rows, `model_of`, pins | ~150 B | 1.5 MB | 15 MB |
| Matrix entries (≤4 nnz, values + slot tapes) | ~50 B | 0.5 MB | 5 MB |
| C/L history (charge ring, ~4 f64) | ~32 B | 0.3 MB | 3 MB |
| Index → field table | 8 B | 80 KB | 0.8 MB |
| **Today:** `collectParams` per executor (~9 × 64 B) | ~580 B | 5.8 MB | 58 MB |
| **Today:** variant row per point (12 B × E, kept) | 12 B/pt | 120 KB/pt | 1.2 MB/pt |

So ~0.25 KB per element (25 MB at 100k) per circuit copy once the last two
rows are gone. Every query instantiates a copy (executor.zig:126-133), so a
handle with `max_parallel` = k holds k + 1 copies.

### 3.6 Lane batching

- Values become lane data with no API change: `values[count][P+E]` is
  already the lane row.
- With R/C/L as VerA resistor/capacitor rows, each element's Model row
  differs per lane, so lane dedup (lane doc §3.2, :254-258) keeps
  E × lanes rows. At ~104 B that is 6.4 MB for W = 8 and 100k elements
  (fine), but **85 GB at N = 8192 on a GPU** (not fine).
- For P2, a dedicated linear-passive batch with value-only SoA lanes
  (`value[i*L + l]`: 8 B × E × L = 6.5 GB at N = 8192 and E = 100k, so N is
  bounded by E) stamps `1/R` or `C` straight from the values. It needs no
  Model row or `derive`, and it fits the lane doc's "element (i, l) at
  i*L+l" layout (:244-252). Hand-written devices are allowed by the ABI
  (`ParamRef.Ptr` f32/f64, abi.zig:39-57).
- Defer that device until P2 is gated. The index API in 3.2 does not change
  when the backing store does.

## 4. Effort and open questions

| Work | Effort |
|---|---|
| DSPF + GPurify-SPEF reader (units, triplets, mirror dedup, NAME_MAP), with goldens from GPurify's `tests/golden/pex` | 2-3 d |
| `.parasitics` directive: scope, `net:0` aliasing, generated names, builder hookup | 2-3 d |
| Index → field table, clamp, dirty-batch recompute, no variant rows (shared with P0) | 2 d |
| `espice_parasitic_count/info`, and optionally `_values` | 1 d |
| Tests: a DSPF RC ramp vs the same deck with literal cards (bitwise), R→rmin and C→0 per point without rebuild, 10k-element template RSS | 1-2 d |
| **v1 total** | **~1.5-2 weeks** |
| Linear-passive lane device (P2 only) | 1-2 weeks, deferred |

Open questions for the owner:
1. **Does ESPice need a SPEF/DSPF reader at all?** MATCHA links GPurify
   in-process, already has the parasitic skeleton as `.param`s, and could
   emit GPurify's `write_spice` output with `{p_i}` values. That runs today.
   The only blockers are the per-point costs in §2, which the index path in
   3.3 fixes. If yes, which one: file-per-point (`_values`), or values only?
2. **Is the topology really fixed across points?** A resized transistor
   changes the layout, so GPurify can add or drop segments, and a coupling
   can enter or leave the halo. A missing C can read as 0, but a missing R
   cannot be expressed. Does MATCHA freeze the skeleton (union of elements,
   absent C = 0), or refuse such a point (`REFUSED`)?
3. **Pin placement.** GPurify lumps every terminal on `net:0`. Is that
   accurate enough for MATCHA's delays, or should GPurify emit `*I`/`*|I`
   pin nodes, which ESPice would then map onto device pins?
4. **Corners.** Pick one value of a triplet per template, or make the corner
   a lane dimension (feature 5)?
5. **L, K and substrate R.** Include them? Asap7 tiles likely need only R/C.
   SPEF carries them only as GPurify comments.
6. **R floor.** 1e-12 (the card floor) or 1 mΩ? Are negative values from
   extraction allowed? `resistor.va` declares `r` in `(0:inf)`.
7. **Index contract.** File order across kinds (proposed), or separate R
   and C index spaces as the DSPF card numbers suggest?
8. **Name prefix.** Confirm that `P.` collides with no dialect's card letter
   (HSPICE `P` is a port element, and its names never contain `.` at top
   level), or pick another reserved prefix.
