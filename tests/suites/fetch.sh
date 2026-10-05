#!/usr/bin/env bash
# External SPICE suites for `zig build bench-suites`: fetched at pinned
# revisions into DIR/<suite>/, never vendored (several are GPL-3 or carry
# no licence). Each tests/suites/<suite>/fetch.sh takes its output dir and
# leaves ngspice-dialect *.sp decks there; the bench runner times every one
# against ngspice and VACASK and compares their waveforms.
#   tests/suites/fetch.sh zig-out/suites            every suite
#   tests/suites/fetch.sh zig-out/suites ngspice    one suite
# Survey and licences: docs/research/spice-benchmark-suites.md.
set -euo pipefail
OUT=${1:?usage: fetch.sh DIR [suite...]}
shift
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
suites=("$@")
[ ${#suites[@]} -gt 0 ] || for d in "$HERE"/*/; do [ -x "$d/fetch.sh" ] && suites+=("$(basename "$d")"); done
for s in "${suites[@]}"; do
  echo "suite $s" >&2
  "$HERE/$s/fetch.sh" "$OUT/$s"
done
