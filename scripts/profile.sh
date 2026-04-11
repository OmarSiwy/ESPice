#!/usr/bin/env bash
# Profile BigOSpice with cargo-flamegraph.
# Usage: scripts/profile.sh [NETLIST] [OUTPUT_SVG]
#
# Requires: nix develop (provides cargo-flamegraph + perf)
# Run from repo root inside the nix dev shell.

set -euo pipefail

NETLIST="${1:-tests/fixtures/basic/rc_transient.sp}"
OUT="${2:-flamegraph.svg}"
BENCH="${3:-}"  # optional: bench name to profile instead of binary

if [ ! -f "$NETLIST" ] && [ -z "$BENCH" ]; then
    echo "Usage: $0 [NETLIST] [OUTPUT_SVG]"
    echo "       $0 --bench suite [OUTPUT_SVG]"
    exit 1
fi

echo "Building release binary with debug info..."
CARGO_PROFILE_RELEASE_DEBUG=true cargo build --release

if [ -n "$BENCH" ]; then
    echo "Profiling bench: $BENCH → $OUT"
    cargo flamegraph --bench suite -- "$BENCH" --profile-time 10 -o "$OUT"
else
    echo "Profiling: bigospice $NETLIST → $OUT"
    cargo flamegraph --bin bigospice -- "$NETLIST" -o "$OUT"
fi

echo "Flamegraph written to $OUT"
echo "Open in browser: xdg-open $OUT"
