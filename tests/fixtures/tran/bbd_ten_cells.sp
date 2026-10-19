* BBD regression: ten single-RC subcircuit instances on one shared input make
* the block-bordered-diagonal LU apply (>= 8 small blocks); its factor used to
* read the solver's trash value slot (bbd.zig assert, memory corruption in Release).
* Oracle: analytic ramp response of each RC at t = 1.5 ns.
* Expected results: bbd_ten_cells.expected.json
.subckt cell in out r=1k c=1p
r1 in out {r}
c1 out 0 {c}
.ends
vin in 0 pulse(0 1 0 10p 10p 10n 20n)
x0 in o0 cell r=1000 c=1p
x1 in o1 cell r=1100 c=1p
x2 in o2 cell r=1200 c=1p
x3 in o3 cell r=1300 c=1p
x4 in o4 cell r=1400 c=1p
x5 in o5 cell r=1500 c=1p
x6 in o6 cell r=1600 c=1p
x7 in o7 cell r=1700 c=1p
x8 in o8 cell r=1800 c=1p
x9 in o9 cell r=1900 c=1p
.tran 1p 2n
.meas tran v0 find v(o0) at=1.5n
.meas tran v1 find v(o1) at=1.5n
.meas tran v2 find v(o2) at=1.5n
.meas tran v3 find v(o3) at=1.5n
.meas tran v4 find v(o4) at=1.5n
.meas tran v5 find v(o5) at=1.5n
.meas tran v6 find v(o6) at=1.5n
.meas tran v7 find v(o7) at=1.5n
.meas tran v8 find v(o8) at=1.5n
.meas tran v9 find v(o9) at=1.5n
.end
