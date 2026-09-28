* A resistor value naming no parameter and no model is an error, not
* ngspice's 1 mOhm default. ngspice 45 rejects it too ("unknown parameter").
* Expected results: unresolved_parameter.expected.json
v1 a 0 1
r1 a 0 rv
.op
.end
