* Parser Test — .POLY polynomial controlled source (SPICE2 style)
*
* E element with POLY(N) keyword:
*   Exxx out 0 POLY(1) vin 0 p0 p1 p2 ...
*   Vout = p0 + p1*Vin + p2*Vin^2 + ...
*
* This implements a 2nd-order transfer: Vout = 0 + 1*Vin + 0.1*Vin^2
*
Vin in 0 DC 2
*
* Linear + quadratic gain: Vout = Vin + 0.1*Vin^2
Epoly out 0 POLY(1) in 0 0 1 0.1
Rload out 0 10k
*
* Two-input polynomial: Vout = V1 + V2 (adder)
V1 a 0 DC 1
V2 b 0 DC 1.5
Eadd sum 0 POLY(2) a 0 b 0 0 1 1
Rsum sum 0 10k
*
.options noacct
.op
.dc Vin 0 5 0.5
.print DC V(in) V(out) V(sum)
.END
