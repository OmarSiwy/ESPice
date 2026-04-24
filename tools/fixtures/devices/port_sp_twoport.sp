* Two-port Network — AC analysis (ngspice)
*
* ngspice does not support the P (port) element.
* Equivalent circuit: voltage source at port 1, 50-ohm source resistance,
* series 25-ohm network element, 50-ohm load at port 2.
* This models the same resistive two-port as the original P-element netlist.
*
Vin in 0 AC 1
RS  in p1 50
R1  p1 p2 25
RL  p2 0  50
*
.options noacct
.ac DEC 10 1MEG 1GHz
.print AC V(p1) V(p2)
.END
