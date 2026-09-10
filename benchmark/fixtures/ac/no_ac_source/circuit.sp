* AC fixture: no card names AC, so nothing drives the circuit and the whole
* response is zero. ngspice loads acReal = acImag = 0 for such a source
* (vsrcacld.c:171) — the V card stays an AC short, not an implicit 1 V poke.
V1 a 0 DC 1
R1 a b 1k
R2 b 0 1k
C1 b 0 1u
.ac dec 2 1k 10k
.end
