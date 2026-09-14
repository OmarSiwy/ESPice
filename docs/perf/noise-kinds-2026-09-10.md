# The PSD is the model's, not the Jacobian's — shot and flicker end to end

2026-09-10, branches ARPice `noise-kinds` / VerA `noise-kinds-vera`.
Scope: `docs/devices/noise-contract.md` §2(a) and §3 — the `noisePsd` hook,
whose declaration surface landed 2026-07-12 and whose implementation never did.

**Result: `noise/amp_noise` goes from +19.46% against ngspice to 1.72e-6,
inside the 1.74e-7 CODATA floor's exponential lever. A shot-dominated deck reads
a base/new power ratio of 1.999481 — the predicted `2/N`. Flicker goes from
100% absent to 1.27e-7. 254 of 256 fixture raws byte-identical; the two that
moved are both `.noise` decks. 407/407 `zig build test`, VerA 280/281 (one
pre-existing failure, identical at the branch point).**

---

## 1. The defect, in one sentence

`collectNoise` read a conductance off the analytic Jacobian and called the
answer `4kT·g`, and the two kinds that are not that — shot and flicker — were
`.shot, .flicker => {}`, dropped on the floor. VerA never emitted the PSD at
all: `codegen.zig emitNoiseTable` exported the branch and a tag and discarded
the call's argument.

Both halves were wrong for the same reason. **In Verilog-A §4.6.4.1 the PSD IS
the argument.** `white_noise(pwr)` states `S(f) = pwr` outright, so
`white_noise(2·q·|I|)` is shot noise and `white_noise(4·k·T/R)` is thermal —
the same call, different arguments, and nothing in the call distinguishes them.
A tag cannot carry a PSD, and a Jacobian cannot reconstruct one.

## 2. What each kind actually is, from ngspice 44.2

Source at `/tmp/ngsrc/ngspice-44.2`. Every line number below was read there.

### The transport boundary collapses the kinds immediately

`src/spicelib/analysis/nevalsrc.c` — `NevalSrc` computes the adjoint gain once
and then switches:

| line | case | body |
|---|---|---|
| `nevalsrc.c:100-102` | — | `gain = (Vadj_p − Vadj_n)²`, real² + imag² |
| `nevalsrc.c:105-108` | `SHOTNOISE` | `*noise = gain * 2 * CHARGE * fabs(param)` — "param is the dc current in a semiconductor" |
| `nevalsrc.c:110-113` | `THERMNOISE` | `*noise = gain * 4 * CONSTboltz * ckt->CKTtemp * param` — "param is the conductance of a resistor" |
| `nevalsrc.c:115-117` | `N_GAIN` | `*noise = gain` — the bare `|H|²`, for a device that will apply its own 1/f coefficient |

Two things follow. First, **SHOTNOISE and THERMNOISE land in the same `*noise`
and are indistinguishable one instruction later** — ngspice transports a
density, not a kind, exactly as this branch now does. Second, the THERMNOISE
`param` is not even always a conductance: `mos1noi.c:140-142` passes the
channel's `Sid`, which is `2/3·β·vgst·(1+α+α²)/(1+α)·gdsnoi` (`mos1noi.c:133`, the `nlev ≥ 1` branch),
not a `dI/dV` anywhere in the Jacobian. "Read the conductance off the Jacobian"
was never the reference behaviour even for thermal.

### Thermal — `S = 4kT·g`

`resnoise.c:97-99` (`RESconduct`), `dionoise.c:90-92` (RS), `bjtnoise.c:93-103` (rc/rb/re),
`mos1noi.c:106-111` (rd/rs). `g` is whatever conductance the device names; for
a plain series resistance it *is* the Jacobian entry, which is why
`noise/rc_noise` and `noise/resistor_noise` came out **byte-identical** before
and after this change. That coincidence is the whole reason the old path looked
right.

### Shot — `S = 2q|I|`

