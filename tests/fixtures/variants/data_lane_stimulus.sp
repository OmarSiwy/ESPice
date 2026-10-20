* Per-lane stimulus (#212): a .data table sweeps input selection x polarity
* of a 2:1 transmission-gate mux driving an inverter. sel picks the input
* that toggles, pol whether it rises (1) or falls (0); the other input holds
* 0 V. Input b passes a weaker gate and the inverter pulls up weaker than it
* pulls down, so the four rows measure differently. Only the pulse levels
* come from the .params: every row keeps the same delay, rise, fall, width
* and period, and a pulse with v1 = v2 still lands its edge breakpoints, so
* all points share one breakpoint set.
* tpd/tpd2: input 50 % (25p, 125p) to the first/second output crossing;
* slew: 20 % to 80 % of the first output edge, negative when it falls.
* Oracle: ngspice, each row run alone (sel and pol as plain .params).
* Expected results: data_lane_stimulus.expected.json
.param vdd=1 sel=0 pol=1
vdd vdd 0 'vdd'
vs s 0 'sel*vdd'
vsb sb 0 '(1-sel)*vdd'
va a 0 pulse('(1-sel)*(1-pol)*vdd' '(1-sel)*pol*vdd' 20p 10p 10p 90p 200p)
vb b 0 pulse('sel*(1-pol)*vdd' 'sel*pol*vdd' 20p 10p 10p 90p 200p)
mna m sb a 0 nm l=0.1u w=1u
mpa m s a vdd pm l=0.1u w=2u
mnb m s b 0 nm l=0.1u w=0.4u
mpb m sb b vdd pm l=0.1u w=0.8u
mn y m 0 0 nm l=0.1u w=1u
mp y m vdd vdd pm l=0.1u w=1.2u
cm m 0 5f
cl y 0 10f
.model nm nmos level=1 vto=0.3 kp=200u
.model pm pmos level=1 vto=-0.3 kp=100u
.data lanes sel pol
+ 0 1
+ 0 0
+ 1 1
+ 1 0
.enddata
.tran 1p 250p sweep data=lanes
.meas tran tpd trig at=25p targ v(y) val=0.5 cross=1
.meas tran tpd2 trig at=125p targ v(y) val=0.5 cross=2
.meas tran slew trig v(y) val=0.2 cross=1 targ v(y) val=0.8 cross=1
.end
