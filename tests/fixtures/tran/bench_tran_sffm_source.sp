* SFFM stimulus into an RC: single-frequency FM, the last independent-source
* Expected results: bench_tran_sffm_source.expected.json
* Origin: benchmark/fixtures/tran/sffm_source/circuit.sp
* waveform nothing in the suite exercised. PULSE, SIN and PWL are each covered
* several times over; EXP (tran/exp_source) and this one were not covered at all.
*
* The oracle is ngspice 44.2's run of this deck. ngspice reads the card as
* SFFM(VO VA FM MDI FC), modulating frequency third and carrier fifth, and
* limits MDI to FC/FM (vsrcload.c:235-259, "MDI in v1 limited to FC/FM"),
* so it simulates a 10 kHz carrier modulated at 100 kHz with MDI = 0.1:
*
*     v(t) = VO + VA * sin(2*pi*FC*t + MDI * sin(2*pi*FM*t))
*
* espice (models/vsource.va) reads the card the same way.
V1 in 0 SFFM(0 1 100k 2 10k)
R1 in out 1k
C1 out 0 1n
.tran 100n 200u
.end
