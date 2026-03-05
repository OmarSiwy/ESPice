* Rectifier startup, diode commutation and charge storage
* Expected results: bridge_capacitor_transient.expected.json
Vin in 0 SIN(0 10 1k)
Rsrc in acp 10
D1 acp vp dm
D2 0 vp dm
D3 vn acp dm
D4 vn 0 dm
Rload vp vn 1k
Cload vp vn 1u
Rcm1 vp 0 1meg
Rcm2 vn 0 1meg
.model dm D(is=1e-14 rs=.1)
.tran .2u 5m 0 .2u
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
