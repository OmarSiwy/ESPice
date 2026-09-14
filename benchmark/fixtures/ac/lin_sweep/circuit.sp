* AC sweep on a LINEAR grid: the only `.ac lin` deck in the suite. Every other
* AC fixture here uses `dec`, so the two remaining sweep types went untested.
*
* The counts are not the same kind of number. SPICE's LIN count is the TOTAL
* number of points; its DEC and OCT counts are per-decade and per-octave RATES.
* Any reader that treats all three alike lands every sample half a step off the
* other engine's grid and reports a phantom error across the whole column.
*
* espice currently declines this deck with UnsupportedFrequencySweep, so its
* row reads `skip` with that reason. ngspice and VACASK both run it. That skip
* is the point: the gap was invisible while nothing in the suite asked.
*
* Same RC corner (1 kHz) as ac/oct_sweep, so the two decks differ only in how
* the frequency axis is generated and a disagreement isolates the grid.
V1 in 0 DC 0 AC 1
R1 in out 1k
C1 out 0 159.155n
.ac lin 21 1k 21k
.end
