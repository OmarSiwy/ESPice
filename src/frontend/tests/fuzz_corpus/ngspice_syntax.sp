* ngspice-flavoured netlist: trailing dollar comment and AC source spec.
* Expected results: ngspice_syntax.expected.json
* Origin: benchmark/fixtures/parser/ngspice_syntax/circuit.sp
Vin in 0 DC 0 AC 1 $ small-signal stimulus
R1 in out 1k
C1 out 0 1u
.ac dec 10 1 100k
.end
