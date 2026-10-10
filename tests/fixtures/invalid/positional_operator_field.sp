* A field that starts with an operator is refused by name (#200): ngspice-45
* fails 'R1 a 0 10 %3' with "unknown parameter (%3)" (INPgetTok keeps `%3`
* one token, and no R parameter is named so). The legal neighbour is
* 'R1 a 0 10%3', which ngspice reads as 10 (syntax/ngspice_mod_idiv.sp).
V1 a 0 1
R1 a 0 10 %3
.op
.end
