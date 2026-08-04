# Spectre corpus

Spectre decks from NyanCAD/NetlistParse.rs `tests/corpus/spectre/`
(commit a71091f88217488298fd769bdaf9060134b07139), MIT licensed (LICENSE here). Most are drawn from the Cadence
Spectre manuals; `err_*` decks are inputs that parser rejects. They are the
Spectre grammar's corpus in `tests/grammar/root.zig`: each is read by the
grammar oracle and by the frontend, and the two must agree. The decks carry
no title line (NetlistParse.rs reads line 1 as a statement), so the harness
puts one in front, as the Spectre User Guide's first-line rule reads it.
