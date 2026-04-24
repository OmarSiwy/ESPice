Netlist to Test the Xyce Sinusoidal Voltage Source Model
*********************************************************************
* Tier No.:	1                                           
* Description:	Sinusoidal voltage source test. Implements a cosine
*		signal via negative delay. 5V peak, 100KHz frequency.
********************************************************************** 
VCOS 1 0 SIN(0 5 100K -2.5U)
R 1 0 500
.TRAN 1US 10US
.PRINT TRAN V(1)
.END
