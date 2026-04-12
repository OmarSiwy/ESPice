* Parser Test — .GLOBAL node declaration
*
* .global declares nodes accessible across all subcircuits
* without explicit port connections — typically used for VDD/GND
*
.global vdd gnd
*
VDD vdd gnd DC 3.3
*
* Subcircuits reference global nodes directly
.subckt INVG in out
* Uses global vdd and gnd without port declaration
MP1 out in vdd vdd PMOD W=2u L=250n
MN1 out in gnd gnd NMOD W=1u L=250n
.ends INVG
*
.subckt BUF in out
Xinv1 in mid INVG
Xinv2 mid out INVG
.ends BUF
*
Vin in gnd DC 0 PULSE(0 3.3 1n 0.1n 0.1n 5n 10n)
Xbuf in out BUF
Rload out gnd 10k
*
.model NMOD NMOS LEVEL=1 VTO=0.5 KP=200u LAMBDA=0.01
.model PMOD PMOS LEVEL=1 VTO=-0.5 KP=80u LAMBDA=0.01
*
.options noacct
.tran 0.2n 30n
.print TRAN V(in) V(out)
.END
