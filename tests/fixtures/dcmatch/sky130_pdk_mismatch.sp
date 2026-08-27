* .dcmatch with no .variation block reads the mismatch the PDK states in its
* model cards (#100): sky130's MC_MM_SWITCH*AGAUSS(0,1,1)*slope/sqrt(l*w*mult)
* on vth0, toxe and voff, one group per draw.
* Oracle: ngspice 45 (nixpkgs), same circuit and models, 4000 runs of
* reset + op in a .control loop: stddev v(g) = 2.3819 mV (standard error
* 1.1 %), so total_3sigma = 7.146 mV. The linearization error at a 1.5 mV
* vth0 sigma is well under the tolerance.
* Expected results: sky130_pdk_mismatch.expected.json
.include '../regression/ota_buffer_large_step.assets/sky130_fet01v8_tt.spice'
.param mc_mm_switch=1
ib 0 g 10u
xm g g 0 0 sky130_fd_pr__nfet_01v8 w=6 l=0.8
.dcmatch v(g)
.end
