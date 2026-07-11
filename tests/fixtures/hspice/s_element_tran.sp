* HSPICE S element in the time domain: the two-port of s_element.sp (same
* Touchstone file) driven by a 1 V pulse behind 50 ohm, loaded by 50 ohm.
* Expected results: s_element_tran.expected.json
* Oracle: ngspice-44.2 on the lumped network the data were computed from
* (series 10 ohm + 5 nH between the ports, 100 ohm at port 1, 25 ohm + 2 pF
* at port 2).
v1 in 0 pulse(0 1 0.1n 0.2n 0.2n 1n 10n)
rs in p1 50
s1 p1 p2 mname=smod
rl p2 0 50
.model smod s tstonefile=s_element.assets/net.s2p
.tran 1p 3n
.end
