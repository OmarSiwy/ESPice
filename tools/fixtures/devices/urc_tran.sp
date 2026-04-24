* Uniform Distributed RC Line (URC element) — transient test
*
* U element: Uxxx n1 n2 gnd MODNAME L=val [LUMPS=n]
* Models a distributed RC interconnect line
*
Vin in 0 PULSE(0 1 1n 0.1n 0.1n 10n 20n)
RS in n1 50
U1 n1 n2 0 URCMOD L=1000u
Rload n2 0 1MEG
*
.model URCMOD URC (K=1.2 FMAX=1G RO=1k CO=0.1P)
*
.options noacct
.tran 0.5n 50n
.print TRAN V(in) V(n1) V(n2)
.END
