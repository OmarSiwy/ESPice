* SP fixture: 3rd-order Butterworth LC low-pass, 50 ohm, fc ~ 100 MHz.
* Expected results: bench_sp_lc_lowpass.expected.json
* Origin: benchmark/fixtures/sp/lc_lowpass/circuit.sp
VP1 in 0 DC 0 AC 1 portnum 1 z0 50
C1 in 0 31.8p
L1 in out 159n
C2 out 0 31.8p
VP2 out 0 DC 0 portnum 2 z0 50
.sp dec 20 1meg 1g
.end
