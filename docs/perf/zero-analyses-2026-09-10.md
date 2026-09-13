# The two analyses that returned zero — `.noise` and `.disto`, 2026-09-13

`docs/perf/na-audit-2026-09-10.md` §B2 named nine fixtures — four `.disto` and
five `.noise` — whose espice output was zero (seven of them *identically* zero
at every point, the other two missing their dominant term) and which the
benchmark comparator scored `N/A`, so the zero read as a pass in every summary
anyone wrote. This is the fix, with ngspice 44.2 as the normative reference.

Source tree cited throughout: `/tmp/ngsrc/ngspice-44.2` (the packaged build in
the nix store has no sources; `/home/omare/.../ngspice-44.2-fromsource` is an
install prefix, not a source tree).

Fixtures: `golden/noise`, `noise/rc_noise`, `noise/resistor_noise`,
`noise/amp_noise`, `devices/vbic_noise_scale`, `golden/disto`,
`disto/bjt_ce`, `disto/diode_clipper`, `disto/mos_cs`.

## 1. `.noise` — what ngspice actually does

### 1.1 The generators

A resistor's only noise source is `4kT·G` across its own two terminals:

```c
/* resnoise.c:97-99 */
NevalSrcInstanceTemp(&noizDens[RESTHNOIZ], &lnNdens[RESTHNOIZ],
    ckt, THERMNOISE, inst->RESposNode, inst->RESnegNode,
    inst->RESconduct, dtemp);
```

and `NevalSrc*` turns `THERMNOISE` into `gain * 4·k·(T+dtemp)·param`, with
`gain = |V_adj(n1) − V_adj(n2)|²` off the adjoint solution
(`nevalsrc.c:100-102`, `:336-339`). `param` is the conductance; `dtemp` is the
instance `temp`/`dtemp` offset, zero for every fixture here. ngspice's second
resistor generator is flicker, `KF·|I|^AF / (area·f^EF)` (`resnoise.c:101-112`),
and `KF` defaults to 0 (`ressetup.c:38`), so a plain `R` card has thermal
only. A `noisy=0` resistor is skipped entirely (`resnoise.c:57`; `noisy`
itself defaults to 1 at `ressetup.c:55`).

The diode has three (`dionoise.c:90-104`): RS thermal
`4kT·DIOtConductance` across `(posPrime, pos)`, junction shot `2q|Id|` across
`(posPrime, neg)`, and flicker on the same branch. ngspice's constants are
`CONSTboltz 1.38064852e-23` and `CHARGE 1.6021766208e-19` (`const.h:32,37`) —
CODATA 2014; espice uses the 2018 exact values. That difference is the entire
residual on the resistor fixtures below (`√(1.380649/1.38064852) − 1 =
1.74e-7`).

### 1.2 The plots, and the units

`noisean.c` writes **two** plots per `.noise` card:

| plot | scale | columns | points | site |
|---|---|---|---:|---|
| `Noise Spectral Density Curves` | `frequency` | `onoise_spectrum`, `inoise_spectrum` | one per sweep point | `noisean.c:318-325` + `cktnoise.c:56-64` |
| `Integrated Noise` | *none* | `v(onoise_total)`, `v(inoise_total)` | 1 | `noisean.c:516-522` + `cktnoise.c:76-82` |

The second is emitted only when `job->NstartFreq != job->NstopFreq`
(`noisean.c:495`). The `v(...)` spelling on the totals is literal — they are
declared `SV_VOLTAGE` (`noisean.c:507-508`) and the raw writer decorates a
voltage; the density columns are `SV_VOLTAGE_DENSITY` and stay bare. Both
spellings were confirmed against actual raws (see §4).

**Units.** Everything inside `Ndata` is squared; the writer takes the square
root of every column whose name starts with `onoise`/`inoise` unless the user
sets `sqrnoise`:

```c
/* cktnoise.c:110-113 (density) and :123-126 (totals) */
if (!data->squared)
    for (i = 0; i < data->outNumber; i++)
        if (data->squared_value[i])
            data->outpVector[i] = sqrt(data->outpVector[i]);
```

So the default raw carries **V/√Hz** and **V rms**, not V²/Hz. espice was
emitting the squared quantity under the name `onoise_density`.

