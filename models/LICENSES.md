# Model licences

ESPice's own code is Apache-2.0 (`../LICENSE`). The Verilog-A models in this
directory keep the licence of the code they come from. Each file's header
carries its notice; this page is the index.

| Licence | Models |
|---|---|
| Apache-2.0 (written for ESPice) | `bsource_q`, `capacitor`, `inductor`, `sparam_1`-`sparam_4`, `vccs_delay`, `vccs_laplace`, `vccs_pole`, `vcvs_delay`, `vcvs_laplace`, `vcvs_pole`, `wline_1`-`wline_4` |
| BSD-3-Clause: ngspice / SPICE3, Copyright Regents of the University of California and others | `b3soidd`, `b3soifd`, `bsim1`, `bsim2`, `bsim3`, `bsource`, `bsource_i`, `cccs`, `ccvs`, `coupled_ltra` (and its `coupled_ltra3`, `coupled_ltra4` variants), `coupled_tlines`, `cswitch`, `diode`, `gummel_poon`, `hfet1`, `hfet2`, `isource`, `jfet`, `jfet2`, `kinduc`, `lossy_tline`, `ltra`, `mes`, `mesa`, `mos1`, `mos2`, `mos3`, `mos6`, `mos9`, `resistor`, `tline`, `txl`, `vccs`, `vcvs`, `vdmos`, `vsource`, `vswitch` |
| PSP licence (CEA, NXP Semiconductors, Delft University of Technology): perpetual, royalty-free, notice must be kept | `psp103`, `psp103_nqs` |
| HiSIM licence (Hiroshima University, STARC) | `hisim2_va`, `hisimhv_va` |
| HICUM licence (Michael Schroter): perpetual, royalty-free, notice must be kept | `hicumL2_va` |
| BSIM-SOI licence (University of California): perpetual, royalty-free, notice must be kept | `bsimsoi_va` |
| Not stated in the file; upstream (Dietmar Warning's VA-Models, through VACASK) is mostly ECL-2.0, see below | `vbic13_4t` |
| **CC-BY-NC 4.0** (Cogenda VA-BSIM48): **no commercial use** | `bsim4va` |

## Read before redistributing

- `bsim4va` is non-commercial. Apache-2.0 lets anyone use ESPice
  commercially, but it cannot relicense this file: a commercial user must
  swap it for a commercially licensed BSIM4 (Berkeley's BSIM4 Verilog-A is
  one). It serves `LEVEL=54`/`14` decks, the sky130 decks and the BSIM4
  post-layout benches.
- `psp103_nqs` is `psp103` compiled with the NQS model; its file carries the
  same CMC notice as `psp103.va`.
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
