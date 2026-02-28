# Output plumbing: five defects between the solved circuit and the raw file — 2026-09-13

Five things the solver got right and the writer got wrong. None of them is a
numerics bug; four are naming or column-set bugs and one (`ac=`) is a missing
parameter path. They are grouped because they share a failure shape: the values
were already correct, nothing downstream could address them.

Normative reference throughout is ngspice 44.2, sources at
`/tmp/ngsrc/ngspice-44.2`. (`/home/omare/Documents/Projects/Zig/ngspice-44.2-fromsource`
is an install prefix, not a source tree — do not cite line numbers off it.)

Gate: `zig build test` after every commit. Baseline at `spice-audit`
(6f60612) is 408/408; this branch adds six tests and holds **414/414 at all
five commits**.

Method note for every before/after table below: plots are matched by **title**,
not by position. ngspice writes the AC plot first and the OP plot second on a
deck that asks for both; espice writes them in deck order. A positional
comparison scores each plot against the wrong one and reports a clean 0.00e+0
for a deck that is off by 50%. `benchmark/check_fixtures.py`'s `compare()`
still zips positionally; that is a separate pre-existing limitation and was
left alone, since touching it would change the pass rule.

Fixture evidence is a full 258-deck capture (`benchmark/capture_raws.sh`)
against a baseline binary built from 6f60612 in a sibling worktree. **Exit
codes are identical for all 258 decks; 237 decks are byte-for-byte unchanged.**

---

## 0. Why four of the five were inert when first written

The original patch series was committed but never built. Two of its five
defects were dead on arrival for one shared reason, worth recording because the
mechanism will bite again.

`analysis.CardRef` is a `(device type, instance ordinal) -> card name` table
that `.sens` and the resistor `ac=` path both resolve through
`CardRef.lookup`. It was filled in `Builder.addDevice`, immediately before
`ProtoStore(D).append`:

```zig
const store = try self.protoStore(D);
if (self.card.len != 0) try self.cards.append(self.gpa, .{
    .type_name = comptime shortTypeName(D),
    .index = @intCast(store.instances.items.len),   // <- never reached
    .name = self.card,
});
```

That code is unreachable for every shipped device. Since the per-model object
split, `addDevice` opens with

```zig
if (comptime devices.modelName(D)) |name| {
    const vt = devices.vtable(name);
    ...
    return vt.proto_add(proto.ctx, self.gpa, ...);   // <- RETURNS
}
```

so a generated device — which is all of them — is instantiated through the
device object's own `ProtoStore` behind `vt.proto_add`, and control never
reaches the in-process `protoStore(D)` path below. `b.cards` was empty on
every deck, `CardRef.lookup` returned null on every row, and both consumers
silently fell back: `.sens` re-emitted `resistor#0.r` under a `v(...)` wrapper,
`acParams` resolved no resistor at all.

The fix is a per-device-type counter on the `Builder`, placed *above* the
branch, incremented on every add whether or not a card is open so it stays in
lockstep with the ordinal the device object's store hands out:

```zig
const gop = try self.card_counts.getOrPut(self.gpa, comptime shortTypeName(D));
if (!gop.found_existing) gop.value_ptr.* = 0;
if (self.card.len != 0) try self.cards.append(self.gpa, .{ ... .index = gop.value_ptr.* ... });
gop.value_ptr.* += 1;
```

It cannot read the count off the store, because naming `ProtoStore(D)` in this
compilation unit is exactly what the object split exists to prevent; and it
cannot ask the vtable, because `DeviceVtable` is frozen at the GPU boundary.
`shortTypeName(D)` is the same `@typeName`-last-component derivation
`ParamRef.device_type` uses, so the key matches by construction.