`dionoise.c:94-96` (junction current), `bjtnoise.c:105-111` (Ic and Ib),
`vbicnoise.c:130-151` (Itzf/Ibe/Ibep/Iccp). `I` is a **current**, and for a
junction the Jacobian entry on that same branch is `g = dI/dV = I/(N·Vt)`, so

```
4kT·g = 4kT·I/(N·Vt) = 4kT·I·q/(N·k·T) = (2/N) · 2q·I
```

— exactly 2x too much power at `N = 1`. Measured below.

### Flicker — `S = KF·|I|^AF / f^EF`, and it is frequency-dependent

`dionoise.c:99-104` and `bjtnoise.c:112-118` are `KF·|I/M|^AF / freq` at
`EF = 1`. `mos1noi.c:175-181` (`nlev` 2 and 3) is the one ngspice branch where
the frequency exponent is a model parameter: `pow(data->freq, MOS1fNexp)`.
BSIM4 (`bsim4va.va:9712`) and BSIMSOI (`bsimsoi_va.va:7978`) pass their own `ef`
through the Verilog-A call.

Every one of these is an `N_GAIN` call followed by the device's own multiply —
ngspice's own split between "the analysis owns `|H|²`" and "the device owns the
density", including the frequency axis. **A `4kT·g` derivation structurally
cannot express `1/f^EF`: there is no frequency in a Jacobian.** That is why
`PsdTerm` is `white + flicker/f^ef` and not a single number.

### The band integral

`ninteg.c:27-45` — a per-interval power-law fit of one source's log-log
spectrum (rectangle rule when the slope is flat, logarithmic when it is near
−1), taken **per source** (`resnoise.c:141-150`, "In order to get the best curve fit, we have to integrate each component separately"), not a trapezoid of the total.
This was already implemented correctly (`ac/noise.zig nintegrate`) and is
unchanged; it matters here only because a source that is now `1/f` instead of
flat takes the third branch of that fit, and the integrated-noise column moved
accordingly on `bjt_flicker`.

### The accepted floor

`include/ngspice/const.h:37` still defines `CONSTboltz 1.38064852e-23` (CODATA
2014); every `.va` in `src/devices/models` writes `1.380649e-23` (CODATA 2018).
`sqrt(1.380649/1.38064852) − 1 = 1.74e-7`, which is the exact residual on every
pure-thermal deck below. `CHARGE` differs likewise (`const.h:32`, `1.6021766208e-19`), and the *ratio* `k/q` enters `Vt`, so on a deck biased at
`Vbe/Vt ≈ 25` the floor is levered by that exponent — see §6.

## 3. What VerA changed

`src/ir/lower.zig`

- `NoiseSrc` grows `pwr`/`exp`: the §4.6.4.1/.2 arguments **as MIR values**.
  `kind` stays, demoted to what it always was — which of the two calls this row
  came from.
- `lowerNoise` records `(pwr, exp)` into a new `noise_psd` map keyed by
  `Ast.ExprId`. It has to be recorded there: `lowerNoise` is the only place the
  arguments are lowered, and `noiseSrcsOf` walks the AST afterwards, where the
  MIR values are no longer reachable from the id.

`src/backend/codegen.zig`

- `planNoise` builds `noise_rows` once — one row is simultaneously a
  `noise_gens` entry and a `noisePsd` return position, so the two tables cannot
  drift apart. It replaces the open-coded loop that used to live inside
  `emitNoiseTable`.
- `emitNoiseTable` now emits `pub fn noisePsd(x, model, inst) [k]PsdTerm`
  beside `noise_gens`: one value-only `core(R, …)` sweep at the caller's state
  vector, `updateState`'s shape exactly. `rscalar_txt` (the plain-`f64` `R`
  scalar) is opened for `noise_rows.len != 0` for the same reason `$limit` and
  `collapse` open it.
- `buildJobs` queues a `$noise` job per PSD argument so the value becomes a
  core live-out.
- **`planPrecompute` refuses `$noise` targets.** This is the load-bearing line,
  and the one the inherited WIP did not have — §4.

