* HSPICE .ac POI np f1 ... fn [CR .AC]: an explicit frequency list.
* Oracle: analytic RC low-pass, H = 1/(1 + j*2*pi*f*R*C), R*C = 1 ms.
* Expected results: ac_poi.expected.json
v1 in 0 ac 1
r1 in out 1k
c1 out 0 1u
.ac poi 3 10 159.1549431 1k
.end
