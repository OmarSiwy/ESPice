* HSPICE forbids an exponent and a scale factor in one number (#203):
* UG08 p. 49 (dev/research/hspice-syntax.md T3), "not both". ESPice refuses
* the deck by name instead of reading 1e3k as 1e6. Legal neighbours: 1e6
* and 1meg.
v1 a 0 1
r1 a 0 1e3k
.op
.end
