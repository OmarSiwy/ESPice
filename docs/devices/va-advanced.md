# VA-normative advanced models — EKV, HiSIM2/HV, BSIMBULK, BSIM-CMG/IMG, LUTSOI, PSP102

Short-form doc: for these models a **free production Verilog-A is the
normative spec** (OpenVAF integration_tests,
`github.com/pascalkuthe/OpenVAF/tree/master/integration_tests` — EKV,
HiSIM2, HiSIMHV, HiSIMSOTB, BSIMBULK, BSIMCMG, BSIMIMG, PSP102; LUTSOI
from its authors). Deriving full math here duplicates the VA; instead:
core idea, region/flow shape, batching notes, noise — and the VA file
as the equation source. Full 4-section docs get written per-model when
a fixture demands bit-exactness (the bsim3/bsim4/psp103 docs show the
template).

## 1. Mathematical specification (core per model)

**EKV 2.6** (`EKV/ekv.va`): charge-based, symmetric
source/drain-referenced-to-bulk model. Pinch-off voltage
$V_P = f(V_G)$ (single expression), normalized forward/reverse currents
$i_{f,r} = \left[\ln(1 + e^{(V_P - V_{S,D})/(2V_t)})\right]^2$ (the
famous interpolation covering weak→strong inversion), drain current
$I_D = I_S(i_f - i_r)$, $I_S = 2n\beta V_t^2$. All-region single
expression, no mode swap (symmetric by construction) — the friendliest
advanced model for SIMT after PSP.

**HiSIM2 / HiSIM-HV** (`HiSIM2/hisim2.va`, `HiSIMHV/hisimhv.va`):
complete surface-potential models (Hiroshima); unlike PSP the surface
potential is solved by an internal **iterative** solve at source and
drain (bounded Newton, typically 2–6 iterations) — the GPU note from
hicum applies (fixed-trip iteration). HiSIM-HV adds the drift/LDMOS
extension: bias-dependent drift resistance region with its own
internal nodes, quasi-saturation, and self-heating — the standard for
power LDMOS sign-off.

**BSIMBULK** (`BSIMBULK/bsimbulk.va`): Berkeley's charge-based
successor to BSIM4 (BSIM6 lineage — same model family, bsimbulk is the
CMC-standardized name; we carry `bsim_bulk.zig`, there is no separate
bsim6 in our tree). Symmetric core (no source/drain swap
discontinuities — fixes BSIM4's Gummel-symmetry defect), all BSIM4
extras (tunneling, GIDL, rdsMod, rgate/rbody) re-derived
charge-consistently.

**BSIM-CMG / BSIM-IMG** (`BSIMCMG/bsimcmg.va`, `BSIMIMG/bsimimg.va`):
FinFET/GAA common-multi-gate and independent-double-gate models;
perimeter-normalized charge core with quantum confinement, multi-fin
geometry scaling; IMG adds separate front/back gate control (FDSOI).

**LUTSOI**: table-model (lookup + interpolation) SOI device — spline
evaluation over pre-characterized (Vg, Vd, Vb, T) grids; the "model"
is the interpolation scheme + monotonicity guards, not physics.

**PSP102 → 103 delta note**: PSP102 is the previous PSP generation —
same surface-potential core as psp103.md; 103 added (rel. notes):
reworked velocity saturation/`THESATB`, edge-transistor model
(SWEDGE), NUD effect, updated noise (§ below), JUNCAP200 updates.
Cards for 102 mostly load under 103 with defaulted new params; exact
delta list lives in `releasenotesPSP103p7.txt` in the same dataset.

## 2. Flow / 3. CPU / 4. GPU (family notes)

Flow: all are single-expression or bounded-internal-iteration models
evaluated per NR iteration with no external region switching; our VA
pipeline (`.hdl` → per-batch dyn ABI, or baked `va_devices`) is the
intended execution route — the Zig ports in-tree
(`ekv.zig, hisim2.zig, hisim_hv.zig, bsim_bulk.zig, bsim_cmg.zig,
bsim_img.zig, lutsoi.zig`) are hand-ports pinned by fixtures.

CPU pseudo-code shape: `eval = VA contribution list` — the OpenVAF/our
codegen order is the flow. GPU: EKV/BSIMBULK/CMG/IMG are straight-line
(batch like bsim4); HiSIM's internal SP Newton → fixed-trip unroll;
LUTSOI → texture/table gathers, keep tables in read-only cache, batch
key = table id.

## Noise model (in-device)

Contract: [noise-contract.md](noise-contract.md). **All of these carry
their noise in the VA** — transcribe, don't invent:

- EKV: thermal $4kT\,\gamma\,g_{ms}$-form (slope factor weighted),
  flicker KF/AF over $C_{ox}WL$.
- HiSIM2/HV: channel thermal from the SP solution (Nyquist integral
  form), 1/f (NFALP/NFTRP trap model), induced gate noise optional.
- BSIMBULK/CMG/IMG: BSIM4-style tnoiMod lineage incl. correlated
  gate/drain terms — `white_noise`/`flicker_noise` +
  correlation contributions in the VA.
- LUTSOI: typically none (tables) — declare none.
- PSP102: as PSP103 minus the 103 noise updates.

`noisePsd` hook: the VA `white_noise(P)`/`flicker_noise(K, ef)`
contributions map 1:1 onto PsdTerm{white, flicker, ef} — the VA
pipeline can emit the hook mechanically (same codegen that builds
eval). That is the actual implementation plan for this whole family.

## Sources

- https://github.com/pascalkuthe/OpenVAF/tree/master/integration_tests — EKV, HiSIM2, HiSIMHV, HiSIMSOTB, BSIMBULK, BSIMCMG, BSIMIMG, PSP102 directories (dataset confirmed; individual files fetched on demand — only PSP103/BSIM4/BSIMSOI were pulled in this pass, see their docs).
- `releasenotesPSP103p7.txt` (same dataset) for the 102→103 delta.

## Verification status

- Everything here: **structural** — deliberately. The VA is the spec;
  this doc is the index entry + batching/noise guidance. Per-model
  full docs get written when a fixture forces bit-exact work.

## Our implementation

- `modules/devices/src/{ekv,hisim2,hisim_hv,hisim_soi,hisim_sotb,bsim_bulk,bsim_cmg,bsim_img,lutsoi}.zig`; runtime VA route per `arpice-runtime-va-loading` memory.
- Bench fixtures: `devices/ekv`? (none today), `hisim2`, `hisimhv`; CMG/IMG/BULK/LUTSOI currently fixture-less (coverage gap — add fixtures before trusting the ports).
