* .four analyses the last period of the deck's .tran, not its own run (#147)
* Expected results: deck_tran_window.expected.json
* Damped sine: the window is [1m, 2m], before tstop's decay to ~0.01 at 5m.
V1 in 0 sin(0 1 1k 0 1000)
R1 in 0 1k
.tran 1u 2m
.four 1k v(in)
.end
