* sky130 OTA unity-gain buffer, 0.7 -> 1.2 V input step at 100 ns: BSIM4 Newton
* limiting (b4ld.c fetlim/limvds/pnjlim) keeps the transient operating point
* on the physical branch. Unlimited, the TIGHT options' operating point
* (reltol=1e-4) converged on a spurious equilibrium of the zero-junction-area
* model, V(out) = -17.6 V in the x86_64-linux-gnu build, and the transient crawled from there.
* Origin: AnalogIOC analog/ota/test/tb_ota.py buffer(), SpiceRack netlist,
* subcircuit inlined; models are the sky130A tt bins it selects (assets/README).
* Oracle: ngspice 45 on this deck. tsettle is the last crossing of the
* 0.5 % band edge (final - 2.5 mV) after the step; the response is monotone.
* Expected results: ota_buffer_large_step.expected.json
.include 'ota_buffer_large_step.assets/sky130_fet01v8_tt.spice'
.subckt ota inp inn out vb_nc vb_pc vb_tail vdd vss
Xtail ts vb_tail vss vss sky130_fd_pr__nfet_01v8 W=6.99 L=0.5
Xin_p d1 inp ts vss sky130_fd_pr__nfet_01v8 W=0.54 L=0.3
Xin_n d2 inn ts vss sky130_fd_pr__nfet_01v8 W=0.54 L=0.3
Xnc_l x1 vb_nc d1 vss sky130_fd_pr__nfet_01v8 W=0.42 L=0.3
Xnc_r out vb_nc d2 vss sky130_fd_pr__nfet_01v8 W=0.42 L=0.3
Xpc_l x1 vb_pc y1 vdd sky130_fd_pr__pfet_01v8 W=2.61 L=0.5
Xpc_r out vb_pc y2 vdd sky130_fd_pr__pfet_01v8 W=2.61 L=0.5
Xpm_l y1 x1 vdd vdd sky130_fd_pr__pfet_01v8 W=2.61 L=0.5
Xpm_r y2 x1 vdd vdd sky130_fd_pr__pfet_01v8 W=2.61 L=0.5
.ends ota
Iref_tail vdd vb_tail 12u
Vrep_pm vdd rep_y 350m
Iref_pc vb_pc vss 6u
Vvb_nc vb_nc vss 1.251
Xxdut inp inn out vb_nc vb_pc vb_tail vdd vss ota
Xrep_tail vb_tail vb_tail vss vss sky130_fd_pr__nfet_01v8 W=6.99 L=0.5
Xrep_pc vb_pc vb_pc rep_y vdd sky130_fd_pr__pfet_01v8 W=2.61 L=0.5
Vsup vdd 0 1.8
Vss vss 0 0
Vin inp 0 0 PWL(0 0.7 100n 0.7 100.5n 1.2 250n 1.2)
Vfb out inn 0
Cl out 0 200f
.options reltol=0.0001 abstol=1e-12 vntol=1e-06 method=gear
.temp 27
.save V(out)
.tran 0.05n 250n
.meas tran vpre find v(out) at=99n
.meas tran vfinal find v(out) at=250n
.meas tran tsettle trig at=100n targ v(out) val=1.181044 cross=last
.end
