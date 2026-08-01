* .noise with a current-source input (#84): ngspice names the integrated
* input-referred total i(inoise_total), not v(inoise_total). One 1k
* resistor: onoise = sqrt(4kT*1k*bandwidth), inoise = onoise/1k A rms.
Iin 0 out DC 0 AC 1
R1 out 0 1000
.noise v(out) Iin dec 1 10 1k
.end
