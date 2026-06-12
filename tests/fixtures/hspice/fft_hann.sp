* HSPICE .fft with WINDOW=HANN, FORMAT=NORM, START=/STOP= [CR .FFT]. Oracle:
* the DFT of the exact samples 0.5 sin(2 pi 2k t) at t = 1m + 4m k/256,
* weighted by HSPICE's Hanning window 0.5 - 0.5 cos(2 pi n/(NP-1)) [SA
* Table 56], scaled by 2/sum(w), sine phase, normalized to the largest bin.
* Expected results: fft_hann.expected.json
vin out 0 sin(0 0.5 2k)
r1 out 0 1k
.tran 1u 6m
.fft v(out) start=1m stop=5m np=256 window=hann
.end
