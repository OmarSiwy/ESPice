* AC Sweep — RC Low-Pass Filter
*
* Demonstrates: .AC DEC sweep, RC network, VDB/VP output
*
* First-order RC low-pass:
*   Vin -> R1 -> out -> C1 -> GND
*   -3 dB corner: f_c = 1 / (2*pi*R*C) = 1 / (2*pi*1k*100n) ≈ 1.592 kHz

Vlpf_in  in  0  DC 0  AC 1

R1  in   out  1k
C1  out  0    100n

.AC  DEC  20  100  1MEG

.PRINT  AC  VDB(out)  VP(out)

.END
