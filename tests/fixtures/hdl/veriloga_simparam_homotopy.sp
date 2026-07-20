* $simparam("gmin"/"sourceScaleFactor") after the stepping rungs: G = 1e-6*1e6 + 1 = 2 S
* Expected results: veriloga_simparam_homotopy.expected.json
* va_expd has no $limit, so plain Newton fails and the stepping rungs
* write both knobs; the answer must see them restored.
.hdl "veriloga_simparam_homotopy.assets/va_ghom.va"
.hdl "veriloga_simparam_homotopy.assets/va_expd.va"
.options gmin=1e-6
N1 out 0 va_ghom
R1 in out 1
Vin in 0 DC 1.2
V2 a 0 DC 5
R2 a d 1k
N2 d 0 va_expd
.op
.end
