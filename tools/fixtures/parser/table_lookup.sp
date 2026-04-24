* Parser Test — TABLE lookup controlled source
*
* E element with TABLE keyword provides piecewise-linear transfer:
*   Exxx out 0 TABLE {expr} = (x0,y0) (x1,y1) (x2,y2) ...
* Values between points are linearly interpolated
*
* This models a non-linear amplifier with compression:
*   Vin=0V -> Vout=0V, Vin=1V -> Vout=3V, Vin=2V -> Vout=4V
*
Vin in 0 DC 0
*
Etable out 0 TABLE {V(in)} = (0,0) (0.5,1.5) (1.0,3.0) (1.5,3.8) (2.0,4.0) (3.0,4.0)
Rload out 0 10k
*
.options noacct
.dc Vin 0 3 0.1
.print DC V(in) V(out)
.END
