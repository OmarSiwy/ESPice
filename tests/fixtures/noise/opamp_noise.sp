* Opamp Input-Referred Noise — BJT Differential Pair Opamp
*
* Simple BJT opamp subcircuit (diff pair + current mirror + output stage)
* Configured as inverting amplifier (gain = -10)
* Measures input-referred noise voltage spectral density
* Dominant noise sources: diff pair base shot noise, collector shot noise

.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)
.MODEL PNP1 PNP (BF=80 IS=1e-15 VAF=80 RB=15 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.5n TR=8n)

* Simple opamp subcircuit
.SUBCKT OPAMP inp inn out vcc vee

* Tail current source (1mA)
I_tail tail vee DC 1m

* Differential pair
Q1 c1 inp tail NPN1
Q2 c2 inn tail NPN1

* Active load (PNP current mirror)
Q3 c1 c1 vcc PNP1
Q4 c2 c1 vcc PNP1

* Output stage: common-emitter with emitter degeneration
Q5 vcc c2 out_int NPN1
R_out out_int vee 5k

* Output buffer
R_ob out_int out 100
C_comp c2 out 10p

.ENDS OPAMP

* Supplies
VCC vcc 0 DC 12
VEE vee 0 DC -12

* Input signal
VIN in 0 DC 0 AC 1

* Inverting amplifier configuration (gain = -R2/R1 = -10)
R1 in inv 1k
R2 inv out 10k

* Non-inverting input to ground
X1 0 inv out vcc vee OPAMP

.NOISE V(out) VIN DEC 20 1 100MEG

.END
