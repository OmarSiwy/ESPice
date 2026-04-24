Diode Circuit Netlist
********************************************************************************
* Tier No.:  2
* Directory/Circuit Name: DIODE/DIODE.cir
* Description:  Simple diode circuit to test the validity of the diode model.
* Input:  VIN
* Output: V(3), I(VMON)
* Analysis:
*      Vd=0.6158V  and Id=2.19mA
*******************************************************************************
VIN 1 0 PULSE ( 5 -1 0.05ms 100ns 100ns 0.1ms 0.2ms )
R1 1 2 2K
D1 3 0 DMOD
VMON 2 3 0
.MODEL DMOD D (IS=100FA)
.TRAN 0 0.5ms
.options timeint reltol=1.0e-4
.PRINT TRAN I(VMON) V(3) {V(3)/I(VMON)}
.END
