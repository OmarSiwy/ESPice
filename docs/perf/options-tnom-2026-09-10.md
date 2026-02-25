# `.options tnom` — the nominal temperature was never plumbed

`.options tnom` was parsed by nothing and reached nothing. `grep -rn tnom
src/**/*.zig` on the branch point found two hits: `sweep/temp_sweep.zig`, which
means something else by the name (the sweep's restore point), and the
`tnom`→`tref` card-key alias at `src/builder.zig:480`. A deck that set the
option got no warning, no diagnostic and no change in the answer.

Every `.va` in `src/devices/models/` spelled its own extraction temperature as
a literal instead. `bsim4va.va` said so out loud:

```verilog
/* NOTE: Verilog-A does not support access to the modelcard
 * default Tnom value */
if (!$param_given(tnom))
    BSIM4tnom = `DEFAULT_TNOM + `P_CELSIUS0;
```

That note is what this change disproves. §9.15 Table 9-27 is exactly the
channel a module uses to ask the simulator for the nominal temperature;
VerA was folding the answer to a constant 27 before anyone could publish one.

Cost of getting it wrong, measured on the fixture added below: **26x** on a
diode current, **2547%** on a BJT collector current, **3.5%** on a MOS1 drain
current — silently, on a deck whose whole point was the option.

---

## 1. ngspice semantics, with citations

ngspice 44.2, `/tmp/ngsrc/ngspice-44.2` (the pinned release tarball).

| Question | Answer | Citation |
|---|---|---|
| Card spelling | `.options tnom=<v>` | `src/spicelib/analysis/cktsopt.c:268` — `{ "tnom", OPT_TNOM, IF_SET\|IF_ASK\|IF_REAL, "Nominal temperature" }` |
| Units | the CARD is **degrees Celsius**; stored in kelvin | `cktsopt.c:71-73` — `case OPT_TNOM: task->TSKnomTemp = val->rValue + CONSTCtoK; /* Centegrade to Kelvin */` |
| Default | 300.15 K = **27 °C** | `cktntask.c:127` — `tsk->TSKnomTemp = 300.15;` |
| Reaches the circuit as | `CKTnomTemp` | `cktdojob.c:53` — `ckt->CKTnomTemp = task->TSKnomTemp;` |
| Interaction with `.options temp` | **none** — two independent task fields | `cktsopt.c:74-76` (`OPT_TEMP → TSKtemp`), default `cktntask.c:126` (`TSKtemp = 300.15`). `cktdojob.c:122-123` prints them as two numbers: `"Doing analysis at TEMP = %f and TNOM = %f"` |
| Per-card override | the card wins, unconditionally | every model setup: `if (!<X>tnomGiven) <X>tnom = ckt->CKTnomTemp` |

The per-card override is one line repeated across 37 device directories
(`grep -rln CKTnomTemp src/spicelib/devices | wc -l` → 37). Representative:

- `src/spicelib/devices/bsim4/b4set.c:1950-1951`
  ```c
  /* unit degree celcius */
  if (!model->BSIM4tnomGiven)
      model->BSIM4tnom = ckt->CKTnomTemp;
  ```
- `src/spicelib/devices/dio/diosetup.c:219-220` — `if(!model->DIOnomTempGiven) { model->DIOnomTemp = ckt->CKTnomTemp;`
- `src/spicelib/devices/mos1/mos1temp.c:42` — `model->MOS1tnom = ckt->CKTnomTemp;`
- `src/spicelib/devices/bjt/bjttemp.c:43` — `if(!model->BJTtnomGiven) model->BJTtnom = ckt->CKTnomTemp;`
- `src/spicelib/devices/mos6/mos6temp.c:41` — same shape

`TREF` is a second card key for the same storage, not a second parameter:
`src/spicelib/devices/dio/dio.c:53-54` binds `"tnom"` and `"tref"` to the same
`DIO_MOD_TNOM`. ESPice already had that alias (`src/builder.zig:480`), so both
spellings raise the same `__given` flag and both still override.

Two devices read `CKTnomTemp` **directly**, with no card parameter of their own
(`hfet1/hfettemp.c:71-73`, `mesa/mesatemp.c:60-61,97,112`). Our `.va` for those
exposes `tnom` as a card parameter as well, which is a superset — the option
still lands, and a card can additionally override it.

Semantics restated, which is what the implementation had to hit:

> `.options tnom` is a **model-card default**, in °C, defaulting to 27, applied
> once at setup, independent of the operating temperature, and overridden by any
> per-card `TNOM`/`TREF`.

Note what it is *not*: it is not an analysis knob. Nothing in a run moves it.

---

## 2. Where the value enters, and how it reaches parameter derivation

The models could not read it — a Verilog-A `parameter` default is the module's
own text, and `$temperature` is the *operating* temperature — so the host has to
supply it. The split is:

```
.options tnom=50                                  (deck)
  └─ engine.zig parseDeckOptions → DeckOptions.tnom_c        [°C, default 27]
       └─ Builder.nom_temp_c                                  (one f64 per RUN)
            └─ builder.deriveModel(D, &model, b.nom_temp_c)
                 ├─ model.nom_temp__ = nom_temp_c             (VerA's reserved field)
                 └─ D.derive(model)  ──▶  if (!model.tnom__given)
                                              model.tnom = model.nom_temp__;
                      └─ D.precompute / D.collapse read model.tnom
```

### 2.1 VerA side (`options-tnom-vera`, commit `9ff8c93`)

`Lower.simparamHostField` is the new table: a §9.15 name whose value belongs to
the host maps to a reserved `Model` field. One row today — `tnom` →
`nom_temp__`. Three renderers consult it:

| Renderer | Position | Emits |
|---|---|---|
| `codegen.emitSysCall` | a read in the module body | `S.con(model.nom_temp__)` |
| `codegen.f64Const` | a §3.4 parameter default over it | `model.nom_temp__`, which `emitDerive` then wraps in its `__given` guard |
| `Analysis.foldConst` | the field initializer only (`resolve_params`) | Table 9-27's declared `27.0` |

That third row is the one that keeps the default from moving. `foldConst`
already had the rule — "*only a Model DEFAULT may look through a parameter:
everywhere else the value is whatever the host overrode it with*" — and a host
simparam now follows it, so `resolve_params` cleanly separates the two jobs:

- **field initializer** (`paramDefault`, `resolve_params = true`) → `27.0`, so
  `Model{}` is byte-for-byte what it was;
- **derive assignment** (`emitDerive`, `resolve_params = false`) → does not
  fold, so the line is emitted and reads the host's field.

Generated `mos1.device.zig`, before → after:

```zig
// before
tnom: f64 = 27.0,
// (no derive line)

// after
tnom: f64 = 27.0,
tnom__given: bool = false,          // §9.19 $param_given
nom_temp__: f64 = 27.0,             // §9.15 $simparam("tnom"), degC — host-written
...
pub fn derive(model: *Model) void {
    if (!model.tnom__given) model.tnom = model.nom_temp__;
}
```

`tnom__given` needed no new machinery: `p_given[i]` is already raised for every
non-local parameter whose default does not fold (`codegen.zig:1326-1329`), which
a `$simparam` default now is by construction.

**Model, not Instance.** `.options tnom` is one number per run. The generated
`Instance` already carries `temperature`/`abstime`/`dt`/`mfactor`/
`analysis_kind` and the step-phase flags — about 64 B of simulation globals
replicated per instance, which the memory audit flagged. Putting `tnom` there
would have added a seventh copy of a global across every instance of every
batch, for a value read exactly once per model card at build. `Model` is
per-card: tens of copies, not tens of thousands.

The `__` suffix cannot collide with a user identifier: `naming.sanitize`
escapes a trailing `_` and a `__` run to `Z5f`, so no Verilog-A name reaches a
field of that shape. Same rule that makes `<p>__given` unambiguous.

### 2.2 Model sources (23 files)

The `.va` files now name the channel instead of a literal. One token each:

```verilog
-parameter real tnom = 27.0;                   // degC
+parameter real tnom = $simparam("tnom");
```

and, for the five that want kelvin, the conversion is written where the unit is
known rather than guessed by the host:

```verilog
-parameter real tnom = 300.15 from (0:inf);     // K
+parameter real tnom = $simparam("tnom") + 273.15 from (0:inf);
```

- °C, `tnom`: `diode`, `mos1`, `mos2`, `mos3`, `mos9`, `jfet`, `jfet2`,
  `bsim3`, `vdmos`, `hicumL2_va`, `vbic13_4t` (+ its `` `ALIAS(tref,tnom) ``)
- °C, `TNOM`: `bsimsoi_va`, `hisim2_va`, `hisimhv_va`
- K, `tnom`: `bjt`, `hfet1`, `hfet2`, `mesa`, `mos6`
- `bsim4va`: the parameter default is left alone; the `` `DEFAULT_TNOM ``
  literal inside its `$param_given(tnom)` arm becomes `$simparam("tnom")`,
  which is `b4set.c:1950` transcribed. The `` `define DEFAULT_TNOM `` is gone.
- no nominal temperature at all, untouched: `mes`, `bsource`, `bsim2`, and the
  passive/source/line models.

`27.0 + 273.15` folds to the same f64 as the literal `300.15` (VerA's
round-trip formatter prints the folded constant back as `300.15`), so the five
kelvin models keep their exact field initializers. That is asserted in VerA's
own test, not assumed.

### 2.3 Host side (`options-tnom`)

- `engine.zig`: `DeckOptions.tnom_c: f64 = 27.0`, filled by `parseDeckOptions`
  from `.options tnom`. `parseDeckOptions` moved to the top of `fromNetlist`
  (it is a pure function of `nl.directives`; it was already being called there,
  just later).
- `builder.zig`: `Builder.nom_temp_c`, and `deriveModel` writes
  `model.nom_temp__` immediately before `D.derive`.
- `devices/engine.zig`: `paramField` skips any field whose name ends in `__`.
  Without this, `nom_temp__` would have joined `collectParams` as if it were a
  §3.4 parameter, and `.mc`/`.sens`/`.dcmatch` would perturb a simulation
  global — and, worse for this change, silently renumber every existing draw.

**Why build time and not a runtime hook.** The task sketch anticipated a
`setCircuitTemp`-shaped setter plus `recompute`/`reprep`, with the
`TopologyChanged` error path that `tests/builder.zig` "DC outer temperature
topology error" and `dc.zig`'s first-point full `recompute` walk exist for.
That path is not needed here, and adding it would have been the wrong shape:
`tnom` is a deck constant, not a swept quantity. Writing it before `nb.build()`
means every model is derived from its final value as it is created, so
`precompute` and `collapse` see the right answer the first time and there is no
re-derivation to get wrong. The `collapse` topology hazard is real for
`temperature` precisely because `temperature` moves during a run; `tnom` never
does.

---

## 3. Override precedence

SPICE order, unchanged and now actually exercised:

1. device card `TNOM=` / `TREF=` — `applyKv(&model, dev.kv)`
2. `.model` card `TNOM=` / `TREF=` — `applyKv(&model, m.kv)`
3. `.options tnom` — `deriveModel` → `if (!model.tnom__given)`
4. Table 9-27's 27 °C — the field initializer, if the host writes nothing

Both card spellings raise `tnom__given` (`markGiven` in `engine.zig`, via the
`tnom`→`tref` alias at `builder.zig:480`), so 1 and 2 short-circuit 3 the same
way `BSIM4tnomGiven` short-circuits `CKTnomTemp`. Verified in §4.2 below: with
`.options tnom=50` in force, the diode carrying `tnom=27` on its card answers
1.0800e-2 A — the 27 °C number — while its otherwise-identical twin with no
card `TNOM` answers 4.0802e-4 A.

---

## 4. Evidence

Binaries: `/tmp/espice-base` = branch point `888d4d8` built against VerA
`020c159`; `/tmp/espice-new` = this branch built against VerA `9ff8c93`.
ngspice is the pinned nixpkgs 44.2 on `PATH`.

### 4.1 Bit-identity at the default — the gate

Every deck in the corpus omits `.options tnom`, so nothing may move. This
change touches the parameter derivation of 20 of the 38 generated devices, so
"nothing may move" is checked by raw-file comparison, not by tolerance.

```
$ find benchmark/fixtures -name circuit.sp | wc -l
286
$ for f in <all 286>; do espice -b -r $OUT/<key>.raw $f; done   # base, then new
$ ls /tmp/raws-base | wc -l ; ls /tmp/raws-new | wc -l
256
256
$ diff -rq /tmp/raws-base /tmp/raws-new ; echo $?
0
```

**256/256 raw files byte-identical**, same file set on both sides. (The 30
decks that produce no raw fail identically on both binaries — unsupported
cards; `diff -rq` reports no `Only in` either way.)

This is structural, not lucky: the generated field initializer for every
nominal-temperature parameter is unchanged (`tnom: f64 = 27.0`, and `300.15`
for the five kelvin models), the new `nom_temp__` field initializes to 27.0,
and `derive()` assigns that same 27.0 when the host writes nothing.

### 4.2 The new fixture — `benchmark/fixtures/regression/options_tnom`

`.options tnom=50` with `.temp 100`, an `.op` over a diode, a MOSFET and a BJT
that give no card `TNOM`, plus a second diode that gives `TNOM=27` to pin the
override. Against ngspice 44.2 on the same deck:

| signal | ngspice | before | after | err before | err after |
|---|---|---|---|---|---|
| `i(vd1)` diode, no card TNOM | -4.08022507e-04 | -1.07998102e-02 | -4.08019183e-04 | **2546.9%** | 0.00% |
| `i(vce)` BJT | -9.38503260e-05 | -2.48408994e-03 | -9.38494624e-05 | **2546.9%** | 0.00% |
| `i(vbe)` BJT | -1.85702608e-06 | -3.25805206e-05 | -1.85701188e-06 | **1654.5%** | 0.00% |
| `i(vdd)` MOS1 | -3.41414385e-04 | -3.29367162e-04 | -3.41414387e-04 | **3.53%** | 0.00% |
| `i(vd2)` diode, card `TNOM=27` | -1.07999094e-02 | -1.07998102e-02 | -1.07998102e-02 | 0.00% | 0.00% |

Read the last two rows together: before the fix, `i(vd1)` and `i(vd2)` were the
*same current*, because the option did nothing and both diodes ran at 27 °C
nominal. After, `i(vd1)` moved to ngspice's answer and `i(vd2)` did not move at
all — the card override still wins, and it wins by the same mechanism it always
did.

```
$ python3 benchmark/check_fixtures.py --engine /tmp/espice-base --category regression --reference
PASS regression/bsim4_tnoimod1: reference
FAIL regression/options_tnom: i(vce), sample 0: -0.002484089938593943 != -9.385032599537363e-05 (atol=1e-12, rtol=0.001)
1/2 passed; 0 unsupported

$ python3 benchmark/check_fixtures.py --engine /tmp/espice-new --category regression --reference
PASS regression/bsim4_tnoimod1: reference
PASS regression/options_tnom: reference
2/2 passed; 0 unsupported
```

The fixture needs `ngspice` on `PATH`, so the same three-way claim is also a
`zig build test` case — `tests/devices.zig`, "`.options tnom` reaches the model
card default, and a card TNOM still wins" — carrying the ngspice numbers above
as literals and exercising `nom_temp__` → `derive` → `precompute` → `eval`
directly.

### 4.3 Test counts

| | before | after |
|---|---|---|
| ESPice `zig build test` | 412/412 | **413/413** (one added) |
| VerA `zig build test` | 279/280 | **281/282** (two added) |

Both "before" figures were measured, not quoted: the working tree was reverted
to the branch point in place (`git checkout -- .` / `checkout HEAD~1 -- .`,
never `git stash` — AGENTS.md) and rebuilt. ESPice's branch point is 412/412,
not the 407/407 of an earlier measurement; five tests have been added to it
since, none of them here.

VerA's single failure, `codegen: §5.6.5 a zero-short switch branch emits a
collapse hook`, pre-dates this branch: measured at 279/280 with the working
tree reverted to `020c159`, same test, same assertion.

### 4.4 Cost

None to measure. The value is one `f64` store per model card at build time —
`grep -c '\.model' ` on the largest corpus deck gives tens, against the tens of
thousands of instances that pay nothing. No field was added to `Instance`, no
hook to the per-solve or per-Newton sweep, and no analysis calls `recompute`
for this. The 256-raw byte-identity above is also the statement that the eval
path did not change.

---

## 5. Ceilings

- `simparamHostField` has one row. A second host-published §9.15 name (`gmin`
  is the obvious candidate — the host steps it, and VerA answers a constant
  1e-12 today) is a one-line table edit plus a second `Model` field; the three
  renderers already key off the table. Not done: nothing asked.
- The internal diode lumps `lossy_tline` synthesises (`builder.zig:1096`) build
  a `Diode.Model` by direct field write and never call `derive`, so they keep
  the 27 °C initializer regardless of the option. Unchanged behaviour, and
  calling `derive` there would re-derive fields the lump generator set by hand.
  Fix when a lossy line's diode clamps have to track nominal — the deck would
  have to set `.options tnom` *and* use `ltra` with `dnorm`.
- `hfet1`/`mesa` gained a card-overridable `tnom` that ngspice does not offer
  (it reads `CKTnomTemp` inline there). Superset, not a divergence.

## 6. Commits

- ESPice `options-tnom` (this commit) — this document, the 23 `.va` sources, the three host
  files and the two tests.
- VerA `options-tnom-vera` `9ff8c93` — `simparam: $simparam("tnom") is the
  HOST's nominal temperature, not a folded 27`.