Checked against the binary, not just the source: the `resistor_noise` deck
re-run inside a `.control` block with `set sqrnoise` gives
`onoise_total = 8.2872e-12`, and `√(8.2872e-12) = 2.8788e-6`, which is exactly
what the default run writes. `sqrnoise` also renames the plots
(`Integrated Noise - V^2 or A^2`) and drops the `v(...)` decoration from the
totals, since the type becomes `SV_SQR_VOLTAGE`. espice implements the default
only; nothing in the tree asks for the squared form.

### 1.3 Input-referred spectrum

`noisean.c:423-430`: an ordinary AC solve driven from the `.noise` card's own
input source gives the gain, and `inoise = onoise / max(|H|², N_MINGAIN)` with
`N_MINGAIN = 1e-20` (`noisedef.h:106`). The card's second argument names that
source, and ngspice refuses a card whose source has no AC value
(`noisean.c:144-149`). espice resolved the argument and threw it away, which is
why `inoise_spectrum` had nothing to divide by and was absent.

### 1.4 The band integral is not a trapezoid

`Nintegrate` (`ninteg.c:27-45`) fits `S = a·f^p` between two adjacent points in
log-log and integrates that exactly; `|p| < 1e-10` degenerates to the rectangle
rule and `|p+1| < 1e-10` to `a·ln(f₂/f₁)`. Critically it is applied **per
generator** (`resnoise.c:141-161`, `dionoise.c` likewise), not to the total —
the sum of a flat thermal term and a `1/f` flicker term is not a power law, so
integrating the sum would be wrong wherever both are present. The first sweep
point has `delFreq == 0` and only seeds the history (`noisean.c:376`).

## 2. `.disto` — what ngspice actually does

### 2.1 Where the drive goes

```c
/* cktdisto.c:100-117 */
if (here->VSRCdGiven) {
  if ((here->VSRCdF1given) && (mode == D_RHSF1)) {
     mag   = here->VSRCdF1mag;
     phase = here->VSRCdF1phase;
  }
  ...
  ckt->CKTrhs [here->VSRCbranch] = 0.5*mag*cos(M_PI*phase/180.0);
  ckt->CKTirhs[here->VSRCbranch] = 0.5*mag*sin(M_PI*phase/180.0);
}
```

Three facts, all of which espice had wrong:

1. **The drive lands on the source's MNA branch row**, not a node row.
2. **The card is selected by `DISTOF1`**, not by deck position. `disto/bjt_ce`
   is the proof: its first V card is the supply `Vcc`, and `DISTOF1` is on
   `Vin`.
3. **The magnitude is halved** — every Volterra kernel here is a one-sided
   phasor. `DISTOF1` parses as bare keyword → mag 1 phase 0, one number → mag,
   two numbers → mag and phase in degrees (`vsrcpar.c:180-193`).

An I card instead drives its two node rows with `∓0.5·mag`
(`cktdisto.c:151-158`) — that is the only form for which a node-row stamp is
correct, and it carries a negation espice did not have either.

### 2.2 The other two factors

The second-order source term is `½·F''[V₁,V₁]`: ngspice folds the ½ into the
device coefficient (`g2 = 0.5 * gd / vte`, `diodset.c:78`, which is exactly
½·d²I/dV²) and contributes `g2·V₁²` (`dloadfns.c:545` `D1n2F1` → `S2v2F1`),
stamped negative into the positive row (`diodisto.c:76-79`). espice's tensor
contraction already sums both `(a,b)` and `(b,a)`, so the ½ belongs once on the
RHS.

Stored kernels are scaled back to **sinusoid amplitude** before output — ×2 for
`F1` and `2F1`, ×4 for the two-tone mixing buckets, ×6 for `2F1−F2`
(`dkerproc.c:24-95`). HD2 is a ratio, so the ×2 cancels there.

### 2.3 Output shape (a divergence we did not close)

ngspice writes two *complex* plots, `DISTORTION - 2nd harmonic` and
`DISTORTION - 3rd harmonic`, each over every circuit variable
(`distoan.c:516-555`). espice writes one real plot,
(`frequency`, `hd2`, `v1_mag`, `v2_mag`), at one node. §4.2 shows the kernel
values agree with the matching ngspice column; the shape does not, and closing
it needs the third-order kernel as well. Left open, recorded in
`docs/analysis/distortion.md`.

## 3. Root causes

### 3.1 `.noise` returned exactly zero on a resistor deck

`Circuit.collectNoiseSources` walks `b.hooks.collect_noise`, and
`devices/engine.zig` installs that hook only for a device that declares
`noise_gens`:

