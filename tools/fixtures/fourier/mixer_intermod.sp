* Diode Mixer — Two-Tone Intermodulation Test
*
* Two sine sources at 1MHz and 1.01MHz (10kHz spacing)
* Single-diode mixer generates sum, difference, and intermodulation products
* IM3 products at 2*f1-f2 = 0.99MHz and 2*f2-f1 = 1.02MHz
* Fourier analysis at fundamental (1MHz) reveals harmonic structure

.MODEL DMOD D (IS=1e-14 N=1.05 RS=10 BV=100 IBV=100u CJO=2p TT=5n)

* Tone 1: 1 MHz, 0.5V peak
V1 tone1 0 SIN(0 0.5 1MEG)
R1 tone1 mix_in 50

* Tone 2: 1.01 MHz, 0.5V peak
V2 tone2 0 SIN(0 0.5 1.01MEG)
R2 tone2 mix_in 50

* Single-diode mixer
D1 mix_in mix_out DMOD

* Load and DC return
R_load mix_out 0 1k
C_out mix_out out 100p
R_out out 0 1k

.TRAN 10n 100u
.FOUR 1MEG V(out)

.END
