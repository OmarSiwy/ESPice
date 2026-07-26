#!/usr/bin/env bash
# ngspice's own decks for `zig build bench-suites -Dsuite=ngspice`: the
# repo's tests/ and examples/ at the ngspice-45 tag (the version the
# benchmarking shell runs), plus the Quality-page archives (paranoia,
# ISCAS85 on PTM 45 nm BSIM4, KiCad). Fetched, never vendored. Sources land
# in DIR/src.assets (the runner skips *.assets/); every runnable deck becomes
# DIR/<collection>/<path>.sp with its .include/.lib paths made absolute.
#   tests/suites/ngspice/fetch.sh zig-out/suites/ngspice
#
# Conversion: .control blocks are dropped. A deck with no analysis card of
# its own gets the plain analysis and save commands of its control block as
# cards (ISCAS85 runs `tran 1ps 1ns uic` that way, given a 10 ps max step).
# Identical source files are kept once.
#
# Skipped, with the reason:
#   tests/{bsim3,bsim4,bsimsoi,hicum2,hisim,hisimhv1,hisimhv2}
#               CMC qaSpec trees, run by tests/bin/runQaTests.pl, not decks
#   examples/osdi, any deck loading OSDI or with N instances
#               OSDI; ESPice compiles its Verilog-A at build time
#   examples/{xspice,digital}, tests/xspice, any deck with an A instance
#               XSPICE code models; ESPice has none
#   examples/cider, any numd/nbjt/numos model
#               CIDER numerical devices; ESPice has none
#   examples/{tclspice,shared,klu,paranoia}
#               Tcl/shared-library drivers; klu/Circuits/85 duplicates the
#               iscas85Circuits.7z archive taken below
#   decks with no analysis card whose control block runs its analyses in a
#   loop (foreach, repeat, while, dowhile) or alters the circuit (alter,
#   altermod, alterparam, reset, mc_source)
#               the result depends on the script, not on the netlist
#   decks whose .include/.lib file is missing from the source tree
#               Windows paths to a local PDK, uncommitted vendor models
#   files left with no analysis   includes, libraries, control-only decks
#   ISCAS85 c*p/ and *_oc variants  repeats of the base c432..c7552 ladder
#   KiCad projects with only a .sch (no exported netlist)
set -euo pipefail
D=$(mkdir -p "${1:?usage: fetch.sh DIR}" && cd "$1" && pwd)
S=$D/src.assets
mkdir -p "$S"

