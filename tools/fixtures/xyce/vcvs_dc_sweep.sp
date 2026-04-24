Netlist to Test the Xyce Voltage-Controlled Voltage Source Model
******************************************************************************
* Tier No.:	1                                                             
* Description:	VCVS test using a voltage amplifier circuit.
* Analysis:
*   E = V(3) = 2 * VIN
*   V(2) = VIN * 0.9975
*   V(4) = VIN * 1.9231
*   Rin=100.25K, Rout=38.46, gain=1.923
****************************************************************************** 
VIN 1 0 10V
E 3 0 1 0 2V
R1 1 2 250
R2 2 0 100K
R3 3 4 40
R4 4 0 1K
.DC VIN 1 10 1
.PRINT DC V(1) V(2) V(3) V(4)
.END
