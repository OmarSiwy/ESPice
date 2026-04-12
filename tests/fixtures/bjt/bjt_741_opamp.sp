* Simplified UA741-Style Opamp (Subcircuit) with Inverting Amplifier Test
*
* Input diff pair (Q1/Q2 PNP), active load (Q3/Q4 NPN mirror)
* Gain stage (Q5 NPN CE with Q6 current source)
* Output stage (Q7/Q8 push-pull emitter followers)
* Compensation cap 30pF
*

.SUBCKT UA741 INP INN OUT VCC VEE

* --- Bias current source ---
* Q9 generates ~20uA bias current
RBIAS1 VCC nbias 500k
Q9 nbias nbias VEE NPN1

* --- Input differential pair (PNP) ---
* Q1, Q2: PNP input pair
* Tail current from Q10
Q10 tail nbias VEE NPN1
RTAIL VCC tail 10k

Q1 col1 INP tail PNP1
Q2 col2 INN tail PNP1

* --- Active load (NPN current mirror) ---
Q3 col1 col1 VEE NPN1
Q4 col2 col1 VEE NPN1

* --- Gain stage (CE amplifier Q5 with current source Q6) ---
Q5 col5 col2 VEE NPN1
Q6 VCC col5 n6e PNP1
R6E n6e VEE 50k

* Compensation capacitor (Miller)
CC col2 col5 30p

* --- Output stage (push-pull emitter followers) ---
* Q7 NPN sourcing, Q8 PNP sinking
RBIAS2 VCC nb7 20k
RBIAS3 nb8 VEE 20k
Q11 nb7 col5 nb8 NPN1

Q7 VCC nb7 OUT NPN1
Q8 VEE nb8 OUT PNP1

* Output current limit resistors
RLIM1 VCC nb7 100
RLIM2 nb8 VEE 100

.ENDS UA741

* --- BJT Models ---
.MODEL NPN1 NPN (BF=100 IS=1e-15 VAF=100 RB=10 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.3n TR=6n)
.MODEL PNP1 PNP (BF=80 IS=1e-15 VAF=80 RB=15 RC=1 RE=0.5 CJE=2p CJC=1p TF=0.5n TR=8n)

* --- Test Circuit: Inverting Amplifier ---
VCC vcc 0 DC 15
VEE vee 0 DC -15
VIN in 0 DC 0 AC 1

* Inverting configuration: gain = -Rf/R1 = -100k/10k = -10
R1 in inv 10k
RF inv out 100k

* Non-inverting input to ground
X1 0 inv out vcc vee UA741

.OP
.AC DEC 20 1 100MEG

.END
