* PXF adjoint output-node current injection transfer
* KNOWN GAP: PXF reactive transfer must retain the physical complex phase; the current adjoint extraction conjugates it.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: two_poles.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
R1 in a 1k
C1 a 0 1u
Ebuf b 0 a 0 1
R2 b out 1k
C2 out 0 1u
.pxf 1k dec 4 10 10k
.end