Second inert-on-arrival item: `Circuit.linearizeAc` was added for defect 5 and
`FreqSolver.fromCircuit` switched to it, but `freq_solve.zig`'s test-local
`Ckt` mock still declared `fn linearize`. That should have failed the solvers
suite to compile. It did not, because **this worktree's pre-seeded
`.zig-cache` was serving stale results**: manifests copied from the main tree
made `zig build test-solvers` report `cached` and PASS for source that does not
compile. Verified by appending a `@compileError` test — green against
`.zig-cache`, correct failure against `--cache-dir /tmp/...`. Deleting
`.zig-cache/h` (manifests only; `o/` objects survive) restored honest caching
at the cost of one 4m32s full rebuild. Any measurement taken in a seeded
worktree before that point is worthless.

---

## 1. `parser.zig` — subcircuit flattening built names inner-first

### What ngspice does

`src/frontend/parser.zig:995` built the instance path inside-out:
`nd.name = sd.name ++ "." ++ d.name`. ngspice prepends the *enclosing*
instance:

```c
/* subckt.c:1135-1155, translate_node_name  -> <scname>.<node>            */
/* subckt.c:1159-1173, translate_inst_name                                */
/*   non-X card : <letter>.<scname>.<name>                                */
/*   nested X   :          <scname>.<name>                                */
```

with `scname` the instance being expanded, each enclosing level prepending in
turn. So a V card inside `x1` inside `x2` is `v.x2.x1.v1`, and the nested X is
`x2.x1`. Nodes take the same path without the letter.

### The fix

```zig
nd.name = if (sd.letter() == 'x')
    try std.mem.concat(arena, u8, &.{ d.name, ".", sd.name })
else
    try std.mem.concat(arena, u8, &.{ &.{sd.letter()}, ".", d.name, ".", sd.name });
```

The leading letter is load-bearing, not cosmetic: `Device.letter()` reads
`name[0]` to dispatch, so an outer-first path without it types every flattened
device as an X card and `fourbitadder` fails to parse.

### Before / after

| deck | shared with ngspice | missing | extra | max rel err on shared |
|---|---|---|---|---|
| `ngspice/fourbitadder` | 64 → **271** | 207 → **0** | 207 → **0** | 2.63e-5 → 1.21e-4 |
| `tran/fourbitadder` | 64 → **271** | 207 → **0** | 207 → **0** | 2.63e-5 → 1.21e-4 |

271 of 271 column names now agree with ngspice, zero difference in either
direction, on both decks.

### Only NAMES moved

The apparent error growth is the 207 previously-unscorable columns joining the
comparison, not a regression. Two independent proofs:

1. **The multiset of column data blobs is bit-identical before vs after**,
   271 of 271 columns, both decks. The rename is a pure permutation of the
   name → data mapping.
2. Restricted to the 64 column names that survive the rename, max rel err vs
   ngspice is **2.63e-5 before and 2.63e-5 after** — identical. Of those 64,
   exactly 12 changed data, and they are the two mutually-reversed paths
   `v(x1.x1.x2.x1.N)` ↔ `v(x1.x2.x1.x1.N)` for N ∈ {5,6,7,8,9,10}. Their data
   swapped; per-column error vs ngspice is unchanged to the last digit on all
   12 (5.44e-6, 4.02e-7, 5.59e-6, 2.20e-6, 2.50e-5, 7.56e-7, each appearing
   twice).

`parameter_tests.zig` expectations renamed to the same convention.

---

## 2. `ac/sp.zig` — `portnum`/`z0` never reached `sp.Options.ports`

### What ngspice does

```c
/* vsrctemp.c:74-82   a V source is a port when `portnum` is GIVEN;      */
/*                    z0 defaults to 50; counted while z0>0 && portnum>0 */
/* vsrctemp.c:110-124 CKTrfPorts sorted by portnum                       */
/* vsrctemp.c:143-160 gapped or duplicated numbering is fatal            */
/* vsrcload.c:50-63   the port stamps series g0 = 1/z0 between its node  */
/*                    and an internal `res` node, ideal source behind it */
```

i.e. a Thévenin source of impedance z0 per port.

### Root cause

