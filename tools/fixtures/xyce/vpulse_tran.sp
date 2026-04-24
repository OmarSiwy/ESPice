Netlist to Test the Xyce Pulse Voltage Source Model
*********************************************************************
* Tier No.:	1                                           
* Description:	Test of Xyce model for a pulse voltage source.
*		Sawtooth waveform rising from 0V to 1V in 10us.
********************************************************************** 
VPULSE 1 0 PULSE(0V 1V 0S 10US 10US 0.1US 20.1US)
R 1 0 500
.TRAN 1US 20.1US
.PRINT TRAN V(1)
.END
