* A stop frequency whose 2*pi*f overflows is refused at the card (#108).
* Expected results: ac_frequency_overflow.expected.json
Vin in 0 1 ac 1
R1 in out 1k
C1 out 0 1n
.ac dec 10 1 1e308
.end
