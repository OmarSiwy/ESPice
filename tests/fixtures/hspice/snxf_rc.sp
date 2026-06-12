* HSPICE .snxf v(out) <sweep> [CR .SNXF] runs as .pxf at the .sn tone.
* Oracle: pxf/rc's, analytic: the adjoint transfer of the LTI RC at
* sideband 0.
* Expected results: snxf_rc.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
R1 in out 1k
C1 out 0 1u
.sn tone=1k nharms=8
.snxf v(out) dec 4 10 10k
.end
