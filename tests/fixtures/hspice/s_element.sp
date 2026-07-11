* HSPICE S element, a two-port from Touchstone data of an analytic network:
* series 10 ohm + 5 nH between the ports, 100 ohm shunt at port 1, series
* 25 ohm + 2 pF shunt at port 2 (s_element.assets/net.s2p, 50 ohm, RI,
* 1 MHz to 10 GHz). Driven by 1 V behind 50 ohm, loaded by 50 ohm.
* Expected results: s_element.expected.json
* Oracle (analytic): node voltages of the lumped network. DC is the fit's
* H(0), exact here since the network is rational; AC is at the data points.
v1 in 0 dc 1 ac 1
rs in p1 50
s1 p1 p2 mname=smod
rl p2 0 50
.model smod s tstonefile=s_element.assets/net.s2p
.op
.ac dec 10 1meg 10g
.end
