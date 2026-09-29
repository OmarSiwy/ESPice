# Variants: `.step`, `.data`, `.alter` and Monte Carlo

One prepared circuit, many parameter sets. This page covers the variant
runner (hspice-comparison C1), the live parameter table under it (C2,
vacask-comparison G1) and statistical Monte Carlo (C3, G2).

## 1. What a deck can say

| Form | Meaning | Rows |
|---|---|---|
| `.step [lin\|dec\|oct] param p a b x`, `.step param p list v...` | every analysis once per point (ngspice/LTspice form) | one per point, no nominal run |
| `.step temp ...`, `.step <source> ...` | the same over the temperature or a card's primary value (`dc`, `r`, `c`, `l`) | as above |
| several `.step` cards | cartesian product; the **last card varies fastest** | |
| `.data d p1 p2 ... .enddata` (inline) | a table; columns are `.param` names, sources/elements or `temp` | |
| `<analysis> ... SWEEP DATA=d` | that card once per row | one per row |
| `<analysis> ... SWEEP p a b x`, `SWEEP p lin\|dec\|oct\|poi ...` | that card once per point | one per point |
| `.dc DATA=d` | the rows as one DC sweep (first column is the axis) | one lane query |
| `<analysis> ... SWEEP MONTE=n [FIRSTRUN=k]` | the nominal run, then trials k..k+n-1 | nominal plus n |
| `.dc MONTE=n` | the trials as one DC table (`run` column) | one lane query |
| `.alter` blocks (HSPICE) | the base run, then one run per block | base plus one per block |

Every analysis card runs per variant, and each plot is named
`<plot> (<label>)`: `Operating Point (rv=3000)`, `AC Analysis (rl=1000,
v1=1)`, `Transient Analysis (monte=7)`, `Operating Point (alter=2)`.
`.meas` prints per plot as before; over Monte Carlo trials it then prints
`mean(name)`, `sigma(name)` (Bessel-corrected), `min(name)` and
`max(name)` per card.

### Choices that are ours

- **`.alter` is cumulative**: block k edits the deck as blocks 1..k-1 left
  it. HSPICE's manual describes each run reading the input after the
  previous `.alter`, and options set in one block staying set until a
  later block turns them off; Spectre's `alter` statements persist the
  same way. **Not yet checked against an HSPICE run.** In a block, an
  element card replaces the top-level card of that name, `.model` and
  `.subckt ... .ends` replace by name, `.lib file sec` replaces the `.lib`
  line naming the same file, `.del lib` removes one, and anything else is
  appended (`.param`: the last definition wins).
- **Monte Carlo draws** are counter-based: trial k's value at a call site
  is a hash of (seed, k, site), so any trial can be recomputed alone. A
  site is the call in its defining text: a global `.param` call draws once
  per trial wherever it is read, a subcircuit parameter's call once per
  instance, a call written on a card once per card. `.option seed=`
  (default 1) and `.option sampling_method=srs|lhs`. Latin hypercube keeps
  one random stratum permutation per site.
- **Distributions** [SA Ch.20]: `agauss(nom, abs, sigmas[, mult])` and
  `gauss(nom, rel, sigmas[, mult])` are normal with sigma `abs/sigmas`
  (`nom*rel/sigmas`); `aunif(nom, abs[, mult])`, `unif(nom, rel[, mult])`
  uniform over ±width; `limit(nom, abs)` one of the two extremes. A
  multiplier m keeps the largest of m draws. Outside Monte Carlo every one
  folds to its nominal.
- **`DEV`/`LOT`** after a `.model` value (`is=1e-14 lot/gauss=10%
  dev/2/gauss=2%`): `LOT` draws once per model and trial, `DEV` once per
  device. The value is one sigma for `gauss`, the half range for `unif`
  (the default distribution) and `limit`; `%` makes it relative. The
  sigma reading follows the variation block; **HSPICE's own convention
  for DEV/LOT GAUSS is not verified.**
- **`.variation`**: `.global_variation` rows (`<type> <model> p=σ [%]`)
  draw per model, `.local_variation` rows per device, and
  `.element_variation` rows (`<letter> p=σ [%]`) per element; σ is one
  sigma of a normal.

## 2. How a variant becomes a row

