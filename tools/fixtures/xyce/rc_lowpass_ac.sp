Simple RC circuit
**********************************************************************
* AC analysis of a simple RC low-pass filter.
**********************************************************************
Isrc 1 0 AC 1 0 sin(0 1 1e+5 0 0)
R1 1 0 1e3
C1 1 0 2e-6

.print ac v(1)
.AC DEC 10 1 1e5 
.END