NGSPICE_SHA=86c78150b77ceea8488707565b3be2d2f4e7fbb9   # tag ngspice-45
Q=https://ngspice.sourceforge.io/tests
archive() { # NAME SHA256
  [ -s "$S/$1.7z" ] || curl -sSfL -o "$S/$1.7z" "$Q/$1.7z"
  echo "$2  $S/$1.7z" | sha256sum -c --quiet
  [ -d "$S/$1" ] || { nix shell nixpkgs#p7zip -c 7z x -y -o"$S/$1.tmp" "$S/$1.7z" >/dev/null && mv "$S/$1.tmp"/* "$S/$1" && rmdir "$S/$1.tmp"; }
}
if [ "$(git -C "$S/ngspice" rev-parse HEAD 2>/dev/null)" != "$NGSPICE_SHA" ]; then
  rm -rf "$S/ngspice"
  git -c init.defaultBranch=main init -q "$S/ngspice"
  git -C "$S/ngspice" remote add origin https://git.code.sf.net/p/ngspice/ngspice
  git -C "$S/ngspice" sparse-checkout set tests examples COPYING
  git -C "$S/ngspice" fetch -q --depth 1 origin "$NGSPICE_SHA"
  git -C "$S/ngspice" checkout -q FETCH_HEAD
fi
archive paranoia 9d8cdc5c9b0bb8cff314115afbca9ee100c37facc80e2d55dd324c375178765b
archive iscas85Circuits da7b8f4c1b817fbe353b09394697d3e4c5bdd32d45cbc96c0e0a17457bbf5dad
archive kicad-test-circuits 2fe661de9bc0b8f5f7747721b8e4deffb5cbeddba49cdb4530a766bc70ca2a62

# One deck to stdout; exit 3 scripted, 4 no analysis, 5 XSPICE, 6 CIDER,
# 7 OSDI, 8 an include missing from the source tree.
convert() { # SRC
  tr -d '\r' < "$1" | awk -v dir="$(dirname "$1")" '
    function word(s) { sub(/^[ \t]+/, "", s); split(s, w, /[ \t(]+/); return tolower(w[1]) }
    BEGIN { ana = "^(op|dc|ac|tran|noise|tf|pz|sens|disto|pss|sp)$"; rc = 0 }
    NR == 1 { print; next }
    { h = word($0) }
    ctl { if (h == ".endc") ctl = 0
          else if (h ~ /^(foreach|repeat|while|dowhile|if)$/) { st[++sp] = h; loops += h != "if" }
          else if (h == "end" && sp > 0) loops -= st[sp--] != "if"
          else if (h ~ /^(alter|altermod|alterparam|reset|mc_source)$/) scr = 1
          else if (h ~ /^(pre_osdi|osdi)$/) rc = 7
          else if ((h ~ ana || h == "save") && loops) scr = 1
          else if ((h ~ ana || h == "save") && $0 !~ /\$/) { sub(/^[ \t]+/, ""); lift = lift "." $0 "\n" }
          next }
    h == ".control" { ctl = 1; next }
    ended { next }
    h == ".end" { ended = 1; next }
    h ~ /^\.(osdi)$/ || h ~ /^n/ { rc = 7 }
    h ~ /^a/ { rc = rc == 7 ? 7 : 5 }
    h == ".model" && tolower($3) ~ /^(numd|nbjt|numos)/ { rc = 6 }
    h ~ ("^\\." substr(ana, 2)) { has = 1 }
    (h == ".include" || h == ".inc" || (h == ".lib" && NF >= 3)) {
      p = $2; gsub(/["\047]/, "", p)
      if (p !~ /^\//) p = dir "/" p
      if ((getline junk < p) < 0) rc = rc ? rc : 8; else close(p)
      $2 = "\"" p "\""
    }
    { print }
    END { if (!has) printf "%s", lift
          print ".end"
          exit rc ? rc : has ? 0 : scr ? 3 : lift != "" ? 0 : 4 }'
}

declare -A seen=() count=()
emit() { # COLLECTION ROOT REL
  local src=$2/$3 out=$D/$1/${3%.*}.sp sum
  [ ! -e "$out" ] || out=$D/$1/$3.sp
  sum=$(md5sum < "$src" | cut -c1-32)
  [ -z "${seen[$sum]:-}" ] || { count[duplicate]=$((${count[duplicate]:-0} + 1)); return; }
  seen[$sum]=1
  mkdir -p "$(dirname "$out")"
  local rc=0; convert "$src" > "$out.tmp" || rc=$?
  case $rc in
    0) mv "$out.tmp" "$out"; [ ! -f "$(dirname "$src")/.spiceinit" ] || cp "$(dirname "$src")/.spiceinit" "$(dirname "$out")/"; count[deck]=$((${count[deck]:-0} + 1)); return ;;
    3) count[scripted]=$((${count[scripted]:-0} + 1)) ;;
    4) count[no-analysis]=$((${count[no-analysis]:-0} + 1)) ;;
    5) count[xspice]=$((${count[xspice]:-0} + 1)) ;;
    6) count[cider]=$((${count[cider]:-0} + 1)) ;;
    7) count[osdi]=$((${count[osdi]:-0} + 1)) ;;
    8) count[missing-include]=$((${count[missing-include]:-0} + 1)) ;;
    *) exit "$rc" ;;
  esac
  rm -f "$out.tmp"
}
walk() { # COLLECTION ROOT FIND-ARGS...
  local c=$1 r=$2; shift 2
  while IFS= read -r -d '' f; do emit "$c" "$r" "$f"; done < <(cd "$r" && find "$@" -type f \( -name '*.cir' -o -name '*.sp' -o -name '*.net' \) -printf '%P\0' | sort -z)
}

rm -rf "${D:?}"/{tests,examples,paranoia,iscas85,kicad}
N=$S/ngspice
walk tests "$N/tests" . -path ./bsim3 -prune -o -path ./bsim4 -prune -o -path ./bsimsoi -prune -o -path ./hicum2 -prune \
  -o -path ./hisim -prune -o -path ./hisimhv1 -prune -o -path ./hisimhv2 -prune -o -path ./xspice -prune -o -path ./bin -prune -o
walk examples "$N/examples" . -path ./osdi -prune -o -path ./xspice -prune -o -path ./digital -prune -o -path ./cider -prune \
  -o -path ./tclspice -prune -o -path ./shared -prune -o -path ./klu -prune -o -path ./paranoia -prune -o
walk paranoia "$S/paranoia/examples" . -path ./xspice -prune -o -path ./digital -prune -o -path ./cider -prune -o
walk iscas85 "$S/iscas85Circuits/85" . -path './c*p' -prune -o ! -name '*_oc.net'
# ponytail: a 10 ps max step instead of the implied 1 ps (c432 in ngspice:
# 21 s to 2.6 s); c5315 and up still need `--timeout` above 300 s on a busy
# machine. The window and the inputs are the originals.
sed -i 's/^\.tran 1ps 1ns\( uic\)\?$/.tran 1ps 1ns 0 10ps\1/' "$D"/iscas85/*/*.sp
walk kicad "$S/kicad-test-circuits" .
# Decks written for ngspice's PSpice/LTspice compatibility mode (KiCad sets
# it; upstream ships it as .spiceinit only in p-to-n-examples and optran).
# Every other deck in these directories runs the same under it.
for d in "$D"/kicad/*/ "$D"/examples/{ddt,probe,soa}/; do echo 'set ngbehavior=ltpsa' > "$d/.spiceinit"; done
for k in "${!count[@]}"; do echo "$k: ${count[$k]}"; done | sort >&2
