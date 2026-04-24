* Simplified Flyback Converter with Coupled Inductors
*
* Primary side: VIN=12V, NMOS switch, primary inductor L1
* Secondary side: diode, secondary inductor L2, output cap, load
* Coupled via K statement (k=0.95, turns ratio ~1:2 for voltage step-up)
* Switching at 100kHz (period=10us, duty~40%)

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.MODEL DMOD D (IS=1e-14 N=1.05 RS=10 BV=100 IBV=100u CJO=2p TT=5n)

* Input supply
VIN vin 0 DC 12

* Primary winding: vin -> drain of MOSFET through L1
* Dot convention: current into dotted terminal
L1 vin drain 100u

* NMOS switch
V_GATE gate 0 PULSE(0 10 0 10n 10n 3.99u 10u)
M1 drain gate 0 0 NMOD W=5000u L=1u

* Secondary winding (coupled to L1)
* Secondary has higher inductance for step-up (turns ratio squared)
L2 sec_dot sec_out 400u

* Coupling coefficient
K1 L1 L2 0.95

* Secondary diode (rectifier)
D1 sec_out out DMOD

* Secondary ground reference (isolated, but we tie to same ground for simplicity)
R_sec_gnd sec_dot 0 0.001

* Output filter cap and load
C_out out 0 10u IC=24
R_load out 0 100

* Snubber on primary (protects MOSFET from leakage inductance spike)
R_snub drain snub_mid 100
C_snub snub_mid 0 1n

.IC V(out)=24

.TRAN 0.1u 200u UIC

.END