```zig
.collect_noise = if (@hasDecl(D, "noise_gens")) collectNoise else null,
```

`resistor.va` and `diode.va` declared none. A model with no declaration is
therefore **silent, not noiseless** — it is removed from the analysis. A deck
whose only sources are resistors produced an empty source list and `onoise = 0`
at every frequency. Three further defects sat on top: the squared units, the
absent `inoise_spectrum`, and the absent `Integrated Noise` plot.

### 3.2 `.disto` returned zero for every output

`disto.zig:124` stamped `rhs_work[options.ac_source_node] = options.ac_magnitude`,
with `ac_source_node` defaulting to `ctx.source_node` — the **node** the drive V
source holds. That node's voltage is pinned by the source's own branch
equation, so injecting current into its row changes only the branch current:
`V₁ = 0` everywhere, hence `v1_mag = 0`, `v2_mag = 0`, and the
`v1_out_mag > 1e-30` guard collapsed `hd2` to 0 as well.

## 4. What changed

Commits on `zero-analyses`:

| commit | subject |
|---|---|
| `31d137a` | noise: nobody declared a generator, so the analysis reported zero |
| `01a8021` | disto: the F1 drive belongs on the DISTOF1 card's branch row |
| (this file) | docs: the two analyses that returned zero |

No VerA change was needed, so `zero-analyses-vera` is unchanged from its branch
point — the `noise_gens` mechanism already existed and the models simply did not
use it. Both commits replace `612415d`, an unbuilt, untested WIP snapshot that
was rebased away; the code in them is byte-identical to the tree that ran
407/407.

**Devices** (`src/devices/models/{resistor,diode}.va`) — one `white_noise`
contribution per ngspice generator: resistor `4kT/R` across `(p,n)`; diode RS
thermal `4kT/rs(T)` on the series branch and junction shot `2q|Id|` on
`(ai,c)`. With `rs == 0` the series branch collapses, its two ends become one
row, and its adjoint gain is 0 — which is also ngspice's answer, since
`DIOtConductance` is only stamped when RS > 0.

**Analysis** (`src/analysis/ac/noise.zig`) — `sweep` now fills `onoise` and
`inoise` (both squared, like `Ndata`) and returns the two band integrals from a
port of `Nintegrate` including `limexp` and all four `noisedef.h` thresholds;
`run` takes the square root at the same boundary `cktnoise.c` does and emits
whichever of the two plots `Options.integrated` selects.
`src/engine.zig` resolves the input source to `in_branch` for the gain solve,
and queues the second job for the `Integrated Noise` plot when the band is
non-degenerate.

**Analysis** (`src/analysis/post/disto.zig`) — `drive_branch` replaces the node
stamp, with `0.5·mag·e^{jφ}` on the branch row and the negated current-source
form kept for an I-card drive; `−½` on the second-order RHS; ×2 on the reported
`v1_mag`/`v2_mag`. `src/builder.zig` parses `DISTOF1 [mag [phase]]` off every V
card into `v_distof1` (and teaches `sourceDc` to skip its operands);
`src/engine.zig` picks the first card that carries one.

Two deliberate simplifications, both carrying a `ponytail:` comment. ngspice
sums *every* `DISTOF1` card into one RHS; espice takes the first, because no
fixture has two. And a `.disto` deck with no `DISTOF1` anywhere falls back to
the deck's drive source at unit magnitude, where ngspice would solve an
unexcited system and print zeros — a divergence chosen in the direction of the
defect this document is about: a non-zero answer gets looked at, a zero does
not.

### 4.1 `.noise`, before and after

"before" is HEAD~ (`446268a`) with the four analysis/device files at their
pre-fix state, same binary flags (`-b --backend cpu`). Reference is
`ngspice-44.2 -b`. `max rel` is over every point of the column.

