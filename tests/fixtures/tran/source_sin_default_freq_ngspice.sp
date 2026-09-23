* SIN without a frequency runs at 1/TSTOP (#73).
* Expected results: source_sin_default_freq_ngspice.expected.json
* FREQ = 1/1u = 1 MHz: v(a) = sin(2 pi t / 1u).
V1 a 0 SIN(0 1)
R1 a 0 1k
.tran 10n 1u
.end
