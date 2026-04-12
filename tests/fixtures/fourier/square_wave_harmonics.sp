* Square Wave Fourier Decomposition
*
* PULSE source generates square wave at 100kHz
* Resistive divider passes signal to output
* .FOUR extracts harmonic content
* Expected: fundamental + odd harmonics (3rd, 5th, 7th, 9th)
* Amplitudes: 4/(n*pi) for nth harmonic of ideal square wave

V1 in 0 PULSE(-1 1 0 1n 1n 5u 10u)
R1 in out 1k
R2 out 0 1k

.TRAN 0.1u 100u
.FOUR 100k V(out)

.END
