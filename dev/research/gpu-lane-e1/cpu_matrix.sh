#!/bin/sh
# cpu_matrix.sh ESPICE PM: host eval on 1, 24 and 32 threads (ParEval) over the same decks.
cd "$(dirname "$0")"
./run.sh "$1" "$2" 32 lane mixed "100p uic" cpu 1
for c in "lane coherent" "lane mixed" "shuffle mixed"; do ./run.sh "$1" "$2" 1024 $c "100p uic" cpu 1; done
for T in 24 32; do ./run.sh "$1" "$2" 1024 lane mixed "100p uic" cpu $T; done
