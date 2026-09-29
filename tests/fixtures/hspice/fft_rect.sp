* HSPICE .fft [CR .FFT; SA Ch.15], rectangular window, FORMAT=UNORM:
* the plot holds every bin from DC to NP/2. Oracle: analytic, a 1 V sine
* at 1 kHz over exactly ten periods lands in bin 10 (100 Hz bins) with
* amplitude 1 and sine phase 0; DC and bin 30 are empty.
* Expected results: fft_rect.expected.json
vin out 0 sin(0 1 1k)
r1 out 0 1k
.tran 1u 10m
.fft v(out) np=1024 format=unorm
.end
