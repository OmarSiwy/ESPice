# cmcqa: compact-model QA decks

`fetch.sh DIR` downloads the public CMC QA material and the GF180MCU MOS
regression into `DIR/src` and checks each file's sha256. `gen.py` then
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
| GF180MCU MOS | `google/globalfoundries-pdk-libs-gf180mcu_fd_pr`, `models/ngspice` | commit `9f992d5a`, per-file sha256 in `gf180.sha256` | Apache-2.0 |
| VBIC 1.3 | not public | none | QA is for CMC members only, and the `ominux/cmcqa` mirror has no VBIC |

## Decks

| Model | LEVEL | Decks | Kinds | ngspice-45 |
|---|---|---|---|---|
| HICUM/L2 (`hicum_*`) | 8 | 520 (169 tests x temperature) | 390 DC, 130 AC | runs all 520; 514 finish |
| PSP 103 (`psp_{sym,asym}_{nmos,pmos}_*`) | 1040 | 1,816 (454 per variant) | 1,664 DC, 152 AC | **cannot run: ESPice-only, compare against the CMC reference** |
| GF180 BSIM4 (`gf180_{vgs,vbs}_*`) | 54, via the PDK's `sm141064.ngspice` | 882 (14 device templates x W/L/temperature rows) | DC (nested) | runs all 882 |

How the decks are built:

- **HICUM**: there is one deck per test and temperature, since a test sweeps
  up to six temperatures. The reference is that temperature's slice of the
  test's `.standard` file.
- **PSP**: PSP has no ngspice LEVEL; it is OSDI-only in ngspice-45, and the
  bench runner refuses any `level=1040` deck for ngspice. ESPice maps 1040
  to `psp103`.
- **GF180**: the `mos_iv_vgs` (Id vs Vds, stepped Vgs) and `mos_iv_vbs` (Id
  vs Vgs, stepped Vbs) Id templates are rendered the way upstream
  `models_regression.py` renders them. Upstream wraps the sweep in a
  `.control` block; here it becomes a `.dc` card. The reference is the
  foundry's Id table for that W/L, taken from the `.nl_out.xlsx` file.
  `design.ngspice` and `sm141064.ngspice` are copied next to the decks.

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
  - noise tests (13 HICUM, 8 PSP per variant);
  - the HICUM pnp polarity check;
  - the PSP self-heating `*_t` variants, because ESPice has no `psp103t`;
  - the PSP pin-flip and m-factor variants;
  - the other GF180 regressions (BJT, diode, MIM/MOS caps, resistors, MOS
    CV, Rds). Each needs its own xlsx column mapping, ported from its
    `models_regression.py`.