`portnum`/`z0` parsed as inert positionals on the V card and never reached
`sp.Options.ports`, so `sp.run` always took its one-port fallback. Port 2
stayed a plain 0 V source — a **short to ground** — and only S11 came out.
`sp.zig` already implemented the Thévenin form (`-z0` on the branch-row
diagonal); it was only ever handed an empty port list.

Measurable, not inferred: `sp/pi_attenuator` with port 2 terminated in 50 Ω has
Zin = 150 ∥ (37.5 + 150∥50) = 50 → S11 = 0. Shorted it is 150 ∥ 37.5 = 30 →
S11 = −0.25, which is what espice printed at every frequency.

Column spelling is ngspice's too: `span.c:544-551` emits `S_<i>_<j>` as
`UID_OTHER`, which its raw writer types as a voltage, so the file spells it
`v(S_1_1)`; the plot opens as `"SP Analysis"` (`inp2dot.c:710`).

### Before / after

| deck | shared | missing | extra | max rel err |
|---|---|---|---|---|
| `sp/pi_attenuator` | 1 → **5** | 18 → **14** | 1 → **0** | 4.00e-16 |
| `sp/rc_twoport` | 1 → **5** | 18 → **14** | 1 → **0** | 3.21e-15 |
| `sp/lc_lowpass` | 1 → **5** | 19 → **15** | 1 → **0** | 7.09e-15 |
| `golden/sp` | 1 → **5** | 18 → **14** | 1 → **0** | 1.68e-15 |

`pi_attenuator` now reads S11 = 5.55e-17 (ngspice 0), S22 = 5.55e-17 (ngspice
1.67e-16), S12 = S21 = 0.5 exactly. The 14 still-missing reference columns are
ngspice's node voltages inside the sp plot plus its Y and Z matrices, which
espice does not emit.

`benchmark/check_fixtures.py` `PLOTS["sp"]` follows the plot rename; no
tolerance changed.

---

## 3. `engine.zig` — one `i()` column per branch unknown, not per card letter

### What ngspice does

The rule is structural, not a list of letters: every MNA branch-current unknown
gets a `CKTmkCur` row and `CKTnames` turns every such row into an `i(<card>)`
column.

```c
/* vcvsset.c:41-46   E: CKTmkCur unconditionally                          */
/* ccvsset.c:41-46   H: CKTmkCur unconditionally                          */
/* asrcset.c:81-88   B: CKTmkCur ONLY under `ASRCtype == ASRC_VOLTAGE`    */
```

F, G and S stamp no branch and correctly have no column. **A current-mode B
also has none** — `asrcset.c` guards its `CKTmkCur` on `ASRC_VOLTAGE`, so
`b1 out 0 i={...}` produces no `i(b1)` in an ngspice raw.

### Root cause

The probe list registered V cards and inductors and explicitly *skipped* any V
card an F/H/W sensed. Two gaps: E, H and a V-mode B got no branch current at
all, and `i(vam)` vanished the moment a V card was named as a sensor — the same
card emitted `i(vzero)` when nobody referenced it.

The missing `i(vam)` was a stale row, not a missing one: `builder.zig` recorded
the sensed card's branch as `self.b.n` sampled before an `addDevice` that never
runs (the 4-port F/H/W model carries `branch (cp,cn) ctrl` in its place), so
the row pointed at whatever card came next. `addBranchRef` now rewrites
`v_branches[ctrl]` to the ctrl branch the model actually allocated, and the
engine stops skipping sensed cards.

espice's 4-port `bsource` declares the branch unknown in *both* modes, so the
mode has to be reported out: `addBsource` returns true for V-mode and only then
is the probe registered. Publishing the I-mode row would have added a permanent
zero column ngspice never writes.

`internalRow(D, "flowZ28cpZ2ccnZ29", first)` names the U member rather than
hardcoding `first + 1` — ccvs declares two branches and the sense one comes
first, so a wrong offset is now a compile error, not a mislabelled current.

### Before / after

