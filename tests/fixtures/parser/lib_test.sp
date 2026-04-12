* Parser Test — .LIB section selection from library file
*
* .lib "file" <corner> pulls in a named section from a library file
* Here we select the "tt" (typical-typical) corner
*
.lib "std_cells.lib" tt
*
VDD vdd 0 DC 1.8
Vin in 0 DC 0.9
MN1 out in 0 0 NMOD W=1u L=180n
MP1 out in vdd vdd PMOD W=2u L=180n
*
.options noacct
.op
.dc Vin 0 1.8 0.05
.print DC V(out)
.END