Contract surface unchanged: `PsdTerm` and the `noisePsd` validation were
already in `tools/contract.zig:524-530` (`PsdTerm`) and `:909-912`
(validation), already allowlisted at `:1112-1113`. Its "devices without it keep
the thermal-off-the-Jacobian fallback" comment is corrected in the same commit:
there is no fallback any more.

## 4. The bug in the inherited WIP: a guarded generator is not a hoistable value

The WIP's own comment claimed a generator whose statement did not execute
"reads back the zero `probeBody` seeds a conditional live-out with". That is
true of a core live-out and false of a precompute field, and the PSD was
becoming a precompute field.

Every series resistance in the tree writes this shape:

```verilog
if (rc_t > 0.0) begin
    I(c, ci) <+ V(c, ci) / rc_t;
    I(c, ci) <+ white_noise(fourkt / rc_t, "rc");
end else begin
    V(c, ci) <+ 0.0;            // collapses c onto ci
end
```

`4kT/rc_t` depends only on model parameters, so `planPrecompute` classified it
hoistable, and the `$noise` job marked it a root. The generated BJT read

```zig
inst.pc__98 = t116.val();     // t116 = t114 / t35  ==  fourkt / rc_t
...
.f37 = S.con(inst.pc__98),    // unconditional
```

With `rc = 0` (the default, and what `noise/amp_noise`'s card gives) that is
`4kT/0 = +inf`. The `else` branch has collapsed `c` onto `ci`, so the adjoint
gain on that branch is exactly 0, and `0 · inf = NaN` — the entire
`amp_noise` spectrum came out `nan`. **The WIP would have shipped a NaN on the
headline fixture.**

The fix is one `continue` in `planPrecompute`. A core live-out is seeded
`h[k] = S.con(0.0)` at function entry and assigned only inside the block that
declared it, which is both the right *value* and the right *semantics*: a
generator this bias does not have has zero power. After the change the same
device reads

```zig
h[39] = S.con(0.0);                                  // entry seed
...
    h[39] = S.con((inst.pc__96) / (inst.pc__17));    // inside `if (rc_t > 0)`
```

The exponent keeps the inline-constant shortcut, because it is only ever read on
a row whose power is non-zero — i.e. one that executed.

This is not just an infinity. `vbic13_4t.va:1716-1730` guards fifteen
generators on `if (sw_noise)`, and `hisim2_va.va:10218` guards two on
`if (flg_rs)`; hoisting those would have reported noise from a device with its
noise switched off. The guard has to be honoured, not the divide-by-zero
patched.

Cost of un-hoisting: none measurable. `inverter_chain_4k` 93.72 s → 91.70 s,
`parallel_inverters_2000` 0.78 s → 0.73 s (best of 3 each); 254/256 fixture raws
byte-identical, which is the real proof that `eval` never computes these
live-outs — LLVM DCEs the unread struct fields after inlining `core`.

## 5. What the host changed

`src/devices/engine.zig`

- `NoiseSource` is `{node_p, node_n, white, flicker, ef}` — a **density**, in
  the contributed nature's units² per Hz. `kind`/`conductance`/`current`/`kf`/
  `af` are gone; they were an attempt to re-derive on the analysis side what the
  device already knew.
- `collectNoise` calls `D.noisePsd(x_local, model, instance)` and copies term
  `k` onto generator `k`. `@abs` on both halves is ngspice's own read of a
  signed density argument (`nevalsrc.c:106` `fabs(param)`).
- The Jacobian fallback is **deleted**, not kept as a legacy path. A device that
  declares `noise_gens` without `noisePsd` is now a `@compileError`. Keeping the
  fallback would have kept the 2x alive for any device that forgot the hook, and
  its only user was `tests/testdev.zig`, which now declares its own three-line
  `noisePsd`. Deleting it also removed the last use of the `Dual` scalar inside
  `DeviceBatch`.

`src/analysis/ac/noise.zig` — `sourcePsd(src, f) = white + flicker/f^ef`.
`src/analysis/pss/pnoise.zig` — the per-PSS-sample arrays become
`src_white`/`src_flicker`, so cyclostationary modulation now tracks the whole
density along the orbit instead of a conductance and a current that were never
populated. `src/analysis/tran/tran_noise.zig` — `sigma = sqrt(white·BW)`.

`temp_k` is gone from all three `Options` structs and from
`engine.zig applyDeckOptions`. It was dead the moment the device owned the
density: `.temp` already reaches instances through `setCircuitTemp`
(`engine.zig:396`), and ngspice only multiplies by `CKTtemp` in `NevalSrc`
because *its* devices hand over a bare conductance. Leaving the field would have
been two sources of truth for temperature.

## 6. Numbers

### Every `.noise` fixture against ngspice 44.2

Max relative deviation over the sweep, per plot column. `before` is ARPice at
the branch point (`888d4d8`), `after` is this branch; both against a live
`ngspice -b` run of the same deck.

| fixture | column | before | after |
|---|---|---:|---:|
| `noise/amp_noise` | `onoise_spectrum` | **1.9460e-01** | **1.7248e-06** |
| `noise/amp_noise` | `inoise_spectrum` | 1.9461e-01 | 7.1492e-06 |
| `noise/amp_noise` | `v(onoise_total)` | 1.9460e-01 | 1.7248e-06 |
| `noise/amp_noise` | `v(inoise_total)` | 1.9461e-01 | 7.1492e-06 |
| `noise/bjt_flicker` (new) | `onoise_spectrum` | 9.9818e-01 | 1.2660e-07 |
| `noise/bjt_flicker` (new) | `inoise_spectrum` | 9.9818e-01 | 1.1019e-07 |
| `noise/bjt_flicker` (new) | `v(onoise_total)` | 8.3204e-01 | 1.2638e-07 |
| `noise/bjt_flicker` (new) | `v(inoise_total)` | 8.3204e-01 | 1.0996e-07 |
| `noise/rc_noise` | all four | 1.7383e-07 | 1.7383e-07 |
| `noise/resistor_noise` | all four | 1.7383e-07 | 1.7383e-07 |

`1.7383e-07` is the `CONSTboltz` floor of §2, to five digits. The two
pure-thermal decks are byte-identical before and after — the device's own
`4kT/r` and the Jacobian's `4kT·g` are the same number for a linear resistor,
which is exactly why a thermal-only test suite could never have caught this.

The gate itself, no tolerance touched:

```
$ python3 benchmark/check_fixtures.py --category noise --reference
  before: FAIL noise/amp_noise: onoise_spectrum, sample 0:
          1.3930542346474888e-08 != 1.1661230992674485e-08 (atol=1e-30, rtol=0.001)
          2/3 passed
  after:  4/4 passed; 0 unsupported
```

### The 2x, isolated

`/tmp/nk/pureshot.sp` — a diode fed from 100 V through 100 MΩ, so the bias
resistor's own `4kT/R` is `2·Vt/V = 5.2e-4` of the junction's `2q·Id` and the
onoise is the shot generator to within 0.03%:

| | onoise @1 kHz |
|---|---|
| before | 2.07527760e-08 |
| after | 1.46763346e-08 |
| ngspice | 1.46763331e-08 |

```
before/after POWER ratio = 1.999481      predicted 2/N = 2 (N = 1), less the
                                         5.2e-4 resistor admixture
after vs ngspice          = 1.052e-07    below the 1.74e-7 thermal floor
before vs ngspice         = 4.140e-01
```

### Flicker, isolated

`noise/bjt_flicker` — base driven through 100 kΩ so the b–e generator has
gain, `KF=2e-12 AF=1`, so the sweep crosses the 1/f corner:

| f | before | after | ngspice |
|---|---|---|---|
| 10 Hz | 1.949463e-06 | 1.073929e-03 | 1.073929e-03 |
| 1 kHz | 1.949463e-06 | 1.074019e-04 | 1.074019e-04 |
| 1 MHz | 1.949463e-06 | 3.670551e-06 | 3.670552e-06 |

Before is **flat** — the generator existed in `noise_gens` and contributed
nothing. A `KF=1e-8` variant of the same deck measured a per-decade amplitude
ratio of 3.1622776554 against ngspice's 3.1622776554, i.e. `1/f` in power to
eleven digits.

### Whole-corpus regression

`benchmark/capture_raws.sh` over all 256 fixture decks, branch point vs this
branch: **exit codes identical, 254 raws byte-identical, 2 differ** —
`noise/amp_noise` and `devices/vbic_noise_scale`. Both are `.noise`. Category
pass counts unchanged: `golden` 21/24 both (the two pre-existing failures are
`golden/noise`'s plot-name mismatch and `golden/qpss`'s non-convergence),
`devices` 103/111 both.

### Which models moved

All 18 models that declare a generator now state their own PSD. Broken down by
what the generator writes:

| model | gens | shot `2q\|I\|` | flicker | thermal |
|---|---:|---:|---:|---:|
| `bjt` | 6 | 2 | 1 | 3 |
| `bsim1` | 4 | 0 | 1 | 3 |
| `bsim2` | 4 | 0 | 1 | 3 |
| `bsim4va` | 16 | 5 | 1 | 10 |
| `bsimsoi_va` | 18 | 5 | 1 | 12 |
| `diode` | 2 | 1 | 0 | 1 |
| `hicumL2_va` | 17 | 9 | 3 | 5 |
| `hisim2_va` | 8 | 3 | 1 | 4 |
| `hisimhv_va` | 8 | 3 | 1 | 4 |
| `jfet` | 4 | 0 | 1 | 3 |
| `jfet2` | 4 | 0 | 1 | 3 |
| `mes` | 4 | 0 | 1 | 3 |
| `mos2` | 4 | 0 | 1 | 3 |
| `mos3` | 4 | 0 | 1 | 3 |
| `mos6` | 4 | 0 | 1 | 3 |
| `mos9` | 4 | 0 | 1 | 3 |
| `resistor` | 1 | 0 | 0 | 1 |
| `vbic13_4t` | 15 | 5 | 3 | 7 |
| **total** | **127** | **33** | **20** | **74** |

**8 models / 33 generators** wrote `white_noise(2q|I|)` and read 2x too much
power. **16 models / 20 generators** wrote `flicker_noise` and contributed
nothing at all. The brief's "16 models write `white_noise(2q|I|)`" conflated the
two counts: 16 is the flicker model count, 8 is the shot model count. The 74
thermal generators are unchanged in value wherever the branch is a plain
conductance and corrected wherever it is not (`mos1`-style channel `Sid`,
`vbic`'s `qb·Gbi`).

### The one fixture that is still off

`devices/vbic_noise_scale` improved from **61.8% to 17.0%** on the spectrum, and
its integrated totals moved 2.70% → 4.78% and 5.71% → 8.31%. That residual is a
**model** divergence, not a transport one, and is out of scope here:

- `vbicnoise.c:122-124` hangs VBIC's `rbp` thermal generator on
  `(emitEINode, emitNode)` — the same node pair as `rbp`'s neighbour two calls
  up. `vbic13_4t.va:1728` puts it on `b_rbp`, which is where VBIC 1.3 says it
  goes.
- `vbicnoise.c:107-108` scales the rci generator by the raw conductance
  `irci_Vrci`; `vbic13_4t.va:1724` uses VBIC's own
  `(|Irci| + 1e-10·Gci)/(…)` form.
- ngspice applies no `sw_noise` gate at all; the `.va` gates all fifteen
  generators on it.

The fixture is smoke-graded (`devices` category), not reference-graded, and its
pass count did not change.

## 7. What the engine still cannot express

- **Correlation.** `contract.PsdTerm` carries `corr_with`/`corr`, and
  `collectNoise` drops them: `NoiseSource` has no partner field, so every
  generator is transported as independent. BSIM4 `tnoiMod ≥ 1`, PSP103's
  `c_igid`, and HICUM/L2 §2.13.3 B–C correlation all need the pair.
  `bsimsoi_va.va:7876-7878` already writes the `ctnoi` split that wants it.
  (`docs/devices/noise-contract.md` §2(c).)
- **`noise_table` / `noise_table_log`** (§4.6.4.3/.4) — piecewise
  PSD-vs-frequency, which `white + flicker/f^ef` cannot state. `emitNoiseTable`
  omits them from `noise_gens` rather than mis-stating them; no model in the
  tree uses them.
- **A generator on a ground–ground branch** (§1.3.1.1) has no row or column to
  name and is skipped.
- **Transient noise samples only the white half.** A per-step iid draw cannot
  produce a `1/f` shape; sampling the flicker coefficient as if it were white
  would put the whole 1/f power at every frequency, which is worse than omitting
  it. Marked `ponytail:` in `tran_noise.zig` with the shaping-filter upgrade
  path. `.noise` and `.pnoise` carry the full PSD.
- **`.noise` with a current source as the input** returns
  `AnalysisSourceNotFound` — `Options.in_branch` is an MNA branch row, and an
  independent current source has none. ngspice accepts it. Unrelated to this
  branch, found while building the isolated shot deck.

## 8. Test accounting

`zig build test` **407/407** on this branch; **412/412** at the branch point
(`888d4d8`). The five removed tests are all PSD-kind assertions that moved to
the device side:

- `ac/noise.zig` 6 → 5: the four `sourcePsd thermal/shot/flicker/flicker af
  exponent` plus `defaults backward compatible` became four that test what the
  function now owns — the `white + flicker/f^ef` shape, including the 2x
  identity as an explicit assertion.
- `pss/pnoise.zig` 7 → 3: same collapse. `kf`/`af`/`kind` are no longer this
  file's arguments; what survives is the sideband frequency axis and the
  near-DC clamp.

One test added on the VerA side — `codegen: §4.6.4 noisePsd is the model's own
PSD, and a guarded one reads zero` — which pins exactly the §4 bug: it compiles
a module with a `if (rs > 0)`-guarded `white_noise(1.6e-23/rs)` and asserts the
power comes back as `m.fN` whose declaration is `h[…]` (a seeded live-out) and
never `inst.pc__…` (a precompute field).

VerA: 280/281. The one failure,
`codegen: §5.6.5 a zero-short switch branch emits a collapse hook`, is
pre-existing and reproduces byte-for-byte at the branch point `020c159` in a
clean worktree.

## Sources

- ngspice 44.2, `/tmp/ngsrc/ngspice-44.2`: `src/spicelib/analysis/nevalsrc.c`,
  `ninteg.c`, `noisean.c`, `cktnoise.c`; `src/spicelib/devices/dio/dionoise.c`,
  `bjt/bjtnoise.c`, `mos1/mos1noi.c`, `res/resnoise.c`, `vbic/vbicnoise.c`;
  `src/include/ngspice/const.h`.
- In-tree: `docs/devices/noise-contract.md` (§2 gaps, §3 hook design),
  `../VerA/tools/contract.zig:485-531` (`NoiseGen`, `PsdTerm`), `:909-912`
  (validation).

## Cross-links

- VerA branch `noise-kinds-vera`, the single commit `noise: emit noisePsd` —
  `src/ir/lower.zig`, `src/backend/codegen.zig`, `tools/contract.zig`. Its
  message carries this commit's hash.
- ARPice branch `noise-kinds`, the single commit on top of `888d4d8`.
- Analysis-side docs: [../analysis/ac-small-signal-noise.md](../analysis/ac-small-signal-noise.md),
  [../analysis/periodic-noise.md](../analysis/periodic-noise.md),
  [../analysis/transient-noise.md](../analysis/transient-noise.md).
