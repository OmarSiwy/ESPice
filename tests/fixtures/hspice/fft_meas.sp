* HSPICE .measure FFT [CR .MEASURE FFT; SA Ch.15]: THD, SNR, SNDR, ENOB,
* SFDR and FIND vm(..) AT= over the .fft spectrum. Oracle: analytic, a
* 1 V fundamental at 1 kHz, a 10 mV third harmonic and a 1 mV spur at
* 1.5 kHz, all on 100 Hz bins: THD = 0.01, SNR = 60 dB, SNDR =
* 10 log10(1/(1e-4 + 1e-6)) = 39.9568 dB, ENOB = (SNDR - 1.76)/6.02 =
* 6.34498, SFDR = 40 dB, and vm(out) at 3 kHz = 0.01 (normalized).
* Expected results: fft_meas.expected.json
v1 a 0 sin(0 1 1k)
v2 b a sin(0 0.01 3k)
v3 out b sin(0 0.001 1.5k)
r1 out 0 1k
.tran 1u 10m
.fft v(out) np=1024
.meas fft thd1 thd v(out)
.meas fft snr1 snr v(out)
.meas fft sndr1 sndr v(out)
.meas fft enob1 enob v(out)
.meas fft sfdr1 sfdr v(out)
.meas fft m3k find vm(out) at=3k
.end