| fixture | column | ngspice | before | after | max rel before / after |
|---|---|---|---|---|---|
| `golden/noise` (1k+3k) | `onoise_spectrum` | 3.5259e-9 flat | **0**, all 21 pts | 3.5259e-9 flat | 1.00e0 / 1.74e-7 |
| | `inoise_spectrum` | 4.7012e-9 | column absent | 4.7012e-9 | — / 1.74e-7 |
| | `v(onoise_total)` | 1.1149e-6 | plot absent | 1.1149e-6 | — / 1.74e-7 |
| | `v(inoise_total)` | 1.4866e-6 | plot absent | 1.4866e-6 | — / 1.74e-7 |
| `noise/resistor_noise` (10k+10k) | `onoise_spectrum` | 9.1039e-9 flat | **0**, all 41 pts | 9.1039e-9 flat | 1.00e0 / 1.74e-7 |
| | `inoise_spectrum` | 1.8208e-8 | column absent | 1.8208e-8 | — / 1.74e-7 |
| | `v(onoise_total)` | 2.8788e-6 | plot absent | 2.8788e-6 | — / 1.74e-7 |
| | `v(inoise_total)` | 5.7575e-6 | plot absent | 5.7575e-6 | — / 1.74e-7 |
| `noise/rc_noise` (100k+100p) | `onoise_spectrum` | 4.0714e-8 → 6.4798e-11 | **0**, all 141 pts | 4.0714e-8 → 6.4798e-11 | 1.00e0 / 1.74e-7 |
| | `inoise_spectrum` | 4.0714e-8 flat | column absent | 4.0714e-8 flat | — / 1.74e-7 |
| | `v(onoise_total)` | 6.4322e-6 | plot absent | 6.4322e-6 | — / 1.74e-7 |
| | `v(inoise_total)` | 1.3636e-4 | plot absent | 1.3636e-4 | — / 1.74e-7 |
| `noise/amp_noise` (BJT+100k+4.7k) | `onoise_spectrum` | 1.1661e-8 flat | 1.0777e-8 flat | 1.3931e-8 flat | 7.58e-2 / 1.95e-1 |
| | `v(onoise_total)` | 1.1661e-5 | plot absent | 1.3930e-5 | — / 1.95e-1 |
| `devices/vbic_noise_scale` | `onoise_spectrum` | 8.6321e-7 → 3.6737e-9 | 2.0425e-7 → 1.0242e-9 | 3.2986e-7 → 3.1396e-9 | 7.63e-1 / 6.18e-1 |
| | `v(onoise_total)` | 2.4860e-4 | plot absent | 2.4189e-4 | — / 2.70e-2 |

The "before" column is the same quantity, square-rooted: espice wrote V²/Hz as
`onoise_density`, so the raw held 1.1615e-16 where this table shows 1.0777e-8.
That conversion is the only thing done to it.

The three resistor-only fixtures go from identically zero to exact — the
1.74e-7 is the Boltzmann-constant revision and nothing else.

**`noise/amp_noise` got numerically worse, and that is the right outcome.**
Before, the deck had one contribution (the BJT, at 2× the correct shot power)
and was 7.6% low; now it has two, the resistor term is exact, and the total is
19.5% high. The two errors had been partially cancelling. The arithmetic is
exact:

    after² − before²  =  1.9405e-16 − 1.1615e-16  =  7.7908e-17
    4·k·T·(1/4.7k)·(4.7k)²                        =  7.7908e-17

to five digits. So the term this work added is right to the last digit, and
100% of the residual is the shot-noise factor of §5. `devices/vbic_noise_scale`
improves in the same breath (−76% → −62% at 1 kHz, −72% → −15% at 100 MHz)
because its resistors were missing too.

### 4.2 `.disto`, before and after

espice reports one node; the table names the ngspice 2nd-harmonic column it
corresponds to. `max rel` is `|v2_mag − |V_2f1(node)||` over every point.

| fixture | node reported | ngspice \|V_2f1\| | before | after | max rel (after) |
|---|---|---|---|---|---|
| `golden/disto` | `v(out)` | 1.044775e-2 | 0 (all 6 pts) | 1.044798e-2 | 2.15e-5 |
| `disto/diode_clipper` | `v(out)` | 1.044775e-2 | 0 (all 21 pts) | 1.044798e-2 | 2.15e-5 |
| `disto/bjt_ce` | `v(b)` | 1.319478e-4 | 0 (all 31 pts) | 1.319506e-4 | 2.08e-5 |
| `disto/mos_cs` | `v(d)` | 7.877036e-4 | 0 (all 31 pts) | 7.877036e-4 | 9.85e-9 |

`hd2` and `v1_mag` were 0 before and are non-zero after on all four; ngspice
emits no F1 plot for a one-tone `.disto`, so they have no reference column.

