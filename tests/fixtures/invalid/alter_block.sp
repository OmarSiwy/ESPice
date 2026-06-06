* .alter reruns the deck with edits; reading its cards into the base deck
* (two resistors in parallel) was a silent wrong answer. Oracle: input
* contract: ESPice has no .alter yet.
* Expected results: alter_block.expected.json
v1 a 0 1
r1 a 0 1k
.op
.alter
r1 a 0 2k
.end
