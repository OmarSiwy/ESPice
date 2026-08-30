# In-device noise contract — current state and target design

Anchor for every per-device "Noise model (in-device)" section in this
directory. Convention: **noise lives inside the device model** — each
device declares its generators and (target) computes its own PSDs
through the device contract; analyses (AC noise, pnoise, transient
noise) only transport them. Design doc — no code changes here.

## 1. What exists today (source-verified)

**Declaration** — `../VerA/tools/contract.zig:269`:

```zig
pub fn NoiseGen(comptime D: type) type {
    return struct {
        row: ..., col: ...,                     // branch = (row unknown, col unknown)
        kind: enum { thermal, shot, flicker },
    };
}
```

Devices export `pub const noise_gens = [k]NoiseGen(Self){...}`
(validated at `contract.zig:597`). Examples: `resistor.zig:88` (one
thermal p–n), `mos1.zig:177` (rd/rs thermal + channel), `bjt.zig:282`
(rc/rb/re thermal), `diode.zig:157` (shot + flicker on the junction,
thermal on RS), `switch.zig` (thermal on G_eff).

**Collection** — `src/devices/engine.zig:736`
(`collectNoise`, installed as the `collect_noise` hook at `:284` only
when `noise_gens` exists): per instance, seeds the AD dual at the OP
`x`, calls `D.eval`, and for each `thermal` generator reads the branch
conductance off the analytic Jacobian:

```zig
const g = @abs(out[gen.row].d[gen.col]);   // g = |∂I_row/∂V_col| at x_op
// -> NoiseSource{ node_p, node_n, conductance = g }
// ponytail: shot/flicker need branch current + KF/AF;
// add a device noisePsd hook when greenlit.     (batch.zig:759)
.shot, .flicker => {},                      // <- skipped today
```

**Plumbing** — `src/analysis/root.zig:669`
`Circuit.collectNoiseSources` fans the hook over batches;
`NoiseSource = {node_p, node_n, conductance}` (`root.zig:226`).

**Consumption** — `src/analysis/ac/noise.zig:66`: adjoint sweep,
per source `psd = 4kT·conductance`, output density
$\sum |H_{branch}|^2 \cdot 4kT g$. `pss/pnoise.zig:190` and
`tran/tran_noise.zig` reuse the same collection.

So today: **thermal-only, conductance-derived, bias-frozen at x_op.**
Docs: [../analysis/ac-small-signal-noise.md](../analysis/ac-small-signal-noise.md),
[../analysis/periodic-noise.md](../analysis/periodic-noise.md),
[../analysis/transient-noise.md](../analysis/transient-noise.md).

## 2. The gaps

(a) **Shot/flicker need device data the Jacobian can't give.** Shot is
$2q|I_{branch}|$ — a *current*, and for a junction $g = dI/dV = I/(NV_t)$
so `4kT·g = 2q·I·(2/N)`: wrong by 2/N if faked as thermal. Flicker is
$K_F |I|^{A_F} / f^{E_F}$ — needs model params and the frequency axis.
Both require a device-side evaluation, not an external read.

(b) **pnoise needs orbit-sampled sources.** `pnoise.zig:190` collects
once at the DC point. Cyclostationary noise (mixers, oscillators)
requires PSDs evaluated at each PSS sample $x(t_k)$ — the hook must be a
pure function of an *arbitrary* state vector, same as `eval`.

(c) **Correlation has no representation.** BSIM4 tnoiMod ≥ 1
(drain–gate partial correlation via `rnoia/rnoib`), PSP103's
`c_igid`-correlated induced gate noise, HICUM/L2 §2.13.3 B–C
correlation: all need a pair (two branches + complex correlation
coefficient), which `noise_gens` cannot express.

## 3. Target hook design — **LANDED in contract.zig (2026-07-12)**

`PsdTerm` + the `noisePsd` validation now live in
`../VerA/tools/contract.zig` (optional decl, requires `noise_gens`;
allowlisted). Landed form drops the draft's `gen: u8` field — return
position k IS generator k. Device implementations + the collectNoise
consumption path below are still pending.

Landed shape (verbatim, contract.zig:279 + validation :611–614):

```zig
/// One generator's PSD at a given state vector, returned by the optional
/// device `noisePsd` hook (position k = noise_gens[k]):
///   S(f) = white + flicker / f^ef   [A²/Hz]
pub const PsdTerm = struct {
    white: f64,            // thermal 4kT·g, shot 2q|I| — device computes it
    flicker: f64 = 0,
    ef: f64 = 1,
    corr_with: ?u8 = null, // partner generator index (BSIM4 tnoiMod, PSP igid)
    corr: f64 = 0,         // real coeff until a reference demands complex
};

// device hook (validated when declared; requires noise_gens):
pub fn noisePsd(x: [n_u]f64, model: *const Model, instance: *const Instance)
    [noise_gens.len]PsdTerm
```

