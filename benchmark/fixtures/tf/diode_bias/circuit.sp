* TF fixture: small-signal transfer through a forward-biased diode divider.
Vin in 0 DC 5
R1 in out 1k
D1 out 0 dm
.model dm D(is=1e-14 n=1.8)
.tf V(out) Vin
.end
