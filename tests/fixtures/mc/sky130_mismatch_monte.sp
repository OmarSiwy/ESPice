* sky130 nfet_01v8 local mismatch under a MONTE sweep (#100): the PDK states
* mismatch as MC_MM_SWITCH*AGAUSS(0,1,1)*slope/sqrt(l*w*mult) in its binned
* model cards (the tt_mm section sets mc_mm_switch=1). Each trial draws them
* per instance; before #100 the sweep ran nominal in every trial.
* Oracle: ngspice 45 (nixpkgs), the same circuit with mc_mm_switch=1, 1000
* runs of `reset` + `op` in a .control loop: Id at Vgs 0.7 V, Vds 0.9 V has
* mean 1.0545 uA and stddev 0.2805 uA. The generators differ, so only the
* statistics compare.
* Expected results: sky130_mismatch_monte.expected.json
.include '../regression/ota_buffer_large_step.assets/sky130_fet01v8_tt.spice'
.param mc_mm_switch=1
vg g 0 0.7
vd d 0 0.9
xm d g 0 0 sky130_fd_pr__nfet_01v8 w=0.42 l=0.3
.dc monte=1000
.end
