* SFFM stimulus into an RC: single-frequency FM, the last independent-source
* Expected results: bench_tran_sffm_source.expected.json
* Origin: benchmark/fixtures/tran/sffm_source/circuit.sp
* waveform nothing in the suite exercised. PULSE, SIN and PWL are each covered
* several times over; EXP (tran/exp_source) and this one were not covered at all.
*
* For SFFM(VO VA FC MDI FS) the defining formula is
*
*     v(t) = VO + VA * sin(2*pi*FC*t + MDI * sin(2*pi*FS*t))
*
* and the oracle is that closed form (v(out) the RC driven by it). ngspice
* 44.2 cannot be the reference: it emits a clean 10 kHz sinusoid for this
* card, the MODULATING frequency as the carrier with no modulation on it, and
* disagrees with the closed form, with espice and with VACASK alike
* (comma-separated and fully-expanded argument forms give the same output).
V1 in 0 SFFM(0 1 100k 2 10k)
R1 in out 1k
C1 out 0 1n
.tran 100n 200u
.end
