#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# bench_core.sh -- the RA8EMU-12 throughput benchmark. Runs every ELF in a
# directory for the same instruction budget under --cpu zig and --cpu unicorn,
# subtracts the load-only time (budget 0) and prints net milliseconds, million
# instructions per second for each backend and how many times slower the Zig
# core is.
#
#   tools/bench_core.sh EMULATOR DIR [INSTRUCTIONS]
#
# Build the emulator with -Doptimize=ReleaseFast first; a Debug number says
# nothing. An image the Zig core does not spend the whole budget on (it went
# idle with nothing to wake it, or stopped) is marked with how far it got and
# left out of the total, since the two backends did not do the same work.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 EMULATOR DIR [INSTRUCTIONS]" >&2
    exit 2
fi
emulator=$1
dir=$2
budget=${3:-2000000}

now() { date +%s%N; }

# Wall milliseconds for one run of IMAGE under CPU for N instructions.
wall() {
    local start end
    start=$(now)
    "$emulator" "$1" --cpu "$2" --instructions "$3" >/dev/null 2>&1 || true
    end=$(now)
    echo $(((end - start) / 1000000))
}

# How the Zig core ended IMAGE: its "zig core:" summary line.
ending() {
    local out
    out=$("$emulator" "$1" --cpu zig --instructions "$budget" 2>&1 || true)
    printf '%s\n' "$out" | sed -n 's/^zig core: //p' | head -n 1
}

mips() { awk -v n="$budget" -v ms="$1" 'BEGIN { printf "%.1f", (ms > 0) ? n / ms / 1000 : 0 }'; }

echo "budget $budget instructions per image"
echo
echo "| image | zig ms | unicorn ms | zig MIPS | unicorn MIPS | zig/unicorn |"
echo "|---|---|---|---|---|---|"
zig_total=0
uc_total=0
for image in "$dir"/*.elf; do
    name=$(basename "$image")
    end=$(ending "$image")
    case $end in
    "ran $budget instructions"*) ;;
    *)
        echo "| $name | not timed: ${end:-no summary line} | | | | |"
        continue
        ;;
    esac
    zig=$(($(wall "$image" zig "$budget") - $(wall "$image" zig 0)))
    uc=$(($(wall "$image" unicorn "$budget") - $(wall "$image" unicorn 0)))
    [ "$zig" -lt 1 ] && zig=1
    [ "$uc" -lt 1 ] && uc=1
    zig_total=$((zig_total + zig))
    uc_total=$((uc_total + uc))
    ratio=$(awk -v a="$zig" -v b="$uc" 'BEGIN { printf "%.1fx", a / b }')
    echo "| $name | $zig | $uc | $(mips "$zig") | $(mips "$uc") | $ratio |"
done
[ "$uc_total" -lt 1 ] && uc_total=1
echo "| total | $zig_total | $uc_total | | | $(awk -v a="$zig_total" -v b="$uc_total" 'BEGIN { printf "%.1fx", a / b }') |"
