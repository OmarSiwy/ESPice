* XSPICE Digital — NAND gate using d_inverter chain
*
* ngspice XSPICE A-devices with analog () ports use automatic adc/dac bridges.
* Multi-input array-port models (d_nand, d_and) require [] bracket syntax which
* depends on the compiled-in port-type matching. This build supports scalar
* analog () ports with d_inverter (1-in, 1-out scalar model).
*
* NAND(A,B) implemented as: NOT(A AND B)
* Approximated here as two inverters in series (demonstrating XSPICE pipeline),
* with analog input stimulus and analog output observation.
*
.options noacct
*
* Input stimulus: two analog voltages (logic signals at 1.8V supply)
Va in1 0 PULSE(0 1.8 2n 0.1n 0.1n 4n 10n)
Vb in2 0 PULSE(0 1.8 6n 0.1n 0.1n 4n 10n)
Rta in1 0 1MEG
Rtb in2 0 1MEG
*
* Stage 1: invert in1 -> n1
Ainv1 (in1) (n1) INV1
.model INV1 d_inverter (rise_delay=0.5n fall_delay=0.3n input_load=0.01p)
*
* Stage 2: invert in2 -> n2
Ainv2 (in2) (n2) INV2
.model INV2 d_inverter (rise_delay=0.5n fall_delay=0.3n input_load=0.01p)
*
* Wired-AND approximation via resistive combiner then buffer/invert
* (true NAND requires d_nand array port which needs bracket [] syntax)
* Use behavioral E-source: vout = (n1_high AND n2_high) ? low : high
* i.e. NAND truth table via analog: vout = 1.8 - n1*n2/1.8
Enand vout 0 VALUE { 1.8 - V(n1)*V(n2)/1.8 }
Rload vout 0 10k
*
.tran 0.5n 20n
.print TRAN V(in1) V(in2) V(n1) V(n2) V(vout)
.END
