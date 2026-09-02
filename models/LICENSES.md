# Model licences

ESPice's own code is Apache-2.0 (`../LICENSE`). The Verilog-A models in this
directory keep the licence of the code they come from. Each file's header
carries its notice; this page is the index.

| Licence | Models |
|---|---|
| Apache-2.0 (written for ESPice) | `bsource_q`, `capacitor`, `inductor`, `sparam_1`-`sparam_4`, `vccs_delay`, `vccs_laplace`, `vccs_pole`, `vcvs_delay`, `vcvs_laplace`, `vcvs_pole`, `wline_1`-`wline_4` |
| BSD-3-Clause: ngspice / SPICE3, Copyright Regents of the University of California and others | `b3soidd`, `b3soifd`, `bsim1`, `bsim2`, `bsim3`, `bsource`, `bsource_i`, `cccs`, `ccvs`, `coupled_ltra` (and its `coupled_ltra3`, `coupled_ltra4` variants), `coupled_tlines`, `cswitch`, `diode`, `gummel_poon`, `hfet1`, `hfet2`, `isource`, `jfet`, `jfet2`, `kinduc`, `lossy_tline`, `ltra`, `mes`, `mesa`, `mos1`, `mos2`, `mos3`, `mos6`, `mos9`, `resistor`, `tline`, `txl`, `vccs`, `vcvs`, `vdmos`, `vsource`, `vswitch` |
| HiSIM licence (Hiroshima University, STARC) | `hisim2_va` |
| Not stated in the file; upstream (Dietmar Warning's VA-Models, through VACASK) is mostly ECL-2.0, see below | `vbic13_4t` |
| **CC-BY-NC 4.0** (Cogenda VA-BSIM48): **no commercial use** | `bsim4va` |

## Upstream releases

These are not in this directory: `build.zig` builds each from its upstream
release, unmodified, and `build.zig.zon` pins the release's download link and
hash. Each release ships its own licence file. Releases from si2's
registration form are mirrored byte for byte on the `models-si2-2026-10`
GitHub release, since the form's links expire.

| Licence | Models (release) |
|---|---|
| CMC in-code statement (NXP Semiconductors, Delft University of Technology, CEA): royalty-free; the code itself may not be sold; credit in product documentation | `psp103`, `psp103_nqs`, `psp103t`, `juncap200` (PSP 103.8.2, JUNCAP 200.6.2) |
| Same terms (NXP Semiconductors, Delft University of Technology, Auburn University) | `mextram`, `mextram_t` (Mextram 505.6.0) |
| ECL-2.0 (NXP Semiconductors, CEA) | `psp104`, `psp104_nqs`, `psp104t` (PSP 104.1.0) |
| ECL-2.0 (University of California) | `bsimimg` (BSIM-IMG 103.1.0), `bsimcmg` (BSIM-CMG 112.1.0), `bsimbulk` (BSIM-BULK 107.2.1), `bsimsoi_va` (BSIM-SOI 101.0.0) |
| ECL-2.0 (CEA-Leti) | `l_utsoi` (L-UTSOI 102.9.0) |
| ECL-2.0 (Hiroshima University) | `hisimhv_va` (HiSIM_HV 2.5.1), `hisimsoi` (HiSIM_SOI 1.5.0), `hisimsotb` (HiSIM_SOTB 1.3.0) |
| ECL-2.0 (HICUM group) | `hicumL2_va` (HICUM/L2 3.2.0), `hicumL0` (HICUM/L0 2.1.0) |
| ECL-2.0 (IIT Kanpur and others) | `asmhemt` (ASM-HEMT 101.6.0), `asmesd`, `asmesd_dio` (ASM-ESD 101.1.0) |
| ECL-2.0 (CMC) | `diode_cmc` (DIODE_CMC 3.0), `r2_cmc` (R2_CMC 1.0.2), `r3_cmc` (R3_CMC 1.1.2), `mvsg` (MVSG_CMC 5.0.0), `mosvar` (MOSVAR 1.4.0) |

## Read before redistributing

- `bsim4va` is non-commercial. Apache-2.0 lets anyone use ESPice
  commercially, but it cannot relicense this file: a commercial user must
  swap it for a commercially licensed BSIM4 (Berkeley's BSIM4 Verilog-A is
  one). It serves `LEVEL=54`/`14` decks, the sky130 decks and the BSIM4
  post-layout benches.
- `vbic13_4t` carries no licence notice in the file. Its source is VACASK's
  `devices/vbic/vbic_1p3.va`, which VACASK's README says comes from Dietmar
  Warning's VA-Models (github.com/dwarning/VA-Models). That repository's
  README puts most of its model code under ECL-2.0 (Educational Community
  License 2.0), with copyright per model directory; its vbic directory has
  no notice of its own, so the file's terms are stated nowhere closer than
  that README. Keep this provenance with any copy.
- The sky130 model slice under
  `tests/fixtures/regression/ota_buffer_large_step.assets/` is Apache-2.0
  (SkyWater PDK); its README there says so.
