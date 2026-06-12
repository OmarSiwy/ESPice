* HSPICE .snnoise ov insrc <sweep> [n1 +/-1] [CR .SNNOISE] runs as .pnoise
* at the .sn tone, in the n1 = 0 band. Oracle: pnoise/lti_rc_sidebands_7's,
* analytic LTI RC noise at 27 C (TNOM and TEMP pinned to it).
* Expected results: snnoise_rc.expected.json
Vin in 0 AC 1 SIN(0 1 1k)
R1 in out 1k
C1 out 0 1u
.option tnom=27
.temp 27
.sn tone=1k nharms=8
.snnoise v(out) Vin dec 3 10 10k 0 1
.end
