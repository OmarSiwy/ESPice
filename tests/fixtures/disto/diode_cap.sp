* Diode with a junction capacitance: HD2/HD3 from the charge Taylor terms
* Expected results: diode_cap.expected.json
Vin in 0 DC .7 DISTOF1 0.01
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14 cjo=10p vj=0.7 m=0.5)
.disto dec 5 100k 1g
.end
