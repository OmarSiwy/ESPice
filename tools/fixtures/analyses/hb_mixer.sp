* Harmonic Balance Analysis — Single-balanced Diode Mixer
*
* HB finds frequency-domain steady state for nonlinear RF circuits
* Syntax: .hb fund=<freq> nharm=N (hspice extension)
* LO at 900MHz, RF at 901MHz -> IF at 1MHz
*
VLO lo 0 SIN(0 0.5 900Meg)
VRF rf 0 SIN(0 0.01 901Meg)
*
* Balun (transformer) - simplified as coupled inductors
LLO_p lo_p 0 10n
LLO_s lo_s1 lo_s2 10n
K1 LLO_p LLO_s 0.99
*
* Diode quad mixer (simplified single-balanced)
D1 rf lo_s1 DMOD
D2 lo_s2 rf DMOD
*
* IF bandpass filter
LIF if 0 10u
CIF if 0 2.8p
RIF if 0 50
*
.model DMOD D (IS=1E-14 N=1.05 RS=5 CJO=0.1P TT=10P)
*
.options noacct
.op
* HB: LO fundamental 900MHz, 10 harmonics
.hb fund=900Meg nharm=10
.print HB V(if)
.END
