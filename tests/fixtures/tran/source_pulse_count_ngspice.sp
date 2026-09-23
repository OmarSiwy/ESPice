* PULSE's eighth argument is ngspice's pulse count (#73).
* Expected results: source_pulse_count_ngspice.expected.json
* Two 10 ns pulses every 20 ns, then 0: v(a) is 1 at 5n and 25n, 0 from 45n.
V1 a 0 PULSE(0 1 0 1n 1n 10n 20n 2)
R1 a 0 1k
.tran 1n 100n
.end
