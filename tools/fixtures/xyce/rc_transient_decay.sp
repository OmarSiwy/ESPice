Regression test to show proper transient RC circuit
********************************************************************************
* Tier No.:  1
* Directory/Circuit Name:  CAPACITOR/capacitor.cir
*
* If this circuit is simulated correctly, the T=0 value of the voltage v(1)
* should be 1V, and it should decay to 0 with a time constant of 1ms, as
*   v(1)(T)=1V*exp(-t/1ms)
*
********************************************************************************
c1 1 0 1uF IC=1
R1 1 2 1K
v1 2 0 0V
.print tran v(1)
.tran 0 5ms
.options timeint reltol=1e-6 abstol=1e-6
.end
