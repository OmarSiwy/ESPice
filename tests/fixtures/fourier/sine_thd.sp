* Sine Wave THD Through Diode Clipper
*
* Pure sine input (1MHz, 2V peak) clipped by back-to-back diodes
* Clipping generates harmonics — THD depends on clipping level
* .FOUR extracts harmonic distortion content
* Expected: significant 3rd, 5th harmonics from symmetric clipping

V1 in 0 SIN(0 2 1MEG)
R1 in out 1k
D1 out 0 DMOD
D2 0 out DMOD

.MODEL DMOD D (IS=1e-14)

R2 out 0 10k

.TRAN 10n 20u
.FOUR 1MEG V(out)

.END
