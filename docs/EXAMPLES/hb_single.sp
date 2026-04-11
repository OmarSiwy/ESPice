* Single-Tone Harmonic Balance — Diode Mixer
*
* Demonstrates: .HB analysis, diode nonlinearity, harmonic content
*
* RF input at 900 MHz drives a series diode into a load.
* HB computes the steady-state harmonic spectrum up to the 7th harmonic,
* revealing rectification and harmonic generation in the diode.
*
* For a mixer add a second tone (LO): .HB tones=900MEG,1100MEG nharms=5

.MODEL DSCH D (IS=1e-14 N=1.1 RS=5)

Vrf   rfin  0  AC 0  SIN(0 0.5 900MEG)
Vbias rfin  0  DC 0.3

Rs    rfin  anode  50
D1    anode cathode  DSCH
Rload cathode  0    200

.HB  900MEG  nharms=7

.PRINT  HB  V(anode)  V(cathode)

.END