**Positional return**: `terms[k]` belongs to `noise_gens[k]` — branch
and kind come from the declaration; a generator inactive at this bias
returns `white = 0`. Devices without the hook keep the declarative
thermal-off-the-Jacobian path.

Design points:

- **Evaluable at arbitrary x** → pnoise calls it per PSS sample
  (cyclostationary modulation for free); AC noise calls it once at
  x_op; transient noise can call it per accepted step.
- **Frequency parametrized, not sampled**: the term is
  $S(f) = \text{white} + \text{flicker}/f^{e_f}$, so one device eval
  covers the whole sweep — the analysis owns the f axis (matches how
  ngspice separates NevalSrc from the 1/f multiply).
- **Correlation** as an index pair keeps the common case (no
  correlation) zero-cost and lets BSIM4 tnoiMod2 / PSP igid emit
  (id, ig, c) triples.
- Devices that only ever need thermal-off-the-Jacobian can omit the
  hook; `collectNoise` keeps its current path as the fallback.

**CPU collection pass** (replaces the thermal-only branch in
batch.zig `collectNoise`):

```
fn collectNoise(batch, x, list):
    for id in 0..batch.count:
        xl = gather(x, gath[id*n_u..])
        if D.has(noisePsd):
            terms = D.noisePsd(xl, &models[id], &instances[id])
            for k, t in enumerate(terms):          # positional: k = gen index
                g = noise_gens[k]
                if t.white == 0 and t.flicker == 0: continue
                list.append({ node_p: gath[id*n_u+g.row],
                              node_n: gath[id*n_u+g.col],
                              white: t.white, flicker: t.flicker, ef: t.ef,
                              corr_with/corr })
        else:                       # legacy: thermal off AD Jacobian
            out = D.eval(Dual, seed(xl), ...)
            for g in noise_gens where g.kind == .thermal:
                list.append({ ..., white: 4kT*|out[g.row].d[g.col]| })
```

(`NoiseSource` grows the same fields; ac/noise.zig's per-frequency loop
becomes `psd = src.white + src.flicker/pow(f, src.ef)` plus a correlated
cross term `2·c·Re(H_a·conj(H_b))·sqrt(...)` when `corr_with` set.)

**GPU collection pass** — same batching pattern as the eval megakernel
(thread-per-instance, gather, no allocation; output is a fixed-size SoA
slab since `noise_gens.len` is comptime):

```
kernel noise_batch(g, desc, blob, x, out_terms):
    for i = g.tid; i < desc.count; i += g.stride:
        xl = gather(x, gath[i*n_u..])
        terms = D.noisePsd(xl, &models[i], &instances[i])   # straight-line
        #pragma unroll
        for k in 0..NGENS:
            out_terms[(desc.term_base + i*NGENS + k)] = terms[k]
    # host: adjoint |H|² dot per frequency stays on CPU (it's per-output,
    # tiny); for pnoise the kernel runs once per PSS sample -> out_terms
    # is [n_samples][count][NGENS], fed to the LPTV sweep
```

## 4. Per-device sections reference this contract

Every device doc's "Noise model (in-device)" section states, per
generator: the `noise_gens` branch, the kind, and the exact ngspice/VA
PSD formula it must produce through `noisePsd` — i.e. the table is the
device's `noisePsd` spec. Where ngspice computes less than a modern
treatment (e.g. no induced gate noise in MOS1–9), the delta is noted.

## Sources

- `../VerA/tools/contract.zig` (NoiseGen, validation), `src/devices/engine.zig` (collectNoise + ponytail marker), `src/analysis/root.zig` (NoiseSource, collectNoiseSources), `src/analysis/ac/noise.zig`, `pss/pnoise.zig`, `tran/tran_noise.zig` — all read in-tree (this repo).
- ngspice `NevalSrc` semantics (THERMNOISE = 4kT·g·|H|², SHOTNOISE = 2q·I·|H|², N_GAIN = |H|² for external 1/f multiply): from the fetched `*noise.c`/`*noi.c` files cited in the per-device docs.

## Verification status

- §1: **source-verified** (file:line cited, this repo).
- §2: source-verified gaps (ponytail marker at batch.zig:759; pnoise x_op at pnoise.zig:188–190).
- §3: **contract surface landed** (PsdTerm + noisePsd validation in contract.zig); device impls + batch.zig/noise.zig consumption still pending.

## Cross-links

- Analysis side: [../analysis/ac-small-signal-noise.md](../analysis/ac-small-signal-noise.md), [../analysis/periodic-noise.md](../analysis/periodic-noise.md), [../analysis/transient-noise.md](../analysis/transient-noise.md).
- Bench fixtures: `benchmark/fixtures/noise/*`, `devices/vbic_noise_scale`.
