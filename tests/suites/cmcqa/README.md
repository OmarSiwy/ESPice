# cmcqa: compact-model QA decks

`fetch.sh DIR` downloads the public CMC QA material and the GF180MCU
model regressions into `DIR/src` and checks each file's sha256. `gen.py` then
writes one single-device ngspice-dialect deck per test into
`DIR/{hicum,psp,gf180}`. Nothing is vendored. A second run downloads
nothing and only regenerates the decks.

Each `X.sp` has the developer's or foundry's result beside it as
`X.sp.reference`, a whitespace table with one header line. Nothing reads
these files yet; they are there for a later oracle comparison. The row
order and sign conventions are in `gen.py`'s docstring. In short: rows run
biasList outer, then biasSweep, then frequency; `I(p) = -i(v<p>_<copy>)`;
G and C follow CMC's `runQaTests.pl`.

## Sources and pins

| Model | Source | Pin | Licence |
|---|---|---|---|
| HICUM/L2 2.4.0 | TU Dresden, `iee/eb/forsch/Models/qa_{setup,results}_hicumL2V2p4p0.zip` | sha256 in `fetch.sh` | None stated; HICUM licence (Schröter) for the model. Fetch only. |
| PSP 103.3 | CEA-Leti PSP support, `Documents/Level 103.3.3/psp_VA_and_CMC_ref_data.tar.gz` (the `103.3.0` tree) | sha256 in `fetch.sh` | PSP `IP_NOTICE_DISCLAIMER_LICENSE` (in the tarball's `vacode/`). Fetch only. |
| GF180MCU | `google/globalfoundries-pdk-libs-gf180mcu_fd_pr`, `models/ngspice` | commit `9f992d5a`, per-file sha256 in `gf180.sha256` | Apache-2.0 |
| VBIC 1.3 | not public | none | QA is for CMC members only, and the `ominux/cmcqa` mirror has no VBIC |

## Decks

| Model | LEVEL | Decks | Kinds | ngspice-45 |
|---|---|---|---|---|
| HICUM/L2 (`hicum_*`) | 8 | 585 (169 tests x temperature, the 13 noise tests x 5 bias points) | 390 DC, 130 AC, 65 noise | runs all 585; 514 of the 520 DC/AC finish |
| PSP 103 (`psp_{sym,asym}_{nmos,pmos}_*`) | 1040 | 1,944 (486 per variant) | 1,664 DC, 152 AC, 128 noise | **cannot run: ESPice-only, compare against the CMC reference** |
| GF180 (`gf180_*`), via the PDK's `sm141064.ngspice` | BSIM4, GP BJT, diode 3, subckt R/C | 3,116 | DC (nested), OP, tran | runs every family (sampled) |

The GF180 decks by family (upstream `models_regression.py` directory):

| Decks | Upstream | Count | Reference |
|---|---|---|---|
| `gf180_vgs_*`, `gf180_vbs_*` | `mos_iv_vgs`, `mos_iv_vbs` (Id) | 576 + 306 | Id against Vds (stepped Vgs) and Vgs (stepped Vbs) |
| `gf180_rds_*` | `mos_iv_vgs/device_netlists_Rds` | 576 | \|Rds\| (3.3 V) or \|Gds\| (6 V sheets) against Vds, stepped Vgs: `1/gds`, the slope of the Id sweep |
| `gf180_cv_{cgc,cgs,cgd}_*` | `mos_cv` | 24 | Cgc, Cgs, Cgd (fF) of the 3.3 V devices |
| `gf180_icvc_*` | `bjt_iv` | 40 | Ic against Vc, stepped Ib |
| `gf180_beta_*` | `bjt_beta` | 40 | Ic and Ib against Vb, stepped Vc, side by side |
| `gf180_cj_*` | `bjt_cj` | 234 | EB, CB (and npn CS) junction capacitance per corner and temperature |
| `gf180_diode_*` | `diode` | 432 | I(V) and C(V) per corner |
| `gf180_cap_*` | `mimcap_c`, `moscap_c` | 132 | one capacitance (fF) from the deck's `.meas` |
| `gf180_res_*` | `resistor_r` | 756 | sheet resistance per W/L (RES\*a) or temperature (RES\*b) |

How the decks are built:

- **HICUM**: there is one deck per test and temperature, since a test sweeps
  up to six temperatures. The reference is that temperature's slice of the
  test's `.standard` file.
- **PSP**: PSP has no ngspice LEVEL; it is OSDI-only in ngspice-45, and the
  bench runner refuses any `level=1040` deck for ngspice. ESPice maps 1040
  to `psp103`. The self-heating `_t` variants (pins `d g s b dt`, `dt`
  floating) need PSP103TVA: `fetch.sh` generates them once
  `src/frontend/spice.zig` maps `psp103tva` (the `models-upstream`
  work), as N cards on `.model qamod psp103tva type=1|-1`, 456 decks per
  variant. Their `idvdh_dt` tests read `V(dt)`, the temperature rise.
- **GF180**: each family's templates are rendered the way its upstream
  `models_regression.py` renders them: one deck per foundry row, with that
  row's geometry, temperature and corner. Upstream wraps the sweep in a
  `.control` block; here it becomes the `.dc` card it runs (a `let` /
  `compose` / `alter` loop becomes a nested `.dc`). The reference is that
  row's block of the `.nl_out.xlsx` file, found by its quantity header and
  the device label under it. Resistors put one copy per row in a deck per
  file, corner and temperature (`Rs = 1M*V(p_k)/(V(n)-V(p_k)) * w/l`).
  The capacitance decks (MOS CV, BJT and diode junctions) run the bias
  sweep, but the reference is an operating-point device quantity
  (`@mn[cgd]`, `@dn[cd]`, ...) that the `.dc` output does not carry; each
  names it on a `* reference quantity:` line.
  `design.ngspice` and `sm141064.ngspice` are copied next to the decks.
  Deliberate departures from upstream: the Cgs/Cgd templates hardcode
  W=200u L=0.28u nf=20 for every row, replaced here by the row's geometry;
  the resistors' wl polarity list is off by one upstream, so every p-type
  resistor takes -3.3 V as in its temperature half; `RES*b` rows take their
  width from the row label rather than upstream's `l` or `l/2` rule.

The 6 HICUM decks that ngspice cannot finish are `hicum_fout_npn_1D_npn_*`
for the `full_sh`, `full_subcoupl*`, `full_subtran` and `cornoise` cards.
In these, Vce sweeps to 6 V while Vbe reaches 0.9 V. ngspice loses DC
convergence near 5.7 V ("temperature limiting function received NaN"),
but the CMC reference covers the whole sweep.

## Version mismatches and gaps

- **PSP**: the public QA is for 103.3, but ESPice ships 103.7 (`models/psp103.va`).
  The parameter cards come from 103.3. Expect small differences wherever
  103.4 to 103.7 changed the model; the newer QA sets are members-only.
- **HICUM**: the version matches exactly (2.4.0). ngspice's built-in
  `hicum2` is 2.4.0 as well.
- **Sweep endpoint**: a CMC sweep whose stop value is off the step grid
  (HICUM `0.3,1.05,0.02`) ends on the stop value in the reference. ngspice's
  `.dc` stops at the last grid point, one row short.
- **Not generated**:
  - the HICUM pnp polarity check;
  - the PSP self-heating `*_t` variants until ESPice has `psp103t`;
  - the PSP pin-flip and m-factor variants;
  - the GF180 `sc_regression` (standard cells) and `smoke_test`.
- **Noise**: one deck per bias point, rigged as `runQaTests.pl` rigs
  ngspice (`hn` turns the pin's ammeter current into `v(n_<pin>)`;
  `N(pin) = onoise_spectrum^2` in A^2/Hz). Against the CMC reference,
  ESPice at b397ecc (max relative error over the frequency sweep):
  - HICUM: all 65 decks (13 tests) within 1e-3.
  - PSP: 40 of 128 decks within 1%. The other 88 differ only at the top
    decade (1e8 Hz, or 1e9 Hz for `*_fntexc`), by up to 65%: the
    simulated spectrum lacks the f^2 rise of induced gate noise. Cause:
    `models/psp103.va` is ngspice-45's ADMS flattening, which comments
    out the correlated noise (`I(GP,SI|DI) <+ ddt(... CGeff * V(NOIC))`
    and the `migid` drain term, "ngspice-adms: can't handle specific
    noise contributions"). Upstream's PSP103_module.include keeps them.
  - PSP `_t` on the models-upstream PSP 103.8.2 build: 88 of 128 within
    1% (every `N(g)`); 40 `N(d)` decks still differ at the top decade, by
    up to 28%, cause not isolated (the drain-gate correlation term, or
    the 103.3 to 103.8 model changes).
- **GF180 against ngspice-44.2** (one or two decks per family, ESPice at
  b397ecc): MOS Id, Rds and CV sweeps agree within 0.4% (12% on a 1.5 pA
  bulk leakage); the dnwps diode and the nplus/rm resistors agree to 1e-8.
  These ESPice gaps show up:
  - Gummel-Poon `vnpn_*`/`vpnp_*` (icvc, beta, cj): collector currents off
    by orders of magnitude;
  - `np_3p3` and `sc_diode` (level 3) I(V): forward current 1e-7 of
    ngspice's;
  - `ppolyf_u` resistors: V(p) wrong; its `.subckt` line continues with
    `+` after a `*` comment line;
  - `gf180_cap_*`: `temper` in a subckt `.param` expression fails with
    UnresolvedParameter, and `.meas ... FIND par('...time...')` is
    dropped as malformed.
