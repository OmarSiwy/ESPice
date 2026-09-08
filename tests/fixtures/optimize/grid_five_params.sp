* ESPice's fifth opt argument, the grid (#95): five independent dividers,
* four sized on their own grids (5, 10, 25, 100 ohm) and one continuous.
* Oracle: analytic. Divider k reads 5 r / (1k + r) against its goal g, so
* the continuous optimum is r = 1k g / (5 - g); on a grid the best point is
* whichever neighbouring multiple gives the smaller relative error, and the
* dividers are independent, so the joint optimum is that point for each.
* Expected results: grid_five_params.expected.json
.param w=opt1(1k, 100, 10k, 0, 5) l=opt1(1k, 100, 10k, 0, 10) w2=opt1(1k, 100, 10k, 0, 25) l2=opt1(1k, 100, 10k, 0, 100) ib=opt1(1k, 100, 10k)
v1 in 0 5
ra0 in o0 1k
rb0 o0 0 w
ra1 in o1 1k
rb1 o1 0 l
ra2 in o2 1k
rb2 o2 0 w2
ra3 in o3 1k
rb3 o3 0 l2
ra4 in o4 1k
rb4 o4 0 ib
.model optmod opt itropt=100 relin=1e-6
.dc v1 0 5 1 sweep optimize=opt1 results=m0,m1,m2,m3,m4 model=optmod
.meas dc m0 find v(o0) at=5 goal=2
.meas dc m1 find v(o1) at=5 goal=1.3
.meas dc m2 find v(o2) at=5 goal=3.1
.meas dc m3 find v(o3) at=5 goal=2.7
.meas dc m4 find v(o4) at=5 goal=1.7
.end
