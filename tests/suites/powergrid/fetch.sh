#!/usr/bin/env bash
# IBM power grid benchmarks (Nassif, ASP-DAC 2008) and SRAM-PG, fetched at
# pinned URLs with sha256 checks and never vendored (the IBM files carry no
# licence). Leaves DIR/<name>.sp decks, plus DIR/<name>.solution where the
# source ships one (IBM .solution/.output, SRAM-PG .sol.ic/.sol.pt0), for a
# later oracle comparison. Downloads are cached in DIR/src; reruns skip them.
#   tests/suites/powergrid/fetch.sh zig-out/suites/powergrid
#   POWERGRID_LARGE=1 tests/suites/powergrid/fetch.sh zig-out/suites/powergrid
# Default: ibmpg1-3, ibmpg1t and SRAM-PG ssram (DC and transient), each
# measured under 10 minutes in ngspice-45 with KLU. POWERGRID_LARGE=1 adds
# the rest (README.md lists why): ibmpg4-8 DC, ibmpg2t-6t, and the three
# multi-million-node SRAM-PG designs (about 800 MB compressed, 7 GB unpacked).
set -euo pipefail
D=$(mkdir -p "${1:?usage: fetch.sh DIR}" && cd "$1" && pwd)
cd "$D"
mkdir -p src

IBM=https://web.ece.ucsb.edu/~lip/PGBenchmarks/ibmpg
SRAM=https://media.githubusercontent.com/media/ShenShan123/SRAM-PG/62a95026696e8f669e9aab25dba574a9cd65b74d

fetch() { # URL SHA256: into src/, verified
  local f=src/${1##*/}
  [ -s "$f" ] || { curl -sSfL -o "$f.part" "$1" && mv "$f.part" "$f"; }
  echo "$2  $f" | sha256sum -c --quiet - || { rm -f "$f"; exit 1; }
}
gen() { # OUT CMD...: OUT from CMD's stdout, unless it already exists
  [ -s "$1" ] || { "${@:2}" > "$1.part" && mv "$1.part" "$1"; }
}
untar() { tar -xjOf "$1"; }
# Transient decks: drop the SPICE2 .opti/.width cards and turn .print into
# .save, so the raw file holds the 20 probes instead of every node. Under
# ngspice-45's default trapezoidal rule ibmpg1t stalls at t = 0.23 ps
# (the step shrinks without bound), so they run with Gear.
tran_deck() {
  bzcat "$1" | sed -e '1a .options method=gear' -e '/^\.opti /d' -e '/^\.width /d' -e 's/^\.print tran /.save /'
}

# DC decks run as shipped (R, V, I, .op).
ibm_dc() { # N SPICE_SHA SOLUTION_SHA
  fetch "$IBM/ibmpg$1.spice.bz2" "$2"
  fetch "$IBM/ibmpg$1.solution.bz2" "$3"
  gen ibmpg$1.sp bzcat src/ibmpg$1.spice.bz2
  gen ibmpg$1.solution bzcat src/ibmpg$1.solution.bz2
}
ibm_tran() { # N SPICE_SHA OUTPUT_FILE OUTPUT_SHA
  fetch "$IBM/ibmpg$1t.spice.bz2" "$2"
  fetch "$IBM/$3" "$4"
  gen ibmpg$1t.sp tran_deck src/ibmpg$1t.spice.bz2
  case $3 in
    *.bz2) gen ibmpg$1t.solution bzcat "src/$3" ;;
    *) gen ibmpg$1t.solution gzip -dc "src/$3" ;;
  esac
}
# ibmpg7/8 ship zipped with no solution.
ibm_zip() { # N ZIP_SHA
  fetch "$IBM/ibmpg$1.zip" "$2"
  gen ibmpg$1.sp unzip -p src/ibmpg$1.zip ibmpg$1.spice
}
# SRAM-PG decks start with a resistor (SPICE would eat it as the title) and
# carry HSPICE .option cards and one .meas per node (40k in ssram). Give
# them a title, drop both, and save the 20 probes the transient solution
# lists.
sram_deck() { # TARBALL TITLE SAVE
  untar "$1" | sed -e "1i * $2" -e '/^\.title/d' -e '/^\.option/d' -e '/^\.meas/d' -e "s#^\.END\$#$3\n.end#"
}
probes() { awk '$1 == "time" { $1 = ".save"; print; exit }' "$1"; }
# SRAM-PG: one file per tarball.
sram() { # NAME DC_SHA DCSOL_SHA TRAN_SHA TRANSOL_SHA
  fetch "$SRAM/$1_dc.sp.tar.bz2" "$2"
  fetch "$SRAM/$1_dc.sol.ic.tar.bz2" "$3"
  fetch "$SRAM/$1_trans.sp.tar.bz2" "$4"
  fetch "$SRAM/$1_trans.sol.pt0.tar.bz2" "$5"
  gen $1_dc.solution untar src/$1_dc.sol.ic.tar.bz2
  gen $1_trans.solution untar src/$1_trans.sol.pt0.tar.bz2
  gen $1_dc.sp sram_deck src/$1_dc.sp.tar.bz2 "SRAM-PG $1 DC" ""
  gen $1_trans.sp sram_deck src/$1_trans.sp.tar.bz2 "SRAM-PG $1 transient" "$(probes $1_trans.solution)"
}