The deck is parsed once. Before the device walk, every swept `.param`
name is registered as **live**. `subst` then emits a `.live` operand for
it instead of splicing its text, and a device or model value that reads a
live name (or, when some card runs Monte Carlo, a distribution call) keeps
its postfix. After the walk each such value becomes a **slot**: a pointer
to the table value, the postfix it is re-evaluated from, and the factor
`.option scale` applies. The nominal build sees the nominal number, so a
deck without variants builds exactly as before.

`variants.zig` then turns each point into a `core.Variants` row, the
parameter writes that turn the nominal circuit into that variant:

1. Re-evaluate the slots for the point (`Netlist.setLive`). No text is
   read again.
2. **Fast path.** On the first point that moves a slot, one probe build
   sets every slot to a distinct nearby value and diffs the parameters
   (`collectParams` order). If every parameter that moved holds exactly
   one slot's probe value, and held that slot's nominal before, the map
   slot → parameters is recorded and every later point writes slot values
   straight to those parameters. Nothing is rebuilt.
3. **Rebuild path.** Otherwise (a derived parameter moved, a slot is zero,
   or a point takes a value across zero, which may collapse a node), the
   point rebinds the netlist into a scratch circuit and keeps the
   parameters that differ. `force_rebuild` makes this the oracle of the
   fast path's differential test (`frontend/tests/variants.zig`).
4. If the rebuilt circuit's pattern, node count or devices per type
   differ, or a B-source expression reads a live name (its tape is not
   `ParamRef` storage), the point becomes its own `Prepared` run with its
   own session, published after the main one.
5. Source/element targets, `.data` card columns and Monte Carlo
   `DEV`/`LOT`/`.variation` draws add their writes on top.

An `.alter` run is parsed from its own text. When it keeps the same cards
on the same nets and the same analyses and options, and the deck has no
other variants, it is diffed into a row like a point; otherwise it is a
separate run that plans its own variants.

At run time a query carries `Tolerances.variant`; its executor writes the
row through `ParamRef.set`, sets the row's temperature, and recomputes
once. Dependent queries copy the OP circuit, variant included.

`.dc DATA=` and `.dc MONTE=` run their rows as one `Mc` query on the
structural lanes (`sweep/lanes.zig`), each lane warm-started from the
previous lane's solution when that converged.

## 3. Measurements

A 100 x 100 resistor grid (19,801 resistors, every value `{rv}`) with
`.step param rv list` of 20 points and one `.op`, `--timing-in-depth`,
three runs each, ReleaseFast, CPU-only, on a machine at load average 20-25
(other builds running), so read the ratios, not the digits:

| Path | Problem creation | run total | wall |
|---|---|---|---|
| fast path (one probe build) | 57-77 ms | 0.94-1.08 s | 1.08-1.24 s |
| rebuild every point (`force_rebuild`) | 375-540 ms | 0.91-1.01 s | 1.37-1.67 s |
| 20 separate decks, one `espice` each (re-prepare) | 10-15 ms each | | 1.28-1.48 s |

The fast path costs one extra build over the nominal one, whatever the
point count; the rebuild path pays a bind and freeze per point. Per-point
analysis time is the same in all three: each variant is its own `.op`
query on its own circuit copy.

## 4. Limits

- `ponytail:` a swept name read by an analysis card, `.meas`, `.ic`,
  `.options` or `.if` is refused (`UnsupportedCard`), since nothing would
  re-read it. A top-level `.if` on a swept name keeps its nominal branch.
- A swept or sampled `l`/`w` on an M card whose model is binned is refused:
  a variant never re-picks the bin.
- `.data` reads inline tables only (`MER`, `LAM`, `FILE=` are refused).
  `MONTE=list(...)` is not parsed.
- `SWEEP` on a card together with `.step` in the same deck is refused.
- A DC ensemble point that needs its own topology is refused.
- The fast-path probe sees each parameter at one perturbed point: a
  parameter that is a non-identity function of a slot but equals it there
  (a clamp that is inactive near the nominal) would be written as the slot
  value. The rebuild path has no such blind spot.
- Runs with their own topology are listed on stderr only for the main
  session (`espice` prints its summary from the main Problem); their plots
  are in the output file.
