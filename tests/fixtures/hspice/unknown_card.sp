* HSPICE .LSTB is an analysis ESPice does not run: an error naming the
* line, never a silent drop. Oracle: input contract (HSPICE only).
* Expected results: unknown_card.expected.json
v1 a 0 1 ac 1
r1 a 0 1k
.ac dec 10 1k 1meg
.lstb mode=single vsource=v1
.end
