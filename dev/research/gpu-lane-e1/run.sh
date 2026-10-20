#!/bin/sh
# run.sh ESPICE PM N ORDER SIZING TSTOP BACKEND [THREADS]: one E1 timing run.
# BACKEND cuda prints the per-eval device phases (ESPICE_GPU_STATS=phases);
# cpu prints --timing-in-depth's eval split. Decks land in $TMPDIR.
E=$1 PM=$2 N=$3 ORDER=$4 SIZING=$5 TSTOP=$6 BE=$7 TH=${8:-1}
D=${TMPDIR:-/tmp}/e1_${N}_${ORDER}_${SIZING}_$(echo "$TSTOP" | tr " " _).sp
[ -f "$D" ] || python3 "$(dirname "$0")/gen_lanes.py" "$PM" "$N" "$ORDER" "$SIZING" "$TSTOP" > "$D"
echo "== N=$N order=$ORDER sizing=$SIZING tstop=$TSTOP backend=$BE threads=$TH load=$(cut -d' ' -f1-3 /proc/loadavg)"
ESPICE_THREADS=$TH ESPICE_GPU_STATS=phases /usr/bin/env time -f "wall=%e s rss=%M KB" \
  "$E" --backend "$BE" --timing-in-depth -b -r /dev/null "$D" 2>&1 |
  grep -E "gpu-prof|gpu-stats|eval|Newton|query 1 tran|wall=|rror|total" | grep -v "attempt=" | head -40
