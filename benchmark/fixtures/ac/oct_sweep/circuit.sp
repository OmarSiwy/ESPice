* AC sweep on an OCTAVE grid: the only `.ac oct` deck in the suite, and the
* other half of the sweep-type gap ac/lin_sweep opens.
*
* 4 points per octave over 6 octaves (100 Hz to 6.4 kHz) is 25 samples. Unlike
* LIN, this count IS a rate, so it carries across to a simulator that counts
* intervals without adjustment — which is exactly the asymmetry that makes the
* pair worth having rather than either deck alone.
*
* espice currently declines this deck with UnsupportedFrequencySweep, same as
* ac/lin_sweep; ngspice and VACASK both run it.
*
* Same RC corner (1 kHz) as ac/lin_sweep, so a disagreement between the two
* isolates the frequency grid rather than the circuit.
V1 in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 159.155n
.ac oct 4 100 6400
.end
