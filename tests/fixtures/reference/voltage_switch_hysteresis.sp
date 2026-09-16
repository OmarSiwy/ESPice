* Hysteretic switch thresholds and state retention
* Expected results: voltage_switch_hysteresis.expected.json
Vdd supply 0 1
Vc control 0 PWL(0 -2 1m 2 2m -2 3m 2)
S1 supply out control 0 sm
R1 out 0 1k
.model sm SW(ron=1 roff=1meg vt=0 vh=.5)
.tran .2u 3m 0 .2u
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