| deck | shared | missing | extra | max rel err | column |
|---|---|---|---|---|---|
| `devices/vcvs` | 4 → **5** | 1 → **0** | 0 | 0.00e+0 | `i(e1)` |
| `devices/ccvs` | 4 → **6** | 2 → **0** | 0 | 0.00e+0 | `i(h1)`, `i(vam)` |
| `devices/cccs` | 4 → **5** | 1 → **0** | 0 | 0.00e+0 | `i(vam)` |
| `devices/cswitch` | 7 → **8** | 1 → **0** | 0 | 0.00e+0 | `i(vam)` |
| `devices/bsource` | 4 → **5** | 1 → **0** | 0 | 8.46e-16 | `i(b1)` (V-mode) |
| `analog/opamp_inverting` | 4 → **5** | 1 → **0** | 0 | 5.55e-17 | `i(eopamp)` |
| `convergence/high_gain_fb` | 4 → **5** | 1 → **0** | 0 | 1.11e-16 | `i(e1)` |
| `convergence/schmitt` | 6 → **7** | 1 → **0** | 0 | 2.70e-12 | `i(e1)` |
| `ngspice/behavioral_bsrc` | 4 → **4** | 0 | 1 → **0** | 1.07e-15 | I-mode B: no column |
| `devices/mesa_inverter` | 15 → **15** | 4 | 2 → **0** | 4.73e-4 | I-mode B ×2: no column |

Every new column agrees with ngspice in sign and value; no previously scored
column moved. The last two rows are the I-mode B correction — caught only
because the full capture flagged `extra=1`/`extra=2` against the reference.
Xyce independently corroborates the E/H/B column set.

---

## 4. `sweep/sens.zig` — columns keyed by device-class ordinal

### What ngspice does

```c
/* cktsens.c:224-238                                                  */
/*   model parameter             -> <card>:<param>    (r1:tc1)        */
/*   IF_PRINCIPAL instance param -> <card>            (r1)            */
/*   any other instance param    -> <card>_<param>    (r1_scale)      */
```

The name goes out as `UID_OTHER`, which the raw writer types as a voltage, so
the file spells it `v(r1)`. Plot is `"Sensitivity Analysis"` (`inp2dot.c:461`).

### Root cause

`.sens` wrote 175 columns keyed `resistor#0.r`, `vsource#0.dc`. The values were
right — they matched ngspice exactly on every nonzero entry across all three
sens decks — but a device-class ordinal resolves to nothing a raw-file reader
can map back to a card, so no comparator and no user could address them.
`ParamRef` already carried `is_instance` and `primary`; what it lacked was the
CARD. The `CardRef` table (§0) supplies it.

`principal` is NOT gated on `is_instance`: VerA puts every Verilog-A
`parameter` on `Model`, so ngspice's `IF_PRINCIPAL` flag landed on `primary`.

### Before / after

| deck | shared | missing | extra | max rel err on shared |
|---|---|---|---|---|
| `sens/voltage_divider` | 0 → **3** | 53 → 50 | 175 → 172 | — → 1.62e-11 |
| `sens/rc_lowpass` | 0 → **3** | 61 → 58 | 178 → 175 | — → 2.06e-12 |
| `sens/bridge` | 0 → **6** | 125 → 119 | 184 → 178 | — → 1.27e-11 |
| `golden/sens` | 0 → **3** | 53 → 50 | 175 → 172 | — → 1.62e-11 |

The shared set is exactly ngspice's nonzero entries. The rest do not intersect
because the parameter SETS differ (ngspice's `r1:rsh` / `r1_temp` / `r1_m` have
no espice counterpart; espice's `r1_temperature` / `r1_mfactor` have no ngspice
one). `.sens` needs intersection-only scoring either way, which is what the N/A
audit already concluded.

### Only NAMES moved

Column count is unchanged on all four decks (175, 178, 184, 175) and the
**multiset of column data blobs is bit-identical before vs after on all four**.
Zero names survive the rename, which is the point: every column was previously
unaddressable.

