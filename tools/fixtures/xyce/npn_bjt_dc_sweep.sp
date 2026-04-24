NPN Bipolar Transistor Circuit Netlist
**************************************************************
* Tier No.: 1                                               
* Description:   Circuit netlist to determine the current-volt-
*                age characteristics of the Xyce npn bipolar 
*                transistor model. Common-emitter configuration.
* Analysis:	
* IB = {VCC - VBE} / RB = {12 - 0.7} / 377E+3 = 29.9uA
* IC = BETA * IB = 100 * 29.9E-6 = 2.99mA
* VCE = VCC - IC*RC = 12 - (2.99E-3)*(2E+3) = 6.01V 
************************************************************** 
VCC  4 0 DC 12V
RC 3 4 2K
RB 4 5 377K
VMON1 5 1 0
VMON2 3 2 0
Q 2 1 0 NBJT
.MODEL NBJT NPN (BF=100)
.DC VCC 0 12 1
.PRINT DC V(4) I(VMON1) I(VMON2) V(1) V(2) 
.END