`mos_cs` agrees to 1e-8 because MOS level-1 is polynomial and the
finite-differenced `F''` is exact for it; the diode and BJT residuals are the
`fd_eps = 1e-6` truncation error of the kernel pass, not a modelling
difference.

`disto/bjt_ce` reporting `v(b)` and not the collector is the "last probe"
default, which is an artifact of MNA row numbering — espice's probe order for
that deck is `v(vcc), v(in), v(c), v(b)`. The numbers are right at the node
chosen; the choice is not meaningful. See §2.3.

## 5. The noise kinds the engine cannot represent

`devices/engine.zig collectNoise` handles one kind:

```zig
switch (gen.kind) {
    .thermal => { const g = @abs(out[gen.row].ddxAt(gen.col)); ... },
    .shot, .flicker => {},
}
```

and the PSD is derived from the **Jacobian**, `4kT·|∂F_row/∂x_col|`. VerA
compounds this from the other side: `src/ir/lower.zig noiseSrcsOf` tags every
`white_noise` call `.thermal` and every `flicker_noise` call `.flicker`
regardless of what the argument computes, and `src/backend/codegen.zig`
`emitNoiseTable` exports only `{row, col, kind, source}` — the PSD expression
itself is discarded (`codegen.zig:6154` carries the `ponytail:` note saying so).
`.shot` is never emitted by VerA at all.

Consequences, measured:

- **Shot noise is 2× high in power, √2 in amplitude.** Sixteen models in the
  tree write shot generators as `white_noise(2q|I|)`; the host evaluates them
  as `4kT·g`, and for a junction `g = qI/(NkT)`, so `4kT·g = 4q·I/N` against
  the true `2q·I`. `noise/amp_noise` is the clean case: the only contributions
  at the output are `RC` thermal (`4kT·4.7k` = 7.79e-17 V²/Hz, exact) and the
  BJT collector generator. §4.1 separates the two exactly: the pre-fix binary
  ran with the BJT alone and produced 1.1615e-16 V²/Hz, and the post-fix binary
  produces 1.9405e-16, a difference of 7.7908e-17 = `4kT·4.7k` to five digits.
  ngspice's own total is 1.3598e-16, so its BJT term is 5.81e-17 — **half** of
  espice's 1.1615e-16. The measured 1.3931e-8 / 1.1661e-8 = **+19.5%** is that
  factor and nothing else. Every other generator in that deck is shorted by an
  ideal source, which is why the deck isolates it so cleanly.
- **Flicker noise is dropped.** `devices/vbic_noise_scale` sets
  `KFN=10e-15 AFN=1 BFN=1`, and at 1 kHz ngspice's flicker term dominates:
  espice reads 3.2986e-7 against 8.6321e-7, **−62%**. The error shrinks with
  frequency (−15% at 100 MHz) exactly as a `1/f` term should.
- **Non-Jacobian thermal expressions are approximated.** VBIC's `rci` generator
  is `4kT·(|Irci| + 1e-10·Gci)/(|Vrci| + 1e-10)` (`vbic13_4t.va:1724`), a
  ratio the host replaces with the branch conductance.

None of this is new — `docs/devices/noise-contract.md` §2 specifies the fix
(`noisePsd` returning a `PsdTerm` per generator; the contract surface landed
2026-07-12) and `docs/perf/remaining-2026-09-10.md` already recorded
"`engine.zig:1651` emits only `.thermal`" as a live hazard. What is new is the
number attached to it. Declaring the diode's shot generator anyway is the
consistent choice — it matches the sixteen models already doing it, and
`√2` high beats a diode that contributes exactly nothing.

Also unchanged and worth naming: the gain solve in §1.3 drives the input branch
at unit magnitude rather than reading the card's `AC <mag>`, which is the same
`ac.zig` defect the `ac-source-drive` work fixed on `main`. Every `.noise`
fixture here carries `AC 1`, so it does not move a number; rebasing onto that
work removes the hardcode.

## 6. Reproducing

```
ngspice -b -r ref.raw benchmark/fixtures/<f>/circuit.sp
zig-out/bin/espice -b --backend cpu -r out.raw benchmark/fixtures/<f>/circuit.sp
```

Both raws are multi-plot, so the benchmark comparator still scores them `N/A`
(the `P5` branch, `runner.zig:400`). Validating them in the runner is
`na-audit-2026-09-10.md` change #2 (match plots by name), not an espice change;
the numbers above were taken by parsing the raws directly.
