* HSPICE .dc grids [CR .DC]: POI point list inside, a LIN second source
* outside. Oracle: analytic, v(out) = v1*r2/(3k + r2) + i1*(3k || r2)
* with i1 driven from ground into out.
* Expected results: dc_poi_grid.expected.json
v1 in 0 1
i1 0 out 0
r1 in out 3k
r2 out 0 1k
.dc v1 poi 3 0.5 -1 2 i1 lin 2 0 1m
.end
