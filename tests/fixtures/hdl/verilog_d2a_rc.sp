* Verilog D2A output ramp into an RC: the Thevenin driver (rout = 1 kohm)
* ramps its level like transition() with trise = 4 ns and tfall = 2 ns, into
* C1 = 1 pF (tau = 1 ns), so the capacitor voltage shows the ramp
* Expected results: verilog_d2a_rc.expected.json
* Oracle (analytic): a linear source ramp of slope S from V0 over T into an
* RC low-pass gives v(s) = V0 + S (s - tau (1 - exp(-s/tau))) for s <= T,
* then an exponential settle to the final level with time constant tau.
* Rise: 0 -> 5 V over 4 ns from 10 ns; fall: from v(60 ns) to 0 over 2 ns
* from 60 ns. Both event times land exactly (pendingBreakpoint).
.hdl "verilog_d2a_rc.assets/v_pulse.v"
N1 y pm
.model pm v_pulse rout=1k trise=4n tfall=2n
C1 y 0 1p
.tran 0.1n 70n
.end
