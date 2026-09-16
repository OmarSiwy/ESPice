* Emitter-degenerated BJT amplifier dc
* Expected results: bjt_emitter_degenerated_dc.expected.json
Vcc vcc 0 5
Vin drive 0 DC .8 AC 1
Rb drive base 10k
Rc vcc out 2k
Re emit 0 100
Q1 out base emit qm
.model qm NPN(is=1e-15 bf=150 vaf=80 cje=5p cjc=2p tf=.3n)
.dc Vin -.05 .05 .005
.options reltol=1e-6 abstol=1e-12 vntol=1e-8 method=gear temp=27 tnom=27
.end
