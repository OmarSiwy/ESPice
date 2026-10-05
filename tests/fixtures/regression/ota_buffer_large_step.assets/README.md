`sky130_fet01v8_tt.spice` is a subset of the SkyWater sky130A PDK
(Copyright 2020 The SkyWater PDK Authors, Apache License 2.0), shared by
`ota_buffer_large_step.sp` and `ota_buffer_large_step_0p88.sp`. It holds what
the `tt` section of `libs.tech/ngspice/sky130.lib.spice` defines for
`sky130_fd_pr__nfet_01v8` and `sky130_fd_pr__pfet_01v8`, cut to the bins the
decks' geometries select (nfet W/L 6.99/0.5, 0.54/0.3, 0.42/0.3; pfet
2.61/0.5):

- `.option scale=1.0u`, `mc_mm_switch = mc_pr_switch = 0`,
  `parameters/lod.spice` and the 01v8 `dlc_rotweak` parameters (all.spice);
- `sky130_fd_pr__{n,p}fet_01v8__mismatch.corner.spice` and
  `sky130_fd_pr__pfet_01v8__tt.corner.spice` parameters;
- the `sky130_fd_pr__nfet_01v8` and `sky130_fd_pr__pfet_01v8` subcircuits of
  `sky130_fd_pr__{n,p}fet_01v8__tt.pm3.spice`, with only the `.model` bins whose
  lmin..lmax and wmin..wmax hold those geometries (6 nfet, 2 pfet).

Comments are dropped; every kept line is as the PDK wrote it. ngspice 45
writes a bit-identical v(out) for the 0.7 -> 1.2 V deck with this file and with
`.lib sky130.lib.spice tt` (sky130A 8afc8346).