ibm_dc 1 aaa6d3159e088719058084ee0a3d28d943a5bfead7e931165da9f28165ff385a 2ae611b859ad257a1f766a1fbc9987aef6964217ad6600589496f9c670c94d8d
ibm_dc 2 244b6ade058e811965c64b612b0fc23ed38c1f48c03ab8d34c821ec98b2d7d0d 8804d46c222a733d810fb4057dec7cf45489eaa3fb88a2b322c6203875718cc9
ibm_dc 3 12352f3ed5a413987a70415e3b5460834aa5b00e5961213d7947bdc3b2116e6e acb80c036e1ce6727585a0080cd3c793d00b6bdf8a400858ff25df54a6ce9a91
ibm_tran 1 b07ff53c59c288fe4da9a62e9e0216676e334dec12ed2f6ebb46946e2b4436b5 ibmpg1t.output.bz2 77035fd8a6650262e2ecbfbdd14cf1bde437694a1944a11066e7cb6e30d8e7fd
sram ssram 157e4a7166a8095c18df2e344427b7e32bb816c4fa3877707ae54f05b594e92c ca9c0cae180cfcc8c8fe62f4a57c961b14a598b88976820d7dd9b5d39a7a28d8 a7b4810eea99ce18ca62dafefd7e33d9164c5c32c4f56cd181e7f1f062101f40 a5291a117bee151646c951c918261a34d79d76c9677d68cf37d5f40c4ed59d61

[ "${POWERGRID_LARGE:-0}" = 1 ] || exit 0
ibm_dc 4 4f694e1684fab2547b8d06e7360ea9836d500cfa7c992df81cc5c2883cf94888 416c3fded47d39de3248c8c454c77512d4e8f4abd0272f4236204230c041a2b0
ibm_dc 5 be174fbd65956dc4f2d784ff6749fbfdc261d4b6e0e02ddc2ed6e73606855ae2 6d3fed2aea5c86d4bf0f549e9f6cc622eb7ae856a1570d62cd1fa8d0740aa614
ibm_dc 6 2a50f2facf37a6a890cc718f323eaadcaf689cbe439a2886b1366d411dc239f8 1a562c56a2043038e704705531587bdd3b54f1713e9dc88ab7ad3e407f85ca1b
ibm_zip 7 041fdffba29a71fee5ab83d7c6d0bc185dfe42a8cbcf0ea846b2c8659179f168
ibm_zip 8 17016ea957aba25c0d7692ab90d5526791dd38a69d3595fb38da4ecd49eddac7
ibm_tran 2 405a029cd0cbbb5901d864af979494fc7d50169ed2abe7123783124a698b3ffc ibmpg2t.output.gz 410afad1caa845da7309aa779a80d33f3f089086fbc2ddb4fcacd70917c9ed4f
ibm_tran 3 a5dd42cda8a34af2d737cbbfd9a93820e26647aa8ae01f273e46f65ee45bf72a ibmpg3t.output.gz 4fb332f08b8856231460aa543d2a720fce4ca0b6cc13e32f9e6c235ccbefba85
ibm_tran 4 adbdde2a03d8b90ccfcda43b0b69e9dce128a20e6cb5023d38b58cb0a9c77284 ibmpg4t.output.gz ec7213a1d3d02c47c621e3429d8a1743386a93577aabd5071072eef3785409d3
ibm_tran 5 ccec0048f51c317e9e3e16f73d779e60cac53394b51373b60b55d2c016ccfc58 ibmpg5t.output.gz 6019320dd005d70f0cded49901897faf32ed30b00661eb9ba12fab0dcb33b72d
ibm_tran 6 33e20e4f8c7c9d44f47094897f2d7592a0fae7b8a84965813d9f86a9af79b7b5 ibmpg6t.output.gz 434f8eed3d801423df63fee4245577656588c5b14fd9961411c4c070c854ca5b
sram ultra8T b20fdede1182d3c0ea7528c71dcd78293bd24e587ff5132b604541cff522da79 2b54d77064c52256342bb03b46e814b26c594474635bca86ef5883a3f408f483 fd32cffaa86dbedacfc84fac36a55eb92f66a0da19a1f95315c0d2a64769c743 0f4fcf75a153741c29d0e0bbcb199e66faf8ee28f7ecc1016a0b263b06bd2699
sram sandwich 823c4767782fc0ad0fdea92d775d80ed6c358c25923a78500bc5dd97bd81ba03 fd799e4956a10ad21252ca9ba0f8f05c4ddb7a2b3804465f9b01ecbfdbc22b62 db23f2bb48ae95ac005301a547cd9237afdbb7702f7463a9fbefe5e18205bf93 5e3e7bbc4066699600de180f773deed22cf84a1da723a66eabd6b16e926468df
sram sp8192w 528d00d21f8e153bc666c4dd1b6b9bd001c4f060e15bfd0ae3fd18a05960ab99 67916dfc40c1408d322657aa387a23e554a7ad220a29c42c08b0d94f4e5c1b12 a2927acb1cc6827e4e720348643983379da5537ae07c5ee9d5284ba74c39e275 70d48d71fcffa867b910113dc5abb78a8d5696d5b51c4cadff07b40189f95be3
