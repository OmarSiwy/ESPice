* Periodic Steady State Analysis — LC VCO
*
* PSS finds the steady-state waveform of a periodic circuit
* Syntax: .pss fund=<freq> [harms=N] [maxacfreq=F]
* (hspice/spectre extension; shown here in hspice syntax)
*
VDD vdd 0 DC 1.8
Vctrl ctrl 0 DC 0.9
*
* LC tank VCO (simplified)
* L-C resonator at ~1GHz: L=25nH, C=1pF
Ltank vdd out 25n
Ctank out 0 1p
*
* Active device (NMOS cross-coupled pair)
MN1 out ctrl 0 0 NMOD W=10u L=180n
MN2 ctrl out 0 0 NMOD W=10u L=180n
*
.model NMOD NMOS LEVEL=1 VTO=0.4 KP=270u LAMBDA=0.01
*
.options noacct
.op
* PSS: fundamental ~1GHz, 10 harmonics
.pss fund=1G harms=10 maxacfreq=10G errpreset=moderate
.print PSS V(out)
.END
