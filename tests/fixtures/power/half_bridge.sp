* Half-Bridge Driver with Bootstrap Cap and Inductive Load
*
* Two NMOS: high-side (M1) and low-side (M2)
* Bootstrap capacitor C_boot charges through D_boot when low-side is ON
* Complementary gate drives at 100kHz
* VDD=12V, L_load=100uH, R_load=1 ohm

.MODEL NMOD NMOS (VTO=0.7 KP=110u GAMMA=0.4 PHI=0.65 LAMBDA=0.04)
.MODEL DMOD D (IS=1e-14 N=1.05 RS=10 BV=100 IBV=100u CJO=2p TT=5n)

* Power supply
VDD vdd 0 DC 12

* Bootstrap supply (represents charge pump / bootstrap diode path)
V_boot boot_pwr 0 DC 12
D_boot boot_pwr boot DMOD
C_boot boot sw 10u IC=12

* Gate drive: low-side (active during first half of period)
V_GL gl 0 PULSE(0 12 0 10n 10n 4.9u 10u)

* Gate drive: high-side (complementary, active during second half)
* Dead time of ~100ns between transitions
V_GH gh_ref 0 PULSE(0 12 5.1u 10n 10n 4.9u 10u)

* High-side gate is referenced to switch node
* Use behavioral source: V(gh) = V(sw) + V(gh_ref)
E_GH gh sw gh_ref 0 1

* High-side NMOS: drain=VDD, gate=gh, source=sw
M1 vdd gh sw sw NMOD W=1000u L=1u

* Low-side NMOS: drain=sw, gate=gl, source=GND
M2 sw gl 0 0 NMOD W=1000u L=1u

* Inductive load from switch node to ground (with freewheeling path)
L_load sw load_mid 100u
R_load load_mid 0 1

* Initial conditions
.IC V(sw)=0 V(boot)=12

.TRAN 0.1u 100u UIC

.END
