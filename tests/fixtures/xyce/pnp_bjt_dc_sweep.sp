PNP Bipolar Transistor Circuit Netlist
**************************************************************
* Tier No.:  2
* Description:  Common collector PNP configuration.
* Analysis:
* IE = {VCC - VEC}/RE = {5 - 2.5}/2E+3 = 1.25mA
* IC = {BETA/(1 + BETA)} * IE = 60/61 * 1.25E-3 = 1.23mA
* IB = IC/BETA = 1.23E-3/60 = 20.5uA
************************************************************** 
VPOS  1 0 DC 5V
VBB   6 0 DC -2V
RE    1 2 2K
RB    3 4 190K
Q 5 3 7 PBJT
VMON1 4 6 0
VMON2 5 0 0
VMON3 2 7 0 
.MODEL PBJT PNP (IS=100FA BF=60)
.DC VPOS 0 5 1 VBB 0 -2 -0.5
.PRINT DC V(1) V(6) I(VMON1) I(VMON2) I(VMON3)
.END
