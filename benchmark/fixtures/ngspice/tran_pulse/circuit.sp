* PULSE waveform driving an RC: standard ngspice transient source form.
Vin in 0 PULSE(0 5 1u 100n 100n 5u 12u)
R1 in out 2k
C1 out 0 1n
.tran 0.1u 36u
.end
