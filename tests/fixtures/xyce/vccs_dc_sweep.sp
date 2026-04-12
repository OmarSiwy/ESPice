Netlist to Test the Xyce Voltage Controlled Current Source Model
******************************************************************************
* Tier No.:	1                                                             
* Description:	VCCS test using a simple resistor circuit.
* Analysis:
*   V(2) = VIN * R2/(R1+R2) = VIN * 0.75
*   I_G  = k*V(2) = 0.02 * VIN * 0.75
*   V(3) = -(R3*VIN*0.0075) = -(VIN*1.5)
*   Rin=1200, Rout=100, V(3)/VIN=-1.5
****************************************************************************** 
VIN 1 0 DC 12V
G 3 0 2 0 0.02
R1 1 2 300
R2 2 0 900
R3 3 0 200
R4 3 0 200
.DC VIN 1 12 1
.PRINT DC V(1) V(2) V(3) 
.END
