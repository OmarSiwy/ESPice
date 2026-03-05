* PXF adjoint output-node current injection transfer
* KNOWN GAP: PXF reactive transfer must retain the physical complex phase; the current adjoint extraction conjugates it.
* This correctness test should currently fail; implement support to match the expected output.
* Expected results: divider.expected.json
Vin in 0 DC 0 AC 1 SIN(0 1 1k)
R1 in out 1000
R2 out 0 3000
.pxf 1k dec 4 10 10k
.end
