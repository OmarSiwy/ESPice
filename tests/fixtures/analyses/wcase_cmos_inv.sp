* Worst-Case Corner Analysis — CMOS Inverter
*
* .wcase sweeps model parameters to worst-case corners
* hspice syntax: .wcase <analysis> <output> <function>
* Also demonstrates .corners / process corner approach
*
VDD vdd 0 DC 1.8
Vin in 0 DC 0.9
MN1 out in 0 0 NMOD W=1u L=180n
MP1 out in vdd vdd PMOD W=2u L=180n
*
* Typical corner models
.model NMOD NMOS LEVEL=1 VTO=0.4 KP=270u LAMBDA=0.01 TNOM=27
.model PMOD PMOS LEVEL=1 VTO=-0.4 KP=90u LAMBDA=0.01 TNOM=27
*
.options noacct
.op
.dc Vin 0 1.8 0.05
.print DC V(out) I(VDD)
*
* hspice worst-case analysis directive
* .wcase dc V(out) ymax
* Corners: ff (fast-fast), ss (slow-slow), fs, sf, tt
.wcase dc V(out) ymax reltol=0.01
.END
