#!/usr/bin/env bash
# Real post-layout decks for `zig build bench-postlayout`, fetched rather
# than vendored (the ISCAS decks carry no license). Writes DIR/*.sp plus
# DIR/pdk; the runner picks up DIR when it sits under zig-out/postlayout:
#   tests/benchmark/postlayout/fetch.sh zig-out/postlayout/real
#
#   c7552_sky130.sp  ISCAS85 c7552 on SkyWater sky130 (ngspice's own KLU
#                    benchmark): 14,942 BSIM4 FETs, one synthetic pi per net
#   c7552_ihp.sp     the same netlist on IHP SG13G2 (PSP 103.6); ngspice-45
#                    needs an OSDI build of PSP for it, so espice only
#   tdc_sky130.sp    iic-jku TT06 time-to-digital converter, magic-extracted
#                    (2,562 FETs, extracted C), Apache-2.0
# Windows are 2 ns (the originals run 15 ns and 600 ns) so a benchmark pass
# fits in minutes; the TDC's start/stop edges move into that window and its
# supply is DC instead of a 100 ns ramp.
set -euo pipefail
D=$(mkdir -p "${1:?usage: fetch.sh DIR}" && cd "$1" && pwd)
cd "$D"
mkdir -p pdk src

# Pinned sources.
VOLARE=https://github.com/chipfoundry/volare/releases/download/sky130-c6d73a35f524070e85faff4a6a9eef49553ebc2b
IHP_SHA=5e6d592e4002946a4616f798c357f0f3c06cf3b6   # IHP-GmbH/IHP-Open-PDK
TDC_SHA=beeb8db07992302216fbea7e0da7845b8ada2a2c   # iic-jku/jku-tt06-tdc-v1

fetch() { [ -s "$2" ] || curl -sSfL -o "$2" "$1"; }
fetch "$VOLARE/common.tar.zst" src/common.tar.zst                 # sky130A ngspice libs, Apache-2.0
fetch "$VOLARE/sky130_fd_pr.tar.zst" src/sky130_fd_pr.tar.zst     # sky130_fd_pr models, Apache-2.0
fetch https://ngspice.sourceforge.io/tests/skywater-examples.7z src/skywater-examples.7z
fetch https://ngspice.sourceforge.io/tests/IHP-c7552_ann.7z src/IHP-c7552_ann.7z
T=https://raw.githubusercontent.com/iic-jku/jku-tt06-tdc-v1/$TDC_SHA
fetch "$T/sim/tdc_simple/tdc.pex.spice" tdc.pex.spice
fetch "$T/sim/tdc_simple/tb_tt06_tdc.spice" src/tb_tt06_tdc.spice
fetch "$T/LICENSE" src/LICENSE.tdc

if [ ! -d pdk/sky130A ]; then
  nix shell nixpkgs#zstd -c tar --zstd -C pdk -xf src/common.tar.zst
  nix shell nixpkgs#zstd -c tar --zstd -C pdk -xf src/sky130_fd_pr.tar.zst
  rm -rf pdk/sky130B
fi
[ -f src/c7552_ann_skywater.net ] || nix shell nixpkgs#p7zip -c 7z x -y -osrc src/skywater-examples.7z >/dev/null
[ -f src/c7552_ann_IHP.net ] || nix shell nixpkgs#p7zip -c 7z x -y -osrc src/IHP-c7552_ann.7z >/dev/null
if [ ! -d pdk/ihp ]; then
  git -c init.defaultBranch=main init -q pdk/ihp
  git -C pdk/ihp remote add origin https://github.com/IHP-GmbH/IHP-Open-PDK
  git -C pdk/ihp sparse-checkout set ihp-sg13g2/libs.tech/ngspice/models
  git -C pdk/ihp fetch -q --depth 1 --filter=blob:none origin "$IHP_SHA"
  git -C pdk/ihp checkout -q FETCH_HEAD
fi

SKY=pdk/sky130A/libs.tech/ngspice/sky130.lib.spice
# c7552: the .control block becomes a .save of 16 outputs and a 2 ns .tran.
c7552() { # NET LIBLINE OUT
  local saves
  saves=$(grep -m1 '^\*\*\*\* the output ports:' "$1" | tr ' ' '\n' | grep '^g' | head -16 | sed 's/.*/v(&)/' | tr '\n' ' ')
  sed -e "s#^\.lib .*#$2#" -e '/^\.control/,/^\.endc/d' \
      -e "s#^\.end\$#.save $saves\n.tran 1p 2n 0 10p uic\n.end#" "$1" | tr -d '\r' > "$3"
}
c7552 src/c7552_ann_skywater.net ".lib \"$SKY\" tt" c7552_sky130.sp
c7552 src/c7552_ann_IHP.net ".lib \"pdk/ihp/ihp-sg13g2/libs.tech/ngspice/models/cornerMOSlv.lib\" mos_tt" c7552_ihp.sp
# ngspice's settings for the sky130 decks (from the archive's spice.rc).
printf 'set ngbehavior=hsa\nset ng_nomodcheck\n' > .spiceinit

# TDC: drop the two load caps on floating nodes (they make the ngspice OP
# singular), hold VDD at 1.8 V, start at 0.1 ns and stop at 0.9 ns.
sed -e '/^Cload\[6[45]\]/d' \
    -e 's#^VDAC2 VDD GND .*#VDAC2 VDD GND 1.8#' \
    -e 's#^VDAC start GND .*#VDAC start GND 0 pwl(0 0 100p 0 110p 1.8)#' \
    -e 's#^VDAC1 stop GND .*#VDAC1 stop GND 0 pwl(0 0 900p 0 910p 1.8)#' \
    -e "s#^\.lib .*sky130.lib.spice.*#.lib \"$SKY\" tt#" \
    -e '/^\.control/,/^\.endc/d' -e 's#^\.tran .*#.tran 0.01n 2n#' src/tb_tt06_tdc.spice > tdc_sky130.sp
grep -q '^\.tran' tdc_sky130.sp || sed -i 's#^\.end$#.tran 0.01n 2n\n.end#' tdc_sky130.sp

for f in c7552_sky130.sp c7552_ihp.sp tdc_sky130.sp; do
  echo "$D/$f: $(grep -ci '^x' "$f") X, $(grep -ci '^r' "$f") R, $(grep -ci '^c' "$f") C"
done
