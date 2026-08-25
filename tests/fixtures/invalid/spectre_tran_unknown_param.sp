Spectre tran refuses a parameter it does not map (#151)
// Expected results: spectre_tran_unknown_param.expected.json
v1 (a 0) vsource dc=1
r1 (a 0) resistor r=1k
t1 tran stop=1u bogusparam=3
