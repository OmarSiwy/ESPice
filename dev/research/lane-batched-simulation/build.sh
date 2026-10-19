#!/bin/sh
# build.sh W: bench_w$W from bench.zig, run inside `nix develop .#ci`.
# Needs beside it: bsimcmg.zig (VerA 0.10.3 output, from .zig-cache/o/*/),
# contract.zig (zig-pkg/vera-0.10.3-*/tools/contract.zig), params.zig (the
# asap7 nmos_rvt card as `pub const card = [_]struct{[]const u8, f64}{...}`).
W=$1
echo "pub const W = $W; pub const SIG = false;" > cfg$W.zig
nice -n 10 zig build-exe -OReleaseFast -mcpu=native -j6 --name bench_w$W \
  --dep contract --dep device --dep cfg -Mroot=bench.zig \
  --dep contract -Mdevice=bsimcmg.zig -Mcontract=contract.zig -Mcfg=cfg$W.zig
