#!/usr/bin/env bash
# Capture one .raw per fixture deck into $1, plus an exit-code manifest.
# Used to prove bit-identity across a kernel change (see docs/perf/*.md).
set -u
out="$1"
mkdir -p "$out"
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/zig-out/bin/espice"
: >"$out/exits.txt"
while IFS= read -r deck; do
    rel="${deck#"$root"/benchmark/fixtures/}"
    tag="${rel%/circuit.sp}"
    tag="${tag//\//_}"
    timeout 300 "$bin" -b --backend cpu -r "$out/$tag.raw" "$deck" >/dev/null 2>&1
    echo "$tag $?" >>"$out/exits.txt"
done < <(find "$root/benchmark/fixtures" -name circuit.sp | sort)
