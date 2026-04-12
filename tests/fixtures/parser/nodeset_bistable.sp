* Parser Test — .NODESET initial node voltages
*
* .nodeset provides initial voltage hints to the DC solver
* to select the desired operating point in bistable circuits
* Without nodeset a latch may converge to either state
*
VDD vdd 0 DC 5
*
* RS latch using cross-coupled NOR gates (BJT implementation)
Q1 c1 b1 0 QMOD
Q2 c2 b2 0 QMOD
RC1 vdd c1 4.7k
RC2 vdd c2 4.7k
RB1 c2 b1 10k
RB2 c1 b2 10k
*
.model QMOD NPN (IS=1E-14 BF=100 VAF=100 RC=5 RB=50 RE=1)
*
* Steer latch to Q=HIGH state (c1 low, c2 high)
.nodeset V(c1)=0.2 V(c2)=4.8 V(b1)=0.1 V(b2)=0.65
*
.options noacct
.op
.print OP V(c1) V(c2)
.END
