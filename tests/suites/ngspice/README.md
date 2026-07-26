# ngspice suite

ngspice's own decks, run by `zig build bench-suites -Dsuite=ngspice`.
`fetch.sh DIR` downloads them and writes the runnable ones to DIR as
ngspice-dialect `*.sp` files. Nothing here is vendored.

## Source

- The ngspice repo `https://git.code.sf.net/p/ngspice/ngspice` at tag
  `ngspice-45`, commit `86c78150b77ceea8488707565b3be2d2f4e7fbb9`. The
  benchmarking shell runs ngspice-45, so its oracle and its decks come from
  the same release. Only `tests/` and `examples/` are checked out.
- The Quality-page archives (https://ngspice.sourceforge.io/quality.html),
  checked by sha256 in `fetch.sh`: `paranoia.7z`, `iscas85Circuits.7z`
  (c432 to c7552 on PTM 45 nm BSIM4, plain and RC-annotated, a size ladder
  from 261 to 3,624 gates) and `kicad-test-circuits.7z`.

## Licence

Modified BSD (ngspice `COPYING`; the paranoia scripts say "New BSD"). The
ISCAS85 netlists and the PTM 45 nm card carry no licence of their own, which
is one more reason the suite is fetched rather than vendored.

## Decks

353 decks: 105 from `tests/`, 147 from `examples/`, 78 from paranoia, 20
ISCAS85 (c432 to c7552, plain and `_ann`) and 3 KiCad. A source file that
appears twice, such as the paranoia copies of `examples/`, is kept once.

Conversion:

- Each `.control` block is dropped. A deck with no analysis card gets the
  analysis and `save` commands of its control block as cards. That is how
  the ISCAS85 decks get their `.tran 1ps 1ns uic`.
- The ISCAS85 decks get a 10 ps max step. It cuts ngspice's c432 run from
  21 s to 2.6 s; the 1 ns window and the inputs are unchanged.
- Include paths become absolute, since the decks are written outside the
  source tree.
- Decks written for ngspice's PSpice/LTspice mode get a `.spiceinit` with
  `set ngbehavior=ltpsa`: upstream's own in `p-to-n-examples` and `optran`,
  plus `kicad/*` and `examples/{ddt,probe,soa}`. The bench runner calls
  `ngspice -n`, which skips `.spiceinit`, so under the runner those decks
  fail in ngspice until the runner drops `-n` for them.

## ngspice-45 status (2026-10-06)

332 of the 353 decks run in ngspice-45 (`ngspice -b`, with `.spiceinit`
honoured). The other 21:

| Decks | Result |
|---|---|
| `examples/pss/*` (6) | this ngspice build has no `.pss` |
| `examples/sp/filter` | no RF port once the control block's `do_sp=1` is gone |
| `examples/optran/HiPass3opamps_optran` | a nested include (`opa1611.lib`) was never committed upstream |
| `paranoia/TransmissionLines/{ltra5_1,txl4_1}_line` | "device already exists" |
| `paranoia/vdmos/ro_11_vdmos` | "unknown parameter (l)" |
| `tests/vbic/diffamp` | "timestep too small" |
| `iscas85/{c5315,c5315_ann,c6288_ann,c7552,c7552_ann}`, `tests/mesa/{mesa12,mesa-12}`, `tests/vbic/FG`, `kicad/GaN_Test/GaN_boost` | did not finish within 300 s on a loaded machine (GaN_boost: 120 s); not retried with a longer timeout |

## Excluded

| What | Why |
|---|---|
| `tests/{bsim3,bsim4,bsimsoi,hicum2,hisim,hisimhv1,hisimhv2}` | CMC qaSpec trees run by `runQaTests.pl`, not decks |
| `examples/osdi`, decks that load OSDI or have N instances | ESPice compiles its Verilog-A at build time and loads no OSDI |
| `examples/{xspice,digital}`, `tests/xspice`, decks with A instances | XSPICE code models; ESPice has none |
| `examples/cider`, `numd`/`nbjt`/`numos` models | CIDER numerical devices; ESPice has none |
| `examples/{tclspice,shared,klu}` | Tcl and shared-library drivers; `klu/Circuits/85` repeats the ISCAS85 archive |
| Decks whose only analyses run inside a control loop, or after `alter`, `reset` or `mc_source` | the result comes from the script, not the netlist |
| Decks whose `.include`/`.lib` file is not in the source tree | Windows paths to a local PDK, vendor models that were never committed |
| Files with no analysis left | includes, libraries and interpreter-only decks |
| ISCAS85 `c*p/` and `*_oc` netlists | repeats of the base ladder |
| KiCad projects without an exported netlist | schematics only |
