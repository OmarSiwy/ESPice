#!/usr/bin/env bash
# CMC model QA material and the GF180MCU fd_pr ngspice regression, fetched
# at pinned URLs and commits (sha256-checked, never vendored) and turned
# into single-device ngspice decks by gen.py:
#   tests/suites/cmcqa/fetch.sh zig-out/suites/cmcqa
# Writes DIR/{hicum,psp,gf180}/*.sp, each with its <deck>.sp.reference.
# Sources, licences and what ngspice can run: README.md here.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
D=$(mkdir -p "${1:?usage: fetch.sh DIR}" && cd "$1" && pwd)
cd "$D"
mkdir -p src hicum psp gf180

get() { # URL FILE SHA256
  [ -s "$2" ] || curl -sSfL -o "$2" "$1"
  echo "$3  $2" | sha256sum -c --quiet - || { rm -f "$2"; echo "cmcqa: $2 failed its sha256 check" >&2; exit 1; }
}

HIC=https://www.iee.et.tu-dresden.de/iee/eb/forsch/Models
get "$HIC/qa_setup_hicumL2V2p4p0.zip" src/hicum_setup.zip 80caeec32d4a86781f52b8155aa8c49389f30b0b1d7b7cc6083c5be46c0874b5
get "$HIC/qa_results_hicumL2V2p4p0.zip" src/hicum_results.zip 27496ce9b80b35eccb214eae0676589006e0104c174a313c1480f419f8f11193
get 'https://www.cea.fr/cea-tech/leti/pspsupport/Documents/Level%20103.3.3/psp_VA_and_CMC_ref_data.tar.gz' \
  src/psp.tar.gz da9f0815753e049e1122f2f24aba78724929fd86d485ed133639309811853b7e
GF=https://raw.githubusercontent.com/google/globalfoundries-pdk-libs-gf180mcu_fd_pr/9f992d5a9186d1f7820c58f039c484ad35b2edea
while read -r sum path; do
  mkdir -p "src/gf180/$(dirname "$path")"
  get "$GF/$path" "src/gf180/$path" "$sum"
done < "$HERE/gf180.sha256"

[ -f src/hicum/setup/qaSpec ] || python3 -m zipfile -e src/hicum_setup.zip src/hicum/setup
[ -d src/hicum/results ] || python3 -m zipfile -e src/hicum_results.zip src/hicum/results
PSP=src/psp_VA_and_CMC_ref_data/psp/103.3.0
[ -d "$PSP" ] || tar -xzf src/psp.tar.gz -C src psp_VA_and_CMC_ref_data/psp/103.3.0

rm -f hicum/*.sp* psp/*.sp* gf180/*.sp*
python3 "$HERE/gen.py" cmc src/hicum/setup/qaSpec src/hicum/results hicum hicum NPN 8
for v in sym_nmos:NMOS sym_pmos:PMOS asym_nmos:NMOS asym_pmos:PMOS; do
  python3 "$HERE/gen.py" cmc "$PSP/${v%%:*}/qaSpec" "$PSP/${v%%:*}/reference" psp "psp_${v%%:*}" "${v##*:}" 1040
done
GT=src/gf180/models/ngspice
cp "$GT/design.ngspice" "$GT/sm141064.ngspice" gf180/
python3 "$HERE/gen.py" gf180 "$GT/testing" gf180
