Diode clipper in periodic steady state
* A 1 kHz, 1 V sine drives a diode clipper. AC 1 is the small signal
* that .pac moves through the periodically switching circuit.
V1 in 0 DC 0 AC 1 SIN(0 1 1k)
R1 in out 1k
D1 out 0 dmod
C1 out 0 10n
.model dmod D(IS=1e-14)
.pss 1k 256
.pac 1k dec 4 10 10k
.hb 1k 8
.end
