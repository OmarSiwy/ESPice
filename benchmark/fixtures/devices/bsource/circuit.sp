* Unit fixture: behavioral B source, nonlinear V expression.
Vc ctl 0 DC 1
B1 out 0 V = V(ctl)*V(ctl) + 0.5
RL out 0 1k
.dc Vc 0 3 0.1
.end
