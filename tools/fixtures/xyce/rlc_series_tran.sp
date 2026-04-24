Netlist to Test Xyce with RLC
*********************************************************************
* Tier No.:	1                                               
* Description: Solution verification circuit containing the linear 
*              resistor, capacitor, and inductor models implemented 
*              in Xyce. 
*	The solution is the zero state response of the circuit:
*	A DC voltage source in series with a 3 Ohm resistor,
*	a 1H inductor, and a .5F capacitor.
*********************************************************************** 
r1 1 2 3
l1 2 3 1
c1 3 0 .5
v1 1 0 10 pulse(0 10 0 0 0 10 10)

.tran  0.01 10 0
.print tran v(1) {i(v1)-1.0}
.options timeint reltol=1.0e-3
.end
