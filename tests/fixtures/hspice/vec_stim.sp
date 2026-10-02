* HSPICE .vec [CR .VEC; SA Ch.9 "Specifying a Digital Vector File"]:
* vec_stim.vec drives a and b[1], b[0] through PWL sources and checks y.
* Oracle: analytic. a holds 2.5 V (VIH), falls at 20n and rises at 30n
* over the 0.5 ns SLOPE; b = 2, 1, 3 gives b[1] 3.3, 0, 3.3 V and b[0] 0,
* 3.3, 3.3 V, each change 1 ns after its row (b[0] reads 1.65 V at
* 21.25n). y copies a and is compared 2 ns after each row against VTH
* 1.25 V: 1 at 12n, 0 at 22n, don't-care at 32n, and 0 at 37n where a is
* high: dout1_y = 1.
* Expected results: vec_stim.expected.json
.vec 'vec_stim.vec'
e1 y 0 a 0 1
r1 y 0 1k
.tran 0.1n 40n
.end