`.dcmatch` keeps its ordinal keys; it is a different output contract.
`check_fixtures.py`'s `analytical()` follows the rename for `sens` and keeps
the ordinal keys for `dcmatch`; no tolerance and no pass rule changed.

---

## 5. `builder.zig` — `ac=` on a resistor was ignored

### What ngspice does

```c
/* res.c:16          `ac` is an IOPAA on the resistor instance            */
/* resdefs.h:48-49   RESacResist / RESacConduct beside the DC pair        */
/* restemp.c:112-118 acConduct = m / (acResist * tempco * scale) — the    */
/*                   SAME instance factors as DC; absent `ac`,            */
/*                   acConduct := conduct                                 */
/* resload.c:60-62   RESacload stamps acConduct where RESload stamps      */
/*                   conduct                                             */
```

So `ac=` moves `.ac` / `.sp` / `.noise` / `.pz` and leaves `.op` / `.dc` /
`.tran` alone.

### Root cause and fix

`r2 2 0 5K ac=15k` used 5 kΩ everywhere. That split is the whole feature, so
espice gets the same split rather than a second resistor parameter:
`Circuit.linearizeAc` is `CKTacLoad` to `linearize`'s `CKTload` — it swaps the
AC values in, fills the planes, puts the DC values straight back, and leaves
the linearization memo invalid so a later DC eval cannot read the AC planes as
its own. Every frequency-domain entry point goes through it
(`freq_solve.fromCircuit` for `.ac`/`.noise`, `sp.zig` both paths, `stb.zig`,
`pz.zig`); a deck with no override takes a length check and falls into plain
`linearize`.

Overrides are recorded by CARD in the builder and resolved to `ParamRef`s after
freeze, since instance ordinals and the pointers they key do not exist before
it — which is why this defect is coupled to §0's `CardRef` table and was inert
for the same reason `.sens` was.

`Circuit.init` builds from `undefined`, so struct defaults do not apply;
`ac_params` is assigned there explicitly.

### Before / after

| deck | plot | max rel err before | after |
|---|---|---|---|
| `ngspice/res_partition` | AC Analysis | **1.43e-1** | **2.88e-15** |
| `ngspice/res_partition` | Operating Point | 0.00e+0 | 0.00e+0 |
| `ngspice/res_array` | AC Analysis | **7.99e-4** | **5.77e-15** |
| `ngspice/res_array` | Operating Point | 1.00e-30 | 1.00e-30 |
| `ngspice/res_array` | Transient Analysis | 0.00e+0 | 0.00e+0 |

`res_partition` v(2): 0.5 → **0.75** in AC (ngspice 0.75), 0.5 in OP
(ngspice 0.5) — the DC answer is unchanged, as it must be. `res_array`
exercises `ac=` against `m=`, `scale=` and an R model card; all five branch
currents land on ngspice's values. No non-AC plot moved on either deck.

---

## Aggregate effect on the 258-deck capture

| | |
|---|---|
| decks captured | 258 |
| exit codes changed | **0** |
| decks byte-identical before/after | **237** |
| decks with name changes only, values bit-identical | **6** (2 × fourbitadder, 4 × sens) |
| decks with value changes | **15** (sp ×4, i() ×8, `ac=` ×2, vbic_diffamp) |
| `golden` fixture suite | 21/24 + 1 XFAIL, before **and** after |

The 3 non-passing golden fixtures (`noise` plot-name split, `qpss`
non-convergence, `stb` XFAIL) are identical at baseline and pre-date this
branch.

## Commits

Each builds and passes `zig build test` at 414/414 on its own, so any one can
be reverted independently.

| | |
|---|---|
| `fix(parser): flatten subckt names outer-first, as SPICE does` | §1 |
| `fix(sp): terminate every declared port in its own z0` | §2 |
| `fix(engine): one i() column per branch unknown, not per card letter` | §3 |
| `fix(sens): name sensitivity columns after the card, as ngspice does` | §4 + §0 card table |
| `fix(builder): `ac=` on a resistor is an AC-only resistance` | §5 + §0 mock |
