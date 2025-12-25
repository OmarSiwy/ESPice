* STB fixture: BJT shunt-feedback stage, device-level loop probe.
Vcc vcc 0 DC 12
Rc vcc c 4.7k
Rf c bp 47k
Vprb bp b DC 0
Q1 c b 0 qn
.model qn NPN(bf=150 is=1e-15)
.stb Vprb dec 10 1 100meg
.end
