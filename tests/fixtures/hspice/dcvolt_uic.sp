* .dcvolt is HSPICE's .ic [CR .DCVOLT], in both the v(n)=value and the
* bare "node value" spellings. With UIC the capacitor starts at 1 V and
* discharges through 1k. Oracle: analytic, exp(-t / 1 us).
* Expected results: dcvolt_uic.expected.json
c1 a 0 1n
r1 a 0 1k
c2 b 0 1n
r2 b 0 1k
.dcvolt v(a)=1
.dcvolt b 2
.tran 10n 5u uic
.end
