* Bypass fixture: 3-edge burst then long idle — 95% of the run is latent.
* KNOWN GAP: nonzero transient output-start time is rejected by the dispatcher.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: bench_bypass_burst_clock.expected.json
* Origin: benchmark/fixtures/bypass/burst_clock/circuit.sp
Vin in 0 DC 0 PWL(0 0 0.1u 5 1u 5 1.1u 0 2u 0 2.1u 5 3u 5 3.1u 0 100u 0)
R1 in a 1k
C1 a 0 10n
Da a clamp dm
Vclamp clamp 0 DC 3
R2 a b 10k
C2 b 0 10n
.model dm D(is=1e-14)
.tran 50n 100u
.end
